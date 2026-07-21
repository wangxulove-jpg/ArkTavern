/**
 * WorldRelationshipService 多人世界关系服务
 *
 * 职责:
 * - CharacterUserRelationship 的查询与更新(角色 ↔ 用户)
 * - CharacterRelationship 的查询与更新(角色 ↔ 角色)
 * - 关系变更历史记录(供回滚与审计)
 * - 会话级关系记录的继承(从世界级关系派生 chatId/branchId 级别关系)
 * - 关系失效与重建(Swipe/分支切换/重新生成时)
 *
 * 不负责:
 * - 关系数值的具体规则(由 MultiPersonResponseParser 决定变更)
 * - 关系变更触发的记忆事件(由 WorldMemoryService 处理)
 *
 * 规则:
 * - 角色对用户的关系 与 角色对其他角色的关系 完全独立
 * - A 对 B 与 B 对 A 允许不同
 * - 关系变化必须缓慢、连续、有依据
 * - 不打印 privateOpinion / secretsFromUser / secretsSharedByUser 正文
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { WorldRepository } from '../repositories/WorldRepository';
import {
  CharacterUserRelationship,
  CharacterRelationship,
  RelationshipChangeRecord,
  createCharacterUserRelationship,
  createCharacterRelationship,
  createRelationshipChangeRecord
} from '../models/WorldRelationship';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldRelationshipService';

/**
 * 单个关系字段的更新(用于审计与回滚)。
 */
export interface RelationshipFieldUpdate {
  readonly characterId: string;
  readonly targetCharacterId: string | null;
  readonly fieldName: string;
  readonly oldValue: string;
  readonly newValue: string;
  readonly reason: string;
  readonly sourceMessageId: string | null;
}

export class WorldRelationshipService {
  private readonly dbHelper: DbHelper;
  private readonly worldRepo: WorldRepository;

  constructor(dbHelper: DbHelper, worldRepo: WorldRepository) {
    this.dbHelper = dbHelper;
    this.worldRepo = worldRepo;
  }

  // ===== 查询:角色与用户的关系 =====

