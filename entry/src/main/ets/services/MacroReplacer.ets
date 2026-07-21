/**
 * MacroReplacer 宏替换服务
 *
 * 对文本中的基础宏进行替换。
 * 独立服务,不依赖 ArkUI、Preferences 或网络。
 *
 * 支持的宏(大小写不敏感):
 * - {{char}} / {{character}} → context.characterName
 * - {{user}} → context.userName
 * - {{description}} → context.description(未提供时保持原样)
 * - {{personality}} → context.personality
 * - {{scenario}} → context.scenario
 * - {{mes_example}} / {{mesexample}} → context.mesExample
 * - {{last_message}} / {{lastmessage}} → context.lastMessage
 * - {{original}} → context.originalContent
 *
 * 替换规则:
 * - 宏名称大小写不敏感
 * - 同一文本中的多个宏全部替换
 * - 未识别宏保持原样
 * - 字段为 undefined 时,对应宏保持原样
 * - characterName / userName 为空时对应宏保持原样
 * - 不执行递归替换
 * - 空字符串返回空字符串
 *
 * 设计:
 * - 使用单次正则扫描替换,避免递归
 * - replace 回调返回的替换文本不会被再次扫描
 * - 日志只记录是否执行替换和替换数量,不记录原文或替换结果
 */

import { MacroContext } from '../models/MacroContext';

/**
 * 匹配所有支持的宏,大小写不敏感,全局匹配。
 * 捕获组 1 为宏名称(不含花括号)。
 */
const MACRO_PATTERN: RegExp =
  /\{\{(char|character|user|description|personality|scenario|mes_example|mesexample|last_message|lastmessage|original)\}\}/gi;

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

    const result: string = content.replace(
      MACRO_PATTERN,
      (match: string, macroName: string): string => {
        const lower: string = macroName.toLowerCase();
        if (lower === 'char' || lower === 'character') {
          if (context.characterName.length > 0) {
            return context.characterName;
          }
          return match;
        }
        if (lower === 'user') {
          if (context.userName.length > 0) {
            return context.userName;
          }
          return match;
        }
        if (lower === 'description') {
          if (context.description !== undefined && context.description.length > 0) {
            return context.description;
          }
          return match;
        }
        if (lower === 'personality') {
          if (context.personality !== undefined && context.personality.length > 0) {
            return context.personality;
          }
          return match;
        }
        if (lower === 'scenario') {
          if (context.scenario !== undefined && context.scenario.length > 0) {
            return context.scenario;
          }
          return match;
        }
        if (lower === 'mes_example' || lower === 'mesexample') {
          if (context.mesExample !== undefined && context.mesExample.length > 0) {
            return context.mesExample;
          }
          return match;
        }
        if (lower === 'last_message' || lower === 'lastmessage') {
          if (context.lastMessage !== undefined && context.lastMessage.length > 0) {
            return context.lastMessage;
          }
          return match;
        }
        if (lower === 'original') {
          if (context.originalContent !== undefined) {
            return context.originalContent;
          }
          return match;
        }
        return match;
      }
    );

    return result;
  }
}
