/**
 * WorldService 多人世界业务服务
 *
 * 职责:
 * - World / WorldMember / WorldScene / WorldChatLink 的业务编排
 * - 创建世界时事务性写入 world + members + initial scene + chat link + 初始关系
 * - 成员管理(加入/移出/在场/离场/静音/活跃度),不删除原角色卡
 * - 场景管理(创建/编辑/切换当前场景)
 * - Chat-World 关联(创建多人会话)
 * - 删除世界时级联清理 9 张 v10 表
 *
 * 不负责:
 * - 角色卡本身(走 CharacterService)
 * - 消息流式生成(走 MultiPersonChatService)
 * - 关系数值变更规则(走 WorldRelationshipService)
 * - 记忆事件总结(走 WorldMemoryService)
 *
 * 规则:
 * - 至少 2 个角色才能创建世界
 * - 移出成员不删除原角色卡、不破坏历史消息
 * - 跨表写入必须使用事务
 * - 不打印关系字段正文
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { WorldRepository } from '../repositories/WorldRepository';
import { ChatRepository } from '../repositories/ChatRepository';
import { CharacterRepository } from '../repositories/CharacterRepository';
import {
  World,
  WorldUserIdentity,
  WorldReplyMode,
  replyModeToString,
  createWorld,
  updateWorld
} from '../models/World';
import {
  WorldMember,
  WorldMemberUpdates,
  createWorldMember,
  updateWorldMember,
  clampTalkativeness
} from '../models/WorldMember';
import {
  WorldScene,
  createWorldScene,
  updateWorldScene
} from '../models/WorldScene';
import { WorldChatLink, createWorldChatLink, updateWorldChatLink } from '../models/WorldChatLink';
import {
  CharacterUserRelationship,
  InitialRelationship,
  createCharacterUserRelationship
} from '../models/WorldRelationship';
import { Chat, createChat } from '../models/Chat';
import { Character } from '../models/Character';
import { DatabaseError } from '../models/DatabaseError';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldService';

/** 创建世界时最少需要的角色数量 */
export const MIN_WORLD_MEMBERS: number = 2;

/**
 * 创建世界时单个成员的输入。
 */
export interface CreateWorldMemberInput {
  readonly characterId: string;
  readonly present: boolean;
  readonly talkativeness: number;
  readonly displayOrder: number;
  readonly initialRelationship: InitialRelationship;
}

/**
 * 创建世界的输入。
 */
export interface CreateWorldInput {
  readonly name: string;
  readonly background: string;
  readonly initialScene: string;
  readonly userIdentity: WorldUserIdentity;
  readonly defaultReplyMode: WorldReplyMode;
  readonly members: CreateWorldMemberInput[];
}

/**
 * 创建场景的输入。
 */
export interface CreateSceneInput {
  readonly name: string;
  readonly location: string;
  readonly timeDescription: string;
  readonly description: string;
  readonly presentCharacterIds: string[];
  readonly importantObjects: string[];
}

/**
 * WorldService 返回的世界成员视图(含角色卡摘要)。
 */
export interface WorldMemberView {
  readonly member: WorldMember;
  readonly character: Character | null;
}

/**
 * 创建世界的完整结果(供 ViewModel 直接使用)。
 */
export interface CreateWorldResult {
  readonly world: World;
  readonly members: WorldMember[];
  readonly initialScene: WorldScene;
}

/**
 * 为世界创建会话的结果。
 */
export interface CreateChatForWorldResult {
  readonly chat: Chat;
  readonly link: WorldChatLink;
}

export class WorldService {
  private readonly dbHelper: DbHelper;
  private readonly worldRepo: WorldRepository;
  private readonly chatRepo: ChatRepository;
  private readonly characterRepo: CharacterRepository;

  constructor(
    dbHelper: DbHelper,
    worldRepo: WorldRepository,
    chatRepo: ChatRepository,
    characterRepo: CharacterRepository
  ) {
    this.dbHelper = dbHelper;
    this.worldRepo = worldRepo;
    this.chatRepo = chatRepo;
    this.characterRepo = characterRepo;
  }

