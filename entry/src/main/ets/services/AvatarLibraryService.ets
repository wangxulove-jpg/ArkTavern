/**
 * AvatarLibraryService Avatar 模型库业务服务
 *
 * T-4.1 阶段 B: 多 Avatar 模型库
 *
 * 职责:
 * - 协调 AvatarLibraryStore(元数据) + Character3DService(导入/VRM 解析)
 * - 提供"导入即入库"和"切换激活"两个核心能力
 * - 提供 Agent 可调用的稳定 API:通过 avatarId 获取模型 URI
 * - 不直接操作 UI / Preferences 内部 key(委托给 Store)
 *
 * 与 Character3DService 的关系:
 * - 复用 Character3DService.importModel 的 VRM 解析 + 文件管理能力
 * - "设为当前激活"时,通过重新调用 importModel 同步 Character3DService 全局状态
 *   (此设计接受文件冗余,因切换激活频率低;文件名带时间戳不会冲突)
 * - 不修改 Character3DService 现有 API,保持向后兼容
 *
 * Agent API:
 * - getAvatarModelUri(avatarId): 返回可直接用于 Scene.load() 的 URI,或 null
 * - listAvatars(): 返回全部 AvatarRecord,供 Agent 选择
 *
 * 日志约束:
 * - 不打印模型文件完整 URI、SHA-256、API Key、Authorization
 * - 仅打印 avatarId 前 8 位 + displayName + 操作结果
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AvatarLibraryStore, AvatarRecord } from '../storage/AvatarLibraryStore';
import { Character3DService, Character3DImportResult, Character3DModelConfig } from './Character3DService';
import { Model3DAssetStore } from '../storage/Model3DAssetStore';
import { AppPreferences } from '../storage/AppPreferences';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';
import { ModelConversionProgress } from '../models/character3d/ModelCompatibility';
import { computeSha256Base64 } from '../utils/ShaUtil';
import {
  AvatarChangeDispatcher,
  AvatarChangeSource,
  AvatarChangedEvent,
  AvatarChangeListener
} from './AvatarChangeEvent';

const LOG_TAG: string = 'AvatarLibraryService';

/** avatarId 日志截断长度(避免打印完整 UUID) */
const AVATAR_ID_LOG_LEN: number = 8;

/**
 * Avatar 入库结果(包含 record 和导入产物)。
 */
export interface AvatarSaveResult {
  /** 新建的 AvatarRecord */
  record: AvatarRecord;
  /** Character3DService 的导入结果(含 VRM 解析等) */
  importResult: Character3DImportResult;
  /** 是否已设为激活 */
  setActive: boolean;
}

/**
 * 重复 Avatar 检测结果(T--4.2 阶段 3.3 SHA-256 去重)。
 */
export interface DuplicateAvatarResult {
  /** 检测到重复,true 表示已存在相同 SHA-256 的 Avatar */
  duplicate: boolean;
  /** 重复时返回已存在的 AvatarRecord;否则 null */
  existingRecord: AvatarRecord | null;
  /** 新导入但未入库的临时结果(duplicate=false 时为本次入库结果) */
  saveResult: AvatarSaveResult | null;
}

/**
 * T-4.2 阶段 4: 模型库修复报告。
 */
export interface AvatarLibraryRepairReport {
  /** 库中引用的文件数量 */
  referencedFiles: number;
  /** 无引用的孤儿文件 URI 列表(当前实现不主动扫描,为空数组) */
  orphanFiles: string[];
  /** 记录存在但文件缺失的 avatarId 列表 */
  missingFiles: string[];
  /** 已清理的失效记录 avatarId 列表 */
  staleRecords: string[];
  /** 是否发现旧单模型 preference */
  legacyPreferenceFound: boolean;
  /** 迁移成功后的 avatarId(未迁移时为空) */
  migratedLegacyAvatarId: string;
  /** 已删除的孤儿文件数量 */
  deletedOrphanCount: number;
  /** 警告信息列表 */
  warnings: string[];
}

