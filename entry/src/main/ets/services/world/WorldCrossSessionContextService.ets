import { WorldSessionSummaryRepository } from '../../repositories/world/WorldSessionSummaryRepository';
import { WorldCharacterMemoryEntryRepository } from '../../repositories/world/WorldCharacterMemoryEntryRepository';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldSessionSummary,
  WorldSessionSummaryVisibilityScope
} from '../../models/world/WorldSessionSummary';
import {
  WorldCharacterMemoryEntry,
  WorldCharacterMemoryKind,
  WorldCharacterMemoryEntryStatus
} from '../../models/world/WorldCharacterMemoryEntry';
import {
  WorldConversationSession,
  WorldConversationSessionStatus,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldScene } from '../../models/world/WorldScene';
import { estimateTextTokens } from '../TokenCounter';
import {
  WorldCrossSessionContextRequest,
  WorldCrossSessionContextSnapshot,
  WorldCrossSessionSummaryContextItem,
  WorldCrossSessionMemoryContextItem,
  MAX_SHARED_SUMMARY_ITEMS,
  MAX_CHARACTER_MEMORY_ITEMS,
  MAX_CROSS_SESSION_CONTEXT_CHARS
} from '../../models/world/WorldCrossSessionContext';
import { relationalStore } from '@kit.ArkData';

