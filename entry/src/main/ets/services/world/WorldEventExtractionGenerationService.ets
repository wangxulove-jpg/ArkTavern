import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatStreamCallbacks, ChatStreamResult } from '../../models/ChatStreamTypes';
import { NetworkError } from '../../models/NetworkError';
import { ModelService } from '../ModelService';
import {
  WorldEventSourceSnapshot,
  WorldEventEntryDraft,
  WorldEventExtractionRun,
  WorldEventEntry,
  WorldEventExtractionResult,
  WorldEventKind,
  isWorldEventKind
} from '../../models/world/WorldEventExtraction';
import { WorldEventStoreService } from './WorldEventStoreService';
import {
  WorldEventExtractionPromptAssembler,
  WorldEventExtractionMetadata,
  WorldEventExtractionPromptResult,
  WORLD_EVENT_EXTRACTION_PROMPT_VERSION,
  MAX_EVENTS_PER_EXTRACTION,
  MAX_EVENT_TEXT_LENGTH
} from './WorldEventExtractionPromptAssembler';
import { WorldStateError, WorldStateErrorKind } from '../../models/world/WorldStateError';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldEventExtractionGen';

export enum WorldEventExtractionGenerationErrorKind {
  SourcePreparationFailed = 'source_preparation_failed',
  NoSharedSummary = 'no_shared_summary',
  NoModelConfiguration = 'no_model_configuration',
  ModelRequestFailed = 'model_request_failed',
  ModelCancelled = 'model_cancelled',
  InvalidModelOutput = 'invalid_model_output',
  TooManyEvents = 'too_many_events',
  EventTextTooLarge = 'event_text_too_large',
  InvalidEventKind = 'invalid_event_kind',
  InvalidActor = 'invalid_actor',
  InvalidEvidence = 'invalid_evidence',
  InvalidConfidence = 'invalid_confidence',
  SourceChanged = 'source_changed',
  PersistenceFailed = 'persistence_failed',
  MetadataNotFound = 'metadata_not_found'
}

export class WorldEventExtractionGenerationError extends Error {
  readonly kind: WorldEventExtractionGenerationErrorKind;
  readonly cause: Object | null;

  constructor(kind: WorldEventExtractionGenerationErrorKind, message: string, cause: Object | null = null) {
    super(message);
    this.name = 'WorldEventExtractionGenerationError';
    this.kind = kind;
    this.cause = cause;
  }
}

export interface WorldEventExtractionGenerationOptions {
  readonly worldId: string;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly forceNewVersion?: boolean;
}

export enum WorldEventExtractionGenerationStatus {
  Generated = 'generated',
  Existing = 'existing'
}

export interface WorldEventExtractionGenerationResult {
  readonly status: WorldEventExtractionGenerationStatus;
  readonly run: WorldEventExtractionRun;
  readonly entries: WorldEventEntry[];
  readonly errorKind: WorldEventExtractionGenerationErrorKind | null;
}

export class WorldEventExtractionGenerationService {
  private readonly storeService: WorldEventStoreService;
  private readonly promptAssembler: WorldEventExtractionPromptAssembler;
  private readonly modelService: ModelService;

  constructor(
    storeService: WorldEventStoreService,
    promptAssembler: WorldEventExtractionPromptAssembler,
    modelService: ModelService
  ) {
    this.storeService = storeService;
    this.promptAssembler = promptAssembler;
    this.modelService = modelService;
  }

