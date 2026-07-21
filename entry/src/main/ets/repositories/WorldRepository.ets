/**
 * WorldRepository 多人世界仓储
 *
 * 统一负责:
 * - worlds 表 CRUD
 * - world_members 表 CRUD
 * - world_scenes 表 CRUD
 * - world_chat_links 表 CRUD
 * - character_user_relationships 表 CRUD
 * - character_relationships 表 CRUD
 * - world_memory_events 表 CRUD
 * - world_private_memories 表 CRUD
 * - relationship_change_history 表 CRUD
 *
 * 设计约束:
 * - 不实现跨表事务(由 Service 层通过 DbHelper.runInTransaction 协调)
 * - 不缓存
 * - 不打印角色字段/关系字段正文
 * - JSON 字段使用 JSON.stringify/parse,异常抛 InvalidData
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { DatabaseError } from '../models/DatabaseError';
import { World, WorldUserIdentity, WorldReplyMode, parseReplyMode, EMPTY_USER_IDENTITY } from '../models/World';
import {
  WorldMember,
  createWorldMember,
  updateWorldMember
} from '../models/WorldMember';
import {
  WorldScene,
  createWorldScene,
  updateWorldScene,
  parseSceneStatus
} from '../models/WorldScene';
import {
  WorldChatLink,
  createWorldChatLink,
  updateWorldChatLink
} from '../models/WorldChatLink';
import {
  CharacterUserRelationship,
  CharacterRelationship,
  RelationshipChangeRecord,
  createCharacterUserRelationship,
  createCharacterRelationship,
  InitialRelationship
} from '../models/WorldRelationship';
import {
  WorldMemoryEvent,
  WorldPrivateMemory,
  createWorldMemoryEvent,
  createWorldPrivateMemory,
  parseVisibility
} from '../models/WorldMemory';
import {
  TABLE_WORLDS,
  TABLE_WORLD_MEMBERS,
  TABLE_WORLD_SCENES,
  TABLE_WORLD_CHAT_LINKS,
  TABLE_CHARACTER_USER_RELATIONSHIPS,
  TABLE_CHARACTER_RELATIONSHIPS,
  TABLE_WORLD_MEMORY_EVENTS,
  TABLE_WORLD_PRIVATE_MEMORIES,
  TABLE_RELATIONSHIP_CHANGE_HISTORY,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_WORLD_NAME,
  COLUMN_WORLD_BACKGROUND,
  COLUMN_WORLD_INITIAL_SCENE,
  COLUMN_WORLD_USER_IDENTITY_JSON,
  COLUMN_WORLD_DEFAULT_REPLY_MODE,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_MEMBER_ID,
  COLUMN_MEMBER_WORLD_ID,
  COLUMN_MEMBER_CHARACTER_ID,
  COLUMN_MEMBER_ENABLED,
  COLUMN_MEMBER_PRESENT,
  COLUMN_MEMBER_MUTED,
  COLUMN_MEMBER_TALKATIVENESS,
  COLUMN_MEMBER_DISPLAY_ORDER,
  COLUMN_MEMBER_JOINED_AT,
  COLUMN_MEMBER_INITIAL_RELATIONSHIP_JSON,
  COLUMN_SCENE_ID_FULL,
  COLUMN_SCENE_WORLD_ID,
  COLUMN_SCENE_NAME,
  COLUMN_SCENE_LOCATION,
  COLUMN_SCENE_TIME_DESCRIPTION,
  COLUMN_SCENE_DESCRIPTION,
  COLUMN_SCENE_PRESENT_CHARACTER_IDS_JSON,
  COLUMN_SCENE_IMPORTANT_OBJECTS_JSON,
  COLUMN_SCENE_STATUS,
  COLUMN_WCL_CHAT_ID,
  COLUMN_WCL_WORLD_ID,
  COLUMN_WCL_CURRENT_SCENE_ID,
  COLUMN_WCL_REPLY_MODE,
  COLUMN_CHAT_ID,
  COLUMN_BRANCH_ID,
  COLUMN_SCENE_ID,
  COLUMN_RELATIONSHIP_LABEL,
  COLUMN_AFFINITY,
  COLUMN_TRUST,
  COLUMN_RESPECT,
  COLUMN_FEAR,
  COLUMN_HOSTILITY,
  COLUMN_DEPENDENCY,
  COLUMN_FAMILIARITY,
  COLUMN_CURRENT_EMOTION,
  COLUMN_PRIVATE_OPINION,
  COLUMN_SHARED_EXPERIENCES_JSON,
  COLUMN_PROMISES_JSON,
  COLUMN_CONFLICTS_JSON,
  COLUMN_SECRETS_FROM_USER_JSON,
  COLUMN_SECRETS_SHARED_BY_USER_JSON,
  COLUMN_USER_NAME_OVERRIDE,
  COLUMN_LAST_UPDATED_MESSAGE_ID,
  COLUMN_SOURCE_CHARACTER_ID,
  COLUMN_TARGET_CHARACTER_ID,
  COLUMN_KNOWN_SECRETS_JSON,
  COLUMN_EVENT_PARTICIPANT_IDS_JSON,
  COLUMN_EVENT_WITNESS_IDS_JSON,
  COLUMN_EVENT_INFORMED_IDS_JSON,
  COLUMN_EVENT_SUBJECT_CHARACTER_ID,
  COLUMN_EVENT_RELATED_CHARACTER_IDS_JSON,
  COLUMN_EVENT_VISIBILITY,
  COLUMN_EVENT_SUMMARY,
  COLUMN_EVENT_START_MESSAGE_ID,
  COLUMN_EVENT_END_MESSAGE_ID,
  COLUMN_MEMORY_ENABLED,
  COLUMN_PRIVATE_MEMORY_CHARACTER_ID,
  COLUMN_CHANGE_TARGET_CHARACTER_ID,
  COLUMN_CHANGE_FIELD_NAME,
  COLUMN_CHANGE_OLD_VALUE,
  COLUMN_CHANGE_NEW_VALUE,
  COLUMN_CHANGE_REASON,
  COLUMN_CHANGE_SOURCE_MESSAGE_ID,
  COLUMN_MEMBER_CHARACTER_ID as COLUMN_REL_CHARACTER_ID
} from '../database/DatabaseConstants';

// ===== JSON 序列化辅助 =====
function jsonStringify(value: Object): string {
  try {
    return JSON.stringify(value);
  } catch (e) {
    throw DatabaseError.invalidData('json stringify failed');
  }
}

function jsonParseArray(value: string | null): string[] {
  if (value === null || value === '') {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(value);
    if (Array.isArray(parsed)) {
      const result: string[] = [];
      for (let i = 0; i < (parsed as Object[]).length; i++) {
        const item: Object = (parsed as Object[])[i];
        if (typeof item === 'string') {
          result.push(item);
        }
      }
      return result;
    }
    return [];
  } catch (e) {
    throw DatabaseError.invalidData('json parse array failed');
  }
}

function jsonParseObject(value: string | null): Record<string, Object> {
  if (value === null || value === '') {
    const empty: Record<string, Object> = {};
    return empty;
  }
  try {
    return JSON.parse(value) as Record<string, Object>;
  } catch (e) {
    throw DatabaseError.invalidData('json parse object failed');
  }
}

function intToBoolean(value: number): boolean {
  return value !== 0;
}

function booleanToInt(value: boolean): number {
  return value ? 1 : 0;
}

function extractCauseMessage(err: Object): string {
  if (err === null || err === undefined) {
    return '';
  }
  if (typeof err === 'object') {
    const obj: Object = err as Object;
    const msg: Object | undefined = Reflect.has(obj, 'message')
      ? (obj as Record<string, Object>).message
      : undefined;
    if (typeof msg === 'string') {
      return msg;
    }
  }
  return 'unknown error';
}

function isConstraintViolation(err: Object): boolean {
  const cause: string = extractCauseMessage(err);
  const lower: string = cause.toLowerCase();
  return lower.indexOf('unique') >= 0
    || lower.indexOf('constraint') >= 0
    || lower.indexOf('primary key') >= 0;
}

// ===== World CRUD =====
function worldToBucket(world: World): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_WORLD_ID] = world.id;
  bucket[COLUMN_WORLD_NAME] = world.name;
  bucket[COLUMN_WORLD_BACKGROUND] = world.background;
  bucket[COLUMN_WORLD_INITIAL_SCENE] = world.initialScene;
  bucket[COLUMN_WORLD_USER_IDENTITY_JSON] = jsonStringify(world.userIdentity as Object);
  bucket[COLUMN_WORLD_DEFAULT_REPLY_MODE] = world.defaultReplyMode;
  bucket[COLUMN_CREATED_AT] = world.createdAt;
  bucket[COLUMN_UPDATED_AT] = world.updatedAt;
  return bucket;
}

function worldFromRow(rs: relationalStore.ResultSet): World {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_NAME));
  const background: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_BACKGROUND));
  const initialScene: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_INITIAL_SCENE));
  const userIdentityJson: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_USER_IDENTITY_JSON));
  const defaultReplyMode: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_DEFAULT_REPLY_MODE));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  const identityObj: Object = jsonParseObject(userIdentityJson);
  const userIdentity: WorldUserIdentity = parseUserIdentity(identityObj);
  return {
    id: id,
    name: name,
    background: background,
    initialScene: initialScene,
    userIdentity: userIdentity,
    defaultReplyMode: parseReplyMode(defaultReplyMode),
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function parseUserIdentity(obj: Object): WorldUserIdentity {
  const rec: Record<string, Object> = obj as Record<string, Object>;
  const userName: string = typeof rec['userName'] === 'string' ? rec['userName'] as string : '';
  const identityDescription: string = typeof rec['identityDescription'] === 'string' ? rec['identityDescription'] as string : '';
  const appearance: string = typeof rec['appearance'] === 'string' ? rec['appearance'] as string : '';
  const background: string = typeof rec['background'] === 'string' ? rec['background'] as string : '';
  const publicInfo: string = typeof rec['publicInfo'] === 'string' ? rec['publicInfo'] as string : '';
  const privateInfo: string = typeof rec['privateInfo'] === 'string' ? rec['privateInfo'] as string : '';
  const defaultAddressTerm: string = typeof rec['defaultAddressTerm'] === 'string' ? rec['defaultAddressTerm'] as string : '';
  return {
    userName: userName,
    identityDescription: identityDescription,
    appearance: appearance,
    background: background,
    publicInfo: publicInfo,
    privateInfo: privateInfo,
    defaultAddressTerm: defaultAddressTerm
  };
}

// ===== WorldMember CRUD =====
function memberToBucket(member: WorldMember): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_MEMBER_ID] = member.id;
  bucket[COLUMN_MEMBER_WORLD_ID] = member.worldId;
  bucket[COLUMN_MEMBER_CHARACTER_ID] = member.characterId;
  bucket[COLUMN_MEMBER_ENABLED] = booleanToInt(member.enabled);
  bucket[COLUMN_MEMBER_PRESENT] = booleanToInt(member.present);
  bucket[COLUMN_MEMBER_MUTED] = booleanToInt(member.muted);
  bucket[COLUMN_MEMBER_TALKATIVENESS] = member.talkativeness;
  bucket[COLUMN_MEMBER_DISPLAY_ORDER] = member.displayOrder;
  bucket[COLUMN_MEMBER_JOINED_AT] = member.joinedAt;
  bucket[COLUMN_MEMBER_INITIAL_RELATIONSHIP_JSON] = jsonStringify(member.initialRelationship as Object);
  return bucket;
}

function memberFromRow(rs: relationalStore.ResultSet): WorldMember {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_MEMBER_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMBER_WORLD_ID));
  const characterId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMBER_CHARACTER_ID));
  const enabled: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_MEMBER_ENABLED)));
  const present: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_MEMBER_PRESENT)));
  const muted: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_MEMBER_MUTED)));
  const talkativeness: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMBER_TALKATIVENESS));
  const displayOrder: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMBER_DISPLAY_ORDER));
  const joinedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMBER_JOINED_AT));
  const initialRelJson: string = rs.getString(rs.getColumnIndex(COLUMN_MEMBER_INITIAL_RELATIONSHIP_JSON));
  const initialRelationship: InitialRelationship = parseInitialRelationship(jsonParseObject(initialRelJson));
  return {
    id: id,
    worldId: worldId,
    characterId: characterId,
    enabled: enabled,
    present: present,
    muted: muted,
    talkativeness: talkativeness,
    displayOrder: displayOrder,
    joinedAt: joinedAt,
    initialRelationship: initialRelationship
  };
}

function parseInitialRelationship(obj: Object): InitialRelationship {
  const rec: Record<string, Object> = obj as Record<string, Object>;
  return {
    relationshipLabel: typeof rec['relationshipLabel'] === 'string' ? rec['relationshipLabel'] as string : '',
    addressTerm: typeof rec['addressTerm'] === 'string' ? rec['addressTerm'] as string : '',
    affinity: typeof rec['affinity'] === 'number' ? rec['affinity'] as number : 0,
    trust: typeof rec['trust'] === 'number' ? rec['trust'] as number : 0,
    currentImpression: typeof rec['currentImpression'] === 'string' ? rec['currentImpression'] as string : '',
    sharedExperiences: typeof rec['sharedExperiences'] === 'string' ? rec['sharedExperiences'] as string : '',
    knownSecrets: typeof rec['knownSecrets'] === 'string' ? rec['knownSecrets'] as string : ''
  };
}

// ===== WorldScene CRUD =====
function sceneToBucket(scene: WorldScene): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_SCENE_ID_FULL] = scene.id;
  bucket[COLUMN_SCENE_WORLD_ID] = scene.worldId;
  bucket[COLUMN_SCENE_NAME] = scene.name;
  bucket[COLUMN_SCENE_LOCATION] = scene.location;
  bucket[COLUMN_SCENE_TIME_DESCRIPTION] = scene.timeDescription;
  bucket[COLUMN_SCENE_DESCRIPTION] = scene.description;
  bucket[COLUMN_SCENE_PRESENT_CHARACTER_IDS_JSON] = jsonStringify(scene.presentCharacterIds as Object);
  bucket[COLUMN_SCENE_IMPORTANT_OBJECTS_JSON] = jsonStringify(scene.importantObjects as Object);
  bucket[COLUMN_SCENE_STATUS] = scene.status;
  bucket[COLUMN_CREATED_AT] = scene.createdAt;
  return bucket;
}

function sceneFromRow(rs: relationalStore.ResultSet): WorldScene {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_ID_FULL));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_WORLD_ID));
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_NAME));
  const location: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_LOCATION));
  const timeDescription: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_TIME_DESCRIPTION));
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_DESCRIPTION));
  const presentJson: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_PRESENT_CHARACTER_IDS_JSON));
  const objectsJson: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_IMPORTANT_OBJECTS_JSON));
  const status: string = rs.getString(rs.getColumnIndex(COLUMN_SCENE_STATUS));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  return {
    id: id,
    worldId: worldId,
    name: name,
    location: location,
    timeDescription: timeDescription,
    description: description,
    presentCharacterIds: jsonParseArray(presentJson),
    importantObjects: jsonParseArray(objectsJson),
    status: parseSceneStatus(status),
    createdAt: createdAt
  };
}

// ===== WorldChatLink CRUD =====
function chatLinkToBucket(link: WorldChatLink): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_WCL_CHAT_ID] = link.chatId;
  bucket[COLUMN_WCL_WORLD_ID] = link.worldId;
  bucket[COLUMN_WCL_CURRENT_SCENE_ID] = link.currentSceneId !== null ? link.currentSceneId : null;
  bucket[COLUMN_WCL_REPLY_MODE] = link.replyMode;
  return bucket;
}

function chatLinkFromRow(rs: relationalStore.ResultSet): WorldChatLink {
  const chatId: string = rs.getString(rs.getColumnIndex(COLUMN_WCL_CHAT_ID));
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WCL_WORLD_ID));
  const sceneIdCol: number = rs.getColumnIndex(COLUMN_WCL_CURRENT_SCENE_ID);
  const currentSceneId: string | null =
    (sceneIdCol >= 0 && !rs.isColumnNull(sceneIdCol))
      ? rs.getString(sceneIdCol) : null;
  const replyMode: string = rs.getString(rs.getColumnIndex(COLUMN_WCL_REPLY_MODE));
  return {
    chatId: chatId,
    worldId: worldId,
    currentSceneId: currentSceneId,
    replyMode: parseReplyMode(replyMode)
  };
}

// ===== CharacterUserRelationship CRUD =====
function userRelToBucket(rel: CharacterUserRelationship): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = rel.id;
  bucket[COLUMN_MEMBER_WORLD_ID] = rel.worldId;
  bucket[COLUMN_CHAT_ID] = rel.chatId;
  bucket[COLUMN_BRANCH_ID] = rel.branchId;
  bucket[COLUMN_REL_CHARACTER_ID] = rel.characterId;
  bucket[COLUMN_RELATIONSHIP_LABEL] = rel.relationshipLabel;
  bucket[COLUMN_AFFINITY] = rel.affinity;
  bucket[COLUMN_TRUST] = rel.trust;
  bucket[COLUMN_RESPECT] = rel.respect;
  bucket[COLUMN_FEAR] = rel.fear;
  bucket[COLUMN_HOSTILITY] = rel.hostility;
  bucket[COLUMN_DEPENDENCY] = rel.dependency;
  bucket[COLUMN_FAMILIARITY] = rel.familiarity;
  bucket[COLUMN_CURRENT_EMOTION] = rel.currentEmotion;
  bucket[COLUMN_PRIVATE_OPINION] = rel.privateOpinion;
  bucket[COLUMN_SHARED_EXPERIENCES_JSON] = jsonStringify(rel.sharedExperiences as Object);
  bucket[COLUMN_PROMISES_JSON] = jsonStringify(rel.promises as Object);
  bucket[COLUMN_CONFLICTS_JSON] = jsonStringify(rel.conflicts as Object);
  bucket[COLUMN_SECRETS_FROM_USER_JSON] = jsonStringify(rel.secretsFromUser as Object);
  bucket[COLUMN_SECRETS_SHARED_BY_USER_JSON] = jsonStringify(rel.secretsSharedByUser as Object);
  bucket[COLUMN_USER_NAME_OVERRIDE] = rel.userNameOverride;
  bucket[COLUMN_LAST_UPDATED_MESSAGE_ID] = rel.lastUpdatedMessageId !== null ? rel.lastUpdatedMessageId : null;
  bucket[COLUMN_UPDATED_AT] = rel.updatedAt;
  return bucket;
}

function userRelFromRow(rs: relationalStore.ResultSet): CharacterUserRelationship {
  const lastMsgCol: number = rs.getColumnIndex(COLUMN_LAST_UPDATED_MESSAGE_ID);
  const lastMsgId: string | null =
    (lastMsgCol >= 0 && !rs.isColumnNull(lastMsgCol))
      ? rs.getString(lastMsgCol) : null;
  return {
    id: rs.getString(rs.getColumnIndex(COLUMN_ID)),
    worldId: rs.getString(rs.getColumnIndex(COLUMN_MEMBER_WORLD_ID)),
    chatId: rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID)),
    branchId: rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID)),
    characterId: rs.getString(rs.getColumnIndex(COLUMN_REL_CHARACTER_ID)),
    relationshipLabel: rs.getString(rs.getColumnIndex(COLUMN_RELATIONSHIP_LABEL)),
    affinity: rs.getLong(rs.getColumnIndex(COLUMN_AFFINITY)),
    trust: rs.getLong(rs.getColumnIndex(COLUMN_TRUST)),
    respect: rs.getLong(rs.getColumnIndex(COLUMN_RESPECT)),
    fear: rs.getLong(rs.getColumnIndex(COLUMN_FEAR)),
    hostility: rs.getLong(rs.getColumnIndex(COLUMN_HOSTILITY)),
    dependency: rs.getLong(rs.getColumnIndex(COLUMN_DEPENDENCY)),
    familiarity: rs.getLong(rs.getColumnIndex(COLUMN_FAMILIARITY)),
    currentEmotion: rs.getString(rs.getColumnIndex(COLUMN_CURRENT_EMOTION)),
    privateOpinion: rs.getString(rs.getColumnIndex(COLUMN_PRIVATE_OPINION)),
    sharedExperiences: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_SHARED_EXPERIENCES_JSON))),
    promises: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_PROMISES_JSON))),
    conflicts: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_CONFLICTS_JSON))),
    secretsFromUser: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_SECRETS_FROM_USER_JSON))),
    secretsSharedByUser: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_SECRETS_SHARED_BY_USER_JSON))),
    userNameOverride: rs.getString(rs.getColumnIndex(COLUMN_USER_NAME_OVERRIDE)),
    lastUpdatedMessageId: lastMsgId,
    updatedAt: rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT))
  };
}

// ===== CharacterRelationship CRUD =====
function charRelToBucket(rel: CharacterRelationship): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = rel.id;
  bucket[COLUMN_MEMBER_WORLD_ID] = rel.worldId;
  bucket[COLUMN_CHAT_ID] = rel.chatId;
  bucket[COLUMN_BRANCH_ID] = rel.branchId;
  bucket[COLUMN_SOURCE_CHARACTER_ID] = rel.sourceCharacterId;
  bucket[COLUMN_TARGET_CHARACTER_ID] = rel.targetCharacterId;
  bucket[COLUMN_RELATIONSHIP_LABEL] = rel.relationshipLabel;
  bucket[COLUMN_TRUST] = rel.trust;
  bucket[COLUMN_AFFINITY] = rel.affinity;
  bucket[COLUMN_HOSTILITY] = rel.hostility;
  bucket[COLUMN_CURRENT_EMOTION] = rel.currentEmotion;
  bucket[COLUMN_PRIVATE_OPINION] = rel.privateOpinion;
  bucket[COLUMN_SHARED_EXPERIENCES_JSON] = jsonStringify(rel.sharedExperiences as Object);
  bucket[COLUMN_PROMISES_JSON] = jsonStringify(rel.promises as Object);
  bucket[COLUMN_CONFLICTS_JSON] = jsonStringify(rel.conflicts as Object);
  bucket[COLUMN_KNOWN_SECRETS_JSON] = jsonStringify(rel.knownSecrets as Object);
  bucket[COLUMN_UPDATED_AT] = rel.updatedAt;
  return bucket;
}

function charRelFromRow(rs: relationalStore.ResultSet): CharacterRelationship {
  return {
    id: rs.getString(rs.getColumnIndex(COLUMN_ID)),
    worldId: rs.getString(rs.getColumnIndex(COLUMN_MEMBER_WORLD_ID)),
    chatId: rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID)),
    branchId: rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID)),
    sourceCharacterId: rs.getString(rs.getColumnIndex(COLUMN_SOURCE_CHARACTER_ID)),
    targetCharacterId: rs.getString(rs.getColumnIndex(COLUMN_TARGET_CHARACTER_ID)),
    relationshipLabel: rs.getString(rs.getColumnIndex(COLUMN_RELATIONSHIP_LABEL)),
    trust: rs.getLong(rs.getColumnIndex(COLUMN_TRUST)),
    affinity: rs.getLong(rs.getColumnIndex(COLUMN_AFFINITY)),
    hostility: rs.getLong(rs.getColumnIndex(COLUMN_HOSTILITY)),
    currentEmotion: rs.getString(rs.getColumnIndex(COLUMN_CURRENT_EMOTION)),
    privateOpinion: rs.getString(rs.getColumnIndex(COLUMN_PRIVATE_OPINION)),
    sharedExperiences: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_SHARED_EXPERIENCES_JSON))),
    promises: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_PROMISES_JSON))),
    conflicts: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_CONFLICTS_JSON))),
    knownSecrets: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_KNOWN_SECRETS_JSON))),
    updatedAt: rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT))
  };
}

// ===== WorldMemoryEvent CRUD =====
function eventToBucket(event: WorldMemoryEvent): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = event.id;
  bucket[COLUMN_MEMBER_WORLD_ID] = event.worldId;
  bucket[COLUMN_CHAT_ID] = event.chatId;
  bucket[COLUMN_BRANCH_ID] = event.branchId;
  bucket[COLUMN_SCENE_ID] = event.sceneId !== null ? event.sceneId : null;
  bucket[COLUMN_EVENT_PARTICIPANT_IDS_JSON] = jsonStringify(event.participantIds as Object);
  bucket[COLUMN_EVENT_WITNESS_IDS_JSON] = jsonStringify(event.witnessIds as Object);
  bucket[COLUMN_EVENT_INFORMED_IDS_JSON] = jsonStringify(event.informedCharacterIds as Object);
  bucket[COLUMN_EVENT_SUBJECT_CHARACTER_ID] = event.subjectCharacterId !== null ? event.subjectCharacterId : null;
  bucket[COLUMN_EVENT_RELATED_CHARACTER_IDS_JSON] = jsonStringify(event.relatedCharacterIds as Object);
  bucket[COLUMN_EVENT_VISIBILITY] = event.visibility;
  bucket[COLUMN_EVENT_SUMMARY] = event.summary;
  bucket[COLUMN_EVENT_START_MESSAGE_ID] = event.startMessageId !== null ? event.startMessageId : null;
  bucket[COLUMN_EVENT_END_MESSAGE_ID] = event.endMessageId !== null ? event.endMessageId : null;
  bucket[COLUMN_MEMORY_ENABLED] = booleanToInt(event.enabled);
  bucket[COLUMN_CREATED_AT] = event.createdAt;
  bucket[COLUMN_UPDATED_AT] = event.updatedAt;
  return bucket;
}

function eventFromRow(rs: relationalStore.ResultSet): WorldMemoryEvent {
  const sceneIdCol: number = rs.getColumnIndex(COLUMN_SCENE_ID);
  const sceneId: string | null =
    (sceneIdCol >= 0 && !rs.isColumnNull(sceneIdCol))
      ? rs.getString(sceneIdCol) : null;
  const subjectCol: number = rs.getColumnIndex(COLUMN_EVENT_SUBJECT_CHARACTER_ID);
  const subjectId: string | null =
    (subjectCol >= 0 && !rs.isColumnNull(subjectCol))
      ? rs.getString(subjectCol) : null;
  const startMsgCol: number = rs.getColumnIndex(COLUMN_EVENT_START_MESSAGE_ID);
  const startMsgId: string | null =
    (startMsgCol >= 0 && !rs.isColumnNull(startMsgCol))
      ? rs.getString(startMsgCol) : null;
  const endMsgCol: number = rs.getColumnIndex(COLUMN_EVENT_END_MESSAGE_ID);
  const endMsgId: string | null =
    (endMsgCol >= 0 && !rs.isColumnNull(endMsgCol))
      ? rs.getString(endMsgCol) : null;
  return {
    id: rs.getString(rs.getColumnIndex(COLUMN_ID)),
    worldId: rs.getString(rs.getColumnIndex(COLUMN_MEMBER_WORLD_ID)),
    chatId: rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID)),
    branchId: rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID)),
    sceneId: sceneId,
    participantIds: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_EVENT_PARTICIPANT_IDS_JSON))),
    witnessIds: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_EVENT_WITNESS_IDS_JSON))),
    informedCharacterIds: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_EVENT_INFORMED_IDS_JSON))),
    subjectCharacterId: subjectId,
    relatedCharacterIds: jsonParseArray(rs.getString(rs.getColumnIndex(COLUMN_EVENT_RELATED_CHARACTER_IDS_JSON))),
    visibility: parseVisibility(rs.getString(rs.getColumnIndex(COLUMN_EVENT_VISIBILITY))),
    summary: rs.getString(rs.getColumnIndex(COLUMN_EVENT_SUMMARY)),
    startMessageId: startMsgId,
    endMessageId: endMsgId,
    enabled: intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_ENABLED))),
    createdAt: rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT)),
    updatedAt: rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT))
  };
}

// ===== WorldPrivateMemory CRUD =====
function privateMemToBucket(mem: WorldPrivateMemory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = mem.id;
  bucket[COLUMN_MEMBER_WORLD_ID] = mem.worldId;
  bucket[COLUMN_CHAT_ID] = mem.chatId;
  bucket[COLUMN_BRANCH_ID] = mem.branchId;
  bucket[COLUMN_PRIVATE_MEMORY_CHARACTER_ID] = mem.characterId;
  bucket[COLUMN_SCENE_ID] = mem.sceneId !== null ? mem.sceneId : null;
  bucket[COLUMN_EVENT_SUMMARY] = mem.summary;
  bucket[COLUMN_EVENT_START_MESSAGE_ID] = mem.startMessageId !== null ? mem.startMessageId : null;
  bucket[COLUMN_EVENT_END_MESSAGE_ID] = mem.endMessageId !== null ? mem.endMessageId : null;
  bucket[COLUMN_MEMORY_ENABLED] = booleanToInt(mem.enabled);
  bucket[COLUMN_CREATED_AT] = mem.createdAt;
  bucket[COLUMN_UPDATED_AT] = mem.updatedAt;
  return bucket;
}

function privateMemFromRow(rs: relationalStore.ResultSet): WorldPrivateMemory {
  const sceneIdCol: number = rs.getColumnIndex(COLUMN_SCENE_ID);
  const sceneId: string | null =
    (sceneIdCol >= 0 && !rs.isColumnNull(sceneIdCol))
      ? rs.getString(sceneIdCol) : null;
  const startMsgCol: number = rs.getColumnIndex(COLUMN_EVENT_START_MESSAGE_ID);
  const startMsgId: string | null =
    (startMsgCol >= 0 && !rs.isColumnNull(startMsgCol))
      ? rs.getString(startMsgCol) : null;
  const endMsgCol: number = rs.getColumnIndex(COLUMN_EVENT_END_MESSAGE_ID);
  const endMsgId: string | null =
    (endMsgCol >= 0 && !rs.isColumnNull(endMsgCol))
      ? rs.getString(endMsgCol) : null;
  return {
    id: rs.getString(rs.getColumnIndex(COLUMN_ID)),
    worldId: rs.getString(rs.getColumnIndex(COLUMN_MEMBER_WORLD_ID)),
    chatId: rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID)),
    branchId: rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID)),
    characterId: rs.getString(rs.getColumnIndex(COLUMN_PRIVATE_MEMORY_CHARACTER_ID)),
    sceneId: sceneId,
    summary: rs.getString(rs.getColumnIndex(COLUMN_EVENT_SUMMARY)),
    startMessageId: startMsgId,
    endMessageId: endMsgId,
    enabled: intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_ENABLED))),
    createdAt: rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT)),
    updatedAt: rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT))
  };
}

/**
 * WorldRepository 主类。
 * 每个方法对应一个表的 CRUD,Service 层负责跨表事务。
 */
