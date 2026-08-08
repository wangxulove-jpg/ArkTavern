import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldDirectionalRelationshipEntryRepository } from '../../repositories/world/WorldDirectionalRelationshipEntryRepository';
import { WorldCharacterMemoryStoreService } from './WorldCharacterMemoryStoreService';
import {
  WorldDirectionalRelationshipEntry,
  WorldDirectionalRelationshipEntryStatus,
  WorldDirectionalRelationshipErrorKind,
  WorldDirectionalRelationshipPersistResult,
  createWorldDirectionalRelationshipEntryRecord,
  parseJsonIdArray,
  stableDedupAndSort,
  WORLD_DIRECTIONAL_RELATIONSHIP_ENTRY_ID_PREFIX
} from '../../models/world/WorldDirectionalRelationshipEntry';
import {
  WorldCharacterMemorySourceSnapshot
} from '../../models/world/WorldCharacterMemoryEntry';
import { WorldStateError } from '../../models/world/WorldStateError';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldDirectionalRelationshipStoreService';

export class WorldDirectionalRelationshipStoreService {
  private readonly relationshipRepo: WorldDirectionalRelationshipEntryRepository;
  private readonly memoryStoreService: WorldCharacterMemoryStoreService;
  private readonly dbHelper: DbHelper;

  constructor(
    relationshipRepo: WorldDirectionalRelationshipEntryRepository,
    memoryStoreService: WorldCharacterMemoryStoreService,
    dbHelper: DbHelper
  ) {
    this.relationshipRepo = relationshipRepo;
    this.memoryStoreService = memoryStoreService;
    this.dbHelper = dbHelper;
  }

