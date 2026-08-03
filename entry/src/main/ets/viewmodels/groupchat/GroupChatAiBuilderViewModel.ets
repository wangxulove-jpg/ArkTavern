/**
 * GroupChatAiBuilderViewModel AI 建群页面状态管理(G-AI-BUILDER-1)
 *
 * 职责:
 * - 从 CharacterService 读取真实角色列表
 * - 维护候选角色选择(2~12,用于 AI 筛选)
 * - 维护群聊描述输入
 * - 调用 GroupChatDraftBuilderService 生成草案
 * - 维护草案状态(Idle/Generating/Ready/Failed)
 * - 允许用户编辑草案(标题/成员顺序/增删/开场消息)
 * - 确认创建时调用 GroupConversationPersistenceService.createGroupConversation
 *
 * 不依赖:ArkUI 装饰器(供 Page 使用 @Observed)。
 * 不直接写入:messages / 轮次 / 运行时。
 *
 * 草案与正式数据隔离:
 * - 生成结果只保存在 ViewModel 内存状态
 * - 只有用户点击"确认创建"才写入数据库
 */

import { Character } from '../../models/Character';
import { Chat } from '../../models/Chat';
import { CharacterService } from '../../services/CharacterService';
import { GroupConversationPersistenceService } from '../../services/groupchat/GroupConversationPersistenceService';
import { GroupChatDraftBuilderService } from '../../services/groupchat/builder/GroupChatDraftBuilderService';
import {
  GroupChatDraftCandidate,
  GeneratedGroupChatDraft,
  GroupChatDraftState,
  GroupChatDraftError,
  GroupChatDraftErrorType,
  MIN_CANDIDATE_COUNT,
  MAX_CANDIDATE_COUNT,
  MIN_DRAFT_MEMBER_COUNT,
  MAX_DRAFT_MEMBER_COUNT,
  MAX_OPENING_MESSAGE_LENGTH,
  MAX_DRAFT_TITLE_LENGTH
} from '../../services/groupchat/builder/GroupChatDraftTypes';
import { AppServices } from '../../services/AppServices';
import { Logger } from '../../utils/Logger';
import { CharacterPickState } from './GroupChatUiModels';

const LOG_TAG: string = 'GroupAiBuilderVM';

/**
 * 草案成员 UI 项(含角色信息,用于显示与排序调整)。
 */
export interface DraftMemberItem {
  readonly characterId: string;
  readonly name: string;
  readonly avatarUri: string;
}

@Observed
export class GroupChatAiBuilderViewModel {
  /** 全部角色列表 */
  characters: Character[] = [];
  /** 角色列表加载状态 */
  pickState: CharacterPickState = CharacterPickState.Loading;
  /** 已选候选角色 ID 列表(去重,数组形式确保 ArkUI 响应式) */
  selectedCandidateIds: string[] = [];
  /** 群聊描述输入 */
  description: string = '';
  /** 草案状态 */
  draftState: GroupChatDraftState = GroupChatDraftState.Idle;
  /** 草案标题(可编辑) */
  draftTitle: string = '';
  /** 草案成员列表(可调整顺序/增删) */
  draftMembers: DraftMemberItem[] = [];
  /** 推荐理由 */
  draftRationale: string = '';
  /** 开场消息草案(可编辑/删除) */
  draftOpeningMessage: string = '';
  /** 用户可读错误提示 */
  errorMessage: string = '';
  /** 是否正在创建正式群聊(防止重复提交) */
  isCreating: boolean = false;

  private readonly characterService: CharacterService;
  private readonly groupService: GroupConversationPersistenceService;
  private readonly builderService: GroupChatDraftBuilderService;
  private disposed: boolean = false;

  constructor() {
    this.characterService = AppServices.getCharacterService();
    this.groupService = AppServices.getGroupConversationPersistenceService();
    this.builderService = new GroupChatDraftBuilderService(
      AppServices.getModelService(), this.characterService
    );
  }

