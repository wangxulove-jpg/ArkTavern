/**
 * GroupPromptInspectionStore 群聊 Prompt 诊断快照存储(G-CONTEXT-INSPECTOR-1 / G-CONTEXT-PERSIST-1)
 *
 * 职责:
 * - 持有最近一次 Prompt 诊断快照(每角色每群聊只保留最近一次)
 * - 内存 + AppPreferences 双重存储:store() 时自动持久化,restore() 时从本地恢复
 * - 不记录 API Key / Authorization / 敏感信息
 *
 * 存储键: groupConversationId + speakerCharacterId
 * 持久化: 单个 Preferences key 存 JSON 数组,限制最大快照数量(超出丢弃最旧)
 * 生命周期: 应用进程内常驻;退出应用后从 Preferences 恢复
 *
 * 线程安全:
 * - ArkTS 单线程模型,无需同步
 * - Map 操作均为同步
 */

import { AppPreferences } from '../../storage/AppPreferences';
import { Logger } from '../../utils/Logger';
import {
  GroupPromptInspectionSnapshot,
  MemoryInspectionItem,
  RelationshipInspectionItem,
  PromptMessageInspectionItem,
  TokenBudgetInspection,
  LorebookInspection
} from '../../models/groupchat/GroupPromptInspectionModels';

const LOG_TAG: string = 'GroupPromptInspectionStore';

/** Preferences 存储 key */
const PERSIST_KEY: string = 'group_prompt_inspection_snapshots_v1';
/** 最大持久化快照数量(超出丢弃最旧) */
const MAX_PERSISTED_SNAPSHOTS: number = 50;

/** 持久化用精简结构(与快照一致,便于 JSON 往返) */
interface PersistedInspectionSnapshot {
  readonly snapshotId: string;
  readonly groupConversationId: string;
  readonly speakerCharacterId: string;
  readonly speakerCharacterName: string;
  readonly roundId: string;
  readonly capturedAt: number;
  readonly totalMemoriesStored: number;
  readonly totalMemoriesActive: number;
  readonly totalMemoriesSelected: number;
  readonly totalMemoriesInjected: number;
  readonly totalRelationshipsStored: number;
  readonly totalRelationshipsActive: number;
  readonly totalRelationshipsSelected: number;
  readonly totalRelationshipsInjected: number;
  readonly reverseRelationships: PersistedReverseRelationship[];
  readonly tokenBudget: PersistedTokenBudget;
  readonly lorebookMatchedEntryCount: number;
  readonly promptMessages: PersistedPromptMessage[];
  readonly presetSystemPromptPreview: string;
  readonly groupConstraintPreview: string;
  readonly replyTargetMode: string;
  readonly participantNames: string[];
}

interface PersistedReverseRelationship {
  readonly id: string;
  readonly ownerCharacterName: string;
  readonly targetName: string;
}

interface PersistedTokenBudget {
  readonly contextWindow: number;
  readonly availableInputTokens: number;
  readonly estimatedTotalTokens: number;
  readonly usagePercent: number;
  readonly totalMessagesBeforeTrim: number;
  readonly totalMessagesAfterTrim: number;
  readonly trimmedMessageCount: number;
}

interface PersistedPromptMessage {
  readonly role: string;
  readonly contentPreview: string;
  readonly category: string;
  readonly estimatedTokens: number;
}

export class GroupPromptInspectionStore {
  private readonly snapshots: Map<string, GroupPromptInspectionSnapshot> =
    new Map<string, GroupPromptInspectionSnapshot>();
  private readonly prefs: AppPreferences | null;

  constructor(prefs: AppPreferences | null = null) {
    this.prefs = prefs;
  }

  private buildKey(groupConversationId: string, speakerCharacterId: string): string {
    return groupConversationId + ':' + speakerCharacterId;
  }

