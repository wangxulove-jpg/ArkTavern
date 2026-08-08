import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldEventExtractionRunRepository, WorldEventEntryRepository } from '../../repositories/world/WorldEventExtractionRepository';
import { WorldSessionSummaryRepository } from '../../repositories/world/WorldSessionSummaryRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import {
  WorldEventExtractionRun,
  WorldEventEntry,
  WorldEventExtractionRunStatus,
  WorldEventEntryStatus,
  WorldEventSourceSnapshot,
  WorldEventSourceMessage,
  WorldEventEntryDraft,
  WorldEventExtractionResult,
  ActiveExtractionInfo,
  createWorldEventExtractionRunRecord,
  createWorldEventEntryRecord,
  WORLD_EVENT_EXTRACTION_RUN_ID_PREFIX,
  WORLD_EVENT_ENTRY_ID_PREFIX,
  isWorldEventKind
} from '../../models/world/WorldEventExtraction';
import {
  WorldSessionSummary,
  WorldSessionSummaryVisibilityScope
} from '../../models/world/WorldSessionSummary';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldSceneMessage, WorldSceneMessageVisibility, WorldSceneMessageStatus } from '../../models/world/WorldSceneMessage';
import { WorldScene } from '../../models/world/WorldScene';
import { WorldStateError } from '../../models/world/WorldStateError';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';

