import {
  WorldSessionSummary,
  WorldSessionSummarySourceSnapshot
} from '../../models/world/WorldSessionSummary';
import {
  WorldSessionSummaryStoreService
} from './WorldSessionSummaryStoreService';
import {
  WorldSessionSummaryPromptAssembler,
  WorldSessionSummaryPromptResult,
  WorldSessionSummaryMetadata,
  WORLD_SESSION_SUMMARY_PROMPT_VERSION
} from './WorldSessionSummaryPromptAssembler';
import { ModelService } from '../ModelService';
import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatMessage } from '../../models/ChatMessage';
import { ChatRequestOptions } from '../../models/ChatRequest';
import {
  ChatStreamCallbacks,
  ChatStreamResult
} from '../../models/ChatStreamTypes';
import { NetworkError } from '../../models/NetworkError';
import { WorldStateError, WorldStateErrorKind } from '../../models/world/WorldStateError';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSummaryGen';

export enum WorldSessionSummaryGenerationStatus {
  Generated = 'generated',
  Existing = 'existing',
  NoPublicContent = 'no_public_content'
}

export interface WorldSessionSummaryGenerationResult {
  readonly status: WorldSessionSummaryGenerationStatus;
  readonly summary: WorldSessionSummary | null;
}

export enum WorldSessionSummaryGenerationErrorKind {
  SourcePreparationFailed = 'source_preparation_failed',
  NoModelConfiguration = 'no_model_configuration',
  ModelRequestFailed = 'model_request_failed',
  ModelCancelled = 'model_cancelled',
  EmptyModelOutput = 'empty_model_output',
  ModelOutputTooLarge = 'model_output_too_large',
  SourceChanged = 'source_changed',
  SummaryPersistenceFailed = 'summary_persistence_failed',
  MetadataNotFound = 'metadata_not_found',
  Internal = 'internal'
}

export class WorldSessionSummaryGenerationError extends Error {
  readonly kind: WorldSessionSummaryGenerationErrorKind;
  readonly cause: Object | null;

  constructor(kind: WorldSessionSummaryGenerationErrorKind, message: string, cause: Object | null = null) {
    super(message);
    this.name = 'WorldSessionSummaryGenerationError';
    this.kind = kind;
    this.cause = cause;
  }
}

export class WorldSessionSummaryGenerationService {
  private readonly storeService: WorldSessionSummaryStoreService;
  private readonly promptAssembler: WorldSessionSummaryPromptAssembler;
  private readonly modelService: ModelService;

  constructor(
    storeService: WorldSessionSummaryStoreService,
    promptAssembler: WorldSessionSummaryPromptAssembler,
    modelService: ModelService
  ) {
    this.storeService = storeService;
    this.promptAssembler = promptAssembler;
    this.modelService = modelService;
  }

  async generateSummary(
    sessionId: string,
    forceNewVersion: boolean = false
  ): Promise<WorldSessionSummaryGenerationResult> {
    const startTime: number = Date.now();
    Logger.info(LOG_TAG, 'generateSummary start sessionId=' + sessionId.slice(0, 16)
      + ' forceNew=' + String(forceNewVersion));

    let snapshot: WorldSessionSummarySourceSnapshot;
    try {
      snapshot = await this.storeService.prepareSourceSnapshot(sessionId);
    } catch (e) {
      Logger.error(LOG_TAG, 'prepareSourceSnapshot failed: ' + (e as Error).message);
      throw new WorldSessionSummaryGenerationError(
        WorldSessionSummaryGenerationErrorKind.SourcePreparationFailed,
        'Source preparation failed',
        e as Error
      );
    }

    if (snapshot.sourceMessageCount === 0) {
      Logger.info(LOG_TAG, 'No public source messages, skipping model request');
      return {
        status: WorldSessionSummaryGenerationStatus.NoPublicContent,
        summary: null
      };
    }

    const sourceMessageIdsJson: string = JSON.stringify(snapshot.sourceMessageIds);

    if (!forceNewVersion) {
      const latest: WorldSessionSummary | null =
        await this.storeService.getLatestSummary(sessionId);
      if (latest !== null &&
        latest.promptVersion === WORLD_SESSION_SUMMARY_PROMPT_VERSION &&
        latest.sourceMessageIdsJson === sourceMessageIdsJson) {
        Logger.info(LOG_TAG, 'Existing summary matches source+promptVersion, returning existing');
        return {
          status: WorldSessionSummaryGenerationStatus.Existing,
          summary: latest
        };
      }
    }

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new WorldSessionSummaryGenerationError(
        WorldSessionSummaryGenerationErrorKind.NoModelConfiguration,
        'No model configuration available'
      );
    }
    const configSnapshot: ProviderConfig = config;
    const providerId: string = configSnapshot.id;
    const modelId: string = configSnapshot.modelName;