  /**
   * 保存快照并持久化。
   * 无 AppPreferences 时仅写内存(降级模式)。
   */
  async store(snapshot: GroupPromptInspectionSnapshot): Promise<void> {
    const key: string = this.buildKey(
      snapshot.groupConversationId,
      snapshot.speakerCharacterId
    );
    this.snapshots.set(key, snapshot);
    if (this.prefs === null) {
      return;
    }
    try {
      const list: PersistedInspectionSnapshot[] = await this.loadPersistedList();
      const next: PersistedInspectionSnapshot[] = [];
      for (let i = 0; i < list.length; i++) {
        const item: PersistedInspectionSnapshot = list[i];
        const itemKey: string = this.buildKey(
          item.groupConversationId,
          item.speakerCharacterId
        );
        if (itemKey !== key) {
          next.push(item);
        }
      }
      next.push(toPersisted(snapshot));
      // 限制数量,保留最新
      while (next.length > MAX_PERSISTED_SNAPSHOTS) {
        next.shift();
      }
      await this.savePersistedList(next);
    } catch (e) {
      Logger.warn(LOG_TAG, 'store persist failed: ' + String(e));
    }
  }

  get(
    groupConversationId: string,
    speakerCharacterId: string
  ): GroupPromptInspectionSnapshot | undefined {
    const key: string = this.buildKey(groupConversationId, speakerCharacterId);
    return this.snapshots.get(key);
  }

  has(groupConversationId: string, speakerCharacterId: string): boolean {
    const key: string = this.buildKey(groupConversationId, speakerCharacterId);
    return this.snapshots.has(key);
  }

  async remove(groupConversationId: string, speakerCharacterId: string): Promise<void> {
    const key: string = this.buildKey(groupConversationId, speakerCharacterId);
    this.snapshots.delete(key);
    if (this.prefs === null) {
      return;
    }
    try {
      const list: PersistedInspectionSnapshot[] = await this.loadPersistedList();
      const next: PersistedInspectionSnapshot[] = [];
      for (let i = 0; i < list.length; i++) {
        const item: PersistedInspectionSnapshot = list[i];
        const itemKey: string = this.buildKey(
          item.groupConversationId,
          item.speakerCharacterId
        );
        if (itemKey !== key) {
          next.push(item);
        }
      }
      await this.savePersistedList(next);
    } catch (e) {
      Logger.warn(LOG_TAG, 'remove persist failed: ' + String(e));
    }
  }

  async clear(): Promise<void> {
    this.snapshots.clear();
    if (this.prefs === null) {
      return;
    }
    try {
      await this.prefs.putString(PERSIST_KEY, '[]');
    } catch (e) {
      Logger.warn(LOG_TAG, 'clear persist failed: ' + String(e));
    }
  }

  /**
   * 从 AppPreferences 恢复全部快照到内存。
   * 在应用初始化时调用一次。
   */
  async restore(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    try {
      const list: PersistedInspectionSnapshot[] = await this.loadPersistedList();
      let restoredCount: number = 0;
      for (let i = 0; i < list.length; i++) {
        const snapshot: GroupPromptInspectionSnapshot | undefined =
          fromPersisted(list[i]);
        if (snapshot === undefined) {
          continue;
        }
        const key: string = this.buildKey(
          snapshot.groupConversationId,
          snapshot.speakerCharacterId
        );
        this.snapshots.set(key, snapshot);
        restoredCount++;
      }
      Logger.info(LOG_TAG, 'restore ok: count=' + String(restoredCount));
    } catch (e) {
      Logger.warn(LOG_TAG, 'restore failed: ' + String(e));
    }
  }

  // ===== 持久化辅助 =====

  private async loadPersistedList(): Promise<PersistedInspectionSnapshot[]> {
    if (this.prefs === null) {
      return [];
    }
    const json: string = await this.prefs.getString(PERSIST_KEY, '');
    if (json.length === 0) {
      return [];
    }
    const parsed: Object = JSON.parse(json);
    if (typeof parsed !== 'object' || parsed === null) {
      return [];
    }
    const arr: Object[] = parsed as Object[];
    const result: PersistedInspectionSnapshot[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      const parsedItem: PersistedInspectionSnapshot | undefined =
        parsePersistedItem(item);
      if (parsedItem !== undefined) {
        result.push(parsedItem);
      }
    }
    return result;
  }

