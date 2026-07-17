/**
 * MacroReplacer 宏替换服务
 *
 * 对文本中的基础宏进行替换。
 * 独立服务,不依赖 ArkUI、Preferences 或网络。
 *
 * 支持的宏:
 * - {{char}} → context.characterName
 * - {{character}} → context.characterName
 * - {{user}} → context.userName
 *
 * 替换规则:
 * - 宏名称大小写不敏感
 * - 同一文本中的多个宏全部替换
 * - 未识别宏保持原样
 * - characterName 为空时角色宏保持原样
 * - userName 为空时用户宏保持原样
 * - 不执行递归替换
 * - 空字符串返回空字符串
 *
 * 设计:
 * - 使用单次正则扫描替换,避免递归
 * - replace 回调返回的替换文本不会被再次扫描
 * - 日志只记录是否执行替换和替换数量,不记录原文或替换结果
 */

import { MacroContext } from '../models/MacroContext';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MacroReplacer';

/**
 * 匹配 {{char}} / {{character}} / {{user}},大小写不敏感,全局匹配。
 * 捕获组 1 为宏名称(不含花括号)。
 */
const MACRO_PATTERN: RegExp = /\{\{(char|character|user)\}\}/gi;

/**
 * 宏替换服务。
 */
export class MacroReplacer {
  /**
   * 替换文本中的宏。
   *
   * @param content 原始文本
   * @param context 宏替换上下文
   * @returns 替换后的文本
   */
  replace(content: string, context: MacroContext): string {
    if (content.length === 0) {
      return '';
    }

    let replaceCount: number = 0;
    const result: string = content.replace(
      MACRO_PATTERN,
      (match: string, macroName: string): string => {
        const lower: string = macroName.toLowerCase();
        if (lower === 'char' || lower === 'character') {
          if (context.characterName.length > 0) {
            replaceCount++;
            return context.characterName;
          }
          return match;
        }
        if (lower === 'user') {
          if (context.userName.length > 0) {
            replaceCount++;
            return context.userName;
          }
          return match;
        }
        return match;
      }
    );

    if (replaceCount > 0) {
      Logger.info(LOG_TAG, 'replace: count=' + replaceCount);
    }
    return result;
  }
}