export class WorldRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  // ===== World =====
  async insertWorld(world: World): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLDS, worldToBucket(world));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('world.insert');
      }
      throw DatabaseError.queryFailed(`world.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertWorldWithStore(
    store: relationalStore.RdbStore,
    world: World
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLDS, worldToBucket(world));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('world.insert');
      }
      throw DatabaseError.queryFailed(`world.insert: ${extractCauseMessage(err)}`);
    }
  }

  async getWorld(id: string): Promise<World | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_WORLD_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return worldFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listWorlds(): Promise<World[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.orderByDesc(COLUMN_UPDATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const worlds: World[] = [];
      while (rs.goToNextRow()) {
        worlds.push(worldFromRow(rs));
      }
      return worlds;
    } finally {
      rs.close();
    }
  }

  async updateWorld(world: World): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_WORLD_ID, world.id);
    let affected: number;
    try {
      affected = await store.update(worldToBucket(world), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`world.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('world.update');
    }
  }

  async deleteWorld(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_WORLD_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`world.delete: ${extractCauseMessage(err)}`);
    }
  }

  // ===== WorldMember =====
  async insertMember(member: WorldMember): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_MEMBERS, memberToBucket(member));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('member.insert');
      }
      throw DatabaseError.queryFailed(`member.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertMemberWithStore(
    store: relationalStore.RdbStore,
    member: WorldMember
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_MEMBERS, memberToBucket(member));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('member.insert');
      }
      throw DatabaseError.queryFailed(`member.insert: ${extractCauseMessage(err)}`);
    }
  }

  async listMembersByWorld(worldId: string): Promise<WorldMember[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMBERS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.orderByAsc(COLUMN_MEMBER_DISPLAY_ORDER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const members: WorldMember[] = [];
      while (rs.goToNextRow()) {
        members.push(memberFromRow(rs));
      }
      return members;
    } finally {
      rs.close();
    }
  }

  async getMember(worldId: string, characterId: string): Promise<WorldMember | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMBERS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_MEMBER_CHARACTER_ID, characterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return memberFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async updateMember(member: WorldMember): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMBERS);
    predicates.equalTo(COLUMN_MEMBER_ID, member.id);
    let affected: number;
    try {
      affected = await store.update(memberToBucket(member), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`member.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('member.update');
    }
  }

  async deleteMember(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMBERS);
    predicates.equalTo(COLUMN_MEMBER_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`member.delete: ${extractCauseMessage(err)}`);
    }
  }

  // ===== WorldScene =====
  async insertScene(scene: WorldScene): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_SCENES, sceneToBucket(scene));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('scene.insert');
      }
      throw DatabaseError.queryFailed(`scene.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertSceneWithStore(
    store: relationalStore.RdbStore,
    scene: WorldScene
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_SCENES, sceneToBucket(scene));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('scene.insert');
      }
      throw DatabaseError.queryFailed(`scene.insert: ${extractCauseMessage(err)}`);
    }
  }

  async getScene(id: string): Promise<WorldScene | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_SCENE_ID_FULL, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return sceneFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listScenesByWorld(worldId: string): Promise<WorldScene[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_SCENE_WORLD_ID, worldId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const scenes: WorldScene[] = [];
      while (rs.goToNextRow()) {
        scenes.push(sceneFromRow(rs));
      }
      return scenes;
    } finally {
      rs.close();
    }
  }

  async updateScene(scene: WorldScene): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_SCENES);
    predicates.equalTo(COLUMN_SCENE_ID_FULL, scene.id);
    let affected: number;
    try {
      affected = await store.update(sceneToBucket(scene), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`scene.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('scene.update');
    }
  }

  // ===== WorldChatLink =====
  async insertChatLink(link: WorldChatLink): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_CHAT_LINKS, chatLinkToBucket(link));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('chatLink.insert');
      }
      throw DatabaseError.queryFailed(`chatLink.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertChatLinkWithStore(
    store: relationalStore.RdbStore,
    link: WorldChatLink
  ): Promise<void> {
    try {
      await store.insert(TABLE_WORLD_CHAT_LINKS, chatLinkToBucket(link));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('chatLink.insert');
      }
      throw DatabaseError.queryFailed(`chatLink.insert: ${extractCauseMessage(err)}`);
    }
  }

  async getChatLink(chatId: string): Promise<WorldChatLink | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHAT_LINKS);
    predicates.equalTo(COLUMN_WCL_CHAT_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return chatLinkFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async updateChatLink(link: WorldChatLink): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHAT_LINKS);
    predicates.equalTo(COLUMN_WCL_CHAT_ID, link.chatId);
    let affected: number;
    try {
      affected = await store.update(chatLinkToBucket(link), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`chatLink.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('chatLink.update');
    }
  }

  async listChatLinksByWorld(worldId: string): Promise<WorldChatLink[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHAT_LINKS);
    predicates.equalTo(COLUMN_WCL_WORLD_ID, worldId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const links: WorldChatLink[] = [];
      while (rs.goToNextRow()) {
        links.push(chatLinkFromRow(rs));
      }
      return links;
    } finally {
      rs.close();
    }
  }

  async deleteChatLink(chatId: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHAT_LINKS);
    predicates.equalTo(COLUMN_WCL_CHAT_ID, chatId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`chatLink.delete: ${extractCauseMessage(err)}`);
    }
  }

  // ===== CharacterUserRelationship =====
  async upsertUserRelationship(rel: CharacterUserRelationship): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_USER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, rel.worldId);
    predicates.equalTo(COLUMN_CHAT_ID, rel.chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, rel.branchId);
    predicates.equalTo(COLUMN_REL_CHARACTER_ID, rel.characterId);
    const existing: relationalStore.ResultSet = await store.query(predicates);
    let exists: boolean = false;
    try {
      exists = rs_count(existing) > 0;
    } finally {
      existing.close();
    }
    if (exists) {
      try {
        await store.update(userRelToBucket(rel), predicates);
      } catch (err) {
        throw DatabaseError.queryFailed(`userRel.update: ${extractCauseMessage(err)}`);
      }
    } else {
      try {
        await store.insert(TABLE_CHARACTER_USER_RELATIONSHIPS, userRelToBucket(rel));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('userRel.insert');
        }
        throw DatabaseError.queryFailed(`userRel.insert: ${extractCauseMessage(err)}`);
      }
    }
  }

  async getUserRelationship(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<CharacterUserRelationship | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_USER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.equalTo(COLUMN_REL_CHARACTER_ID, characterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return userRelFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listUserRelationships(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<CharacterUserRelationship[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_USER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const rels: CharacterUserRelationship[] = [];
      while (rs.goToNextRow()) {
        rels.push(userRelFromRow(rs));
      }
      return rels;
    } finally {
      rs.close();
    }
  }

  // ===== CharacterRelationship =====
  async upsertCharacterRelationship(rel: CharacterRelationship): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, rel.worldId);
    predicates.equalTo(COLUMN_CHAT_ID, rel.chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, rel.branchId);
    predicates.equalTo(COLUMN_SOURCE_CHARACTER_ID, rel.sourceCharacterId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_ID, rel.targetCharacterId);
    const existing: relationalStore.ResultSet = await store.query(predicates);
    let exists: boolean = false;
    try {
      exists = rs_count(existing) > 0;
    } finally {
      existing.close();
    }
    if (exists) {
      try {
        await store.update(charRelToBucket(rel), predicates);
      } catch (err) {
        throw DatabaseError.queryFailed(`charRel.update: ${extractCauseMessage(err)}`);
      }
    } else {
      try {
        await store.insert(TABLE_CHARACTER_RELATIONSHIPS, charRelToBucket(rel));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('charRel.insert');
        }
        throw DatabaseError.queryFailed(`charRel.insert: ${extractCauseMessage(err)}`);
      }
    }
  }

  async getCharacterRelationship(
    worldId: string,
    chatId: string,
    branchId: string,
    sourceCharacterId: string,
    targetCharacterId: string
  ): Promise<CharacterRelationship | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.equalTo(COLUMN_SOURCE_CHARACTER_ID, sourceCharacterId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_ID, targetCharacterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return charRelFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listCharacterRelationshipsBySource(
    worldId: string,
    chatId: string,
    branchId: string,
    sourceCharacterId: string
  ): Promise<CharacterRelationship[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.equalTo(COLUMN_SOURCE_CHARACTER_ID, sourceCharacterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const rels: CharacterRelationship[] = [];
      while (rs.goToNextRow()) {
        rels.push(charRelFromRow(rs));
      }
      return rels;
    } finally {
      rs.close();
    }
  }

  // ===== WorldMemoryEvent =====
  async insertMemoryEvent(event: WorldMemoryEvent): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_MEMORY_EVENTS, eventToBucket(event));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('event.insert');
      }
      throw DatabaseError.queryFailed(`event.insert: ${extractCauseMessage(err)}`);
    }
  }

  async listMemoryEvents(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<WorldMemoryEvent[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMORY_EVENTS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const events: WorldMemoryEvent[] = [];
      while (rs.goToNextRow()) {
        events.push(eventFromRow(rs));
      }
      return events;
    } finally {
      rs.close();
    }
  }

  async updateMemoryEvent(event: WorldMemoryEvent): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMORY_EVENTS);
    predicates.equalTo(COLUMN_ID, event.id);
    let affected: number;
    try {
      affected = await store.update(eventToBucket(event), predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`event.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('event.update');
    }
  }

  // ===== WorldPrivateMemory =====
  async insertPrivateMemory(mem: WorldPrivateMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_PRIVATE_MEMORIES, privateMemToBucket(mem));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('privateMemory.insert');
      }
      throw DatabaseError.queryFailed(`privateMemory.insert: ${extractCauseMessage(err)}`);
    }
  }

  async listPrivateMemoriesByCharacter(
    worldId: string,
    chatId: string,
    branchId: string,
    characterId: string
  ): Promise<WorldPrivateMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_PRIVATE_MEMORIES);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.equalTo(COLUMN_PRIVATE_MEMORY_CHARACTER_ID, characterId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const mems: WorldPrivateMemory[] = [];
      while (rs.goToNextRow()) {
        mems.push(privateMemFromRow(rs));
      }
      return mems;
    } finally {
      rs.close();
    }
  }

  // ===== RelationshipChangeRecord =====
  async insertChangeRecord(record: RelationshipChangeRecord): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertChangeRecordWithStore(store, record);
  }

  async insertChangeRecordWithStore(
    store: relationalStore.RdbStore,
    record: RelationshipChangeRecord
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_ID] = record.id;
    bucket[COLUMN_MEMBER_WORLD_ID] = record.worldId;
    bucket[COLUMN_CHAT_ID] = record.chatId;
    bucket[COLUMN_BRANCH_ID] = record.branchId;
    bucket[COLUMN_REL_CHARACTER_ID] = record.characterId;
    bucket[COLUMN_CHANGE_TARGET_CHARACTER_ID] = record.targetCharacterId !== null
      ? record.targetCharacterId : null;
    bucket[COLUMN_CHANGE_FIELD_NAME] = record.fieldName;
    bucket[COLUMN_CHANGE_OLD_VALUE] = record.oldValue;
    bucket[COLUMN_CHANGE_NEW_VALUE] = record.newValue;
    bucket[COLUMN_CHANGE_REASON] = record.reason;
    bucket[COLUMN_CHANGE_SOURCE_MESSAGE_ID] = record.sourceMessageId !== null
      ? record.sourceMessageId : null;
    bucket[COLUMN_CREATED_AT] = record.createdAt;
    try {
      await store.insert(TABLE_RELATIONSHIP_CHANGE_HISTORY, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('changeRecord.insert');
      }
      throw DatabaseError.queryFailed(`changeRecord.insert: ${extractCauseMessage(err)}`);
    }
  }

  async listChangeRecords(
    worldId: string,
    chatId: string,
    branchId: string
  ): Promise<RelationshipChangeRecord[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_RELATIONSHIP_CHANGE_HISTORY);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const records: RelationshipChangeRecord[] = [];
      while (rs.goToNextRow()) {
        records.push(changeRecordFromRow(rs));
      }
      return records;
    } finally {
      rs.close();
    }
  }

  // ===== WithStore 变体(供 Service 层事务组合使用) =====

  /**
   * 在给定 store 上 upsert 用户关系。
   * 用于 Service 层在事务中写入关系记录。
   */
  async upsertUserRelationshipWithStore(
    store: relationalStore.RdbStore,
    rel: CharacterUserRelationship
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_USER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, rel.worldId);
    predicates.equalTo(COLUMN_CHAT_ID, rel.chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, rel.branchId);
    predicates.equalTo(COLUMN_REL_CHARACTER_ID, rel.characterId);
    const existing: relationalStore.ResultSet = await store.query(predicates);
    let exists: boolean = false;
    try {
      exists = rs_count(existing) > 0;
    } finally {
      existing.close();
    }
    if (exists) {
      try {
        await store.update(userRelToBucket(rel), predicates);
      } catch (err) {
        throw DatabaseError.queryFailed(`userRel.update: ${extractCauseMessage(err)}`);
      }
    } else {
      try {
        await store.insert(TABLE_CHARACTER_USER_RELATIONSHIPS, userRelToBucket(rel));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('userRel.insert');
        }
        throw DatabaseError.queryFailed(`userRel.insert: ${extractCauseMessage(err)}`);
      }
    }
  }

  /**
   * 在给定 store 上 upsert 角色关系。
   */
  async upsertCharacterRelationshipWithStore(
    store: relationalStore.RdbStore,
    rel: CharacterRelationship
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTER_RELATIONSHIPS);
    predicates.equalTo(COLUMN_MEMBER_WORLD_ID, rel.worldId);
    predicates.equalTo(COLUMN_CHAT_ID, rel.chatId);
    predicates.equalTo(COLUMN_BRANCH_ID, rel.branchId);
    predicates.equalTo(COLUMN_SOURCE_CHARACTER_ID, rel.sourceCharacterId);
    predicates.equalTo(COLUMN_TARGET_CHARACTER_ID, rel.targetCharacterId);
    const existing: relationalStore.ResultSet = await store.query(predicates);
    let exists: boolean = false;
    try {
      exists = rs_count(existing) > 0;
    } finally {
      existing.close();
    }
    if (exists) {
      try {
        await store.update(charRelToBucket(rel), predicates);
      } catch (err) {
        throw DatabaseError.queryFailed(`charRel.update: ${extractCauseMessage(err)}`);
      }
    } else {
      try {
        await store.insert(TABLE_CHARACTER_RELATIONSHIPS, charRelToBucket(rel));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('charRel.insert');
        }
        throw DatabaseError.queryFailed(`charRel.insert: ${extractCauseMessage(err)}`);
      }
    }
  }

  /**
   * 在给定 store 上删除指定成员记录(仅 world_members 表)。
   * 不级联删除关系/记忆,Service 层负责协调。
   */
  async deleteMemberWithStore(
    store: relationalStore.RdbStore,
    memberId: string
  ): Promise<void> {
    if (memberId.length === 0) {
      throw DatabaseError.invalidData('memberId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_MEMBERS);
    predicates.equalTo(COLUMN_MEMBER_ID, memberId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`member.delete: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在给定 store 上级联删除世界及其全部相关数据。
   * 顺序:relationship_change_history → world_private_memories → world_memory_events →
   *       character_relationships → character_user_relationships → world_chat_links →
   *       world_scenes → world_members → worlds
   * 注意:不删除关联 Chat/Message(仅断开 world_chat_links),保留为普通单角色对话。
   */
  async deleteWorldWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    if (worldId.length === 0) {
      throw DatabaseError.invalidData('worldId empty');
    }
    const tables: string[] = [
      TABLE_RELATIONSHIP_CHANGE_HISTORY,
      TABLE_WORLD_PRIVATE_MEMORIES,
      TABLE_WORLD_MEMORY_EVENTS,
      TABLE_CHARACTER_RELATIONSHIPS,
      TABLE_CHARACTER_USER_RELATIONSHIPS,
      TABLE_WORLD_CHAT_LINKS,
      TABLE_WORLD_SCENES,
      TABLE_WORLD_MEMBERS,
      TABLE_WORLDS
    ];
    for (let i = 0; i < tables.length; i++) {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(tables[i]);
      predicates.equalTo(COLUMN_MEMBER_WORLD_ID, worldId);
      try {
        await store.delete(predicates);
      } catch (err) {
        throw DatabaseError.queryFailed(
          `world.cascade.delete[${tables[i]}]: ${extractCauseMessage(err)}`
        );
      }
    }
  }
}

