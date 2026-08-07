import { ChatStreamHandle } from '../../models/ChatStreamTypes';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldRuntimeReg';

export interface RegistryEntry {
  sessionId: string;
  operationId: number;
  generationBatchId: string;
  startedAt: number;
  handle: ChatStreamHandle | null;
}

export class WorldRuntimeRegistry {
  private readonly entries: Map<string, RegistryEntry> = new Map();
  private operationIdCounter: number = 0;

  tryAcquire(sessionId: string, generationBatchId: string): RegistryEntry | null {
    const existing: RegistryEntry | undefined = this.entries.get(sessionId);
    if (existing !== undefined) {
      Logger.warn(LOG_TAG, 'tryAcquire rejected: sessionId=' + this.shortId(sessionId)
        + ' existing op=' + existing.operationId.toString());
      return null;
    }

    const operationId: number = ++this.operationIdCounter;
    const entry: RegistryEntry = {
      sessionId: sessionId,
      operationId: operationId,
      generationBatchId: generationBatchId,
      startedAt: Date.now(),
      handle: null
    };
    this.entries.set(sessionId, entry);

    Logger.info(LOG_TAG, 'tryAcquire ok: sessionId=' + this.shortId(sessionId)
      + ' op=' + operationId.toString()
      + ' batch=' + this.shortId(generationBatchId));

    return entry;
  }

  isCurrent(sessionId: string, operationId: number): boolean {
    const entry: RegistryEntry | undefined = this.entries.get(sessionId);
    if (entry === undefined) {
      return false;
    }
    return entry.operationId === operationId;
  }

  attachHandle(sessionId: string, operationId: number, handle: ChatStreamHandle): boolean {
    const entry: RegistryEntry | undefined = this.entries.get(sessionId);
    if (entry === undefined || entry.operationId !== operationId) {
      return false;
    }
    entry.handle = handle;
    return true;
  }

  release(sessionId: string, operationId: number): void {
    const entry: RegistryEntry | undefined = this.entries.get(sessionId);
    if (entry === undefined) {
      return;
    }
    if (entry.operationId !== operationId) {
      Logger.warn(LOG_TAG, 'release rejected: sessionId=' + this.shortId(sessionId)
        + ' expected op=' + entry.operationId.toString()
        + ' got op=' + operationId.toString());
      return;
    }
    this.entries.delete(sessionId);
    Logger.info(LOG_TAG, 'release ok: sessionId=' + this.shortId(sessionId)
      + ' op=' + operationId.toString());
  }

  forceRelease(sessionId: string): void {
    this.entries.delete(sessionId);
    Logger.info(LOG_TAG, 'forceRelease: sessionId=' + this.shortId(sessionId));
  }

  stop(sessionId: string): boolean {
    const entry: RegistryEntry | undefined = this.entries.get(sessionId);
    if (entry === undefined) {
      Logger.warn(LOG_TAG, 'stop: no entry for sessionId=' + this.shortId(sessionId));
      return false;
    }

    if (entry.handle !== null) {
      entry.handle.abort();
      Logger.info(LOG_TAG, 'stop: abort sent for sessionId=' + this.shortId(sessionId)
        + ' op=' + entry.operationId.toString());
    }

    this.entries.delete(sessionId);
    Logger.info(LOG_TAG, 'stop: released sessionId=' + this.shortId(sessionId));

    return true;
  }

  getEntry(sessionId: string): RegistryEntry | null {
    const entry: RegistryEntry | undefined = this.entries.get(sessionId);
    return entry !== undefined ? entry : null;
  }

  isBusy(sessionId: string): boolean {
    return this.entries.has(sessionId);
  }

  getOperationId(sessionId: string): number {
    const entry: RegistryEntry | undefined = this.entries.get(sessionId);
    return entry !== undefined ? entry.operationId : -1;
  }

  private shortId(id: string): string {
    return id.length > 8 ? id.substring(0, 8) : id;
  }
}