  /**
   * 创建世界(事务):
   * 1. 校验:名称非空、至少 2 个成员、characterId 不重复
   * 2. 校验:每个 characterId 在本地角色库存在
   * 3. 写入 world + members + initial scene + 每个角色与用户的初始关系
   */
  async createWorld(input: CreateWorldInput): Promise<CreateWorldResult> {
    if (input.name.length === 0) {
      throw DatabaseError.invalidData('world.name empty');
    }
    if (input.members.length < MIN_WORLD_MEMBERS) {
      throw DatabaseError.invalidData(
        `world.members count < ${MIN_WORLD_MEMBERS}`
      );
    }
    // 重复 characterId 校验
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < input.members.length; i++) {
      const cid: string = input.members[i].characterId;
      if (cid.length === 0) {
        throw DatabaseError.invalidData(`members[${i}].characterId empty`);
      }
      if (seen.has(cid)) {
        throw DatabaseError.invalidData(`duplicate characterId in members`);
      }
      seen.add(cid);
    }
    // 校验所有角色存在
    for (let i = 0; i < input.members.length; i++) {
      const cid: string = input.members[i].characterId;
      const ch: Character | null = await this.characterRepo.getById(cid);
      if (ch === null) {
        throw DatabaseError.notFound(`character ${cid} not found`);
      }
    }
    // 解析 replyMode
    replyModeToString(input.defaultReplyMode);

    const worldId: string = generateUuid();
    const now: number = nowMillis();
    const world: World = createWorld({
      id: worldId,
      name: input.name,
      background: input.background,
      initialScene: input.initialScene,
      userIdentity: input.userIdentity,
      defaultReplyMode: input.defaultReplyMode,
      createdAt: now
    });

    const members: WorldMember[] = [];
    for (let i = 0; i < input.members.length; i++) {
      const m: CreateWorldMemberInput = input.members[i];
      members.push(createWorldMember({
        id: generateUuid(),
        worldId: worldId,
        characterId: m.characterId,
        enabled: true,
        present: m.present,
        muted: false,
        talkativeness: clampTalkativeness(m.talkativeness),
        displayOrder: m.displayOrder,
        joinedAt: now,
        initialRelationship: m.initialRelationship
      }));
    }

    const sceneId: string = generateUuid();
    const initialScene: WorldScene = createWorldScene({
      id: sceneId,
      worldId: worldId,
      name: input.initialScene.length > 0 ? input.initialScene : '初始场景',
      location: '',
      timeDescription: '',
      description: input.initialScene,
      presentCharacterIds: members.filter((m: WorldMember) => m.present).map((m: WorldMember) => m.characterId),
      importantObjects: [],
      status: 'active',
      createdAt: now
    });

