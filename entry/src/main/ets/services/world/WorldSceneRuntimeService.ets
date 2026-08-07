import {
  WorldSceneMessage,
  WorldSceneMessageStatus
} from '../../models/world/WorldSceneMessage';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldPlayerProfile } from '../../models/world/WorldPlayerProfile';
import { Character } from '../../models/Character';
import { WorldRuntimeError, WorldRuntimeErrorKind } from '../../models/world/WorldRuntimeError';
import { WorldSceneMessageService, AddWorldUserMessageOptions } from './WorldSceneMessageService';
import { WorldRuntimeRegistry, RegistryEntry } from './WorldRuntimeRegistry';
import {
  WorldScenePromptAssembler,
  WorldPromptAssemblyInput,
  WorldPromptAssemblyResult
} from './WorldScenePromptAssembler';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldPlayerProfileRepository } from '../../repositories/world/WorldPlayerProfileRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { CharacterService } from '../../services/CharacterService';
import { ModelService } from '../ModelService';
import { ChatStreamCallbacks, ChatDelta, ChatStreamResult } from '../../models/ChatStreamTypes';
import { ChatRequestOptions } from '../../models/ChatRequest';
import { generateUuid } from '../../utils/Uuid';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneRuntime';
const PERSISTENCE_THROTTLE_MS: number = 400;
const PERSISTENCE_MIN_CHARS: number = 64;

export interface WorldRuntimeTurnOptions {
  worldId: string;
  sceneId: string;
  sessionId: string;
  userContent: string;
}

export interface WorldRuntimeTurnResult {
  userMessage: WorldSceneMessage;
  characterMessage: WorldSceneMessage;
  generationBatchId: string;
}

export class WorldSceneRuntimeService {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly playerProfileRepo: WorldPlayerProfileRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly characterService: CharacterService;
  private readonly modelService: ModelService;
  private readonly messageService: WorldSceneMessageService;
  private readonly registry: WorldRuntimeRegistry;
  private readonly promptAssembler: WorldScenePromptAssembler;

