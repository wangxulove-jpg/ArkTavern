/**
 * MacroContext 宏替换上下文
 *
 * 纯数据模型,提供宏替换所需的上下文信息。
 * 不依赖 ArkUI,不读取 Preferences,不访问页面或系统时间。
 *
 * 当前仅包含角色名和用户名,后续可扩展。
 */

/**
 * 宏替换上下文。
 */
export interface MacroContext {
  /** 当前角色名称(为空时角色宏保持原样) */
  readonly characterName: string;
  /** 当前用户名称(为空时用户宏保持原样) */
  readonly userName: string;
}

/**
 * 创建宏替换上下文。
 */
export function createMacroContext(characterName: string, userName: string): MacroContext {
  return {
    characterName: characterName,
    userName: userName
  };
}