export class WorldCrossSessionContextService {
  private readonly summaryRepo: WorldSessionSummaryRepository;
  private readonly memoryEntryRepo: WorldCharacterMemoryEntryRepository;
  private readonly sessionRepo: WorldConversationSessionRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    summaryRepo: WorldSessionSummaryRepository,
    memoryEntryRepo: WorldCharacterMemoryEntryRepository,
    sessionRepo: WorldConversationSessionRepository,
    sceneRepo: WorldSceneRepository,
    dbHelper: DbHelper
  ) {
    this.summaryRepo = summaryRepo;
    this.memoryEntryRepo = memoryEntryRepo;
    this.sessionRepo = sessionRepo;
    this.sceneRepo = sceneRepo;
    this.dbHelper = dbHelper;
  }

  async prepareContext(request: WorldCrossSessionContextRequest): Promise<WorldCrossSessionContextSnapshot> {
    this.validateRequest(request);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const currentSession: WorldConversationSession | null =
      await this.sessionRepo.getByIdWithStore(store, request.sessionId);
    if (currentSession === null) {
      throw new Error('WorldCrossSessionContext: session not found');
    }
    if (currentSession.status !== WorldConversationSessionStatus.Active) {
      throw new Error('WorldCrossSessionContext: session must be Active');
    }
    if (currentSession.worldId !== request.worldId) {
      throw new Error('WorldCrossSessionContext: session worldId mismatch');
    }
    if (currentSession.sceneId !== request.sceneId) {
      throw new Error('WorldCrossSessionContext: session sceneId mismatch');
    }
    const scene: WorldScene | null =
      await this.sceneRepo.getByIdWithStore(store, request.sceneId);
    if (scene === null) {
      throw new Error('WorldCrossSessionContext: scene not found');
    }
    if (scene.worldId !== request.worldId) {
      throw new Error('WorldCrossSessionContext: scene worldId mismatch');
    }
    const currentParticipants: WorldSessionParticipantSnapshot[] =
      this.deserializeSnapshotSafe(currentSession.participantSnapshotJson);
    const speakerInSession: boolean = this.isParticipant(
      request.speakerCharacterInstanceId, currentParticipants
    );
    if (!speakerInSession) {
      throw new Error('WorldCrossSessionContext: speaker not in current session participantSnapshot');
    }
    const allSceneSessions: WorldConversationSession[] =
      await this.sessionRepo.listBySceneId(request.sceneId);
    const priorEndedSessions: WorldConversationSession[] = [];
    for (let i = 0; i < allSceneSessions.length; i++) {
      const s: WorldConversationSession = allSceneSessions[i];
      if (s.id === request.sessionId) {
        continue;
      }
      if (s.status !== WorldConversationSessionStatus.Ended) {
        continue;
      }
      if (s.sequenceNumber >= currentSession.sequenceNumber) {
        continue;
      }
      if (s.updatedAt > currentSession.createdAt) {
        continue;
      }
      priorEndedSessions.push(s);
    }
    priorEndedSessions.sort((a: WorldConversationSession, b: WorldConversationSession): number => {
      return b.sequenceNumber - a.sequenceNumber;
    });
    const summaryCandidates: SummaryCandidate[] = [];
    for (let i = 0; i < priorEndedSessions.length; i++) {
      const priorSession: WorldConversationSession = priorEndedSessions[i];
      const latestSummary: WorldSessionSummary | null =
        await this.summaryRepo.getLatestBySessionIdWithStore(store, priorSession.id);
      if (latestSummary === null) {
        continue;
      }
      if (latestSummary.worldId !== request.worldId) {
        continue;
      }
      if (latestSummary.sceneId !== request.sceneId) {
        continue;
      }
      const summaryParticipants: string[] =
        this.extractParticipantIdsFromSummary(latestSummary);
      if (summaryParticipants.length === 0) {
        continue;
      }
      const speakerAuthorized: boolean =
        summaryParticipants.indexOf(request.speakerCharacterInstanceId) >= 0;
      if (!speakerAuthorized) {
        continue;
      }
      const sourceMsgIds: string[] = this.parseJsonStringArray(
        latestSummary.sourceMessageIdsJson
      );
      summaryCandidates.push({
        summary: latestSummary,
        sourceSessionSequenceNumber: priorSession.sequenceNumber,
        participantIds: summaryParticipants,
        sourceMessageIds: sourceMsgIds
      });
    }
    summaryCandidates.sort((a: SummaryCandidate, b: SummaryCandidate): number => {
      return b.sourceSessionSequenceNumber - a.sourceSessionSequenceNumber;
    });
    const selectedSummaries: WorldCrossSessionSummaryContextItem[] = [];
    let totalChars: number = 0;
    let omittedSummaryCount: number = 0;
    for (let i = 0; i < summaryCandidates.length; i++) {
      if (selectedSummaries.length >= MAX_SHARED_SUMMARY_ITEMS) {
        omittedSummaryCount += summaryCandidates.length - i;
        break;
      }
      const cand: SummaryCandidate = summaryCandidates[i];
      const itemChars: number = cand.summary.content.length;
      if (totalChars + itemChars > MAX_CROSS_SESSION_CONTEXT_CHARS) {
        omittedSummaryCount++;
        continue;
      }
      selectedSummaries.push({
        summaryId: cand.summary.id,
        sourceSessionId: cand.summary.sessionId,
        sourceSessionSequenceNumber: cand.sourceSessionSequenceNumber,
        sourceLocationId: cand.summary.locationId,
        version: cand.summary.version,
        summaryText: cand.summary.content,
        participantCharacterInstanceIds: cand.participantIds,
        sourceMessageIds: cand.sourceMessageIds,
        createdAt: cand.summary.createdAt
      });
      totalChars += itemChars;
    }
    selectedSummaries.sort((a: WorldCrossSessionSummaryContextItem, b: WorldCrossSessionSummaryContextItem): number => {
      return a.sourceSessionSequenceNumber - b.sourceSessionSequenceNumber;
    });
    const allOwnerMemories: WorldCharacterMemoryEntry[] =
      await this.memoryEntryRepo.listActiveByOwnerWithStore(
        store, request.worldId, request.speakerCharacterInstanceId
      );
    const memoryCandidates: MemoryCandidate[] = [];
    for (let i = 0; i < allOwnerMemories.length; i++) {
      const mem: WorldCharacterMemoryEntry = allOwnerMemories[i];
      if (mem.worldId !== request.worldId) {
        continue;
      }
      if (mem.memoryKind !== WorldCharacterMemoryKind.EpisodicSession) {
        continue;
      }
      if (mem.sourceSessionId === request.sessionId) {
        continue;
      }
      const sourceSession: WorldConversationSession | null =
        await this.sessionRepo.getByIdWithStore(store, mem.sourceSessionId);
      if (sourceSession === null) {
        continue;
      }
      if (sourceSession.status !== WorldConversationSessionStatus.Ended) {
        continue;
      }
      if (sourceSession.sequenceNumber >= currentSession.sequenceNumber) {
        continue;
      }
      if (sourceSession.updatedAt > currentSession.createdAt) {
        continue;
      }
      const sourceMsgIds: string[] = this.parseJsonStringArray(
        mem.sourceMessageIdsJson
      );
      const isRedundant: boolean = this.isMemoryRedundantAgainstSummaries(
        sourceMsgIds, selectedSummaries
      );
      if (isRedundant) {
        continue;
      }
      const currentSceneId: string = request.sceneId;
      const currentLocationId: string = scene.locationId;
      const relevanceScore: number = this.computeMemoryRelevanceScore(
        mem, currentSceneId, currentLocationId, sourceSession
      );
      memoryCandidates.push({
        memory: mem,
        sourceSessionSequenceNumber: sourceSession.sequenceNumber,
        sourceMessageIds: sourceMsgIds,
        relevanceScore: relevanceScore
      });
    }
    memoryCandidates.sort((a: MemoryCandidate, b: MemoryCandidate): number => {
      if (a.relevanceScore !== b.relevanceScore) {
        return b.relevanceScore - a.relevanceScore;
      }
      if (a.sourceSessionSequenceNumber !== b.sourceSessionSequenceNumber) {
        return b.sourceSessionSequenceNumber - a.sourceSessionSequenceNumber;
      }
      if (a.memory.createdAt !== b.memory.createdAt) {
        return b.memory.createdAt - a.memory.createdAt;
      }
      if (a.memory.id < b.memory.id) {
        return -1;
      }
      if (a.memory.id > b.memory.id) {
        return 1;
      }
      return 0;
    });
    const selectedMemories: WorldCrossSessionMemoryContextItem[] = [];
    let omittedMemoryCount: number = 0;
    for (let i = 0; i < memoryCandidates.length; i++) {
      if (selectedMemories.length >= MAX_CHARACTER_MEMORY_ITEMS) {
        omittedMemoryCount += memoryCandidates.length - i;
        break;
      }
      const cand: MemoryCandidate = memoryCandidates[i];
      const itemChars: number = cand.memory.memoryText.length;
      if (totalChars + itemChars > MAX_CROSS_SESSION_CONTEXT_CHARS) {
        omittedMemoryCount++;
        continue;
      }
      selectedMemories.push({
        memoryId: cand.memory.id,
        ownerCharacterInstanceId: cand.memory.ownerCharacterInstanceId,
        sourceSessionId: cand.memory.sourceSessionId,
        sourceSceneId: cand.memory.sourceSceneId,
        sourceLocationId: cand.memory.sourceLocationId,
        version: cand.memory.version,
        memoryText: cand.memory.memoryText,
        confidence: cand.memory.confidence,
        memoryKind: cand.memory.memoryKind,
        sourceMessageIds: cand.sourceMessageIds,
        createdAt: cand.memory.createdAt
      });
      totalChars += itemChars;
    }
    selectedMemories.sort((a: WorldCrossSessionMemoryContextItem, b: WorldCrossSessionMemoryContextItem): number => {
      if (a.sourceSessionId !== b.sourceSessionId) {
        const sessionA: WorldConversationSession | undefined =
          this.findSessionById(allSceneSessions, a.sourceSessionId);
        const sessionB: WorldConversationSession | undefined =
          this.findSessionById(allSceneSessions, b.sourceSessionId);
        const seqA: number = sessionA !== undefined ? sessionA.sequenceNumber : 0;
        const seqB: number = sessionB !== undefined ? sessionB.sequenceNumber : 0;
        if (seqA !== seqB) {
          return seqA - seqB;
        }
      }
      if (a.createdAt !== b.createdAt) {
        return a.createdAt - b.createdAt;
      }
      if (a.memoryId < b.memoryId) {
        return -1;
      }
      if (a.memoryId > b.memoryId) {
        return 1;
      }
      return 0;
    });
    return {
      worldId: request.worldId,
      sceneId: request.sceneId,
      sessionId: request.sessionId,
      speakerCharacterInstanceId: request.speakerCharacterInstanceId,
      summaries: selectedSummaries,
      memories: selectedMemories,
      omittedSummaryCount: omittedSummaryCount,
      omittedMemoryCount: omittedMemoryCount
    };
  }

  private validateRequest(request: WorldCrossSessionContextRequest): void {
    if (request.worldId === '') {
      throw new Error('WorldCrossSessionContext: worldId empty');
    }
    if (request.sceneId === '') {
      throw new Error('WorldCrossSessionContext: sceneId empty');
    }
    if (request.sessionId === '') {
      throw new Error('WorldCrossSessionContext: sessionId empty');
    }
    if (request.speakerCharacterInstanceId === '') {
      throw new Error('WorldCrossSessionContext: speakerCharacterInstanceId empty');
    }
  }

  private isParticipant(
    instanceId: string,
    participants: WorldSessionParticipantSnapshot[]
  ): boolean {
    for (let i = 0; i < participants.length; i++) {
      if (participants[i].characterInstanceId === instanceId) {
        return true;
      }
    }
    return false;
  }

  private deserializeSnapshotSafe(json: string): WorldSessionParticipantSnapshot[] {
    if (json === '' || json === '[]') {
      return [];
    }
    try {
      return deserializeParticipantSnapshots(json);
    } catch (_e) {
      return [];
    }
  }

  private extractParticipantIdsFromSummary(summary: WorldSessionSummary): string[] {
    const participants: WorldSessionParticipantSnapshot[] =
      this.deserializeSnapshotSafe(summary.participantSnapshotJson);
    const ids: string[] = [];
    for (let i = 0; i < participants.length; i++) {
      ids.push(participants[i].characterInstanceId);
    }
    return ids;
  }

  private parseJsonStringArray(json: string): string[] {
    if (json === '' || json === '[]') {
      return [];
    }
    try {
      const parsed: Object[] = JSON.parse(json) as Object[];
      const result: string[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const item: Object = parsed[i];
        if (typeof item === 'string') {
          result.push(item as string);
        }
      }
      return result;
    } catch (_e) {
      return [];
    }
  }

  private isMemoryRedundantAgainstSummaries(
    memorySourceIds: string[],
    selectedSummaries: WorldCrossSessionSummaryContextItem[]
  ): boolean {
    if (memorySourceIds.length === 0) {
      return false;
    }
    if (selectedSummaries.length === 0) {
      return false;
    }
    const allSummarySourceIds: Set<string> = new Set<string>();
    for (let i = 0; i < selectedSummaries.length; i++) {
      const summary: WorldCrossSessionSummaryContextItem = selectedSummaries[i];
      if (summary.sourceSessionId !== memorySourceIds[0]) {
        continue;
      }
      for (let j = 0; j < summary.sourceMessageIds.length; j++) {
        allSummarySourceIds.add(summary.sourceMessageIds[j]);
      }
    }
    if (allSummarySourceIds.size === 0) {
      return false;
    }
    for (let i = 0; i < memorySourceIds.length; i++) {
      if (!allSummarySourceIds.has(memorySourceIds[i])) {
        return false;
      }
    }
    return true;
  }

  private computeMemoryRelevanceScore(
    memory: WorldCharacterMemoryEntry,
    currentSceneId: string,
    currentLocationId: string,
    sourceSession: WorldConversationSession
  ): number {
    let score: number = 0;
    if (memory.sourceSceneId === currentSceneId) {
      score += 2;
    }
    if (memory.sourceLocationId === currentLocationId) {
      score += 1;
    }
    score += sourceSession.sequenceNumber;
    return score;
  }

  private findSessionById(
    sessions: WorldConversationSession[],
    sessionId: string
  ): WorldConversationSession | undefined {
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId) {
        return sessions[i];
      }
    }
    return undefined;
  }
}

interface SummaryCandidate {
  readonly summary: WorldSessionSummary;
  readonly sourceSessionSequenceNumber: number;
  readonly participantIds: string[];
  readonly sourceMessageIds: string[];
}

interface MemoryCandidate {
  readonly memory: WorldCharacterMemoryEntry;
  readonly sourceSessionSequenceNumber: number;
  readonly sourceMessageIds: string[];
  readonly relevanceScore: number;
}
