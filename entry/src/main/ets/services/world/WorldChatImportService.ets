/**
 * WorldChatImportService 单聊导入世界业务服务
 *
 * 职责:
 * - 将普通单聊(角色卡 + 聊天记录)导入世界模式
 * - 步骤:
 *   1. 读取角色卡与单聊消息
 *   2. 调用 AI 分析:生成活动地点(名称+描述)与角色设定优化建议
 *   3. 在世界中创建地点
 *   4. 将角色加入世界并放置到该地点
 *   5. 创建场景与会话,把聊天记录逐条导入为世界场景消息
 *   6. 将 AI 的设定优化保存为该角色的世界记忆
 * - 不修改原始角色卡(仅生成世界内设定记忆)
 *
 * 日志安全:不记录消息正文 / 完整 ID / SQL,仅记录数量与短 ID。
 */

import { ChatRepository } from '../../repositories/ChatRepository';
import { MessageRepository } from '../../repositories/MessageRepository';
import { CharacterService } from '../CharacterService';
import { ModelService } from '../ModelService';
import { WorldStateService } from './WorldStateService';
import { WorldSceneService } from './WorldSceneService';
import { WorldConversationSessionService } from './WorldConversationSessionService';
import { WorldCharacterMemoryService } from './WorldCharacterMemoryService';
import {
  WorldChatImportPromptAssembler,
  WorldChatImportAiOutput,
  WorldChatImportTranscriptMessage,
  WORLD_CHAT_IMPORT_MESSAGE_MAX_CHARS,
  WORLD_CHAT_IMPORT_TRANSCRIPT_MAX
} from './WorldChatImportPromptAssembler';
import { Chat } from '../../models/Chat';
import { ChatMessage, ChatMessageStatus } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse } from '../../models/ChatResponse';
import { Character } from '../../models/Character';
import { ProviderConfig } from '../../models/ProviderConfig';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene } from '../../models/world/WorldScene';
import { WorldConversationSession } from '../../models/world/WorldConversationSession';
import { WorldSceneMessageVisibility } from '../../models/world/WorldSceneMessage';
import { WorldCharacterMemoryType } from '../../models/world/WorldCharacterMemory';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldChatImport';

export enum WorldChatImportErrorKind {
  CharacterNotFound = 'character_not_found',
  ChatNotFound = 'chat_not_found',
  NoModelConfiguration = 'no_model_configuration',
  ModelRequestFailed = 'model_request_failed',
  InvalidModelOutput = 'invalid_model_output',
  WorldNotActive = 'world_not_active',
  CharacterAlreadyInWorld = 'character_already_in_world',
  ImportFailed = 'import_failed'
}

export class WorldChatImportError extends Error {
  readonly kind: WorldChatImportErrorKind;

  constructor(kind: WorldChatImportErrorKind, message: string) {
    super(message);
    this.name = 'WorldChatImportError';
    this.kind = kind;
  }
}

export interface WorldChatImportResult {
  readonly worldId: string;
  readonly characterId: string;
  readonly locationId: string;
  readonly locationName: string;
  readonly characterInstanceId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly importedMessageCount: number;
  readonly characterOptimization: string;
}

export class WorldChatImportService {
  private readonly stateService: WorldStateService;
  private readonly sceneService: WorldSceneService;
  private readonly sessionService: WorldConversationSessionService;
  private readonly memoryService: WorldCharacterMemoryService;
  private readonly characterService: CharacterService;
  private readonly chatRepo: ChatRepository;
  private readonly messageRepo: MessageRepository;
  private readonly modelService: ModelService;
  private readonly promptAssembler: WorldChatImportPromptAssembler;

