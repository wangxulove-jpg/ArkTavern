/**
 * WorldCharacterMemoryViewModel 多人世界角色记忆 ViewModel
 *
 * 职责:
 * - 加载世界全部成员(角色头像列表)
 * - 选中某个角色后加载其各类记忆:
 *   * 私人记忆(WorldPrivateMemory)
 *   * 已知事件(WorldMemoryEvent: subject=该角色)
 *   * 与用户的共同经历(WorldMemoryEvent: visibility=participants 且 subject 或 participant 包含该角色)
 *   * 角色关系(CharacterRelationship: source=该角色)
 * - 加载公共世界记忆(WorldMemoryEvent: visibility=public)单独展示
 * - 支持刷新(页面进入 / 切换角色 / onShow / 手动刷新)
 * - 区分空状态:尚未产生 / 加载中 / 加载失败
 * - 脱敏日志:只打印 worldId/branchId/characterId 前缀 + 数量,不打印正文
 *
 * 不负责:
 * - 触发记忆生成(由 MultiPersonChatService 在整轮完成后异步调用 WorldMemoryService)
 * - 写入/修改记忆(由 WorldMemoryService 处理)
 * - 关系变更(由 WorldRelationshipService 处理)
 *
 * 路由参数:{ worldId: string, chatId: string, branchId: string }
 */

import { Character } from '../models/Character';
import { WorldMember } from '../models/WorldMember';
import { WorldService, WorldMemberView } from '../services/WorldService';
import { WorldMemoryService } from '../services/WorldMemoryService';
import { WorldRelationshipService } from '../services/WorldRelationshipService';
import {
  WorldMemoryEvent,
  WorldPrivateMemory,
  MemoryVisibility
} from '../models/WorldMemory';
import {
  CharacterUserRelationship,
  CharacterRelationship
} from '../models/WorldRelationship';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldCharMemoryVM';

/** 记忆展示项(统一格式,供 UI 渲染) */
export interface MemoryDisplayItem {
  readonly id: string;
  /** 记忆类型:private / known_event / shared_with_user / public / relationship */
  readonly kind: MemoryKind;
  /** 摘要正文 */
  readonly summary: string;
  /** 所属场景 ID(可能为空) */
  readonly sceneId: string;
  /** 来源消息 ID 范围(start - end) */
  readonly startMessageId: string;
  readonly endMessageId: string;
  /** 可见范围文本 */
  readonly visibilityLabel: string;
  /** 创建时间戳 */
  readonly createdAt: number;
  /** 是否有效 */
  readonly enabled: boolean;
}

export type MemoryKind = 'private' | 'known_event' | 'shared_with_user' | 'public' | 'relationship';

/** 空状态类型 */
export type MemoryEmptyState =
  | 'not_loaded'
  | 'loading'
  | 'no_memories'
  | 'query_failed';

/** 角色头像展示项 */
export interface CharacterAvatarItem {
  readonly characterId: string;
  readonly character: Character | null;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly member: WorldMember;
  readonly isCurrent: boolean;
}

@Observed
export class WorldCharacterMemoryViewModel {
  // ===== 路由参数 =====
  worldId: string = '';
  chatId: string = '';
  branchId: string = '';

  // ===== 成员列表 =====
  members: CharacterAvatarItem[] = [];
  selectedCharacterId: string = '';

  // ===== 记忆数据 =====
  privateMemories: MemoryDisplayItem[] = [];
  knownEvents: MemoryDisplayItem[] = [];
  sharedExperiences: MemoryDisplayItem[] = [];
  publicMemories: MemoryDisplayItem[] = [];
  relationshipMemories: MemoryDisplayItem[] = [];
  userRelationship: CharacterUserRelationship | null = null;

  // ===== 状态 =====
  loadState: MemoryEmptyState = 'not_loaded';
  errorMessage: string = '';
  /** 上次查询的总数(诊断用) */
  lastTotalCount: number = 0;
  /** 上次被 enabled/visibility 过滤掉的数量(诊断用) */
  lastFilteredCount: number = 0;
  /** 上次查询时间戳 */
  lastQueryAt: number = 0;

  /** 页面订阅回调 */
  onDataUpdate?: () => void;

  private readonly worldService: WorldService;
  private readonly worldMemoryService: WorldMemoryService;
  private readonly worldRelationshipService: WorldRelationshipService;
  private disposed: boolean = false;

  constructor(
    worldService: WorldService,
    worldMemoryService: WorldMemoryService,
    worldRelationshipService: WorldRelationshipService
  ) {
    this.worldService = worldService;
    this.worldMemoryService = worldMemoryService;
    this.worldRelationshipService = worldRelationshipService;
  }

