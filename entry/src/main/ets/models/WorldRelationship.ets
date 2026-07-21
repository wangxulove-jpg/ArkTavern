/**
 * WorldRelationship 世界关系模型
 *
 * 包含两类关系:
 * 1. 角色与用户的关系(CharacterUserRelationship)
 * 2. 角色之间的关系(CharacterRelationship)
 *
 * 设计约束:
 * - 每个角色的关系完全独立,A 对用户的变化不影响 B
 * - A 对 B 与 B 对 A 的关系允许不同
 * - 关系绑定到具体 Branch,Branch 切换时关系独立
 * - 关系变化必须有明确事件依据,缓慢连续变化
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

/**
 * 初始关系设定(创建世界时配置,用于新会话初始化)。
 */
export interface InitialRelationship {
  readonly relationshipLabel: string;
  readonly addressTerm: string;
  readonly affinity: number;
  readonly trust: number;
  readonly currentImpression: string;
  readonly sharedExperiences: string;
  readonly knownSecrets: string;
}

/**
 * 创建默认 InitialRelationship。
 * 允许部分覆盖,未指定字段使用默认值(空字符串 / 0)。
 */
export function createInitialRelationship(
  overrides?: Partial<InitialRelationship>
): InitialRelationship {
  const base: InitialRelationship = {
    relationshipLabel: '',
    addressTerm: '',
    affinity: 0,
    trust: 0,
    currentImpression: '',
    sharedExperiences: '',
    knownSecrets: ''
  };
  if (overrides === undefined || overrides === null) {
    return base;
  }
  return {
    relationshipLabel: overrides.relationshipLabel !== undefined ? overrides.relationshipLabel : base.relationshipLabel,
    addressTerm: overrides.addressTerm !== undefined ? overrides.addressTerm : base.addressTerm,
    affinity: overrides.affinity !== undefined ? overrides.affinity : base.affinity,
    trust: overrides.trust !== undefined ? overrides.trust : base.trust,
    currentImpression: overrides.currentImpression !== undefined ? overrides.currentImpression : base.currentImpression,
    sharedExperiences: overrides.sharedExperiences !== undefined ? overrides.sharedExperiences : base.sharedExperiences,
    knownSecrets: overrides.knownSecrets !== undefined ? overrides.knownSecrets : base.knownSecrets
  };
}

/**
 * 角色与用户的关系记录。
 * - 每个 (worldId, chatId, branchId, characterId) 唯一
 * - 完全独立于其他角色对用户的关系
 */
export interface CharacterUserRelationship {
  readonly id: string;
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly characterId: string;
  readonly relationshipLabel: string;
  /** 好感 [-100, 100] */
  readonly affinity: number;
  /** 信任 [-100, 100] */
  readonly trust: number;
  /** 尊重 [-100, 100] */
  readonly respect: number;
  /** 恐惧 [0, 100] */
  readonly fear: number;
  /** 敌意 [0, 100] */
  readonly hostility: number;
  /** 依赖 [0, 100] */
  readonly dependency: number;
  /** 熟悉度 [0, 100] */
  readonly familiarity: number;
  readonly currentEmotion: string;
  /** 角色对用户的私人看法(其他角色不可见) */
  readonly privateOpinion: string;
  readonly sharedExperiences: string[];
  readonly promises: string[];
  readonly conflicts: string[];
  /** 角色从用户处得知的秘密(其他角色不可见) */
  readonly secretsFromUser: string[];
  /** 角色向用户透露的秘密 */
  readonly secretsSharedByUser: string[];
  /** 角色对用户的专属称呼(覆盖世界默认) */
  readonly userNameOverride: string;
  readonly lastUpdatedMessageId: string | null;
  readonly updatedAt: number;
}

export interface CreateCharacterUserRelationshipOptions {
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly characterId: string;
  readonly relationshipLabel?: string;
  readonly affinity?: number;
  readonly trust?: number;
  readonly respect?: number;
  readonly fear?: number;
  readonly hostility?: number;
  readonly dependency?: number;
  readonly familiarity?: number;
  readonly currentEmotion?: string;
  readonly privateOpinion?: string;
  readonly sharedExperiences?: string[];
  readonly promises?: string[];
  readonly conflicts?: string[];
  readonly secretsFromUser?: string[];
  readonly secretsSharedByUser?: string[];
  readonly userNameOverride?: string;
  readonly lastUpdatedMessageId?: string | null;
}

export interface CharacterUserRelationshipUpdates {
  readonly relationshipLabel?: string;
  readonly affinity?: number;
  readonly trust?: number;
  readonly respect?: number;
  readonly fear?: number;
  readonly hostility?: number;
  readonly dependency?: number;
  readonly familiarity?: number;
  readonly currentEmotion?: string;
  readonly privateOpinion?: string;
  readonly sharedExperiences?: string[];
  readonly promises?: string[];
  readonly conflicts?: string[];
  readonly secretsFromUser?: string[];
  readonly secretsSharedByUser?: string[];
  readonly userNameOverride?: string;
  readonly lastUpdatedMessageId?: string | null;
}