  async generate(
    options: WorldEventExtractionGenerationOptions
  ): Promise<WorldEventExtractionGenerationResult> {
    const startTime: number = Date.now();
    const sessionId: string = options.sessionId;
    const forceNewVersion: boolean = options.forceNewVersion === true;

    Logger.info(LOG_TAG, 'generate start session=' + sessionId.substring(0, 8)
      + ' forceNew=' + String(forceNewVersion));

    let snapshot: WorldEventSourceSnapshot;
    try {
      snapshot = await this.storeService.prepareSourceSnapshot(
        options.worldId, options.sceneId, sessionId
      );
    } catch (e) {
      const err: Object = e as Object;
      if (e instanceof WorldStateError) {
        if (e.kind === WorldStateErrorKind.SessionNotEnded) {
          Logger.info(LOG_TAG, 'Session not ended');
          throw new WorldEventExtractionGenerationError(
            WorldEventExtractionGenerationErrorKind.SourcePreparationFailed,
            'Session not ended',
            err
          );
        }
        const msg: string = (e as Error).message;
        if (msg === 'NoSharedSummary') {
          Logger.info(LOG_TAG, 'NoSharedSummary');
          throw new WorldEventExtractionGenerationError(
            WorldEventExtractionGenerationErrorKind.NoSharedSummary,
            'No SharedPublic summary available',
            err
          );
        }
      }
      Logger.error(LOG_TAG, 'prepareSourceSnapshot failed: ' + (e as Error).message);
      throw new WorldEventExtractionGenerationError(
        WorldEventExtractionGenerationErrorKind.SourcePreparationFailed,
        'Source preparation failed',
        err
      );
    }

    const sourceMessageIdsJson: string = JSON.stringify(snapshot.sourceMessageIds);

    if (!forceNewVersion) {
      const activeInfo = await this.storeService.getActiveExtractionForSession(
        options.worldId, sessionId
      );
      if (activeInfo !== null && activeInfo.isSourceCurrent) {
        const run: WorldEventExtractionRun = activeInfo.run;
        if (run.sourceSummaryId === snapshot.summaryId &&
          run.sourceSummaryVersion === snapshot.summaryVersion &&
          run.sourceMessageIdsJson === sourceMessageIdsJson &&
          run.promptVersion === WORLD_EVENT_EXTRACTION_PROMPT_VERSION) {
          Logger.info(LOG_TAG, 'Existing extraction matches source+promptVersion, returning existing');
          return {
            status: WorldEventExtractionGenerationStatus.Existing,
            run: run,
            entries: activeInfo.entries,
            errorKind: null
          };
        }
      }
    }

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new WorldEventExtractionGenerationError(
        WorldEventExtractionGenerationErrorKind.NoModelConfiguration,
        'No model configuration available'
      );
    }
    const configSnapshot: ProviderConfig = config;
    const providerId: string = configSnapshot.id;
    const modelId: string = configSnapshot.modelName;

    const metadata: WorldEventExtractionMetadata | null =
      await this.promptAssembler.loadMetadata(snapshot);
    if (metadata === null) {
      throw new WorldEventExtractionGenerationError(
        WorldEventExtractionGenerationErrorKind.MetadataNotFound,
        'Failed to load world/location/scene metadata'
      );
    }

    const promptResult: WorldEventExtractionPromptResult =
      this.promptAssembler.assemble(snapshot, metadata);

    Logger.info(LOG_TAG, 'Sending model request provider=' + providerId.substring(0, 8)
      + ' model=' + modelId.substring(0, 16)
      + ' sourceMsgCount=' + String(snapshot.sourceMessageIds.length));

    let rawOutput: string;
    try {
      rawOutput = await this.executeModelRequest(configSnapshot, promptResult);
    } catch (err) {
      if (err instanceof WorldEventExtractionGenerationError) {
        Logger.info(LOG_TAG, 'ModelFailed kind=' + err.kind);
        throw err;
      }
      throw new WorldEventExtractionGenerationError(
        WorldEventExtractionGenerationErrorKind.ModelRequestFailed,
        'Model request failed',
        err as Object
      );
    }

    const cleanedOutput: string = this.promptAssembler.validateOutput(rawOutput);
    if (cleanedOutput === '') {
      Logger.error(LOG_TAG, 'Model output validation failed (empty or too large)');
      throw new WorldEventExtractionGenerationError(
        WorldEventExtractionGenerationErrorKind.InvalidModelOutput,
        'Model output is empty or too large after validation'
      );
    }

