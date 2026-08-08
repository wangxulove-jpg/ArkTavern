import {
  WorldSceneMessage,
  WorldSceneMessageStatus,
  WorldSceneMessageSenderType
} from '../../models/world/WorldSceneMessage';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldPlayerProfile } from '../../models/world/WorldPlayerProfile';
import { Character } from '../../models/Character';
import { WorldRuntimeError, WorldRuntimeErrorKind } from '../../models/world/WorldRuntimeError';
import { WorldSceneMessageService, AddWorldUserMessageOptions } from './WorldSceneMessageService';
import { WorldRuntimeRegistry, RegistryEntry, RegistrySnapshot } from './WorldRuntimeRegistry';
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
import { ChatStreamCallbacks, ChatDelta, ChatStreamResult, ChatStreamHandle } from '../../models/ChatStreamTypes';
import { ChatRequestOptions } from '../../models/ChatRequest';
import { ProviderConfig } from '../../models/ProviderConfig';
import { generateUuid } from '../../utils/Uuid';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneRuntime';
const PERSISTENCE_THROTTLE_MS: number = 400;
const PERSISTENCE_MIN_CHARS: number = 64;

export interface WorldRuntimeObserver {
  onStreamingDelta(sessionId: string, messageId: string, content: string, operationId: number): void;
  onStreamingCompleted(sessionId: string, messageId: string, content: string, operationId: number): void;
  onStreamingFailed(sessionId: string, messageId: string, operationId: number): void;
  onStreamingCancelled(sessionId: string, messageId: string, operationId: number): void;
  onSpeakerStarted(
    sessionId: string,
    characterInstanceId: string,
    messageId: string,
    speakerIndex: number,
    totalSpeakers: number,
    operationId: number
  ): void;
  onRoundStarted(
    sessionId: string,
    generationBatchId: string,
    operationId: number,
    totalSpeakers: number
  ): void;
  onRoundCompleted(
    sessionId: string,
    generationBatchId: string,
    operationId: number
  ): void;
  onRoundFailed(
    sessionId: string,
    generationBatchId: string,
    failedCharacterInstanceId: string,
    failedMessageId: string,
    operationId: number
  ): void;
  onRoundCancelled(
    sessionId: string,
    generationBatchId: string,
    cancelledCharacterInstanceId: string,
    cancelledMessageId: string,
    operationId: number
  ): void;
}

export interface WorldRuntimeTurnOptions {
  worldId: string;
  sceneId: string;
  sessionId: string;
  userContent: string;
}

export interface WorldRuntimeTurnResult {
  userMessage: WorldSceneMessage;
  characterMessage: WorldSceneMessage;
  characterMessages: WorldSceneMessage[];
  generationBatchId: string;
}

export interface WorldRuntimeRetryOptions {
  worldId: string;
  sceneId: string;
  sessionId: string;
  failedMessageId: string;
}

export interface WorldRuntimeRetryResult {
  characterMessage: WorldSceneMessage;
  generationBatchId: string;
}

export interface WorldRuntimeResumeOptions {
  worldId: string;
  sceneId: string;
  sessionId: string;
  generationBatchId: string;
}

export interface WorldRuntimeResumeResult {
  characterMessages: WorldSceneMessage[];
  generationBatchId: string;
}

export enum WorldRoundInspectionStatus {
  Unknown,
  AllCompleted,
  PartiallyCompleted,
  HasFailed,
  HasCancelled,
  Mixed
}

export interface WorldRoundInspection {
  generationBatchId: string;
  totalSpeakers: number;
  completedCount: number;
  failedCount: number;
  cancelledCount: number;
  streamingCount: number;
  nextSpeakerIndex: number;
  nextSpeakerInstanceId: string;
  status: WorldRoundInspectionStatus;
  failedCharacterInstanceId: string;
  failedMessageId: string;
  cancelledCharacterInstanceId: string;
  cancelledMessageId: string;
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
  private observers: WorldRuntimeObserver[] = [];

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
    if (participants.length === 0) {
      throw WorldRuntimeError.participantSnapshotEmpty();
    }

    for (let i = 0; i < participants.length; i++) {
      const ps: WorldSessionParticipantSnapshot = participants[i];
      const instance: WorldCharacterInstance = await this.validateSpeakerInstance(
        ps.characterInstanceId,
        options.worldId,
        session
      );
      if (!instance.isActive) {
        throw WorldRuntimeError.participantInactive(ps.displayNameSnapshot);
      }
    }

