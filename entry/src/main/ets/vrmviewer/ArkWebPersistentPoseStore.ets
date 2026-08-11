import { Logger } from '../utils/Logger';
/**
 * ArkWebPersistentPoseStore — 持久化姿势存储 (Phase 3D-1)
 *
 * 职责:
 * - 导入 .json 姿势文件到 filesDir/avatar-assets/poses/
 * - 校验文件 (非空 / 大小)
 * - 读取并基础验证 JSON 结构 (可解析 / 根对象 / 可识别的骨骼或姿势数据对象)
 * - 生成 poseId (pose_<timestamp>_<random>)
 * - 创建 relativePath (poses/<poseId>.json)
 * - 原子复制姿势文件 (.json.part → rename)
 * - 构造 ArkWebAvatarPoseAsset
 * - 删除失败的临时文件
 * - 提交到 AssetLibrary (appendPose)
 * - 清单写入失败时回滚: 删除新姿势文件
 * - 解析持久资源绝对路径
 *
 * 持久目录:
 * - <context.filesDir>/avatar-assets/poses/
 * - 目标文件: <poseId>.json
 * - 临时文件: <poseId>.json.part
 *
 * 安全约束:
 * - poseId 只包含 a-z A-Z 0-9 _ -
 * - 不使用原始文件名
 * - 不包含路径分隔符
 * - 相对路径必须以 "poses/" 开头且以 .json 结尾
 *
 * 原子复制流程:
 * 1. 打开源 URI (只读)
 * 2. stat 获取源文件大小
 * 3. 校验非空
 * 4. 创建 .part 临时文件
 * 5. 分块复制 (64 KiB 缓冲)
 * 6. 验证写入大小
 * 7. rename .part → 最终文件
 * 8. 读取并验证 JSON 结构
 * 9. 构造 ArkWebAvatarPoseAsset
 * 10. 提交到 AssetLibrary.appendPose
 * 11. 清单失败 → 删除新姿势文件 (回滚)
 *
 * JSON 结构验证 (基础):
 * - 文件非空
 * - JSON.parse 成功
 * - 根节点是对象 (非数组/非原始值)
 * - 存在可识别的骨骼或姿势数据对象:
 *   - bones (对象, 至少包含一个 key)
 *   - humanBones (对象, 至少包含一个 key)
 *   - pose (对象, 至少包含一个 key)
 * 不识别的 JSON 返回 POSE_JSON_SCHEMA_UNSUPPORTED, 拒绝导入。
 *
 * 失败处理:
 * - 关闭文件描述符
 * - 删除 .part 临时文件
 * - 不覆盖已有姿势文件
 * - 清单写入失败时删除本次新复制的姿势文件
 *
 * 本阶段不实现:
 * - 应用姿势到模型骨骼
 * - 骨骼旋转解析
 * - 姿势混合
 * - VRMA 转换
 *
 * Reference:
 * - ArkWebPersistentAnimationStore (Phase 3C-1): 复制 / .part / rename 模式
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import {
  ArkWebAvatarPoseAsset,
  PersistentPoseErrorCode
} from './ArkWebAvatarAssetTypes';
import {
  ArkWebAvatarAssetLibrary,
  POSES_SUBDIR_NAME
} from './ArkWebAvatarAssetLibrary';
import {
  ArkWebPoseData,
  ArkWebPoseBoneEntry
} from './ArkWebVrmViewerTypes';

/**
 * 复制缓冲区大小: 64 KiB。
 */
const PERSISTENT_POSE_COPY_BUFFER_SIZE: number = 64 * 1024;

/**
 * poseId 随机部分长度。
 */
const POSE_ID_RANDOM_LENGTH: number = 8;

/**
 * 姿势 JSON 格式标识。
 */
export const POSE_FORMAT_JSON: string = 'json';

/**
 * 可识别的骨骼或姿势数据字段名 (任一存在且为非空对象即视为姿势 JSON)。
 * 'data' 用于兼容 VRoid Studio 导出格式 (顶层 data 字段封装骨骼 map)。
 */
const RECOGNIZED_POSE_FIELDS: string[] = ['bones', 'humanBones', 'pose', 'data'];