  async prepareSourceSnapshot(
    sessionId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldCharacterMemorySourceSnapshot> {
    return await this.memoryStoreService.prepareSourceSnapshot(sessionId, ownerCharacterInstanceId);
  }

  async getActiveRelationship(
    worldId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string
  ): Promise<WorldDirectionalRelationshipEntry | null> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (ownerCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    if (targetCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    if (ownerCharacterInstanceId === targetCharacterInstanceId) {
      throw WorldStateError.invalidOperation('owner equals target');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.relationshipRepo.getActiveForPairWithStore(
      store, worldId, ownerCharacterInstanceId, targetCharacterInstanceId
    );
  }

  async listActiveRelationshipsByOwner(
    worldId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldDirectionalRelationshipEntry[]> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (ownerCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.relationshipRepo.listActiveByOwnerWithStore(store, worldId, ownerCharacterInstanceId);
  }

  async listHistoricalForPair(
    worldId: string,
    ownerCharacterInstanceId: string,
    targetCharacterInstanceId: string
  ): Promise<WorldDirectionalRelationshipEntry[]> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (ownerCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    if (targetCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.relationshipRepo.listHistoricalForPairWithStore(
      store, worldId, ownerCharacterInstanceId, targetCharacterInstanceId
    );
  }

  async persistRelationshipSnapshot(
    sourceSnapshot: WorldCharacterMemorySourceSnapshot,
    targetCharacterInstanceId: string,
    relationshipText: string,
    confidence: number,
    evidenceMessageIds: string[],
    promptVersion: string,
    forceNewVersion: boolean,
    providerId?: string,
    modelId?: string
  ): Promise<WorldDirectionalRelationshipPersistResult> {
    if (targetCharacterInstanceId === '') {
      throw WorldStateError.invalidOperation('targetCharacterInstanceId empty');
    }
    if (relationshipText.trim() === '') {
      throw WorldStateError.invalidOperation('relationshipText empty');
    }
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
      throw WorldStateError.invalidOperation('confidence invalid');
    }
    if (promptVersion === '') {
      throw WorldStateError.invalidOperation('promptVersion empty');
    }
    if (sourceSnapshot.ownerCharacterInstanceId === targetCharacterInstanceId) {
      throw WorldStateError.invalidOperation('owner equals target');
    }
    const dedupedEvidenceIds: string[] = stableDedupAndSort(evidenceMessageIds);
    if (dedupedEvidenceIds.length === 0) {
      throw WorldStateError.invalidOperation('evidenceMessageIds empty');
    }
    this.validateEvidenceSubset(dedupedEvidenceIds, sourceSnapshot.sourceMessageIds);
    this.validateTargetInParticipants(targetCharacterInstanceId, sourceSnapshot);
    const targetDisplayNameSnapshot: string = this.findDisplayNameInSnapshot(
      targetCharacterInstanceId, sourceSnapshot
    );
    if (targetDisplayNameSnapshot === '') {
      throw WorldStateError.invalidOperation('target not found in participant snapshot');
    }
    const evidenceIdsJson: string = JSON.stringify(dedupedEvidenceIds);
    let result: WorldDirectionalRelationshipPersistResult | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const freshSnapshot: WorldCharacterMemorySourceSnapshot =
          await this.memoryStoreService.prepareSourceSnapshot(
            sourceSnapshot.sessionId, sourceSnapshot.ownerCharacterInstanceId
          );
        const freshSourceIds: string[] = Array.from(freshSnapshot.sourceMessageIds);
        const originalSourceIds: string[] = Array.from(sourceSnapshot.sourceMessageIds);
        const freshIdsJson: string = JSON.stringify(stableDedupAndSort(freshSourceIds));
        const originalIdsJson: string = JSON.stringify(stableDedupAndSort(originalSourceIds));
        if (freshIdsJson !== originalIdsJson) {
          throw WorldStateError.invalidOperation('SourceChanged');
        }
        const activeCount: number = await this.relationshipRepo.countActiveForPairWithStore(
          store, sourceSnapshot.worldId,
          sourceSnapshot.ownerCharacterInstanceId, targetCharacterInstanceId
        );
        if (activeCount > 1) {
          Logger.error(LOG_TAG, `invariant: ${activeCount} active entries for pair owner=${sourceSnapshot.ownerCharacterInstanceId.substring(0, 8)}... target=${targetCharacterInstanceId.substring(0, 8)}...`);
          throw WorldStateError.invalidOperation('MultipleActiveInvariant');
        }
        const activeEntry: WorldDirectionalRelationshipEntry | null =
          await this.relationshipRepo.getActiveForPairWithStore(
            store, sourceSnapshot.worldId,
            sourceSnapshot.ownerCharacterInstanceId, targetCharacterInstanceId
          );
        if (activeEntry !== null && !forceNewVersion) {
          const activeEvidenceIds: string[] = parseJsonIdArray(activeEntry.evidenceMessageIdsJson);
          const activeEvidenceJson: string = JSON.stringify(stableDedupAndSort(activeEvidenceIds));
          if (activeEntry.sourceSessionId === sourceSnapshot.sessionId &&
            activeEntry.promptVersion === promptVersion &&
            activeEvidenceJson === evidenceIdsJson &&
            activeEntry.relationshipText === relationshipText.trim() &&
            activeEntry.confidence === confidence) {
            result = { entry: activeEntry, isExisting: true };
            return;
          }
        }
        const version: number = await this.relationshipRepo.getNextVersionForPairWithStore(
          store, sourceSnapshot.worldId,
          sourceSnapshot.ownerCharacterInstanceId, targetCharacterInstanceId
        );
        if (activeEntry !== null) {
          const superseded: boolean = await this.relationshipRepo.updateStatusWithStore(
            store, activeEntry.id,
            WorldDirectionalRelationshipEntryStatus.Active,
            WorldDirectionalRelationshipEntryStatus.Superseded,
            nowMillis()
          );
          if (!superseded) {
            throw WorldStateError.invalidOperation('ActiveSupersedeFailed');
          }
        }
        const entryId: string = WORLD_DIRECTIONAL_RELATIONSHIP_ENTRY_ID_PREFIX + generateUuid();
        const entry: WorldDirectionalRelationshipEntry = createWorldDirectionalRelationshipEntryRecord({
          id: entryId,
          worldId: sourceSnapshot.worldId,
          ownerCharacterInstanceId: sourceSnapshot.ownerCharacterInstanceId,
          targetCharacterInstanceId: targetCharacterInstanceId,
          version: version,
          relationshipText: relationshipText.trim(),
          confidence: confidence,
          sourceSceneId: sourceSnapshot.sceneId,
          sourceSessionId: sourceSnapshot.sessionId,
          sourceLocationId: sourceSnapshot.locationId,
          evidenceMessageIdsJson: evidenceIdsJson,
          ownerDisplayNameSnapshot: sourceSnapshot.ownerDisplayNameSnapshot,
          targetDisplayNameSnapshot: targetDisplayNameSnapshot,
          promptVersion: promptVersion,
          providerId: providerId,
          modelId: modelId,
          supersedesRelationshipId: activeEntry !== null ? activeEntry.id : undefined
        });
        await this.relationshipRepo.insertWithStore(store, entry);
        result = { entry: entry, isExisting: false };
      },
      'world_directional_relationship_persist'
    );
    if (result === null) {
      throw DatabaseError.queryFailed('WorldDirectionalRelationshipStoreService.persistRelationshipSnapshot: no result');
    }
    return result;
  }

  async rejectRelationship(
    worldId: string,
    relationshipId: string
  ): Promise<boolean> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (relationshipId === '') {
      throw WorldStateError.invalidOperation('relationshipId empty');
    }
    let result: boolean = false;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const entry: WorldDirectionalRelationshipEntry | null =
          await this.relationshipRepo.getByIdWithStore(store, worldId, relationshipId);
        if (entry === null) {
          throw WorldStateError.invalidOperation('RelationshipNotFound');
        }
        result = await this.relationshipRepo.updateStatusWithStore(
          store, relationshipId,
          WorldDirectionalRelationshipEntryStatus.Active,
          WorldDirectionalRelationshipEntryStatus.Rejected,
          nowMillis()
        );
      },
      'world_directional_relationship_reject'
    );
    return result;
  }

  async deleteRelationshipsByWorldId(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    await this.relationshipRepo.deleteByWorldIdWithStore(store, worldId);
  }

  private validateEvidenceSubset(
    evidenceIds: string[],
    sourceMessageIds: ReadonlyArray<string>
  ): void {
    const sourceIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < sourceMessageIds.length; i++) {
      sourceIdSet.add(sourceMessageIds[i]);
    }
    for (let i = 0; i < evidenceIds.length; i++) {
      if (!sourceIdSet.has(evidenceIds[i])) {
        throw WorldStateError.invalidOperation('EvidenceNotInSource');
      }
    }
  }

  private validateTargetInParticipants(
    targetCharacterInstanceId: string,
    sourceSnapshot: WorldCharacterMemorySourceSnapshot
  ): void {
    for (let i = 0; i < sourceSnapshot.participantCharacterInstanceIds.length; i++) {
      if (sourceSnapshot.participantCharacterInstanceIds[i] === targetCharacterInstanceId) {
        return;
      }
    }
    throw WorldStateError.invalidOperation('TargetNotParticipant');
  }

  private findDisplayNameInSnapshot(
    characterInstanceId: string,
    sourceSnapshot: WorldCharacterMemorySourceSnapshot
  ): string {
    const messages: ReadonlyArray<WorldCharacterMemorySourceMessage> = sourceSnapshot.messages;
    for (let i = 0; i < messages.length; i++) {
      const msg: WorldCharacterMemorySourceMessage = messages[i];
      if (msg.senderCharacterInstanceId === characterInstanceId && msg.senderDisplayNameSnapshot !== '') {
        return msg.senderDisplayNameSnapshot;
      }
    }
    for (let i = 0; i < messages.length; i++) {
      const msg: WorldCharacterMemorySourceMessage = messages[i];
      const participantIds: string[] | undefined = msg.participantCharacterInstanceIds;
      if (participantIds !== undefined) {
        for (let j = 0; j < participantIds.length; j++) {
          if (participantIds[j] === characterInstanceId) {
            return msg.senderDisplayNameSnapshot;
          }
        }
      }
    }
    return '';
  }
}

interface WorldCharacterMemorySourceMessage {
  readonly messageId: string;
  readonly sequenceNumber: number;
  readonly senderKind: string;
  readonly senderCharacterInstanceId: string | undefined;
  readonly senderDisplayNameSnapshot: string;
  readonly visibility: string;
  readonly recipientCharacterInstanceIds: string[] | undefined;
  readonly participantCharacterInstanceIds: string[] | undefined;
  readonly witnessCharacterInstanceIds: string[] | undefined;
  readonly content: string;
  readonly createdAt: number;
}