  /**
   * 获取指定 chatId/branchId 下的角色与用户关系。
   * 如果该级别查不到,回退到世界级(chatId='', branchId='')。
   */
  async getUserRelationship(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<CharacterUserRelationship | null> {
    let rel: CharacterUserRelationship | null =
      await this.worldRepo.getUserRelationship(worldId, chatId, branchId, characterId);
    if (rel !== null) {
      return rel;
    }
    // 回退到世界级
    if (chatId.length > 0 || branchId.length > 0) {
      rel = await this.worldRepo.getUserRelationship(worldId, '', '', characterId);
    }
    return rel;
  }

  async listUserRelationships(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<CharacterUserRelationship[]> {
    return await this.worldRepo.listUserRelationships(worldId, chatId, branchId);
  }

  /**
   * 列出指定角色作为发起方的全部角色关系。
   * 先查 chatId/branchId 级别,若为空回退到世界级。
   */
  async listCharacterRelationshipsBySource(
    worldId: string,
    chatId: string,
    branchId: string,
    sourceCharacterId: string
  ): Promise<CharacterRelationship[]> {
    let rels: CharacterRelationship[] =
      await this.worldRepo.listCharacterRelationshipsBySource(
        worldId, chatId, branchId, sourceCharacterId
      );
    if (rels.length > 0) {
      return rels;
    }
    if (chatId.length > 0 || branchId.length > 0) {
      rels = await this.worldRepo.listCharacterRelationshipsBySource(
        worldId, '', '', sourceCharacterId
      );
    }
    return rels;
  }

  // ===== 查询:角色之间的关系 =====

  async getCharacterRelationship(
    worldId: string,
    chatId: string,
    branchId: string,
    sourceCharacterId: string,
    targetCharacterId: string
  ): Promise<CharacterRelationship | null> {
    let rel: CharacterRelationship | null = await this.worldRepo.getCharacterRelationship(
      worldId, chatId, branchId, sourceCharacterId, targetCharacterId
    );
    if (rel !== null) {
      return rel;
    }
    if (chatId.length > 0 || branchId.length > 0) {
      rel = await this.worldRepo.getCharacterRelationship(
        worldId, '', '', sourceCharacterId, targetCharacterId
      );
    }
    return rel;
  }

  // ===== 更新:关系数值(带变更记录) =====

  /**
   * 在事务中应用关系字段更新:
   * 1. 读取当前关系记录(若不存在,从世界级派生)
   * 2. 应用字段更新(仅允许数值字段变更,如 affinity/trust/...)
   * 3. 写入新的关系记录(upsert)
   * 4. 写入变更历史记录
   *
   * 调用方必须传入完整的字段更新列表,Service 不做规则判断。
   */
  async applyRelationshipUpdates(
    worldId: string,
    chatId: string,
    branchId: string,
    updates: RelationshipFieldUpdate[]
  ): Promise<void> {
    if (updates.length === 0) {
      return;
    }
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const now: number = nowMillis();
        for (let i = 0; i < updates.length; i++) {
          const u: RelationshipFieldUpdate = updates[i];
          if (u.targetCharacterId === null) {
            // 角色 ↔ 用户
            const current: CharacterUserRelationship | null =
              await this.worldRepo.getUserRelationship(
                worldId, chatId, branchId, u.characterId
              );
            let base: CharacterUserRelationship;
            if (current !== null) {
              base = current;
            } else {
              const worldLevel: CharacterUserRelationship | null =
                await this.worldRepo.getUserRelationship(
                  worldId, '', '', u.characterId
                );
              if (worldLevel === null) {
                // 无初始关系,跳过(避免凭空创建)
                Logger.warn(LOG_TAG, 'applyUpdates: no base user rel, skip');
                continue;
              }
              // 派生 chat/branch 级别关系
              base = createCharacterUserRelationship({
                worldId: worldId,
                chatId: chatId,
                branchId: branchId,
                characterId: worldLevel.characterId,
                relationshipLabel: worldLevel.relationshipLabel,
                affinity: worldLevel.affinity,
                trust: worldLevel.trust,
                respect: worldLevel.respect,
                fear: worldLevel.fear,
                hostility: worldLevel.hostility,
                dependency: worldLevel.dependency,
                familiarity: worldLevel.familiarity,
                currentEmotion: worldLevel.currentEmotion,
                privateOpinion: worldLevel.privateOpinion,
                sharedExperiences: worldLevel.sharedExperiences,
                promises: worldLevel.promises,
                conflicts: worldLevel.conflicts,
                secretsFromUser: worldLevel.secretsFromUser,
                secretsSharedByUser: worldLevel.secretsSharedByUser,
                userNameOverride: worldLevel.userNameOverride,
                lastUpdatedMessageId: ''
              });
            }
            const updated: CharacterUserRelationship = applyUserFieldUpdate(
              base, u.fieldName, u.newValue, u.sourceMessageId, now
            );
            await this.worldRepo.upsertUserRelationshipWithStore(store, updated);
            const record: RelationshipChangeRecord = createRelationshipChangeRecord(
              worldId,
              chatId,
              branchId,
              u.characterId,
              null,
              u.fieldName,
              u.oldValue,
              u.newValue,
              u.reason,
              u.sourceMessageId
            );
            await this.worldRepo.insertChangeRecordWithStore(store, record);
          } else {
            // 角色 ↔ 角色
            const current: CharacterRelationship | null =
              await this.worldRepo.getCharacterRelationship(
                worldId, chatId, branchId,
                u.characterId, u.targetCharacterId
              );
            let base: CharacterRelationship;
            if (current !== null) {
              base = current;
            } else {
              const worldLevel: CharacterRelationship | null =
                await this.worldRepo.getCharacterRelationship(
                  worldId, '', '', u.characterId, u.targetCharacterId
                );
              if (worldLevel === null) {
                Logger.warn(LOG_TAG, 'applyUpdates: no base char rel, skip');
                continue;
              }
              base = createCharacterRelationship({
                worldId: worldId,
                chatId: chatId,
                branchId: branchId,
                sourceCharacterId: worldLevel.sourceCharacterId,
                targetCharacterId: worldLevel.targetCharacterId,
                relationshipLabel: worldLevel.relationshipLabel,
                trust: worldLevel.trust,
                affinity: worldLevel.affinity,
                hostility: worldLevel.hostility,
                currentEmotion: worldLevel.currentEmotion,
                privateOpinion: worldLevel.privateOpinion,
                sharedExperiences: worldLevel.sharedExperiences,
                promises: worldLevel.promises,
                conflicts: worldLevel.conflicts,
                knownSecrets: worldLevel.knownSecrets
              });
            }
            const updated: CharacterRelationship = applyCharFieldUpdate(
              base, u.fieldName, u.newValue, now
            );
            await this.worldRepo.upsertCharacterRelationshipWithStore(store, updated);
            const record: RelationshipChangeRecord = createRelationshipChangeRecord(
              worldId,
              chatId,
              branchId,
              u.characterId,
              u.targetCharacterId,
              u.fieldName,
              u.oldValue,
              u.newValue,
              u.reason,
              u.sourceMessageId
            );
            await this.worldRepo.insertChangeRecordWithStore(store, record);
          }
        }
      }
    );
    Logger.info(LOG_TAG, `applyRelationshipUpdates count=${updates.length}`);
  }