/**
 * 持久化姿势存储。
 *
 * 使用方式:
 * 1. 页面 aboutToAppear 创建实例,传入 UIAbilityContext 和 AssetLibrary
 * 2. 用户选择文件后调用 importPose(sourceUri, displayName)
 * 3. 成功返回 ArkWebAvatarPoseAsset,失败返回 null (查看 lastError)
 * 4. 页面 aboutToDisappear 调用 dispose()
 */
export class ArkWebPersistentPoseStore {
  /** 应用上下文 (用于 filesDir)。 */
  private readonly context: common.UIAbilityContext;
  /** 资产库 (单一所有者, 由页面注入)。 */
  private readonly assetLibrary: ArkWebAvatarAssetLibrary;
  /** 姿势目录绝对路径。 */
  private readonly posesDir: string;
  /** 最近一次错误消息。 */
  private lastError: string = '';
  /** 是否已销毁。 */
  private disposed: boolean = false;

  constructor(context: common.UIAbilityContext, assetLibrary: ArkWebAvatarAssetLibrary) {
    this.context = context;
    this.assetLibrary = assetLibrary;
    this.posesDir = assetLibrary.getPosesDir();
  }

  /** 获取最近一次错误消息。 */
  getLastError(): string {
    return this.lastError;
  }

  /** 是否已销毁。 */
  isDisposed(): boolean {
    return this.disposed;
  }

  /**
   * 获取姿势目录绝对路径 (filesDir/avatar-assets/poses)。
   */
  getPosesDir(): string {
    return this.posesDir;
  }