    const metadata: WorldSessionSummaryMetadata | null =
      await this.promptAssembler.loadMetadata(snapshot);
    if (metadata === null) {
      throw new WorldSessionSummaryGenerationError(
        WorldSessionSummaryGenerationErrorKind.MetadataNotFound,
        'Failed to load world/location/scene metadata'
      );
    }

    const promptResult: WorldSessionSummaryPromptResult =
      this.promptAssembler.assemble(snapshot, metadata);

    Logger.info(LOG_TAG, 'Sending model request provider=' + providerId.slice(0, 8)
      + ' model=' + modelId.slice(0, 16)
      + ' sourceMsgCount=' + String(snapshot.sourceMessageCount));

    const summaryText: string = await this.executeModelRequest(
      configSnapshot, promptResult.messages, promptResult.options
    );

    const validatedText: string = this.promptAssembler.validateOutput(summaryText);
    if (validatedText.length === 0) {
      Logger.error(LOG_TAG, 'Model output validation failed (empty or too large)');
      throw new WorldSessionSummaryGenerationError(
        WorldSessionSummaryGenerationErrorKind.EmptyModelOutput,
        'Model output is empty or too large after validation'
      );
    }

    try {
      const persisted: WorldSessionSummary =
        await this.storeService.persistCompletedSummary(
          sessionId,
          validatedText,
          WORLD_SESSION_SUMMARY_PROMPT_VERSION,
          forceNewVersion,
          providerId,
          modelId
        );
      const duration: number = Date.now() - startTime;
      Logger.info(LOG_TAG, 'Summary generated version=' + String(persisted.version)
        + ' duration=' + String(duration) + 'ms');
      return {
        status: WorldSessionSummaryGenerationStatus.Generated,
        summary: persisted
      };
    } catch (e) {
      const caughtError: Object = e as Object;
      if (e instanceof WorldStateError && e.kind === WorldStateErrorKind.SummarySourceChanged) {
        Logger.warn(LOG_TAG, 'Source changed during generation, refusing to persist');
        throw new WorldSessionSummaryGenerationError(
          WorldSessionSummaryGenerationErrorKind.SourceChanged,
          'Source data changed during generation',
          caughtError
        );
      }
      Logger.error(LOG_TAG, 'persistCompletedSummary failed: ' + (e as Error).message);
      throw new WorldSessionSummaryGenerationError(
        WorldSessionSummaryGenerationErrorKind.SummaryPersistenceFailed,
        'Failed to persist summary',
        caughtError
      );
    }
  }

  async regenerateSummary(sessionId: string): Promise<WorldSessionSummaryGenerationResult> {
    return await this.generateSummary(sessionId, true);
  }

  private executeModelRequest(
    config: ProviderConfig,
    messages: ChatMessage[],
    options: ChatRequestOptions
  ): Promise<string> {
    return new Promise<string>((resolve: (text: string) => void, reject: (error: WorldSessionSummaryGenerationError) => void): void => {
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
          reject(new WorldSessionSummaryGenerationError(
            WorldSessionSummaryGenerationErrorKind.ModelRequestFailed,
            'Model request failed: ' + error.message,
            error
          ));
        }
      };

      this.modelService.streamChatWithConfig(config, messages, options, callbacks);
    });
  }
}