  /**
   * 查询关系变更历史(按时间倒序)。
   */
  async listChangeHistory(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<RelationshipChangeRecord[]> {
    return await this.worldRepo.listChangeRecords(worldId, chatId, branchId);
  }
}

/**
 * 应用单个字段更新到 CharacterUserRelationship。
 * 仅允许特定字段更新,非法字段抛 InvalidData。
 */
function applyUserFieldUpdate(
  base: CharacterUserRelationship,
  fieldName: string,
  newValue: string,
  sourceMessageId: string | null,
  now: number
): CharacterUserRelationship {
  const numericFields: Set<string> = new Set<string>([
    'affinity', 'trust', 'respect', 'fear', 'hostility', 'dependency', 'familiarity'
  ]);
  const stringFields: Set<string> = new Set<string>([
    'relationshipLabel', 'currentEmotion', 'privateOpinion', 'userNameOverride'
  ]);
  if (numericFields.has(fieldName)) {
    const num: number = Number.parseFloat(newValue);
    if (!Number.isFinite(num)) {
      throw DatabaseError.invalidData(`relationship field ${fieldName} not numeric`);
    }
    return applyUserNumericField(base, fieldName, num, sourceMessageId, now);
  }
  if (stringFields.has(fieldName)) {
    return applyUserStringField(base, fieldName, newValue, sourceMessageId, now);
  }
  throw DatabaseError.invalidData(`relationship field ${fieldName} not updatable`);
}

function applyUserNumericField(
  base: CharacterUserRelationship,
  fieldName: string,
  newValue: number,
  sourceMessageId: string | null,
  now: number
): CharacterUserRelationship {
  const lastId: string | null = sourceMessageId !== null ? sourceMessageId : base.lastUpdatedMessageId;
  // 显式枚举避免动态访问
  switch (fieldName) {
    case 'affinity':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: newValue, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'trust':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: newValue, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'respect':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: newValue, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'fear':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: newValue,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'hostility':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: newValue, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'dependency':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: newValue, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'familiarity':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: newValue,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    default:
      throw DatabaseError.invalidData(`unknown numeric field ${fieldName}`);
  }
}

function applyUserStringField(
  base: CharacterUserRelationship,
  fieldName: string,
  newValue: string,
  sourceMessageId: string | null,
  now: number
): CharacterUserRelationship {
  const lastId: string | null = sourceMessageId !== null ? sourceMessageId : base.lastUpdatedMessageId;
  switch (fieldName) {
    case 'relationshipLabel':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: newValue,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'currentEmotion':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: newValue, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'privateOpinion':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: newValue,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: base.userNameOverride, lastUpdatedMessageId: lastId, updatedAt: now
      };
    case 'userNameOverride':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        characterId: base.characterId, relationshipLabel: base.relationshipLabel,
        affinity: base.affinity, trust: base.trust, respect: base.respect, fear: base.fear,
        hostility: base.hostility, dependency: base.dependency, familiarity: base.familiarity,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        secretsFromUser: base.secretsFromUser, secretsSharedByUser: base.secretsSharedByUser,
        userNameOverride: newValue, lastUpdatedMessageId: lastId, updatedAt: now
      };
    default:
      throw DatabaseError.invalidData(`unknown string field ${fieldName}`);
  }
}

