/**
 * Character 角色模型
 *
 * 定义角色数据结构和校验规则,本次不做 PNG 角色卡、Lorebook、Swipe 等。
 * 不依赖 ArkUI,可用于服务层和持久化层。
 *
 * 约束:
 * - name 必填,最长 100 字符
 * - 各字段最长 5000 字符
 * - 不加入 Lorebook/Swipe/PNG 元数据等后续字段
 */

/**
 * 角色数据模型。
 */
export interface Character {
  /** 唯一标识(UUID v4) */
  readonly id: string;
  /** 角色名称(必填,最长 100 字符) */
  readonly name: string;
  /** 角色描述 */
  readonly description: string;
  /** 性格描述 */
  readonly personality: string;
  /** 场景/世界观 */
  readonly scenario: string;
  /** 开场白(首次进入聊天时显示) */
  readonly firstMessage: string;
  /** 系统提示词 */
  readonly systemPrompt: string;
  /** 头像 URI(可选,本次不实现图片导入) */
  readonly avatarUri: string;
  /** 创建时间戳(毫秒) */
  readonly createdAt: number;
  /** 更新时间戳(毫秒) */
  readonly updatedAt: number;
}

const MAX_NAME_LENGTH: number = 100;
const MAX_FIELD_LENGTH: number = 5000;

/**
 * 创建新角色,自动填充 id 和时间戳。
 */
export function createCharacter(
  id: string,
  name: string,
  description: string = '',
  personality: string = '',
  scenario: string = '',
  firstMessage: string = '',
  systemPrompt: string = '',
  avatarUri: string = ''
): Character {
  const now: number = Date.now();
  return {
    id: id,
    name: name.trim(),
    description: description.trim(),
    personality: personality.trim(),
    scenario: scenario.trim(),
    firstMessage: firstMessage.trim(),
    systemPrompt: systemPrompt.trim(),
    avatarUri: avatarUri.trim(),
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 校验角色数据。
 * @returns 错误信息字符串,如果校验通过返回 null
 */
export function validateCharacter(character: Character): string | null {
  if (character.name.trim().length === 0) {
    return '角色名称不能为空';
  }
  if (character.name.length > MAX_NAME_LENGTH) {
    return '角色名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (character.description.length > MAX_FIELD_LENGTH) {
    return '角色描述不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.personality.length > MAX_FIELD_LENGTH) {
    return '性格描述不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.scenario.length > MAX_FIELD_LENGTH) {
    return '场景描述不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.firstMessage.length > MAX_FIELD_LENGTH) {
    return '开场白不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.systemPrompt.length > MAX_FIELD_LENGTH) {
    return 'System Prompt 不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  return null;
}

/**
 * 更新角色时可选字段。
 */
export interface CharacterUpdates {
  name?: string;
  description?: string;
  personality?: string;
  scenario?: string;
  firstMessage?: string;
  systemPrompt?: string;
  avatarUri?: string;
}

/**
 * 不可变更新角色字段。
 * 返回新 Character 对象,不修改原对象。
 */
export function updateCharacter(
  character: Character,
  updates: CharacterUpdates
): Character {
  const merged: Character = {
    id: character.id,
    name: updates.name !== undefined ? updates.name.trim() : character.name,
    description: updates.description !== undefined ? updates.description.trim() : character.description,
    personality: updates.personality !== undefined ? updates.personality.trim() : character.personality,
    scenario: updates.scenario !== undefined ? updates.scenario.trim() : character.scenario,
    firstMessage: updates.firstMessage !== undefined ? updates.firstMessage.trim() : character.firstMessage,
    systemPrompt: updates.systemPrompt !== undefined ? updates.systemPrompt.trim() : character.systemPrompt,
    avatarUri: updates.avatarUri !== undefined ? updates.avatarUri.trim() : character.avatarUri,
    createdAt: character.createdAt,
    updatedAt: Date.now()
  };
  return merged;
}

/**
 * 构建角色聊天上下文的 System 消息内容。
 * 优先使用 systemPrompt;如果为空,组合 name/description/personality/scenario。
 */
export function buildCharacterSystemContent(character: Character): string {
  if (character.systemPrompt.trim().length > 0) {
    return character.systemPrompt;
  }
  const parts: string[] = [];
  if (character.name.trim().length > 0) {
    parts.push('你是' + character.name);
  }
  if (character.description.trim().length > 0) {
    parts.push(character.description);
  }
  if (character.personality.trim().length > 0) {
    parts.push('性格: ' + character.personality);
  }
  if (character.scenario.trim().length > 0) {
    parts.push('场景: ' + character.scenario);
  }
  return parts.join('\n');
}