    const playerProfile: WorldPlayerProfile = await this.validatePlayerProfile(options.worldId);
    const location: WorldLocation = await this.validateLocation(session.sceneId.length > 0 ? scene.locationId : '');

    const generationBatchId: string = 'batch-' + generateUuid();

    const entry: RegistryEntry | null = this.registry.tryAcquire(options.sessionId, generationBatchId);
    if (entry === null) {
      throw WorldRuntimeError.runtimeBusy();
    }

    const operationId: number = entry.operationId;

    const providerConfig: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (providerConfig === null) {
      this.registry.release(options.sessionId, operationId);
      throw WorldRuntimeError.modelRequestFailed('未配置 Provider');
    }

    try {
      const replyTargets: string[] = [];
      for (let i = 0; i < participants.length; i++) {
        replyTargets.push(participants[i].characterInstanceId);
      }

      const userMessage: WorldSceneMessage = await this.messageService.addUserMessage({
        worldId: options.worldId,
        sceneId: options.sceneId,
        sessionId: options.sessionId,
        content: trimmed,
        replyTargetCharacterInstanceIds: replyTargets
      });

      this.registry.updateSpeakerProgress(
        options.sessionId, operationId, '', '', 0, participants.length
      );

      this.notifyRoundStarted(options.sessionId, generationBatchId, operationId, participants.length);

      const characterMessages: WorldSceneMessage[] = [];
      let roundTerminalFired: boolean = false;

      for (let speakerIdx = 0; speakerIdx < participants.length; speakerIdx++) {
        if (!this.registry.isCurrent(options.sessionId, operationId)) {
          Logger.info(LOG_TAG, 'round interrupted before speaker ' + speakerIdx.toString());
          if (!roundTerminalFired) {
            const cancelledInstId: string = this.registry.getSnapshot(options.sessionId)?.currentSpeakerCharacterInstanceId ?? '';
            const cancelledMsgId: string = this.registry.getSnapshot(options.sessionId)?.currentSpeakerMessageId ?? '';
            this.notifyRoundCancelled(options.sessionId, generationBatchId, cancelledInstId, cancelledMsgId, operationId);
            roundTerminalFired = true;
          }
          break;
        }

        const speakerSnapshot: WorldSessionParticipantSnapshot = participants[speakerIdx];
        const speakerInstance: WorldCharacterInstance = await this.validateSpeakerInstance(
          speakerSnapshot.characterInstanceId,
          options.worldId,
          session
        );
        const speakerCharacter: Character = await this.validateSpeakerCharacter(speakerInstance.characterId);

        const otherNames: Map<string, string> = this.buildOtherParticipantNames(participants, speakerIdx);

        const characterPlaceholder: WorldSceneMessage = await this.messageService.addCharacterPlaceholder({
          worldId: options.worldId,
          sceneId: options.sceneId,
          sessionId: options.sessionId,
          senderCharacterInstanceId: speakerSnapshot.characterInstanceId,
          generationBatchId: generationBatchId
        });

        this.registry.updateSpeakerProgress(
          options.sessionId, operationId,
          speakerSnapshot.characterInstanceId, characterPlaceholder.id,
          speakerIdx, participants.length
        );

        this.notifySpeakerStarted(
          options.sessionId,
          speakerSnapshot.characterInstanceId,
          characterPlaceholder.id,
          speakerIdx,
          participants.length,
          operationId
        );

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
          generationBatchId: generationBatchId,
          allParticipantSnapshots: participants,
          otherParticipantDisplayNames: otherNames
        };

        const promptResult: WorldPromptAssemblyResult = await this.promptAssembler.assemble(promptInput);

        this.streamingContent = '';
        this.lastPersistedLength = 0;

        const speakerCompleted: boolean = await this.generateForSpeaker(
          options.sessionId,
          operationId,
          generationBatchId,
          characterPlaceholder,
          speakerSnapshot,
          promptResult,
          providerConfig
        );

        if (speakerCompleted) {
          characterMessages.push(characterPlaceholder);
        } else {
          Logger.info(LOG_TAG, 'speaker failed/stopped: idx=' + speakerIdx.toString()
            + ' round aborted');
          if (!roundTerminalFired) {
            const lastEntry: RegistryEntry | null = this.registry.getEntry(options.sessionId);
            if (lastEntry !== null && lastEntry.operationId === operationId) {
              this.notifyRoundFailed(
                options.sessionId, generationBatchId,
                speakerSnapshot.characterInstanceId, characterPlaceholder.id,
                operationId
              );
            } else {
              this.notifyRoundCancelled(
                options.sessionId, generationBatchId,
                speakerSnapshot.characterInstanceId, characterPlaceholder.id,
                operationId
              );
            }
            roundTerminalFired = true;
          }
          break;
        }
      }