/**
 * Avatar 模型库业务服务。
 *
 * 使用方式:
 * - AppServices 初始化时创建,注入 AppPreferences + Character3DService + Model3DAssetStore
 * - UI 通过 AppServices.getAvatarLibraryService() 获取
 * - Agent 通过同一路径调用 getAvatarModelUri(avatarId)
 */
export class AvatarLibraryService {
  private readonly store: AvatarLibraryStore;
  private readonly character3DService: Character3DService;
  private readonly assetStore: Model3DAssetStore;
  /** T-4.2 阶段 2: Avatar 变更事件分发器(单例,进程内) */
  private readonly dispatcher: AvatarChangeDispatcher = new AvatarChangeDispatcher();

  constructor(
    context: common.Context,
    preferences: AppPreferences,
    character3DService: Character3DService
  ) {
    this.store = new AvatarLibraryStore(preferences);
    this.character3DService = character3DService;
    // 复用同一沙箱目录(models3d/),多个 Model3DAssetStore 实例操作同一目录是安全的
    // (HarmonyOS 文件 API 进程级安全,文件名带时间戳不会冲突)
    this.assetStore = new Model3DAssetStore();
    this.assetStore.initialize(context);
  }

  /**
   * T-4.2 阶段 2: 获取事件分发器(供 ViewModel 订阅 AvatarChangedEvent)。
   */
  getDispatcher(): AvatarChangeDispatcher {
    return this.dispatcher;
  }

  /**
   * T-4.2 阶段 2: 订阅 Avatar 变更事件(便捷方法,等价于 getDispatcher().subscribe)。
   */
  subscribe(listener: AvatarChangeListener): void {
    this.dispatcher.subscribe(listener);
  }

  /**
   * T-4.2 阶段 2: 取消订阅。
   */
  unsubscribe(listener: AvatarChangeListener): void {
    this.dispatcher.unsubscribe(listener);
  }