export function createCharacterUserRelationship(
  options: CreateCharacterUserRelationshipOptions
): CharacterUserRelationship {
  return {
    id: generateUuid(),
    worldId: options.worldId,
    chatId: options.chatId,
    branchId: options.branchId,
    characterId: options.characterId,
    relationshipLabel: options.relationshipLabel !== undefined ? options.relationshipLabel : '',
    affinity: options.affinity !== undefined ? options.affinity : 0,
    trust: options.trust !== undefined ? options.trust : 0,
    respect: options.respect !== undefined ? options.respect : 0,
    fear: options.fear !== undefined ? options.fear : 0,
    hostility: options.hostility !== undefined ? options.hostility : 0,
    dependency: options.dependency !== undefined ? options.dependency : 0,
    familiarity: options.familiarity !== undefined ? options.familiarity : 0,
    currentEmotion: options.currentEmotion !== undefined ? options.currentEmotion : '',
    privateOpinion: options.privateOpinion !== undefined ? options.privateOpinion : '',
    sharedExperiences: options.sharedExperiences !== undefined
      ? [...options.sharedExperiences] : [],
    promises: options.promises !== undefined ? [...options.promises] : [],
    conflicts: options.conflicts !== undefined ? [...options.conflicts] : [],
    secretsFromUser: options.secretsFromUser !== undefined
      ? [...options.secretsFromUser] : [],
    secretsSharedByUser: options.secretsSharedByUser !== undefined
      ? [...options.secretsSharedByUser] : [],
    userNameOverride: options.userNameOverride !== undefined ? options.userNameOverride : '',
    lastUpdatedMessageId: options.lastUpdatedMessageId !== undefined
      ? options.lastUpdatedMessageId : null,
    updatedAt: nowMillis()
  };
}

export function updateCharacterUserRelationship(
  rel: CharacterUserRelationship,
  updates: CharacterUserRelationshipUpdates
): CharacterUserRelationship {
  return {
    id: rel.id,
    worldId: rel.worldId,
    chatId: rel.chatId,
    branchId: rel.branchId,
    characterId: rel.characterId,
    relationshipLabel: updates.relationshipLabel !== undefined
      ? updates.relationshipLabel : rel.relationshipLabel,
    affinity: updates.affinity !== undefined ? updates.affinity : rel.affinity,
    trust: updates.trust !== undefined ? updates.trust : rel.trust,
    respect: updates.respect !== undefined ? updates.respect : rel.respect,
    fear: updates.fear !== undefined ? updates.fear : rel.fear,
    hostility: updates.hostility !== undefined ? updates.hostility : rel.hostility,
    dependency: updates.dependency !== undefined ? updates.dependency : rel.dependency,
    familiarity: updates.familiarity !== undefined ? updates.familiarity : rel.familiarity,
    currentEmotion: updates.currentEmotion !== undefined
      ? updates.currentEmotion : rel.currentEmotion,
    privateOpinion: updates.privateOpinion !== undefined
      ? updates.privateOpinion : rel.privateOpinion,
    sharedExperiences: updates.sharedExperiences !== undefined
      ? [...updates.sharedExperiences] : rel.sharedExperiences,
    promises: updates.promises !== undefined ? [...updates.promises] : rel.promises,
    conflicts: updates.conflicts !== undefined ? [...updates.conflicts] : rel.conflicts,
    secretsFromUser: updates.secretsFromUser !== undefined
      ? [...updates.secretsFromUser] : rel.secretsFromUser,
    secretsSharedByUser: updates.secretsSharedByUser !== undefined
      ? [...updates.secretsSharedByUser] : rel.secretsSharedByUser,
    userNameOverride: updates.userNameOverride !== undefined
      ? updates.userNameOverride : rel.userNameOverride,
    lastUpdatedMessageId: updates.lastUpdatedMessageId !== undefined
      ? updates.lastUpdatedMessageId : rel.lastUpdatedMessageId,
    updatedAt: nowMillis()
  };
}

/**
 * 角色之间的关系记录。
 * - source 对 target 的关系独立于 target 对 source 的关系
 * - 每个 (worldId, chatId, branchId, sourceCharacterId, targetCharacterId) 唯一
 */
export interface CharacterRelationship {
  readonly id: string;
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly sourceCharacterId: string;
  readonly targetCharacterId: string;
  readonly relationshipLabel: string;
  readonly trust: number;
  readonly affinity: number;
  readonly hostility: number;
  readonly currentEmotion: string;
  readonly privateOpinion: string;
  readonly sharedExperiences: string[];
  readonly promises: string[];
  readonly conflicts: string[];
  /** source 知道 target 的秘密(其他角色不可见) */
  readonly knownSecrets: string[];
  readonly updatedAt: number;
}