    const parsed: ParsedEventOutput = this.parseEventJson(cleanedOutput, snapshot);
    if (parsed.errorKind !== null) {
      Logger.error(LOG_TAG, 'Parse/validation failed kind=' + parsed.errorKind);
      throw new WorldEventExtractionGenerationError(
        parsed.errorKind,
        'Model output validation failed',
        null
      );
    }

    Logger.info(LOG_TAG, 'Parsed events count=' + String(parsed.drafts.length));

    try {
      const result: WorldEventExtractionResult =
        await this.storeService.persistCompletedExtraction(
          snapshot,
          parsed.drafts,
          WORLD_EVENT_EXTRACTION_PROMPT_VERSION,
          forceNewVersion,
          providerId,
          modelId
        );
      const duration: number = Date.now() - startTime;
      Logger.info(LOG_TAG, 'Generated version=' + String(result.run.version)
        + ' events=' + String(result.entries.length)
        + ' isExisting=' + String(result.isExisting)
        + ' duration=' + String(duration) + 'ms');
      return {
        status: result.isExisting
          ? WorldEventExtractionGenerationStatus.Existing
          : WorldEventExtractionGenerationStatus.Generated,
        run: result.run,
        entries: result.entries,
        errorKind: null
      };
    } catch (e) {
      const caughtError: Object = e as Object;
      if (e instanceof WorldStateError && e.kind === WorldStateErrorKind.SummarySourceChanged) {
        Logger.warn(LOG_TAG, 'Source changed during generation, refusing to persist');
        throw new WorldEventExtractionGenerationError(
          WorldEventExtractionGenerationErrorKind.SourceChanged,
          'Source data changed during generation',
          caughtError
        );
      }
      Logger.error(LOG_TAG, 'persistCompletedExtraction failed: ' + (e as Error).message);
      throw new WorldEventExtractionGenerationError(
        WorldEventExtractionGenerationErrorKind.PersistenceFailed,
        'Failed to persist extraction',
        caughtError
      );
    }
  }

  async regenerate(
    options: WorldEventExtractionGenerationOptions
  ): Promise<WorldEventExtractionGenerationResult> {
    const forceOptions: WorldEventExtractionGenerationOptions = {
      worldId: options.worldId,
      sceneId: options.sceneId,
      sessionId: options.sessionId,
      forceNewVersion: true
    };
    return await this.generate(forceOptions);
  }

  private executeModelRequest(
    config: ProviderConfig,
    promptResult: WorldEventExtractionPromptResult
  ): Promise<string> {
    return new Promise<string>((resolve: (text: string) => void, reject: (error: WorldEventExtractionGenerationError) => void): void => {
      let accumulated: string = '';
      let terminalFired: boolean = false;

      const callbacks: ChatStreamCallbacks = {
        onDelta: (delta): void => {
          if (terminalFired) {
            return;
          }
          accumulated += delta.content;
        },
        onComplete: (result: ChatStreamResult): void => {
          if (terminalFired) {
            return;
          }
          terminalFired = true;
          const finalText: string = result.content.length > 0 ? result.content : accumulated;
          resolve(finalText);
        },
        onError: (error: NetworkError): void => {
          if (terminalFired) {
            return;
          }
          terminalFired = true;
          reject(new WorldEventExtractionGenerationError(
            WorldEventExtractionGenerationErrorKind.ModelRequestFailed,
            'Model request failed: ' + error.message,
            error
          ));
        }
      };

      this.modelService.streamChatWithConfig(config, promptResult.messages, promptResult.options, callbacks);
    });
  }

  private parseEventJson(
    raw: string,
    snapshot: WorldEventSourceSnapshot
  ): ParsedEventOutput {
    let parsed: Object;
    try {
      parsed = JSON.parse(raw);
    } catch (_e) {
      return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
    }
    const root: Record<string, Object> = parsed as Record<string, Object>;
    const eventsObj: Object | undefined = root['events'];
    if (eventsObj === undefined || !Array.isArray(eventsObj)) {
      return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
    }
    const eventsArr: Object[] = eventsObj as Object[];
    if (eventsArr.length === 0) {
      return { drafts: [], errorKind: null };
    }
    if (eventsArr.length > MAX_EVENTS_PER_EXTRACTION) {
      return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.TooManyEvents };
    }

    const sourceIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < snapshot.sourceMessageIds.length; i++) {
      sourceIdSet.add(snapshot.sourceMessageIds[i]);
    }
    const participantIdSet: Set<string> = new Set<string>();
    for (let i = 0; i < snapshot.participantCharacterInstanceIds.length; i++) {
      participantIdSet.add(snapshot.participantCharacterInstanceIds[i]);
    }

    const drafts: WorldEventEntryDraft[] = [];
    for (let i = 0; i < eventsArr.length; i++) {
      const item: Object = eventsArr[i];
      if (typeof item !== 'object' || item === null || Array.isArray(item)) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
      }
      const event: Record<string, Object> = item as Record<string, Object>;

      const kindObj: Object | undefined = event['kind'];
      if (typeof kindObj !== 'string') {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEventKind };
      }
      const kind: string = kindObj as string;
      if (!isWorldEventKind(kind)) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEventKind };
      }

      const textObj: Object | undefined = event['text'];
      if (typeof textObj !== 'string') {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
      }
      const text: string = (textObj as string).trim();
      if (text === '') {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
      }
      if (text.length > MAX_EVENT_TEXT_LENGTH) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.EventTextTooLarge };
      }

      const actorObj: Object | undefined = event['actorCharacterInstanceIds'];
      if (actorObj === undefined || !Array.isArray(actorObj)) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidActor };
      }
      const actorArr: Object[] = actorObj as Object[];
      const actorIds: string[] = [];
      for (let j = 0; j < actorArr.length; j++) {
        if (typeof actorArr[j] !== 'string') {
          return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidActor };
        }
        const aid: string = actorArr[j] as string;
        if (aid === '') {
          continue;
        }
        if (!participantIdSet.has(aid)) {
          return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidActor };
        }
        actorIds.push(aid);
      }

      const playerInvolvedObj: Object | undefined = event['playerInvolved'];
      if (typeof playerInvolvedObj !== 'boolean') {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidModelOutput };
      }
      const playerInvolved: boolean = playerInvolvedObj as boolean;

      const evidenceObj: Object | undefined = event['evidenceMessageIds'];
      if (evidenceObj === undefined || !Array.isArray(evidenceObj)) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEvidence };
      }
      const evidenceArr: Object[] = evidenceObj as Object[];
      if (evidenceArr.length === 0) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEvidence };
      }
      const evidenceIds: string[] = [];
      for (let j = 0; j < evidenceArr.length; j++) {
        if (typeof evidenceArr[j] !== 'string') {
          return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEvidence };
        }
        const eid: string = evidenceArr[j] as string;
        if (eid === '') {
          continue;
        }
        if (!sourceIdSet.has(eid)) {
          return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEvidence };
        }
        evidenceIds.push(eid);
      }
      if (evidenceIds.length === 0) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidEvidence };
      }

      const confidenceObj: Object | undefined = event['confidence'];
      if (typeof confidenceObj !== 'number') {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidConfidence };
      }
      const confidence: number = confidenceObj as number;
      if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
        return { drafts: [], errorKind: WorldEventExtractionGenerationErrorKind.InvalidConfidence };
      }

      const dedupedActorIds: string[] = stableDedup(actorIds);
      const dedupedEvidenceIds: string[] = stableDedup(evidenceIds);

      drafts.push({
        eventKind: kind as WorldEventKind,
        eventText: text,
        actorCharacterInstanceIds: dedupedActorIds,
        playerInvolved: playerInvolved,
        evidenceMessageIds: dedupedEvidenceIds,
        confidence: confidence
      });
    }

    return { drafts: drafts, errorKind: null };
  }
}

interface ParsedEventOutput {
  readonly drafts: WorldEventEntryDraft[];
  readonly errorKind: WorldEventExtractionGenerationErrorKind | null;
}

function stableDedup(ids: string[]): string[] {
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    const id: string = ids[i];
    if (!seen.has(id)) {
      seen.add(id);
      result.push(id);
    }
  }
  result.sort();
  return result;
}
