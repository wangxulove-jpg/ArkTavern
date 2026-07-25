/**
 * ShaUtil SHA-256 计算工具
 *
 * T-4.2E-Closeout: 统一 SHA-256 计算逻辑,供 Character3DService / AvatarLibraryService 复用。
 *
 * 使用 HarmonyOS cryptoFramework 的同步 API 计算 buffer 的 SHA-256,
 * 返回 Base64 编码字符串(与 Character3DModelCompatibilityService 历史实现一致)。
 *
 * 不依赖 ArkUI / 网络 / 数据库。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * 计算 ArrayBuffer 的 SHA-256,返回 Base64 字符串。
 *
 * @param buffer 待计算的二进制内容
 * @returns Base64 编码的 SHA-256 字符串;输入为空时返回空字符串
 */
export function computeSha256Base64(buffer: ArrayBuffer): string {
  if (buffer === null || buffer === undefined || buffer.byteLength === 0) {
    return '';
  }
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const inputData: cryptoFramework.DataBlob = {
    data: new Uint8Array(buffer)
  } as cryptoFramework.DataBlob;
  md.updateSync(inputData);
  const digestBlob: cryptoFramework.DataBlob = md.digestSync();
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(digestBlob.data, util.Type.BASIC);
}
