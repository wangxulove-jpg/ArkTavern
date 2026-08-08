import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatStreamCallbacks, ChatStreamResult } from '../../models/ChatStreamTypes';
import { NetworkError } from '../../models/NetworkError';
import { ModelService } from '../ModelService';
import {
  WorldCharacterMemoryEntry,
  WorldCharacterMemorySourceSnapshot,
  WorldCharacterMemoryErrorKind,
  WorldCharacterMemoryEntryError
} from '../../models/world/WorldCharacterMemoryEntry';
import {
  WorldConversationSession,
  WorldSessionParticipantSnapshot,
  deserializeParticipantSnapshots
} from '../../models/world/WorldConversationSession';
import { WorldConversationSessionRepository } from '../../repositories/world/WorldConversationSessionRepository';
import { WorldCharacterMemoryStoreService } from './WorldCharacterMemoryStoreService';
import {
  WorldCharacterMemoryPromptAssembler,
  WorldCharacterMemoryMetadata,
  WorldCharacterMemoryPromptResult,
  WORLD_CHARACTER_EPISODIC_MEMORY_PROMPT_VERSION,
  MAX_WORLD_CHARACTER_MEMORY_TEXT_LENGTH
} from './WorldCharacterMemoryPromptAssembler';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterMemoryGeneration';

export enum WorldCharacterMemoryGenerationErrorKind {
  SourcePreparationFailed = 'source_preparation_failed',
  NoVisibleEvidence = 'no_visible_evidence',
  NoModelConfiguration = 'no_model_configuration',
  MetadataNotFound = 'metadata_not_found',
  ModelRequestFailed = 'model_request_failed',
  ModelCancelled = 'model_cancelled',
  InvalidModelOutput = 'invalid_model_output',
  EmptyMemoryOutput = 'empty_memory_output',
  MemoryOutputTooLarge = 'memory_output_to_large',
  InvalidConfidence = 'invalid_confidence',
  SourceChanged = 'source_changed',
  MemoryPersistenceFailed = 'memory_persistence_failed'
}

export class WorldCharacterMemoryGenerationError extends Error {
  readonly kind: WorldCharacterMemoryGenerationErrorKind;
  readonly cause: Object | null;

  constructor(kind: WorldCharacterMemoryGenerationErrorKind, message: string, cause: Object | null = null) {
    super(message);
    this.name = 'WorldCharacterMemoryGenerationError';
    this.kind = kind;
    this.cause = cause;
  }
}

export interface WorldCharacterMemoryGenerationOptions {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly ownerCharacterInstanceId: string;
  readonly forceNewVersion?: boolean;
}

export enum WorldCharacterMemoryGenerationStatus {
  Generated = 'generated',
  Existing = 'existing',
  NoVisibleEvidence = 'no_visible_evidence'
}

export interface WorldCharacterMemoryGenerationResult {
  readonly status: WorldCharacterMemoryGenerationStatus;
  readonly memory: WorldCharacterMemoryEntry | null;
  readonly errorKind: WorldCharacterMemoryGenerationErrorKind | null;
}

export interface OwnerMemoryGenerationResult {
  readonly ownerCharacterInstanceId: string;
  readonly status: WorldCharacterMemoryGenerationStatus;
  readonly memory: WorldCharacterMemoryEntry | null;
  readonly errorKind: WorldCharacterMemoryGenerationErrorKind | null;
}

export interface WorldCharacterMemoryBatchGenerationResult {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly results: ReadonlyArray<OwnerMemoryGenerationResult>;
}

export class WorldCharacterMemoryGenerationService {
  private readonly storeService: WorldCharacterMemoryStoreService;
  private readonly promptAssembler: WorldCharacterMemoryPromptAssembler;
  private readonly modelService: ModelService;
  private readonly sessionRepo: WorldConversationSessionRepository;

  constructor(
    storeService: WorldCharacterMemoryStoreService,
    promptAssembler: WorldCharacterMemoryPromptAssembler,
    modelService: ModelService,
    sessionRepo: WorldConversationSessionRepository
  ) {
    this.storeService = storeService;
    this.promptAssembler = promptAssembler;
    this.modelService = modelService;
    this.sessionRepo = sessionRepo;
  }