  /**
   * 从源 URI 导入模型并保存到 Avatar 模型库。
   *
   * 流程:
   * 1. 生成新 avatarId (UUID v4)
   * 2. 调用 Character3DService.importModel 完成:
   *    - 复制文件到沙箱
   *    - VRM 解析 + 骨骼映射
   *    - 更新 Character3DService 全局"当前模型"
   * 3. 从 importResult 提取 VRM 元数据 + sourceSha256
   * 4. 创建 AvatarRecord 保存到 store
   * 5. 若 setActive=true,调用 store.setActiveId(avatarId)
   *
   * @param sourceUri DocumentViewPicker 返回的源 URI
   * @param displayName 显示名(空时由 Model3DAssetStore 从 sourceUri 提取)
   * @param setActive 是否同时设为激活模型(默认 true)
   * @param onProgress T-3D.6C-C 转换进度回调(可选)
   * @returns 入库结果
   */
  async saveAvatarFromUri(
    sourceUri: string,
    displayName: string,
    setActive: boolean = true,
    onProgress?: (progress: ModelConversionProgress) => void
  ): Promise<AvatarSaveResult> {
    if (sourceUri.length === 0) {
      throw new Error('sourceUri must not be empty');
    }
    const avatarId: string = generateUuid();
    Logger.info(LOG_TAG, 'saveAvatarFromUri: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', name=' + displayName + ', setActive=' + setActive);

    // 委托 Character3DService 完成导入和 VRM 解析
    // keepOldModel=true: 不删除前一个 Avatar 的模型文件(多模型共存)
    const importResult: Character3DImportResult =
      await this.character3DService.importModel(sourceUri, onProgress, true);

    // 计算文件大小(从沙箱文件读取)
    const fileSize: number = await this.getFileSize(importResult.modelUri);

    // 创建 AvatarRecord(T-4.2: 含 sourceSha256 用于重复检测)
    const record: AvatarRecord = {
      avatarId: avatarId,
      displayName: displayName.length > 0 ? displayName : importResult.displayName,
      modelUri: importResult.modelUri,
      fileSize: fileSize,
      importedAt: Date.now(),
      isVrm: importResult.isVrm,
      vrmVersion: importResult.vrmVersion,
      declaredHumanBoneCount: importResult.declaredHumanBoneCount,
      validHumanBoneCount: importResult.validHumanBoneCount,
      sourceSha256: importResult.sourceSha256
    };
    await this.store.save(record);

    if (setActive) {
      const previousAvatarId: string = await this.store.getActiveId();
      await this.character3DService.setCurrentModelByUri(record.modelUri, record.displayName);
      await this.store.setActiveId(avatarId);
      // T-4.2 阶段 2: 发布 AvatarChangedEvent
      this.dispatcher.dispatch(
        previousAvatarId, avatarId, record.modelUri, record.displayName, AvatarChangeSource.Import
      );
    }

    Logger.info(LOG_TAG, 'saveAvatarFromUri ok: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', isVrm=' + record.isVrm + ', version=' + record.vrmVersion
      + ', declaredBones=' + record.declaredHumanBoneCount
      + ', validBones=' + record.validHumanBoneCount);
    return { record, importResult, setActive };
  }

  /**
   * T-4.2 阶段 3: 统一导入入口(activateAfterImport 控制是否自动激活)。
   *
   * PoC 页面与 AvatarLibraryPage 都通过此方法导入,避免两套逻辑。
   * 默认 activateAfterImport=true。
   *
   * T-4.2 阶段 3.3: 包含 SHA-256 重复检测。
   * - 重复时:删除新导入的模型文件,激活已存在的记录,返回 DuplicateAvatarResult
   * - 非重复:正常入库,返回 DuplicateAvatarResult(duplicate=false, saveResult 非空)
   *
   * @param sourceUri DocumentViewPicker 返回的源 URI
   * @param displayName 显示名(空时由 Service 提取)
   * @param activateAfterImport 导入后是否设为激活
   * @param onProgress T-3D.6C-C 转换进度回调(可选)
   */
  async importAndActivate(
    sourceUri: string,
    displayName: string,
    activateAfterImport: boolean = true,
    onProgress?: (progress: ModelConversionProgress) => void
  ): Promise<DuplicateAvatarResult> {
    // 先执行导入(会复制文件 + 计算 sha256)
    const saveResult: AvatarSaveResult =
      await this.saveAvatarFromUri(sourceUri, displayName, activateAfterImport, onProgress);

    // T-4.2 阶段 3.3: 重复检测(基于 sourceSha256)
    const sha: string = saveResult.record.sourceSha256;
    if (sha.length > 0) {
      const existing: AvatarRecord | null = await this.findDuplicateBySha256(sha, saveResult.record.avatarId);
      if (existing !== null) {
        // 重复:删除新导入的文件,激活已存在的记录
        Logger.info(LOG_TAG, 'importAndActivate: duplicate detected, existing='
          + existing.avatarId.substring(0, AVATAR_ID_LOG_LEN)
          + ', removing new=' + saveResult.record.avatarId.substring(0, AVATAR_ID_LOG_LEN));
        try {
          await this.assetStore.deleteModelByUri(saveResult.record.modelUri);
        } catch (e) {
          Logger.warn(LOG_TAG, 'importAndActivate: delete duplicate file failed: '
            + (e as Error)?.message);
        }
        // 删除新记录
        await this.store.delete(saveResult.record.avatarId);
        // 激活已存在的记录
        if (activateAfterImport) {
          await this.setActiveAvatar(existing.avatarId);
        }
        return { duplicate: true, existingRecord: existing, saveResult: null };
      }
    }
    return { duplicate: false, existingRecord: null, saveResult: saveResult };
  }

  /**
   * T-4.2 阶段 3.3: 按 SHA-256 查找重复 Avatar(排除指定 avatarId)。
   *
   * @param sha256 目标 SHA-256
   * @param excludeAvatarId 需要排除的 avatarId(通常是刚导入的)
   * @returns 已存在的 AvatarRecord;无重复时 null
   */
  async findDuplicateBySha256(
    sha256: string, excludeAvatarId: string
  ): Promise<AvatarRecord | null> {
    if (sha256.length === 0) {
      return null;
    }
    const all: AvatarRecord[] = await this.store.listAll();
    for (let i: number = 0; i < all.length; i++) {
      const r: AvatarRecord = all[i];
      if (r.avatarId === excludeAvatarId) {
        continue;
      }
      if (r.sourceSha256 === sha256) {
        return r;
      }
    }
    return null;
  }

  /**
   * 从 rawfile 导入测试模型并保存到库(用于 PoC 验证)。
   *
   * @param rawfileName rawfile 文件名(如 'vrm_samples/vrm1_seed_san.vrm')
   * @param displayName 显示名
   * @param setActive 是否设为激活
   */
  async saveAvatarFromRawfile(
    rawfileName: string,
    displayName: string,
    setActive: boolean = true
  ): Promise<AvatarSaveResult> {
    const avatarId: string = generateUuid();
    Logger.info(LOG_TAG, 'saveAvatarFromRawfile: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', name=' + displayName);

    const importResult: Character3DImportResult =
      await this.character3DService.importFromRawfileByName(rawfileName, displayName, true);

    const fileSize: number = await this.getFileSize(importResult.modelUri);
    const record: AvatarRecord = {
      avatarId: avatarId,
      displayName: displayName,
      modelUri: importResult.modelUri,
      fileSize: fileSize,
      importedAt: Date.now(),
      isVrm: importResult.isVrm,
      vrmVersion: importResult.vrmVersion,
      declaredHumanBoneCount: importResult.declaredHumanBoneCount,
      validHumanBoneCount: importResult.validHumanBoneCount,
      sourceSha256: importResult.sourceSha256
    };
    await this.store.save(record);
    if (setActive) {
      const previousAvatarId: string = await this.store.getActiveId();
      await this.character3DService.setCurrentModelByUri(record.modelUri, record.displayName);
      await this.store.setActiveId(avatarId);
      // T-4.2 阶段 2: 发布 AvatarChangedEvent(Import 来源)
      this.dispatcher.dispatch(
        previousAvatarId, avatarId, record.modelUri, record.displayName, AvatarChangeSource.Import
      );
    }
    return { record, importResult, setActive };
  }

  /**
   * 列出全部 Avatar 模型(按导入时间升序)。
   */
  async listAvatars(): Promise<AvatarRecord[]> {
    return this.store.listAll();
  }

  /**
   * 清空全部 Avatar 记录及其模型文件(用于开发测试或用户重置)。
   *
   * 流程:
   * 1. listAll 获取全部记录
   * 2. 逐个删除模型文件 + 元数据
   * 3. 清空激活 ID
   * 4. 同步清理 Character3DService 全局状态
   */
  async clearAllAvatars(): Promise<void> {
    const records: AvatarRecord[] = await this.store.listAll();
    for (let i = 0; i < records.length; i++) {
      const rec: AvatarRecord = records[i];
      if (rec.modelUri.length > 0) {
        try {
          await this.assetStore.deleteModelByUri(rec.modelUri);
        } catch (_e) {
          // 文件可能已不存在,忽略
        }
      }
      await this.store.delete(rec.avatarId);
    }
    // 清空激活 ID(store.delete 已自动清空若是激活项,这里再保险一次)
    await this.store.setActiveId('');
    // 同步清理 Character3DService 全局状态
    try {
      await this.character3DService.clearModel();
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearAllAvatars: clearModel failed: ' + (e as Error)?.message);
    }
    Logger.info(LOG_TAG, 'clearAllAvatars ok: cleared ' + records.length + ' records');
  }

  /**
   * 按 avatarId 读取单条记录。
   */
  async getAvatar(avatarId: string): Promise<AvatarRecord | null> {
    return this.store.get(avatarId);
  }

  /**
   * Agent API: 按 avatarId 获取可直接用于 Scene.load() 的模型 URI。
   *
   * @returns 模型 URI;avatarId 不存在或文件丢失时返回 null
   */
  async getAvatarModelUri(avatarId: string): Promise<string | null> {
    const rec: AvatarRecord | null = await this.store.get(avatarId);
    if (rec === null) {
      return null;
    }
    // 文件丢失时返回 null
    if (!this.assetStore.exists(rec.modelUri)) {
      Logger.warn(LOG_TAG, 'getAvatarModelUri: file missing, id='
        + avatarId.substring(0, AVATAR_ID_LOG_LEN));
      return null;
    }
    return rec.modelUri;
  }

  /**
   * 重命名 Avatar(仅修改 displayName,不影响 avatarId 和模型文件)。
   */
  async renameAvatar(avatarId: string, newDisplayName: string): Promise<void> {
    if (newDisplayName.length === 0) {
      throw new Error('newDisplayName must not be empty');
    }
    await this.store.rename(avatarId, newDisplayName);
    Logger.info(LOG_TAG, 'renameAvatar ok: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', newName=' + newDisplayName);
  }

  /**
   * 删除 Avatar(同时清理模型文件)。
   *
   * 流程:
   * 1. 读取 record 获取 modelUri
   * 2. 调用 Model3DAssetStore.deleteModelByUri 删除模型文件
   * 3. 调用 store.delete 清理元数据(若为激活,store 自动清空激活 ID)
   * 4. 若删除的是当前激活模型,同时调用 Character3DService.clearModel 同步全局状态
   *
   * @param avatarId 待删除的 Avatar ID
   */
  async deleteAvatar(avatarId: string): Promise<void> {
    const rec: AvatarRecord | null = await this.store.get(avatarId);
    if (rec === null) {
      Logger.warn(LOG_TAG, 'deleteAvatar: not found, id='
        + avatarId.substring(0, AVATAR_ID_LOG_LEN));
      return;
    }
    const isActive: boolean = (await this.store.getActiveId()) === avatarId;

    // 删除模型文件
    if (rec.modelUri.length > 0) {
      try {
        await this.assetStore.deleteModelByUri(rec.modelUri);
      } catch (e) {
        Logger.warn(LOG_TAG, 'deleteAvatar: file delete failed: ' + (e as Error)?.message);
      }
    }
    // 删除元数据
    await this.store.delete(avatarId);

    // 若是激活模型,同步清理 Character3DService 全局状态
    if (isActive) {
      try {
        await this.character3DService.clearModel();
      } catch (e) {
        Logger.warn(LOG_TAG, 'deleteAvatar: clearModel failed: ' + (e as Error)?.message);
      }
    }
    Logger.info(LOG_TAG, 'deleteAvatar ok: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', wasActive=' + isActive);
  }

  /**
   * 设置当前激活 Avatar。
   *
   * 流程:
   * 1. 读取 record,校验存在
   * 2. 校验模型文件存在
   * 3. 调用 Character3DService.setCurrentModelByUri 更新全局当前模型指针
   *    (不复制文件,不重新验证;模型文件已在首次导入时落盘)
   * 4. 更新 store.setActiveId(avatarId)
   *
   * @param avatarId 待激活的 Avatar ID
   */
  async setActiveAvatar(avatarId: string): Promise<void> {
    const rec: AvatarRecord | null = await this.store.get(avatarId);
    if (rec === null) {
      throw new Error('Avatar not found: ' + avatarId);
    }
    Logger.info(LOG_TAG, 'setActiveAvatar: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', name=' + rec.displayName);

    // 校验模型文件存在(防御性检查)
    if (!this.assetStore.exists(rec.modelUri)) {
      throw new Error('模型文件不存在: ' + rec.displayName);
    }

    // T-4.2 阶段 2: 读取切换前的 avatarId(用于事件 payload)
    const previousAvatarId: string = await this.store.getActiveId();
    // 同一 avatarId 且文件未变时不重复 dispatch(避免无意义刷新)
    // 但仍执行 setCurrentModelByUri + setActiveId 以保证状态一致

    // 仅更新 Character3DService 的当前模型指针,不复制文件
    await this.character3DService.setCurrentModelByUri(rec.modelUri, rec.displayName);
    await this.store.setActiveId(avatarId);

    // T-4.2 阶段 2: 发布 AvatarChangedEvent
    // 即使 previousAvatarId === avatarId,也通过 revision 递增通知订阅者
    // (用于"同一 Avatar 重新激活"场景,如文件被外部更新后强制刷新)
    this.dispatcher.dispatch(
      previousAvatarId, avatarId, rec.modelUri, rec.displayName, AvatarChangeSource.User
    );
    Logger.info(LOG_TAG, 'setActiveAvatar ok: id=' + avatarId.substring(0, AVATAR_ID_LOG_LEN)
      + ', prev=' + previousAvatarId.substring(0, AVATAR_ID_LOG_LEN));
  }

  /**
   * 读取当前激活 avatarId(空字符串表示无激活)。
   */
  async getActiveAvatarId(): Promise<string> {
    return this.store.getActiveId();
  }

  /**
   * 读取当前激活 AvatarRecord。
   */
  async getActiveAvatar(): Promise<AvatarRecord | null> {
    const id: string = await this.store.getActiveId();
    if (id.length === 0) {
      return null;
    }
    return this.store.get(id);
  }

  /**
   * 读取模型文件大小(字节)。
   * 失败时返回 0。
   */
  private async getFileSize(modelUri: string): Promise<number> {
    if (modelUri.length === 0 || !this.assetStore.exists(modelUri)) {
      return 0;
    }
    try {
      let path: string = modelUri;
      if (path.startsWith('file://')) {
        path = path.substring('file://'.length);
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        return stat.size;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'getFileSize failed: ' + (e as Error)?.message);
      return 0;
    }
  }

  /**
   * T-4.2 阶段 4: 修复模型库(旧数据清理 + 失效记录修复)。
   *
   * 清理顺序:
   * 1. 读取 Avatar Library 索引
   * 2. 构建所有被引用文件集合
   * 3. 检查旧单模型 preference(Character3DService.getConfig)
   * 4. 若旧模型不在模型库中且文件存在,先迁移
   * 5. 确认迁移成功后,删除旧 preference(调用 Character3DService.clearModel)
   * 6. 检查所有记录的模型文件是否存在,删除失效记录
   *
   * 不得删除:
   * - vrm_samples rawfile(不在沙箱,不受影响)
   * - 当前模型库正在引用的模型
   * - 测试框架仍明确依赖的 fixture
   */
  async repairLibrary(): Promise<AvatarLibraryRepairReport> {
    const report: AvatarLibraryRepairReport = {
      referencedFiles: 0,
      orphanFiles: [],
      missingFiles: [],
      staleRecords: [],
      legacyPreferenceFound: false,
      migratedLegacyAvatarId: '',
      deletedOrphanCount: 0,
      warnings: []
    };

    // 1. 读取所有记录
    const records: AvatarRecord[] = await this.store.listAll();
    report.referencedFiles = records.length;
    Logger.info(LOG_TAG, 'repairLibrary: start, records=' + records.length);

    // 2. 检查旧单模型 preference
    let legacyConfig: Character3DModelConfig = { modelUri: '', displayName: '', fileExists: false };
    try {
      legacyConfig = await this.character3DService.getConfig();
    } catch (e) {
      report.warnings.push('读取旧模型配置失败: ' + (e as Error)?.message);
    }

    if (legacyConfig.modelUri.length > 0) {
      report.legacyPreferenceFound = true;
      Logger.info(LOG_TAG, 'repairLibrary: legacy pref found, uri valid=' + legacyConfig.fileExists);

      if (legacyConfig.fileExists) {
        // 检查是否已在库中(按 modelUri 匹配)
        let alreadyInLibrary: boolean = false;
        for (let i: number = 0; i < records.length; i++) {
          if (records[i].modelUri === legacyConfig.modelUri) {
            alreadyInLibrary = true;
            break;
          }
        }

        if (!alreadyInLibrary) {
          // 迁移:创建 AvatarRecord 加入库
          const avatarId: string = generateUuid();
          const migratedRecord: AvatarRecord = {
            avatarId: avatarId,
            displayName: legacyConfig.displayName.length > 0
              ? legacyConfig.displayName : '迁移模型',
            modelUri: legacyConfig.modelUri,
            fileSize: 0,
            importedAt: Date.now(),
            isVrm: false,
            vrmVersion: 'NonVrm',
            declaredHumanBoneCount: 0,
            validHumanBoneCount: 0,
            sourceSha256: ''
          };
          try {
            await this.store.save(migratedRecord);
            report.migratedLegacyAvatarId = avatarId;
            report.referencedFiles = report.referencedFiles + 1;
            Logger.info(LOG_TAG, 'repairLibrary: migrated legacy model, id='
              + avatarId.substring(0, AVATAR_ID_LOG_LEN));
          } catch (e) {
            report.warnings.push('迁移旧模型失败: ' + (e as Error)?.message);
          }
        } else {
          Logger.info(LOG_TAG, 'repairLibrary: legacy model already in library, skip migration');
        }

        // 迁移成功或已在库中,清理旧 preference
        try {
          await this.character3DService.clearModel();
          Logger.info(LOG_TAG, 'repairLibrary: legacy preference cleared');
        } catch (e) {
          report.warnings.push('清理旧 preference 失败: ' + (e as Error)?.message);
        }
      } else {
        // 旧 URI 文件已丢失,直接清理 preference
        try {
          await this.character3DService.clearModel();
          Logger.info(LOG_TAG, 'repairLibrary: legacy file missing, preference cleared');
        } catch (e) {
          report.warnings.push('清理失效旧 preference 失败: ' + (e as Error)?.message);
        }
      }
    }

    // 3. 重新读取记录(可能新增了迁移记录)
    const updatedRecords: AvatarRecord[] = await this.store.listAll();

    // 4. 检查失效记录(文件缺失)
    for (let i: number = 0; i < updatedRecords.length; i++) {
      const r: AvatarRecord = updatedRecords[i];
      if (r.modelUri.length === 0) {
        continue;
      }
      if (!this.assetStore.exists(r.modelUri)) {
        report.missingFiles.push(r.avatarId);
        Logger.info(LOG_TAG, 'repairLibrary: stale record, id='
          + r.avatarId.substring(0, AVATAR_ID_LOG_LEN) + ', file missing');
        // 删除失效记录(不删文件,因为文件已不存在)
        try {
          await this.store.delete(r.avatarId);
          report.staleRecords.push(r.avatarId);
        } catch (e) {
          report.warnings.push('删除失效记录失败 ' + r.avatarId.substring(0, AVATAR_ID_LOG_LEN)
            + ': ' + (e as Error)?.message);
        }
      }
    }

    Logger.info(LOG_TAG, 'repairLibrary: done, referenced=' + report.referencedFiles
      + ', missing=' + report.missingFiles.length
      + ', stale=' + report.staleRecords.length
      + ', legacy=' + report.legacyPreferenceFound
      + ', migrated=' + report.migratedLegacyAvatarId.length);
    return report;
  }

  /**
   * T-4.2E-Closeout: 修复 sourceSha256 为空的 AvatarRecord。
   *
   * 历史问题:
   * - importFromRawfileByName 曾硬编码返回 sourceSha256=''
   * - 旧单模型迁移(repairLibrary)创建的记录 sourceSha256=''
   * - 导致 VRM asset cache / bone mapping cache / capability report 无法按 SHA 隔离
   * - duplicate detection 对空 SHA 记录失效(findDuplicateBySha256 在 sha 为空时返回 null)
   *
   * 修复流程:
   * 1. listAll 获取全部记录
   * 2. 过滤 sourceSha256 为空的记录
   * 3. 对每条记录:
   *    a. 校验模型文件存在(assetStore.exists)
   *    b. 读取模型二进制
   *    c. 重新计算 SHA-256
   *    d. 更新 AvatarRecord 并保存
   *    e. 不修改 displayName/tags/favorite/activeAvatarId
   * 4. 文件缺失的记录标记 stale(不伪造 SHA)
   *
   * 调用时机: AppServices 初始化完成后(repairLibrary 之后)。
   *
   * @returns 迁移报告
   */
  async repairEmptySha256(): Promise<ShaMigrationReport> {
    const report: ShaMigrationReport = {
      scannedCount: 0,
      emptyShaCount: 0,
      repairedCount: 0,
      missingFileCount: 0,
      failedCount: 0,
      details: []
    };

    const records: AvatarRecord[] = await this.store.listAll();
    report.scannedCount = records.length;
    Logger.info(LOG_TAG, 'repairEmptySha256: start, scanned=' + records.length);

    for (let i: number = 0; i < records.length; i++) {
      const rec: AvatarRecord = records[i];
      if (rec.sourceSha256.length > 0) {
        // SHA 已存在,跳过
        continue;
      }
      report.emptyShaCount++;

      // 校验模型文件存在
      if (!this.assetStore.exists(rec.modelUri)) {
        report.missingFileCount++;
        report.details.push({
          avatarId: rec.avatarId,
          displayName: rec.displayName,
          success: false,
          reason: '模型文件缺失,无法计算 SHA'
        });
        Logger.warn(LOG_TAG, 'repairEmptySha256: file missing, id='
          + rec.avatarId.substring(0, AVATAR_ID_LOG_LEN));
        continue;
      }

      // 读取模型二进制并计算 SHA
      try {
        const buffer: ArrayBuffer = this.readModelFileToBuffer(rec.modelUri);
        const sha: string = computeSha256Base64(buffer);
        if (sha.length === 0) {
          report.failedCount++;
          report.details.push({
            avatarId: rec.avatarId,
            displayName: rec.displayName,
            success: false,
            reason: 'SHA 计算返回空'
          });
          Logger.warn(LOG_TAG, 'repairEmptySha256: sha empty, id='
            + rec.avatarId.substring(0, AVATAR_ID_LOG_LEN));
          continue;
        }

        // 更新 record 并保存(不修改其他字段)
        rec.sourceSha256 = sha;
        await this.store.save(rec);
        report.repairedCount++;
        report.details.push({
          avatarId: rec.avatarId,
          displayName: rec.displayName,
          success: true,
          reason: ''
        });
        Logger.info(LOG_TAG, 'repairEmptySha256: repaired, id='
          + rec.avatarId.substring(0, AVATAR_ID_LOG_LEN)
          + ', name=' + rec.displayName
          + ', sha=' + sha.substring(0, 8));
      } catch (e) {
        report.failedCount++;
        report.details.push({
          avatarId: rec.avatarId,
          displayName: rec.displayName,
          success: false,
          reason: (e as Error)?.message ?? 'unknown'
        });
        Logger.warn(LOG_TAG, 'repairEmptySha256: failed, id='
          + rec.avatarId.substring(0, AVATAR_ID_LOG_LEN)
          + ', err=' + (e as Error)?.message);
      }
    }

    Logger.info(LOG_TAG, 'repairEmptySha256: done, scanned=' + report.scannedCount
      + ', empty=' + report.emptyShaCount
      + ', repaired=' + report.repairedCount
      + ', missing=' + report.missingFileCount
      + ', failed=' + report.failedCount);
    return report;
  }

  /**
   * T-4.2E-Closeout: 读取模型文件为 ArrayBuffer(用于 SHA 计算)。
   *
   * @param modelUri file:// URI 或绝对路径
   * @returns 文件二进制内容
   */
  private readModelFileToBuffer(modelUri: string): ArrayBuffer {
    let path: string = modelUri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buffer);
      return buffer;
    } finally {
      fileIo.closeSync(file);
    }
  }
}

/**
 * T-4.2E-Closeout: SHA 迁移报告。
 */
export interface ShaMigrationReport {
  /** 扫描的记录总数 */
  scannedCount: number;
  /** SHA 为空的记录数 */
  emptyShaCount: number;
  /** 成功修复的记录数 */
  repairedCount: number;
  /** 模型文件缺失的记录数 */
  missingFileCount: number;
  /** 修复失败的记录数(非文件缺失) */
  failedCount: number;
  /** 每条记录的修复详情 */
  details: ShaMigrationDetail[];
}

/**
 * T-4.2E-Closeout: 单条记录的 SHA 迁移详情。
 */
export interface ShaMigrationDetail {
  /** avatarId */
  avatarId: string;
  /** 显示名 */
  displayName: string;
  /** 是否成功 */
  success: boolean;
  /** 失败原因(成功时为空) */
  reason: string;
}
