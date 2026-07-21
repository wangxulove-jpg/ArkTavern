/**
 * ChatRichText 聊天富文本渲染组件
 *
 * 职责:
 * - 接收原始文本和发送者信息,解析为富文本片段并渲染
 * - 支持 Markdown 子集(加粗/斜体/删除线/代码/链接/引用/列表)
 * - 支持角色对白差异化配色
 * - 支持流式渲染(节流刷新)
 * - 支持长按复制原始文本
 * - 支持字体大小/行间距缩放
 *
 * 不负责:
 * - 消息气泡背景/布局(由调用方提供)
 * - 头像/名称显示(由调用方提供)
 * - 设置 UI(由 AppSettingsPage 提供)
 *
 * 使用方式:
 *   ChatRichText({
 *     content: message.content,
 *     senderType: message.senderType,
 *     senderCharacterId: message.senderCharacterId,
 *     isStreaming: false,
 *     settings: chatTextStyleSettings,
 *     selectable: true
 *   })
 */

import { ChatTextSegment, parseChatText, ChatTextParserOptions } from '../parser/ChatTextParser';
import { getCharacterColor } from '../utils/ChatPalette';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';

/** 发送者类型 */
export type ChatSenderType = 'user' | 'assistant' | 'character' | 'narrator' | 'system';

/** 缓存条目 */
interface CacheEntry {
  readonly segments: ChatTextSegment[];
  readonly contentHash: number;
  readonly settingsVersion: number;
  readonly senderCharacterId: string;
}