  private async savePersistedList(list: PersistedInspectionSnapshot[]): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const json: string = JSON.stringify(list);
    await this.prefs.putString(PERSIST_KEY, json);
  }
}

// ===== 序列化辅助 =====

function toPersisted(snapshot: GroupPromptInspectionSnapshot): PersistedInspectionSnapshot {
  const reverseRels: PersistedReverseRelationship[] = [];
  for (let i = 0; i < snapshot.reverseRelationships.length; i++) {
    const r: RelationshipInspectionItem = snapshot.reverseRelationships[i];
    reverseRels.push({
      id: r.id,
      ownerCharacterName: r.ownerCharacterName,
      targetName: r.targetName
    });
  }
  const promptMsgs: PersistedPromptMessage[] = [];
  for (let i = 0; i < snapshot.promptMessages.length; i++) {
    const m: PromptMessageInspectionItem = snapshot.promptMessages[i];
    promptMsgs.push({
      role: m.role,
      contentPreview: m.contentPreview,
      category: m.category,
      estimatedTokens: m.estimatedTokens
    });
  }
  const result: PersistedInspectionSnapshot = {
    snapshotId: snapshot.snapshotId,
    groupConversationId: snapshot.groupConversationId,
    speakerCharacterId: snapshot.speakerCharacterId,
    speakerCharacterName: snapshot.speakerCharacterName,
    roundId: snapshot.roundId,
    capturedAt: snapshot.capturedAt,
    totalMemoriesStored: snapshot.totalMemoriesStored,
    totalMemoriesActive: snapshot.totalMemoriesActive,
    totalMemoriesSelected: snapshot.totalMemoriesSelected,
    totalMemoriesInjected: snapshot.totalMemoriesInjected,
    totalRelationshipsStored: snapshot.totalRelationshipsStored,
    totalRelationshipsActive: snapshot.totalRelationshipsActive,
    totalRelationshipsSelected: snapshot.totalRelationshipsSelected,
    totalRelationshipsInjected: snapshot.totalRelationshipsInjected,
    reverseRelationships: reverseRels,
    tokenBudget: {
      contextWindow: snapshot.tokenBudget.contextWindow,
      availableInputTokens: snapshot.tokenBudget.availableInputTokens,
      estimatedTotalTokens: snapshot.tokenBudget.estimatedTotalTokens,
      usagePercent: snapshot.tokenBudget.usagePercent,
      totalMessagesBeforeTrim: snapshot.tokenBudget.totalMessagesBeforeTrim,
      totalMessagesAfterTrim: snapshot.tokenBudget.totalMessagesAfterTrim,
      trimmedMessageCount: snapshot.tokenBudget.trimmedMessageCount
    },
    lorebookMatchedEntryCount: snapshot.lorebook.matchedEntryCount,
    promptMessages: promptMsgs,
    presetSystemPromptPreview: snapshot.presetSystemPromptPreview,
    groupConstraintPreview: snapshot.groupConstraintPreview,
    replyTargetMode: snapshot.replyTargetMode,
    participantNames: snapshot.participantNames
  };
  return result;
}

