/**
 * WorldChatImportPromptAssembler 单聊导入世界 AI 分析 Prompt 组装器
 *
 * 职责:
 * - 根据角色卡 + 单聊对话记录,构建让 AI 分析"导入世界"所需信息的 Prompt
 * - 解析 AI 返回 JSON:
 *   {
 *     "location": { "name": "...", "description": "..." },
 *     "characterOptimization": "角色在世界中的设定优化建议"
 *   }
 * - 纯逻辑,不调用模型、不依赖数据库
 */

import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequest } from '../../models/ChatRequest';
import { Character } from '../../models/Character';

export const WORLD_CHAT_IMPORT_PROMPT_VERSION: string = 'world-chat-import-v1';

/** 参与 AI 分析的最近消息上限 */
export const WORLD_CHAT_IMPORT_TRANSCRIPT_MAX: number = 40;
/** 每条消息参与分析的最大字符数 */
export const WORLD_CHAT_IMPORT_MESSAGE_MAX_CHARS: number = 300;
/** AI 输出优化建议最大长度 */
export const WORLD_CHAT_IMPORT_OPTIMIZATION_MAX: number = 2000;

export interface WorldChatImportPromptResult {
  readonly messages: ChatMessage[];
  readonly temperature: number;
  readonly maxTokens: number;
}

export interface WorldChatImportAiOutput {
  readonly locationName: string;
  readonly locationDescription: string;
  readonly characterOptimization: string;
}

/** 参与 AI 分析的单聊消息(已截断) */
export interface WorldChatImportTranscriptMessage {
  readonly isUser: boolean;
  readonly content: string;
}

export class WorldChatImportPromptAssembler {
  buildImportPrompt(
    character: Character,
    playerName: string,
    transcript: WorldChatImportTranscriptMessage[]
  ): WorldChatImportPromptResult {
    const card: string = this.formatCharacterCard(character);
    const transcriptText: string = this.formatTranscript(transcript, playerName, character.name);

    const now: number = Date.now();
    const systemMsg: ChatMessage = createChatMessage(
      'sys_chat_import',
      ChatRole.System,
      '你是世界模式角色导入顾问,精通角色设定分析与叙事世界构建。' +
        '你擅长从角色卡与既有聊天记录中提炼角色的活动地点、关系与性格细节,并把单聊内容合理转译为世界模式的叙事背景。',
      now
    );

    const userContent: string =
      '请根据下面的角色卡与聊天记录,为"把该角色及其聊天经历导入世界模式"生成以下信息。' +
      '输出结果仅包含以下 JSON 格式(不要添加额外文字、不要使用 Markdown 代码块):\n' +
      '{\n' +
      '  "location": {"name": "地点名称","description": "地点描述"},\n' +
      '  "characterOptimization": "角色在世界中的设定优化建议"\n' +
      '}\n' +
      '- location.name:该角色聊天中主要活动或适合作为其初始场景的地点,中文,2-10 字\n' +
      '- location.description:该地点的场景描述,结合聊天中体现的环境与事件,80-200 字\n' +
      '- characterOptimization:基于聊天记录优化该角色在世界中的设定说明,补充聊天中体现出的性格细节、与{{user}}的关系、经历事实;' +
      '以第三人称客观描述,200-500 字;只依据聊天与角色卡证据,不得虚构聊天中不存在的事实\n' +
      '\n' +
      '角色卡:\n' +
      card +
      '\n\n聊天记录(按时间顺序):\n' +
      transcriptText;

    const userMsg: ChatMessage = createChatMessage(
      'user_chat_import',
      ChatRole.User,
      userContent,
      now + 1
    );

    return {
      messages: [systemMsg, userMsg],
      temperature: 0.5,
      maxTokens: 2048
    };
  }

  /** 解析 AI 返回内容,失败返回 null */
  parseOutput(raw: string): WorldChatImportAiOutput | null {
    let text: string = raw.trim();
    const fenceMatch: RegExpMatchArray | null = text.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (fenceMatch !== null) {
      text = fenceMatch[1].trim();
    }
    const jsonMatch: RegExpMatchArray | null = text.match(/\{[\s\S]*\}/);
    if (jsonMatch !== null) {
      text = jsonMatch[0];
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const locObj: Record<string, Object> | undefined =
        parsed['location'] as Record<string, Object> | undefined;
      const locationName: string = locObj !== undefined
        ? this.cleanString(locObj['name']) : '';
      const locationDescription: string = locObj !== undefined
        ? this.cleanString(locObj['description']) : '';
      const optimization: string = this.cleanString(parsed['characterOptimization']);
      if (locationName.length === 0 && optimization.length === 0) {
        return null;
      }
      return {
        locationName: locationName,
        locationDescription: locationDescription,
        characterOptimization: this.truncate(optimization, WORLD_CHAT_IMPORT_OPTIMIZATION_MAX)
      };
    } catch (_e) {
      return null;
    }
  }

  /** 截断到指定长度 */
  truncate(value: string, max: number): string {
    if (value.length <= max) {
      return value;
    }
    return value.substring(0, max);
  }

  private cleanString(value: Object | undefined): string {
    if (typeof value !== 'string') {
      return '';
    }
    return value.trim();
  }

  private formatCharacterCard(character: Character): string {
    const desc: string = this.truncate(character.description, 500);
    const personality: string = this.truncate(character.personality, 300);
    const scenario: string = this.truncate(character.scenario, 300);
    const parts: string[] = [];
    parts.push('名称:' + character.name);
    if (desc.length > 0) {
      parts.push('描述:' + desc);
    }
    if (personality.length > 0) {
      parts.push('性格:' + personality);
    }
    if (scenario.length > 0) {
      parts.push('场景/背景:' + scenario);
    }
    return parts.join('\n');
  }

  private formatTranscript(
    transcript: WorldChatImportTranscriptMessage[],
    playerName: string,
    characterName: string
  ): string {
    const startIndex: number = Math.max(0, transcript.length - WORLD_CHAT_IMPORT_TRANSCRIPT_MAX);
    const parts: string[] = [];
    for (let i = startIndex; i < transcript.length; i++) {
      const msg: WorldChatImportTranscriptMessage = transcript[i];
      const label: string = msg.isUser
        ? (playerName.length > 0 ? playerName : '用户')
        : characterName;
      parts.push('[' + label + ']: ' + msg.content);
    }
    if (parts.length === 0) {
      return '(无有效聊天内容)';
    }
    return parts.join('\n');
  }
}
