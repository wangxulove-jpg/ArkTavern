/**
 * ArkWebAvatarAssetLibrary — 持久化资产清单 (Phase 3B)
 *
 * 职责 (AGENTS.md Phase 3B §十三):
 * - 创建资产目录 <filesDir>/avatar-assets/
 * - 读取 library.json
 * - 验证 schema
 * - 查找 active model
 * - 原子写入 library.json (library.json.part → rename)
 * - 更新 activeModelId
 * - 添加或替换模型记录
 * - 处理损坏清单 (重命名为 library.json.corrupt.<timestamp>)
 * - dispose
 *
 * 单一所有权:
 * - 禁止 VrmViewerPage / ArkWebFileImportController / ArkWebModelResourceProvider
 *   各自直接修改 JSON 文件
 * - 所有清单操作必须通过本类
 *
 * 安全约束:
 * - 禁止保存绝对路径 / 原始 URI / cachePath / ArkWeb URL / 文件描述符
 * - relativePath 必须以 "models/" 开头且不含 ..
 * - 内存状态同步: 写入成功后更新 inMemoryData
 *
 * 原子写入流程 (AGENTS.md Phase 3B §十四):
 * 1. 序列化到内存
 * 2. 验证序列化结果非空
 * 3. 写入 library.json.part
 * 4. flush / close
 * 5. 验证临时文件大小 > 0
 * 6. rename library.json.part → library.json
 * 7. 更新内存状态
 *
 * 失败处理:
 * - 关闭文件描述符
 * - 删除 library.json.part
 * - 保留旧 library.json
 * - 不更新 activeModelId
 *
 * 损坏清单处理 (AGENTS.md Phase 3B §十五):
 * - 不崩溃
 * - 不自动删除模型文件
 * - 将损坏清单重命名为 library.json.corrupt.<timestamp>
 * - 创建新的空清单
 * - 状态进入 EMPTY
 * - 记录 warning
 *
 * Reference:
 * - SDK: @kit.CoreFileKit fileIo (read / write / rename / stat / mkdir)
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import {
  ArkWebAvatarAssetLibraryData,
  ArkWebAvatarModelAsset,
  ArkWebAvatarAnimationAsset,
  ArkWebAvatarPoseAsset,
  AssetLibraryErrorCode
} from './ArkWebAvatarAssetTypes';
import { ASSET_LIBRARY_SCHEMA_VERSION } from './ArkWebAvatarAssetTypes';

/**
 * 资产目录名称 (相对 filesDir)。
 */
export const AVATAR_ASSETS_DIR_NAME: string = 'avatar-assets';

/**
 * 模型子目录名称 (相对 avatar-assets/)。
 */
export const MODELS_SUBDIR_NAME: string = 'models';

/**
 * 动画子目录名称 (相对 avatar-assets/)。Phase 3C-1。
 */
export const ANIMATIONS_SUBDIR_NAME: string = 'animations';

/**
 * 姿势子目录名称 (相对 avatar-assets/)。Phase 3D-1。
 */
export const POSES_SUBDIR_NAME: string = 'poses';

/**
 * library.json 文件名。
 */
export const LIBRARY_FILE_NAME: string = 'library.json';

/**
 * library.json 临时文件名。
 */
export const LIBRARY_PART_FILE_NAME: string = 'library.json.part';