function parsePersistedItem(item: Object): PersistedInspectionSnapshot | undefined {
  if (item === null || typeof item !== 'object') {
    return undefined;
  }
  const rec: Record<string, Object> = item as Record<string, Object>;
  const str = (key: string): string => {
    const v: Object | undefined = rec[key];
    return v !== undefined && v !== null && typeof v === 'string' ? v : '';
  };
  const num = (key: string): number => {
    const v: Object | undefined = rec[key];
    return v !== undefined && v !== null && typeof v === 'number' ? v : 0;
  };

  const reverseRels: PersistedReverseRelationship[] = [];
  const reverseRaw: Object | undefined = rec['reverseRelationships'];
  if (reverseRaw !== undefined && typeof reverseRaw === 'object' && reverseRaw !== null) {
    const arr: Object[] = reverseRaw as Object[];
    for (let i = 0; i < arr.length; i++) {
      const r: Object = arr[i];
      if (r !== null && typeof r === 'object') {
        const rrec: Record<string, Object> = r as Record<string, Object>;
        const id: Object | undefined = rrec['id'];
        const owner: Object | undefined = rrec['ownerCharacterName'];
        const target: Object | undefined = rrec['targetName'];
        reverseRels.push({
          id: id !== undefined && typeof id === 'string' ? id : '',
          ownerCharacterName: owner !== undefined && typeof owner === 'string' ? owner : '',
          targetName: target !== undefined && typeof target === 'string' ? target : ''
        });
      }
    }
  }

  const promptMsgs: PersistedPromptMessage[] = [];
  const promptRaw: Object | undefined = rec['promptMessages'];
  if (promptRaw !== undefined && typeof promptRaw === 'object' && promptRaw !== null) {
    const arr: Object[] = promptRaw as Object[];
    for (let i = 0; i < arr.length; i++) {
      const m: Object = arr[i];
      if (m !== null && typeof m === 'object') {
        const mrec: Record<string, Object> = m as Record<string, Object>;
        const role: Object | undefined = mrec['role'];
        const preview: Object | undefined = mrec['contentPreview'];
        const category: Object | undefined = mrec['category'];
        const tokens: Object | undefined = mrec['estimatedTokens'];
        promptMsgs.push({
          role: role !== undefined && typeof role === 'string' ? role : '',
          contentPreview: preview !== undefined && typeof preview === 'string' ? preview : '',
          category: category !== undefined && typeof category === 'string' ? category : 'other',
          estimatedTokens: tokens !== undefined && typeof tokens === 'number' ? tokens : 0
        });
      }
    }
  }

  const budgetRaw: Object | undefined = rec['tokenBudget'];
  let budget: PersistedTokenBudget = {
    contextWindow: 0,
    availableInputTokens: 0,
    estimatedTotalTokens: 0,
    usagePercent: 0,
    totalMessagesBeforeTrim: 0,
    totalMessagesAfterTrim: 0,
    trimmedMessageCount: 0
  };
  if (budgetRaw !== undefined && typeof budgetRaw === 'object' && budgetRaw !== null) {
    const brec: Record<string, Object> = budgetRaw as Record<string, Object>;
    const read = (key: string): number => {
      const v: Object | undefined = brec[key];
      return v !== undefined && v !== null && typeof v === 'number' ? v : 0;
    };
    budget = {
      contextWindow: read('contextWindow'),
      availableInputTokens: read('availableInputTokens'),
      estimatedTotalTokens: read('estimatedTotalTokens'),
      usagePercent: read('usagePercent'),
      totalMessagesBeforeTrim: read('totalMessagesBeforeTrim'),
      totalMessagesAfterTrim: read('totalMessagesAfterTrim'),
      trimmedMessageCount: read('trimmedMessageCount')
    };
  }

  const result: PersistedInspectionSnapshot = {
    snapshotId: str('snapshotId'),
    groupConversationId: str('groupConversationId'),
    speakerCharacterId: str('speakerCharacterId'),
    speakerCharacterName: str('speakerCharacterName'),
    roundId: str('roundId'),
    capturedAt: num('capturedAt'),
    totalMemoriesStored: num('totalMemoriesStored'),
    totalMemoriesActive: num('totalMemoriesActive'),
    totalMemoriesSelected: num('totalMemoriesSelected'),
    totalMemoriesInjected: num('totalMemoriesInjected'),
    totalRelationshipsStored: num('totalRelationshipsStored'),
    totalRelationshipsActive: num('totalRelationshipsActive'),
    totalRelationshipsSelected: num('totalRelationshipsSelected'),
    totalRelationshipsInjected: num('totalRelationshipsInjected'),
    reverseRelationships: reverseRels,
    tokenBudget: budget,
    lorebookMatchedEntryCount: num('lorebookMatchedEntryCount'),
    promptMessages: promptMsgs,
    presetSystemPromptPreview: str('presetSystemPromptPreview'),
    groupConstraintPreview: str('groupConstraintPreview'),
    replyTargetMode: str('replyTargetMode'),
    participantNames: parseStringArray(rec['participantNames'])
  };
  return result;
}