  constructor(
    stateService: WorldStateService,
    sceneService: WorldSceneService,
    sessionService: WorldConversationSessionService,
    memoryService: WorldCharacterMemoryService,
    characterService: CharacterService,
    chatRepo: ChatRepository,
    messageRepo: MessageRepository,
    modelService: ModelService,
    promptAssembler: WorldChatImportPromptAssembler
  ) {
    this.stateService = stateService;
    this.sceneService = sceneService;
    this.sessionService = sessionService;
    this.memoryService = memoryService;
    this.characterService = characterService;
    this.chatRepo = chatRepo;
    this.messageRepo = messageRepo;
    this.modelService = modelService;
    this.promptAssembler = promptAssembler;
  }

  /** 列出某角色可导入的单聊会话(供 UI 选择) */
  async listImportableChats(characterId: string): Promise<Chat[]> {
    if (characterId === '') {
      return [];
    }
    try {
      return await this.chatRepo.listByExactCharacterId(characterId, { limit: 50, offset: 0 });
    } catch (e) {
      Logger.warn(LOG_TAG, 'listImportableChats failed: ' + (e as Error).message);
      return [];
    }
  }

  /**
   * 执行单聊导入。
   * 不修改原始角色卡;AI 设定优化保存为世界角色记忆。
   */
  async importChat(
    worldId: string,
    characterId: string,
    chatId: string
  ): Promise<WorldChatImportResult> {
    if (worldId === '') {
      throw new WorldChatImportError(WorldChatImportErrorKind.ImportFailed, '世界 ID 为空');
    }
    if (characterId === '') {
      throw new WorldChatImportError(WorldChatImportErrorKind.CharacterNotFound, '角色 ID 为空');
    }
    if (chatId === '') {
      throw new WorldChatImportError(WorldChatImportErrorKind.ChatNotFound, '会话 ID 为空');
    }

    const character: Character | null = await this.characterService.getById(characterId);
    if (character === null) {
      throw new WorldChatImportError(WorldChatImportErrorKind.CharacterNotFound, '角色不存在');
    }

    const chat: Chat | null = await this.chatRepo.getById(chatId);
    if (chat === null) {
      throw new WorldChatImportError(WorldChatImportErrorKind.ChatNotFound, '单聊会话不存在');
    }

    const messages: ChatMessage[] = await this.messageRepo.listByChat(chatId);
    const transcript: WorldChatImportTranscriptMessage[] = this.buildTranscript(messages);

    const aiOutput: WorldChatImportAiOutput =
      await this.analyzeWithAi(character, chat.userNameOverride, transcript);

    const locationName: string = aiOutput.locationName.length > 0
      ? aiOutput.locationName
      : (character.name.length > 0 ? character.name + '的活动地' : '导入地点');

    Logger.info(LOG_TAG, 'importChat: creating location worldShortId=' + worldId.substring(0, 8));
    const location: WorldLocation =
      await this.stateService.createLocation(worldId, locationName, aiOutput.locationDescription);

    Logger.info(LOG_TAG, 'importChat: adding character to world charShortId=' + characterId.substring(0, 8));
    const instance: WorldCharacterInstance =
      await this.stateService.addCharacterToWorld(worldId, characterId, location.id);

    const scene: WorldScene = await this.sceneService.startScene(worldId, location.id);
    const session: WorldConversationSession = await this.sessionService.startSession({
      worldId: worldId,
      sceneId: scene.id,
      participantCharacterInstanceIds: [instance.id]
    });

    const importedCount: number =
      await this.importMessages(scene.id, instance.id, messages);

    if (aiOutput.characterOptimization.length > 0) {
      await this.memoryService.createManualMemory({
        worldId: worldId,
        characterInstanceId: instance.id,
        content: aiOutput.characterOptimization,
        type: WorldCharacterMemoryType.Semantic,
        importance: 5,
        sourceLocationId: location.id
      });
    }

    Logger.info(LOG_TAG, 'importChat ok: locationShortId=' + location.id.substring(0, 8)
      + ' sceneShortId=' + scene.id.substring(0, 8)
      + ' imported=' + importedCount.toString()
      + ' charShortId=' + characterId.substring(0, 8));
    return {
      worldId: worldId,
      characterId: characterId,
      locationId: location.id,
      locationName: location.name,
      characterInstanceId: instance.id,
      sceneId: scene.id,
      sessionId: session.id,
      importedMessageCount: importedCount,
      characterOptimization: aiOutput.characterOptimization
    };
  }

