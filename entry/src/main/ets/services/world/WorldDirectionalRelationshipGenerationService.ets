import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatStreamCallbacks, ChatStreamResult } from '../../models/ChatStreamTypes';
import { NetworkError } from '../../models/NetworkError';
import { ModelService } from '../ModelService';
import {
  WorldDirectionalRelationshipEntry,
  WorldDirectionalRelationshipPersistResult
} from '../../models/world/WorldDirectionalRelationshipEntry';
import {
  WorldCharacterMemorySourceSnapshot
} from '../../models/world/WorldCharacterMemoryEntry';
import {
  WorldConversationSession,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldStateError } from '../../models/world/WorldStateError';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldDirectionalRelationshipStoreService } from './WorldDirectionalRelationshipStoreService';
import {
  WorldDirectionalRelationshipPromptAssembler,
  WorldDirectionalRelationshipMetadata,
  WorldDirectionalRelationshipPromptResult,
  WORLD_DIRECTIONAL_RELATIONSHIP_PROMPT_VERSION,
  MAX_WORLD_RELATIONSHIP_TEXT_LENGTH
} from './WorldDirectionalRelationshipPromptAssembler';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldRelGen';

export const MAX_RELATIONSHIP_PAIR_GENERATIONS_PER_BATCH: number = 20;

export enum WorldDirectionalRelationshipGenerationErrorKind {
  SourcePreparationFailed = 'source_preparation_failed',
  NoVisibleEvidence = 'no_visible_evidence',
  NoModelConfiguration = 'no_model_configuration',
  MetadataNotFound = 'metadata_not_found',
  TargetNotParticipant = 'target_not_participant',
  OwnerEqualsTarget = 'owner_equals_target',
  ModelRequestFailed = 'model_request_failed',
  ModelCancelled = 'model_cancelled',
  InvalidModelOutput = 'invalid_model_output',
  InvalidResultField = 'invalid_result_field',
  EmptyRelationshipText = 'empty_relationship_text',
  RelationshipTextTooLarge = 'relationship_text_too_large',
  InvalidConfidence = 'invalid_confidence',
  InvalidEvidenceIds = 'invalid_evidence_ids',
  UnknownEvidenceId = 'unknown_evidence_id',
  SourceChanged = 'source_changed',
  PersistenceFailed = 'persistence_failed',
  SessionNotFound = 'session_not_found',
  BatchTooLarge = 'batch_too_large'
}

export class WorldDirectionalRelationshipGenerationError extends Error {
  readonly kind: WorldDirectionalRelationshipGenerationErrorKind;
  readonly cause: Object | null;

  constructor(kind: WorldDirectionalRelationshipGenerationErrorKind, message: string, cause: Object | null = null) {
    super(message);
    this.name = 'WorldDirectionalRelationshipGenerationError';
    this.kind = kind;
    this.cause = cause;
  }
}

export interface WorldDirectionalRelationshipPairGenerationOptions {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly ownerCharacterInstanceId: string;
  readonly targetCharacterInstanceId: string;
  readonly forceNewVersion?: boolean;
}

export enum WorldDirectionalRelationshipPairGenerationStatus {
  Generated = 'generated',
  Existing = 'existing',
  NoChange = 'no_change',
  Failed = 'failed'
}

export interface WorldDirectionalRelationshipPairGenerationResult {
  readonly ownerCharacterInstanceId: string;
  readonly targetCharacterInstanceId: string;
  readonly status: WorldDirectionalRelationshipPairGenerationStatus;
  readonly relationship: WorldDirectionalRelationshipEntry | null;
  readonly errorKind: WorldDirectionalRelationshipGenerationErrorKind | null;
}

export interface WorldDirectionalRelationshipBatchGenerationResult {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly results: ReadonlyArray<WorldDirectionalRelationshipPairGenerationResult>;
}

export class WorldDirectionalRelationshipGenerationService {
  private readonly storeService: WorldDirectionalRelationshipStoreService;
  private readonly promptAssembler: WorldDirectionalRelationshipPromptAssembler;
  private readonly modelService: ModelService;
  private readonly sessionRepo: WorldConversationSessionRepository;

  constructor(
    storeService: WorldDirectionalRelationshipStoreService,
    promptAssembler: WorldDirectionalRelationshipPromptAssembler,
    modelService: ModelService,
    sessionRepo: WorldConversationSessionRepository
  ) {
    this.storeService = storeService;
    this.promptAssembler = promptAssembler;
    this.modelService = modelService;
    this.sessionRepo = sessionRepo;
  }

