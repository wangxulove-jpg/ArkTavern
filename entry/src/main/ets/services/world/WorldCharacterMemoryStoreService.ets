import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldCharacterMemoryEntryRepository } from '../../repositories/world/WorldCharacterMemoryEntryRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import {
  WorldCharacterMemoryEntry,
  WorldCharacterMemoryKind,
  WorldCharacterMemoryEntryStatus,
  WorldCharacterMemorySourceSnapshot,
  WorldCharacterMemorySourceMessage,
  WorldCharacterMemoryEntryError,
  WorldCharacterMemoryErrorKind,
  createWorldCharacterMemoryEntryRecord,
  WORLD_CHARACTER_MEMORY_ENTRY_ID_PREFIX
} from '../../models/world/WorldCharacterMemoryEntry';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldSceneMessage, WorldSceneMessageVisibility, WorldSceneMessageStatus } from '../../models/world/WorldSceneMessage';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { DatabaseError } from '../../models/DatabaseError';
import { generateUuid } from '../../utils/Uuid';

export class WorldCharacterMemoryStoreService {
  private readonly memoryRepo: WorldCharacterMemoryEntryRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly sceneMessageRepo: WorldSceneMessageRepository;
  private readonly characterInstanceRepo: WorldCharacterInstanceRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    memoryRepo: WorldCharacterMemoryEntryRepository,
    sessionRepo: WorldConversationSessionRepository,
    sceneMessageRepo: WorldSceneMessageRepository,
    characterInstanceRepo: WorldCharacterInstanceRepository,
    dbHelper: DbHelper
  ) {
    this.memoryRepo = memoryRepo;
    this.sessionRepo = sessionRepo;
    this.sceneMessageRepo = sceneMessageRepo;
    this.characterInstanceRepo = characterInstanceRepo;
    this.dbHelper = dbHelper;
  }

  async prepareSourceSnapshot(
    sessionId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldCharacterMemorySourceSnapshot> {
    if (sessionId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.SessionNotFound,
        'sessionId empty'
      );
    }
    if (ownerCharacterInstanceId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerNotFound,
        'ownerCharacterInstanceId empty'
      );
    }
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.SessionNotFound,
        'session not found'
      );
    }
    if (session.status !== WorldConversationSessionStatus.Ended) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.SessionNotEnded,
        'session not ended'
      );
    }
    const owner: WorldCharacterInstance | null =
      await this.characterInstanceRepo.getById(ownerCharacterInstanceId);
    if (owner === null) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerNotFound,
        'owner character instance not found'
      );
    }
    if (owner.worldId !== session.worldId) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerWorldMismatch,
        'owner world does not match session world'
      );
    }
    const participants: WorldSessionParticipantSnapshot[] =
      session.participantSnapshotJson !== ''
        ? deserializeParticipantSnapshots(session.participantSnapshotJson)
        : [];
    const ownerInSession: boolean = this.isOwnerInParticipantSnapshot(
      ownerCharacterInstanceId,
      participants
    );
    if (!ownerInSession) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerNotSessionParticipant,
        'owner not in session participant snapshot'
      );
    }
    const ownerDisplayName: string = this.getOwnerDisplayNameFromSnapshot(
      ownerCharacterInstanceId,
      participants
    );
    const allParticipantInstanceIds: string[] = [];
    for (let i = 0; i < participants.length; i++) {
      allParticipantInstanceIds.push(participants[i].characterInstanceId);
    }
    const allMessages: WorldSceneMessage[] =
      await this.sceneMessageRepo.listBySessionId(sessionId);
    const sourceMessages: WorldCharacterMemorySourceMessage[] = [];
    const sourceMessageIds: string[] = [];
    const witnessUnionSet: Set<string> = new Set<string>();
    for (let i = 0; i < allMessages.length; i++) {
      const msg: WorldSceneMessage = allMessages[i];
      if (!this.isMessageVisibleToOwner(msg, ownerCharacterInstanceId)) {
        continue;
      }
      const senderDisplayName: string = this.getSenderDisplayName(
        msg,
        participants
      );
      sourceMessages.push({
        messageId: msg.id,
        sequenceNumber: msg.sequenceNumber,
        senderKind: msg.senderType,
        senderCharacterInstanceId: msg.senderCharacterInstanceId,
        senderDisplayNameSnapshot: senderDisplayName,
        visibility: msg.visibility,
        recipientCharacterInstanceIds: msg.recipientCharacterInstanceIds,
        participantCharacterInstanceIds: msg.participantCharacterInstanceIds,
        witnessCharacterInstanceIds: msg.witnessCharacterInstanceIds,
        content: msg.content,
        createdAt: msg.createdAt
      });
      sourceMessageIds.push(msg.id);
      this.collectWitnessIdsForOwner(msg, ownerCharacterInstanceId, witnessUnionSet);
    }
    const sourceWitnessIds: string[] = Array.from(witnessUnionSet);
    sourceWitnessIds.sort();
    return {
      worldId: session.worldId,
      sceneId: session.sceneId,
      sessionId: sessionId,
      locationId: owner.currentLocationId !== undefined ? owner.currentLocationId : '',
      ownerCharacterInstanceId: ownerCharacterInstanceId,
      ownerDisplayNameSnapshot: ownerDisplayName,
      playerDisplayNameSnapshot: session.playerDisplayNameSnapshot,
      participantCharacterInstanceIds: allParticipantInstanceIds,
      messages: sourceMessages,
      sourceMessageIds: sourceMessageIds,
      sourceMessageCount: sourceMessageIds.length,
      sourceWitnessCharacterInstanceIds: sourceWitnessIds
    };
  }

  async persistCompletedMemory(
    sessionId: string,
    ownerCharacterInstanceId: string,
    memoryText: string,
    promptVersion: string,
    confidence: number,
    forceNewVersion: boolean,
    providerId?: string,
    modelId?: string
  ): Promise<WorldCharacterMemoryEntry> {
    if (sessionId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.SessionNotFound,
        'sessionId empty'
      );
    }
    if (ownerCharacterInstanceId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerNotFound,
        'ownerCharacterInstanceId empty'
      );
    }
    if (memoryText.trim() === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.EmptyMemory,
        'memoryText empty'
      );
    }
    if (promptVersion === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.InvalidSource,
        'promptVersion empty'
      );
    }
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.InvalidConfidence,
        'confidence must be in [0.0, 1.0]'
      );
    }
    const snapshot: WorldCharacterMemorySourceSnapshot =
      await this.prepareSourceSnapshot(sessionId, ownerCharacterInstanceId);
    const sourceMessageIdsJson: string = JSON.stringify(snapshot.sourceMessageIds);
    let result: WorldCharacterMemoryEntry | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const session: WorldConversationSession | null =
          await this.sessionRepo.getByIdWithStore(store, sessionId);
        if (session === null) {
          throw new WorldCharacterMemoryEntryError(
            WorldCharacterMemoryErrorKind.SessionNotFound,
            'session not found in transaction'
          );
        }
        if (session.status !== WorldConversationSessionStatus.Ended) {
          throw new WorldCharacterMemoryEntryError(
            WorldCharacterMemoryErrorKind.SessionNotEnded,
            'session not ended in transaction'
          );
        }
        if (!forceNewVersion) {
          const existing: WorldCharacterMemoryEntry | null =
            await this.memoryRepo.findActiveByOwnerSessionKindPromptVersionWithStore(
              store,
              snapshot.worldId,
              ownerCharacterInstanceId,
              sessionId,
              WorldCharacterMemoryKind.EpisodicSession,
              promptVersion
            );
          if (existing !== null && existing.sourceMessageIdsJson === sourceMessageIdsJson) {
            result = existing;
            return;
          }
        }
        const freshMessages: WorldSceneMessage[] =
          await this.sceneMessageRepo.listBySessionIdWithStore(store, sessionId);
        const freshVisibleIds: string[] = [];
        for (let i = 0; i < freshMessages.length; i++) {
          const msg: WorldSceneMessage = freshMessages[i];
          if (this.isMessageVisibleToOwner(msg, ownerCharacterInstanceId)) {
            freshVisibleIds.push(msg.id);
          }
        }
        const freshSourceIdsJson: string = JSON.stringify(freshVisibleIds);
        if (freshSourceIdsJson !== sourceMessageIdsJson) {
          throw new WorldCharacterMemoryEntryError(
            WorldCharacterMemoryErrorKind.SourceChanged,
            'source message ids changed during transaction'
          );
        }
        const existingActive: WorldCharacterMemoryEntry | null =
          await this.memoryRepo.findActiveByOwnerSessionKindPromptVersionWithStore(
            store,
            snapshot.worldId,
            ownerCharacterInstanceId,
            sessionId,
            WorldCharacterMemoryKind.EpisodicSession,
            promptVersion
          );
        let supersedesMemoryId: string | undefined = undefined;
        if (existingActive !== null) {
          const now: number = Date.now();
          await this.memoryRepo.updateStatusWithStore(
            store,
            existingActive.id,
            WorldCharacterMemoryEntryStatus.Superseded,
            now
          );
          supersedesMemoryId = existingActive.id;
        }
        const version: number =
          await this.memoryRepo.getNextVersionForOwnerSessionKindWithStore(
            store,
            snapshot.worldId,
            ownerCharacterInstanceId,
            sessionId,
            WorldCharacterMemoryKind.EpisodicSession
          );
        const id: string = WORLD_CHARACTER_MEMORY_ENTRY_ID_PREFIX + generateUuid();
        const entry: WorldCharacterMemoryEntry = createWorldCharacterMemoryEntryRecord({
          id: id,
          worldId: snapshot.worldId,
          ownerCharacterInstanceId: ownerCharacterInstanceId,
          memoryKind: WorldCharacterMemoryKind.EpisodicSession,
          sourceSceneId: snapshot.sceneId,
          sourceSessionId: sessionId,
          sourceLocationId: snapshot.locationId,
          version: version,
          memoryText: memoryText,
          sourceMessageIdsJson: sourceMessageIdsJson,
          sourceMessageCount: snapshot.sourceMessageCount,
          sourceParticipantInstanceIdsJson: JSON.stringify(snapshot.participantCharacterInstanceIds),
          sourceWitnessInstanceIdsJson: JSON.stringify(snapshot.sourceWitnessCharacterInstanceIds),
          ownerDisplayNameSnapshot: snapshot.ownerDisplayNameSnapshot,
          playerDisplayNameSnapshot: snapshot.playerDisplayNameSnapshot,
          confidence: confidence,
          promptVersion: promptVersion,
          providerId: providerId,
          modelId: modelId,
          supersedesMemoryId: supersedesMemoryId
        });
        await this.memoryRepo.insertWithStore(store, entry);
        result = entry;
      },
      'world_character_memory_entry_persist'
    );
    if (result === null) {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.MemoryPersistenceFailed,
        'no result after persist transaction'
      );
    }
    return result;
  }

  async getLatestMemoryForSession(
    worldId: string,
    ownerCharacterInstanceId: string,
    sessionId: string
  ): Promise<WorldCharacterMemoryEntry | null> {
    if (worldId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.WorldNotFound,
        'worldId empty'
      );
    }
    if (ownerCharacterInstanceId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerNotFound,
        'ownerCharacterInstanceId empty'
      );
    }
    if (sessionId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.SessionNotFound,
        'sessionId empty'
      );
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const entries: WorldCharacterMemoryEntry[] =
      await this.memoryRepo.listActiveByOwnerAndSessionWithStore(
        store,
        worldId,
        ownerCharacterInstanceId,
        sessionId
      );
    if (entries.length === 0) {
      return null;
    }
    return entries[0];
  }

  async listActiveMemoriesForOwner(
    worldId: string,
    ownerCharacterInstanceId: string
  ): Promise<WorldCharacterMemoryEntry[]> {
    if (worldId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.WorldNotFound,
        'worldId empty'
      );
    }
    if (ownerCharacterInstanceId === '') {
      throw new WorldCharacterMemoryEntryError(
        WorldCharacterMemoryErrorKind.OwnerNotFound,
        'ownerCharacterInstanceId empty'
      );
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.memoryRepo.listActiveByOwnerWithStore(
      store,
      worldId,
      ownerCharacterInstanceId
    );
  }

  private isOwnerInParticipantSnapshot(
    ownerCharacterInstanceId: string,
    participants: WorldSessionParticipantSnapshot[]
  ): boolean {
    for (let i = 0; i < participants.length; i++) {
      if (participants[i].characterInstanceId === ownerCharacterInstanceId) {
        return true;
      }
    }
    return false;
  }

  private getOwnerDisplayNameFromSnapshot(
    ownerCharacterInstanceId: string,
    participants: WorldSessionParticipantSnapshot[]
  ): string {
    for (let i = 0; i < participants.length; i++) {
      if (participants[i].characterInstanceId === ownerCharacterInstanceId) {
        return participants[i].displayNameSnapshot;
      }
    }
    return '';
  }

  private isMessageVisibleToOwner(
    msg: WorldSceneMessage,
    ownerCharacterInstanceId: string
  ): boolean {
    if (msg.status !== WorldSceneMessageStatus.Completed) {
      return false;
    }
    if (msg.content.trim() === '') {
      return false;
    }
    if (msg.visibility === WorldSceneMessageVisibility.Public) {
      const participantIds: string[] | undefined = msg.participantCharacterInstanceIds;
      const witnessIds: string[] | undefined = msg.witnessCharacterInstanceIds;
      const hasProvenance: boolean =
        (participantIds !== undefined && participantIds.length > 0) ||
        (witnessIds !== undefined && witnessIds.length > 0);
      if (!hasProvenance) {
        return false;
      }
      const isInParticipant: boolean = participantIds !== undefined
        && participantIds.indexOf(ownerCharacterInstanceId) >= 0;
      const isInWitness: boolean = witnessIds !== undefined
        && witnessIds.indexOf(ownerCharacterInstanceId) >= 0;
      return isInParticipant || isInWitness;
    }
    if (msg.visibility === WorldSceneMessageVisibility.Private) {
      const isSender: boolean = msg.senderType === 'character'
        && msg.senderCharacterInstanceId === ownerCharacterInstanceId;
      const recipientIds: string[] | undefined = msg.recipientCharacterInstanceIds;
      const isRecipient: boolean = recipientIds !== undefined
        && recipientIds.indexOf(ownerCharacterInstanceId) >= 0;
      return isSender || isRecipient;
    }
    if (msg.visibility === WorldSceneMessageVisibility.Narrator) {
      const participantIds: string[] | undefined = msg.participantCharacterInstanceIds;
      const witnessIds: string[] | undefined = msg.witnessCharacterInstanceIds;
      const hasProvenance: boolean =
        (participantIds !== undefined && participantIds.length > 0) ||
        (witnessIds !== undefined && witnessIds.length > 0);
      if (!hasProvenance) {
        return false;
      }
      const isInParticipant: boolean = participantIds !== undefined
        && participantIds.indexOf(ownerCharacterInstanceId) >= 0;
      const isInWitness: boolean = witnessIds !== undefined
        && witnessIds.indexOf(ownerCharacterInstanceId) >= 0;
      return isInParticipant || isInWitness;
    }
    return false;
  }

  private getSenderDisplayName(
    msg: WorldSceneMessage,
    participants: WorldSessionParticipantSnapshot[]
  ): string {
    if (msg.senderType === 'character' && msg.senderCharacterInstanceId !== undefined) {
      for (let i = 0; i < participants.length; i++) {
        if (participants[i].characterInstanceId === msg.senderCharacterInstanceId) {
          return participants[i].displayNameSnapshot;
        }
      }
    }
    if (msg.senderType === 'user') {
      return 'User';
    }
    if (msg.senderType === 'narrator') {
      return 'Narrator';
    }
    return '';
  }

  private collectWitnessIdsForOwner(
    msg: WorldSceneMessage,
    ownerCharacterInstanceId: string,
    witnessUnionSet: Set<string>
  ): void {
    if (!this.isMessageVisibleToOwner(msg, ownerCharacterInstanceId)) {
      return;
    }
    const participantIds: string[] | undefined = msg.participantCharacterInstanceIds;
    if (participantIds !== undefined) {
      for (let i = 0; i < participantIds.length; i++) {
        witnessUnionSet.add(participantIds[i]);
      }
    }
    const witnessIds: string[] | undefined = msg.witnessCharacterInstanceIds;
    if (witnessIds !== undefined) {
      for (let i = 0; i < witnessIds.length; i++) {
        witnessUnionSet.add(witnessIds[i]);
      }
    }
    if (msg.senderType === 'character' && msg.senderCharacterInstanceId !== undefined) {
      witnessUnionSet.add(msg.senderCharacterInstanceId);
    }
  }
}