export class WorldEventStoreService {
  private readonly extractionRunRepo: WorldEventExtractionRunRepository;
  private readonly entryRepo: WorldEventEntryRepository;
  private readonly summaryRepo: WorldSessionSummaryRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly sceneMessageRepo: WorldSceneMessageRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    extractionRunRepo: WorldEventExtractionRunRepository,
    entryRepo: WorldEventEntryRepository,
    summaryRepo: WorldSessionSummaryRepository,
    sessionRepo: WorldConversationSessionRepository,
    sceneMessageRepo: WorldSceneMessageRepository,
    sceneRepo: WorldSceneRepository,
    dbHelper: DbHelper
  ) {
    this.extractionRunRepo = extractionRunRepo;
    this.entryRepo = entryRepo;
    this.summaryRepo = summaryRepo;
    this.sessionRepo = sessionRepo;
    this.sceneMessageRepo = sceneMessageRepo;
    this.sceneRepo = sceneRepo;
    this.dbHelper = dbHelper;
  }

  async prepareSourceSnapshot(
    worldId: string,
    sceneId: string,
    sessionId: string
  ): Promise<WorldEventSourceSnapshot> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (sceneId === '') {
      throw WorldStateError.sceneNotFound();
    }
    if (sessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      throw WorldStateError.sessionNotFound();
    }
    if (session.worldId !== worldId) {
      throw WorldStateError.sessionNotFound();
    }
    if (session.sceneId !== sceneId) {
      throw WorldStateError.sceneNotFound();
    }
    if (session.status !== WorldConversationSessionStatus.Ended) {
      throw WorldStateError.sessionNotEnded();
    }
    const scene: WorldScene | null = await this.sceneRepo.getById(sceneId);
    if (scene === null) {
      throw WorldStateError.sceneNotFound();
    }
    const locationId: string = scene.locationId;
    const latestSummary: WorldSessionSummary | null =
      await this.summaryRepo.getLatestBySessionId(sessionId);
    if (latestSummary === null) {
      throw WorldStateError.invalidOperation('NoSharedSummary');
    }
    if (latestSummary.visibilityScope !== WorldSessionSummaryVisibilityScope.SharedPublic) {
      throw WorldStateError.invalidOperation('NoSharedSummary');
    }
    const participantSnapshots: WorldSessionParticipantSnapshot[] =
      session.participantSnapshotJson !== ''
        ? deserializeParticipantSnapshots(session.participantSnapshotJson)
        : [];
    if (participantSnapshots.length === 0) {
      throw WorldStateError.invalidOperation('SummaryParticipantProvenanceEmpty');
    }
    const participantIds: Set<string> = new Set<string>();
    for (let i = 0; i < participantSnapshots.length; i++) {
      participantIds.add(participantSnapshots[i].characterInstanceId);
    }
    const sourceMessageIds: string[] = this.parseSourceMessageIds(latestSummary.sourceMessageIdsJson);
    if (sourceMessageIds.length === 0) {
      throw WorldStateError.invalidOperation('SummarySourceMessageIdsEmpty');
    }
    const allMessages: WorldSceneMessage[] =
      await this.sceneMessageRepo.listBySessionId(sessionId);
    const messageMap: Map<string, WorldSceneMessage> = new Map<string, WorldSceneMessage>();
    for (let i = 0; i < allMessages.length; i++) {
      messageMap.set(allMessages[i].id, allMessages[i]);
    }
    const resolvedMessages: WorldSceneMessage[] = [];
    for (let i = 0; i < sourceMessageIds.length; i++) {
      const msgId: string = sourceMessageIds[i];
      const msg: WorldSceneMessage | undefined = messageMap.get(msgId);
      if (msg === undefined) {
        throw WorldStateError.invalidOperation('SourceMessageMissing');
      }
      resolvedMessages.push(msg);
    }
    const sourceMessages: WorldEventSourceMessage[] = [];
    for (let i = 0; i < resolvedMessages.length; i++) {
      const msg: WorldSceneMessage = resolvedMessages[i];
      if (!this.isEligibleForEventSource(msg, participantIds)) {
        throw WorldStateError.invalidOperation('SourceMessageIneligible');
      }
      const senderDisplayName: string = this.getSenderDisplayName(msg, participantSnapshots);
      sourceMessages.push({
        messageId: msg.id,
        sequenceNumber: msg.sequenceNumber,
        senderKind: msg.senderType,
        senderCharacterInstanceId: msg.senderCharacterInstanceId,
        senderDisplayNameSnapshot: senderDisplayName,
        content: msg.content,
        participantCharacterInstanceIds: msg.participantCharacterInstanceIds !== undefined
          ? msg.participantCharacterInstanceIds : [],
        witnessCharacterInstanceIds: msg.witnessCharacterInstanceIds !== undefined
          ? msg.witnessCharacterInstanceIds : [],
        createdAt: msg.createdAt
      });
    }
    const participantInstanceIds: string[] = Array.from(participantIds);
    participantInstanceIds.sort();
    return {
      worldId: worldId,
      sceneId: sceneId,
      sessionId: sessionId,
      locationId: locationId,
      summaryId: latestSummary.id,
      summaryVersion: latestSummary.version,
      summaryText: latestSummary.content,
      sourceMessageIds: sourceMessageIds,
      participantCharacterInstanceIds: participantInstanceIds,
      playerDisplayNameSnapshot: session.playerDisplayNameSnapshot,
      messages: sourceMessages
    };
  }

  async persistCompletedExtraction(
    sourceSnapshot: WorldEventSourceSnapshot,
    eventDrafts: WorldEventEntryDraft[],
    promptVersion: string,
    forceNewVersion: boolean,
    providerId?: string,
    modelId?: string
  ): Promise<WorldEventExtractionResult> {
    if (promptVersion === '') {
      throw WorldStateError.invalidOperation('promptVersion empty');
    }
    const sourceMessageIdsJson: string = JSON.stringify(sourceSnapshot.sourceMessageIds);
    const participantInstanceIdsJson: string = JSON.stringify(sourceSnapshot.participantCharacterInstanceIds);
    let result: WorldEventExtractionResult | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const session: WorldConversationSession | null =
          await this.sessionRepo.getByIdWithStore(store, sourceSnapshot.sessionId);
        if (session === null) {
          throw WorldStateError.sessionNotFound();
        }
        if (session.status !== WorldConversationSessionStatus.Ended) {
          throw WorldStateError.sessionNotEnded();
        }
        const latestSummary: WorldSessionSummary | null =
          await this.summaryRepo.getLatestBySessionIdWithStore(store, sourceSnapshot.sessionId);
        if (latestSummary === null) {
          throw WorldStateError.invalidOperation('NoSharedSummary');
        }
        if (latestSummary.id !== sourceSnapshot.summaryId ||
          latestSummary.version !== sourceSnapshot.summaryVersion) {
          throw WorldStateError.summarySourceChanged();
        }
        const freshSourceIdsJson: string = latestSummary.sourceMessageIdsJson;
        if (freshSourceIdsJson !== sourceMessageIdsJson) {
          throw WorldStateError.summarySourceChanged();
        }
        const activeRun: WorldEventExtractionRun | null =
          await this.extractionRunRepo.getActiveBySessionWithStore(
            store, sourceSnapshot.worldId, sourceSnapshot.sessionId
          );
        if (activeRun !== null && !forceNewVersion) {
          if (activeRun.sourceSummaryId === sourceSnapshot.summaryId &&
            activeRun.sourceSummaryVersion === sourceSnapshot.summaryVersion &&
            activeRun.sourceMessageIdsJson === sourceMessageIdsJson &&
            activeRun.promptVersion === promptVersion) {
            const existingEntries: WorldEventEntry[] =
              await this.entryRepo.listByRunWithStore(store, sourceSnapshot.worldId, activeRun.id);
            result = {
              run: activeRun,
              entries: existingEntries,
              isExisting: true
            };
            return;
          }
        }
        const version: number =
          await this.extractionRunRepo.getNextVersionForSessionWithStore(
            store, sourceSnapshot.worldId, sourceSnapshot.sessionId
          );
        if (activeRun !== null) {
          const superseded: boolean =
            await this.extractionRunRepo.updateStatusWithStore(
              store, activeRun.id,
              WorldEventExtractionRunStatus.Active,
              WorldEventExtractionRunStatus.Superseded,
              nowMillis()
            );
          if (!superseded) {
            throw WorldStateError.invalidOperation('ActiveRunSupersedeFailed');
          }
        }
        const runId: string = WORLD_EVENT_EXTRACTION_RUN_ID_PREFIX + generateUuid();
        const run: WorldEventExtractionRun = createWorldEventExtractionRunRecord({
          id: runId,
          worldId: sourceSnapshot.worldId,
          sourceSceneId: sourceSnapshot.sceneId,
          sourceSessionId: sourceSnapshot.sessionId,
          sourceLocationId: sourceSnapshot.locationId,
          version: version,
          sourceSummaryId: sourceSnapshot.summaryId,
          sourceSummaryVersion: sourceSnapshot.summaryVersion,
          sourceMessageIdsJson: sourceMessageIdsJson,
          sourceMessageCount: sourceSnapshot.sourceMessageIds.length,
          participantInstanceIdsJson: participantInstanceIdsJson,
          playerDisplayNameSnapshot: sourceSnapshot.playerDisplayNameSnapshot,
          status: WorldEventExtractionRunStatus.Active,
          promptVersion: promptVersion,
          providerId: providerId,
          modelId: modelId
        });
        await this.extractionRunRepo.insertWithStore(store, run);
        const validatedDrafts: WorldEventEntryDraft[] =
          this.validateDrafts(eventDrafts, sourceSnapshot);
        const entries: WorldEventEntry[] = [];
        for (let i = 0; i < validatedDrafts.length; i++) {
          const draft: WorldEventEntryDraft = validatedDrafts[i];
          const witnessIds: string[] =
            this.computeWitnessIds(draft.evidenceMessageIds, sourceSnapshot);
          const actorIdsJson: string = JSON.stringify(draft.actorCharacterInstanceIds);
          const evidenceIdsJson: string = JSON.stringify(draft.evidenceMessageIds);
          const witnessIdsJson: string = JSON.stringify(witnessIds);
          const entryId: string = WORLD_EVENT_ENTRY_ID_PREFIX + generateUuid();
          const entry: WorldEventEntry = createWorldEventEntryRecord({
            id: entryId,
            worldId: sourceSnapshot.worldId,
            extractionRunId: runId,
            sourceSceneId: sourceSnapshot.sceneId,
            sourceSessionId: sourceSnapshot.sessionId,
            sourceLocationId: sourceSnapshot.locationId,
            eventOrdinal: i,
            eventKind: draft.eventKind,
            eventText: draft.eventText,
            actorInstanceIdsJson: actorIdsJson,
            playerInvolved: draft.playerInvolved,
            evidenceMessageIdsJson: evidenceIdsJson,
            witnessInstanceIdsJson: witnessIdsJson,
            confidence: draft.confidence
          });
          await this.entryRepo.insertWithStore(store, entry);
          entries.push(entry);
        }
        result = {
          run: run,
          entries: entries,
          isExisting: false
        };
      },
      'world_event_extraction_persist'
    );
    if (result === null) {
      throw DatabaseError.queryFailed('WorldEventStoreService.persistCompletedExtraction: no result');
    }
    return result;
  }

  async getActiveExtractionForSession(
    worldId: string,
    sessionId: string
  ): Promise<ActiveExtractionInfo | null> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (sessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const activeRun: WorldEventExtractionRun | null =
      await this.extractionRunRepo.getActiveBySessionWithStore(store, worldId, sessionId);
    if (activeRun === null) {
      return null;
    }
    const entries: WorldEventEntry[] =
      await this.entryRepo.listByRunWithStore(store, worldId, activeRun.id);
    const latestSummary: WorldSessionSummary | null =
      await this.summaryRepo.getLatestBySessionIdWithStore(store, sessionId);
    const isSourceCurrent: boolean = latestSummary !== null &&
      latestSummary.id === activeRun.sourceSummaryId &&
      latestSummary.version === activeRun.sourceSummaryVersion;
    return {
      run: activeRun,
      entries: entries,
      isSourceCurrent: isSourceCurrent
    };
  }

  async listCurrentEventsForSession(
    worldId: string,
    sessionId: string
  ): Promise<WorldEventEntry[]> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (sessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.entryRepo.listCurrentActiveBySessionWithStore(store, worldId, sessionId);
  }

  private isEligibleForEventSource(
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
    const msgParticipantIds: string[] | undefined = msg.participantCharacterInstanceIds;
    const msgWitnessIds: string[] | undefined = msg.witnessCharacterInstanceIds;
    const hasAnyProvenance: boolean =
      (msgParticipantIds !== undefined && msgParticipantIds.length > 0) ||
      (msgWitnessIds !== undefined && msgWitnessIds.length > 0);
    if (!hasAnyProvenance) {
      return false;
    }
    if (allParticipantInstanceIds.size === 0) {
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
    const participantKeys: string[] = Array.from(allParticipantInstanceIds);
    for (let i = 0; i < participantKeys.length; i++) {
      if (!visibleIds.has(participantKeys[i])) {
        return false;
      }
    }
    return true;
  }

  private getSenderDisplayName(
    msg: WorldSceneMessage,
    participantSnapshots: WorldSessionParticipantSnapshot[]
  ): string {
    if (msg.senderType === 'user') {
      return '';
    }
    if (msg.senderCharacterInstanceId !== undefined) {
      for (let i = 0; i < participantSnapshots.length; i++) {
        if (participantSnapshots[i].characterInstanceId === msg.senderCharacterInstanceId) {
          return participantSnapshots[i].displayNameSnapshot;
        }
      }
    }
    return '';
  }

  private parseSourceMessageIds(json: string): string[] {
    if (json === '') {
      return [];
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(json);
    } catch (_e) {
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const arr: Object[] = parsed as Object[];
    const result: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (typeof item === 'string') {
        const str: string = item as string;
        if (str !== '') {
          result.push(str);
        }
      }
    }
    return result;
  }

  private validateDrafts(
    drafts: WorldEventEntryDraft[],
    sourceSnapshot: WorldEventSourceSnapshot
  ): WorldEventEntryDraft[] {
    const sourceIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < sourceSnapshot.sourceMessageIds.length; i++) {
      sourceIdSet.add(sourceSnapshot.sourceMessageIds[i]);
    }
    const participantIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < sourceSnapshot.participantCharacterInstanceIds.length; i++) {
      participantIdSet.add(sourceSnapshot.participantCharacterInstanceIds[i]);
    }
    const validated: WorldEventEntryDraft[] = [];
    for (let i = 0; i < drafts.length; i++) {
      const draft: WorldEventEntryDraft = drafts[i];
      if (!isWorldEventKind(draft.eventKind)) {
        throw WorldStateError.invalidOperation(`draft[${i}].eventKind invalid: ${draft.eventKind}`);
      }
      if (draft.eventText.trim() === '') {
        throw WorldStateError.invalidOperation(`draft[${i}].eventText empty`);
      }
      if (!Number.isFinite(draft.confidence) || draft.confidence < 0 || draft.confidence > 1) {
        throw WorldStateError.invalidOperation(`draft[${i}].confidence invalid`);
      }
      const actorIds: string[] = this.stableDedup(draft.actorCharacterInstanceIds);
      for (let j = 0; j < actorIds.length; j++) {
        if (!participantIdSet.has(actorIds[j])) {
          throw WorldStateError.invalidOperation(`draft[${i}].actorCharacterInstanceId not in participant snapshot: ${actorIds[j]}`);
        }
      }
      const evidenceIds: string[] = this.stableDedup(draft.evidenceMessageIds);
      if (evidenceIds.length === 0) {
        throw WorldStateError.invalidOperation(`draft[${i}].evidenceMessageIds empty`);
      }
      for (let j = 0; j < evidenceIds.length; j++) {
        if (!sourceIdSet.has(evidenceIds[j])) {
          throw WorldStateError.invalidOperation(`draft[${i}].evidenceMessageId not in source: ${evidenceIds[j]}`);
        }
      }
      validated.push({
        eventKind: draft.eventKind,
        eventText: draft.eventText,
        actorCharacterInstanceIds: actorIds,
        playerInvolved: draft.playerInvolved,
        evidenceMessageIds: evidenceIds,
        confidence: draft.confidence
      });
    }
    return validated;
  }

  private computeWitnessIds(
    evidenceMessageIds: string[],
    sourceSnapshot: WorldEventSourceSnapshot
  ): string[] {
    const evidenceIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < evidenceMessageIds.length; i++) {
      evidenceIdSet.add(evidenceMessageIds[i]);
    }
    const evidenceMessages: WorldEventSourceMessage[] = [];
    for (let i = 0; i < sourceSnapshot.messages.length; i++) {
      if (evidenceIdSet.has(sourceSnapshot.messages[i].messageId)) {
        evidenceMessages.push(sourceSnapshot.messages[i]);
      }
    }
    if (evidenceMessages.length === 0) {
      return [];
    }
    const firstVisible: Set<string> = new Set<string>();
    for (let i = 0; i < evidenceMessages[0].participantCharacterInstanceIds.length; i++) {
      firstVisible.add(evidenceMessages[0].participantCharacterInstanceIds[i]);
    }
    for (let i = 0; i < evidenceMessages[0].witnessCharacterInstanceIds.length; i++) {
      firstVisible.add(evidenceMessages[0].witnessCharacterInstanceIds[i]);
    }
    const witnessIntersection: Set<string> = new Set<string>(firstVisible);
    for (let m = 1; m < evidenceMessages.length; m++) {
      const msgVisible: Set<string> = new Set<string>();
      for (let i = 0; i < evidenceMessages[m].participantCharacterInstanceIds.length; i++) {
        msgVisible.add(evidenceMessages[m].participantCharacterInstanceIds[i]);
      }
      for (let i = 0; i < evidenceMessages[m].witnessCharacterInstanceIds.length; i++) {
        msgVisible.add(evidenceMessages[m].witnessCharacterInstanceIds[i]);
      }
      const toRemove: string[] = [];
      const witnessKeys: string[] = Array.from(witnessIntersection);
      for (let i = 0; i < witnessKeys.length; i++) {
        if (!msgVisible.has(witnessKeys[i])) {
          toRemove.push(witnessKeys[i]);
        }
      }
      for (let i = 0; i < toRemove.length; i++) {
        witnessIntersection.delete(toRemove[i]);
      }
    }
    const result: string[] = Array.from(witnessIntersection);
    result.sort();
    return result;
  }

  private stableDedup(ids: string[]): string[] {
    const seen: Set<string> = new Set<string>();
    const result: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      if (id === '' || seen.has(id)) {
        continue;
      }
      seen.add(id);
      result.push(id);
    }
    result.sort();
    return result;
  }
}