  async generateForPair(
    options: WorldDirectionalRelationshipPairGenerationOptions
  ): Promise<WorldDirectionalRelationshipPairGenerationResult> {
    const ownerInstanceId: string = options.ownerCharacterInstanceId;
    const targetInstanceId: string = options.targetCharacterInstanceId;
    const forceNewVersion: boolean = options.forceNewVersion === true;

    if (ownerInstanceId === targetInstanceId) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.OwnerEqualsTarget
      };
    }

    let snapshot: WorldCharacterMemorySourceSnapshot;
    try {
      snapshot = await this.storeService.prepareSourceSnapshot(
        options.sessionId, ownerInstanceId
      );
    } catch (err) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.SourcePreparationFailed
      };
    }

    if (snapshot.sourceMessageCount === 0) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.NoVisibleEvidence
      };
    }

    let isTargetParticipant: boolean = false;
    for (let i = 0; i < snapshot.participantCharacterInstanceIds.length; i++) {
      if (snapshot.participantCharacterInstanceIds[i] === targetInstanceId) {
        isTargetParticipant = true;
        break;
      }
    }
    if (!isTargetParticipant) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.TargetNotParticipant
      };
    }

    const sourceMessageIdsJson: string = JSON.stringify(snapshot.sourceMessageIds);
    const existingActive: WorldDirectionalRelationshipEntry | null =
      await this.storeService.getActiveRelationship(
        options.worldId, ownerInstanceId, targetInstanceId
      );
    if (!forceNewVersion && existingActive !== null) {
      if (existingActive.sourceSessionId === options.sessionId
        && existingActive.promptVersion === WORLD_DIRECTIONAL_RELATIONSHIP_PROMPT_VERSION
        && existingActive.evidenceMessageIdsJson === sourceMessageIdsJson) {
        Logger.info(LOG_TAG, `Existing: owner=${ownerInstanceId.substring(0, 8)} target=${targetInstanceId.substring(0, 8)} v=${existingActive.version}`);
        return {
          ownerCharacterInstanceId: ownerInstanceId,
          targetCharacterInstanceId: targetInstanceId,
          status: WorldDirectionalRelationshipPairGenerationStatus.Existing,
          relationship: existingActive,
          errorKind: null
        };
      }
    }

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.NoModelConfiguration
      };
    }
    const providerId: string = config.id;
    const modelId: string = config.modelName;

    const participants = await this.loadParticipantSnapshot(options.sessionId);
    const targetDisplayName: string = this.resolveDisplayNameFromParticipants(
      targetInstanceId, participants
    );

    const metadata: WorldDirectionalRelationshipMetadata | null =
      await this.promptAssembler.loadMetadata(snapshot, targetDisplayName);
    if (metadata === null) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.MetadataNotFound
      };
    }

    const previousRelationship: WorldDirectionalRelationshipEntry | null =
      await this.storeService.getActiveRelationship(
        options.worldId, ownerInstanceId, targetInstanceId
      );

    const promptResult: WorldDirectionalRelationshipPromptResult =
      this.promptAssembler.assemble(snapshot, metadata, previousRelationship);

    let rawOutput: string;
    try {
      rawOutput = await this.executeModelRequest(config, promptResult);
    } catch (err) {
      if (err instanceof WorldDirectionalRelationshipGenerationError) {
        return {
          ownerCharacterInstanceId: ownerInstanceId,
          targetCharacterInstanceId: targetInstanceId,
          status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
          relationship: null,
          errorKind: err.kind
        };
      }
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.ModelRequestFailed
      };
    }

    const cleanedOutput: string = this.promptAssembler.validateOutput(rawOutput);
    if (cleanedOutput === '') {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidModelOutput
      };
    }

    const parsed: ParsedRelationshipOutput = this.parseRelationshipJson(cleanedOutput, snapshot.sourceMessageIds);

    if (parsed.result === 'no_change') {
      Logger.info(LOG_TAG, `NoChange: owner=${ownerInstanceId.substring(0, 8)} target=${targetInstanceId.substring(0, 8)}`);
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.NoChange,
        relationship: null,
        errorKind: null
      };
    }

    if (parsed.errorKind !== null) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: parsed.errorKind
      };
    }

    if (parsed.relationshipText === '' || parsed.evidenceMessageIds === null || parsed.confidenceValid === false) {
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidModelOutput
      };
    }

    try {
      const persistResult: WorldDirectionalRelationshipPersistResult =
        await this.storeService.persistRelationshipSnapshot(
          snapshot,
          targetInstanceId,
          parsed.relationshipText,
          parsed.confidence,
          parsed.evidenceMessageIds,
          WORLD_DIRECTIONAL_RELATIONSHIP_PROMPT_VERSION,
          forceNewVersion,
          providerId,
          modelId
        );
      Logger.info(LOG_TAG, `Generated: owner=${ownerInstanceId.substring(0, 8)} target=${targetInstanceId.substring(0, 8)} v=${persistResult.entry.version} conf=${parsed.confidence}`);
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Generated,
        relationship: persistResult.entry,
        errorKind: null
      };
    } catch (err) {
      if (err instanceof WorldStateError) {
        const msg: string = err.message;
        if (msg === 'SourceChanged') {
          return {
            ownerCharacterInstanceId: ownerInstanceId,
            targetCharacterInstanceId: targetInstanceId,
            status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
            relationship: null,
            errorKind: WorldDirectionalRelationshipGenerationErrorKind.SourceChanged
          };
        }
      }
      return {
        ownerCharacterInstanceId: ownerInstanceId,
        targetCharacterInstanceId: targetInstanceId,
        status: WorldDirectionalRelationshipPairGenerationStatus.Failed,
        relationship: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.PersistenceFailed
      };
    }
  }

  async generateForSession(
    worldId: string,
    sceneId: string,
    sessionId: string,
    forceNewVersion?: boolean
  ): Promise<WorldDirectionalRelationshipBatchGenerationResult> {
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new WorldDirectionalRelationshipGenerationError(
        WorldDirectionalRelationshipGenerationErrorKind.NoModelConfiguration,
        'no model configuration for batch generation'
      );
    }
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      throw new WorldDirectionalRelationshipGenerationError(
        WorldDirectionalRelationshipGenerationErrorKind.SessionNotFound,
        'session not found'
      );
    }
    const participants: WorldSessionParticipantSnapshot[] =
      session.participantSnapshotJson !== ''
        ? deserializeParticipantSnapshots(session.participantSnapshotJson)
        : [];

    const pairs: DirectedPair[] = this.buildOrderedPairs(participants);
    if (pairs.length > MAX_RELATIONSHIP_PAIR_GENERATIONS_PER_BATCH) {
      throw new WorldDirectionalRelationshipGenerationError(
        WorldDirectionalRelationshipGenerationErrorKind.BatchTooLarge,
        `pair count ${pairs.length} exceeds limit ${MAX_RELATIONSHIP_PAIR_GENERATIONS_PER_BATCH}`
      );
    }

    const results: WorldDirectionalRelationshipPairGenerationResult[] = [];
    for (let i = 0; i < pairs.length; i++) {
      const pair: DirectedPair = pairs[i];
      const pairResult: WorldDirectionalRelationshipPairGenerationResult =
        await this.generateForPair({
          worldId: worldId,
          sceneId: sceneId,
          sessionId: sessionId,
          ownerCharacterInstanceId: pair.owner,
          targetCharacterInstanceId: pair.target,
          forceNewVersion: forceNewVersion
        });
      results.push(pairResult);
    }

    return {
      worldId: worldId,
      sceneId: sceneId,
      sessionId: sessionId,
      results: results
    };
  }

  private buildOrderedPairs(participants: WorldSessionParticipantSnapshot[]): DirectedPair[] {
    const pairs: DirectedPair[] = [];
    for (let i = 0; i < participants.length; i++) {
      for (let j = 0; j < participants.length; j++) {
        if (i !== j) {
          const pair: DirectedPair = {
            owner: participants[i].characterInstanceId,
            target: participants[j].characterInstanceId
          };
          pairs.push(pair);
        }
      }
    }
    return pairs;
  }

  private async loadParticipantSnapshot(sessionId: string): Promise<WorldSessionParticipantSnapshot[]> {
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      return [];
    }
    if (session.participantSnapshotJson === '') {
      return [];
    }
    return deserializeParticipantSnapshots(session.participantSnapshotJson);
  }

  private resolveDisplayNameFromParticipants(
    characterInstanceId: string,
    participants: WorldSessionParticipantSnapshot[]
  ): string {
    for (let i = 0; i < participants.length; i++) {
      if (participants[i].characterInstanceId === characterInstanceId) {
        return participants[i].displayNameSnapshot;
      }
    }
    return '';
  }

  private executeModelRequest(
    config: ProviderConfig,
    promptResult: WorldDirectionalRelationshipPromptResult
  ): Promise<string> {
    return new Promise<string>((resolve: (text: string) => void, reject: (error: WorldDirectionalRelationshipGenerationError) => void): void => {
      let accumulated: string = '';
      let terminalFired: boolean = false;

      const callbacks: ChatStreamCallbacks = {
        onStart: (): void => {},
        onDelta: (delta): void => {
          if (delta.content !== undefined && delta.content !== '') {
            accumulated += delta.content;
          }
        },
        onComplete: (result: ChatStreamResult): void => {
          if (terminalFired) {
            return;
          }
          terminalFired = true;
          const finalText: string = result.content !== '' ? result.content : accumulated;
          resolve(finalText);
        },
        onError: (error: NetworkError): void => {
          if (terminalFired) {
            return;
          }
          terminalFired = true;
          reject(new WorldDirectionalRelationshipGenerationError(
            WorldDirectionalRelationshipGenerationErrorKind.ModelRequestFailed,
            'model request failed',
            error
          ));
        }
      };

      this.modelService.streamChatWithConfig(config, promptResult.messages, promptResult.options, callbacks);
    });
  }

  private parseRelationshipJson(
    raw: string,
    sourceMessageIds: ReadonlyArray<string>
  ): ParsedRelationshipOutput {
    let parsed: Object;
    try {
      parsed = JSON.parse(raw);
    } catch (_e) {
      return {
        result: '',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidModelOutput
      };
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return {
        result: '',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidModelOutput
      };
    }
    const record: Record<string, Object> = parsed as Record<string, Object>;

    const resultObj: Object | undefined = record['result'];
    if (typeof resultObj !== 'string') {
      return {
        result: '',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidResultField
      };
    }
    const resultStr: string = (resultObj as string).trim();

    if (resultStr === 'no_change') {
      return {
        result: 'no_change',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: null
      };
    }

    if (resultStr !== 'changed') {
      return {
        result: '',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidResultField
      };
    }

    const textObj: Object | undefined = record['relationshipText'];
    if (typeof textObj !== 'string') {
      return {
        result: 'changed',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.EmptyRelationshipText
      };
    }
    const relationshipText: string = (textObj as string).trim();
    if (relationshipText === '') {
      return {
        result: 'changed',
        relationshipText: '',
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.EmptyRelationshipText
      };
    }
    if (relationshipText.length > MAX_WORLD_RELATIONSHIP_TEXT_LENGTH) {
      return {
        result: 'changed',
        relationshipText: relationshipText,
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.RelationshipTextTooLarge
      };
    }

    const confidenceObj: Object | undefined = record['confidence'];
    if (typeof confidenceObj !== 'number') {
      return {
        result: 'changed',
        relationshipText: relationshipText,
        confidence: 0,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidConfidence
      };
    }
    const confidence: number = confidenceObj as number;
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
      return {
        result: 'changed',
        relationshipText: relationshipText,
        confidence: confidence,
        confidenceValid: false,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidConfidence
      };
    }

    const evidenceObj: Object | undefined = record['evidenceMessageIds'];
    if (!Array.isArray(evidenceObj)) {
      return {
        result: 'changed',
        relationshipText: relationshipText,
        confidence: confidence,
        confidenceValid: true,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidEvidenceIds
      };
    }
    const evidenceArr: Object[] = evidenceObj as Object[];
    if (evidenceArr.length === 0) {
      return {
        result: 'changed',
        relationshipText: relationshipText,
        confidence: confidence,
        confidenceValid: true,
        evidenceMessageIds: null,
        errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidEvidenceIds
      };
    }
    const evidenceIds: string[] = [];
    const sourceIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < sourceMessageIds.length; i++) {
      sourceIdSet.add(sourceMessageIds[i]);
    }
    for (let i = 0; i < evidenceArr.length; i++) {
      const item: Object = evidenceArr[i];
      if (typeof item !== 'string') {
        return {
          result: 'changed',
          relationshipText: relationshipText,
          confidence: confidence,
          confidenceValid: true,
          evidenceMessageIds: null,
          errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidEvidenceIds
        };
      }
      const id: string = item as string;
      if (id === '') {
        return {
          result: 'changed',
          relationshipText: relationshipText,
          confidence: confidence,
          confidenceValid: true,
          evidenceMessageIds: null,
          errorKind: WorldDirectionalRelationshipGenerationErrorKind.InvalidEvidenceIds
        };
      }
      if (!sourceIdSet.has(id)) {
        return {
          result: 'changed',
          relationshipText: relationshipText,
          confidence: confidence,
          confidenceValid: true,
          evidenceMessageIds: null,
          errorKind: WorldDirectionalRelationshipGenerationErrorKind.UnknownEvidenceId
        };
      }
      evidenceIds.push(id);
    }

    return {
      result: 'changed',
      relationshipText: relationshipText,
      confidence: confidence,
      confidenceValid: true,
      evidenceMessageIds: evidenceIds,
      errorKind: null
    };
  }
}

interface ParsedRelationshipOutput {
  readonly result: string;
  readonly relationshipText: string;
  readonly confidence: number;
  readonly confidenceValid: boolean;
  readonly evidenceMessageIds: string[] | null;
  readonly errorKind: WorldDirectionalRelationshipGenerationErrorKind | null;
}

interface DirectedPair {
  readonly owner: string;
  readonly target: string;
}
