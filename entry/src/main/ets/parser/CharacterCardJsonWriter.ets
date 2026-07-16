/**
 * CharacterCardJsonWriter 角色卡 JSON 导出器
 *
 * 将 Character 模型序列化为 ArkTavern schemaVersion=1 格式。
 * 不包含 API Key、模型配置、聊天记录或本地绝对路径。
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/存储/数据库
 * - 纯逻辑序列化,可本地单元测试
 */

import { Character } from '../models/Character';

/** ArkTavern 导出格式:角色数据字段 */
export interface ArkTavernCharacterData {
  name: string;
  description: string;
  personality: string;
  scenario: string;
  firstMessage: string;
  systemPrompt: string;
  avatarUri: string;
  createdAt: number;
  updatedAt: number;
}

/** ArkTavern 导出格式 */
export interface ArkTavernCharacterCard {
  /** 格式版本,固定为 1 */
  schemaVersion: number;
  /** 角色数据 */
  character: ArkTavernCharacterData;
}

/**
 * 将 Character 序列化为 ArkTavern JSON 字符串。
 * 不包含 id(导入时重新生成)、API Key、模型配置、聊天记录。
 *
 * @param character 角色数据
 * @returns 格式化 JSON 字符串
 */
export function writeCharacterToJson(character: Character): string {
  const charData: ArkTavernCharacterData = {
    name: character.name,
    description: character.description,
    personality: character.personality,
    scenario: character.scenario,
    firstMessage: character.firstMessage,
    systemPrompt: character.systemPrompt,
    avatarUri: character.avatarUri,
    createdAt: character.createdAt,
    updatedAt: character.updatedAt
  };
  const card: ArkTavernCharacterCard = {
    schemaVersion: 1,
    character: charData
  };
  return JSON.stringify(card, null, 2);
}

/** 敏感字段黑名单,导出时不应出现在 JSON 中 */
const SENSITIVE_KEYS: string[] = [
  'apiKey', 'api_key', 'secret', 'authorization',
  'token', 'password', 'key', 'credential'
];

/**
 * 验证导出 JSON 不包含敏感字段。
 * 用于测试验证,确保导出内容安全。
 *
 * @param jsonString 导出 JSON 字符串
 * @returns 包含敏感字段的键名列表,为空表示安全
 */
export function findSensitiveKeys(jsonString: string): string[] {
  const lower: string = jsonString.toLowerCase();
  const found: string[] = [];
  for (let i = 0; i < SENSITIVE_KEYS.length; i++) {
    const key: string = SENSITIVE_KEYS[i];
    // 仅匹配 JSON 键名(用 "key": 模式,区分键名和值)
    const keyWithColon: string = '"' + key.toLowerCase() + '":';
    if (lower.includes(keyWithColon)) {
      found.push(key);
    }
  }
  return found;
}

/**
 * 生成安全的导出文件名。
 * 移除非法字符,限制长度,确保文件系统兼容。
 *
 * @param characterName 角色名称
 * @returns 安全的文件名(不含扩展名)
 */
export function sanitizeFileName(characterName: string): string {
  // 移除或替换文件系统非法字符
  let sanitized: string = characterName.replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
  // 移除首尾空格和点
  sanitized = sanitized.trim().replace(/^\.+|\.+$/g, '');
  // 限制长度(留出扩展名空间)
  if (sanitized.length > 200) {
    sanitized = sanitized.substring(0, 200);
  }
  // 空名称兜底
  if (sanitized.length === 0) {
    sanitized = 'character';
  }
  return sanitized + '.json';
}