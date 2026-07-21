/**
 * WorldMemoryService 多人世界记忆服务
 *
 * 职责:
 * - WorldMemoryEvent 的写入与查询(世界公共、场景、私人可见性隔离)
 * - WorldPrivateMemory 的写入与查询
 * - 按 visibility 规则过滤角色可见事件
 * - 失效与重建(Swipe/分支切换/重新生成时)
 *
 * 不负责:
 * - 记忆摘要生成(由 MultiPersonChatService 调用 ModelService 完成)
 * - 关系变更(由 WorldRelationshipService 处理)
 *
 * 规则:
 * - 角色只能注入:公共事实、当前场景、自己的私人记忆、自己参与/目击/被告知的事件
 * - 禁止注入其他角色的私人秘密和内心评价
 * - 不打印记忆事件正文
 */

import { DbHelper } from '../database/DbHelper';
import { WorldRepository } from '../repositories/WorldRepository';
import {
  WorldMemoryEvent,
  WorldPrivateMemory,
  MemoryVisibility,
  createWorldMemoryEvent,
  createWorldPrivateMemory,
  parseVisibility,
  canCharacterKnowEvent
} from '../models/WorldMemory';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';
import { ChatMessage, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatRequest } from '../models/ChatRequest';
import { Character } from '../models/Character';
import { ModelService } from './ModelService';

const LOG_TAG: string = 'WorldMemoryService';

/**
 * 创建记忆事件的输入。
 */
export interface CreateMemoryEventInput {
  readonly chatId: string;
  readonly branchId: string;
  readonly sceneId: string;
  readonly participantIds: string[];
  readonly witnessIds: string[];
  readonly informedCharacterIds: string[];
  readonly subjectCharacterId: string;
  readonly relatedCharacterIds: string[];
  readonly visibility: MemoryVisibility;
  readonly summary: string;
  readonly startMessageId: string;
  readonly endMessageId: string;
  readonly enabled: boolean;
}

/**
 * 创建角色私人记忆的输入。
 */
export interface CreatePrivateMemoryInput {
  readonly chatId: string;
  readonly branchId: string;
  readonly sceneId: string;
  readonly characterId: string;
  readonly content: string;
}

/**
 * 本轮记忆生成的输入。
 * - roundMessages:本轮产生的全部消息(用户消息 + 角色消息 + 旁白消息,按时间顺序)
 * - speakerCharacters:本轮实际发言的角色列表(用于生成私人记忆)
 * - presentCharacters:本轮在场角色列表(用于公共事件的 participantIds)
 */
export interface GenerateRoundMemoryInput {
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly sceneId: string;
  readonly roundMessages: ChatMessage[];
  readonly speakerCharacters: Character[];
  readonly presentCharacters: Character[];
}

/**
 * 本轮记忆生成结果(用于诊断日志,不含正文)。
 */
export interface RoundMemoryResult {
  readonly publicEventCreated: boolean;
  readonly privateMemoriesCreated: number;
  readonly failed: boolean;
  readonly error: string;
}

export class WorldMemoryService {
  private readonly dbHelper: DbHelper;
  private readonly worldRepo: WorldRepository;
  private readonly modelService: ModelService;

  constructor(dbHelper: DbHelper, worldRepo: WorldRepository, modelService: ModelService) {
    this.dbHelper = dbHelper;
    this.worldRepo = worldRepo;
    this.modelService = modelService;
  }

  /**
   * 写入一个记忆事件。
   * 校验 summary 非空、visibility 合法。
   * 注意:visibility=public 时允许 subjectCharacterId 为空(公共事件无明确主体)。
   */
  async recordEvent(worldId: string, input: CreateMemoryEventInput): Promise<WorldMemoryEvent> {
    if (worldId.length === 0) {
      throw DatabaseError.invalidData('worldId empty');
    }
    if (input.summary.length === 0) {
      throw DatabaseError.invalidData('memory.summary empty');
    }
    if (input.subjectCharacterId.length === 0 && input.visibility !== 'public') {
      throw DatabaseError.invalidData('memory.subjectCharacterId empty');
    }
    parseVisibility(input.visibility);
    const event: WorldMemoryEvent = createWorldMemoryEvent({
      worldId: worldId,
      chatId: input.chatId,
      branchId: input.branchId,
      sceneId: input.sceneId,
      participantIds: input.participantIds,
      witnessIds: input.witnessIds,
      informedCharacterIds: input.informedCharacterIds,
      subjectCharacterId: input.subjectCharacterId,
      relatedCharacterIds: input.relatedCharacterIds,
      visibility: input.visibility,
      summary: input.summary,
      startMessageId: input.startMessageId,
      endMessageId: input.endMessageId,
      enabled: input.enabled
    });
    await this.worldRepo.insertMemoryEvent(event);
    return event;
  }