  private streamingContent: string = '';
  private lastPersistedLength: number = 0;
  private persistenceTimerId: number = -1;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    sceneRepo: WorldSceneRepository,
    sessionRepo: WorldConversationSessionRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    playerProfileRepo: WorldPlayerProfileRepository,
    messageRepo: WorldSceneMessageRepository,
    characterService: CharacterService,
    modelService: ModelService,
    messageService: WorldSceneMessageService,
    registry: WorldRuntimeRegistry,
    promptAssembler: WorldScenePromptAssembler
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.sceneRepo = sceneRepo;
    this.sessionRepo = sessionRepo;
    this.instanceRepo = instanceRepo;
    this.playerProfileRepo = playerProfileRepo;
    this.messageRepo = messageRepo;
    this.characterService = characterService;
    this.modelService = modelService;
    this.messageService = messageService;
    this.registry = registry;
    this.promptAssembler = promptAssembler;
  }

  async sendAndGenerate(options: WorldRuntimeTurnOptions): Promise<WorldRuntimeTurnResult> {
    const trimmed: string = options.userContent.trim();
    if (trimmed.length === 0) {
      throw WorldRuntimeError.emptyUserMessage();
    }

    const session: WorldConversationSession = await this.validateSession(options);
    const scene: WorldScene = await this.validateScene(options, session);
    const world: World = await this.validateWorld(options);

    const participants = deserializeParticipantSnapshots(session.participantSnapshotJson);
    if (participants.length !== 1) {
      throw WorldRuntimeError.unsupportedParticipantCount(participants.length);
    }

    const speakerSnapshot = participants[0];
    const speakerInstance: WorldCharacterInstance = await this.validateSpeakerInstance(
      speakerSnapshot.characterInstanceId,
      options.worldId,
      session
    );
    const speakerCharacter: Character = await this.validateSpeakerCharacter(speakerInstance.characterId);

    const playerProfile: WorldPlayerProfile = await this.validatePlayerProfile(options.worldId);
    const location: WorldLocation = await this.validateLocation(session.sceneId.length > 0 ? scene.locationId : '');

    const generationBatchId: string = 'batch-' + generateUuid();

    const entry: RegistryEntry | null = this.registry.tryAcquire(options.sessionId, generationBatchId);
    if (entry === null) {
      throw WorldRuntimeError.runtimeBusy();
    }

    const operationId: number = entry.operationId;

    try {
      const replyTargets: string[] = [speakerSnapshot.characterInstanceId];
      const userMessage: WorldSceneMessage = await this.messageService.addUserMessage({
        worldId: options.worldId,
        sceneId: options.sceneId,
        sessionId: options.sessionId,
        content: trimmed,
        replyTargetCharacterInstanceIds: replyTargets
      });

      const characterPlaceholder: WorldSceneMessage = await this.messageService.addCharacterPlaceholder({
        worldId: options.worldId,
        sceneId: options.sceneId,
        sessionId: options.sessionId,
        senderCharacterInstanceId: speakerSnapshot.characterInstanceId,
        generationBatchId: generationBatchId
      });

      const sessionMessages: WorldSceneMessage[] = await this.messageRepo.listBySessionId(options.sessionId);
      const promptInput: WorldPromptAssemblyInput = {
        world: world,
        scene: scene,
        session: session,
        location: location,
        speakerInstance: speakerInstance,
        speakerCharacter: speakerCharacter,
        playerProfile: playerProfile,
        sessionMessages: sessionMessages,
        generationBatchId: generationBatchId
      };

      const promptResult: WorldPromptAssemblyResult = await this.promptAssembler.assemble(promptInput);

      this.streamingContent = '';
      this.lastPersistedLength = 0;

      const self: WorldSceneRuntimeService = this;
      const callbacks: ChatStreamCallbacks = {
        onStart: () => {
          Logger.info(LOG_TAG, 'streaming started: op=' + operationId.toString());
        },

        onDelta: (delta: ChatDelta) => {
          if (!self.registry.isCurrent(options.sessionId, operationId)) {
            return;
          }
          self.streamingContent += delta.content;
          self.scheduleStreamingFlush(characterPlaceholder.id, options.sessionId, operationId);
        },

        onComplete: (result: ChatStreamResult) => {
          if (!self.registry.isCurrent(options.sessionId, operationId)) {
            Logger.info(LOG_TAG, 'late onComplete discarded: op=' + operationId.toString());
            return;
          }
          self.clearPersistenceTimer();
          const finalContent: string = result.content.length > 0 ? result.content : self.streamingContent;
          self.streamingContent = finalContent;
          self.messageService.finalizeCharacterMessage({
            messageId: characterPlaceholder.id,
            content: finalContent,
            status: WorldSceneMessageStatus.Completed
          }).then((success: boolean) => {
            if (!success) {
              Logger.warn(LOG_TAG, 'finalize Completed failed for msg=' + self.shortId(characterPlaceholder.id));
            }
            self.registry.release(options.sessionId, operationId);
            Logger.info(LOG_TAG, 'turn completed: batch=' + self.shortId(generationBatchId));
          }).catch((e: Error) => {
            Logger.error(LOG_TAG, 'finalize error: ' + e.message);
            self.registry.release(options.sessionId, operationId);
          });
        },

        onError: (error: Error) => {
          if (!self.registry.isCurrent(options.sessionId, operationId)) {
            Logger.info(LOG_TAG, 'late onError discarded: op=' + operationId.toString());
            return;
          }
          self.clearPersistenceTimer();
          const currentContent: string = self.streamingContent;
          self.messageService.finalizeCharacterMessage({
            messageId: characterPlaceholder.id,
            content: currentContent,
            status: WorldSceneMessageStatus.Failed
          }).then((success: boolean) => {
            if (!success) {
              Logger.warn(LOG_TAG, 'finalize Failed failed for msg=' + self.shortId(characterPlaceholder.id));
            }
            self.registry.release(options.sessionId, operationId);
            Logger.info(LOG_TAG, 'turn failed: batch=' + self.shortId(generationBatchId)
              + ' err=' + error.message);
          }).catch((e: Error) => {
            Logger.error(LOG_TAG, 'finalize-on-error failed: ' + e.message);
            self.registry.release(options.sessionId, operationId);
          });
        }
      };

      const requestOptions: ChatRequestOptions = {
        temperature: promptResult.temperature ?? promptResult.providerConfig.temperature,
        topP: promptResult.topP ?? promptResult.providerConfig.topP,
        maxTokens: promptResult.maxTokens ?? promptResult.providerConfig.maxTokens,
        stream: true
      };

      const handle = this.modelService.streamCurrentChat(
        promptResult.messages,
        requestOptions,
        callbacks
      );

      this.registry.attachHandle(options.sessionId, operationId, handle);

      return {
        userMessage: userMessage,
        characterMessage: characterPlaceholder,
        generationBatchId: generationBatchId
      };
    } catch (e) {
      this.registry.release(options.sessionId, operationId);
      if (e instanceof WorldRuntimeError) {
        throw e;
      }
      throw WorldRuntimeError.modelRequestFailed((e as Error).message);
    }
  }

  stop(sessionId: string): boolean {
    return this.registry.stop(sessionId);
  }

  isBusy(sessionId: string): boolean {
    return this.registry.isBusy(sessionId);
  }

  private async validateSession(options: WorldRuntimeTurnOptions): Promise<WorldConversationSession> {
    const session: WorldConversationSession | null = await this.sessionRepo.getById(options.sessionId);
    if (session === null) {
      throw WorldRuntimeError.sessionNotFound();
    }
    if (session.status !== WorldConversationSessionStatus.Active) {
      throw WorldRuntimeError.sessionEnded();
    }
    if (session.worldId !== options.worldId) {
      throw WorldRuntimeError.sessionWorldMismatch();
    }
    if (session.sceneId !== options.sceneId) {
      throw WorldRuntimeError.sessionSceneMismatch();
    }
    return session;
  }

  private async validateScene(options: WorldRuntimeTurnOptions, session: WorldConversationSession): Promise<WorldScene> {
    const scene: WorldScene | null = await this.sceneRepo.getById(options.sceneId);
    if (scene === null) {
      throw WorldRuntimeError.sceneNotFound();
    }
    if (scene.status === WorldSceneStatus.Ended) {
      throw WorldRuntimeError.sceneEnded();
    }
    return scene;
  }

  private async validateWorld(options: WorldRuntimeTurnOptions): Promise<World> {
    const world: World | null = await this.worldRepo.getById(options.worldId);
    if (world === null) {
      throw WorldRuntimeError.worldNotFound();
    }
    return world;
  }

  private async validateSpeakerInstance(
    instanceId: string,
    worldId: string,
    session: WorldConversationSession
  ): Promise<WorldCharacterInstance> {
    const instance: WorldCharacterInstance | null = await this.instanceRepo.getById(instanceId);
    if (instance === null) {
      throw WorldRuntimeError.participantNotFound();
    }
    if (instance.worldId !== worldId) {
      throw WorldRuntimeError.participantWorldMismatch();
    }
    return instance;
  }

  private async validateSpeakerCharacter(characterId: string): Promise<Character> {
    const character: Character | null = await this.characterService.getById(characterId);
    if (character === null) {
      throw WorldRuntimeError.characterNotFound();
    }
    return character;
  }

  private async validatePlayerProfile(worldId: string): Promise<WorldPlayerProfile> {
    const profile: WorldPlayerProfile | null = await this.playerProfileRepo.getByWorldId(worldId);
    if (profile === null) {
      throw WorldRuntimeError.playerProfileNotFound();
    }
    return profile;
  }

  private async validateLocation(locationId: string): Promise<WorldLocation> {
    const location: WorldLocation | null = await this.locationRepo.getById(locationId);
    if (location === null) {
      throw WorldRuntimeError.sessionLocationMismatch();
    }
    return location;
  }

  private scheduleStreamingFlush(messageId: string, sessionId: string, operationId: number): void {
    const charDelta: number = this.streamingContent.length - this.lastPersistedLength;
    if (charDelta >= PERSISTENCE_MIN_CHARS) {
      this.flushStreamingContent(messageId, sessionId, operationId);
      return;
    }
    if (this.persistenceTimerId === -1) {
      const self: WorldSceneRuntimeService = this;
      this.persistenceTimerId = setTimeout(() => {
        self.flushStreamingContent(messageId, sessionId, operationId);
      }, PERSISTENCE_THROTTLE_MS) as number;
    }
  }

  private flushStreamingContent(messageId: string, sessionId: string, operationId: number): void {
    if (!this.registry.isCurrent(sessionId, operationId)) {
      this.clearPersistenceTimer();
      return;
    }
    this.clearPersistenceTimer();
    const content: string = this.streamingContent;
    this.lastPersistedLength = content.length;
    this.messageService.updateStreamingContent({
      messageId: messageId,
      content: content
    }).catch((e: Error) => {
      Logger.warn(LOG_TAG, 'streaming flush failed: ' + e.message);
    });
  }

  private clearPersistenceTimer(): void {
    if (this.persistenceTimerId !== -1) {
      clearTimeout(this.persistenceTimerId);
      this.persistenceTimerId = -1;
    }
  }

  private shortId(id: string): string {
    return id.length > 8 ? id.substring(0, 8) : id;
  }
}