/** 简单字符串哈希(FNV-1a 32位) */
function hashString(str: string): number {
  let hash: number = 2166136261;
  for (let i = 0; i < str.length; i++) {
    hash ^= str.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

@Component
export struct ChatRichText {
  /** 原始文本内容 */
  @Prop content: string = '';
  /** 发送者类型 */
  @Prop senderType: ChatSenderType = 'assistant';
  /** 发送者角色 ID(用于角色独立颜色) */
  @Prop senderCharacterId: string = '';
  /** 是否流式渲染(节流刷新) */
  @Prop isStreaming: boolean = false;
  /** 文本样式设置 */
  @Prop settings: ChatTextStyle | null = null;
  /** 是否可选择(长按复制) */
  @Prop selectable: boolean = true;

  /** 当前解析的片段(状态) */
  @State private segments: ChatTextSegment[] = [];
  /** 上次解析的内容哈希 */
  private lastContentHash: number = 0;
  /** 上次解析的设置版本 */
  private lastSettingsVersion: number = -1;
  /** 流式节流定时器 ID */
  private throttleTimerId: number = -1;
  /** 流式节流间隔(ms) */
  private static readonly THROTTLE_MS: number = 50;

  /** 解析缓存(key = content hash + settings version + senderCharacterId) */
  private static cache: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  private static readonly CACHE_MAX_SIZE: number = 100;

  aboutToAppear(): void {
    this.reparse();
  }

  aboutToDisappear(): void {
    this.clearThrottle();
  }

  /**
   * 当 content 或 settings 变化时重新解析。
   */
  aboutToReuse(): void {
    this.reparse();
  }

  /**
   * 清除节流定时器。
   */
  private clearThrottle(): void {
    if (this.throttleTimerId !== -1) {
      clearTimeout(this.throttleTimerId);
      this.throttleTimerId = -1;
    }
  }

  /**
   * 重新解析文本。
   * 流式模式下使用节流。
   */
  private reparse(): void {
    if (this.isStreaming) {
      // 流式模式:节流刷新
      this.clearThrottle();
      this.throttleTimerId = setTimeout(() => {
        this.doParse();
      }, ChatRichText.THROTTLE_MS);
    } else {
      // 非流式:立即解析
      this.clearThrottle();
      this.doParse();
    }
  }

  /**
   * 执行解析。
   * 带缓存,避免重复解析未变化的历史消息。
   */
  private doParse(): void {
    if (this.content.length === 0) {
      this.segments = [];
      return;
    }

    const settings: ChatTextStyle = this.settings !== null ? this.settings : {
      enableMarkdown: true,
      enableDialogue: true,
      enableCharacterColor: true,
      fontSize: 16,
      lineHeight: 1.5,
      quoteStyle: 'line',
      codeStyle: 'bg'
    };

    const contentHash: number = hashString(this.content);
    const settingsVersion: number = this.settings !== null ? 0 : 0; // 简化:settings 引用变化即重解析

    // 缓存命中检查
    const cacheKey: string = contentHash.toString() + '_' + this.senderCharacterId + '_' + settings.enableMarkdown + '_' + settings.enableDialogue;
    const cached: CacheEntry | undefined = ChatRichText.cache.get(cacheKey);
    if (cached !== undefined && cached.contentHash === contentHash) {
      this.segments = cached.segments;
      this.lastContentHash = contentHash;
      return;
    }

    // 解析
    const options: ChatTextParserOptions = {
      enableMarkdown: settings.enableMarkdown,
      enableDialogue: settings.enableDialogue
    };
    const parsed: ChatTextSegment[] = parseChatText(this.content, options);

    // 缓存
    if (ChatRichText.cache.size >= ChatRichText.CACHE_MAX_SIZE) {
      // 简单淘汰:清空一半
      ChatRichText.cache.clear();
    }
    ChatRichText.cache.set(cacheKey, {
      segments: parsed,
      contentHash,
      settingsVersion,
      senderCharacterId: this.senderCharacterId
    });

    this.segments = parsed;
    this.lastContentHash = contentHash;
  }

  /**
   * 获取片段对应的字体颜色。
   */
  private getSegmentColor(seg: ChatTextSegment): ResourceColor {
    // 角色独立颜色优先(对白)
    if (seg.dialogue && this.senderType === 'character' && this.settings !== null && this.settings.enableCharacterColor && this.senderCharacterId.length > 0) {
      // 注意:ArkUI 的 .fontColor 不支持直接传 hex 字符串给 ResourceColor,
      // 但我们可以返回 string 类型(ResourceColor 支持 string)
      return getCharacterColor(this.senderCharacterId);
    }

    switch (seg.colorRole) {
      case 'emphasis':
        return $r('app.color.chat_text_emphasis');
      case 'secondary':
        return $r('app.color.chat_text_secondary');
      case 'dialogue':
        return $r('app.color.chat_text_dialogue');
      case 'narrator':
        return $r('app.color.chat_text_narrator');
      case 'action':
        return $r('app.color.chat_text_action');
      case 'code':
        return $r('app.color.chat_text_code');
      case 'link':
        return $r('app.color.chat_text_link');
      case 'quote':
        return $r('app.color.chat_text_quote');
      case 'system':
        return $r('app.color.chat_text_system');
      case 'character':
        return $r('app.color.chat_text_dialogue');
      default:
        // 根据 senderType 选择默认色
        if (this.senderType === 'user') {
          return $r('app.color.chat_user_text');
        } else if (this.senderType === 'system') {
          return $r('app.color.chat_text_system');
        }
        return $r('app.color.chat_text_primary');
    }
  }

  build() {
    if (this.segments.length === 0) {
      // 空内容占位
      Text('')
        .fontSize(this.settings !== null ? this.settings.fontSize : 16)
        .height(0)
    } else {
      // 使用 Text + ForEach Span 的方式渲染富文本
      Text() {
        ForEach(this.segments, (seg: ChatTextSegment, index: number) => {
          Span(seg.text)
            .fontColor(this.getSegmentColor(seg))
            .fontSize(this.settings !== null ? this.settings.fontSize : 16)
            .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(seg.italic ? FontStyle.Italic : FontStyle.Normal)
            .decoration({
              type: seg.strike ? TextDecorationType.LineThrough : TextDecorationType.None,
              color: this.getSegmentColor(seg)
            })
        }, (seg: ChatTextSegment, index: number) => index.toString() + '_' + seg.text.length.toString())
      }
      .lineHeight((this.settings !== null ? this.settings.fontSize : 16) * (this.settings !== null ? this.settings.lineHeight : 1.5))
      .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
    }
  }
}
