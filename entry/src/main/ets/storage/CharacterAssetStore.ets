/**
 * CharacterAssetStore 角色资源文件管理
 *
 * 负责角色头像等资源文件的持久化。
 * 文件存储在应用私有目录,避免外部 URI 失效。
 *
 * 职责:
 * - 将导入 PNG 复制到应用私有目录
 * - 生成安全文件名
 * - 删除角色时同步删除头像文件
 * - 不保存外部临时 URI 作为长期头像地址
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/数据库
 * - 使用 @kit.CoreFileKit 进行文件操作
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterAssetStore';
const AVATAR_DIR: string = 'avatars';
const AVATAR_PREFIX: string = 'avatar_';

export class CharacterAssetStore {
  private baseDir: string = '';
  private initialized: boolean = false;

  /**
   * 初始化,创建头像目录。
   */
  initialize(context: common.Context): void {
    const filesDir: string = context.filesDir;
    this.baseDir = filesDir + '/' + AVATAR_DIR;
    try {
      if (!fileIo.accessSync(this.baseDir)) {
        fileIo.mkdirSync(this.baseDir, true);
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize mkdir failed: ' + String(e));
    }
    this.initialized = true;
    Logger.info(LOG_TAG, 'initialize ok baseDir=' + this.baseDir);
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('CharacterAssetStore not initialized');
    }
  }

  /**
   * 复制头像文件到应用私有目录。
   *
   * @param sourceUri 源文件 URI
   * @param characterId 角色 ID
   * @returns 新的头像文件 URI
   */
  async saveAvatar(sourceUri: string, characterId: string): Promise<string> {
    this.requireInit();
    const destPath: string = this.baseDir + '/' + AVATAR_PREFIX + characterId + '.png';
    try {
      const srcFile: fileIo.File = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(srcFile.fd);
      if (stat.size > 50 * 1024 * 1024) {
        fileIo.closeSync(srcFile);
        throw new Error('头像文件过大,不能超过 50MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, buffer);
      fileIo.closeSync(srcFile);

      const destFile: fileIo.File = fileIo.openSync(destPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      fileIo.writeSync(destFile.fd, buffer);
      fileIo.closeSync(destFile);

      Logger.info(LOG_TAG, 'saveAvatar ok path=' + destPath + ' size=' + String(stat.size));
      return 'file://' + destPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveAvatar failed: ' + String(e));
      throw new Error('保存头像失败: ' + String(e));
    }
  }

  /**
   * 删除角色头像文件。
   * 文件不存在时静默成功。
   *
   * @param characterId 角色 ID
   */
  async deleteAvatar(characterId: string): Promise<void> {
    this.requireInit();
    const path: string = this.baseDir + '/' + AVATAR_PREFIX + characterId + '.png';
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
        Logger.info(LOG_TAG, 'deleteAvatar ok path=' + path);
      }
    } catch (e) {
      // 文件不存在或删除失败,静默处理
      Logger.warn(LOG_TAG, 'deleteAvatar ignored: ' + String(e));
    }
  }
}