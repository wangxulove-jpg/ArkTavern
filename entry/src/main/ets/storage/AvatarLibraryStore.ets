/**
 * AvatarLibraryStore Avatar 模型库持久化
 *
 * T-4.1 阶段 B: 多 Avatar 模型库
 *
 * 职责:
 * - 管理 AvatarRecord 元数据(Preferences 存储)
 * - 维护 avatarId 索引列表(便于 listAvatars)
 * - 维护"当前激活 avatarId"
 * - 不负责模型文件二进制存储(由 Model3DAssetStore 负责)
 * - 不依赖 ArkUI / 网络 / 数据库
 *
 * 存储约定:
 * - `avatar_lib_index`: JSON 数组字符串,元素为 avatarId(按导入时间升序)
 * - `avatar_lib_record_<avatarId>`: AvatarRecord JSON 字符串
 * - `avatar_lib_active_id`: 当前激活的 avatarId(空字符串表示无激活)
 *
 * 不变量:
 * - avatarId 是 UUID v4,导入时生成,稳定不变
 * - displayName 用户可改,但 avatarId 不变
 * - 索引列表中的 avatarId 必须有对应 record,删除时两边同步
 */

import { AppPreferences } from './AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'AvatarLibraryStore';

/** 索引列表 key(avatarId 数组,JSON 字符串) */
const KEY_INDEX: string = 'avatar_lib_index';
/** 当前激活 avatarId key */
const KEY_ACTIVE_ID: string = 'avatar_lib_active_id';
/** 单个 AvatarRecord key 前缀 */
const KEY_RECORD_PREFIX: string = 'avatar_lib_record_';

/**
 * AvatarRecord 单条 Avatar 模型记录。
 *
 * 仅保存 UI 显示和 Agent 调用所需的最小元数据,
 * VRM 详细骨骼信息由 VrmMetaStore 通过 sourceSha256 单独管理,
 * 显示配置由 Character3DDisplayConfig 通过 modelId 单独管理。
 */
export interface AvatarRecord {
  /** UUID v4,导入时生成,稳定不变 */
  avatarId: string;
  /** 显示名,用户可改 */
  displayName: string;
  /** 模型文件 URI(file://<绝对路径>),由 Model3DAssetStore 生成 */
  modelUri: string;
  /** 文件大小(字节) */
  fileSize: number;
  /** 导入时间戳(毫秒) */
  importedAt: number;
  /** 是否 VRM 文件 */
  isVrm: boolean;
  /** VRM 版本('Vrm0x' | 'Vrm1' | 'NonVrm') */
  vrmVersion: string;
  /** VRM 显式声明的骨骼数(非 VRM 为 0) */
  declaredHumanBoneCount: number;
  /** 有效映射的骨骼数(非 VRM 为 0) */
  validHumanBoneCount: number;
  /** T-4.2: 原始文件 SHA-256(用于重复检测;旧记录可能为空字符串) */
  sourceSha256: string;
}

/**
 * Avatar 模型库持久化存储。
 *
 * 使用 AppPreferences 作为底层存储,通过 JSON 序列化 AvatarRecord。
 * 文件操作委托给 Model3DAssetStore,本类只管元数据。
 */