  /** 加载真实角色列表 */
  async loadCharacters(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.pickState = CharacterPickState.Loading;
    try {
      const list: Character[] = await this.characterService.list();
      this.characters = list;
      if (list.length === 0) {
        this.pickState = CharacterPickState.Empty;
      } else {
        this.pickState = CharacterPickState.Ready;
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'loadCharacters failed: ' + String(e));
      this.pickState = CharacterPickState.Error;
    }
  }

  // ===== 候选选择 =====

  /** 切换候选角色选择状态(2~12) */
  toggleCandidate(characterId: string): void {
    if (this.draftState === GroupChatDraftState.Generating || this.isCreating) {
      return;
    }
    const idx: number = this.selectedCandidateIds.indexOf(characterId);
    if (idx >= 0) {
      this.selectedCandidateIds = this.selectedCandidateIds.filter(
        (id: string): boolean => id !== characterId
      );
    } else {
      if (this.selectedCandidateIds.length >= MAX_CANDIDATE_COUNT) {
        this.errorMessage = '最多选择 ' + String(MAX_CANDIDATE_COUNT) + ' 个候选角色';
        return;
      }
      this.selectedCandidateIds = [...this.selectedCandidateIds, characterId];
    }
    this.errorMessage = '';
  }

  /** 判断是否已选为候选 */
  isCandidateSelected(characterId: string): boolean {
    return this.selectedCandidateIds.indexOf(characterId) >= 0;
  }

  /** 已选候选数量 */
  selectedCandidateCount(): number {
    return this.selectedCandidateIds.length;
  }

  /** 是否可以生成草案(候选 2~12 且非生成中) */
  canGenerate(): boolean {
    const count: number = this.selectedCandidateIds.length;
    return count >= MIN_CANDIDATE_COUNT
      && count <= MAX_CANDIDATE_COUNT
      && this.draftState !== GroupChatDraftState.Generating
      && !this.isCreating;
  }

  // ===== 描述输入 =====

  /** 更新描述 */
  updateDescription(text: string): void {
    this.description = text;
  }

  // ===== 草案生成 =====

  /** 是否正在生成 */
  isGenerating(): boolean {
    return this.builderService.isGenerating();
  }

  /**
   * 生成草案。
   * 失败时设置 errorMessage 和 draftState=Failed,保留描述和候选选择。
   */
  async generateDraft(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (!this.canGenerate()) {
      return;
    }
    this.draftState = GroupChatDraftState.Generating;
    this.errorMessage = '';
    try {
      const selectedChars: Character[] = this.getSelectedCharacters();
      const candidates: GroupChatDraftCandidate[] =
        GroupChatDraftBuilderService.buildCandidates(selectedChars);
      const draft: GeneratedGroupChatDraft =
        await this.builderService.generateDraft(this.description, candidates);
      if (this.disposed) {
        return;
      }
      // 填充草案状态
      this.draftTitle = draft.title;
      this.draftMembers = this.mapToDraftMembers(draft.orderedCharacterIds);
      this.draftRationale = draft.rationale;
      this.draftOpeningMessage = draft.openingMessage;
      this.draftState = GroupChatDraftState.Ready;
      Logger.info(LOG_TAG, 'draft ready members=' + String(this.draftMembers.length));
    } catch (e) {
      if (this.disposed) {
        return;
      }
      if (e instanceof GroupChatDraftError) {
        if (e.errorType === GroupChatDraftErrorType.Cancelled) {
          // 取消后回到 Idle,保留描述和候选
          this.draftState = GroupChatDraftState.Idle;
          this.errorMessage = '';
        } else {
          this.draftState = GroupChatDraftState.Failed;
          this.errorMessage = this.mapErrorMessage(e);
        }
      } else {
        this.draftState = GroupChatDraftState.Failed;
        this.errorMessage = '生成失败';
      }
      Logger.error(LOG_TAG, 'generateDraft failed: ' + String(e));
    }
  }

  /** 停止生成 */
  cancelGeneration(): void {
    this.builderService.cancel();
  }

  // ===== 草案编辑 =====