  /**
   * 初始化 ViewModel。
   * 加载成员列表 + 默认选中第一个在场角色 + 加载其记忆。
   */
  async initialize(worldId: string, chatId: string, branchId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.worldId = worldId;
    this.chatId = chatId;
    this.branchId = branchId;
    Logger.info(
      LOG_TAG,
      `initialize wid=${worldId.substring(0, 4)} cid=${chatId.substring(0, 4)} bid=${branchId.substring(0, 4)}`
    );
    await this.loadMembers();
    if (this.members.length > 0) {
      this.selectedCharacterId = this.members[0].characterId;
      await this.loadMemoriesForCurrent();
    } else {
      this.loadState = 'no_memories';
      this.notifyUpdate();
    }
  }

  /** 加载世界全部成员 */
  private async loadMembers(): Promise<void> {
    if (this.disposed) return;
    try {
      const views: WorldMemberView[] = await this.worldService.listMembers(this.worldId);
      const items: CharacterAvatarItem[] = views.map((v: WorldMemberView): CharacterAvatarItem => {
        const ch: Character | null = v.character;
        const item: CharacterAvatarItem = {
          characterId: v.member.characterId,
          character: ch,
          displayName: ch !== null ? ch.name : '未知角色',
          avatarUri: ch !== null ? ch.avatarUri : '',
          member: v.member,
          isCurrent: v.member.characterId === this.selectedCharacterId
        };
        return item;
      });
      this.members = items;
      Logger.info(LOG_TAG, `loadMembers ok count=${items.length}`);
    } catch (e) {
      Logger.warn(LOG_TAG, `loadMembers failed: ${(e as Error).message}`);
      this.errorMessage = '加载角色列表失败: ' + (e as Error).message;
    }
  }

  /** 切换当前选中角色 */
  async selectCharacter(characterId: string): Promise<void> {
    if (this.disposed) return;
    if (characterId === this.selectedCharacterId) {
      return;
    }
    this.selectedCharacterId = characterId;
    // 更新 isCurrent 标志
    for (let i = 0; i < this.members.length; i++) {
      const m: CharacterAvatarItem = this.members[i];
      const isCurrent: boolean = m.characterId === characterId;
      if (m.isCurrent !== isCurrent) {
        const updated: CharacterAvatarItem = {
          characterId: m.characterId,
          character: m.character,
          displayName: m.displayName,
          avatarUri: m.avatarUri,
          member: m.member,
          isCurrent: isCurrent
        };
        this.members[i] = updated;
      }
    }
    await this.loadMemoriesForCurrent();
  }

  /** 加载当前选中角色的全部记忆 */
  async loadMemoriesForCurrent(): Promise<void> {
    if (this.disposed) return;
    if (this.selectedCharacterId.length === 0) {
      this.loadState = 'no_memories';
      this.notifyUpdate();
      return;
    }
    this.loadState = 'loading';
    this.errorMessage = '';
    this.notifyUpdate();

    const cid: string = this.selectedCharacterId;
    const wid: string = this.worldId;
    const chid: string = this.chatId;
    const bid: string = this.branchId;
    Logger.info(
      LOG_TAG,
      `query wid=${wid.substring(0, 4)} bid=${bid.substring(0, 4)} cid=${cid.substring(0, 4)}`
    );

    try {
      // 顺序加载各类记忆(ArkTS 不支持数组解构声明,顺序调用更直观)
      const privateMems: WorldPrivateMemory[] =
        await this.worldMemoryService.listPrivateMemoriesForCharacter(wid, chid, bid, cid);
      if (this.disposed) return;
      const knownEvts: WorldMemoryEvent[] =
        await this.worldMemoryService.listKnownEventsForCharacter(wid, chid, bid, cid);
      if (this.disposed) return;
      const sharedEvts: WorldMemoryEvent[] =
        await this.worldMemoryService.listSharedExperiencesWithUser(wid, chid, bid, cid);
      if (this.disposed) return;
      const publicEvts: WorldMemoryEvent[] =
        await this.worldMemoryService.listPublicEvents(wid, chid, bid);
      if (this.disposed) return;
      const charRels: CharacterRelationship[] =
        await this.worldRelationshipService.listCharacterRelationshipsBySource(wid, chid, bid, cid);
      if (this.disposed) return;
      const userRel: CharacterUserRelationship | null =
        await this.worldRelationshipService.getUserRelationship(wid, chid, bid, cid);
      if (this.disposed) return;

      // 记录过滤诊断:统计被 enabled=false 过滤的数量(在 service 层已过滤,这里只统计总数)
      const totalRaw: number = privateMems.length + knownEvts.length + sharedEvts.length + publicEvts.length;
      this.lastTotalCount = totalRaw;
      this.lastFilteredCount = 0;  // service 层已过滤,此处未知
      this.lastQueryAt = Date.now();

      this.privateMemories = privateMems.map((m: WorldPrivateMemory): MemoryDisplayItem => this.privateMemoryToItem(m));
      this.knownEvents = knownEvts.map((e: WorldMemoryEvent): MemoryDisplayItem => this.eventToItem(e, 'known_event'));
      this.sharedExperiences = sharedEvts.map((e: WorldMemoryEvent): MemoryDisplayItem => this.eventToItem(e, 'shared_with_user'));
      this.publicMemories = publicEvts.map((e: WorldMemoryEvent): MemoryDisplayItem => this.eventToItem(e, 'public'));
      this.relationshipMemories = charRels.map((r: CharacterRelationship): MemoryDisplayItem => this.relationshipToItem(r));
      this.userRelationship = userRel;

      const total: number = this.privateMemories.length
        + this.knownEvents.length
        + this.sharedExperiences.length
        + this.publicMemories.length
        + this.relationshipMemories.length;

      if (total === 0) {
        this.loadState = 'no_memories';
      } else {
        this.loadState = 'not_loaded';  // 表示已有数据
      }

      Logger.info(
        LOG_TAG,
        `query ok private=${privateMems.length} known=${knownEvts.length} shared=${sharedEvts.length} public=${publicEvts.length} rel=${charRels.length} userRel=${userRel !== null ? 1 : 0}`
      );
      this.notifyUpdate();
    } catch (e) {
      if (this.disposed) return;
      Logger.warn(LOG_TAG, `query failed: ${(e as Error).message}`);
      this.loadState = 'query_failed';
      this.errorMessage = '加载记忆失败: ' + (e as Error).message;
      this.notifyUpdate();
    }
  }