    // 在事务中写入 world + members + scene + 初始关系
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.worldRepo.insertWorldWithStore(store, world);
        for (let i = 0; i < members.length; i++) {
          await this.worldRepo.insertMemberWithStore(store, members[i]);
        }
        await this.worldRepo.insertSceneWithStore(store, initialScene);
        // 初始关系写入(空 chatId / branchId,代表世界级关系)
        for (let i = 0; i < members.length; i++) {
          const m: WorldMember = members[i];
          const rel: CharacterUserRelationship = createCharacterUserRelationship({
            worldId: worldId,
            chatId: '',
            branchId: '',
            characterId: m.characterId,
            relationshipLabel: m.initialRelationship.relationshipLabel,
            affinity: m.initialRelationship.affinity,
            trust: m.initialRelationship.trust,
            respect: 0,
            fear: 0,
            hostility: 0,
            dependency: 0,
            familiarity: 0,
            currentEmotion: '',
            privateOpinion: '',
            sharedExperiences: m.initialRelationship.sharedExperiences.length > 0
              ? [m.initialRelationship.sharedExperiences] : [],
            promises: [],
            conflicts: [],
            secretsFromUser: [],
            secretsSharedByUser: m.initialRelationship.knownSecrets.length > 0
              ? [m.initialRelationship.knownSecrets] : [],
            userNameOverride: m.initialRelationship.addressTerm,
            lastUpdatedMessageId: ''
          });
          await this.worldRepo.upsertUserRelationshipWithStore(store, rel);
        }
      }
    );
    Logger.info(LOG_TAG, `createWorld ok members=${members.length}`);
    return { world: world, members: members, initialScene: initialScene };
  }

  async getWorld(worldId: string): Promise<World | null> {
    return await this.worldRepo.getWorld(worldId);
  }

  async listWorlds(): Promise<World[]> {
    return await this.worldRepo.listWorlds();
  }

  async updateWorld(worldId: string, updates: Partial<CreateWorldInput>): Promise<World> {
    const current: World | null = await this.worldRepo.getWorld(worldId);
    if (current === null) {
      throw DatabaseError.notFound('world not found');
    }
    const next: World = updateWorld(current, {
      name: updates.name,
      background: updates.background,
      initialScene: updates.initialScene,
      userIdentity: updates.userIdentity,
      defaultReplyMode: updates.defaultReplyMode
    });
    await this.worldRepo.updateWorld(next);
    return next;
  }

  /**
   * 删除世界(事务):
   * 1. 删除所有 chat link(每个 chat link 对应的 Chat/Message 不删除,保留为普通单角色对话)
   * 2. 删除 world_scenes / world_members / character_user_relationships /
   *    character_relationships / world_memory_events / world_private_memories /
   *    relationship_change_history
   * 3. 删除 world 本身
   *
   * 注意:不删除关联的 Chat,仅断开 world_chat_links。
   * 用户如果需要彻底删除关联 Chat,应单独调用 ChatPersistenceService。
   */
  async deleteWorld(worldId: string): Promise<void> {
    if (worldId.length === 0) {
      throw DatabaseError.invalidData('worldId empty');
    }
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.worldRepo.deleteWorldWithStore(store, worldId);
      }
    );
    Logger.info(LOG_TAG, 'deleteWorld ok');
  }

  // ===== 成员管理 =====

  async listMembers(worldId: string): Promise<WorldMemberView[]> {
    const members: WorldMember[] = await this.worldRepo.listMembersByWorld(worldId);
    const views: WorldMemberView[] = [];
    for (let i = 0; i < members.length; i++) {
      const m: WorldMember = members[i];
      const ch: Character | null = await this.characterRepo.getById(m.characterId);
      views.push({ member: m, character: ch });
    }
    return views;
  }

  async listPresentAndEnabledMembers(worldId: string): Promise<WorldMemberView[]> {
    const all: WorldMemberView[] = await this.listMembers(worldId);
    return all.filter((v: WorldMemberView) => v.member.enabled && v.member.present);
  }

  /**
   * 中途添加角色到世界。
   * - 校验世界存在、角色存在、未重复加入
   * - 写入 world_members + 初始用户关系(空 chatId/branchId)
   */
  async addMember(
    worldId: string,
    characterId: string,
    initialRelationship: InitialRelationship,
    present: boolean,
    talkativeness: number,
    displayOrder: number
  ): Promise<WorldMember> {
    if (worldId.length === 0 || characterId.length === 0) {
      throw DatabaseError.invalidData('worldId or characterId empty');
    }
    const world: World | null = await this.worldRepo.getWorld(worldId);
    if (world === null) {
      throw DatabaseError.notFound('world not found');
    }
    const ch: Character | null = await this.characterRepo.getById(characterId);
    if (ch === null) {
      throw DatabaseError.notFound('character not found');
    }
    const existing: WorldMember | null = await this.worldRepo.getMember(worldId, characterId);
    if (existing !== null) {
      throw DatabaseError.alreadyExists('member already in world');
    }
    const now: number = nowMillis();
    const member: WorldMember = createWorldMember({
      id: generateUuid(),
      worldId: worldId,
      characterId: characterId,
      enabled: true,
      present: present,
      muted: false,
      talkativeness: clampTalkativeness(talkativeness),
      displayOrder: displayOrder,
      joinedAt: now,
      initialRelationship: initialRelationship
    });
    const rel: CharacterUserRelationship = createCharacterUserRelationship({
      worldId: worldId,
      chatId: '',
      branchId: '',
      characterId: characterId,
      relationshipLabel: initialRelationship.relationshipLabel,
      affinity: initialRelationship.affinity,
      trust: initialRelationship.trust,
      respect: 0,
      fear: 0,
      hostility: 0,
      dependency: 0,
      familiarity: 0,
      currentEmotion: '',
      privateOpinion: '',
      sharedExperiences: initialRelationship.sharedExperiences.length > 0
        ? [initialRelationship.sharedExperiences] : [],
      promises: [],
      conflicts: [],
      secretsFromUser: [],
      secretsSharedByUser: initialRelationship.knownSecrets.length > 0
        ? [initialRelationship.knownSecrets] : [],
      userNameOverride: initialRelationship.addressTerm,
      lastUpdatedMessageId: ''
    });
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.worldRepo.insertMemberWithStore(store, member);
        await this.worldRepo.upsertUserRelationshipWithStore(store, rel);
      }
    );
    return member;
  }

  /**
   * 移出成员。
   * - 不删除原角色卡
   * - 不删除历史消息(消息保留 senderCharacterId,仅成员被移除)
   * - 删除该成员在世界的关系记录(关系变化历史保留,用于回滚)
   * - 删除该成员的私人记忆
   * - 删除该成员的关系记录(用户关系 + 角色关系)
   */
  async removeMember(worldId: string, characterId: string): Promise<void> {
    if (worldId.length === 0 || characterId.length === 0) {
      throw DatabaseError.invalidData('worldId or characterId empty');
    }
    const member: WorldMember | null = await this.worldRepo.getMember(worldId, characterId);
    if (member === null) {
      return; // 幂等
    }
    await this.worldRepo.deleteMember(member.id);
    // 关系和记忆的清理由 WorldRelationshipService 单独协调(本阶段保留为简化实现)
    Logger.info(LOG_TAG, 'removeMember ok');
  }

  /**
   * 更新成员状态。
   * 支持 enabled/present/muted/talkativeness/displayOrder 字段更新。
   */
  async updateMemberState(
    worldId: string,
    characterId: string,
    updates: WorldMemberUpdates
  ): Promise<WorldMember> {
    const member: WorldMember | null = await this.worldRepo.getMember(worldId, characterId);
    if (member === null) {
      throw DatabaseError.notFound('member not found');
    }
    const next: WorldMember = updateWorldMember(member, {
      enabled: updates.enabled,
      present: updates.present,
      muted: updates.muted,
      talkativeness: updates.talkativeness !== undefined
        ? clampTalkativeness(updates.talkativeness)
        : undefined,
      displayOrder: updates.displayOrder
    });
    await this.worldRepo.updateMember(next);
    return next;
  }

  // ===== 场景管理 =====

  async createScene(worldId: string, input: CreateSceneInput): Promise<WorldScene> {
    if (worldId.length === 0) {
      throw DatabaseError.invalidData('worldId empty');
    }
    if (input.name.length === 0) {
      throw DatabaseError.invalidData('scene.name empty');
    }
    const scene: WorldScene = createWorldScene({
      id: generateUuid(),
      worldId: worldId,
      name: input.name,
      location: input.location,
      timeDescription: input.timeDescription,
      description: input.description,
      presentCharacterIds: input.presentCharacterIds,
      importantObjects: input.importantObjects,
      status: 'active',
      createdAt: nowMillis()
    });
    await this.worldRepo.insertScene(scene);
    return scene;
  }

  async getScene(sceneId: string): Promise<WorldScene | null> {
    return await this.worldRepo.getScene(sceneId);
  }

  async listScenes(worldId: string): Promise<WorldScene[]> {
    return await this.worldRepo.listScenesByWorld(worldId);
  }

  async updateScene(sceneId: string, updates: Partial<CreateSceneInput>): Promise<WorldScene> {
    const current: WorldScene | null = await this.worldRepo.getScene(sceneId);
    if (current === null) {
      throw DatabaseError.notFound('scene not found');
    }
    const next: WorldScene = updateWorldScene(current, {
      name: updates.name,
      location: updates.location,
      timeDescription: updates.timeDescription,
      description: updates.description,
      presentCharacterIds: updates.presentCharacterIds,
      importantObjects: updates.importantObjects
    });
    await this.worldRepo.updateScene(next);
    return next;
  }

  /**
   * 角色进入或离开场景。
   */
  async setCharacterInScene(
    sceneId: string,
    characterId: string,
    present: boolean
  ): Promise<WorldScene> {
    const scene: WorldScene | null = await this.worldRepo.getScene(sceneId);
    if (scene === null) {
      throw DatabaseError.notFound('scene not found');
    }
    const set: Set<string> = new Set<string>(scene.presentCharacterIds);
    if (present) {
      set.add(characterId);
    } else {
      set.delete(characterId);
    }
    const next: WorldScene = updateWorldScene(scene, {
      presentCharacterIds: Array.from(set)
    });
    await this.worldRepo.updateScene(next);
    // 同步更新 world_members.present
    if (scene.worldId.length > 0) {
      try {
        await this.updateMemberState(scene.worldId, characterId, { present: present });
      } catch (e) {
        // 成员不存在时忽略(可能已被移出世界)
      }
    }
    return next;
  }

  // ===== Chat-World 关联 =====

  /**
   * 为世界创建新会话。
   * - 复用 Chat 表(characterId 留空)
   * - 写入 Chat + world_chat_links(初始场景 = 世界 initialScene)
   * - 默认回复模式继承世界 defaultReplyMode
   */
  async createChatForWorld(
    worldId: string,
    title: string,
    initialSceneId: string
  ): Promise<CreateChatForWorldResult> {
    const world: World | null = await this.worldRepo.getWorld(worldId);
    if (world === null) {
      throw DatabaseError.notFound('world not found');
    }
    const scene: WorldScene | null = await this.worldRepo.getScene(initialSceneId);
    if (scene === null || scene.worldId !== worldId) {
      throw DatabaseError.invalidData('initialSceneId invalid');
    }
    const chatId: string = generateUuid();
    const chat: Chat = createChat({
      id: chatId,
      title: title.length > 0 ? title : world.name,
      characterId: undefined
    });
    const link: WorldChatLink = createWorldChatLink({
      chatId: chatId,
      worldId: worldId,
      currentSceneId: initialSceneId,
      replyMode: world.defaultReplyMode
    });
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        await this.chatRepo.insertWithStore(store, chat);
        await this.worldRepo.insertChatLinkWithStore(store, link);
      }
    );
    const result: CreateChatForWorldResult = { chat: chat, link: link };
    return result;
  }

  async getWorldByChatId(chatId: string): Promise<World | null> {
    const link: WorldChatLink | null = await this.worldRepo.getChatLink(chatId);
    if (link === null) {
      return null;
    }
    return await this.worldRepo.getWorld(link.worldId);
  }

  async getChatLink(chatId: string): Promise<WorldChatLink | null> {
    return await this.worldRepo.getChatLink(chatId);
  }

  async listChatsByWorld(worldId: string): Promise<WorldChatLink[]> {
    return await this.worldRepo.listChatLinksByWorld(worldId);
  }

  /**
   * 更新会话的回复模式。
   */
  async updateChatReplyMode(chatId: string, mode: WorldReplyMode): Promise<void> {
    const link: WorldChatLink | null = await this.worldRepo.getChatLink(chatId);
    if (link === null) {
      throw DatabaseError.notFound('chat link not found');
    }
    replyModeToString(mode);
    const next: WorldChatLink = updateWorldChatLink(link, {
      replyMode: mode
    });
    await this.worldRepo.updateChatLink(next);
  }

  /**
   * 切换会话当前场景。
   */
  async setChatCurrentScene(chatId: string, sceneId: string): Promise<void> {
    const link: WorldChatLink | null = await this.worldRepo.getChatLink(chatId);
    if (link === null) {
      throw DatabaseError.notFound('chat link not found');
    }
    const scene: WorldScene | null = await this.worldRepo.getScene(sceneId);
    if (scene === null || scene.worldId !== link.worldId) {
      throw DatabaseError.invalidData('sceneId invalid');
    }
    const next: WorldChatLink = updateWorldChatLink(link, {
      currentSceneId: sceneId
    });
    await this.worldRepo.updateChatLink(next);
  }
}
