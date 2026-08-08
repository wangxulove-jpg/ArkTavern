import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldSessionSummaryRepository } from '../../repositories/world/WorldSessionSummaryRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import {
  WorldSessionSummary,
  WorldSessionSummaryVisibilityScope,
  WorldSessionSummarySourceSnapshot,
  WorldSessionSummarySourceMessage,
  createWorldSessionSummaryRecord,
  WORLD_SESSION_SUMMARY_ID_PREFIX
} from '../../models/world/WorldSessionSummary';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldSceneMessage } from '../../models/world/WorldSceneMessage';
import {
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus
} from '../../models/world/WorldSceneMessage';
import { WorldScene } from '../../models/world/WorldScene';
import { WorldStateError } from '../../models/world/WorldStateError';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';

export class WorldSessionSummaryStoreService {
  private readonly summaryRepo: WorldSessionSummaryRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly sceneMessageRepo: WorldSceneMessageRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    summaryRepo: WorldSessionSummaryRepository,
    sessionRepo: WorldConversationSessionRepository,
    sceneMessageRepo: WorldSceneMessageRepository,
    sceneRepo: WorldSceneRepository,
    dbHelper: DbHelper
  ) {
    this.summaryRepo = summaryRepo;
    this.sessionRepo = sessionRepo;
    this.sceneMessageRepo = sceneMessageRepo;
    this.sceneRepo = sceneRepo;
    this.dbHelper = dbHelper;
  }

  async prepareSourceSnapshot(sessionId: string): Promise<WorldSessionSummarySourceSnapshot> {
    if (sessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      throw WorldStateError.sessionNotFound();
    }
    if (session.status !== WorldConversationSessionStatus.Ended) {
      throw WorldStateError.sessionNotEnded();
    }
    const scene: WorldScene | null =
      await this.sceneRepo.getById(session.sceneId);
    if (scene === null) {
      throw WorldStateError.sceneNotFound();
    }
    const locationId: string = scene.locationId;
    const participants: WorldSessionParticipantSnapshot[] =
      session.participantSnapshotJson !== ''
        ? deserializeParticipantSnapshots(session.participantSnapshotJson)
        : [];
    const allParticipantInstanceIds: Set<string> = new Set<string>();
    for (let i = 0; i < participants.length; i++) {
      allParticipantInstanceIds.add(participants[i].characterInstanceId);
    }
    const allMessages: WorldSceneMessage[] =
      await this.sceneMessageRepo.listBySessionId(sessionId);
    const sourceMessages: WorldSessionSummarySourceMessage[] = [];
    const sourceMessageIds: string[] = [];
    for (let i = 0; i < allMessages.length; i++) {
      const msg: WorldSceneMessage = allMessages[i];
      if (!this.isEligibleForSharedSummary(msg, allParticipantInstanceIds)) {
        continue;
      }
      sourceMessages.push({
        id: msg.id,
        senderType: msg.senderType,
        senderCharacterInstanceId: msg.senderCharacterInstanceId,
        visibility: msg.visibility,
        content: msg.content,
        participantCharacterInstanceIds: msg.participantCharacterInstanceIds,
        witnessCharacterInstanceIds: msg.witnessCharacterInstanceIds
      });
      sourceMessageIds.push(msg.id);
    }
    return {
      sessionId: sessionId,
      sceneId: session.sceneId,
      worldId: session.worldId,
      locationId: locationId,
      playerDisplayNameSnapshot: session.playerDisplayNameSnapshot,
      participantSnapshotJson: session.participantSnapshotJson,
      sourceMessages: sourceMessages,
      sourceMessageIds: sourceMessageIds,
      sourceMessageCount: sourceMessageIds.length
    };
  }

  async persistCompletedSummary(
    sessionId: string,
    content: string,
    promptVersion: string,
    forceNewVersion: boolean,
    providerId?: string,
    modelId?: string
  ): Promise<WorldSessionSummary> {
    if (sessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    if (promptVersion === '') {
      throw WorldStateError.invalidOperation('promptVersion empty');
    }
    const snapshot: WorldSessionSummarySourceSnapshot =
      await this.prepareSourceSnapshot(sessionId);
    const sourceMessageIdsJson: string = JSON.stringify(snapshot.sourceMessageIds);
    let result: WorldSessionSummary | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const session: WorldConversationSession | null =
          await this.sessionRepo.getByIdWithStore(store, sessionId);
        if (session === null) {
          throw WorldStateError.sessionNotFound();
        }
        if (session.status !== WorldConversationSessionStatus.Ended) {
          throw WorldStateError.sessionNotEnded();
        }
        if (!forceNewVersion) {
          const latest: WorldSessionSummary | null =
            await this.summaryRepo.getLatestBySessionIdWithStore(store, sessionId);
          if (latest !== null &&
            latest.promptVersion === promptVersion &&
            latest.sourceMessageIdsJson === sourceMessageIdsJson) {
            result = latest;
            return;
          }
        }
        const freshMessages: WorldSceneMessage[] =
          await this.sceneMessageRepo.listBySessionIdWithStore(store, sessionId);
        const freshParticipants: WorldSessionParticipantSnapshot[] =
          session.participantSnapshotJson !== ''
            ? deserializeParticipantSnapshots(session.participantSnapshotJson)
            : [];
        const freshParticipantIds: Set<string> = new Set<string>();
        for (let i = 0; i < freshParticipants.length; i++) {
          freshParticipantIds.add(freshParticipants[i].characterInstanceId);
        }
        const freshSourceIds: string[] = [];
        for (let i = 0; i < freshMessages.length; i++) {
          if (this.isEligibleForSharedSummary(freshMessages[i], freshParticipantIds)) {
            freshSourceIds.push(freshMessages[i].id);
          }
        }
        const freshSourceIdsJson: string = JSON.stringify(freshSourceIds);
        if (freshSourceIdsJson !== sourceMessageIdsJson) {
          throw WorldStateError.summarySourceChanged();
        }
        const version: number =
          await this.summaryRepo.getNextVersionForSessionWithStore(store, sessionId);
        const id: string = WORLD_SESSION_SUMMARY_ID_PREFIX + generateUuid();
        const summary: WorldSessionSummary = createWorldSessionSummaryRecord({
          id: id,
          worldId: snapshot.worldId,
          sceneId: snapshot.sceneId,
          sessionId: sessionId,
          version: version,
          visibilityScope: WorldSessionSummaryVisibilityScope.SharedPublic,
          content: content,
          sourceMessageIdsJson: sourceMessageIdsJson,
          sourceMessageCount: snapshot.sourceMessageCount,
          participantSnapshotJson: snapshot.participantSnapshotJson,
          playerDisplayNameSnapshot: snapshot.playerDisplayNameSnapshot,
          locationId: snapshot.locationId,
          promptVersion: promptVersion,
          providerId: providerId,
          modelId: modelId
        });
        await this.summaryRepo.insertWithStore(store, summary);
        result = summary;
      },
      'world_session_summary_persist'
    );
    if (result === null) {
      throw DatabaseError.queryFailed('WorldSessionSummaryStoreService.persistCompletedSummary: no result');
    }
    return result;
  }

  async getLatestSummary(sessionId: string): Promise<WorldSessionSummary | null> {
    if (sessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    return await this.summaryRepo.getLatestBySessionId(sessionId);
  }

  private isEligibleForSharedSummary(
    msg: WorldSceneMessage,
    allParticipantInstanceIds: Set<string>
  ): boolean {
    if (msg.status !== WorldSceneMessageStatus.Completed) {
      return false;
    }
    if (msg.visibility === WorldSceneMessageVisibility.Private) {
      return false;
    }
    if (msg.content.trim() === '') {
      return false;
    }
    if (allParticipantInstanceIds.size === 0) {
      return false;
    }
    const msgParticipantIds: string[] | undefined = msg.participantCharacterInstanceIds;
    const msgWitnessIds: string[] | undefined = msg.witnessCharacterInstanceIds;
    const hasAnyProvenance: boolean =
      (msgParticipantIds !== undefined && msgParticipantIds.length > 0) ||
      (msgWitnessIds !== undefined && msgWitnessIds.length > 0);
    if (!hasAnyProvenance) {
      return false;
    }
    const visibleIds: Set<string> = new Set<string>();
    if (msgParticipantIds !== undefined) {
      for (let i = 0; i < msgParticipantIds.length; i++) {
        visibleIds.add(msgParticipantIds[i]);
      }
    }
    if (msgWitnessIds !== undefined) {
      for (let i = 0; i < msgWitnessIds.length; i++) {
        visibleIds.add(msgWitnessIds[i]);
      }
    }
    const allParticipantKeys: string[] = Array.from(allParticipantInstanceIds);
    for (let i = 0; i < allParticipantKeys.length; i++) {
      if (!visibleIds.has(allParticipantKeys[i])) {
        return false;
      }
    }
    return true;
  }
}
