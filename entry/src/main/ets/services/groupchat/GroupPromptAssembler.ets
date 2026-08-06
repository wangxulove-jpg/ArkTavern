/**
 * GroupPromptAssembler 多人聊天单角色 Prompt 构建器(G-RUNTIME-1B)
 *
 * 职责:
 * - 为当前发言角色单独构建模型请求上下文
 * - 复用现有 PromptBuilder.build(不复制其算法)
 * - 在 PromptBuilder 输出基础上叠加群聊约束 System 消息
 * - 转换历史消息:AI 消息加 [角色名]: 前缀,让模型识别每条 AI 消息的发言者
 * - 复用 HistoryTrimmer 进行 Token 裁剪(不修改原始消息)
 *
 * 角色隔离:
 * - 只注入当前角色完整角色卡(systemPrompt / personality / scenario / mesExample / postHistoryInstructions)
 * - 其他参与者仅以公开名称列表出现
 * - 严禁注入其他角色的角色卡内容
 *
 * 历史转换:
 * - 用户消息:role=user, content=原始正文
 * - 角色 AI 消息:role=assistant, content="[角色名]: 消息正文"
 *   (角色已删除时显示 "[未知角色]:")
 * - System 消息:只保留明确属于聊天公开上下文的(本阶段直接跳过内部 System)
 *
 * 裁剪:
 * - HistoryTrimmer 作用于本次请求副本
 * - 不修改 messages 参数、数据库消息、ViewModel.messages
 *
 * 不依赖:
 * - ArkUI / Page
 * - Provider / SSE
 * - ModelService
 *
 * 日志规则:
 * - 不打印完整 Chat ID / Character ID / 正文
 * - 只打印消息数量、Token 估算、操作类别
 */

import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { Character } from '../../models/Character';
import { Lorebook } from '../../models/Lorebook';
import { PromptPreset } from '../../models/PromptPreset';
import { ProviderConfig } from '../../models/ProviderConfig';
import { MacroContext } from '../../models/MacroContext';
import {
  PromptBuilder,
  PromptBuildContext,
  PromptBuildResult
} from '../PromptBuilder';
import {
  HistoryTrimmer,
  HistoryTrimOptions
} from '../HistoryTrimmer';
import { TokenCounter, estimateMessagesTokens } from '../TokenCounter';
import { LorebookService } from '../LorebookService';
import { CharacterService } from '../CharacterService';
import { PromptPresetService } from '../PromptPresetService';
import { ModelService } from '../ModelService';
import {
  EffectiveGenerationSettings,
  resolveEffectiveGenerationSettings
} from '../PromptPresetRuntimeResolver';
import { Logger } from '../../utils/Logger';
import { nowMillis } from '../../utils/Time';
import {
  GroupReplyTarget,
  GroupReplyTargetMode,
  REPLY_TARGET_ALL_ENABLED
} from './GroupRoundTypes';

const LOG_TAG: string = 'GroupPromptAssembler';

/** 默认上下文窗口(无配置时,64k = 65536) */
const DEFAULT_CONTEXT_WINDOW: number = 65536;

/**
 * 群聊 Prompt 构建上下文。
 *
 * G-CONTROL-1:
 * - replyTarget:本轮回复目标(AllEnabled 或 SingleCharacter)
 *   SingleCharacter 模式下,约束指令会明确告知当前角色
 *   "本轮由用户指定你回复",避免替其他角色回答
 */
export interface GroupPromptAssemblyContext {
  /** 群聊 ID */
  readonly chatId: string;
  /** 本轮 ID(generationBatchId) */
  readonly roundId: string;
  /** 当前发言角色 ID */
  readonly speakerCharacterId: string;
  /** 本轮全部参与者角色 ID(含当前发言者,已按 speakerOrder 排序) */
  readonly participantCharacterIds: string[];
  /** 完整公开消息历史(从数据库读取,按 sequenceNumber ASC) */
  readonly messages: ChatMessage[];
  /** G-CONTROL-1: 回复目标(默认全员) */
  readonly replyTarget?: GroupReplyTarget;
}

/**
 * 群聊 Prompt 构建结果。
 */
