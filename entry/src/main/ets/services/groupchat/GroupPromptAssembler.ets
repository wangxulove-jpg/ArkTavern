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

import { ChatMessage, createChatMessage, MessageSenderType } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { Character } from '../../models/Character';
import { GroupCharacterOverride } from '../../models/groupchat/GroupCharacterOverride';
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
import { GroupCharacterOverrideService } from './GroupCharacterOverrideService';
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
import {
  GroupCharacterMemorySelection,
  MemoryInjectionInspectionItem,
  RelationshipInjectionInspectionItem
} from '../../models/groupchat/GroupPromptInspectionModels';
import {
  GroupMemoryPromptFormatter,
  GroupMemoryFormatResult,
  FormattedPersonalMemoryItem,
  FormattedRelationshipItem
} from './GroupMemoryPromptFormatter';
import {
  GroupUserIdentitySnapshot,
  DEFAULT_USER_DISPLAY_NAME
} from '../../models/groupchat/GroupUserIdentitySnapshot';

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
  /** G-CONTEXT-PROMPT-INJECTION-1: 当前 Speaker 的记忆选择(唯一注入来源;为空时不注入) */
  readonly memorySelection?: GroupCharacterMemorySelection;
  /** G-GROUP-USER-IDENTITY-1: 本轮唯一用户身份快照(所有角色共享) */
  readonly userIdentity: GroupUserIdentitySnapshot;
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
  /** G-IDENTITY-REINFORCE-1: 后置身份提醒完整正文(诊断,未注入时为空字符串) */
  readonly postHistoryIdentityText: string;
  /** G-CONTEXT-PROMPT-INJECTION-1: 每条已选个人记忆的注入状态(无注入时为空数组) */
  readonly memoryInjectionItems?: MemoryInjectionInspectionItem[];
  /** G-CONTEXT-PROMPT-INJECTION-1: 每条已选关系的注入状态(无注入时为空数组) */
  readonly relationshipInjectionItems?: RelationshipInjectionInspectionItem[];
  /** G-CONTEXT-PROMPT-INJECTION-1: 最终注入的个人记忆 System 段完整正文(空字符串表示未注入) */
  readonly personalMemorySegmentText?: string;
  /** G-CONTEXT-PROMPT-INJECTION-1: 最终注入的关系 System 段完整正文(空字符串表示未注入) */
  readonly relationshipMemorySegmentText?: string;
  /** G-GROUP-USER-IDENTITY-1: 用户身份快照(诊断用) */
  readonly userIdentity: GroupUserIdentitySnapshot;
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
  private readonly overrideService: GroupCharacterOverrideService | null;

  constructor(
    promptBuilder: PromptBuilder,
    historyTrimmer: HistoryTrimmer,
    tokenCounter: TokenCounter,
    lorebookService: LorebookService,
    characterService: CharacterService,
    promptPresetService: PromptPresetService | null,
    modelService: ModelService,
    overrideService: GroupCharacterOverrideService | null = null
  ) {
    this.promptBuilder = promptBuilder;
    this.historyTrimmer = historyTrimmer;
    this.tokenCounter = tokenCounter;
    this.lorebookService = lorebookService;
    this.characterService = characterService;
    this.promptPresetService = promptPresetService;
    this.modelService = modelService;
    this.overrideService = overrideService;
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
    let speaker: Character | null = await this.characterService.getById(
      context.speakerCharacterId
    );
    if (speaker === null) {
      throw new Error('GroupPromptAssembler: speaker character not found');
    }

    // 1a. 应用角色覆写(G-OVERRIDE-1A)
    if (this.overrideService !== null) {
      const overrides: GroupCharacterOverride | null =
        await this.overrideService.getOverrides(
          context.chatId, context.speakerCharacterId
        );
      if (overrides !== null) {
        speaker = this.overrideService.applyOverrides(speaker, overrides);
      }
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

    // 6. 转换历史消息(AI 消息加 [角色·名]: 前缀,用户消息加 [用户·名]:)
    const characterMap: Map<string, Character | null> = await this.loadCharacterMap(
      context.messages
    );
    const convertedMessages: ChatMessage[] = this.convertHistoryMessages(
      context.messages,
      characterMap,
      context.speakerCharacterId,
      speaker.name,
      context.userIdentity
    );

    // 7. 构建宏替换上下文(使用快照中的用户名称)
    const macroContext: MacroContext = this.promptBuilder.buildMacroContext(
      speaker,
      context.userIdentity.displayName,
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

    // 8.5 G-CONTEXT-PROMPT-INJECTION-1: 注入群聊专用记忆段(仅使用当前 Speaker 的 Selection)
    // 个人记忆段与关系段作为 System 消息插入到首个对话历史消息之前
    let memoryFormatResult: GroupMemoryFormatResult | null = null;
    let baseMessages: ChatMessage[] = buildResult.messages;
    if (context.memorySelection !== undefined && context.memorySelection !== null) {
      const nameMap: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < context.participantCharacterIds.length; i++) {
        const name: string = i < participantNames.length
          ? participantNames[i] : context.participantCharacterIds[i];
        nameMap.set(context.participantCharacterIds[i], name);
      }
      const ownerNameEntry: string | undefined = nameMap.get(context.speakerCharacterId);
      const ownerName: string = ownerNameEntry !== undefined ? ownerNameEntry : speaker.name;
      memoryFormatResult = GroupMemoryPromptFormatter.format(
        context.memorySelection,
        ownerName,
        nameMap,
        'group-memory-' + context.roundId,
        context.userIdentity.displayName
      );
      baseMessages = this.injectMemorySegments(
        baseMessages,
        memoryFormatResult.personalMemoryMessage,
        memoryFormatResult.relationshipMemoryMessage
      );
    }

    // 9. 生成群聊身份边界 System 段 + 约束
    const replyTarget: GroupReplyTarget = context.replyTarget !== undefined
      ? context.replyTarget : REPLY_TARGET_ALL_ENABLED;
    const identityBoundary: string = this.buildIdentityBoundary(
      context.userIdentity,
      speaker.name,
      participantNames
    );
    const groupConstraint: string = this.buildGroupConstraint(
      speaker.name,
      participantNames,
      replyTarget
    );
    const constraintFull: string = identityBoundary + '\n\n' + groupConstraint;
    const messagesWithConstraint: ChatMessage[] = this.injectGroupConstraint(
      baseMessages,
      constraintFull
    );

    // G-IDENTITY-REINFORCE-1: 后置身份提醒(对话末尾、裁剪保护)。
    // 放置在最靠近模型输出位置处(最后一个非 System 对话消息之前),
    // 长历史场景下仍能锚定"你现在是谁、以谁身份回复"。
    const postHistoryIdentityText: string = this.buildPostHistoryIdentityReminder(
      speaker.name,
      participantNames
    );
    const messagesWithReminder: ChatMessage[] = this.injectPostHistoryIdentityReminder(
      messagesWithConstraint,
      postHistoryIdentityText
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
    const trimmed = this.historyTrimmer.trim(messagesWithReminder, trimOptions);

    // 10.5 G-CONTEXT-PROMPT-INJECTION-1: 计算 selected/formatted/injected 状态
    const requestMessageIds: Set<string> = new Set<string>();
    for (let i = 0; i < trimmed.messages.length; i++) {
      requestMessageIds.add(trimmed.messages[i].id);
    }
    let memoryInjectionItems: MemoryInjectionInspectionItem[] = [];
    let relationshipInjectionItems: RelationshipInjectionInspectionItem[] = [];
    let personalMemorySegmentText: string = '';
    let relationshipMemorySegmentText: string = '';
    if (memoryFormatResult !== null) {
      const personalMessageId: string = memoryFormatResult.personalMemoryMessage !== null
        ? memoryFormatResult.personalMemoryMessage.id : '';
      const relationshipMessageId: string = memoryFormatResult.relationshipMemoryMessage !== null
        ? memoryFormatResult.relationshipMemoryMessage.id : '';
      const personalInjected: boolean = personalMessageId.length > 0
        && requestMessageIds.has(personalMessageId);
      const relationshipInjected: boolean = relationshipMessageId.length > 0
        && requestMessageIds.has(relationshipMessageId);
      const personalMessageIndex: number = personalInjected
        ? this.findMessageIndex(trimmed.messages, personalMessageId) : -1;
      const relationshipMessageIndex: number = relationshipInjected
        ? this.findMessageIndex(trimmed.messages, relationshipMessageId) : -1;
      memoryInjectionItems = this.buildMemoryInjectionItems(
        memoryFormatResult.personalMemoryItems, personalInjected, personalMessageIndex
      );
      relationshipInjectionItems = this.buildRelationshipInjectionItems(
        memoryFormatResult.relationshipItems, relationshipInjected, relationshipMessageIndex
      );
      if (personalInjected && memoryFormatResult.personalMemoryMessage !== null) {
        personalMemorySegmentText = memoryFormatResult.personalMemoryMessage.content;
      }
      if (relationshipInjected && memoryFormatResult.relationshipMemoryMessage !== null) {
        relationshipMemorySegmentText = memoryFormatResult.relationshipMemoryMessage.content;
      }
    }

    // 11. 估算 Token 数
    const estimatedTokens: number = estimateMessagesTokens(trimmed.messages);

    Logger.info(LOG_TAG, 'assemble ok speakers=' + String(context.participantCharacterIds.length)
      + ' msgs=' + String(context.messages.length)
      + ' trimmed=' + String(trimmed.messages.length)
      + ' tokens=' + String(estimatedTokens)
      + ' lorebook=' + String(buildResult.matchedLorebookEntryIds.length)
      + ' memoryInjected=' + String(memoryInjectionItems.length > 0
        ? (personalMemorySegmentText.length > 0 ? 'yes' : 'trimmed') : 'no'));

    return {
      requestMessages: trimmed.messages,
      character: speaker,
      presetSystemPrompt: presetSystemPrompt,
      effectiveSettings: effectiveSettings,
      estimatedTokens: estimatedTokens,
      matchedLorebookCount: buildResult.matchedLorebookEntryIds.length,
      preTrimMessageCount: messagesWithReminder.length,
      postTrimMessageCount: trimmed.messages.length,
      availableInputTokens: availableInputTokens,
      groupConstraintText: groupConstraint,
      participantNames: participantNames,
      replyTargetMode: replyTarget.mode,
      postHistoryIdentityText: postHistoryIdentityText,
      memoryInjectionItems: memoryInjectionItems,
      relationshipInjectionItems: relationshipInjectionItems,
      personalMemorySegmentText: personalMemorySegmentText,
      relationshipMemorySegmentText: relationshipMemorySegmentText,
      userIdentity: context.userIdentity
    };
  }

  /**
   * G-CONTEXT-PROMPT-INJECTION-1: 在首个对话历史消息前插入记忆段(System 消息)。
   * 两个段都为空时返回原数组(行为与注入前完全一致)。
   */
  private injectMemorySegments(
    messages: ChatMessage[],
    personalMessage: ChatMessage | null,
    relationshipMessage: ChatMessage | null
  ): ChatMessage[] {
    if (personalMessage === null && relationshipMessage === null) {
      return messages;
    }
    let firstNonSystem: number = -1;
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].role !== ChatRole.System) {
        firstNonSystem = i;
        break;
      }
    }
    const insertIndex: number = firstNonSystem === -1 ? messages.length : firstNonSystem;
    const result: ChatMessage[] = [];
    for (let i = 0; i < insertIndex; i++) {
      result.push(messages[i]);
    }
    if (personalMessage !== null) {
      result.push(personalMessage);
    }
    if (relationshipMessage !== null) {
      result.push(relationshipMessage);
    }
    for (let i = insertIndex; i < messages.length; i++) {
      result.push(messages[i]);
    }
    return result;
  }

  private buildMemoryInjectionItems(
    formattedItems: FormattedPersonalMemoryItem[],
    injected: boolean,
    messageIndex: number
  ): MemoryInjectionInspectionItem[] {
    const items: MemoryInjectionInspectionItem[] = [];
    for (let i = 0; i < formattedItems.length; i++) {
      const item: FormattedPersonalMemoryItem = formattedItems[i];
      const formatted: boolean = item.failureReason.length === 0;
      const itemInjected: boolean = formatted && injected;
      items.push({
        memoryId: item.memoryId,
        title: item.title,
        content: item.content,
        selected: true,
        formatted: formatted,
        injected: itemInjected,
        messageIndex: itemInjected ? messageIndex : -1,
        failureReason: item.failureReason,
        estimatedTokens: item.estimatedTokens
      });
    }
    return items;
  }

  private buildRelationshipInjectionItems(
    formattedItems: FormattedRelationshipItem[],
    injected: boolean,
    messageIndex: number
  ): RelationshipInjectionInspectionItem[] {
    const items: RelationshipInjectionInspectionItem[] = [];
    for (let i = 0; i < formattedItems.length; i++) {
      const item: FormattedRelationshipItem = formattedItems[i];
      const formatted: boolean = item.failureReason.length === 0;
      const itemInjected: boolean = formatted && injected;
      items.push({
        relationshipId: item.relationshipId,
        direction: item.direction,
        targetId: item.targetId,
        targetType: item.targetType,
        experienceSummary: item.experienceSummary,
        attitudeSummary: item.attitudeSummary,
        relationshipSummary: item.relationshipSummary,
        selected: true,
        formatted: formatted,
        injected: itemInjected,
        messageIndex: itemInjected ? messageIndex : -1,
        source: item.source,
        failureReason: item.failureReason,
        estimatedTokens: item.estimatedTokens
      });
    }
    return items;
  }

  private findMessageIndex(messages: ChatMessage[], id: string): number {
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].id === id) {
        return i;
      }
    }
    return -1;
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
   * 转换历史消息(G-GROUP-USER-IDENTITY-1: 身份标签版)。
   *
   * 规则:
   * - 用户消息:role=user, content="[用户·{displayName}]: 正文"
   * - 当前 Speaker 角色:role=assistant, content="[当前角色·{name}]: 正文"
   * - 其他角色:role=assistant, content="[其他角色·{name}]: 正文"
   * - 旁白:role=assistant, content="[旁白]: 正文"
   * - System 消息:跳过
   */
  private convertHistoryMessages(
    messages: ChatMessage[],
    characterMap: Map<string, Character | null>,
    speakerCharacterId: string,
    speakerName: string,
    userIdentity: GroupUserIdentitySnapshot
  ): ChatMessage[] {
    const result: ChatMessage[] = [];
    const now: number = nowMillis();
    const userLabel: string = userIdentity.displayName;
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.System) {
        continue;
      }
      if (msg.role === ChatRole.Assistant) {
        const senderType: MessageSenderType =
          msg.senderType !== undefined ? msg.senderType : 'user';
        if (senderType === 'narrator') {
          const converted: ChatMessage = createChatMessage(
            msg.id, ChatRole.Assistant, '[旁白]: ' + msg.content, msg.createdAt
          );
          result.push(converted);
          continue;
        }
        const charId: string = msg.senderCharacterId !== undefined ? msg.senderCharacterId : '';
        const character: Character | null = charId.length > 0
          ? (characterMap.get(charId) ?? null) : null;
        const name: string = character !== null ? character.name : '未知角色';
        let prefix: string;
        if (charId === speakerCharacterId) {
          prefix = '[当前角色·' + name + ']: ';
        } else {
          prefix = '[其他角色·' + name + ']: ';
        }
        const converted: ChatMessage = createChatMessage(
          msg.id, ChatRole.Assistant, prefix + msg.content, msg.createdAt
        );
        result.push(converted);
      } else {
        const converted: ChatMessage = createChatMessage(
          msg.id, ChatRole.User, '[用户·' + userLabel + ']: ' + msg.content, msg.createdAt
        );
        result.push(converted);
      }
    }
    return result;
  }

  /**
   * G-GROUP-USER-IDENTITY-1: 构建身份边界 System 段。
   */
  private buildIdentityBoundary(
    userIdentity: GroupUserIdentitySnapshot,
    speakerName: string,
    participantNames: string[]
  ): string {
    const charList: string = participantNames.join('、');
    const lines: string[] = [
      '【群聊身份边界】',
      '',
      '当前唯一的真人用户：',
      '名称：' + userIdentity.displayName,
      '用户信息：' + userIdentity.personaText,
      '',
      '当前群聊角色：',
      '- ' + participantNames.join('\n- '),
      '',
      '你当前扮演：',
      speakerName,
      '',
      '必须遵守：',
      '- 用户和所有群聊角色是不同的人；',
      '- ' + participantNames.join('、') + ' 都不是用户；',
      '- 不得把其他角色的姓名、经历、身份、关系或发言归属于用户；',
      '- 其他角色的发言只是该角色说过的话，不能自动成为用户事实；',
      '- 用户身份只以本身份区块和明确的用户消息为准；',
      '- 当前角色对用户的关系记忆是主观认知，不是用户的客观身份；',
      '- 只以当前角色身份回复；',
      '- 不替用户或其他角色说话；',
      '- 不以任何其他角色名开头，不在正文中出现"我是[其他角色名]"或"我扮演[其他角色名]"的自称；',
      '- 不得替其他角色输出对话，不得以多角色剧本形式回复；',
      '- 不在正文中解释这些规则。'
    ];
    return lines.join('\n');
  }

  /**
   * 构建群聊回复约束(不含身份边界,身份已由 buildIdentityBoundary 提供)。
   */
  private buildGroupConstraint(
    speakerName: string,
    participantNames: string[],
    replyTarget: GroupReplyTarget
  ): string {
    const participantList: string = participantNames.join('、');
    const lines: string[] = [
      '【回复规则】',
      '只输出你自己的回复正文，不要包含其他角色的发言。',
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

  /**
   * G-IDENTITY-REINFORCE-1: 构建后置身份提醒(靠近输出位置的身份锚点)。
   *
   * 与 buildIdentityBoundary / buildGroupConstraint 区别:
   * - 放置在对话历史末尾(最后一个非 System 消息之前),直接锚定"现在你是谁"
   * - 在长历史、多角色场景下,约束文本离输出位置越近越容易被模型遵守
   * - 强调三件事:当前扮演者 / 不得替他人说话 / 输出格式
   */
  private buildPostHistoryIdentityReminder(
    speakerName: string,
    participantNames: string[]
  ): string {
    const lines: string[] = [
      '【本轮身份提醒】',
      '',
      '你当前扮演：' + speakerName + '。',
      '只以 ' + speakerName + ' 的身份回复，不要替其他角色或用户发言。',
      '不要模仿、转述或以其他角色的口吻说话。',
      '输出只包含 ' + speakerName + ' 本人的话，直接开始，不要带任何角色名或格式前缀。',
      '其他角色的历史发言只是你了解到的背景信息，不是你的立场。'
    ];
    if (participantNames.length > 0) {
      lines.push('');
      lines.push('在场角色：' + participantNames.join('、'));
    }
    return lines.join('\n');
  }

  /**
   * G-IDENTITY-REINFORCE-1: 将后置身份提醒 System 消息注入到消息列表末尾附近。
   *
   * 放置规则:
   * - 插入到最后一个非 System 对话消息之前(紧邻模型输出位置)
   * - 若全部为 System 消息,追加到列表末尾
   * - 返回新数组,不修改输入
   */
  private injectPostHistoryIdentityReminder(
    messages: ChatMessage[],
    reminderText: string
  ): ChatMessage[] {
    if (reminderText.length === 0) {
      return messages;
    }
    let lastNonSystem: number = -1;
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role !== ChatRole.System) {
        lastNonSystem = i;
        break;
      }
    }
    const reminderMessage: ChatMessage = createChatMessage(
      'group-identity-reminder-' + String(nowMillis()),
      ChatRole.System,
      reminderText,
      nowMillis()
    );
    const result: ChatMessage[] = [];
    if (lastNonSystem === -1) {
      result.push(reminderMessage);
      for (let i = 0; i < messages.length; i++) {
        result.push(messages[i]);
      }
    } else {
      for (let i = 0; i < lastNonSystem; i++) {
        result.push(messages[i]);
      }
      result.push(reminderMessage);
      for (let i = lastNonSystem; i < messages.length; i++) {
        result.push(messages[i]);
      }
    }
    return result;
  }
}