  /**
   * 导入姿势文件到持久目录。
   *
   * 流程:
   * 1. 校验状态
   * 2. 生成 poseId
   * 3. 打开源 URI
   * 4. stat 获取大小,校验非空
   * 5. 创建 .part 文件
   * 6. 分块复制
   * 7. 验证写入大小
   * 8. 关闭 FD
   * 9. rename .part → 最终文件
   * 10. 读取并验证 JSON 结构 (失败则删除文件并返回 null)
   * 11. 构造资产记录
   * 12. 提交到 AssetLibrary.appendPose
   * 13. 清单失败 → 删除新姿势文件 (回滚)
   *
   * @param sourceUri 源文件 URI (来自 Picker)
   * @param displayName 用户可读显示名
   * @returns 资产记录; 失败返回 null
   */
  async importPose(
    sourceUri: string,
    displayName: string
  ): Promise<ArkWebAvatarPoseAsset | null> {
    if (this.disposed) {
      this.lastError = PersistentPoseErrorCode.POSE_STORE_DISPOSED;
      return null;
    }
    if (this.assetLibrary.isDisposed()) {
      this.lastError = PersistentPoseErrorCode.POSE_STORE_LIBRARY_INVALID;
      return null;
    }

    // 确保 posesDir 目录存在 (由 AssetLibrary.ensureInitialized 创建)。
    // 页面 aboutToAppear 的 ensureInitialized 是 fire-and-forget, 此处补一次 await 防竞态。
    // ensureInitialized 幂等且有并发保护 (复用 initPromise), 重复调用安全。
    const dirOk: boolean = await this.assetLibrary.ensureInitialized();
    Logger.warn(`[PoseStore] importPose: ensureInitialized=${dirOk}, posesDir=${this.posesDir}`);
    if (!dirOk) {
      this.lastError = `${PersistentPoseErrorCode.POSE_TARGET_CREATE_FAILED}: posesDir unavailable`;
      return null;
    }

    // 强制确保 posesDir 物理存在 (不依赖 fileIo.access, 它在 sandbox 下可能误报)。
    // fileIo.mkdir(path, true) 递归创建, 目录已存在时 HarmonyOS 不会抛错。
    // 但旧版本可能抛 "File exists", 用 try/catch 忽略该错误。
    try {
      await fileIo.mkdir(this.posesDir, true);
      Logger.warn(`[PoseStore] importPose: mkdir posesDir OK (forced)`);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      // "File exists" 视为成功,其他错误才真正失败
      if (!/exists|Exist/i.test(msg)) {
        Logger.warn(`[PoseStore] importPose: mkdir posesDir FAILED: ${msg}`);
        this.lastError = `${PersistentPoseErrorCode.POSE_TARGET_CREATE_FAILED}: mkdir posesDir failed: ${msg}`;
        return null;
      }
      Logger.warn(`[PoseStore] importPose: mkdir posesDir returned exists, continue`);
    }

    const poseId: string = this.generatePoseId();
    const fileName: string = `${poseId}.json`;
    const finalPath: string = `${this.posesDir}/${fileName}`;
    const partPath: string = `${finalPath}.part`;

    let sourceFile: fileIo.File | null = null;
    let targetFile: fileIo.File | null = null;
    let sourceSize: number = 0;
    let writtenTotal: number = 0;
    let renameDone: boolean = false;

    try {
      // 1. 打开源文件 (只读)
      try {
        sourceFile = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentPoseErrorCode.POSE_SOURCE_OPEN_FAILED}: ${msg}`;
        return null;
      }

      // 2. stat 获取大小
      try {
        const stat: fileIo.Stat = await fileIo.stat(sourceFile.fd);
        sourceSize = stat.size;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentPoseErrorCode.POSE_SOURCE_OPEN_FAILED}: ${msg}`;
        return null;
      }

      // 3. 校验非空
      if (sourceSize <= 0) {
        this.lastError = PersistentPoseErrorCode.POSE_FILE_EMPTY;
        return null;
      }

      // 4. 创建 .part 文件
      Logger.warn(`[PoseStore] importPose: creating partFile=${partPath}`);
      try {
        targetFile = await fileIo.open(
          partPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
        );
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.warn(`[PoseStore] importPose: partFile CREATE FAILED: ${msg}, posesDir=${this.posesDir}`);
        this.lastError = `${PersistentPoseErrorCode.POSE_TARGET_CREATE_FAILED}: ${msg}`;
        return null;
      }

      // 5. 分块复制
      const buffer: ArrayBuffer = new ArrayBuffer(PERSISTENT_POSE_COPY_BUFFER_SIZE);
      writtenTotal = 0;
      try {
        while (writtenTotal < sourceSize) {
          const remaining: number = sourceSize - writtenTotal;
          const readLen: number = remaining < PERSISTENT_POSE_COPY_BUFFER_SIZE
            ? remaining : PERSISTENT_POSE_COPY_BUFFER_SIZE;
          const bytesRead: number = await fileIo.read(sourceFile.fd, buffer, {
            offset: writtenTotal,
            length: readLen
          });
          if (bytesRead <= 0) {
            break;
          }
          const bytesWritten: number = await fileIo.write(targetFile.fd, buffer, {
            offset: writtenTotal,
            length: bytesRead
          });
          if (bytesWritten !== bytesRead) {
            this.lastError = `${PersistentPoseErrorCode.POSE_FILE_WRITE_FAILED}: ` +
              `写入不完整 (期望 ${bytesRead}, 实际 ${bytesWritten})`;
            return null;
          }
          writtenTotal += bytesWritten;
        }
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentPoseErrorCode.POSE_FILE_READ_FAILED}: ${msg}`;
        return null;
      }

      // 6. 验证写入大小
      if (writtenTotal !== sourceSize) {
        this.lastError = `${PersistentPoseErrorCode.POSE_FILE_COPY_INCOMPLETE}: ` +
          `源 ${sourceSize} 字节, 已写入 ${writtenTotal} 字节`;
        return null;
      }

      // 7. 关闭 FD (rename 前必须关闭)
      await this.closeFile(sourceFile);
      sourceFile = null;
      await this.closeFile(targetFile);
      targetFile = null;

      // 8. rename .part → 最终文件
      try {
        await fileIo.rename(partPath, finalPath);
        renameDone = true;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentPoseErrorCode.POSE_RENAME_FAILED}: ${msg}`;
        return null;
      }

      // 9. 读取并验证 JSON 结构
      const validateOk: boolean = await this.validatePoseJsonFile(finalPath);
      if (!validateOk) {
        // validatePoseJsonFile 已设置 lastError
        await this.safeUnlink(finalPath);
        renameDone = false;
        return null;
      }

      // 10. 构造资产记录
      const now: number = Date.now();
      const asset: ArkWebAvatarPoseAsset = {
        poseId: poseId,
        displayName: displayName,
        relativePath: `${POSES_SUBDIR_NAME}/${fileName}`,
        byteLength: sourceSize,
        format: POSE_FORMAT_JSON,
        createdAt: now,
        updatedAt: now
      };

