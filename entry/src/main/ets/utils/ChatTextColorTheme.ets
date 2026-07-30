/**
 * ChatTextColorTheme 单人聊天字体配色主题
 *
 * 职责:
 * - 定义字体配色模式(AUTO / LIGHT / DARK / CUSTOM)
 * - 定义 Markdown 渲染器颜色主题接口
 * - 提供预设主题(LIGHT / DARK)与默认颜色值
 *
 * 设计约束:
 * - 颜色值只允许 #RRGGBB 格式,禁止 Alpha 通道
 * - AUTO 模式返回 null,表示使用 ChatRichText 默认资源颜色($r('app.color.*'))
 * - LIGHT / DARK / CUSTOM 返回具体主题,覆盖默认资源颜色
 * - 不修改 Markdown 解析行为、节点结构、字体粗细、链接行为或换行逻辑
 * - 与气泡不透明度(chatBubbleOpacity)完全独立
 *
 * 不负责:
 * - 颜色选择 UI(由 ChatPage 显示设置面板提供)
 * - 持久化(本阶段仅页面生命周期内保存)
 * - 气泡背景透明度(由 ChatMessageBubble 通过 bubbleOpacity 控制)
 */

/**
 * 字体配色模式。
 * - AUTO:使用 ChatRichText 默认资源颜色(不覆盖)
 * - LIGHT:适合深色或高度透明背景,文字偏浅
 * - DARK:适合浅色气泡背景,文字偏深
 * - CUSTOM:使用用户选择的颜色值
 */
export class ChatTextColorMode {
  static readonly AUTO: string = 'AUTO';
  static readonly LIGHT: string = 'LIGHT';
  static readonly DARK: string = 'DARK';
  static readonly CUSTOM: string = 'CUSTOM';
}

/**
 * Markdown 渲染器颜色主题。
 *
 * 传入 ChatRichText 后,仅覆盖片段颜色查询逻辑(getSegmentColor),
 * 不改变解析、节点结构、字体粗细、链接行为或换行逻辑。
 *
 * 颜色值格式:#RRGGBB(禁止 #AARRGGBB / rgba alpha < 1)。
 * bodyColor 用于普通正文、列表正文、普通段落。
 * secondaryColor 用于旁白、引用、辅助说明、次级文字。
 * accentColor 用于强调文字、Markdown 链接、标题、当前显示为蓝色的语义文本。
 * linkColor 用于链接(若与 accentColor 不同)。
 * codeColor 用于行内代码。
 * quoteColor 用于引用块。
 * userColor 用于用户消息正文。
 */
export interface ChatMarkdownColorTheme {
  /** 助手普通正文颜色 */
  readonly bodyColor: string;
  /** 次级文字颜色(旁白/引用/辅助说明) */
  readonly secondaryColor: string;
  /** Markdown 强调色(强调/链接/标题) */
  readonly accentColor: string;
  /** 链接颜色(若与 accentColor 相同可传同一值) */
  readonly linkColor: string;
  /** 行内代码颜色 */
  readonly codeColor: string;
  /** 引用块颜色 */
  readonly quoteColor: string;
  /** 用户消息正文颜色 */
  readonly userColor: string;
}

/** 默认助手正文颜色(DARK 模式色值) */
export const DEFAULT_ASSISTANT_TEXT_COLOR: string = '#171717';
/** 默认 Markdown 强调色(品牌蓝) */
export const DEFAULT_MARKDOWN_ACCENT_COLOR: string = '#1976D2';
/** 默认用户消息文字颜色 */
export const DEFAULT_USER_TEXT_COLOR: string = '#FFFFFF';
/** 默认次级文字颜色 */
export const DEFAULT_SECONDARY_TEXT_COLOR: string = '#4B5563';