  /** 手动刷新(重新加载当前角色记忆) */
  async refresh(): Promise<void> {
    await this.loadMemoriesForCurrent();
  }

  /** 重新加载成员列表(用于成员变更后) */
  async reloadMembers(): Promise<void> {
    await this.loadMembers();
    if (this.selectedCharacterId.length > 0) {
      await this.loadMemoriesForCurrent();
    }
  }

  private privateMemoryToItem(m: WorldPrivateMemory): MemoryDisplayItem {
    const item: MemoryDisplayItem = {
      id: m.id,
      kind: 'private',
      summary: m.summary,
      sceneId: m.sceneId !== null ? m.sceneId : '',
      startMessageId: m.startMessageId !== null ? m.startMessageId : '',
      endMessageId: m.endMessageId !== null ? m.endMessageId : '',
      visibilityLabel: '私人',
      createdAt: m.createdAt,
      enabled: m.enabled
    };
    return item;
  }

  private eventToItem(e: WorldMemoryEvent, kind: MemoryKind): MemoryDisplayItem {
    const item: MemoryDisplayItem = {
      id: e.id,
      kind: kind,
      summary: e.summary,
      sceneId: e.sceneId !== null ? e.sceneId : '',
      startMessageId: e.startMessageId !== null ? e.startMessageId : '',
      endMessageId: e.endMessageId !== null ? e.endMessageId : '',
      visibilityLabel: this.visibilityLabel(e.visibility),
      createdAt: e.createdAt,
      enabled: e.enabled
    };
    return item;
  }

  private relationshipToItem(r: CharacterRelationship): MemoryDisplayItem {
    // 将关系记录转为展示项:摘要由 label + emotion 组成(不打印 privateOpinion)
    const parts: string[] = [];
    if (r.relationshipLabel.length > 0) {
      parts.push(`关系: ${r.relationshipLabel}`);
    }
    if (r.currentEmotion.length > 0) {
      parts.push(`情绪: ${r.currentEmotion}`);
    }
    parts.push(`信任=${r.trust} 好感=${r.affinity} 敌意=${r.hostility}`);
    if (r.sharedExperiences.length > 0) {
      parts.push(`共同经历: ${r.sharedExperiences.length} 条`);
    }
    if (r.promises.length > 0) {
      parts.push(`承诺: ${r.promises.length} 条`);
    }
    if (r.conflicts.length > 0) {
      parts.push(`冲突: ${r.conflicts.length} 条`);
    }
    if (r.knownSecrets.length > 0) {
      parts.push(`已知秘密: ${r.knownSecrets.length} 条`);
    }
    const item: MemoryDisplayItem = {
      id: r.id,
      kind: 'relationship',
      summary: parts.join('\n'),
      sceneId: '',
      startMessageId: '',
      endMessageId: '',
      visibilityLabel: '角色关系',
      createdAt: r.updatedAt,
      enabled: true
    };
    return item;
  }

  private visibilityLabel(v: MemoryVisibility): string {
    switch (v) {
      case 'public': return '公开';
      case 'participants': return '参与者可见';
      case 'private': return '私人';
      case 'narrator_only': return '仅旁白';
      default: return v;
    }
  }

  private notifyUpdate(): void {
    if (this.disposed) return;
    if (this.onDataUpdate !== undefined) {
      this.onDataUpdate();
    }
  }

  dispose(): void {
    this.disposed = true;
    this.members = [];
    this.privateMemories = [];
    this.knownEvents = [];
    this.sharedExperiences = [];
    this.publicMemories = [];
    this.relationshipMemories = [];
  }
}