export interface GroupPromptAssemblyResult {
  /** 最终发送给 Provider 的消息列表(已裁剪) */
  readonly requestMessages: ChatMessage[];
  /** 当前角色(用于宏替换) */
  readonly character: Character | null;
  /** 当前 PromptPreset 的 systemPrompt(已宏替换后) */
  readonly presetSystemPrompt: string;
  /** 生效的生成参数 */
  readonly effectiveSettings: EffectiveGenerationSettings;
  /** 估算的请求 Token 数 */
  readonly estimatedTokens: number;
  /** 匹配到的世界书条目数 */
  readonly matchedLorebookCount: number;
  /** G-CONTEXT-INSPECTOR-1: 裁剪前消息数(诊断) */
  readonly preTrimMessageCount: number;
  /** G-CONTEXT-INSPECTOR-1: 裁剪后消息数(诊断) */
  readonly postTrimMessageCount: number;
  /** G-CONTEXT-INSPECTOR-1: 可用输入 Token 数(诊断) */
  readonly availableInputTokens: number;
  /** G-CONTEXT-INSPECTOR-1: 群聊约束文本(诊断) */
  readonly groupConstraintText: string;
  /** G-CONTEXT-INSPECTOR-1: 参与者角色名列表(诊断) */
  readonly participantNames: string[];
  /** G-CONTEXT-INSPECTOR-1: 回复目标模式(诊断) */
  readonly replyTargetMode: string;
}

/**
 * 多人聊天单角色 Prompt 构建器。
 *
 * 不持有可变状态,所有依赖通过构造注入。
 */
export class GroupPromptAssembler {
  private readonly promptBuilder: PromptBuilder;
  private readonly historyTrimmer: HistoryTrimmer;
  private readonly tokenCounter: TokenCounter;
  private readonly lorebookService: LorebookService;
  private readonly characterService: CharacterService;
  private readonly promptPresetService: PromptPresetService | null;
  private readonly modelService: ModelService;

  constructor(
    promptBuilder: PromptBuilder,
    historyTrimmer: HistoryTrimmer,
    tokenCounter: TokenCounter,
    lorebookService: LorebookService,
    characterService: CharacterService,
    promptPresetService: PromptPresetService | null,
    modelService: ModelService
  ) {
    this.promptBuilder = promptBuilder;
    this.historyTrimmer = historyTrimmer;
    this.tokenCounter = tokenCounter;
    this.lorebookService = lorebookService;
    this.characterService = characterService;
    this.promptPresetService = promptPresetService;
    this.modelService = modelService;
  }