export interface CreateCharacterRelationshipOptions {
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly sourceCharacterId: string;
  readonly targetCharacterId: string;
  readonly relationshipLabel?: string;
  readonly trust?: number;
  readonly affinity?: number;
  readonly hostility?: number;
  readonly currentEmotion?: string;
  readonly privateOpinion?: string;
  readonly sharedExperiences?: string[];
  readonly promises?: string[];
  readonly conflicts?: string[];
  readonly knownSecrets?: string[];
}

export interface CharacterRelationshipUpdates {
  readonly relationshipLabel?: string;
  readonly trust?: number;
  readonly affinity?: number;
  readonly hostility?: number;
  readonly currentEmotion?: string;
  readonly privateOpinion?: string;
  readonly sharedExperiences?: string[];
  readonly promises?: string[];
  readonly conflicts?: string[];
  readonly knownSecrets?: string[];
}

export function createCharacterRelationship(
  options: CreateCharacterRelationshipOptions
): CharacterRelationship {
  return {
    id: generateUuid(),
    worldId: options.worldId,
    chatId: options.chatId,
    branchId: options.branchId,
    sourceCharacterId: options.sourceCharacterId,
    targetCharacterId: options.targetCharacterId,
    relationshipLabel: options.relationshipLabel !== undefined ? options.relationshipLabel : '',
    trust: options.trust !== undefined ? options.trust : 0,
    affinity: options.affinity !== undefined ? options.affinity : 0,
    hostility: options.hostility !== undefined ? options.hostility : 0,
    currentEmotion: options.currentEmotion !== undefined ? options.currentEmotion : '',
    privateOpinion: options.privateOpinion !== undefined ? options.privateOpinion : '',
    sharedExperiences: options.sharedExperiences !== undefined
      ? [...options.sharedExperiences] : [],
    promises: options.promises !== undefined ? [...options.promises] : [],
    conflicts: options.conflicts !== undefined ? [...options.conflicts] : [],
    knownSecrets: options.knownSecrets !== undefined ? [...options.knownSecrets] : [],
    updatedAt: nowMillis()
  };
}

export function updateCharacterRelationship(
  rel: CharacterRelationship,
  updates: CharacterRelationshipUpdates
): CharacterRelationship {
  return {
    id: rel.id,
    worldId: rel.worldId,
    chatId: rel.chatId,
    branchId: rel.branchId,
    sourceCharacterId: rel.sourceCharacterId,
    targetCharacterId: rel.targetCharacterId,
    relationshipLabel: updates.relationshipLabel !== undefined
      ? updates.relationshipLabel : rel.relationshipLabel,
    trust: updates.trust !== undefined ? updates.trust : rel.trust,
    affinity: updates.affinity !== undefined ? updates.affinity : rel.affinity,
    hostility: updates.hostility !== undefined ? updates.hostility : rel.hostility,
    currentEmotion: updates.currentEmotion !== undefined
      ? updates.currentEmotion : rel.currentEmotion,
    privateOpinion: updates.privateOpinion !== undefined
      ? updates.privateOpinion : rel.privateOpinion,
    sharedExperiences: updates.sharedExperiences !== undefined
      ? [...updates.sharedExperiences] : rel.sharedExperiences,
    promises: updates.promises !== undefined ? [...updates.promises] : rel.promises,
    conflicts: updates.conflicts !== undefined ? [...updates.conflicts] : rel.conflicts,
    knownSecrets: updates.knownSecrets !== undefined
      ? [...updates.knownSecrets] : rel.knownSecrets,
    updatedAt: nowMillis()
  };
}

/**
 * 关系变化记录(用于审计与回滚)。
 */
export interface RelationshipChangeRecord {
  readonly id: string;
  readonly worldId: string;
  readonly chatId: string;
  readonly branchId: string;
  readonly characterId: string;
  /** 目标角色 ID(null 表示对用户的关系变化) */
  readonly targetCharacterId: string | null;
  readonly fieldName: string;
  readonly oldValue: string;
  readonly newValue: string;
  readonly reason: string;
  readonly sourceMessageId: string | null;
  readonly createdAt: number;
}

export function createRelationshipChangeRecord(
  worldId: string,
  chatId: string,
  branchId: string,
  characterId: string,
  targetCharacterId: string | null,
  fieldName: string,
  oldValue: string,
  newValue: string,
  reason: string,
  sourceMessageId: string | null
): RelationshipChangeRecord {
  return {
    id: generateUuid(),
    worldId: worldId,
    chatId: chatId,
    branchId: branchId,
    characterId: characterId,
    targetCharacterId: targetCharacterId,
    fieldName: fieldName,
    oldValue: oldValue,
    newValue: newValue,
    reason: reason,
    sourceMessageId: sourceMessageId,
    createdAt: nowMillis()
  };
}