function changeRecordFromRow(rs: relationalStore.ResultSet): RelationshipChangeRecord {
  const targetCol: number = rs.getColumnIndex(COLUMN_CHANGE_TARGET_CHARACTER_ID);
  const targetId: string | null =
    (targetCol >= 0 && !rs.isColumnNull(targetCol))
      ? rs.getString(targetCol) : null;
  const srcMsgCol: number = rs.getColumnIndex(COLUMN_CHANGE_SOURCE_MESSAGE_ID);
  const srcMsgId: string | null =
    (srcMsgCol >= 0 && !rs.isColumnNull(srcMsgCol))
      ? rs.getString(srcMsgCol) : null;
  return {
    id: rs.getString(rs.getColumnIndex(COLUMN_ID)),
    worldId: rs.getString(rs.getColumnIndex(COLUMN_MEMBER_WORLD_ID)),
    chatId: rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID)),
    branchId: rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID)),
    characterId: rs.getString(rs.getColumnIndex(COLUMN_REL_CHARACTER_ID)),
    targetCharacterId: targetId,
    fieldName: rs.getString(rs.getColumnIndex(COLUMN_CHANGE_FIELD_NAME)),
    oldValue: rs.getString(rs.getColumnIndex(COLUMN_CHANGE_OLD_VALUE)),
    newValue: rs.getString(rs.getColumnIndex(COLUMN_CHANGE_NEW_VALUE)),
    reason: rs.getString(rs.getColumnIndex(COLUMN_CHANGE_REASON)),
    sourceMessageId: srcMsgId,
    createdAt: rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT))
  };
}

function rs_count(rs: relationalStore.ResultSet): number {
  let count: number = 0;
  while (rs.goToNextRow()) {
    count++;
  }
  return count;
}