  /** 更新草案标题 */
  updateDraftTitle(text: string): void {
    if (this.draftState !== GroupChatDraftState.Ready) {
      return;
    }
    this.draftTitle = text.length > MAX_DRAFT_TITLE_LENGTH
      ? text.substring(0, MAX_DRAFT_TITLE_LENGTH) : text;
  }

  /** 更新开场消息 */
  updateOpeningMessage(text: string): void {
    if (this.draftState !== GroupChatDraftState.Ready) {
      return;
    }
    this.draftOpeningMessage = text.length > MAX_OPENING_MESSAGE_LENGTH
      ? text.substring(0, MAX_OPENING_MESSAGE_LENGTH) : text;
  }

  /** 上移成员 */
  moveMemberUp(characterId: string): void {
    if (this.draftState !== GroupChatDraftState.Ready) {
      return;
    }
    const idx: number = this.findMemberIndex(characterId);
    if (idx <= 0) {
      return;
    }
    const next: DraftMemberItem[] = this.draftMembers.slice();
    const tmp: DraftMemberItem = next[idx];
    next[idx] = next[idx - 1];
    next[idx - 1] = tmp;
    this.draftMembers = next;
  }

  /** 下移成员 */
  moveMemberDown(characterId: string): void {
    if (this.draftState !== GroupChatDraftState.Ready) {
      return;
    }
    const idx: number = this.findMemberIndex(characterId);
    if (idx < 0 || idx >= this.draftMembers.length - 1) {
      return;
    }
    const next: DraftMemberItem[] = this.draftMembers.slice();
    const tmp: DraftMemberItem = next[idx];
    next[idx] = next[idx + 1];
    next[idx + 1] = tmp;
    this.draftMembers = next;
  }

  /**
   * 从候选池添加成员到草案。
   * 仅允许添加已选候选且不在草案中的角色。
   * 不超过 MAX_DRAFT_MEMBER_COUNT。
   */
  addMember(characterId: string): boolean {
    if (this.draftState !== GroupChatDraftState.Ready) {
      return false;
    }
    if (this.selectedCandidateIds.indexOf(characterId) < 0) {
      this.errorMessage = '该角色不在候选列表中';
      return false;
    }
    if (this.findMemberIndex(characterId) >= 0) {
      return false;
    }
    if (this.draftMembers.length >= MAX_DRAFT_MEMBER_COUNT) {
      this.errorMessage = '草案最多 ' + String(MAX_DRAFT_MEMBER_COUNT) + ' 位成员';
      return false;
    }
    const c: Character | undefined = this.findCharacter(characterId);
    if (c === undefined) {
      this.errorMessage = '角色不存在';
      return false;
    }
    this.draftMembers = [...this.draftMembers, {
      characterId: c.id,
      name: c.name,
      avatarUri: c.avatarUri
    }];
    this.errorMessage = '';
    return true;
  }

  /** 从草案移除成员(不少于 MIN_DRAFT_MEMBER_COUNT) */
  removeMember(characterId: string): boolean {
    if (this.draftState !== GroupChatDraftState.Ready) {
      return false;
    }
    if (this.draftMembers.length <= MIN_DRAFT_MEMBER_COUNT) {
      this.errorMessage = '草案至少 ' + String(MIN_DRAFT_MEMBER_COUNT) + ' 位成员';
      return false;
    }
    this.draftMembers = this.draftMembers.filter(
      (m: DraftMemberItem): boolean => m.characterId !== characterId
    );
    this.errorMessage = '';
    return true;
  }

  // ===== 确认创建 =====

  /** 是否可以确认创建(草案 Ready,成员 2~8,非创建中) */
  canConfirmCreate(): boolean {
    return this.draftState === GroupChatDraftState.Ready
      && this.draftMembers.length >= MIN_DRAFT_MEMBER_COUNT
      && this.draftMembers.length <= MAX_DRAFT_MEMBER_COUNT
      && !this.isCreating;
  }