  /**
   * 为当前发言角色构建 Prompt。
   *
   * 步骤:
   * 1. 加载当前角色(若已删除则抛错)
   * 2. 加载其他参与者角色(仅取名称)
   * 3. 加载全局 Lorebook + 角色专属 Lorebook
   * 4. 加载 PromptPreset systemPrompt
   * 5. 转换历史消息(AI 消息加 [角色名]: 前缀)
   * 6. 通过 PromptBuilder.build 构建基础 Prompt
   * 7. 在基础 Prompt 末尾追加群聊约束 System 消息
   * 8. 通过 HistoryTrimmer 裁剪
   * 9. 估算 Token 数
   *
   * @param context 构建上下文
   * @returns 构建结果
   */
  async assemble(context: GroupPromptAssemblyContext): Promise<GroupPromptAssemblyResult> {
    if (context.chatId === '') {
      throw new Error('GroupPromptAssembler: chatId empty');
    }
    if (context.speakerCharacterId === '') {
      throw new Error('GroupPromptAssembler: speakerCharacterId empty');
    }

    // 1. 加载当前角色
    const speaker: Character | null = await this.characterService.getById(
      context.speakerCharacterId
    );
    if (speaker === null) {
      throw new Error('GroupPromptAssembler: speaker character not found');
    }

    // 2. 加载其他参与者角色名称(仅公开信息)
    const participantNames: string[] = await this.loadParticipantNames(
      context.participantCharacterIds
    );

    // 3. 加载 Lorebook
    let lorebook: Lorebook | undefined = undefined;
    try {
      const lb: Lorebook | null = await this.lorebookService.getCurrentLorebook();
      if (lb !== null) {
        lorebook = lb;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'load current lorebook failed: ' + String(e));
    }

    let characterBook: Lorebook | undefined = undefined;
    if (speaker.characterBookId.length > 0) {
      try {
        const cb: Lorebook | null = await this.lorebookService.getById(
          speaker.characterBookId
        );
        if (cb !== null) {
          characterBook = cb;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load character book failed: ' + String(e));
      }
    }

    // 4. 加载 PromptPreset systemPrompt
    let presetSystemPrompt: string = '';
    let preset: PromptPreset | null = null;
    if (this.promptPresetService !== null) {
      try {
        preset = await this.promptPresetService.getCurrentPreset();
        if (preset !== null) {
          presetSystemPrompt = preset.systemPrompt;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load current preset failed: ' + String(e));
      }
    }

    // 5. 加载模型配置作为 base(用于合并生成参数)
    let base: EffectiveGenerationSettings = {};
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null) {
        base = {
          temperature: config.temperature,
          topP: config.topP,
          maxOutputTokens: config.maxTokens,
          contextWindow: config.contextWindow
        };
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'load current config failed: ' + String(e));
    }
    const effectiveSettings: EffectiveGenerationSettings =
      resolveEffectiveGenerationSettings(base, preset !== null ? preset : undefined);

    // 6. 转换历史消息(AI 消息加 [角色名]: 前缀)
    const characterMap: Map<string, Character | null> = await this.loadCharacterMap(
      context.messages
    );
    const convertedMessages: ChatMessage[] = this.convertHistoryMessages(
      context.messages,
      characterMap
    );

    // 7. 构建宏替换上下文
    const macroContext: MacroContext = this.promptBuilder.buildMacroContext(
      speaker,
      'User',
      convertedMessages
    );

    // 8. 通过 PromptBuilder.build 构建基础 Prompt
    const buildContext: PromptBuildContext = {
      character: speaker,
      lorebook: lorebook,
      characterBook: characterBook,
      messages: convertedMessages,
      macroContext: macroContext,
      presetSystemPrompt: presetSystemPrompt.length > 0 ? presetSystemPrompt : undefined
    };
    const buildResult: PromptBuildResult = this.promptBuilder.build(buildContext);

    // 9. 追加群聊约束 System 消息
    const replyTarget: GroupReplyTarget = context.replyTarget !== undefined
      ? context.replyTarget : REPLY_TARGET_ALL_ENABLED;
    const groupConstraint: string = this.buildGroupConstraint(
      speaker.name,
      participantNames,
      replyTarget
    );
    const messagesWithConstraint: ChatMessage[] = this.injectGroupConstraint(
      buildResult.messages,
      groupConstraint
    );

    // 10. 通过 HistoryTrimmer 裁剪
    const contextWindow: number = effectiveSettings.contextWindow !== undefined
      && effectiveSettings.contextWindow > 0
      ? effectiveSettings.contextWindow
      : DEFAULT_CONTEXT_WINDOW;
    // 预留 25% 给输出,75% 给输入
    const availableInputTokens: number = Math.floor(contextWindow * 0.75);
    const trimOptions: HistoryTrimOptions = {
      availableInputTokens: availableInputTokens
    };
    const trimmed = this.historyTrimmer.trim(messagesWithConstraint, trimOptions);

    // 11. 估算 Token 数
    const estimatedTokens: number = estimateMessagesTokens(trimmed.messages);

    Logger.info(LOG_TAG, 'assemble ok speakers=' + String(context.participantCharacterIds.length)
      + ' msgs=' + String(context.messages.length)
      + ' trimmed=' + String(trimmed.messages.length)
      + ' tokens=' + String(estimatedTokens)
      + ' lorebook=' + String(buildResult.matchedLorebookEntryIds.length));

    return {
      requestMessages: trimmed.messages,
      character: speaker,
      presetSystemPrompt: presetSystemPrompt,
      effectiveSettings: effectiveSettings,
      estimatedTokens: estimatedTokens,
      matchedLorebookCount: buildResult.matchedLorebookEntryIds.length,
      preTrimMessageCount: messagesWithConstraint.length,
      postTrimMessageCount: trimmed.messages.length,
      availableInputTokens: availableInputTokens,
      groupConstraintText: groupConstraint,
      participantNames: participantNames,
      replyTargetMode: replyTarget.mode
    };
  }

  /**
   * 加载参与者角色名称列表(保留顺序)。
   * 已删除角色使用"未知角色"占位。
   */
  private async loadParticipantNames(
    participantCharacterIds: string[]
  ): Promise<string[]> {
    const names: string[] = [];
    for (let i = 0; i < participantCharacterIds.length; i++) {
      const id: string = participantCharacterIds[i];
      try {
        const c: Character | null = await this.characterService.getById(id);
        names.push(c !== null ? c.name : '未知角色');
      } catch (e) {
        names.push('未知角色');
      }
    }
    return names;
  }