  /**
   * 写入一条角色私人记忆。
   */
  async recordPrivateMemory(worldId: string, input: CreatePrivateMemoryInput): Promise<WorldPrivateMemory> {
    if (worldId.length === 0) {
      throw DatabaseError.invalidData('worldId empty');
    }
    if (input.characterId.length === 0) {
      throw DatabaseError.invalidData('privateMemory.characterId empty');
    }
    if (input.content.length === 0) {
      throw DatabaseError.invalidData('privateMemory.content empty');
    }
    const mem: WorldPrivateMemory = createWorldPrivateMemory({
      worldId: worldId,
      chatId: input.chatId,
      branchId: input.branchId,
      sceneId: input.sceneId,
      characterId: input.characterId,
      summary: input.content
    });
    await this.worldRepo.insertPrivateMemory(mem);
    return mem;
  }

  /**
   * 列出指定 chatId/branchId 下的全部记忆事件(世界公共 + 场景 + 私人可见性均包含)。
   * 调用方需自行按 visibility 过滤。
   */
  async listEventsByBranch(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<WorldMemoryEvent[]> {
    return await this.worldRepo.listMemoryEvents(worldId, chatId, branchId);
  }

  /**
   * 列出角色可见的记忆事件(按 visibility 规则过滤)。
   * - public: 可见
   * - narrator_only: 不可见(角色不知道)
   * - private: 仅 subjectCharacterId 可见
   * - participants: 仅参与者/目击者/被告知者可见
   */
  async listVisibleEventsForCharacter(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<WorldMemoryEvent[]> {
    const all: WorldMemoryEvent[] = await this.listEventsByBranch(worldId, chatId, branchId);
    const visible: WorldMemoryEvent[] = [];
    for (let i = 0; i < all.length; i++) {
      const e: WorldMemoryEvent = all[i];
      if (!e.enabled) {
        continue;
      }
      if (canCharacterKnowEvent(e, characterId)) {
        visible.push(e);
      }
    }
    return visible;
  }

  /**
   * 列出角色的私人记忆。
   */
  async listPrivateMemoriesForCharacter(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<WorldPrivateMemory[]> {
    return await this.worldRepo.listPrivateMemoriesByCharacter(
      worldId, chatId, branchId, characterId
    );
  }

  /**
   * 设置记忆事件启用/禁用。
   */
  async setEventEnabled(event: WorldMemoryEvent, enabled: boolean): Promise<void> {
    const next: WorldMemoryEvent = {
      id: event.id,
      worldId: event.worldId,
      chatId: event.chatId,
      branchId: event.branchId,
      sceneId: event.sceneId,
      participantIds: event.participantIds,
      witnessIds: event.witnessIds,
      informedCharacterIds: event.informedCharacterIds,
      subjectCharacterId: event.subjectCharacterId,
      relatedCharacterIds: event.relatedCharacterIds,
      visibility: event.visibility,
      summary: event.summary,
      startMessageId: event.startMessageId,
      endMessageId: event.endMessageId,
      enabled: enabled,
      createdAt: event.createdAt,
      updatedAt: nowMillis()
    };
    await this.worldRepo.updateMemoryEvent(next);
  }

  /**
   * 列出当前 chatId/branchId 下的全部公共记忆事件(visibility=public 且 enabled)。
   */
  async listPublicEvents(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<WorldMemoryEvent[]> {
    const all: WorldMemoryEvent[] = await this.listEventsByBranch(worldId, chatId, branchId);
    const publicEvents: WorldMemoryEvent[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].enabled && all[i].visibility === 'public') {
        publicEvents.push(all[i]);
      }
    }
    return publicEvents;
  }

  /**
   * 列出指定角色"与用户的共同经历"事件。
   * 约定:visibility=participants 且 participantIds 包含 characterId,
   * 且 subjectCharacterId 为该角色或 participantIds 包含 user 标识(此处用 'user' 占位)。
   */
  async listSharedExperiencesWithUser(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<WorldMemoryEvent[]> {
    const all: WorldMemoryEvent[] = await this.listEventsByBranch(worldId, chatId, branchId);
    const shared: WorldMemoryEvent[] = [];
    for (let i = 0; i < all.length; i++) {
      const e: WorldMemoryEvent = all[i];
      if (!e.enabled) continue;
      if (e.visibility !== 'participants') continue;
      const isSubject: boolean = e.subjectCharacterId === characterId;
      const isParticipant: boolean = e.participantIds.indexOf(characterId) >= 0;
      if (isSubject || isParticipant) {
        shared.push(e);
      }
    }
    return shared;
  }

  /**
   * 列出指定角色作为主体的"已知事件"。
   * 约定:subjectCharacterId 为该角色,且 visibility 为 public/participants/private 之一。
   */
  async listKnownEventsForCharacter(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<WorldMemoryEvent[]> {
    const all: WorldMemoryEvent[] = await this.listEventsByBranch(worldId, chatId, branchId);
    const known: WorldMemoryEvent[] = [];
    for (let i = 0; i < all.length; i++) {
      const e: WorldMemoryEvent = all[i];
      if (!e.enabled) continue;
      if (e.subjectCharacterId === characterId) {
        known.push(e);
      }
    }
    return known;
  }

  /**
   * 本轮生成完成后,异步生成记忆事件 + 各发言角色私人记忆。
   *
   * 策略(不依赖模型返回 JSON,每次调用只生成纯文本摘要):
   * 1. 调用 1 次:生成本轮"公共事件"摘要 → 写入 WorldMemoryEvent(visibility=public)
   * 2. 对每个发言角色调用 1 次:生成该角色的"私人记忆" → 写入 WorldPrivateMemory
   *
   * 失败处理:
   * - 任何一次调用失败 → 记录日志,继续后续调用,不阻塞主流程
   * - 模型返回空内容 → 跳过该条记忆写入
   * - 不打印记忆正文,只打印数量与 characterId 标识
   *
   * @returns RoundMemoryResult 用于诊断日志(不含正文)
   */
  async generateMemoriesForRound(input: GenerateRoundMemoryInput): Promise<RoundMemoryResult> {
    const tag: string = `${input.worldId.substring(0, 4)}/${input.branchId.substring(0, 4)}`;
    if (input.roundMessages.length === 0) {
      Logger.info(LOG_TAG, `generateMemories skip empty round tag=${tag}`);
      return {
        publicEventCreated: false,
        privateMemoriesCreated: 0,
        failed: false,
        error: ''
      };
    }

    // 解析当前 Provider 配置以获取 model 名
    let modelName: string = '';
    try {
      const config = await this.modelService.getCurrentConfig();
      if (config === null) {
        Logger.warn(LOG_TAG, `generateMemories no provider config tag=${tag}`);
        return {
          publicEventCreated: false,
          privateMemoriesCreated: 0,
          failed: true,
          error: 'no provider config'
        };
      }
      modelName = config.modelName.trim();
      if (modelName.length === 0) {
        Logger.warn(LOG_TAG, `generateMemories empty model name tag=${tag}`);
        return {
          publicEventCreated: false,
          privateMemoriesCreated: 0,
          failed: true,
          error: 'empty model name'
        };
      }
    } catch (e) {
      Logger.warn(LOG_TAG, `generateMemories getConfig failed tag=${tag} err=${(e as Error).message}`);
      return {
        publicEventCreated: false,
        privateMemoriesCreated: 0,
        failed: true,
        error: (e as Error).message
      };
    }

    let publicEventCreated: boolean = false;
    let privateMemoriesCreated: number = 0;
    let failed: boolean = false;
    let errorMsg: string = '';

    // 1. 生成本轮公共事件(visibility=public)
    try {
      const publicSummary: string = await this.requestPublicEventSummary(
        input, modelName
      );
      if (publicSummary.trim().length > 0) {
        const startMsgId: string = input.roundMessages.length > 0
          ? input.roundMessages[0].id : '';
        const endMsgId: string = input.roundMessages.length > 0
          ? input.roundMessages[input.roundMessages.length - 1].id : '';
        const participantIds: string[] = input.presentCharacters.map((c) => c.id);
        await this.recordEvent(input.worldId, {
          chatId: input.chatId,
          branchId: input.branchId,
          sceneId: input.sceneId,
          participantIds: participantIds,
          witnessIds: [],
          informedCharacterIds: [],
          subjectCharacterId: '',
          relatedCharacterIds: input.speakerCharacters.map((c) => c.id),
          visibility: 'public',
          summary: publicSummary.trim(),
          startMessageId: startMsgId,
          endMessageId: endMsgId,
          enabled: true
        });
        publicEventCreated = true;
        Logger.info(
          LOG_TAG,
          `generateMemories publicEvent ok tag=${tag} participants=${participantIds.length}`
        );
      } else {
        Logger.warn(LOG_TAG, `generateMemories publicEvent empty response tag=${tag}`);
      }
    } catch (e) {
      failed = true;
      errorMsg = (e as Error).message;
      Logger.warn(
        LOG_TAG,
        `generateMemories publicEvent failed tag=${tag} err=${(e as Error).message}`
      );
    }

    // 2. 为每个发言角色生成私人记忆
    for (let i = 0; i < input.speakerCharacters.length; i++) {
      const ch: Character = input.speakerCharacters[i];
      try {
        const privateSummary: string = await this.requestPrivateMemorySummary(
          input, ch, modelName
        );
        if (privateSummary.trim().length > 0) {
          await this.recordPrivateMemory(input.worldId, {
            chatId: input.chatId,
            branchId: input.branchId,
            sceneId: input.sceneId,
            characterId: ch.id,
            content: privateSummary.trim()
          });
          privateMemoriesCreated++;
          Logger.info(
            LOG_TAG,
            `generateMemories privateMemory ok tag=${tag} charId=${ch.id.substring(0, 4)}`
          );
        } else {
          Logger.warn(
            LOG_TAG,
            `generateMemories privateMemory empty response tag=${tag} charId=${ch.id.substring(0, 4)}`
          );
        }
      } catch (e) {
        failed = true;
        if (errorMsg.length === 0) errorMsg = (e as Error).message;
        Logger.warn(
          LOG_TAG,
          `generateMemories privateMemory failed tag=${tag} charId=${ch.id.substring(0, 4)} err=${(e as Error).message}`
        );
      }
    }

    Logger.info(
      LOG_TAG,
      `generateMemories done tag=${tag} public=${publicEventCreated} private=${privateMemoriesCreated}/${input.speakerCharacters.length} failed=${failed}`
    );
    return {
      publicEventCreated: publicEventCreated,
      privateMemoriesCreated: privateMemoriesCreated,
      failed: failed,
      error: errorMsg
    };
  }

  /**
   * 调用模型生成本轮"公共事件"摘要。
   * 输出:一段简洁中文摘要(不超过 200 字),描述本轮发生的核心事件。
   */
  private async requestPublicEventSummary(
    input: GenerateRoundMemoryInput,
    modelName: string
  ): Promise<string> {
    const systemPrompt: string =
      '你是多人世界的事件记录员。任务:根据本轮对话,生成一段简洁的公共事件摘要。\n' +
      '要求:\n' +
      '- 只记录在场所有人都能感知的客观事件\n' +
      '- 不记录角色内心想法或私人秘密\n' +
      '- 不记录角色私下对其他人的评价\n' +
      '- 简洁中文,不超过 200 字\n' +
      '- 只输出摘要正文,不要标题、不要 JSON、不要解释';

    const userContent: string = this.formatRoundMessagesForPrompt(input.roundMessages);
    const messages: ChatMessage[] = [
      createChatMessage('mem-pub-sys', ChatRole.System, systemPrompt, nowMillis()),
      createChatMessage('mem-pub-user', ChatRole.User, userContent, nowMillis())
    ];
    const request: ChatRequest = {
      model: modelName,
      messages: messages,
      temperature: 0.3,
      topP: 0.9,
      maxTokens: 400,
      stream: false
    };
    const response = await this.modelService.sendChat(request);
    return response.content;
  }

  /**
   * 调用模型生成指定角色的私人记忆摘要。
   * 输出:该角色视角的私人记忆(内心想法、对他人看法、秘密)。
   */
  private async requestPrivateMemorySummary(
    input: GenerateRoundMemoryInput,
    character: Character,
    modelName: string
  ): Promise<string> {
    const systemPrompt: string =
      `你是角色「${character.name}」的私人记忆记录员。任务:根据本轮对话,从该角色视角生成一段私人记忆。\n` +
      '要求:\n' +
      '- 只记录该角色本人可知的内心想法、对他人评价、私人秘密\n' +
      '- 不记录其他角色的内心\n' +
      '- 简洁中文,不超过 200 字\n' +
      '- 只输出记忆正文,不要角色名前缀、不要标题、不要 JSON、不要解释';

    const userContent: string = this.formatRoundMessagesForPrompt(input.roundMessages);
    const messages: ChatMessage[] = [
      createChatMessage('mem-priv-sys', ChatRole.System, systemPrompt, nowMillis()),
      createChatMessage('mem-priv-user', ChatRole.User, userContent, nowMillis())
    ];
    const request: ChatRequest = {
      model: modelName,
      messages: messages,
      temperature: 0.4,
      topP: 0.9,
      maxTokens: 400,
      stream: false
    };
    const response = await this.modelService.sendChat(request);
    return response.content;
  }

  /**
   * 格式化本轮消息为模型可读文本(脱敏:不含 chatId/branchId,只含角色名 + 内容片段)。
   */
  private formatRoundMessagesForPrompt(messages: ChatMessage[]): string {
    const lines: string[] = ['【本轮对话】'];
    for (let i = 0; i < messages.length; i++) {
      const m: ChatMessage = messages[i];
      const senderType = m.senderType !== undefined ? m.senderType : 'character';
      let speaker: string;
      if (senderType === 'user') {
        speaker = '用户';
      } else if (senderType === 'narrator') {
        speaker = '旁白';
      } else {
        speaker = '角色';
      }
      // 截断过长内容(避免 token 膨胀)
      const content: string = m.content.length > 800
        ? m.content.substring(0, 800) + '...' : m.content;
      lines.push(`${speaker}: ${content}`);
    }
    return lines.join('\n');
  }
}