/**
 * 持久化资产清单 (单一所有者)。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 UIAbilityContext
 * 2. 调用 ensureInitialized() 创建目录与初始清单
 * 3. 调用 readLibrary() 读取并校验清单
 * 4. 调用 upsertModel() / setActiveModel() 修改清单
 * 5. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebAvatarAssetLibrary {
  /** 应用上下文 (用于 filesDir)。 */
  private readonly context: common.UIAbilityContext;
  /** 资产根目录绝对路径 (<filesDir>/avatar-assets)。 */
  private readonly assetsRootDir: string;
  /** 模型目录绝对路径 (<filesDir>/avatar-assets/models)。 */
  private readonly modelsDir: string;
  /** 动画目录绝对路径 (<filesDir>/avatar-assets/animations)。Phase 3C-1。 */
  private readonly animationsDir: string;
  /** 姿势目录绝对路径 (<filesDir>/avatar-assets/poses)。Phase 3D-1。 */
  private readonly posesDir: string;
  /** library.json 绝对路径。 */
  private readonly libraryFilePath: string;
  /** library.json.part 绝对路径。 */
  private readonly libraryPartFilePath: string;
  /** 内存中的清单数据 (写入成功后同步更新)。 */
  private inMemoryData: ArkWebAvatarAssetLibraryData | null = null;
  /** 是否已初始化 (ensureInitialized 成功)。 */
  private initialized: boolean = false;
  /** 进行中的初始化 promise (防止并发初始化导致 .part 竞态)。 */
  private initPromise: Promise<boolean> | null = null;
  /** 是否已销毁。 */
  private disposed: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    const rawRoot: string = `${context.filesDir}/${AVATAR_ASSETS_DIR_NAME}`;
    this.assetsRootDir = this.normalizePath(rawRoot);
    this.modelsDir = `${this.assetsRootDir}/${MODELS_SUBDIR_NAME}`;
    this.animationsDir = `${this.assetsRootDir}/${ANIMATIONS_SUBDIR_NAME}`;
    this.posesDir = `${this.assetsRootDir}/${POSES_SUBDIR_NAME}`;
    this.libraryFilePath = `${this.assetsRootDir}/${LIBRARY_FILE_NAME}`;
    this.libraryPartFilePath = `${this.assetsRootDir}/${LIBRARY_PART_FILE_NAME}`;
  }

  /** 获取资产根目录绝对路径 (<filesDir>/avatar-assets)。 */
  getAssetsRootDir(): string {
    return this.assetsRootDir;
  }

  /** 获取模型目录绝对路径 (<filesDir>/avatar-assets/models)。 */
  getModelsDir(): string {
    return this.modelsDir;
  }

  /** 获取动画目录绝对路径 (<filesDir>/avatar-assets/animations)。Phase 3C-1。 */
  getAnimationsDir(): string {
    return this.animationsDir;
  }

  /** 获取姿势目录绝对路径 (<filesDir>/avatar-assets/poses)。Phase 3D-1。 */
  getPosesDir(): string {
    return this.posesDir;
  }

  /** 获取 library.json 绝对路径。 */
  getLibraryFilePath(): string {
    return this.libraryFilePath;
  }

  /**
   * 初始化资产目录与初始清单。
   *
   * 流程:
   * 1. 创建 <filesDir>/avatar-assets/ (递归,允许已存在)
   * 2. 创建 <filesDir>/avatar-assets/models/ (递归,允许已存在)
   * 3. 若 library.json 不存在,创建空清单
   * 4. 若 library.json 存在但不合法,重命名为 .corrupt.<ts> 并创建空清单
   * 5. initialized = true
   *
   * 并发保护: 多次调用复用同一个 initPromise, 防止 aboutToAppear 的异步
   * ensureInitialized 与 loadAnimationAssetsFromLibrary / importModel 触发的
   * ensureInitialized 并发执行导致 library.json.part 互删竞态。
   *
   * @returns 成功返回 true;失败返回 false (查看 console)
   */
  async ensureInitialized(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.initialized) {
      return true;
    }
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    const promise: Promise<boolean> = this.doEnsureInit();
    this.initPromise = promise;
    try {
      const ok: boolean = await promise;
      return ok;
    } finally {
      // 无论成功失败都清空: 成功后 initialized=true 会短路; 失败后允许重试
      if (this.initPromise === promise) {
        this.initPromise = null;
      }
    }
  }

  /**
   * ensureInitialized 的实际实现 (无并发保护, 由 ensureInitialized 包装调用)。
   */
  private async doEnsureInit(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (this.initialized) {
      return true;
    }

    // 1. 创建资产根目录 (已存在则跳过, 避免 mkdir 抛 "File exists")
    if (!(await this.dirExists(this.assetsRootDir))) {
      try {
        await fileIo.mkdir(this.assetsRootDir, true);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        console.warn(`[ArkWebAvatarAssetLibrary] mkdir assetsRoot failed: ${msg}`);
        return false;
      }
    }

    // 2. 创建模型子目录
    if (!(await this.dirExists(this.modelsDir))) {
      try {
        await fileIo.mkdir(this.modelsDir, true);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        console.warn(`[ArkWebAvatarAssetLibrary] mkdir modelsDir failed: ${msg}`);
        return false;
      }
    }

    // 2b. 创建动画子目录 (Phase 3C-1)
    if (!(await this.dirExists(this.animationsDir))) {
      try {
        await fileIo.mkdir(this.animationsDir, true);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        console.warn(`[ArkWebAvatarAssetLibrary] mkdir animationsDir failed: ${msg}`);
        return false;
      }
    }

    // 2c. 创建姿势子目录 (Phase 3D-1)
    if (!(await this.dirExists(this.posesDir))) {
      try {
        await fileIo.mkdir(this.posesDir, true);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        console.warn(`[ArkWebAvatarAssetLibrary] mkdir posesDir failed: ${msg}`);
        return false;
      }
    }

    // 3. 检查 library.json 是否存在
    let libraryExists: boolean = false;
    try {
      libraryExists = await fileIo.access(this.libraryFilePath);
    } catch (_e) {
      // access 抛异常视为不存在
    }

    if (!libraryExists) {
      // 创建空清单
      const emptyData: ArkWebAvatarAssetLibraryData = this.createEmptyLibraryData();
      const writeOk: boolean = await this.atomicWriteLibrary(emptyData);
      if (!writeOk) {
        return false;
      }
      this.inMemoryData = emptyData;
    } else {
      // 读取并校验,失败则重命名为 .corrupt 并重建空清单
      const readResult: LibraryReadResult = await this.readAndValidateLibrary();
      if (readResult.success && readResult.data !== null) {
        this.inMemoryData = readResult.data;
      } else {
        console.warn(`[ArkWebAvatarAssetLibrary] library corrupt: ${readResult.errorCode} ${readResult.errorMessage}`);
        // 重命名损坏清单
        const corruptPath: string = `${this.assetsRootDir}/library.json.corrupt.${Date.now()}`;
        let renameOk: boolean = false;
        try {
          await fileIo.rename(this.libraryFilePath, corruptPath);
          renameOk = true;
        } catch (e) {
          const msg: string = e instanceof Error ? e.message : String(e);
          console.warn(`[ArkWebAvatarAssetLibrary] corrupt rename failed: ${msg}`);
        }
        if (!renameOk) {
          // 重命名失败:不创建新清单,返回失败
          console.error('[ArkWebAvatarAssetLibrary] corrupt rename failed, cannot recover');
          return false;
        }
        // 创建空清单
        const emptyData: ArkWebAvatarAssetLibraryData = this.createEmptyLibraryData();
        const writeOk: boolean = await this.atomicWriteLibrary(emptyData);
        if (!writeOk) {
          return false;
        }
        this.inMemoryData = emptyData;
        console.info('[ArkWebAvatarAssetLibrary] created empty library after corrupt rename');
      }
    }

    this.initialized = true;
    return true;
  }

  /**
   * 读取并返回内存中的清单数据。
   * 若内存为空,先从磁盘读取。
   */
  async readLibrary(): Promise<ArkWebAvatarAssetLibraryData | null> {
    if (this.disposed) {
      return null;
    }
    if (!this.initialized) {
      const ok: boolean = await this.ensureInitialized();
      if (!ok) {
        return null;
      }
    }
    if (this.inMemoryData !== null) {
      return this.inMemoryData;
    }
    const result: LibraryReadResult = await this.readAndValidateLibrary();
    if (result.success && result.data !== null) {
      this.inMemoryData = result.data;
      return result.data;
    }
    return null;
  }

  /**
   * 查找 active model 资产记录。
   * 若 activeModelId 为空或无对应记录,返回 null。
   */
  async findActiveModel(): Promise<ArkWebAvatarModelAsset | null> {
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return null;
    }
    if (data.activeModelId.length === 0) {
      return null;
    }
    for (let i = 0; i < data.models.length; i++) {
      const m: ArkWebAvatarModelAsset = data.models[i];
      if (m.modelId === data.activeModelId) {
        return m;
      }
    }
    return null;
  }

  /**
   * 添加或替换模型记录,并设置为 active model。
   *
   * 流程:
   * 1. 验证 relativePath 安全 (以 "models/" 开头,不含 ..)
   * 2. 读取当前清单 (内存)
   * 3. 若 modelId 已存在,替换记录 (updatedAt 更新)
   * 4. 若 modelId 不存在,追加到 models
   * 5. 设置 activeModelId = modelId
   * 6. 原子写入 library.json
   *
   * @returns 成功返回 true;失败返回 false
   */
  async upsertModelAndSetActive(asset: ArkWebAvatarModelAsset): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (!this.initialized) {
      const ok: boolean = await this.ensureInitialized();
      if (!ok) {
        return false;
      }
    }
    // 安全校验 relativePath
    if (!this.isRelativePathSafe(asset.relativePath)) {
      console.warn(`[ArkWebAvatarAssetLibrary] unsafe relativePath: ${asset.relativePath}`);
      return false;
    }

    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return false;
    }

    // 查找是否已存在
    let found: boolean = false;
    const newModels: ArkWebAvatarModelAsset[] = [];
    for (let i = 0; i < data.models.length; i++) {
      const m: ArkWebAvatarModelAsset = data.models[i];
      if (m.modelId === asset.modelId) {
        newModels.push(asset);
        found = true;
      } else {
        newModels.push(m);
      }
    }
    if (!found) {
      newModels.push(asset);
    }

    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: asset.modelId,
      models: newModels,
      animations: data.animations,
      defaultIdleActionId: data.defaultIdleActionId,
      poses: data.poses
    };

    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return false;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] upsertModel ok modelId=${asset.modelId} active=true`);
    return true;
  }

  /**
   * 仅更新 activeModelId (不修改 models 数组)。
   */
  async setActiveModel(modelId: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (!this.initialized) {
      const ok: boolean = await this.ensureInitialized();
      if (!ok) {
        return false;
      }
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return false;
    }
    // modelId 必须存在于 models 中 (或为空字符串表示清除)
    if (modelId.length > 0) {
      let found: boolean = false;
      for (let i = 0; i < data.models.length; i++) {
        if (data.models[i].modelId === modelId) {
          found = true;
          break;
        }
      }
      if (!found) {
        console.warn(`[ArkWebAvatarAssetLibrary] setActiveModel: modelId not found: ${modelId}`);
        return false;
      }
    }

    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: modelId,
      models: data.models,
      animations: data.animations,
      defaultIdleActionId: data.defaultIdleActionId,
      poses: data.poses
    };
    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return false;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] setActiveModel ok modelId=${modelId}`);
    return true;
  }

  // ===== Phase 3C-1: 动画资产操作 =====

  /**
   * 读取 library.animations 数组 (Phase 3C-1)。
   *
   * @returns 动画资产数组; 失败返回空数组
   */
  async readAnimations(): Promise<ArkWebAvatarAnimationAsset[]> {
    if (this.disposed) {
      return [];
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return [];
    }
    return data.animations;
  }

  /**
   * 按 actionId 查找动画资产 (Phase 3C-1)。
   */
  async findAnimation(actionId: string): Promise<ArkWebAvatarAnimationAsset | null> {
    if (actionId.length === 0) {
      return null;
    }
    const animations: ArkWebAvatarAnimationAsset[] = await this.readAnimations();
    for (let i = 0; i < animations.length; i++) {
      if (animations[i].actionId === actionId) {
        return animations[i];
      }
    }
    return null;
  }

  /**
   * 追加动画资产记录 (Phase 3C-1)。
   *
   * - 不覆盖已有记录 (若 actionId 已存在, 返回 false)
   * - 安全校验 relativePath (以 "animations/" 开头, 不含 ..)
   * - 原子写入 library.json
   * - 保留 models / poses / activeModelId 不变
   *
   * @returns 成功返回 true; 失败返回 false
   */
  async appendAnimation(asset: ArkWebAvatarAnimationAsset): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (!this.initialized) {
      const ok: boolean = await this.ensureInitialized();
      if (!ok) {
        return false;
      }
    }
    // 安全校验 relativePath
    if (!this.isAnimationRelativePathSafe(asset.relativePath)) {
      console.warn(`[ArkWebAvatarAssetLibrary] unsafe animation relativePath: ${asset.relativePath}`);
      return false;
    }

    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return false;
    }

    // 检查重复 (actionId 不允许重复)
    for (let i = 0; i < data.animations.length; i++) {
      if (data.animations[i].actionId === asset.actionId) {
        console.warn(`[ArkWebAvatarAssetLibrary] appendAnimation: actionId already exists: ${asset.actionId}`);
        return false;
      }
    }

    const newAnimations: ArkWebAvatarAnimationAsset[] = data.animations.slice();
    newAnimations.push(asset);

    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: data.activeModelId,
      models: data.models,
      animations: newAnimations,
      defaultIdleActionId: data.defaultIdleActionId,
      poses: data.poses
    };
    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return false;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] appendAnimation ok actionId=${asset.actionId} count=${newAnimations.length}`);
    return true;
  }

  // ===== Phase 3C-2: 动画管理操作 (重命名 / 删除 / 默认待机) =====

  /**
   * 重命名动画资产 (Phase 3C-2)。
   *
   * 只修改 displayName 和 updatedAt, 保持 actionId / resourceId / relativePath / 文件名不变。
   *
   * 名称要求:
   * - trim 后非空
   * - 长度不超过 64
   *
   * @returns 成功返回新的 asset; 失败返回 null (查看 console)
   */
  async renameAnimation(actionId: string, newDisplayName: string): Promise<ArkWebAvatarAnimationAsset | null> {
    if (this.disposed) {
      return null;
    }
    const trimmed: string = newDisplayName.trim();
    if (trimmed.length === 0 || trimmed.length > 64) {
      console.warn(`[ArkWebAvatarAssetLibrary] renameAnimation invalid name length=${trimmed.length}`);
      return null;
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return null;
    }
    let foundIdx: number = -1;
    for (let i = 0; i < data.animations.length; i++) {
      if (data.animations[i].actionId === actionId) {
        foundIdx = i;
        break;
      }
    }
    if (foundIdx < 0) {
      console.warn(`[ArkWebAvatarAssetLibrary] renameAnimation: actionId not found: ${actionId}`);
      return null;
    }
    const oldAsset: ArkWebAvatarAnimationAsset = data.animations[foundIdx];
    const updatedAsset: ArkWebAvatarAnimationAsset = {
      actionId: oldAsset.actionId,
      resourceId: oldAsset.resourceId,
      displayName: trimmed,
      relativePath: oldAsset.relativePath,
      mimeType: oldAsset.mimeType,
      byteLength: oldAsset.byteLength,
      createdAt: oldAsset.createdAt,
      updatedAt: Date.now()
    };
    const newAnimations: ArkWebAvatarAnimationAsset[] = data.animations.slice();
    newAnimations[foundIdx] = updatedAsset;
    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: data.activeModelId,
      models: data.models,
      animations: newAnimations,
      defaultIdleActionId: data.defaultIdleActionId,
      poses: data.poses
    };
    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return null;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] renameAnimation ok actionId=${actionId}`);
    return updatedAsset;
  }

  /**
   * 从清单删除动画资产记录 (Phase 3C-2)。
   *
   * 仅修改清单, 不操作文件 (文件由 PersistentAnimationStore 负责 rename .deleting / 清理)。
   *
   * 副作用:
   * - 若被删除的是 defaultIdleActionId, 清空 defaultIdleActionId
   *
   * @returns 成功返回 true; 失败返回 false
   */
  async removeAnimationRecord(actionId: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return false;
    }
    let foundIdx: number = -1;
    for (let i = 0; i < data.animations.length; i++) {
      if (data.animations[i].actionId === actionId) {
        foundIdx = i;
        break;
      }
    }
    if (foundIdx < 0) {
      console.warn(`[ArkWebAvatarAssetLibrary] removeAnimationRecord: actionId not found: ${actionId}`);
      return false;
    }
    const newAnimations: ArkWebAvatarAnimationAsset[] = data.animations.slice();
    newAnimations.splice(foundIdx, 1);
    // 若删除的是默认待机, 清空 defaultIdleActionId
    const newDefaultIdle: string = data.defaultIdleActionId === actionId
      ? '' : data.defaultIdleActionId;
    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: data.activeModelId,
      models: data.models,
      animations: newAnimations,
      defaultIdleActionId: newDefaultIdle,
      poses: data.poses
    };
    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return false;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] removeAnimationRecord ok actionId=${actionId}`);
    return true;
  }

  /**
   * 设置或取消默认待机动作 (Phase 3C-2)。
   *
   * - actionId 为空字符串: 取消默认待机
   * - actionId 非空: 必须存在于 animations 中
   *
   * @returns 成功返回 true; 失败返回 false
   */
  async setDefaultIdleAction(actionId: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return false;
    }
    // 非空 actionId 必须存在于 animations 中
    if (actionId.length > 0) {
      let found: boolean = false;
      for (let i = 0; i < data.animations.length; i++) {
        if (data.animations[i].actionId === actionId) {
          found = true;
          break;
        }
      }
      if (!found) {
        console.warn(`[ArkWebAvatarAssetLibrary] setDefaultIdleAction: actionId not found: ${actionId}`);
        return false;
      }
    }
    // 相同值不重复写入
    if (data.defaultIdleActionId === actionId) {
      return true;
    }
    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: data.activeModelId,
      models: data.models,
      animations: data.animations,
      defaultIdleActionId: actionId,
      poses: data.poses
    };
    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return false;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] setDefaultIdleAction ok actionId=${actionId}`);
    return true;
  }

  /**
   * 获取当前默认待机 actionId (Phase 3C-2)。
   * 失败返回空字符串。
   */
  async getDefaultIdleActionId(): Promise<string> {
    if (this.disposed) {
      return '';
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return '';
    }
    return data.defaultIdleActionId;
  }

  // ===== Phase 3D-1: 姿势资产操作 =====

  /**
   * 读取 library.poses 数组 (Phase 3D-1)。
   *
   * @returns 姿势资产数组; 失败返回空数组
   */
  async readPoses(): Promise<ArkWebAvatarPoseAsset[]> {
    if (this.disposed) {
      return [];
    }
    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return [];
    }
    return data.poses;
  }

  /**
   * 按 poseId 查找姿势资产 (Phase 3D-1)。
   */
  async findPose(poseId: string): Promise<ArkWebAvatarPoseAsset | null> {
    if (poseId.length === 0) {
      return null;
    }
    const poses: ArkWebAvatarPoseAsset[] = await this.readPoses();
    for (let i = 0; i < poses.length; i++) {
      if (poses[i].poseId === poseId) {
        return poses[i];
      }
    }
    return null;
  }

  /**
   * 追加姿势资产记录 (Phase 3D-1)。
   *
   * - 不覆盖已有记录 (若 poseId 已存在, 返回 false)
   * - 安全校验 relativePath (以 "poses/" 开头, 不含 ..)
   * - 原子写入 library.json
   * - 保留 models / animations / activeModelId / defaultIdleActionId 不变
   *
   * @returns 成功返回 true; 失败返回 false
   */
  async appendPose(asset: ArkWebAvatarPoseAsset): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    if (!this.initialized) {
      const ok: boolean = await this.ensureInitialized();
      if (!ok) {
        return false;
      }
    }
    // 安全校验 relativePath
    if (!this.isPoseRelativePathSafe(asset.relativePath)) {
      console.warn(`[ArkWebAvatarAssetLibrary] unsafe pose relativePath: ${asset.relativePath}`);
      return false;
    }

    const data: ArkWebAvatarAssetLibraryData | null = await this.readLibrary();
    if (data === null) {
      return false;
    }

    // 检查重复 (poseId 不允许重复)
    for (let i = 0; i < data.poses.length; i++) {
      if (data.poses[i].poseId === asset.poseId) {
        console.warn(`[ArkWebAvatarAssetLibrary] appendPose: poseId already exists: ${asset.poseId}`);
        return false;
      }
    }

    const newPoses: ArkWebAvatarPoseAsset[] = data.poses.slice();
    newPoses.push(asset);

    const newData: ArkWebAvatarAssetLibraryData = {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: data.activeModelId,
      models: data.models,
      animations: data.animations,
      defaultIdleActionId: data.defaultIdleActionId,
      poses: newPoses
    };
    const writeOk: boolean = await this.atomicWriteLibrary(newData);
    if (!writeOk) {
      return false;
    }
    this.inMemoryData = newData;
    console.info(`[ArkWebAvatarAssetLibrary] appendPose ok poseId=${asset.poseId} count=${newPoses.length}`);
    return true;
  }

  /**
   * 销毁 AssetLibrary。
   * - 标记 disposed
   * - 不删除 library.json / 模型文件
   * - 清空内存状态
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.inMemoryData = null;
    this.initialized = false;
    this.initPromise = null;
  }

  /** 是否已销毁。 */
  isDisposed(): boolean {
    return this.disposed;
  }

  // ===== 内部方法 =====

  /**
   * 创建空清单数据。
   */
  private createEmptyLibraryData(): ArkWebAvatarAssetLibraryData {
    const emptyAnimations: ArkWebAvatarAnimationAsset[] = [];
    return {
      schemaVersion: ASSET_LIBRARY_SCHEMA_VERSION,
      activeModelId: '',
      models: [],
      animations: emptyAnimations,
      defaultIdleActionId: '',
      poses: []
    };
  }

  /**
   * 读取并校验 library.json。
   *
   * 返回:
   * - success=true, data=非空: 读取成功
   * - success=false, errorCode/errorMessage: 读取失败 (调用方决定如何处理)
   */
  private async readAndValidateLibrary(): Promise<LibraryReadResult> {
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(this.libraryFilePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        return this.readFail(
          AssetLibraryErrorCode.ASSET_LIBRARY_PARSE_FAILED,
          'library.json is empty'
        );
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const bytesRead: number = await fileIo.read(file.fd, buffer, { length: size });
      if (bytesRead !== size) {
        return this.readFail(
          AssetLibraryErrorCode.ASSET_LIBRARY_READ_FAILED,
          `read mismatch: expected ${size}, got ${bytesRead}`
        );
      }
      const text: string = this.decodeUtf8(buffer);
      let parsed: object;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        return this.readFail(
          AssetLibraryErrorCode.ASSET_LIBRARY_PARSE_FAILED,
          `JSON.parse failed: ${msg}`
        );
      }
      const data: ArkWebAvatarAssetLibraryData | null = this.coerceToLibraryData(parsed);
      if (data === null) {
        return this.readFail(
          AssetLibraryErrorCode.ASSET_LIBRARY_FIELD_INVALID,
          'schema/fields invalid'
        );
      }
      return { success: true, data: data, errorCode: '', errorMessage: '' };
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      return this.readFail(
        AssetLibraryErrorCode.ASSET_LIBRARY_READ_FAILED,
        `read failed: ${msg}`
      );
    } finally {
      if (file !== null) {
        try {
          await fileIo.close(file);
        } catch (_e) {
          // 忽略
        }
      }
    }
  }

  /**
   * 原子写入 library.json。
   *
   * 流程 (AGENTS.md Phase 3B §十四):
   * 1. 序列化到内存
   * 2. 验证序列化结果非空
   * 3. 写入 library.json.part
   * 4. flush / close
   * 5. 验证临时文件大小 > 0
   * 6. rename library.json.part → library.json
   *
   * 失败:
   * - 关闭文件描述符
   * - 删除 library.json.part
   * - 保留旧 library.json
   */
  private async atomicWriteLibrary(data: ArkWebAvatarAssetLibraryData): Promise<boolean> {
    // 1. 序列化
    let json: string;
    try {
      json = JSON.stringify(data);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[ArkWebAvatarAssetLibrary] serialize failed: ${msg}`);
      return false;
    }
    // 2. 验证非空
    if (json.length === 0) {
      console.warn('[ArkWebAvatarAssetLibrary] serialized json is empty');
      return false;
    }

    // 删除已存在的 .part (防止上次失败残留)
    try {
      await fileIo.unlink(this.libraryPartFilePath);
    } catch (_e) {
      // 忽略 (文件可能不存在)
    }

    // 3. 写入 .part
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(
        this.libraryPartFilePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
      );
      // 编码为 UTF-8 字节,确保字节数与返回值一致
      const bytes: Uint8Array = this.encodeUtf8(json);
      const written: number = await fileIo.write(file.fd, bytes.buffer, { length: bytes.byteLength });
      if (written !== bytes.byteLength) {
        console.warn(`[ArkWebAvatarAssetLibrary] write mismatch: expected ${bytes.byteLength}, got ${written}`);
        await this.closeFile(file);
        file = null;
        await this.safeUnlink(this.libraryPartFilePath);
        return false;
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[ArkWebAvatarAssetLibrary] write .part failed: ${msg}`);
      if (file !== null) {
        await this.closeFile(file);
        file = null;
      }
      await this.safeUnlink(this.libraryPartFilePath);
      return false;
    }

    // 4. 关闭文件描述符 (rename 前必须关闭)
    await this.closeFile(file);
    file = null;

    // 5. 验证 .part 大小 > 0
    try {
      const stat: fileIo.Stat = await fileIo.stat(this.libraryPartFilePath);
      if (stat.size <= 0) {
        console.warn(`[ArkWebAvatarAssetLibrary] .part size=${stat.size}`);
        await this.safeUnlink(this.libraryPartFilePath);
        return false;
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[ArkWebAvatarAssetLibrary] .part stat failed: ${msg}`);
      await this.safeUnlink(this.libraryPartFilePath);
      return false;
    }

    // 6. rename .part → library.json
    try {
      await fileIo.rename(this.libraryPartFilePath, this.libraryFilePath);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[ArkWebAvatarAssetLibrary] rename failed: ${msg}`);
      await this.safeUnlink(this.libraryPartFilePath);
      return false;
    }

    return true;
  }

  /**
   * 把 JSON.parse 返回的 object 强制为 ArkWebAvatarAssetLibraryData。
   * 字段缺失或类型不匹配返回 null。
   */
  private coerceToLibraryData(obj: object): ArkWebAvatarAssetLibraryData | null {
    const o: Record<string, Object> = obj as Record<string, Object>;
    // schemaVersion
    const schemaVersionObj: Object | undefined = o['schemaVersion'];
    if (typeof schemaVersionObj !== 'number' || !Number.isFinite(schemaVersionObj)) {
      return null;
    }
    const schemaVersion: number = schemaVersionObj as number;
    if (schemaVersion !== ASSET_LIBRARY_SCHEMA_VERSION) {
      console.warn(`[ArkWebAvatarAssetLibrary] schemaVersion ${schemaVersion} unsupported`);
      return null;
    }
    // activeModelId
    const activeModelIdObj: Object | undefined = o['activeModelId'];
    if (typeof activeModelIdObj !== 'string') {
      return null;
    }
    // models
    const modelsObj: Object | undefined = o['models'];
    if (!Array.isArray(modelsObj)) {
      return null;
    }
    const models: ArkWebAvatarModelAsset[] = [];
    for (let i = 0; i < modelsObj.length; i++) {
      const itemObj: Object = modelsObj[i];
      const m: ArkWebAvatarModelAsset | null = this.coerceToModelAsset(itemObj);
      if (m === null) {
        return null;
      }
      models.push(m);
    }
    // animations (Phase 3C-1 起支持多 VRMA 持久化)
    // 向后兼容: 缺失 animations 字段视为空数组 (Phase 3B 旧清单可能没有此字段)
    const animationsObj: Object | undefined = o['animations'];
    const animations: ArkWebAvatarAnimationAsset[] = [];
    if (animationsObj !== undefined) {
      if (!Array.isArray(animationsObj)) {
        return null;
      }
      for (let i = 0; i < animationsObj.length; i++) {
        const animObj: Object = animationsObj[i];
        const a: ArkWebAvatarAnimationAsset | null = this.coerceToAnimationAsset(animObj);
        if (a === null) {
          return null;
        }
        animations.push(a);
      }
    }
    // poses (Phase 3D-1 起支持 JSON 姿势持久化)
    // 向后兼容: 缺失 poses 字段视为空数组 (旧清单可能没有此字段)
    const posesObj: Object | undefined = o['poses'];
    const poses: ArkWebAvatarPoseAsset[] = [];
    if (posesObj !== undefined) {
      if (!Array.isArray(posesObj)) {
        return null;
      }
      for (let i = 0; i < posesObj.length; i++) {
        const poseObj: Object = posesObj[i];
        const p: ArkWebAvatarPoseAsset | null = this.coerceToPoseAsset(poseObj);
        if (p === null) {
          return null;
        }
        poses.push(p);
      }
    }
    // defaultIdleActionId (Phase 3C-2 起支持默认待机标记)
    // 向后兼容: 缺失字段视为空字符串 (无默认待机)
    const defaultIdleObj: Object | undefined = o['defaultIdleActionId'];
    let defaultIdleActionId: string = '';
    if (defaultIdleObj !== undefined) {
      if (typeof defaultIdleObj !== 'string') {
        return null;
      }
      defaultIdleActionId = defaultIdleObj;
    }

    return {
      schemaVersion: schemaVersion,
      activeModelId: activeModelIdObj as string,
      models: models,
      animations: animations,
      defaultIdleActionId: defaultIdleActionId,
      poses: poses
    };
  }

  /**
   * 把 object 强制为 ArkWebAvatarModelAsset。
   */
  private coerceToModelAsset(obj: Object): ArkWebAvatarModelAsset | null {
    const o: Record<string, Object> = obj as Record<string, Object>;
    const modelId: Object | undefined = o['modelId'];
    if (typeof modelId !== 'string' || modelId.length === 0) {
      return null;
    }
    const resourceId: Object | undefined = o['resourceId'];
    if (typeof resourceId !== 'string' || resourceId.length === 0) {
      return null;
    }
    const displayName: Object | undefined = o['displayName'];
    if (typeof displayName !== 'string') {
      return null;
    }
    const relativePath: Object | undefined = o['relativePath'];
    if (typeof relativePath !== 'string' || !this.isRelativePathSafe(relativePath as string)) {
      return null;
    }
    const mimeType: Object | undefined = o['mimeType'];
    if (typeof mimeType !== 'string') {
      return null;
    }
    const byteLengthObj: Object | undefined = o['byteLength'];
    if (typeof byteLengthObj !== 'number' || !Number.isFinite(byteLengthObj) || byteLengthObj <= 0) {
      return null;
    }
    const createdAtObj: Object | undefined = o['createdAt'];
    if (typeof createdAtObj !== 'number' || !Number.isFinite(createdAtObj)) {
      return null;
    }
    const updatedAtObj: Object | undefined = o['updatedAt'];
    if (typeof updatedAtObj !== 'number' || !Number.isFinite(updatedAtObj)) {
      return null;
    }
    return {
      modelId: modelId as string,
      resourceId: resourceId as string,
      displayName: displayName as string,
      relativePath: relativePath as string,
      mimeType: mimeType as string,
      byteLength: byteLengthObj as number,
      createdAt: createdAtObj as number,
      updatedAt: updatedAtObj as number
    };
  }

  /**
   * 把 object 强制为 ArkWebAvatarAnimationAsset (Phase 3C-1)。
   */
  private coerceToAnimationAsset(obj: Object): ArkWebAvatarAnimationAsset | null {
    const o: Record<string, Object> = obj as Record<string, Object>;
    const actionId: Object | undefined = o['actionId'];
    if (typeof actionId !== 'string' || actionId.length === 0) {
      return null;
    }
    const resourceId: Object | undefined = o['resourceId'];
    if (typeof resourceId !== 'string' || resourceId.length === 0) {
      return null;
    }
    const displayName: Object | undefined = o['displayName'];
    if (typeof displayName !== 'string') {
      return null;
    }
    const relativePath: Object | undefined = o['relativePath'];
    if (typeof relativePath !== 'string' || !this.isAnimationRelativePathSafe(relativePath as string)) {
      return null;
    }
    const mimeType: Object | undefined = o['mimeType'];
    if (typeof mimeType !== 'string') {
      return null;
    }
    const byteLengthObj: Object | undefined = o['byteLength'];
    if (typeof byteLengthObj !== 'number' || !Number.isFinite(byteLengthObj) || byteLengthObj <= 0) {
      return null;
    }
    const createdAtObj: Object | undefined = o['createdAt'];
    if (typeof createdAtObj !== 'number' || !Number.isFinite(createdAtObj)) {
      return null;
    }
    const updatedAtObj: Object | undefined = o['updatedAt'];
    if (typeof updatedAtObj !== 'number' || !Number.isFinite(updatedAtObj)) {
      return null;
    }
    return {
      actionId: actionId as string,
      resourceId: resourceId as string,
      displayName: displayName as string,
      relativePath: relativePath as string,
      mimeType: mimeType as string,
      byteLength: byteLengthObj as number,
      createdAt: createdAtObj as number,
      updatedAt: updatedAtObj as number
    };
  }

  /**
   * 校验 relativePath 是否安全。
   * - 必须以 "models/" 开头
   * - 不得包含 ".."
   * - 不得包含反斜杠
   * - 不得以 "/" 开头 (必须是相对路径)
   */
  private isRelativePathSafe(p: string): boolean {
    if (p.length === 0) {
      return false;
    }
    if (p.startsWith('/')) {
      return false;
    }
    if (!p.startsWith('models/')) {
      return false;
    }
    if (p.includes('..')) {
      return false;
    }
    if (p.includes('\\')) {
      return false;
    }
    return true;
  }

  /**
   * 校验动画 relativePath 是否安全 (Phase 3C-1)。
   * - 必须以 "animations/" 开头
   * - 不得包含 ".."
   * - 不得包含反斜杠
   * - 不得以 "/" 开头 (必须是相对路径)
   */
  private isAnimationRelativePathSafe(p: string): boolean {
    if (p.length === 0) {
      return false;
    }
    if (p.startsWith('/')) {
      return false;
    }
    if (!p.startsWith('animations/')) {
      return false;
    }
    if (p.includes('..')) {
      return false;
    }
    if (p.includes('\\')) {
      return false;
    }
    return true;
  }

  /**
   * 校验姿势 relativePath 是否安全 (Phase 3D-1)。
   * - 必须以 "poses/" 开头
   * - 不得包含 ".."
   * - 不得包含反斜杠
   * - 不得以 "/" 开头 (必须是相对路径)
   * - 必须以 .json 结尾
   */
  private isPoseRelativePathSafe(p: string): boolean {
    if (p.length === 0) {
      return false;
    }
    if (p.startsWith('/')) {
      return false;
    }
    if (!p.startsWith('poses/')) {
      return false;
    }
    if (p.includes('..')) {
      return false;
    }
    if (p.includes('\\')) {
      return false;
    }
    if (!p.endsWith('.json')) {
      return false;
    }
    return true;
  }

  /**
   * 把 object 强制为 ArkWebAvatarPoseAsset (Phase 3D-1)。
   */
  private coerceToPoseAsset(obj: Object): ArkWebAvatarPoseAsset | null {
    const o: Record<string, Object> = obj as Record<string, Object>;
    const poseId: Object | undefined = o['poseId'];
    if (typeof poseId !== 'string' || poseId.length === 0) {
      return null;
    }
    const displayName: Object | undefined = o['displayName'];
    if (typeof displayName !== 'string') {
      return null;
    }
    const relativePath: Object | undefined = o['relativePath'];
    if (typeof relativePath !== 'string' || !this.isPoseRelativePathSafe(relativePath as string)) {
      return null;
    }
    const byteLengthObj: Object | undefined = o['byteLength'];
    if (typeof byteLengthObj !== 'number' || !Number.isFinite(byteLengthObj) || byteLengthObj <= 0) {
      return null;
    }
    const format: Object | undefined = o['format'];
    if (typeof format !== 'string' || format.length === 0) {
      return null;
    }
    const createdAtObj: Object | undefined = o['createdAt'];
    if (typeof createdAtObj !== 'number' || !Number.isFinite(createdAtObj)) {
      return null;
    }
    const updatedAtObj: Object | undefined = o['updatedAt'];
    if (typeof updatedAtObj !== 'number' || !Number.isFinite(updatedAtObj)) {
      return null;
    }
    return {
      poseId: poseId as string,
      displayName: displayName as string,
      relativePath: relativePath as string,
      byteLength: byteLengthObj as number,
      format: format as string,
      createdAt: createdAtObj as number,
      updatedAt: updatedAtObj as number
    };
  }

  /**
   * 路径规范化 (去除末尾多余的 /)。
   */
  private normalizePath(p: string): string {
    if (p.length > 1 && p.charAt(p.length - 1) === '/') {
      return p.substring(0, p.length - 1);
    }
    return p;
  }

  /**
   * 判断目录是否存在 (fileIo.access 异常视为不存在)。
   * 用于 mkdir 前预检, 避免 "File exists" 错误。
   */
  private async dirExists(dirPath: string): Promise<boolean> {
    try {
      await fileIo.access(dirPath);
      return true;
    } catch (_e) {
      return false;
    }
  }

  /**
   * UTF-8 解码 ArrayBuffer 为 string。
   */
  private decodeUtf8(buffer: ArrayBuffer): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buffer));
  }

  /**
   * UTF-8 编码 string 为 Uint8Array。
   */
  private encodeUtf8(s: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(s);
  }

  /** 关闭文件描述符 (忽略错误)。 */
  private async closeFile(file: fileIo.File): Promise<void> {
    try {
      await fileIo.close(file);
    } catch (_e) {
      // 忽略
    }
  }

  /** 安全删除文件 (忽略错误)。 */
  private async safeUnlink(path: string): Promise<void> {
    try {
      await fileIo.unlink(path);
    } catch (_e) {
      // 忽略
    }
  }

  /** 构造读取失败结果。 */
  private readFail(code: string, message: string): LibraryReadResult {
    return { success: false, data: null, errorCode: code, errorMessage: message };
  }
}

/**
 * 读取结果 (内部使用)。
 */
interface LibraryReadResult {
  success: boolean;
  data: ArkWebAvatarAssetLibraryData | null;
  errorCode: string;
  errorMessage: string;
}
