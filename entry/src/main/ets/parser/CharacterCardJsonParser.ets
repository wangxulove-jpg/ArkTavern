/**
 * CharacterCardJsonParser 角色卡 JSON 解析器
 *
 * 解析 ArkTavern schemaVersion=1、SillyTavern V2 (chara_card_v2)、V3 (chara_card_v3) 格式。
 * 返回统一的 ParsedCharacterCard 中间格式,由 CharacterService 转换为内部 Character 模型。
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/存储/数据库
 * - 纯逻辑解析,可本地单元测试
 * - 不抛出原始 JSON 解析异常,返回明确错误类型
 */

/** 解析后的角色卡中间格式 */
export interface ParsedCharacterCard {
  /** 角色名称(必填) */
  name: string;
  /** 角色描述 */
  description: string;
  /** 性格描述 */
  personality: string;
  /** 场景/世界观 */
  scenario: string;
  /** 开场白 */
  firstMessage: string;
  /** 系统提示词 */
  systemPrompt: string;
  /** 头像 URI */
  avatarUri: string;
  /** 来源格式标识 */
  sourceFormat: string;
}

/** 解析结果:成功或失败 */
export class ParseResult {
  readonly success: boolean;
  readonly card: ParsedCharacterCard | null;
  readonly error: string | null;

  private constructor(success: boolean, card: ParsedCharacterCard | null, error: string | null) {
    this.success = success;
    this.card = card;
    this.error = error;
  }

  static ok(card: ParsedCharacterCard): ParseResult {
    return new ParseResult(true, card, null);
  }

  static fail(error: string): ParseResult {
    return new ParseResult(false, null, error);
  }
}

/** 最大文件大小:10MB */
const MAX_FILE_SIZE_BYTES: number = 10 * 1024 * 1024;

/** 字段最大长度:5000 字符(与 Character 模型一致) */
const MAX_FIELD_LENGTH: number = 5000;

/**
 * 解析角色卡 JSON 字符串。
 * 自动识别 ArkTavern schemaVersion=1、V2 (chara_card_v2)、V3 (chara_card_v3)。
 *
 * @param jsonString 原始 JSON 字符串
 * @returns ParseResult 包含解析结果或错误信息
 */
export function parseCharacterJson(jsonString: string): ParseResult {
  // 检查文件大小
  if (jsonString.length > MAX_FILE_SIZE_BYTES) {
    return ParseResult.fail('文件过大,不能超过 10MB');
  }

  // 解析 JSON
  let root: Object;
  try {
    root = JSON.parse(jsonString) as Object;
  } catch (e) {
    return ParseResult.fail('文件格式无效,无法解析 JSON');
  }

  if (typeof root !== 'object' || root === null) {
    return ParseResult.fail('JSON 顶层必须是对象');
  }

  const rootObj: Record<string, Object> = root as Record<string, Object>;

  // 识别格式并解析
  if (typeof rootObj['schemaVersion'] === 'number') {
    return parseArkTavernFormat(rootObj);
  }

  if (typeof rootObj['spec'] === 'string') {
    const spec: string = rootObj['spec'] as string;
    if (spec === 'chara_card_v2' || spec === 'chara_card_v3') {
      return parseCharaCardFormat(rootObj, spec);
    }
    return ParseResult.fail('不支持的角色卡版本: ' + spec);
  }

  return ParseResult.fail('无法识别的角色卡格式,缺少 schemaVersion 或 spec 字段');
}

/**
 * 解析 ArkTavern schemaVersion=1 格式。
 */
function parseArkTavernFormat(root: Record<string, Object>): ParseResult {
  const schemaVersion: number = root['schemaVersion'] as number;
  if (schemaVersion !== 1) {
    return ParseResult.fail('不支持的 ArkTavern schemaVersion: ' + String(schemaVersion));
  }

  const character: Object | undefined = root['character'] as Object | undefined;
  if (typeof character !== 'object' || character === null) {
    return ParseResult.fail('缺少 character 字段');
  }
  const charObj: Record<string, Object> = character as Record<string, Object>;

  return buildCard(
    charObj,
    'name', 'description', 'personality', 'scenario',
    'firstMessage', 'systemPrompt', 'avatarUri',
    'arktavern_v1'
  );
}

/**
 * 解析 V2/V3 chara_card 格式。
 * V2 和 V3 的数据结构相同,仅 spec 和 spec_version 不同。
 */
function parseCharaCardFormat(root: Record<string, Object>, spec: string): ParseResult {
  const data: Object | undefined = root['data'] as Object | undefined;
  if (typeof data !== 'object' || data === null) {
    return ParseResult.fail('缺少 data 字段');
  }
  const dataObj: Record<string, Object> = data as Record<string, Object>;

  return buildCard(
    dataObj,
    'name', 'description', 'personality', 'scenario',
    'first_mes', 'system_prompt', 'avatarUri',
    spec
  );
}

/**
 * 从原始字段对象构建 ParsedCharacterCard。
 * 各格式的字段名映射由参数指定。
 */
function buildCard(
  obj: Record<string, Object>,
  nameKey: string,
  descKey: string,
  personalityKey: string,
  scenarioKey: string,
  firstMessageKey: string,
  systemPromptKey: string,
  avatarKey: string,
  sourceFormat: string
): ParseResult {
  // name 必填
  const rawName: string = getStringField(obj, nameKey);
  if (rawName.trim().length === 0) {
    return ParseResult.fail('角色缺少名称(name),无法导入');
  }

  const name: string = truncateField(rawName.trim(), MAX_FIELD_LENGTH);
  const description: string = truncateField(getStringField(obj, descKey), MAX_FIELD_LENGTH);
  const personality: string = truncateField(getStringField(obj, personalityKey), MAX_FIELD_LENGTH);
  const scenario: string = truncateField(getStringField(obj, scenarioKey), MAX_FIELD_LENGTH);
  const firstMessage: string = truncateField(getStringField(obj, firstMessageKey), MAX_FIELD_LENGTH);
  const systemPrompt: string = truncateField(getStringField(obj, systemPromptKey), MAX_FIELD_LENGTH);
  const avatarUri: string = truncateField(getStringField(obj, avatarKey), MAX_FIELD_LENGTH);

  return ParseResult.ok({
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    systemPrompt: systemPrompt,
    avatarUri: avatarUri,
    sourceFormat: sourceFormat
  });
}

/**
 * 从对象中安全获取字符串字段。
 * 字段不存在或类型错误时返回空字符串。
 */
function getStringField(obj: Record<string, Object>, key: string): string {
  const value: Object | undefined = obj[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

/**
 * 截断过长的字段。
 */
function truncateField(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  return value.substring(0, maxLength);
}