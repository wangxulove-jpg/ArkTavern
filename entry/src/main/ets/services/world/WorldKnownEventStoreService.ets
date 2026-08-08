import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldKnownEventEntryRepository } from '../../repositories/world/WorldKnownEventEntryRepository';
import { WorldEventExtractionRunRepository, WorldEventEntryRepository } from '../../repositories/world/WorldEventExtractionRepository';
import {
  WorldKnownEventEntry,
  WorldKnownEventSourceKind,
  WorldKnownEventEntryStatus,
  WorldKnownEventDerivationResult,
  WorldKnownEventBatchDerivationResult,
  WorldKnownEventErrorKind,
  createWorldKnownEventEntryRecord,
  validateKnowledgeSourceMessageIds,
  WORLD_KNOWN_EVENT_ENTRY_ID_PREFIX
} from '../../models/world/WorldKnownEventEntry';
import {
  WorldEventExtractionRun,
  WorldEventExtractionRunStatus,
  WorldEventEntry,
  WorldEventEntryStatus,
  ActiveExtractionInfo
} from '../../models/world/WorldEventExtraction';
import { WorldStateError } from '../../models/world/WorldStateError';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldKnownEventStoreService';

export class WorldKnownEventStoreService {
  private readonly knownEventRepo: WorldKnownEventEntryRepository;
  private readonly extractionRunRepo: WorldEventExtractionRunRepository;
  private readonly eventEntryRepo: WorldEventEntryRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    knownEventRepo: WorldKnownEventEntryRepository,
    extractionRunRepo: WorldEventExtractionRunRepository,
    eventEntryRepo: WorldEventEntryRepository,
    dbHelper: DbHelper
  ) {
    this.knownEventRepo = knownEventRepo;
    this.extractionRunRepo = extractionRunRepo;
    this.eventEntryRepo = eventEntryRepo;
    this.dbHelper = dbHelper;
  }

  async deriveKnownEventsForExtractionRun(
    worldId: string,
    extractionRunId: string
  ): Promise<WorldKnownEventBatchDerivationResult> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (extractionRunId === '') {
      throw WorldStateError.invalidOperation('extractionRunId empty');
    }
    const derived: WorldKnownEventDerivationResult[] = [];
    const skippedWitnessIds: string[] = [];
    let result: WorldKnownEventBatchDerivationResult | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const run: WorldEventExtractionRun | null =
          await this.extractionRunRepo.getByIdWithStore(store, extractionRunId);
        if (run === null) {
          throw WorldStateError.invalidOperation('ExtractionRunNotFound');
        }
        if (run.worldId !== worldId) {
          throw WorldStateError.invalidOperation('ExtractionRunWorldMismatch');
        }
        if (run.status !== WorldEventExtractionRunStatus.Active) {
          throw WorldStateError.invalidOperation('ExtractionRunNotActive');
        }
        const isCurrent: boolean = await this.isSourceCurrentWithStore(store, worldId, run);
        if (!isCurrent) {
          throw WorldStateError.invalidOperation('StaleExtraction');
        }
        const activeEntries: WorldEventEntry[] =
          await this.eventEntryRepo.listActiveByRunWithStore(store, worldId, extractionRunId);
        const participantIds: Set<string> = this.parseJsonIdSet(run.participantInstanceIdsJson);
        for (let i = 0; i < activeEntries.length; i++) {
          const eventEntry: WorldEventEntry = activeEntries[i];
          const witnessIds: string[] = this.parseJsonIdArray(eventEntry.witnessInstanceIdsJson);
          const evidenceIds: string[] = this.parseJsonIdArray(eventEntry.evidenceMessageIdsJson);
          if (evidenceIds.length === 0) {
            continue;
          }
          for (let w = 0; w < witnessIds.length; w++) {
            const witnessId: string = witnessIds[w];
            if (!participantIds.has(witnessId)) {
              skippedWitnessIds.push(witnessId);
              Logger.warn(LOG_TAG, `Unknown witness: ${witnessId.substring(0, 8)}... in event ${eventEntry.id.substring(0, 8)}...`);
              continue;
            }
            const existing: WorldKnownEventEntry | null =
              await this.knownEventRepo.findByIdentityWithStore(
                store, worldId, witnessId, eventEntry.id,
                WorldKnownEventSourceKind.EvidenceWitness, run.sourceSessionId
              );
            if (existing !== null) {
              derived.push({ entry: existing, isExisting: true });
              continue;
            }
            const knowledgeSourceMessageIdsJson: string = JSON.stringify(evidenceIds);
            const validatedIds: string[] = validateKnowledgeSourceMessageIds(knowledgeSourceMessageIdsJson);
            if (validatedIds.length === 0) {
              continue;
            }
            const entryId: string = WORLD_KNOWN_EVENT_ENTRY_ID_PREFIX + generateUuid();
            const entry: WorldKnownEventEntry = createWorldKnownEventEntryRecord({
              id: entryId,
              worldId: worldId,
              ownerCharacterInstanceId: witnessId,
              eventId: eventEntry.id,
              extractionRunId: extractionRunId,
              knowledgeSourceKind: WorldKnownEventSourceKind.EvidenceWitness,
              sourceSessionId: run.sourceSessionId,
              knowledgeSourceMessageIdsJson: knowledgeSourceMessageIdsJson
            });
            await this.knownEventRepo.insertWithStore(store, entry);
            derived.push({ entry: entry, isExisting: false });
          }
        }
        result = { derived: derived, skippedWitnessIds: skippedWitnessIds };
      },
      'world_known_event_derive'
    );
    if (result === null) {
      throw DatabaseError.queryFailed('WorldKnownEventStoreService.deriveKnownEventsForExtractionRun: no result');
    }
    return result;
  }

  async rejectKnownEventsByStaleRun(
    worldId: string,
    extractionRunId: string
  ): Promise<number> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (extractionRunId === '') {
      throw WorldStateError.invalidOperation('extractionRunId empty');
    }
    let rejected: number = 0;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        rejected = await this.knownEventRepo.rejectByExtractionRunIdWithStore(
          store, extractionRunId, nowMillis()
        );
      },
      'world_known_event_reject'
    );
    return rejected;
  }

  async listActiveKnownEventsByOwner(
    worldId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldKnownEventEntry[]> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (ownerCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.knownEventRepo.listActiveByOwnerWithStore(store, worldId, ownerCharacterInstanceId);
  }

  async listActiveKnownEventsByOwnerAndSession(
    worldId: string,
    ownerCharacterInstanceId: string,
    sourceSessionId: string
  ): Promise<WorldKnownEventEntry[]> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (ownerCharacterInstanceId === '') {
      throw WorldStateError.characterInstanceNotFound();
    }
    if (sourceSessionId === '') {
      throw WorldStateError.sessionNotFound();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.knownEventRepo.listActiveByOwnerAndSessionWithStore(
      store, worldId, ownerCharacterInstanceId, sourceSessionId
    );
  }

  async rejectKnownEvent(
    worldId: string,
    knownEventId: string
  ): Promise<boolean> {
    if (worldId === '') {
      throw WorldStateError.worldNotFound();
    }
    if (knownEventId === '') {
      throw WorldStateError.invalidOperation('knownEventId empty');
    }
    let result: boolean = false;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const entry: WorldKnownEventEntry | null =
          await this.knownEventRepo.getByIdWithStore(store, knownEventId);
        if (entry === null) {
          throw WorldStateError.invalidOperation('KnownEventNotFound');
        }
        if (entry.worldId !== worldId) {
          throw WorldStateError.invalidOperation('KnownEventWorldMismatch');
        }
        result = await this.knownEventRepo.updateStatusToRejectedWithStore(
          store, knownEventId, nowMillis()
        );
      },
      'world_known_event_reject'
    );
    return result;
  }

  async deleteKnownEventsByWorldId(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    await this.knownEventRepo.deleteByWorldIdWithStore(store, worldId);
  }

  private async isSourceCurrentWithStore(
    store: relationalStore.RdbStore,
    worldId: string,
    run: WorldEventExtractionRun
  ): Promise<boolean> {
    const activeRun: WorldEventExtractionRun | null =
      await this.extractionRunRepo.getActiveBySessionWithStore(
        store, worldId, run.sourceSessionId
      );
    if (activeRun === null) {
      return false;
    }
    return activeRun.id === run.id;
  }

  private parseJsonIdArray(json: string): string[] {
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

  private parseJsonIdSet(json: string): Set<string> {
    const ids: string[] = this.parseJsonIdArray(json);
    const result: Set<string> = new Set<string>();
    for (let i = 0; i < ids.length; i++) {
      result.add(ids[i]);
    }
    return result;
  }
}