  async generateForOwner(
    options: WorldCharacterMemoryGenerationOptions
  ): Promise<WorldCharacterMemoryGenerationResult> {
    const sessionId: string = options.sessionId;
    const ownerInstanceId: string = options.ownerCharacterInstanceId;
    const forceNewVersion: boolean = options.forceNewVersion === true;

    let snapshot: WorldCharacterMemorySourceSnapshot;
    try {
      snapshot = await this.storeService.prepareSourceSnapshot(sessionId, ownerInstanceId);
    } catch (err) {
      if (err instanceof WorldCharacterMemoryEntryError) {
        return {
          status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
          memory: null,
          errorKind: WorldCharacterMemoryGenerationErrorKind.SourcePreparationFailed
        };
      }
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.SourcePreparationFailed
      };
    }

    if (snapshot.sourceMessageCount === 0) {
      Logger.info(LOG_TAG, `NoVisibleEvidence: owner=${ownerInstanceId.substring(0, 8)} session=${sessionId.substring(0, 8)}`);
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: null
      };
    }

    const sourceMessageIdsJson: string = JSON.stringify(snapshot.sourceMessageIds);
    if (!forceNewVersion) {
      const existing: WorldCharacterMemoryEntry | null =
        await this.storeService.getLatestMemoryForSession(
          options.worldId, ownerInstanceId, sessionId
        );
      if (existing !== null
        && existing.promptVersion === WORLD_CHARACTER_EPISODIC_MEMORY_PROMPT_VERSION
        && existing.sourceMessageIdsJson === sourceMessageIdsJson) {
        Logger.info(LOG_TAG, `Existing: owner=${ownerInstanceId.substring(0, 8)} version=${existing.version}`);
        return {
          status: WorldCharacterMemoryGenerationStatus.Existing,
          memory: existing,
          errorKind: null
        };
      }
    }

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.NoModelConfiguration
      };
    }
    const providerId: string = config.id;
    const modelId: string = config.modelName;

    const metadata: WorldCharacterMemoryMetadata | null =
      await this.promptAssembler.loadMetadata(snapshot);
    if (metadata === null) {
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.MetadataNotFound
      };
    }

    const promptResult: WorldCharacterMemoryPromptResult =
      this.promptAssembler.assemble(snapshot, metadata);

    let rawOutput: string;
    try {
      rawOutput = await this.executeModelRequest(config, promptResult);
    } catch (err) {
      if (err instanceof WorldCharacterMemoryGenerationError) {
        Logger.info(LOG_TAG, `ModelFailed: owner=${ownerInstanceId.substring(0, 8)} kind=${err.kind}`);
        return {
          status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
          memory: null,
          errorKind: err.kind
        };
      }
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.ModelRequestFailed
      };
    }

    const cleanedOutput: string = this.promptAssembler.validateOutput(rawOutput);
    if (cleanedOutput === '') {
      Logger.info(LOG_TAG, `EmptyModelOutput: owner=${ownerInstanceId.substring(0, 8)}`);
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.EmptyMemoryOutput
      };
    }

    const parsed: ParsedMemoryOutput = this.parseMemoryJson(cleanedOutput);
    if (parsed.memoryText === '') {
      Logger.info(LOG_TAG, `InvalidModelOutput: owner=${ownerInstanceId.substring(0, 8)}`);
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.InvalidModelOutput
      };
    }
    if (parsed.memoryText.length > MAX_WORLD_CHARACTER_MEMORY_TEXT_LENGTH) {
      Logger.info(LOG_TAG, `MemoryOutputTooLarge: owner=${ownerInstanceId.substring(0, 8)} len=${parsed.memoryText.length}`);
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.MemoryOutputTooLarge
      };
    }
    if (!parsed.confidenceValid) {
      Logger.info(LOG_TAG, `InvalidConfidence: owner=${ownerInstanceId.substring(0, 8)}`);
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.InvalidConfidence
      };
    }

    try {
      const entry: WorldCharacterMemoryEntry =
        await this.storeService.persistCompletedMemory(
          sessionId,
          ownerInstanceId,
          parsed.memoryText,
          WORLD_CHARACTER_EPISODIC_MEMORY_PROMPT_VERSION,
          parsed.confidence,
          forceNewVersion,
          providerId,
          modelId
        );
      Logger.info(LOG_TAG, `Generated: owner=${ownerInstanceId.substring(0, 8)} version=${entry.version} confidence=${parsed.confidence}`);
      return {
        status: WorldCharacterMemoryGenerationStatus.Generated,
        memory: entry,
        errorKind: null
      };
    } catch (err) {
      if (err instanceof WorldCharacterMemoryEntryError) {
        if (err.kind === WorldCharacterMemoryErrorKind.SourceChanged) {
          return {
            status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
            memory: null,
            errorKind: WorldCharacterMemoryGenerationErrorKind.SourceChanged
          };
        }
      }
      return {
        status: WorldCharacterMemoryGenerationStatus.NoVisibleEvidence,
        memory: null,
        errorKind: WorldCharacterMemoryGenerationErrorKind.MemoryPersistenceFailed
      };
    }
  }

  async generateForSession(
    worldId: string,
    sceneId: string,
    sessionId: string
  ): Promise<WorldCharacterMemoryBatchGenerationResult> {
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new WorldCharacterMemoryGenerationError(
        WorldCharacterMemoryGenerationErrorKind.NoModelConfiguration,
        'no model configuration for batch generation'
      );
    }
    const session: WorldConversationSession | null =
      await this.sessionRepo.getById(sessionId);
    if (session === null) {
      throw new WorldCharacterMemoryGenerationError(
        WorldCharacterMemoryGenerationErrorKind.SourcePreparationFailed,
        'session not found'
      );
    }
    const participants: WorldSessionParticipantSnapshot[] =
      session.participantSnapshotJson !== ''
        ? deserializeParticipantSnapshots(session.participantSnapshotJson)
        : [];
    const results: OwnerMemoryGenerationResult[] = [];
    for (let i = 0; i < participants.length; i++) {
      const participant: WorldSessionParticipantSnapshot = participants[i];
      const ownerResult: WorldCharacterMemoryGenerationResult =
        await this.generateForOwner({
          worldId: worldId,
          sceneId: sceneId,
          sessionId: sessionId,
          ownerCharacterInstanceId: participant.characterInstanceId
        });
      results.push({
        ownerCharacterInstanceId: participant.characterInstanceId,
        status: ownerResult.status,
        memory: ownerResult.memory,
        errorKind: ownerResult.errorKind
      });
    }
    return {
      worldId: worldId,
      sceneId: sceneId,
      sessionId: sessionId,
      results: results
    };
  }

  private executeModelRequest(
    config: ProviderConfig,
    promptResult: WorldCharacterMemoryPromptResult
  ): Promise<string> {
    return new Promise<string>((resolve: (text: string) => void, reject: (error: WorldCharacterMemoryGenerationError) => void): void => {
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
          reject(new WorldCharacterMemoryGenerationError(
            WorldCharacterMemoryGenerationErrorKind.ModelRequestFailed,
            'model request failed',
            error
          ));
        }
      };

      this.modelService.streamChatWithConfig(config, promptResult.messages, promptResult.options, callbacks);
    });
  }

  private parseMemoryJson(raw: string): ParsedMemoryOutput {
    let parsed: Object;
    try {
      parsed = JSON.parse(raw);
    } catch (_e) {
      return { memoryText: '', confidence: 0, confidenceValid: false };
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return { memoryText: '', confidence: 0, confidenceValid: false };
    }
    const record: Record<string, Object> = parsed as Record<string, Object>;
    const memoryTextObj: Object | undefined = record['memoryText'];
    if (typeof memoryTextObj !== 'string') {
      return { memoryText: '', confidence: 0, confidenceValid: false };
    }
    const memoryText: string = (memoryTextObj as string).trim();
    if (memoryText === '') {
      return { memoryText: '', confidence: 0, confidenceValid: false };
    }
    const confidenceObj: Object | undefined = record['confidence'];
    if (typeof confidenceObj !== 'number') {
      return { memoryText: memoryText, confidence: 0, confidenceValid: false };
    }
    const confidence: number = confidenceObj as number;
    if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
      return { memoryText: memoryText, confidence: confidence, confidenceValid: false };
    }
    return { memoryText: memoryText, confidence: confidence, confidenceValid: true };
  }
}

interface ParsedMemoryOutput {
  readonly memoryText: string;
  readonly confidence: number;
  readonly confidenceValid: boolean;
}