/**
 * 应用单个字段更新到 CharacterRelationship。
 */
function applyCharFieldUpdate(
  base: CharacterRelationship,
  fieldName: string,
  newValue: string,
  now: number
): CharacterRelationship {
  const numericFields: Set<string> = new Set<string>([
    'trust', 'affinity', 'hostility'
  ]);
  const stringFields: Set<string> = new Set<string>([
    'relationshipLabel', 'currentEmotion', 'privateOpinion'
  ]);
  if (numericFields.has(fieldName)) {
    const num: number = Number.parseFloat(newValue);
    if (!Number.isFinite(num)) {
      throw DatabaseError.invalidData(`charRel field ${fieldName} not numeric`);
    }
    return applyCharNumericField(base, fieldName, num, now);
  }
  if (stringFields.has(fieldName)) {
    return applyCharStringField(base, fieldName, newValue, now);
  }
  throw DatabaseError.invalidData(`charRel field ${fieldName} not updatable`);
}

function applyCharNumericField(
  base: CharacterRelationship,
  fieldName: string,
  newValue: number,
  now: number
): CharacterRelationship {
  switch (fieldName) {
    case 'trust':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        sourceCharacterId: base.sourceCharacterId, targetCharacterId: base.targetCharacterId,
        relationshipLabel: base.relationshipLabel, trust: newValue,
        affinity: base.affinity, hostility: base.hostility,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        knownSecrets: base.knownSecrets, updatedAt: now
      };
    case 'affinity':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        sourceCharacterId: base.sourceCharacterId, targetCharacterId: base.targetCharacterId,
        relationshipLabel: base.relationshipLabel, trust: base.trust,
        affinity: newValue, hostility: base.hostility,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        knownSecrets: base.knownSecrets, updatedAt: now
      };
    case 'hostility':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        sourceCharacterId: base.sourceCharacterId, targetCharacterId: base.targetCharacterId,
        relationshipLabel: base.relationshipLabel, trust: base.trust,
        affinity: base.affinity, hostility: newValue,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        knownSecrets: base.knownSecrets, updatedAt: now
      };
    default:
      throw DatabaseError.invalidData(`unknown charRel numeric field ${fieldName}`);
  }
}

function applyCharStringField(
  base: CharacterRelationship,
  fieldName: string,
  newValue: string,
  now: number
): CharacterRelationship {
  switch (fieldName) {
    case 'relationshipLabel':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        sourceCharacterId: base.sourceCharacterId, targetCharacterId: base.targetCharacterId,
        relationshipLabel: newValue, trust: base.trust,
        affinity: base.affinity, hostility: base.hostility,
        currentEmotion: base.currentEmotion, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        knownSecrets: base.knownSecrets, updatedAt: now
      };
    case 'currentEmotion':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        sourceCharacterId: base.sourceCharacterId, targetCharacterId: base.targetCharacterId,
        relationshipLabel: base.relationshipLabel, trust: base.trust,
        affinity: base.affinity, hostility: base.hostility,
        currentEmotion: newValue, privateOpinion: base.privateOpinion,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        knownSecrets: base.knownSecrets, updatedAt: now
      };
    case 'privateOpinion':
      return {
        id: base.id, worldId: base.worldId, chatId: base.chatId, branchId: base.branchId,
        sourceCharacterId: base.sourceCharacterId, targetCharacterId: base.targetCharacterId,
        relationshipLabel: base.relationshipLabel, trust: base.trust,
        affinity: base.affinity, hostility: base.hostility,
        currentEmotion: base.currentEmotion, privateOpinion: newValue,
        sharedExperiences: base.sharedExperiences, promises: base.promises, conflicts: base.conflicts,
        knownSecrets: base.knownSecrets, updatedAt: now
      };
    default:
      throw DatabaseError.invalidData(`unknown charRel string field ${fieldName}`);
  }
}