/** LIGHT 模式正文颜色 */
export const LIGHT_ASSISTANT_TEXT_COLOR: string = '#FFFFFF';
/** LIGHT 模式次级文字颜色 */
export const LIGHT_SECONDARY_TEXT_COLOR: string = '#E5E7EB';
/** LIGHT 模式 Markdown 强调色(浅蓝) */
export const LIGHT_MARKDOWN_ACCENT_COLOR: string = '#90CAF9';
/** LIGHT 模式用户消息文字颜色 */
export const LIGHT_USER_TEXT_COLOR: string = '#FFFFFF';

/** Hex 颜色正则(#RRGGBB,禁止 Alpha) */
const HEX_REGEX: RegExp = /^#[0-9A-Fa-f]{6}$/;

/**
 * 校验颜色值是否为合法 #RRGGBB 格式。
 * 禁止 Alpha 通道(#AARRGGBB)与 CSS 函数(rgba/hsla)。
 */
export function isValidHexColor(color: string): boolean {
  return typeof color === 'string' && HEX_REGEX.test(color);
}

/**
 * 将合法 Hex 颜色标准化为大写。
 * 非法值返回 null,调用方不应提交。
 */
export function normalizeHexColor(color: string): string | null {
  if (!isValidHexColor(color)) {
    return null;
  }
  return color.toUpperCase();
}

/**
 * 构造 LIGHT 模式主题(适合深色或高度透明背景)。
 */
export function getLightColorTheme(): ChatMarkdownColorTheme {
  return {
    bodyColor: LIGHT_ASSISTANT_TEXT_COLOR,
    secondaryColor: LIGHT_SECONDARY_TEXT_COLOR,
    accentColor: LIGHT_MARKDOWN_ACCENT_COLOR,
    linkColor: LIGHT_MARKDOWN_ACCENT_COLOR,
    codeColor: LIGHT_ASSISTANT_TEXT_COLOR,
    quoteColor: LIGHT_SECONDARY_TEXT_COLOR,
    userColor: LIGHT_USER_TEXT_COLOR
  };
}

/**
 * 构造 DARK 模式主题(适合浅色气泡背景)。
 */
export function getDarkColorTheme(): ChatMarkdownColorTheme {
  return {
    bodyColor: DEFAULT_ASSISTANT_TEXT_COLOR,
    secondaryColor: DEFAULT_SECONDARY_TEXT_COLOR,
    accentColor: DEFAULT_MARKDOWN_ACCENT_COLOR,
    linkColor: DEFAULT_MARKDOWN_ACCENT_COLOR,
    codeColor: DEFAULT_ASSISTANT_TEXT_COLOR,
    quoteColor: DEFAULT_SECONDARY_TEXT_COLOR,
    userColor: DEFAULT_USER_TEXT_COLOR
  };
}

/**
 * 构造 CUSTOM 模式主题(使用用户选择的颜色值)。
 * 传入的颜色值应已通过 isValidHexColor 校验。
 * 非法值回退为对应默认值,避免渲染异常。
 */
export function getCustomColorTheme(
  bodyColor: string,
  secondaryColor: string,
  accentColor: string,
  userColor: string
): ChatMarkdownColorTheme {
  return {
    bodyColor: isValidHexColor(bodyColor) ? bodyColor.toUpperCase() : DEFAULT_ASSISTANT_TEXT_COLOR,
    secondaryColor: isValidHexColor(secondaryColor) ? secondaryColor.toUpperCase() : DEFAULT_SECONDARY_TEXT_COLOR,
    accentColor: isValidHexColor(accentColor) ? accentColor.toUpperCase() : DEFAULT_MARKDOWN_ACCENT_COLOR,
    linkColor: isValidHexColor(accentColor) ? accentColor.toUpperCase() : DEFAULT_MARKDOWN_ACCENT_COLOR,
    codeColor: isValidHexColor(bodyColor) ? bodyColor.toUpperCase() : DEFAULT_ASSISTANT_TEXT_COLOR,
    quoteColor: isValidHexColor(secondaryColor) ? secondaryColor.toUpperCase() : DEFAULT_SECONDARY_TEXT_COLOR,
    userColor: isValidHexColor(userColor) ? userColor.toUpperCase() : DEFAULT_USER_TEXT_COLOR
  };
}