      if (!roundTerminalFired && this.registry.isCurrent(options.sessionId, operationId)) {
        this.notifyRoundCompleted(options.sessionId, generationBatchId, operationId);
      }

      if (this.registry.isCurrent(options.sessionId, operationId)) {
        this.registry.release(options.sessionId, operationId);
      }

      return {
        userMessage: userMessage,
        characterMessage: characterMessages.length > 0 ? characterMessages[0] : userMessage,
        characterMessages: characterMessages,
        generationBatchId: generationBatchId
      };
    } catch (e) {
      if (this.registry.isCurrent(options.sessionId, operationId)) {
        this.registry.release(options.sessionId, operationId);
      }
      if (e instanceof WorldRuntimeError) {
        throw e;
      }
      throw WorldRuntimeError.modelRequestFailed((e as Error).message);
    }
  }

  private async generateForSpeaker(
    sessionId: string,
    operationId: number,
    generationBatchId: string,
    placeholder: WorldSceneMessage,
    speakerSnapshot: WorldSessionParticipantSnapshot,
    promptResult: WorldPromptAssemblyResult,
    providerConfig: ProviderConfig
  ): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      const self: WorldSceneRuntimeService = this;
      let resolved: boolean = false;

      const finish = (success: boolean): void => {
        if (resolved) {
          return;
        }
        resolved = true;
        resolve(success);
      };

      const callbacks: ChatStreamCallbacks = {
        onStart: () => {
          Logger.info(LOG_TAG, 'speaker streaming started: op=' + operationId.toString()
            + ' speaker=' + self.shortId(speakerSnapshot.characterInstanceId));
        },

        onDelta: (delta: ChatDelta) => {
          if (!self.registry.isCurrent(sessionId, operationId)) {
            return;
          }
          self.streamingContent += delta.content;
          self.scheduleStreamingFlush(placeholder.id, sessionId, operationId);
          self.notifyDelta(sessionId, placeholder.id, self.streamingContent, operationId);
        },

        onComplete: (result: ChatStreamResult) => {
          if (!self.registry.isCurrent(sessionId, operationId)) {
            Logger.info(LOG_TAG, 'late onComplete discarded: op=' + operationId.toString());
            finish(false);
            return;
          }
          self.clearPersistenceTimer();
          const finalContent: string = result.content.length > 0 ? result.content : self.streamingContent;
          self.streamingContent = finalContent;

          if (finalContent.trim().length === 0) {
            self.messageService.finalizeCharacterMessage({
              messageId: placeholder.id,
              content: finalContent,
              status: WorldSceneMessageStatus.Failed
            }).then((_success: boolean) => {
              self.notifyFailed(sessionId, placeholder.id, operationId);
              self.registry.release(sessionId, operationId);
              finish(false);
            }).catch((_e: Error) => {
              self.registry.release(sessionId, operationId);
              finish(false);
            });
            return;
          }

          self.messageService.finalizeCharacterMessage({
            messageId: placeholder.id,
            content: finalContent,
            status: WorldSceneMessageStatus.Completed
          }).then((success: boolean) => {
            if (!success) {
              Logger.warn(LOG_TAG, 'finalize Completed failed for msg=' + self.shortId(placeholder.id));
            }
            self.notifyCompleted(sessionId, placeholder.id, finalContent, operationId);
            finish(true);
          }).catch((_e: Error) => {
            Logger.error(LOG_TAG, 'finalize error: ' + _e.message);
            finish(false);
          });
        },

        onError: (error: Error) => {
          if (!self.registry.isCurrent(sessionId, operationId)) {
            Logger.info(LOG_TAG, 'late onError discarded: op=' + operationId.toString());
            finish(false);
            return;
          }
          self.clearPersistenceTimer();
          const currentContent: string = self.streamingContent;
          self.messageService.finalizeCharacterMessage({
            messageId: placeholder.id,
            content: currentContent,
            status: WorldSceneMessageStatus.Failed
          }).then((_success: boolean) => {
            self.notifyFailed(sessionId, placeholder.id, operationId);
            self.registry.release(sessionId, operationId);
            finish(false);
          }).catch((_e: Error) => {
            Logger.error(LOG_TAG, 'finalize-on-error failed: ' + _e.message);
            self.registry.release(sessionId, operationId);
            finish(false);
          });
        }
      };

      const requestOptions: ChatRequestOptions = {
        temperature: promptResult.temperature ?? providerConfig.temperature,
        topP: promptResult.topP ?? providerConfig.topP,
        maxTokens: promptResult.maxTokens ?? providerConfig.maxTokens,
        stream: true
      };

      const handle: ChatStreamHandle = self.modelService.streamChatWithConfig(
        providerConfig,
        promptResult.messages,
        requestOptions,
        callbacks
      );

      self.registry.attachHandle(sessionId, operationId, handle);
    });
  }

  stop(sessionId: string): boolean {
    const entry: RegistryEntry | null = this.registry.getEntry(sessionId);
    if (entry === null) {
      return false;
    }
    const operationId: number = entry.operationId;
    const generationBatchId: string = entry.generationBatchId;
    const cancelledInstId: string = entry.currentSpeakerCharacterInstanceId;
    const cancelledMsgId: string = entry.currentSpeakerMessageId;
    const result: boolean = this.registry.stop(sessionId);
    if (result) {
      this.clearPersistenceTimer();
      if (cancelledMsgId.length > 0) {
        this.notifyCancelled(sessionId, cancelledMsgId, operationId);
      }
      this.notifyRoundCancelled(sessionId, generationBatchId, cancelledInstId, cancelledMsgId, operationId);
    }
    return result;
  }

  isBusy(sessionId: string): boolean {
    return this.registry.isBusy(sessionId);
  }

  addObserver(observer: WorldRuntimeObserver): void {
    if (this.observers.indexOf(observer) < 0) {
      this.observers.push(observer);
    }
  }

  removeObserver(observer: WorldRuntimeObserver): void {
    const idx: number = this.observers.indexOf(observer);
    if (idx >= 0) {
      this.observers.splice(idx, 1);
    }
  }

  getOperationId(sessionId: string): number {
    return this.registry.getOperationId(sessionId);
  }

  async retryFailedCharacterMessage(options: WorldRuntimeRetryOptions): Promise<WorldRuntimeRetryResult> {
    const failedMessage: WorldSceneMessage | null = await this.messageRepo.getById(options.failedMessageId);
    if (failedMessage === null) {
      throw WorldRuntimeError.messagePersistenceFailed('Failed message not found');
    }
    if (failedMessage.status !== WorldSceneMessageStatus.Failed) {
      throw WorldRuntimeError.messagePersistenceFailed('Message is not in Failed status');
    }

    const session: WorldConversationSession = await this.validateSessionForRetry(options);
    const scene: WorldScene = await this.validateSceneForRetry(options, session);
    const world: World = await this.validateWorldForRetry(options);

    const participants = deserializeParticipantSnapshots(session.participantSnapshotJson);
    if (participants.length === 0) {
      throw WorldRuntimeError.participantSnapshotEmpty();
    }

    const speakerInstanceId: string = failedMessage.senderCharacterInstanceId ?? '';
    if (speakerInstanceId.length === 0) {
      throw WorldRuntimeError.messagePersistenceFailed('Failed message has no sender');
    }

    const speakerSnapshot: WorldSessionParticipantSnapshot | null = this.findParticipantSnapshot(participants, speakerInstanceId);
    if (speakerSnapshot === null) {
      throw WorldRuntimeError.participantNotFound();
    }

    const speakerInstance: WorldCharacterInstance = await this.validateSpeakerInstance(
      speakerSnapshot.characterInstanceId,
      options.worldId,
      session
    );
    const speakerCharacter: Character = await this.validateSpeakerCharacter(speakerInstance.characterId);
    const playerProfile: WorldPlayerProfile = await this.validatePlayerProfile(options.worldId);
    const location: WorldLocation = await this.validateLocation(scene.locationId);

    const generationBatchId: string = 'batch-' + generateUuid();

    const entry: RegistryEntry | null = this.registry.tryAcquire(options.sessionId, generationBatchId);
    if (entry === null) {
      throw WorldRuntimeError.runtimeBusy();
    }

    const operationId: number = entry.operationId;

    const providerConfig: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (providerConfig === null) {
      this.registry.release(options.sessionId, operationId);
      throw WorldRuntimeError.modelRequestFailed('未配置 Provider');
    }

    try {
      const characterPlaceholder: WorldSceneMessage = await this.messageService.addCharacterPlaceholder({
        worldId: options.worldId,
        sceneId: options.sceneId,
        sessionId: options.sessionId,
        senderCharacterInstanceId: speakerSnapshot.characterInstanceId,
        generationBatchId: generationBatchId
      });

      const otherNames: Map<string, string> = this.buildOtherParticipantNames(
        participants,
        participants.indexOf(speakerSnapshot)
      );

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
        generationBatchId: generationBatchId,
        allParticipantSnapshots: participants,
        otherParticipantDisplayNames: otherNames
      };

      const promptResult: WorldPromptAssemblyResult = await this.promptAssembler.assemble(promptInput);

      this.streamingContent = '';
      this.lastPersistedLength = 0;

      this.notifySpeakerStarted(
        options.sessionId,
        speakerSnapshot.characterInstanceId,
        characterPlaceholder.id,
        0,
        1,
        operationId
      );

      const retryCompleted: boolean = await this.generateForSpeaker(
        options.sessionId,
        operationId,
        generationBatchId,
        characterPlaceholder,
        speakerSnapshot,
        promptResult,
        providerConfig
      );

      if (retryCompleted) {
        return {
          characterMessage: characterPlaceholder,
          generationBatchId: generationBatchId
        };
      } else {
        throw WorldRuntimeError.modelRequestFailed('重试生成失败');
      }
    } catch (e) {
      if (this.registry.isCurrent(options.sessionId, operationId)) {
        this.registry.release(options.sessionId, operationId);
      }
      if (e instanceof WorldRuntimeError) {
        throw e;
      }
      throw WorldRuntimeError.modelRequestFailed((e as Error).message);
    }
  }

  async recoverOrphanedStreamingMessages(sessionId: string): Promise<number> {
    if (this.registry.isBusy(sessionId)) {
      return 0;
    }
    const messages: WorldSceneMessage[] = await this.messageRepo.listBySessionId(sessionId);
    let recoveredCount: number = 0;
    for (let i = 0; i < messages.length; i++) {
      const m: WorldSceneMessage = messages[i];
      if (m.status === WorldSceneMessageStatus.Streaming) {
        const success: boolean = await this.messageService.finalizeCharacterMessage({
          messageId: m.id,
          content: m.content,
          status: WorldSceneMessageStatus.Cancelled
        });
        if (success) {
          recoveredCount = recoveredCount + 1;
          Logger.info(LOG_TAG, 'orphan streaming recovered: msg=' + this.shortId(m.id));
        }
      }
    }
    return recoveredCount;
  }

  async inspectLatestRound(sessionId: string): Promise<WorldRoundInspection | null> {
    const messages: WorldSceneMessage[] = await this.messageRepo.listBySessionId(sessionId);
    if (messages.length === 0) {
      return null;
    }

    let latestBatchId: string = '';
    for (let i = messages.length - 1; i >= 0; i--) {
      const m: WorldSceneMessage = messages[i];
      if (m.generationBatchId !== undefined && m.generationBatchId.length > 0) {
        latestBatchId = m.generationBatchId;
        break;
      }
    }
    if (latestBatchId.length === 0) {
      return null;
    }

    const batchMessages: WorldSceneMessage[] = await this.messageRepo.listBySessionAndGenerationBatch(
      sessionId, latestBatchId
    );

    const session: WorldConversationSession | null = await this.sessionRepo.getById(sessionId);
    if (session === null) {
      return null;
    }
    const participants: WorldSessionParticipantSnapshot[] = deserializeParticipantSnapshots(session.participantSnapshotJson);
    const totalSpeakers: number = participants.length;

    let completedCount: number = 0;
    let failedCount: number = 0;
    let cancelledCount: number = 0;
    let streamingCount: number = 0;
    let failedInstId: string = '';
    let failedMsgId: string = '';
    let cancelledInstId: string = '';
    let cancelledMsgId: string = '';

    for (let i = 0; i < batchMessages.length; i++) {
      const m: WorldSceneMessage = batchMessages[i];
      if (m.senderType !== WorldSceneMessageSenderType.Character) {
        continue;
      }
      if (m.status === WorldSceneMessageStatus.Completed) {
        completedCount++;
      } else if (m.status === WorldSceneMessageStatus.Failed) {
        failedCount++;
        if (failedInstId.length === 0 && m.senderCharacterInstanceId !== undefined) {
          failedInstId = m.senderCharacterInstanceId;
          failedMsgId = m.id;
        }
      } else if (m.status === WorldSceneMessageStatus.Cancelled) {
        cancelledCount++;
        if (cancelledInstId.length === 0 && m.senderCharacterInstanceId !== undefined) {
          cancelledInstId = m.senderCharacterInstanceId;
          cancelledMsgId = m.id;
        }
      } else if (m.status === WorldSceneMessageStatus.Streaming) {
        streamingCount++;
      }
    }

    const nextSpeakerIndex: number = completedCount;
    let nextSpeakerInstId: string = '';
    if (nextSpeakerIndex < participants.length) {
      nextSpeakerInstId = participants[nextSpeakerIndex].characterInstanceId;
    }

    let status: WorldRoundInspectionStatus = WorldRoundInspectionStatus.Unknown;
    if (streamingCount > 0) {
      status = WorldRoundInspectionStatus.Unknown;
    } else if (failedCount > 0 && cancelledCount > 0) {
      status = WorldRoundInspectionStatus.Mixed;
    } else if (failedCount > 0) {
      status = WorldRoundInspectionStatus.HasFailed;
    } else if (cancelledCount > 0) {
      status = WorldRoundInspectionStatus.HasCancelled;
    } else if (completedCount >= totalSpeakers) {
      status = WorldRoundInspectionStatus.AllCompleted;
    } else {
      status = WorldRoundInspectionStatus.PartiallyCompleted;
    }

    return {
      generationBatchId: latestBatchId,
      totalSpeakers: totalSpeakers,
      completedCount: completedCount,
      failedCount: failedCount,
      cancelledCount: cancelledCount,
      streamingCount: streamingCount,
      nextSpeakerIndex: nextSpeakerIndex,
      nextSpeakerInstanceId: nextSpeakerInstId,
      status: status,
      failedCharacterInstanceId: failedInstId,
      failedMessageId: failedMsgId,
      cancelledCharacterInstanceId: cancelledInstId,
      cancelledMessageId: cancelledMsgId
    };
  }

  getActiveRoundSnapshot(sessionId: string): RegistrySnapshot | null {
    return this.registry.getSnapshot(sessionId);
  }

  async resumeInterruptedRound(options: WorldRuntimeResumeOptions): Promise<WorldRuntimeResumeResult> {
    if (this.registry.isBusy(options.sessionId)) {
      throw WorldRuntimeError.runtimeBusy();
    }

    const inspection: WorldRoundInspection | null = await this.inspectLatestRound(options.sessionId);
    if (inspection === null) {
      throw WorldRuntimeError.invalidBatchState('无可恢复的轮次');
    }

    if (inspection.generationBatchId !== options.generationBatchId) {
      throw WorldRuntimeError.invalidBatchState('批次ID不匹配');
    }

    if (inspection.status !== WorldRoundInspectionStatus.HasFailed
      && inspection.status !== WorldRoundInspectionStatus.HasCancelled
      && inspection.status !== WorldRoundInspectionStatus.PartiallyCompleted) {
      throw WorldRuntimeError.invalidBatchState('当前轮次状态不可恢复: ' + inspection.status.toString());
    }

    const session: WorldConversationSession = await this.validateSessionForResume(options);
    const scene: WorldScene = await this.validateSceneForResume(options, session);
    const world: World = await this.validateWorldForResume(options);

    const participants: WorldSessionParticipantSnapshot[] = deserializeParticipantSnapshots(session.participantSnapshotJson);
    if (participants.length === 0) {
      throw WorldRuntimeError.participantSnapshotEmpty();
    }

    const playerProfile: WorldPlayerProfile = await this.validatePlayerProfile(options.worldId);
    const location: WorldLocation = await this.validateLocation(scene.locationId);

    const resumeFromIndex: number = inspection.nextSpeakerIndex;
    if (resumeFromIndex >= participants.length) {
      throw WorldRuntimeError.invalidBatchState('所有角色已完成');
    }

    const entry: RegistryEntry | null = this.registry.tryAcquire(options.sessionId, options.generationBatchId);
    if (entry === null) {
      throw WorldRuntimeError.runtimeBusy();
    }

    const operationId: number = entry.operationId;

    const providerConfig: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (providerConfig === null) {
      this.registry.release(options.sessionId, operationId);
      throw WorldRuntimeError.modelRequestFailed('未配置 Provider');
    }

    try {
      this.registry.updateSpeakerProgress(
        options.sessionId, operationId, '', '', resumeFromIndex, participants.length
      );

      this.notifyRoundStarted(options.sessionId, options.generationBatchId, operationId, participants.length);

      const characterMessages: WorldSceneMessage[] = [];
      let roundTerminalFired: boolean = false;

      const existingBatchMessages: WorldSceneMessage[] = await this.messageRepo.listBySessionAndGenerationBatch(
        options.sessionId, options.generationBatchId
      );
      for (let i = 0; i < existingBatchMessages.length; i++) {
        const m: WorldSceneMessage = existingBatchMessages[i];
        if (m.senderType === WorldSceneMessageSenderType.Character
          && m.status === WorldSceneMessageStatus.Completed) {
          characterMessages.push(m);
        }
      }

      for (let speakerIdx = resumeFromIndex; speakerIdx < participants.length; speakerIdx++) {
        if (!this.registry.isCurrent(options.sessionId, operationId)) {
          Logger.info(LOG_TAG, 'resume round interrupted before speaker ' + speakerIdx.toString());
          if (!roundTerminalFired) {
            const cancelledInstId: string = this.registry.getSnapshot(options.sessionId)?.currentSpeakerCharacterInstanceId ?? '';
            const cancelledMsgId: string = this.registry.getSnapshot(options.sessionId)?.currentSpeakerMessageId ?? '';
            this.notifyRoundCancelled(options.sessionId, options.generationBatchId, cancelledInstId, cancelledMsgId, operationId);
            roundTerminalFired = true;
          }
          break;
        }

        const speakerSnapshot: WorldSessionParticipantSnapshot = participants[speakerIdx];
        const speakerInstance: WorldCharacterInstance = await this.validateSpeakerInstance(
          speakerSnapshot.characterInstanceId,
          options.worldId,
          session
        );
        const speakerCharacter: Character = await this.validateSpeakerCharacter(speakerInstance.characterId);
        const otherNames: Map<string, string> = this.buildOtherParticipantNames(participants, speakerIdx);

        const characterPlaceholder: WorldSceneMessage = await this.messageService.addCharacterPlaceholder({
          worldId: options.worldId,
          sceneId: options.sceneId,
          sessionId: options.sessionId,
          senderCharacterInstanceId: speakerSnapshot.characterInstanceId,
          generationBatchId: options.generationBatchId
        });

        this.registry.updateSpeakerProgress(
          options.sessionId, operationId,
          speakerSnapshot.characterInstanceId, characterPlaceholder.id,
          speakerIdx, participants.length
        );

        this.notifySpeakerStarted(
          options.sessionId,
          speakerSnapshot.characterInstanceId,
          characterPlaceholder.id,
          speakerIdx,
          participants.length,
          operationId
        );

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
          generationBatchId: options.generationBatchId,
          allParticipantSnapshots: participants,
          otherParticipantDisplayNames: otherNames
        };

        const promptResult: WorldPromptAssemblyResult = await this.promptAssembler.assemble(promptInput);

        this.streamingContent = '';
        this.lastPersistedLength = 0;

        const speakerCompleted: boolean = await this.generateForSpeaker(
          options.sessionId,
          operationId,
          options.generationBatchId,
          characterPlaceholder,
          speakerSnapshot,
          promptResult,
          providerConfig
        );

        if (speakerCompleted) {
          characterMessages.push(characterPlaceholder);
        } else {
          Logger.info(LOG_TAG, 'resume speaker failed/stopped: idx=' + speakerIdx.toString());
          if (!roundTerminalFired) {
            const lastEntry: RegistryEntry | null = this.registry.getEntry(options.sessionId);
            if (lastEntry !== null && lastEntry.operationId === operationId) {
              this.notifyRoundFailed(
                options.sessionId, options.generationBatchId,
                speakerSnapshot.characterInstanceId, characterPlaceholder.id,
                operationId
              );
            } else {
              this.notifyRoundCancelled(
                options.sessionId, options.generationBatchId,
                speakerSnapshot.characterInstanceId, characterPlaceholder.id,
                operationId
              );
            }
            roundTerminalFired = true;
          }
          break;
        }
      }

      if (!roundTerminalFired && this.registry.isCurrent(options.sessionId, operationId)) {
        this.notifyRoundCompleted(options.sessionId, options.generationBatchId, operationId);
      }

      if (this.registry.isCurrent(options.sessionId, operationId)) {
        this.registry.release(options.sessionId, operationId);
      }

      return {
        characterMessages: characterMessages,
        generationBatchId: options.generationBatchId
      };
    } catch (e) {
      if (this.registry.isCurrent(options.sessionId, operationId)) {
        this.registry.release(options.sessionId, operationId);
      }
      if (e instanceof WorldRuntimeError) {
        throw e;
      }
      throw WorldRuntimeError.modelRequestFailed((e as Error).message);
    }
  }

  private findParticipantSnapshot(
    participants: WorldSessionParticipantSnapshot[],
    instanceId: string
  ): WorldSessionParticipantSnapshot | null {
    for (let i = 0; i < participants.length; i++) {
      if (participants[i].characterInstanceId === instanceId) {
        return participants[i];
      }
    }
    return null;
  }

  private buildOtherParticipantNames(
    participants: WorldSessionParticipantSnapshot[],
    currentSpeakerIndex: number
  ): Map<string, string> {
    const result: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < participants.length; i++) {
      if (i !== currentSpeakerIndex) {
        result.set(participants[i].characterInstanceId, participants[i].displayNameSnapshot);
      }
    }
    return result;
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

  private notifyDelta(sessionId: string, messageId: string, content: string, operationId: number): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onStreamingDelta(sessionId, messageId, content, operationId);
    }
  }

  private notifyCompleted(sessionId: string, messageId: string, content: string, operationId: number): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onStreamingCompleted(sessionId, messageId, content, operationId);
    }
  }

  private notifyFailed(sessionId: string, messageId: string, operationId: number): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onStreamingFailed(sessionId, messageId, operationId);
    }
  }

  private notifyCancelled(sessionId: string, messageId: string, operationId: number): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onStreamingCancelled(sessionId, messageId, operationId);
    }
  }

  private notifySpeakerStarted(
    sessionId: string,
    characterInstanceId: string,
    messageId: string,
    speakerIndex: number,
    totalSpeakers: number,
    operationId: number
  ): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onSpeakerStarted(sessionId, characterInstanceId, messageId, speakerIndex, totalSpeakers, operationId);
    }
  }

  private notifyRoundStarted(
    sessionId: string,
    generationBatchId: string,
    operationId: number,
    totalSpeakers: number
  ): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onRoundStarted(sessionId, generationBatchId, operationId, totalSpeakers);
    }
  }

  private notifyRoundCompleted(
    sessionId: string,
    generationBatchId: string,
    operationId: number
  ): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onRoundCompleted(sessionId, generationBatchId, operationId);
    }
  }

  private notifyRoundFailed(
    sessionId: string,
    generationBatchId: string,
    failedCharacterInstanceId: string,
    failedMessageId: string,
    operationId: number
  ): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onRoundFailed(sessionId, generationBatchId, failedCharacterInstanceId, failedMessageId, operationId);
    }
  }

  private notifyRoundCancelled(
    sessionId: string,
    generationBatchId: string,
    cancelledCharacterInstanceId: string,
    cancelledMessageId: string,
    operationId: number
  ): void {
    for (let i = 0; i < this.observers.length; i++) {
      this.observers[i].onRoundCancelled(sessionId, generationBatchId, cancelledCharacterInstanceId, cancelledMessageId, operationId);
    }
  }

  private async validateSessionForRetry(options: WorldRuntimeRetryOptions): Promise<WorldConversationSession> {
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

  private async validateSceneForRetry(options: WorldRuntimeRetryOptions, session: WorldConversationSession): Promise<WorldScene> {
    const scene: WorldScene | null = await this.sceneRepo.getById(options.sceneId);
    if (scene === null) {
      throw WorldRuntimeError.sceneNotFound();
    }
    if (scene.status === WorldSceneStatus.Ended) {
      throw WorldRuntimeError.sceneEnded();
    }
    return scene;
  }

  private async validateWorldForRetry(options: WorldRuntimeRetryOptions): Promise<World> {
    const world: World | null = await this.worldRepo.getById(options.worldId);
    if (world === null) {
      throw WorldRuntimeError.worldNotFound();
    }
    return world;
  }

  private async validateSessionForResume(options: WorldRuntimeResumeOptions): Promise<WorldConversationSession> {
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

  private async validateSceneForResume(options: WorldRuntimeResumeOptions, session: WorldConversationSession): Promise<WorldScene> {
    const scene: WorldScene | null = await this.sceneRepo.getById(options.sceneId);
    if (scene === null) {
      throw WorldRuntimeError.sceneNotFound();
    }
    if (scene.status === WorldSceneStatus.Ended) {
      throw WorldRuntimeError.sceneEnded();
    }
    return scene;
  }

  private async validateWorldForResume(options: WorldRuntimeResumeOptions): Promise<World> {
    const world: World | null = await this.worldRepo.getById(options.worldId);
    if (world === null) {
      throw WorldRuntimeError.worldNotFound();
    }
    return world;
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
