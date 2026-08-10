import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus,
  CreateWorldSceneMessageOptions,
  WORLD_SCENE_MESSAGE_ID_PREFIX,
  createWorldSceneMessageRecord
} from '../../models/world/WorldSceneMessage';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldRuntimeError } from '../../models/world/WorldRuntimeError';
import { generateUuid } from '../../utils/Uuid';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneMsgSvc';

export interface AddWorldUserMessageOptions {
  worldId: string;
  sceneId: string;
  sessionId: string;
  content: string;
  replyTargetCharacterInstanceIds?: string[];
}

export interface AddWorldCharacterPlaceholderOptions {
  worldId: string;
  sceneId: string;
  sessionId: string;
  senderCharacterInstanceId: string;
  generationBatchId: string;
}

export interface UpdateWorldCharacterStreamingOptions {
  messageId: string;
  content: string;
}

export interface FinalizeWorldCharacterMessageOptions {
  messageId: string;
  content: string;
  status: WorldSceneMessageStatus;
}

export class WorldSceneMessageService {
  private readonly sceneRepo: WorldSceneRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    sceneRepo: WorldSceneRepository,
    sessionRepo: WorldConversationSessionRepository,
    messageRepo: WorldSceneMessageRepository,
    dbHelper: DbHelper
  ) {
    this.sceneRepo = sceneRepo;
    this.sessionRepo = sessionRepo;
    this.messageRepo = messageRepo;
    this.dbHelper = dbHelper;
  }

  async addUserMessage(options: AddWorldUserMessageOptions): Promise<WorldSceneMessage> {
    const trimmed: string = options.content.trim();
    if (trimmed.length === 0) {
      throw WorldRuntimeError.emptyUserMessage();
    }

    let result: WorldSceneMessage | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const session: WorldConversationSession | null = await this.sessionRepo.getByIdWithStore(store, options.sessionId);
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

        const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, options.sceneId);
        if (scene === null) {
          throw WorldRuntimeError.sceneNotFound();
        }
        if (scene.status === WorldSceneStatus.Ended) {
          throw WorldRuntimeError.sceneEnded();
        }

        const participantIds: string[] = this.extractParticipantIds(session);
        const sequenceNumber: number = await this.allocateSequenceNumber(store, options.sceneId);
        const now: number = Date.now();

        const msgOptions: CreateWorldSceneMessageOptions = {
          id: WORLD_SCENE_MESSAGE_ID_PREFIX + generateUuid(),
          worldId: options.worldId,
          sceneId: options.sceneId,
          senderType: WorldSceneMessageSenderType.User,
          content: trimmed,
          sequenceNumber: sequenceNumber,
          status: WorldSceneMessageStatus.Completed,
          visibility: WorldSceneMessageVisibility.Public,
          participantCharacterInstanceIds: participantIds,
          witnessCharacterInstanceIds: undefined,
          replyTargetCharacterInstanceIds: options.replyTargetCharacterInstanceIds,
          sessionId: options.sessionId,
          locationId: scene.locationId,
          createdAt: now,
          updatedAt: now
        };

        const message: WorldSceneMessage = createWorldSceneMessageRecord(msgOptions);
        await this.messageRepo.insertWithStore(store, message);
        result = message;

        Logger.info(LOG_TAG, 'addUserMessage ok sessionId=' + this.shortId(options.sessionId)
          + ' seq=' + sequenceNumber.toString());
      },
      'world_user_msg'
    );
    if (result === null) {
      throw WorldRuntimeError.messagePersistenceFailed('事务未产生结果');
    }
    return result;
  }

  async addCharacterPlaceholder(options: AddWorldCharacterPlaceholderOptions): Promise<WorldSceneMessage> {
    let result: WorldSceneMessage | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const session: WorldConversationSession | null = await this.sessionRepo.getByIdWithStore(store, options.sessionId);
        if (session === null) {
          throw WorldRuntimeError.sessionNotFound();
        }
        if (session.status !== WorldConversationSessionStatus.Active) {
          throw WorldRuntimeError.sessionEnded();
        }

        const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, options.sceneId);
        if (scene === null) {
          throw WorldRuntimeError.sceneNotFound();
        }
        if (scene.status === WorldSceneStatus.Ended) {
          throw WorldRuntimeError.sceneEnded();
        }

        const participantIds: string[] = this.extractParticipantIds(session);
        const sequenceNumber: number = await this.allocateSequenceNumber(store, options.sceneId);
        const now: number = Date.now();

        const msgOptions: CreateWorldSceneMessageOptions = {
          id: WORLD_SCENE_MESSAGE_ID_PREFIX + generateUuid(),
          worldId: options.worldId,
          sceneId: options.sceneId,
          senderType: WorldSceneMessageSenderType.Character,
          senderCharacterInstanceId: options.senderCharacterInstanceId,
          content: '',
          sequenceNumber: sequenceNumber,
          status: WorldSceneMessageStatus.Streaming,
          generationBatchId: options.generationBatchId,
          visibility: WorldSceneMessageVisibility.Public,
          participantCharacterInstanceIds: participantIds,
          witnessCharacterInstanceIds: undefined,
          sessionId: options.sessionId,
          locationId: scene.locationId,
          createdAt: now,
          updatedAt: now
        };

        const message: WorldSceneMessage = createWorldSceneMessageRecord(msgOptions);
        await this.messageRepo.insertWithStore(store, message);
        result = message;

        Logger.info(LOG_TAG, 'addCharPlaceholder ok sessionId=' + this.shortId(options.sessionId)
          + ' seq=' + sequenceNumber.toString()
          + ' batch=' + this.shortId(options.generationBatchId));
      },
      'world_char_placeholder'
    );
    if (result === null) {
      throw WorldRuntimeError.messagePersistenceFailed('事务未产生结果');
    }
    return result;
  }

  async updateStreamingContent(options: UpdateWorldCharacterStreamingOptions): Promise<boolean> {
    try {
      return await this.messageRepo.updateStreamingContentIfStreaming(
        options.messageId,
        options.content,
        Date.now()
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'updateStreamingContent failed: ' + (e as Error).message);
      return false;
    }
  }

  async finalizeCharacterMessage(options: FinalizeWorldCharacterMessageOptions): Promise<boolean> {
    try {
      return await this.messageRepo.finalizeIfStreaming(
        options.messageId,
        options.content,
        options.status,
        Date.now()
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'finalizeCharacterMessage failed: ' + (e as Error).message);
      return false;
    }
  }

  async updateCharacterMessageStatus(messageId: string, status: WorldSceneMessageStatus, content: string): Promise<boolean> {
    try {
      return await this.messageRepo.finalizeIfStreaming(messageId, content, status, Date.now());
    } catch (e) {
      Logger.warn(LOG_TAG, 'updateCharacterMessageStatus failed: ' + (e as Error).message);
      return false;
    }
  }

  private async allocateSequenceNumber(store: relationalStore.RdbStore, sceneId: string): Promise<number> {
    const maxSeq: number = await this.messageRepo.getMaxSequenceNumberWithStore(store, sceneId);
    return maxSeq + 1;
  }

  private extractParticipantIds(session: WorldConversationSession): string[] {
    try {
      const snapshots = deserializeParticipantSnapshots(session.participantSnapshotJson);
      const ids: string[] = [];
      for (let i = 0; i < snapshots.length; i++) {
        ids.push(snapshots[i].characterInstanceId);
      }
      return ids;
    } catch (e) {
      Logger.warn(LOG_TAG, 'extractParticipantIds failed: ' + (e as Error).message);
      return [];
    }
  }

  private shortId(id: string): string {
    return id.length > 8 ? id.substring(0, 8) : id;
  }
}