function parseStringArray(value: Object | undefined): string[] {
  if (value === undefined || value === null || typeof value !== 'object') {
    return [];
  }
  const arr: Object[] = value as Object[];
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const v: Object = arr[i];
    if (typeof v === 'string') {
      result.push(v);
    }
  }
  return result;
}

function fromPersisted(p: PersistedInspectionSnapshot): GroupPromptInspectionSnapshot | undefined {
  if (p.groupConversationId.length === 0 || p.speakerCharacterId.length === 0) {
    return undefined;
  }
  const memories: MemoryInspectionItem[] = [];
  const relationships: RelationshipInspectionItem[] = [];
  const reverseRels: RelationshipInspectionItem[] = [];
  for (let i = 0; i < p.reverseRelationships.length; i++) {
    const r: PersistedReverseRelationship = p.reverseRelationships[i];
    reverseRels.push({
      id: r.id,
      ownerCharacterId: '',
      ownerCharacterName: r.ownerCharacterName,
      targetId: '',
      targetType: '',
      targetName: r.targetName,
      direction: r.ownerCharacterName + ' → ' + r.targetName,
      experienceSummary: '',
      attitudeSummary: '',
      relationshipSummary: '',
      importance: 0,
      status: '',
      selected: false,
      injected: false,
      isReverse: true
    });
  }
  const promptMsgs: PromptMessageInspectionItem[] = [];
  for (let i = 0; i < p.promptMessages.length; i++) {
    const m: PersistedPromptMessage = p.promptMessages[i];
    promptMsgs.push({
      role: m.role,
      contentPreview: m.contentPreview,
      category: m.category,
      estimatedTokens: m.estimatedTokens
    });
  }
  const budget: TokenBudgetInspection = {
    contextWindow: p.tokenBudget.contextWindow,
    availableInputTokens: p.tokenBudget.availableInputTokens,
    estimatedTotalTokens: p.tokenBudget.estimatedTotalTokens,
    usagePercent: p.tokenBudget.usagePercent,
    totalMessagesBeforeTrim: p.tokenBudget.totalMessagesBeforeTrim,
    totalMessagesAfterTrim: p.tokenBudget.totalMessagesAfterTrim,
    trimmedMessageCount: p.tokenBudget.trimmedMessageCount
  };
  const lorebook: LorebookInspection = {
    globalLorebookLoaded: false,
    characterLorebookLoaded: false,
    matchedEntryCount: p.lorebookMatchedEntryCount
  };
  const snapshot: GroupPromptInspectionSnapshot = {
    snapshotId: p.snapshotId,
    groupConversationId: p.groupConversationId,
    speakerCharacterId: p.speakerCharacterId,
    speakerCharacterName: p.speakerCharacterName,
    roundId: p.roundId,
    capturedAt: p.capturedAt,
    memories: memories,
    totalMemoriesStored: p.totalMemoriesStored,
    totalMemoriesActive: p.totalMemoriesActive,
    totalMemoriesSelected: p.totalMemoriesSelected,
    totalMemoriesInjected: p.totalMemoriesInjected,
    relationships: relationships,
    totalRelationshipsStored: p.totalRelationshipsStored,
    totalRelationshipsActive: p.totalRelationshipsActive,
    totalRelationshipsSelected: p.totalRelationshipsSelected,
    totalRelationshipsInjected: p.totalRelationshipsInjected,
    reverseRelationships: reverseRels,
    promptMessages: promptMsgs,
    tokenBudget: budget,
    lorebook: lorebook,
    presetSystemPromptPreview: p.presetSystemPromptPreview,
    groupConstraintPreview: p.groupConstraintPreview,
    replyTargetMode: p.replyTargetMode,
    participantNames: p.participantNames
  };
  return snapshot;
}