  /** 调用 AI 分析角色卡与聊天记录 */
  private async analyzeWithAi(
    character: Character,
    playerName: string,
    transcript: WorldChatImportTranscriptMessage[]
  ): Promise<WorldChatImportAiOutput> {
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new WorldChatImportError(
        WorldChatImportErrorKind.NoModelConfiguration,
        '请先配置 AI Provider'
      );
    }
    const prompt = this.promptAssembler.buildImportPrompt(character, playerName, transcript);
    const request: ChatRequest = {
      model: config.modelName,
      messages: prompt.messages,
      temperature: prompt.temperature,
      topP: 0.9,
      maxTokens: prompt.maxTokens,
      stream: false
    };
    let response: ChatResponse;
    try {
      response = await this.modelService.sendChat(request);
    } catch (e) {
      throw new WorldChatImportError(
        WorldChatImportErrorKind.ModelRequestFailed,
        'AI 请求失败:' + ((e as Error).message ?? '未知错误')
      );
    }
    const content: string = response.content;
    if (content === undefined || content.length === 0) {
      throw new WorldChatImportError(WorldChatImportErrorKind.InvalidModelOutput, 'AI 返回为空');
    }
    const output: WorldChatImportAiOutput | null = this.promptAssembler.parseOutput(content);
    if (output === null) {
      throw new WorldChatImportError(WorldChatImportErrorKind.InvalidModelOutput, 'AI 返回格式异常');
    }
    return output;
  }

  /** 构建参与 AI 分析的对话文本(仅已完成消息,截断) */
  private buildTranscript(messages: ChatMessage[]): WorldChatImportTranscriptMessage[] {
    const result: WorldChatImportTranscriptMessage[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: ChatMessage = messages[i];
      if (m.status !== undefined && m.status !== ChatMessageStatus.Completed) {
        continue;
      }
      const content: string = m.content.trim();
      if (content.length === 0) {
        continue;
      }
      const isUser: boolean = m.role === ChatRole.User;
      const truncated: string = content.length > WORLD_CHAT_IMPORT_MESSAGE_MAX_CHARS
        ? content.substring(0, WORLD_CHAT_IMPORT_MESSAGE_MAX_CHARS)
        : content;
      result.push({ isUser: isUser, content: truncated });
    }
    const startIndex: number = Math.max(0, result.length - WORLD_CHAT_IMPORT_TRANSCRIPT_MAX);
    return result.slice(startIndex);
  }

  /** 将单聊消息逐条导入为世界场景消息 */
  private async importMessages(
    sceneId: string,
    characterInstanceId: string,
    messages: ChatMessage[]
  ): Promise<number> {
    let count: number = 0;
    for (let i = 0; i < messages.length; i++) {
      const m: ChatMessage = messages[i];
      if (m.status !== undefined && m.status !== ChatMessageStatus.Completed) {
        continue;
      }
      const content: string = m.content.trim();
      if (content.length === 0) {
        continue;
      }
      if (m.role === ChatRole.User) {
        await this.sceneService.addUserMessage({
          sceneId: sceneId,
          content: content,
          visibility: WorldSceneMessageVisibility.Public
        });
        count = count + 1;
      } else if (m.role === ChatRole.Assistant) {
        await this.sceneService.addCharacterMessage({
          sceneId: sceneId,
          senderCharacterInstanceId: characterInstanceId,
          content: content,
          visibility: WorldSceneMessageVisibility.Public
        });
        count = count + 1;
      }
    }
    return count;
  }
}
