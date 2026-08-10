import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { CharacterService } from '../../services/CharacterService';
import { WorldSceneService } from '../../services/world/WorldSceneService';
import {
  WorldSceneRuntimeService,
  WorldRuntimeObserver,
  WorldRuntimeTurnOptions,
  WorldRuntimeRetryOptions,
  WorldRuntimeResumeOptions,
  WorldRoundInspection,
  WorldRoundInspectionStatus
} from '../../services/world/WorldSceneRuntimeService';
import { RegistrySnapshot } from '../../services/world/WorldRuntimeRegistry';
import { Logger } from '../../utils/Logger';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocation, WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus
} from '../../models/world/WorldSceneMessage';
import { Character } from '../../models/Character';
import { DatabaseError } from '../../models/DatabaseError';
import { WorldRuntimeError } from '../../models/world/WorldRuntimeError';
import { mapWorldRuntimeErrorToMessage, isWorldRuntimeError } from './WorldRuntimeErrorMapper';
import { mapWorldSceneErrorToMessage } from './WorldSceneErrorMapper';
import { mapWorldStateErrorToMessage } from './WorldStateErrorMapper';
import {
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from './WorldUiModels';

const LOG_TAG: string = 'WorldSceneChatVM';

export enum WorldSceneChatLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

export interface ChatCharacterUiModel {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly fallbackName: string;
  readonly isActive: boolean;
  readonly characterCardMissing: boolean;
}

export interface ChatMessageUiModel {
  readonly id: string;
  readonly sequenceNumber: number;
  readonly senderType: WorldSceneMessageSenderType;
  readonly senderDisplayName: string;
  readonly senderInstanceId: string;
  readonly senderAvatarUri: string;
  readonly senderFallbackName: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly messageStatus: string;
  readonly recipientNames: string[];
  readonly witnessNames: string[];
  readonly replyTargetNames: string[];
  readonly createdAt: number;
  readonly senderRemoved: boolean;
}

export interface RoundProgressUiModel {
  readonly currentSpeakerIndex: number;
  readonly totalSpeakers: number;
  readonly currentSpeakerInstanceId: string;
  readonly currentSpeakerDisplayName: string;
  readonly generationBatchId: string;
  readonly roundStatus: string;
}

export enum WorldRoundUiStatus {
  Idle,
  Running,
  Completed,
  Failed,
  Cancelled,
  Resumable
}

export interface WorldSceneChatUiModel {
  readonly sceneId: string;
  readonly sceneName: string;
  readonly worldId: string;
  readonly worldName: string;
  readonly worldStatus: WorldStatus;
  readonly locationId: string;
  readonly locationName: string;
  readonly locationStatus: WorldLocationStatus;
  readonly sceneStatus: WorldSceneStatus;
  readonly sessionId: string;
  readonly sessionStatus: WorldConversationSessionStatus;
  readonly sessionSequenceNumber: number;
  readonly sessionParticipantSnapshot: WorldSessionParticipantSnapshot[];
  readonly playerDisplayNameSnapshot: string;
  readonly startedAt: number;
  readonly endedAt: number;
  readonly participantCount: number;
  readonly characters: ChatCharacterUiModel[];
  readonly messages: ChatMessageUiModel[];
}

export class WorldSceneChatViewModel implements WorldRuntimeObserver {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly characterService: CharacterService;
  private readonly sceneService: WorldSceneService;
  private readonly runtimeService: WorldSceneRuntimeService;

  state: WorldSceneChatLoadState = WorldSceneChatLoadState.Loading;
  errorMessage: string = '';
  detail: WorldSceneChatUiModel | null = null;

  isSending: boolean = false;
  isGenerating: boolean = false;
  isStopping: boolean = false;
  runtimeError: string = '';

  streamingMessageId: string = '';
  streamingContent: string = '';
  private currentOperationId: number = -1;

  roundProgress: RoundProgressUiModel | null = null;
  roundStatus: WorldRoundUiStatus = WorldRoundUiStatus.Idle;
  lastInspection: WorldRoundInspection | null = null;

  private expectedSceneId: string = '';
  private expectedSessionId: string = '';
  private expectedWorldId: string = '';
  private expectedLocationId: string = '';
  private loadOperationId: number = 0;
  private operationId: number = 0;
  private disposed: boolean = false;
  readonly instanceShortId: string;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    sessionRepo: WorldConversationSessionRepository,
    characterService: CharacterService,
    sceneService: WorldSceneService,
    runtimeService: WorldSceneRuntimeService
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.sessionRepo = sessionRepo;
    this.characterService = characterService;
    this.sceneService = sceneService;
    this.runtimeService = runtimeService;
    this.instanceShortId = WorldSceneChatViewModel.generateShortId();
    this.runtimeService.addObserver(this);
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  dispose(): void {
    this.disposed = true;
    this.runtimeService.removeObserver(this);
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  setSceneId(sceneId: string): void {
    if (this.expectedSceneId !== sceneId) {
      this.expectedSceneId = sceneId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  setSessionId(sessionId: string): void {
    if (this.expectedSessionId !== sessionId) {
      this.expectedSessionId = sessionId;
      this.loadOperationId = this.loadOperationId + 1;
    }
  }

  setWorldId(worldId: string): void {
    this.expectedWorldId = worldId;
  }

  setLocationId(locationId: string): void {
    this.expectedLocationId = locationId;
  }

  expectedSceneIdOfPage(): string {
    return this.expectedSceneId;
  }

  expectedSessionIdOfPage(): string {
    return this.expectedSessionId;
  }

  isSingleParticipant(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sessionParticipantSnapshot.length === 1;
  }

  isMultiParticipant(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sessionParticipantSnapshot.length >= 2;
  }

  isZeroParticipant(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sessionParticipantSnapshot.length === 0;
  }

  async loadSnapshot(sceneId: string): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed vmInstance=' + this.instanceShortId);
      return;
    }
    if (this.expectedSessionId.length === 0) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: sessionId empty');
      this.state = WorldSceneChatLoadState.Error;
      this.errorMessage = '会话ID缺失,无法加载聊天';
      return;
    }
    this.expectedSceneId = sceneId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;
    const targetSceneId: string = sceneId;

    this.state = WorldSceneChatLoadState.Loading;
    this.errorMessage = '';

    try {
      const scene: WorldScene | null = await this.sceneRepo.getById(targetSceneId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (scene === null) {
        this.state = WorldSceneChatLoadState.NotFound;
        return;
      }

      const world: World | null = await this.worldRepo.getById(scene.worldId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      if (world === null) {
        this.state = WorldSceneChatLoadState.NotFound;
        return;
      }
      this.expectedWorldId = world.id;

      const location: WorldLocation | null = await this.locationRepo.getById(scene.locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const locationName: string = location !== null ? location.name : '(地点已删除)';
      const locationStatus: WorldLocationStatus = location !== null
        ? location.status as WorldLocationStatus : WorldLocationStatus.Archived;

      let session: WorldConversationSession | null = null;
      if (this.expectedSessionId.length > 0) {
        session = await this.safeGetSession(this.expectedSessionId);
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      const sessionStatus: WorldConversationSessionStatus = session !== null
        ? session.status as WorldConversationSessionStatus : WorldConversationSessionStatus.Ended;
      const sessionId: string = session !== null ? session.id : '';
      const sessionSequence: number = session !== null ? session.sequenceNumber : 0;
      const participantSnapshot: WorldSessionParticipantSnapshot[] = session !== null
        ? this.safeDeserializeSnapshots(session.participantSnapshotJson) : [];
      const playerDisplayName: string = session !== null ? session.playerDisplayNameSnapshot : '玩家';

      let messages: WorldSceneMessage[] = [];
      if (sessionId.length > 0) {
        messages = await this.safeListMessagesBySession(sessionId);
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      if (session !== null && !this.runtimeService.isBusy(sessionId)) {
        const recovered: number = await this.runtimeService.recoverOrphanedStreamingMessages(sessionId);
        if (recovered > 0) {
          Logger.info(LOG_TAG, 'orphan recovery: ' + recovered.toString() + ' messages');
          messages = await this.safeListMessagesBySession(sessionId);
        }
      }

      if (this.runtimeService.isBusy(sessionId)) {
        this.isGenerating = true;
        const opId: number = this.runtimeService.getOperationId(sessionId);
        if (opId >= 0) {
          this.currentOperationId = opId;
        }
        const snapshot: RegistrySnapshot | null = this.runtimeService.getActiveRoundSnapshot(sessionId);
        if (snapshot !== null) {
          this.roundProgress = this.buildRoundProgress(
            snapshot.currentSpeakerIndex, snapshot.totalSpeakers,
            snapshot.currentSpeakerCharacterInstanceId,
            snapshot.generationBatchId, 'running'
          );
          this.roundStatus = WorldRoundUiStatus.Running;
        }
      } else {
        this.isGenerating = false;
        this.currentOperationId = -1;
        this.streamingMessageId = '';
        this.streamingContent = '';
      }

      const instanceMap: Map<string, WorldCharacterInstance> = new Map<string, WorldCharacterInstance>();
      const characterIdSet: Set<string> = new Set<string>();

      if (participantSnapshot.length > 0) {
        for (let i = 0; i < participantSnapshot.length; i++) {
          const ps: WorldSessionParticipantSnapshot = participantSnapshot[i];
          const inst: WorldCharacterInstance | null = await this.safeGetInstance(ps.characterInstanceId);
          if (inst !== null) {
            instanceMap.set(inst.id, inst);
            if (inst.characterId.length > 0) {
              characterIdSet.add(inst.characterId);
            }
          }
        }
      }

      for (let i = 0; i < messages.length; i++) {
        const m: WorldSceneMessage = messages[i];
        if (m.senderCharacterInstanceId !== undefined && !instanceMap.has(m.senderCharacterInstanceId)) {
          const histInst: WorldCharacterInstance | null = await this.safeGetInstance(m.senderCharacterInstanceId);
          if (histInst !== null) {
            instanceMap.set(histInst.id, histInst);
            if (histInst.characterId.length > 0) {
              characterIdSet.add(histInst.characterId);
            }
          }
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const characterMap: Map<string, Character | null> = new Map<string, Character | null>();
      const characterIds: string[] = Array.from(characterIdSet);
      for (let i = 0; i < characterIds.length; i++) {
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        const id: string = characterIds[i];
        try {
          const c: Character | null = await this.characterService.getById(id);
          characterMap.set(id, c);
        } catch (e) {
          Logger.warn(LOG_TAG, 'characterService.getById failed: ' + this.safeErrorCategory(e));
          characterMap.set(id, null);
        }
      }
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      const characterUiModels: ChatCharacterUiModel[] = [];
      if (participantSnapshot.length > 0) {
        for (let i = 0; i < participantSnapshot.length; i++) {
          const ps: WorldSessionParticipantSnapshot = participantSnapshot[i];
          const inst: WorldCharacterInstance | undefined = instanceMap.get(ps.characterInstanceId);
          if (inst === undefined) {
            characterUiModels.push({
              instanceId: ps.characterInstanceId,
              displayName: ps.displayNameSnapshot,
              avatarUri: '',
              fallbackName: ps.displayNameSnapshot,
              isActive: false,
              characterCardMissing: true
            });
            continue;
          }
          const character: Character | null | undefined = characterMap.get(inst.characterId);
          const missing: boolean = character === null || character === undefined;
          const displayName: string = !missing && character !== null && character !== undefined
            ? character.name : inst.displayNameSnapshot;
          const avatarUri: string = !missing && character !== null && character !== undefined
            ? character.avatarUri : '';
          characterUiModels.push({
            instanceId: inst.id,
            displayName: displayName,
            avatarUri: avatarUri,
            fallbackName: inst.displayNameSnapshot,
            isActive: inst.isActive,
            characterCardMissing: missing
          });
        }
      }

      const messageUiModels: ChatMessageUiModel[] = new Array<ChatMessageUiModel>(messages.length);
      for (let i = 0; i < messages.length; i++) {
        const m: WorldSceneMessage = messages[i];
        const senderInst: WorldCharacterInstance | undefined =
          m.senderCharacterInstanceId !== undefined ? instanceMap.get(m.senderCharacterInstanceId) : undefined;
        const senderCharacter: Character | null | undefined =
          senderInst !== undefined ? characterMap.get(senderInst.characterId) : undefined;
        const senderDisplayName: string = this.resolveInstanceDisplayName(
          m.senderCharacterInstanceId, instanceMap, characterMap);
        const senderAvatarUri: string = senderCharacter !== null && senderCharacter !== undefined
          ? senderCharacter.avatarUri : '';
        messageUiModels[i] = {
          id: m.id,
          sequenceNumber: m.sequenceNumber,
          senderType: m.senderType,
          senderDisplayName: senderDisplayName,
          senderInstanceId: m.senderCharacterInstanceId !== undefined ? m.senderCharacterInstanceId : '',
          senderAvatarUri: senderAvatarUri,
          senderFallbackName: senderInst !== undefined ? senderInst.displayNameSnapshot : '',
          content: m.content,
          visibility: m.visibility,
          messageStatus: m.status,
          recipientNames: this.resolveInstanceNames(m.recipientCharacterInstanceIds, instanceMap, characterMap),
          witnessNames: this.resolveInstanceNames(m.witnessCharacterInstanceIds, instanceMap, characterMap),
          replyTargetNames: this.resolveInstanceNames(m.replyTargetCharacterInstanceIds, instanceMap, characterMap),
          createdAt: m.createdAt,
          senderRemoved: m.senderCharacterInstanceId !== undefined
            && !instanceMap.has(m.senderCharacterInstanceId)
        };
      }

      const activeCharCount: number = characterUiModels.filter((c: ChatCharacterUiModel): boolean => c.isActive).length;

      const uiModel: WorldSceneChatUiModel = {
        sceneId: scene.id,
        sceneName: locationName + ' · 会话',
        worldId: world.id,
        worldName: world.name,
        worldStatus: world.status as WorldStatus,
        locationId: scene.locationId,
        locationName: locationName,
        locationStatus: locationStatus,
        sceneStatus: scene.status as WorldSceneStatus,
        sessionId: sessionId,
        sessionStatus: sessionStatus,
        sessionSequenceNumber: sessionSequence,
        sessionParticipantSnapshot: participantSnapshot,
        playerDisplayNameSnapshot: playerDisplayName,
        startedAt: scene.startedAt,
        endedAt: scene.endedAt !== undefined ? scene.endedAt : 0,
        participantCount: activeCharCount,
        characters: characterUiModels,
        messages: messageUiModels
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = WorldSceneChatLoadState.Ready;

      if (!this.runtimeService.isBusy(sessionId) && this.isMultiParticipant()) {
        this.checkResumableRound().catch((e: Error) => {
          Logger.warn(LOG_TAG, 'checkResumableRound error: ' + e.message);
        });
      }

      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', state=ready, messageCount=' + messageUiModels.length.toString()
        + ', sessionStatus=' + (session !== null ? session.status : 'null')
        + ', sceneShortId=' + this.shortId(targetSceneId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', ' + this.safeErrorCategory(e)
        + ', sceneShortId=' + this.shortId(targetSceneId));
      this.errorMessage = '场景数据加载失败,请重试';
      this.state = WorldSceneChatLoadState.Error;
    }
  }

  async sendMessage(content: string): Promise<string> {
    if (this.isGenerating || this.isSending) {
      return '当前角色正在回复中';
    }
    if (this.detail === null) {
      return '页面未加载完成';
    }
    const trimmed: string = content.trim();
    if (trimmed.length === 0) {
      return '消息不能为空';
    }

    this.isSending = true;
    this.runtimeError = '';
    this.roundStatus = WorldRoundUiStatus.Running;
    this.operationId = this.operationId + 1;

    try {
      const options: WorldRuntimeTurnOptions = {
        worldId: this.expectedWorldId,
        sceneId: this.expectedSceneId,
        sessionId: this.expectedSessionId,
        userContent: trimmed
      };

      const result = await this.runtimeService.sendAndGenerate(options);

      this.isGenerating = true;
      this.currentOperationId = this.runtimeService.getOperationId(this.expectedSessionId);
      this.streamingMessageId = result.characterMessage.id;
      this.streamingContent = '';

      this.updateRoundProgressFromResult(result.characterMessages, result.generationBatchId);

      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return '';
    } catch (e) {
      const msg: string = this.resolveRuntimeError(e);
      this.runtimeError = msg;
      this.roundStatus = WorldRoundUiStatus.Idle;
      Logger.warn(LOG_TAG, 'sendMessage failed: ' + this.safeErrorCategory(e));
      return msg;
    } finally {
      this.isSending = false;
    }
  }

  stopGeneration(): void {
    if (!this.isGenerating) {
      return;
    }
    this.isStopping = true;
    this.runtimeService.stop(this.expectedSessionId);
  }

  async retryFailedMessage(failedMessageId: string): Promise<string> {
    if (this.isGenerating || this.isSending) {
      return '当前角色正在回复中';
    }
    if (this.detail === null) {
      return '页面未加载完成';
    }

    this.isSending = true;
    this.runtimeError = '';
    this.roundStatus = WorldRoundUiStatus.Running;
    this.operationId = this.operationId + 1;

    try {
      const options: WorldRuntimeRetryOptions = {
        worldId: this.expectedWorldId,
        sceneId: this.expectedSceneId,
        sessionId: this.expectedSessionId,
        failedMessageId: failedMessageId
      };

      const result = await this.runtimeService.retryFailedCharacterMessage(options);

      this.isGenerating = true;
      this.currentOperationId = this.runtimeService.getOperationId(this.expectedSessionId);
      this.streamingMessageId = result.characterMessage.id;
      this.streamingContent = '';

      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return '';
    } catch (e) {
      const msg: string = this.resolveRuntimeError(e);
      this.runtimeError = msg;
      this.roundStatus = WorldRoundUiStatus.Idle;
      Logger.warn(LOG_TAG, 'retryFailedMessage failed: ' + this.safeErrorCategory(e));
      return msg;
    } finally {
      this.isSending = false;
    }
  }

  async endScene(): Promise<string> {
    if (this.isGenerating) {
      return '生成中不能结束场景,请先停止';
    }
    this.operationId = this.operationId + 1;
    try {
      await this.sceneService.endScene(this.expectedSceneId);
      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return '';
    } catch (e) {
      return this.resolveErrorMessage(e);
    }
  }

  onStreamingDelta(sessionId: string, messageId: string, content: string, operationId: number): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    this.streamingMessageId = messageId;
    this.streamingContent = content;
    this.isGenerating = true;
  }

  onStreamingCompleted(sessionId: string, messageId: string, content: string, operationId: number): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    if (this.isSingleParticipant()) {
      this.isGenerating = false;
      this.isStopping = false;
      this.streamingMessageId = '';
      this.streamingContent = '';
      this.currentOperationId = -1;
    }
    this.loadSnapshot(this.expectedSceneId);
  }

  onStreamingFailed(sessionId: string, messageId: string, operationId: number): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    if (this.isSingleParticipant()) {
      this.isGenerating = false;
      this.isStopping = false;
      this.streamingMessageId = '';
      this.streamingContent = '';
      this.currentOperationId = -1;
    }
    this.loadSnapshot(this.expectedSceneId);
  }

  onStreamingCancelled(sessionId: string, messageId: string, operationId: number): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    if (this.isSingleParticipant()) {
      this.isGenerating = false;
      this.isStopping = false;
      this.streamingMessageId = '';
      this.streamingContent = '';
      this.currentOperationId = -1;
    }
    this.loadSnapshot(this.expectedSceneId);
  }

  onSpeakerStarted(
    sessionId: string,
    characterInstanceId: string,
    messageId: string,
    speakerIndex: number,
    totalSpeakers: number,
    operationId: number
  ): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    this.streamingMessageId = messageId;
    this.streamingContent = '';
    this.isGenerating = true;

    if (this.detail !== null) {
      this.roundProgress = this.buildRoundProgress(
        speakerIndex, totalSpeakers, characterInstanceId,
        this.roundProgress !== null ? this.roundProgress.generationBatchId : '',
        'running'
      );
    }
  }

  onRoundStarted(
    sessionId: string,
    generationBatchId: string,
    operationId: number,
    totalSpeakers: number
  ): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    this.roundStatus = WorldRoundUiStatus.Running;
    if (this.detail !== null) {
      this.roundProgress = this.buildRoundProgress(
        0, totalSpeakers, '', generationBatchId, 'running'
      );
    }
  }

  onRoundCompleted(
    sessionId: string,
    generationBatchId: string,
    operationId: number
  ): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    this.isGenerating = false;
    this.isStopping = false;
    this.streamingMessageId = '';
    this.streamingContent = '';
    this.currentOperationId = -1;
    this.roundStatus = WorldRoundUiStatus.Completed;
    if (this.roundProgress !== null) {
      this.roundProgress = this.buildRoundProgress(
        this.roundProgress.totalSpeakers, this.roundProgress.totalSpeakers,
        '', generationBatchId, 'completed'
      );
    }
    this.loadSnapshot(this.expectedSceneId);
  }

  onRoundFailed(
    sessionId: string,
    generationBatchId: string,
    failedCharacterInstanceId: string,
    failedMessageId: string,
    operationId: number
  ): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    this.isGenerating = false;
    this.isStopping = false;
    this.streamingMessageId = '';
    this.streamingContent = '';
    this.currentOperationId = -1;
    this.roundStatus = WorldRoundUiStatus.Failed;
    if (this.roundProgress !== null) {
      this.roundProgress = this.buildRoundProgress(
        this.roundProgress.currentSpeakerIndex, this.roundProgress.totalSpeakers,
        failedCharacterInstanceId, generationBatchId, 'failed'
      );
    }
    this.loadSnapshot(this.expectedSceneId);
  }

  onRoundCancelled(
    sessionId: string,
    generationBatchId: string,
    cancelledCharacterInstanceId: string,
    cancelledMessageId: string,
    operationId: number
  ): void {
    if (sessionId !== this.expectedSessionId) {
      return;
    }
    if (operationId !== this.currentOperationId) {
      return;
    }
    this.isGenerating = false;
    this.isStopping = false;
    this.streamingMessageId = '';
    this.streamingContent = '';
    this.currentOperationId = -1;
    this.roundStatus = WorldRoundUiStatus.Cancelled;
    if (this.roundProgress !== null) {
      this.roundProgress = this.buildRoundProgress(
        this.roundProgress.currentSpeakerIndex, this.roundProgress.totalSpeakers,
        cancelledCharacterInstanceId, generationBatchId, 'cancelled'
      );
    }
    this.loadSnapshot(this.expectedSceneId);
  }

  async reload(): Promise<void> {
    await this.loadSnapshot(this.expectedSceneId);
  }

  async checkResumableRound(): Promise<void> {
    if (this.expectedSessionId.length === 0 || this.isGenerating) {
      return;
    }
    try {
      const inspection: WorldRoundInspection | null = await this.runtimeService.inspectLatestRound(this.expectedSessionId);
      this.lastInspection = inspection;
      if (inspection === null) {
        this.roundStatus = WorldRoundUiStatus.Idle;
        return;
      }
      if (inspection.status === WorldRoundInspectionStatus.HasFailed
        || inspection.status === WorldRoundInspectionStatus.HasCancelled
        || inspection.status === WorldRoundInspectionStatus.PartiallyCompleted) {
        this.roundStatus = WorldRoundUiStatus.Resumable;
        this.roundProgress = this.buildRoundProgressFromInspection(inspection);
      } else if (inspection.status === WorldRoundInspectionStatus.AllCompleted) {
        this.roundStatus = WorldRoundUiStatus.Completed;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'checkResumableRound failed: ' + this.safeErrorCategory(e));
    }
  }

  async resumeRound(): Promise<string> {
    if (this.isGenerating || this.isSending) {
      return '当前角色正在回复中';
    }
    if (this.detail === null) {
      return '页面未加载完成';
    }
    if (this.lastInspection === null) {
      return '无可恢复的轮次';
    }

    this.isSending = true;
    this.runtimeError = '';
    this.roundStatus = WorldRoundUiStatus.Running;
    this.operationId = this.operationId + 1;

    try {
      const options: WorldRuntimeResumeOptions = {
        worldId: this.expectedWorldId,
        sceneId: this.expectedSceneId,
        sessionId: this.expectedSessionId,
        generationBatchId: this.lastInspection.generationBatchId
      };

      const result = await this.runtimeService.resumeInterruptedRound(options);

      this.isGenerating = true;
      this.currentOperationId = this.runtimeService.getOperationId(this.expectedSessionId);
      this.streamingMessageId = '';
      this.streamingContent = '';

      this.updateRoundProgressFromResult(result.characterMessages, result.generationBatchId);

      this.bumpRefreshTokens();
      await this.loadSnapshot(this.expectedSceneId);
      return '';
    } catch (e) {
      const msg: string = this.resolveRuntimeError(e);
      this.runtimeError = msg;
      this.roundStatus = WorldRoundUiStatus.Idle;
      Logger.warn(LOG_TAG, 'resumeRound failed: ' + this.safeErrorCategory(e));
      return msg;
    } finally {
      this.isSending = false;
    }
  }

  private async safeListMessagesBySession(sessionId: string): Promise<WorldSceneMessage[]> {
    try {
      return await this.messageRepo.listBySessionId(sessionId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'listBySessionId(messages) failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeGetSession(sessionId: string): Promise<WorldConversationSession | null> {
    try {
      return await this.sessionRepo.getById(sessionId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getById(session) failed: ' + this.safeErrorCategory(e));
      return null;
    }
  }

  private safeDeserializeSnapshots(json: string): WorldSessionParticipantSnapshot[] {
    try {
      return deserializeParticipantSnapshots(json);
    } catch (e) {
      Logger.warn(LOG_TAG, 'deserializeParticipantSnapshots failed: ' + this.safeErrorCategory(e));
      return [];
    }
  }

  private async safeGetInstance(instanceId: string): Promise<WorldCharacterInstance | null> {
    try {
      return await this.instanceRepo.getById(instanceId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getById(instance) failed: ' + this.safeErrorCategory(e));
      return null;
    }
  }

  private updateRoundProgressFromResult(
    characterMessages: WorldSceneMessage[],
    generationBatchId: string
  ): void {
    if (this.detail === null) {
      return;
    }
    const totalSpeakers: number = this.detail.sessionParticipantSnapshot.length;
    const currentIdx: number = Math.min(characterMessages.length, totalSpeakers);
    let currentInstId: string = '';
    if (characterMessages.length > 0) {
      currentInstId = characterMessages[characterMessages.length - 1].senderCharacterInstanceId ?? '';
    }
    this.roundProgress = this.buildRoundProgress(
      currentIdx, totalSpeakers, currentInstId, generationBatchId, 'running'
    );
  }

  private buildRoundProgress(
    currentSpeakerIndex: number,
    totalSpeakers: number,
    currentSpeakerInstanceId: string,
    generationBatchId: string,
    roundStatus: string
  ): RoundProgressUiModel {
    let displayName: string = '';
    if (this.detail !== null) {
      for (let i = 0; i < this.detail.characters.length; i++) {
        if (this.detail.characters[i].instanceId === currentSpeakerInstanceId) {
          displayName = this.detail.characters[i].displayName;
          break;
        }
      }
    }
    return {
      currentSpeakerIndex: currentSpeakerIndex,
      totalSpeakers: totalSpeakers,
      currentSpeakerInstanceId: currentSpeakerInstanceId,
      currentSpeakerDisplayName: displayName,
      generationBatchId: generationBatchId,
      roundStatus: roundStatus
    };
  }

  private buildRoundProgressFromInspection(inspection: WorldRoundInspection): RoundProgressUiModel {
    let displayName: string = '';
    if (this.detail !== null) {
      for (let i = 0; i < this.detail.characters.length; i++) {
        if (this.detail.characters[i].instanceId === inspection.nextSpeakerInstanceId) {
          displayName = this.detail.characters[i].displayName;
          break;
        }
      }
    }
    return {
      currentSpeakerIndex: inspection.nextSpeakerIndex,
      totalSpeakers: inspection.totalSpeakers,
      currentSpeakerInstanceId: inspection.nextSpeakerInstanceId,
      currentSpeakerDisplayName: displayName,
      generationBatchId: inspection.generationBatchId,
      roundStatus: 'resumable'
    };
  }

  private bumpRefreshTokens(): void {
    const detailToken: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, detailToken + 1);
    const sceneToken: number = AppStorage.get<number>(WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY, sceneToken + 1);
  }

  private resolveInstanceDisplayName(
    instanceId: string | undefined,
    instanceMap: Map<string, WorldCharacterInstance>,
    characterMap: Map<string, Character | null>
  ): string {
    if (instanceId === undefined || instanceId.length === 0) {
      return '';
    }
    const inst: WorldCharacterInstance | undefined = instanceMap.get(instanceId);
    if (inst === undefined) {
      return '已移除角色';
    }
    const character: Character | null | undefined = characterMap.get(inst.characterId);
    if (character !== null && character !== undefined) {
      return character.name;
    }
    return inst.displayNameSnapshot;
  }

  private resolveInstanceNames(
    instanceIds: string[] | undefined,
    instanceMap: Map<string, WorldCharacterInstance>,
    characterMap: Map<string, Character | null>
  ): string[] {
    if (instanceIds === undefined || instanceIds.length === 0) {
      return [];
    }
    const names: string[] = [];
    for (let i = 0; i < instanceIds.length; i++) {
      names.push(this.resolveInstanceDisplayName(instanceIds[i], instanceMap, characterMap));
    }
    return names;
  }

  private resolveRuntimeError(e: Object): string {
    if (isWorldRuntimeError(e)) {
      return mapWorldRuntimeErrorToMessage(e);
    }
    return this.resolveErrorMessage(e);
  }

  private resolveErrorMessage(e: Object): string {
    const sceneMsg: string = mapWorldSceneErrorToMessage(e);
    if (sceneMsg !== '操作失败,请重试') {
      return sceneMsg;
    }
    const stateMsg: string = mapWorldStateErrorToMessage(e);
    if (stateMsg !== '操作失败,请重试') {
      return stateMsg;
    }
    return '操作失败,请重试';
  }

  private safeErrorCategory(e: Object): string {
    if (e instanceof DatabaseError) {
      return 'DatabaseError:' + e.type;
    }
    if (e instanceof WorldRuntimeError) {
      return 'WorldRuntimeError:' + (e as WorldRuntimeError).kind.toString();
    }
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }

  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}

export function formatChatTimestamp(ts: number): string {
  return formatWorldTimestamp(ts);
}