      // 11. 提交到 AssetLibrary
      const commitOk: boolean = await this.assetLibrary.appendPose(asset);
      if (!commitOk) {
        // 回滚: 删除新姿势文件 (不删除 .part, .part 已 rename)
        await this.safeUnlink(finalPath);
        renameDone = false;
        this.lastError = PersistentPoseErrorCode.POSE_LIBRARY_WRITE_FAILED;
        return null;
      }

      this.lastError = '';
      Logger.debug(
        `[ArkWebPersistentPoseStore] importPose ok: poseId=${poseId}, size=${sourceSize}`
      );
      return asset;
    } finally {
      if (sourceFile !== null) {
        await this.closeFile(sourceFile);
        sourceFile = null;
      }
      if (targetFile !== null) {
        await this.closeFile(targetFile);
        targetFile = null;
      }
      // 失败时清理 .part (rename 已完成则不清理)
      if (!renameDone) {
        await this.safeUnlink(partPath);
      }
    }
  }

  /**
   * 读取并基础验证姿势 JSON 文件结构。
   *
   * 验证项:
   * - 文件非空
   * - JSON.parse 成功
   * - 根节点是对象
   * - 存在可识别的骨骼或姿势数据对象 (bones / humanBones / pose)
   *
   * 失败时设置 lastError 并返回 false。
   */
  private async validatePoseJsonFile(filePath: string): Promise<boolean> {
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        this.lastError = PersistentPoseErrorCode.POSE_FILE_EMPTY;
        return false;
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const bytesRead: number = await fileIo.read(file.fd, buffer, { length: size });
      if (bytesRead !== size) {
        this.lastError = `${PersistentPoseErrorCode.POSE_FILE_READ_FAILED}: 读取不完整`;
        return false;
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buffer));

      let parsed: object;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentPoseErrorCode.POSE_JSON_PARSE_FAILED}: ${msg}`;
        return false;
      }

      // 根节点必须是对象 (非数组 / 非原始值)
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        this.lastError = PersistentPoseErrorCode.POSE_JSON_ROOT_NOT_OBJECT;
        return false;
      }

      // 必须存在可识别的骨骼或姿势数据对象
      const root: Record<string, Object> = parsed as Record<string, Object>;
      let recognized: boolean = false;
      for (let i = 0; i < RECOGNIZED_POSE_FIELDS.length; i++) {
        const field: string = RECOGNIZED_POSE_FIELDS[i];
        const v: Object | undefined = root[field];
        if (v !== undefined && typeof v === 'object' && v !== null && !Array.isArray(v)) {
          const fieldObj: Record<string, Object> = v as Record<string, Object>;
          if (Object.keys(fieldObj).length > 0) {
            recognized = true;
            break;
          }
        }
      }
      if (!recognized) {
        this.lastError = PersistentPoseErrorCode.POSE_JSON_SCHEMA_UNSUPPORTED;
        return false;
      }
      return true;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastError = `${PersistentPoseErrorCode.POSE_FILE_READ_FAILED}: ${msg}`;
      return false;
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
   * 根据相对路径解析持久资源的绝对路径 (filesDir + relativePath)。
   *
   * 安全校验: relativePath 必须以 "poses/" 开头且以 .json 结尾, 不含 ..
   *
   * @returns 绝对路径; 不安全返回空字符串
   */
  resolveAbsolutePath(relativePath: string): string {
    if (relativePath.length === 0) {
      return '';
    }
    if (relativePath.startsWith('/')) {
      return '';
    }
    if (!relativePath.startsWith(`${POSES_SUBDIR_NAME}/`)) {
      return '';
    }
    if (!relativePath.endsWith('.json')) {
      return '';
    }
    if (relativePath.includes('..') || relativePath.includes('\\')) {
      return '';
    }
    return `${this.assetLibrary.getAssetsRootDir()}/${relativePath}`;
  }

  /**
   * 销毁 Store。
   * - 标记 disposed
   * - 不删除 filesDir 下的姿势文件
   * - 不清空 library.poses
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
  }

  // ===== Phase 3D-2: 读取姿势 JSON 并构造受控 ArkWebPoseData =====

  /**
   * Phase 3D-2: 根据 poseId 读取持久姿势 JSON 文件,构造受控 ArkWebPoseData。
   *
   * 流程:
   * 1. 校验状态(disposed / library)
   * 2. 从 AssetLibrary.poses 查找匹配 poseId 的 ArkWebAvatarPoseAsset
   * 3. resolveAbsolutePath 解析绝对路径 (安全校验)
   * 4. 读取 JSON 文件 (fileIo.open + stat + read + TextDecoder)
   * 5. JSON.parse 解析
   * 6. 抽取 bones/humanBones/pose 任一入口 (与 Phase 3D-1 入口一致)
   * 7. 规范化为 ArkWebPoseData.bones map
   *    - 每个骨骼条目必须有 rotation (数组或对象)
   *    - rotation 必须有 4 个有限数字
   *    - 不合法的骨骼条目被跳过(忽略),不让整个读取失败
   * 8. 构造 ArkWebPoseData { poseId, displayName, bones }
   * 9. 序列化为 JSON 字符串
   *
   * 不暴露:
   *   - absolutePath / relativePath / filesDir
   *   - 文件描述符
   *   - 原始 URI
   *
   * @param poseId 姿势 ID
   * @returns 受控姿势数据 JSON 字符串; 失败返回空字符串 (查看 lastError)
   */
  async readPoseDataAsJson(poseId: string): Promise<string> {
    if (this.disposed) {
      this.lastError = PersistentPoseErrorCode.POSE_STORE_DISPOSED;
      return '';
    }
    if (this.assetLibrary.isDisposed()) {
      this.lastError = PersistentPoseErrorCode.POSE_STORE_LIBRARY_INVALID;
      return '';
    }
    if (poseId.length === 0) {
      this.lastError = PersistentPoseErrorCode.POSE_JSON_PARSE_FAILED + ': poseId is empty';
      return '';
    }

    // 查找 PoseAsset (使用 AssetLibrary.findPose,内部读取 library.json)
    const targetAsset: ArkWebAvatarPoseAsset | null = await this.assetLibrary.findPose(poseId);
    if (targetAsset === null) {
      this.lastError = PersistentPoseErrorCode.POSE_JSON_PARSE_FAILED + ': poseId not found in library';
      return '';
    }

    // 解析绝对路径
    const absolutePath: string = this.resolveAbsolutePath(targetAsset.relativePath);
    if (absolutePath.length === 0) {
      this.lastError = PersistentPoseErrorCode.POSE_JSON_PARSE_FAILED + ': invalid relativePath';
      return '';
    }

    // 读取文件
    let file: fileIo.File | null = null;
    try {
      file = await fileIo.open(absolutePath, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        this.lastError = PersistentPoseErrorCode.POSE_FILE_EMPTY;
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const bytesRead: number = await fileIo.read(file.fd, buffer, { length: size });
      if (bytesRead !== size) {
        this.lastError = PersistentPoseErrorCode.POSE_FILE_READ_FAILED + ': read incomplete';
        return '';
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(new Uint8Array(buffer));

      let parsed: object;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        this.lastError = `${PersistentPoseErrorCode.POSE_JSON_PARSE_FAILED}: ${msg}`;
        return '';
      }

      // 根节点必须是对象
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        this.lastError = PersistentPoseErrorCode.POSE_JSON_ROOT_NOT_OBJECT;
        return '';
      }

      // 抽取 bones/humanBones/pose 任一入口 (与 Phase 3D-1 一致)
      const root: Record<string, Object> = parsed as Record<string, Object>;
      let sourceBonesMap: Record<string, Object> | null = null;
      for (let i = 0; i < RECOGNIZED_POSE_FIELDS.length; i++) {
        const field: string = RECOGNIZED_POSE_FIELDS[i];
        const v: Object | undefined = root[field];
        if (v !== undefined && typeof v === 'object' && v !== null && !Array.isArray(v)) {
          const fieldObj: Record<string, Object> = v as Record<string, Object>;
          if (Object.keys(fieldObj).length > 0) {
            sourceBonesMap = fieldObj;
            break;
          }
        }
      }
      if (sourceBonesMap === null) {
        this.lastError = PersistentPoseErrorCode.POSE_JSON_SCHEMA_UNSUPPORTED;
        return '';
      }

      // 规范化为 ArkWebPoseData.bones
      // - 每个骨骼条目必须有 rotation (数组或对象)
      // - rotation 必须有 4 个有限数字
      // - 不合法的骨骼条目被跳过 (忽略), 不让整个读取失败
      // - 至少存在一个有效骨骼条目, 否则返回错误
      const normalizedBones: Record<string, ArkWebPoseBoneEntry> = {};
      const boneNames: string[] = Object.keys(sourceBonesMap);
      let validCount: number = 0;
      for (let j = 0; j < boneNames.length; j++) {
        const boneName: string = boneNames[j];
        if (boneName.length === 0) {
          continue;
        }
        const entry: Object | undefined = sourceBonesMap[boneName];
        if (entry === undefined || entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
          continue;
        }
        const entryObj: Record<string, Object> = entry as Record<string, Object>;
        const rotation: Object | undefined = entryObj['rotation'];
        if (rotation === undefined || rotation === null) {
          continue;
        }
        const quat: number[] | null = this.parseRotationToArray(rotation);
        if (quat === null) {
          continue;
        }
        normalizedBones[boneName] = { rotation: quat };
        validCount++;
      }
      if (validCount === 0) {
        this.lastError = PersistentPoseErrorCode.POSE_JSON_SCHEMA_UNSUPPORTED + ': no valid bone entries';
        return '';
      }

      // Phase 3D-2R: 提取来源 JSON 的 vrmVersion (用于 Web 端版本同步)
      let poseVrmVersion: string = '';
      const vrmVersionRaw: Object | undefined = root['vrmVersion'];
      if (vrmVersionRaw !== undefined && vrmVersionRaw !== null) {
        poseVrmVersion = String(vrmVersionRaw);
      }

      // 构造 ArkWebPoseData (不暴露 absolutePath / relativePath / filesDir)
      const poseData: ArkWebPoseData = {
        poseId: targetAsset.poseId,
        displayName: targetAsset.displayName,
        bones: normalizedBones,
        vrmVersion: poseVrmVersion
      };
      this.lastError = '';
      return JSON.stringify(poseData);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.lastError = `${PersistentPoseErrorCode.POSE_FILE_READ_FAILED}: ${msg}`;
      return '';
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
   * Phase 3D-2: 解析 rotation 字段为 [x, y, z, w] 数组。
   *
   * 支持格式:
   *   - 数组 [x, y, z, w]
   *   - 对象 { x, y, z, w }
   *
   * 验证:
   *   - 必须有 4 个有限数字
   *
   * 注意: 此处只做有限值校验,四元数长度校验在 Web 端 ViewerPoseController 中执行。
   * (避免 ArkTS 与 Web 端重复实现长度校验,Web 端是单一真理来源)
   *
   * @returns [x, y, z, w] 或 null (无效)
   */
  private parseRotationToArray(rotation: Object): number[] | null {
    let x: number;
    let y: number;
    let z: number;
    let w: number;
    if (Array.isArray(rotation)) {
      if (rotation.length !== 4) {
        return null;
      }
      const arr: Object[] = rotation as Object[];
      x = this.toFiniteNumber(arr[0]);
      y = this.toFiniteNumber(arr[1]);
      z = this.toFiniteNumber(arr[2]);
      w = this.toFiniteNumber(arr[3]);
    } else if (typeof rotation === 'object') {
      const rObj: Record<string, Object> = rotation as Record<string, Object>;
      x = this.toFiniteNumber(rObj['x']);
      y = this.toFiniteNumber(rObj['y']);
      z = this.toFiniteNumber(rObj['z']);
      w = this.toFiniteNumber(rObj['w']);
    } else {
      return null;
    }
    if (!isFinite(x) || !isFinite(y) || !isFinite(z) || !isFinite(w)) {
      return null;
    }
    return [x, y, z, w];
  }

  /**
   * Phase 3D-2: 安全转换为有限 number。
   * 非数字 / NaN / Infinity 返回 NaN。
   */
  private toFiniteNumber(v: Object): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      const n: number = Number(v);
      return n;
    }
    return NaN;
  }

  // ===== 内部方法 =====

  /**
   * 生成 poseId: pose_<timestamp>_<8 位 hex>。
   *
   * 使用 util.generateRandomUUID 提取前 8 位 hex,与 actionId 生成方式一致。
   */
  private generatePoseId(): string {
    const timestamp: number = Date.now();
    const uuid: string = util.generateRandomUUID(false);
    const randomPart: string = uuid.replace(/-/g, '').substring(0, POSE_ID_RANDOM_LENGTH);
    return `pose_${timestamp}_${randomPart}`;
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
}