  /**
   * 确认创建正式群聊。
   * @returns 新建群聊 ID,失败抛错
   */
  async confirmCreate(): Promise<string> {
    if (this.disposed) {
      throw new Error('disposed');
    }
    if (this.isCreating) {
      throw new Error('creating');
    }
    if (!this.canConfirmCreate()) {
      throw new Error('当前状态不允许创建');
    }
    const title: string = this.draftTitle.trim();
    if (title.length === 0) {
      throw new Error('群聊名称不能为空');
    }
    const orderedIds: string[] = this.draftMembers.map(
      (m: DraftMemberItem): string => m.characterId
    );
    this.isCreating = true;
    this.errorMessage = '';
    try {
      const chat: Chat = await this.groupService.createGroupConversation(title, orderedIds);
      Logger.info(LOG_TAG, 'created chatId');
      return chat.id;
    } catch (e) {
      Logger.error(LOG_TAG, 'confirmCreate failed: ' + String(e));
      this.errorMessage = '创建群聊失败';
      throw new Error(String(e));
    } finally {
      this.isCreating = false;
    }
  }

  // ===== 生命周期 =====

  /**
   * 销毁 ViewModel,停止生成。
   * 页面 aboutToDisappear 时调用。
   */
  disposeWithStop(): void {
    this.disposed = true;
    this.builderService.cancel();
  }

  // ===== 内部方法 =====

  /** 获取已选候选角色列表(按 characters 数组顺序) */
  private getSelectedCharacters(): Character[] {
    const result: Character[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      if (this.selectedCandidateIds.indexOf(this.characters[i].id) >= 0) {
        result.push(this.characters[i]);
      }
    }
    return result;
  }

  /** 按 ID 查找角色 */
  private findCharacter(id: string): Character | undefined {
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].id === id) {
        return this.characters[i];
      }
    }
    return undefined;
  }

  /** 将角色 ID 列表映射为 DraftMemberItem */
  private mapToDraftMembers(orderedIds: string[]): DraftMemberItem[] {
    const result: DraftMemberItem[] = [];
    for (let i = 0; i < orderedIds.length; i++) {
      const c: Character | undefined = this.findCharacter(orderedIds[i]);
      if (c !== undefined) {
        result.push({
          characterId: c.id,
          name: c.name,
          avatarUri: c.avatarUri
        });
      }
    }
    return result;
  }

  /** 查找成员在草案中的索引 */
  private findMemberIndex(characterId: string): number {
    for (let i = 0; i < this.draftMembers.length; i++) {
      if (this.draftMembers[i].characterId === characterId) {
        return i;
      }
    }
    return -1;
  }

  /** 将错误类型映射为用户可读提示(不含敏感信息) */
  private mapErrorMessage(e: GroupChatDraftError): string {
    switch (e.errorType) {
      case GroupChatDraftErrorType.CandidatesInsufficient:
        return '至少选择 ' + String(MIN_CANDIDATE_COUNT) + ' 个候选角色';
      case GroupChatDraftErrorType.CandidatesExcessive:
        return '最多选择 ' + String(MAX_CANDIDATE_COUNT) + ' 个候选角色';
      case GroupChatDraftErrorType.CharacterDeleted:
        return '部分候选角色已被删除,请重新选择';
      case GroupChatDraftErrorType.NoModelConfig:
        return '未选择模型配置,请先在设置中配置';
      case GroupChatDraftErrorType.AuthenticationFailed:
        return '模型认证失败,请检查 API Key';
      case GroupChatDraftErrorType.NetworkFailed:
        return '网络请求失败,请检查网络';
      case GroupChatDraftErrorType.JsonInvalid:
        return 'AI 返回的草案格式无效,请重新生成';
      case GroupChatDraftErrorType.MemberCountInvalid:
        return 'AI 选择的成员数量无效,请重新生成';
      case GroupChatDraftErrorType.OutOfPoolMember:
        return 'AI 选择了候选池外的角色,请重新生成';
      case GroupChatDraftErrorType.CreateFailed:
        return '创建群聊失败';
      default:
        return '生成失败,请重试';
    }
  }
}