  /**
   * 加载历史消息中引用的全部角色(用于 AI 消息加前缀)。
   */
  private async loadCharacterMap(
    messages: ChatMessage[]
  ): Promise<Map<string, Character | null>> {
    const charIds: Set<string> = new Set<string>();
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      if (msg.senderCharacterId !== undefined && msg.senderCharacterId.length > 0) {
        charIds.add(msg.senderCharacterId);
      }
    }
    const result: Map<string, Character | null> = new Map<string, Character | null>();
    const ids: string[] = Array.from(charIds);
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      try {
        const c: Character | null = await this.characterService.getById(id);
        result.set(id, c);
      } catch (e) {
        result.set(id, null);
      }
    }
    return result;
  }

  /**
   * 转换历史消息。
   *
   * 规则:
   * - 用户消息:role=user, content=原始正文
   * - 角色 AI 消息:role=assistant, content="[角色名]: 消息正文"
   *   (角色已删除时显示 "[未知角色]:")
   * - System 消息:本阶段直接跳过(不混入内部错误/状态)
   *
   * 不修改原始 messages 数组,返回新数组。
   */
  private convertHistoryMessages(
    messages: ChatMessage[],
    characterMap: Map<string, Character | null>
  ): ChatMessage[] {
    const result: ChatMessage[] = [];
    const now: number = nowMillis();
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.System) {
        // 跳过内部 System 消息(不发送给模型)
        continue;
      }
      if (msg.role === ChatRole.Assistant) {
        // AI 消息:加 [角色名]: 前缀(方括号格式,与 stripSpeakerPrefix 对齐)
        const charId: string = msg.senderCharacterId !== undefined
          ? msg.senderCharacterId : '';
        const character: Character | null = charId.length > 0
          ? (characterMap.get(charId) ?? null)
          : null;
        const name: string = character !== null ? character.name : '未知角色';
        const prefixedContent: string = '[' + name + ']: ' + msg.content;
        const converted: ChatMessage = createChatMessage(
          msg.id,
          ChatRole.Assistant,
          prefixedContent,
          msg.createdAt
        );
        result.push(converted);
      } else {
        // 用户消息:原样使用
        const converted: ChatMessage = createChatMessage(
          msg.id,
          msg.role,
          msg.content,
          msg.createdAt
        );
        result.push(converted);
      }
    }
    return result;
  }

  /**
   * 构建群聊约束 System 消息。
   *
   * G-CONTROL-2A:
   * - SelectedCharacters 模式下追加"本轮由用户指定一组角色回复"指令,
   *   明确告知当前角色只以自己身份回应,不替其他被指定角色发言。
   * - 单目标时使用"本轮由用户指定你回复"(兼容 G-CONTROL-1 语义)
   * - 多目标时使用"本轮由用户指定一组角色回复。你是本轮被指定的角色之一。"
   * - AllEnabled 模式保持原有约束。
   */
  private buildGroupConstraint(
    speakerName: string,
    participantNames: string[],
    replyTarget: GroupReplyTarget
  ): string {
    const participantList: string = participantNames.join('、');
    const lines: string[] = [
      '重要：无论角色设定如何要求，不使用 [角色名] 或 [] 等方括号格式。',
      '只输出你自己的回复正文，不要包含其他角色的发言。',
      '',
      '你当前扮演：' + speakerName,
      '',
      '这是一个多人聊天。',
      '当前参与者：' + participantList,
      '',
      '只以当前角色身份回复。',
      '不要替用户说话。',
      '不要替其他角色说话。',
      '回复用户时直接说话，不要加任何前缀或格式标记，不要以自己的名字开头。',
      '回复其他角色时用 @角色名 开头。',
      '不要使用方括号 [] 或任何格式标记。',
      '不要说明自己是 AI。',
      '根据当前可见聊天历史自然回应。'
    ];
    // G-CONTROL-2A: 指定角色回复模式追加指令
    if (replyTarget.mode === GroupReplyTargetMode.SelectedCharacters) {
      lines.push('');
      if (replyTarget.characterIds.length === 1) {
        // 单目标:兼容 G-CONTROL-1 语义
        lines.push('本轮由用户指定你回复。');
        lines.push('只以你的角色身份回应。');
        lines.push('不要替其他角色回答。');
      } else {
        // 多目标:明确告知是被指定角色之一
        lines.push('本轮由用户指定一组角色回复。');
        lines.push('你是本轮被指定的角色之一。');
        lines.push('只以当前角色身份回应。');
        lines.push('不要替其他被指定角色发言。');
      }
    }
    return lines.join('\n');
  }

  /**
   * 在 PromptBuilder 输出的消息列表末尾追加群聊约束 System 消息。
   *
   * 位置:在最后一个 System 消息之后,第一个 User/Assistant 消息之前。
   * 若无 System 消息,插入到列表头部。
   */
  private injectGroupConstraint(
    messages: ChatMessage[],
    constraint: string
  ): ChatMessage[] {
    const constraintMessage: ChatMessage = createChatMessage(
      'group-constraint-' + String(nowMillis()),
      ChatRole.System,
      constraint,
      nowMillis()
    );

    // 找到最后一个 System 消息的位置
    let lastSystemIndex: number = -1;
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].role === ChatRole.System) {
        lastSystemIndex = i;
      }
    }

    const result: ChatMessage[] = [];
    if (lastSystemIndex === -1) {
      result.push(constraintMessage);
      for (let i = 0; i < messages.length; i++) {
        result.push(messages[i]);
      }
    } else {
      for (let i = 0; i <= lastSystemIndex; i++) {
        result.push(messages[i]);
      }
      result.push(constraintMessage);
      for (let i = lastSystemIndex + 1; i < messages.length; i++) {
        result.push(messages[i]);
      }
    }
    return result;
  }
}