export class AvatarLibraryStore {
  private prefs: AppPreferences;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
  }

  /**
   * 读取全部 AvatarRecord,按导入时间升序。
   * 索引列表中存在但 record 缺失的 avatarId 会被自动清理。
   */
  async listAll(): Promise<AvatarRecord[]> {
    const indexJson: string = await this.prefs.getString(KEY_INDEX, '');
    if (indexJson.length === 0) {
      return [];
    }
    let ids: string[] = [];
    try {
      const parsed: object = JSON.parse(indexJson);
      if (Array.isArray(parsed)) {
        const arr: object[] = parsed as object[];
        for (let i = 0; i < arr.length; i++) {
          const v: object = arr[i];
          if (typeof v === 'string') {
            // typeof 收窄后,直接赋值给 string 变量(ArkTS 允许 object→string 在 typeof 收窄后)
            const s: string = v as string;
            if (s.length > 0) {
              ids.push(s);
            }
          }
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'listAll parse index failed: ' + String(e));
      return [];
    }
    const records: AvatarRecord[] = [];
    const validIds: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const rec: AvatarRecord | null = await this.loadRecord(ids[i]);
      if (rec !== null) {
        records.push(rec);
        validIds.push(ids[i]);
      }
    }
    // 自动修复索引(record 缺失则从索引移除)
    if (validIds.length !== ids.length) {
      await this.prefs.putString(KEY_INDEX, JSON.stringify(validIds));
    }
    // 升序(老的在前)
    records.sort((a: AvatarRecord, b: AvatarRecord): number => a.importedAt - b.importedAt);
    return records;
  }

  /**
   * 按 avatarId 读取单条记录。
   * 不存在返回 null。
   */
  async get(avatarId: string): Promise<AvatarRecord | null> {
    if (avatarId.length === 0) {
      return null;
    }
    return this.loadRecord(avatarId);
  }

  /**
   * 保存(新增或更新)一条记录。
   * 新增时自动追加到索引列表;更新时索引不变。
   */
  async save(record: AvatarRecord): Promise<void> {
    const key: string = KEY_RECORD_PREFIX + record.avatarId;
    await this.prefs.putString(key, JSON.stringify(record));
    // 追加到索引(若不存在)
    const ids: string[] = await this.readIndex();
    if (ids.indexOf(record.avatarId) < 0) {
      ids.push(record.avatarId);
      await this.prefs.putString(KEY_INDEX, JSON.stringify(ids));
    }
  }

  /**
   * 删除一条记录(仅元数据,不删模型文件)。
   * 若该 avatarId 是当前激活,会清空激活 ID。
   * 调用方负责通过 Model3DAssetStore.deleteModelByUri 删除模型文件。
   */
  async delete(avatarId: string): Promise<void> {
    if (avatarId.length === 0) {
      return;
    }
    const key: string = KEY_RECORD_PREFIX + avatarId;
    await this.prefs.delete(key);
    // 从索引移除
    const ids: string[] = await this.readIndex();
    const idx: number = ids.indexOf(avatarId);
    if (idx >= 0) {
      ids.splice(idx, 1);
      await this.prefs.putString(KEY_INDEX, JSON.stringify(ids));
    }
    // 若是激活,清空
    const activeId: string = await this.getActiveId();
    if (activeId === avatarId) {
      await this.prefs.putString(KEY_ACTIVE_ID, '');
    }
  }

  /**
   * 重命名(仅修改 displayName 字段)。
   */
  async rename(avatarId: string, newDisplayName: string): Promise<void> {
    const rec: AvatarRecord | null = await this.loadRecord(avatarId);
    if (rec === null) {
      throw new Error('Avatar not found: ' + avatarId);
    }
    rec.displayName = newDisplayName;
    await this.save(rec);
  }

  /**
   * 读取当前激活 avatarId。
   * 空字符串表示无激活。
   */
  async getActiveId(): Promise<string> {
    return this.prefs.getString(KEY_ACTIVE_ID, '');
  }

  /**
   * 设置当前激活 avatarId。
   * 传空字符串表示取消激活。
   * 不校验 avatarId 是否存在(由上层 Service 保证)。
   */
  async setActiveId(avatarId: string): Promise<void> {
    await this.prefs.putString(KEY_ACTIVE_ID, avatarId);
  }

  /**
   * 读取索引列表(内部)。
   */
  private async readIndex(): Promise<string[]> {
    const json: string = await this.prefs.getString(KEY_INDEX, '');
    if (json.length === 0) {
      return [];
    }
    try {
      const parsed: object = JSON.parse(json);
      if (Array.isArray(parsed)) {
        const arr: object[] = parsed as object[];
        const ids: string[] = [];
        for (let i = 0; i < arr.length; i++) {
          const v: object = arr[i];
          if (typeof v === 'string') {
            const s: string = v as string;
            if (s.length > 0) {
              ids.push(s);
            }
          }
        }
        return ids;
      }
    } catch (_e) {
      // ignore
    }
    return [];
  }

  /**
   * 读取单条 record(内部)。
   */
  private async loadRecord(avatarId: string): Promise<AvatarRecord | null> {
    const key: string = KEY_RECORD_PREFIX + avatarId;
    const json: string = await this.prefs.getString(key, '');
    if (json.length === 0) {
      return null;
    }
    try {
      const parsed: AvatarRecord = JSON.parse(json) as AvatarRecord;
      if (parsed.avatarId === undefined || parsed.avatarId.length === 0) {
        return null;
      }
      // T-4.2: 向后兼容,旧记录无 sourceSha256 字段时补空字符串
      if (parsed.sourceSha256 === undefined || parsed.sourceSha256 === null) {
        parsed.sourceSha256 = '';
      }
      return parsed;
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadRecord parse failed: ' + String(e));
      return null;
    }
  }
}
