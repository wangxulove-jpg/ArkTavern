/**
 * GroupCharacterMemoryPage 多人聊天角色记忆页(G-MEMORY-1A / G-MEMORY-1A-FIX-UI)
 *
 * 职责:
 * - 显示角色头部(头像/名称/所属群聊/成员状态/记忆总数)
 * - 列出该角色在某群聊中的独立记忆(全部/活跃/已归档)
 * - 手动新增 / 编辑 / 归档 / 恢复 / 删除 记忆
 * - Interaction 记忆只读,不显示编辑/删除入口
 * - 角色被移出群聊时记忆仍可查看,但禁止新增(canCreateMemory=false)
 * - 角色卡缺失时安全降级显示"角色已删除"
 *
 * 所有权语义:
 * - 记忆严格属于 (groupConversationId, characterId)
 * - 不同群聊中同一角色的记忆完全隔离
 * - 删除群聊时同事务级联清理(由 ChatPersistenceOperations 负责)
 *
 * 路由:通过 AppStorage PENDING_GROUP_MEMORY_GROUP_ID_KEY +
 *      PENDING_GROUP_MEMORY_CHARACTER_ID_KEY 传参,读取后清除。
 *
 * 写入调用 GroupCharacterMemoryService(经 ViewModel),不直接访问 Repository。
 * 视觉参考单聊 MemoryManagementPage(Stack 覆盖层模式),
 * 但不复用其 Service / ViewModel / branchId。
 *
 * G-MEMORY-1A-FIX-UI 根因修复:
 * 旧实现使用 bindSheet,在该设备上 Sheet 打开后约 500ms 自动触发 onDisappear
 * (formMode 仍为 Create),导致"闪一下"现象。
 * 改为 Stack 覆盖层(参考单聊 MemoryManagementPage 的 clearConfirmDialog 模式),
 * 避免使用 bindSheet,彻底规避自动关闭问题。
 * 表单状态从 formMode 单状态改为 formVisible + formMode 双状态,
 * 显示状态只在用户操作中改变,不在 build/Builder/load 中重置。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  GroupCharacterMemoryViewModel,
  GroupCharacterMemoryLoadState,
  GroupCharacterMemoryListFilter,
  GroupCharacterMemberStatus,
  GroupCharacterMemoryHeaderUiModel,
  GroupCharacterMemoryItemUiModel,
  CreateGroupMemoryFormInput,
  UpdateGroupMemoryFormInput,
  RelationshipListItemUiModel,
  RelationshipCandidateUiModel,
  UpdateRelationshipMemoryFormInput,
  RELATIONSHIP_MEMORY_IMPORTANCE_MIN,
  RELATIONSHIP_MEMORY_IMPORTANCE_MAX,
  RELATIONSHIP_MEMORY_IMPORTANCE_DEFAULT,
  RELATIONSHIP_EXPERIENCE_MAX,
  RELATIONSHIP_ATTITUDE_MAX,
  RELATIONSHIP_SUMMARY_MAX,
  GROUP_MEMORY_IMPORTANCE_MIN,
  GROUP_MEMORY_IMPORTANCE_MAX,
  GROUP_MEMORY_IMPORTANCE_DEFAULT,
  GROUP_MEMORY_TITLE_MAX,
  GROUP_MEMORY_CONTENT_MAX,
  GroupCharacterSwitcherItemUiModel
} from '../../viewmodels/groupchat/GroupCharacterMemoryViewModel';
import {
  PENDING_GROUP_MEMORY_GROUP_ID_KEY,
  PENDING_GROUP_MEMORY_CHARACTER_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { GroupPromptInspectionSnapshot,
  PromptMessageInspectionItem,
  RelationshipInspectionItem,
  TokenBudgetInspection,
  HistoryVisibilityInspectionItem,
  GroupCharacterMemorySelection,
  SelectedPersonalMemory,
  ExcludedPersonalMemory,
  SelectedRelationshipMemory,
  ExcludedRelationshipMemory,
  GroupCharacterMemoryExclusionReason,
  GroupCharacterRelationshipExclusionReason,
  RelationshipSelectionTargetSource,
  MemoryInjectionInspectionItem,
  RelationshipInjectionInspectionItem
} from '../../models/groupchat/GroupPromptInspectionModels';
import {
  GroupCharacterMemory,
  GroupCharacterMemoryOrigin,
  GroupCharacterMemoryStatus
} from '../../models/groupchat/GroupCharacterMemory';
import {
  GroupCharacterRelationshipMemory,
  GroupRelationshipMemoryStatus,
  GroupRelationshipTargetType
} from '../../models/groupchat/GroupCharacterRelationshipMemory';
import {
  GroupAutoSummaryDetailLevel,
  GroupAutoSummarySettings,
  GroupAutoSummaryPlan,
  getGroupAutoSummaryLevelSpec
} from '../../models/groupchat/GroupAutoSummaryModels';
import { CharacterImageView } from '../../components/CharacterImageView';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharacterMemoryPage';

/** 表单模式(仅当 formVisible=true 时有意义) */
enum GroupMemoryFormMode {
  Create,
  Edit
}

/** 页面视图模式:记忆列表 / 关系与经历列表 / 上下文检查 */
enum PageViewMode {
  Memory,
  Relationship,
  ContextInspector
}

@Entry
@Component
struct GroupCharacterMemoryPage {
  @State private viewModel: GroupCharacterMemoryViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: GroupCharacterMemoryLoadState = GroupCharacterMemoryLoadState.Loading;
  @State private errorMessage: string = '';
  @State private memories: GroupCharacterMemoryItemUiModel[] = [];
  @State private header: GroupCharacterMemoryHeaderUiModel | null = null;

  // G-MEMORY-UI-2: 角色切换
  @State private members: GroupCharacterSwitcherItemUiModel[] = [];
  @State private selectedCharacterId: string = '';
  @State private hasNoMembers: boolean = false;

  @State private filter: GroupCharacterMemoryListFilter = GroupCharacterMemoryListFilter.Active;

  // 表单显示状态(G-MEMORY-1A-FIX-UI:从 formMode 单状态拆分为双状态)
  // formVisible 控制表单 Stack 覆盖层是否显示
  // formMode 仅在 formVisible=true 时决定是新增还是编辑
  // 这两个状态只在用户点击(新增/编辑/取消/保存成功)时改变,
  // 不在 build/Builder/loadSnapshot/syncFromViewModel 中重置。
  @State private formVisible: boolean = false;
  @State private formMode: GroupMemoryFormMode = GroupMemoryFormMode.Create;
  @State private editingMemoryId: string = '';
  // G-MEMORY-AUTO-1A-FIX-2: 标记当前编辑的是否为自动总结记忆
  // true → submitForm 调用 updateApprovedSelfSummary
  // false → submitForm 调用 updateMemory(Manual)
  @State private editingMemoryIsSelfSummary: boolean = false;
  @State private formTitle: string = '';
  @State private formContent: string = '';
  @State private formImportance: number = GROUP_MEMORY_IMPORTANCE_DEFAULT;
  @State private formKeywords: string = '';
  @State private formError: string = '';
  @State private isSaving: boolean = false;
  @State private isDeleting: boolean = false;
  @State private actionError: string = '';

  // 删除确认(独立 Stack 覆盖层,与表单互斥)
  @State private deletingMemoryId: string = '';
  // G-MEMORY-AUTO-1A-FIX-2: 标记当前删除的是否为自动总结记忆
  // true → handleDelete 调用 deleteApprovedSelfSummary
  // false → handleDelete 调用 deleteMemory(Manual)
  @State private deletingMemoryIsSelfSummary: boolean = false;

  // G-MEMORY-AUTO-1A-FIX-2: 详情覆盖层(独立 Stack,与表单/删除/总结互斥)
  // 点击卡片整卡打开详情,详情内提供 修改/归档 入口
  @State private detailVisible: boolean = false;
  @State private detailMemoryId: string = '';
  // 当前详情显示的记忆(在 openDetail 时设置,loadSnapshot 后刷新)
  @State private detailMemory: GroupCharacterMemoryItemUiModel | null = null;

  // G-MEMORY-AUTO-1A 自动总结审核窗口(独立 Stack 覆盖层,与表单/删除互斥)
  // summaryVisible 控制覆盖层显示;draft 字段在 ViewModel 中,本地保留编辑中的字段
  // isSummarizing/isApprovingSummary 从 ViewModel 同步(每次 summary 操作后手动同步)
  @State private summaryVisible: boolean = false;
  @State private summaryTitle: string = '';
  @State private summaryContent: string = '';
  @State private summaryImportance: number = GROUP_MEMORY_IMPORTANCE_DEFAULT;
  @State private summaryKeywords: string = '';
  @State private summaryFormError: string = '';
  @State private isSummarizing: boolean = false;
  @State private isApprovingSummaryState: boolean = false;

  // G-MEMORY-AUTO-1B 关系与经历
  // viewMode: 当前页面视图(记忆 / 关系)
  // relationshipList: 关系记忆列表(从 ViewModel 同步)
  // relationshipReviewVisible: 关系候选审核窗口
  // relationshipDetailVisible: 关系详情窗口
  // relationshipEditVisible: 关系编辑表单窗口
  // relationshipCandidates: 当前审核中的候选(本地可编辑副本)
  // isPreparingRelationship / isApprovingRelationship: 从 ViewModel 同步
  @State private viewMode: PageViewMode = PageViewMode.Memory;
  @State private relationshipList: RelationshipListItemUiModel[] = [];
  @State private isRelationshipListLoading: boolean = false;
  @State private relationshipActionError: string = '';
  @State private relationshipReviewVisible: boolean = false;
  @State private relationshipCandidates: RelationshipCandidateUiModel[] = [];
  @State private isPreparingRelationship: boolean = false;
  @State private isApprovingRelationship: boolean = false;
  @State private relationshipReviewError: string = '';
  @State private relationshipDetailVisible: boolean = false;
  @State private relationshipDetailId: string = '';
  @State private relationshipDetail: RelationshipListItemUiModel | null = null;
  @State private relationshipEditVisible: boolean = false;
  @State private editingRelationshipId: string = '';
  @State private relFormExperience: string = '';
  @State private relFormAttitude: string = '';
  @State private relFormRelationship: string = '';
  @State private relFormImportance: number = RELATIONSHIP_MEMORY_IMPORTANCE_DEFAULT;
  @State private relFormKeywords: string = '';
  @State private relFormError: string = '';

  // G-CONTEXT-INSPECTOR-1: 上下文检查状态
  @State private inspectionSnapshot: GroupPromptInspectionSnapshot | null = null;
  @State private isInspectionLoading: boolean = false;
  // G-CONTEXT-INSPECTOR-1: 上下文调整状态
  @State private contextWindowInput: string = '';
  @State private isContextAdjustLoaded: boolean = false;
  @State private isSavingContextWindow: boolean = false;
  @State private contextAdjustMessage: string = '';
  @State private contextAdjustIsError: boolean = false;

  // G-GROUP-AUTO-SUMMARY-1A: 自动总结诊断状态
  @State private autoSummarySettings: GroupAutoSummarySettings | null = null;
  @State private autoSummaryPlan: GroupAutoSummaryPlan | null = null;
  @State private isAutoSummaryLoading: boolean = false;
  // G-GROUP-AUTO-SUMMARY-1B: 执行诊断状态
  @State private autoSummaryExecutionStatus: string = '';
  @State private autoSummaryActiveCount: number = 0;
  @State private autoSummaryConsolidationPerformed: boolean = false;
  @State private autoSummaryIsExecuting: boolean = false;
  @State private autoSummaryExecutingLabel: string = '';

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const groupConversationId: string =
        AppStorage.get<string>(PENDING_GROUP_MEMORY_GROUP_ID_KEY) ?? '';
      const characterId: string =
        AppStorage.get<string>(PENDING_GROUP_MEMORY_CHARACTER_ID_KEY) ?? '';
      // 读取后立即清除,避免页面重绘时误用
      AppStorage.set<string>(PENDING_GROUP_MEMORY_GROUP_ID_KEY, '');
      AppStorage.set<string>(PENDING_GROUP_MEMORY_CHARACTER_ID_KEY, '');
      if (groupConversationId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: groupConversationId empty');
        this.isInitializing = false;
        this.loadState = GroupCharacterMemoryLoadState.NotFound;
        return;
      }
      this.viewModel = new GroupCharacterMemoryViewModel(
        AppServices.getGroupConversationPersistenceService(),
        AppServices.getCharacterService(),
        AppServices.getGroupCharacterMemoryService(),
        AppServices.getGroupCharacterSelfSummaryService(),
        AppServices.getGroupCharacterRelationshipMemoryService(),
        AppServices.getGroupCharacterRelationshipSummaryService(),
        AppServices.getGroupPromptInspectionStore(),
        AppServices.getModelService(),
        AppServices.getGroupConversationMessageService()
      );
      // G-MEMORY-UI-2: 先加载成员列表,确定默认角色
      await this.viewModel.loadMembers(groupConversationId, characterId);
      if (this.viewModel === null) {
        return;
      }
      this.members = this.viewModel.members;
      this.selectedCharacterId = this.viewModel.selectedCharacterId;
      this.hasNoMembers = this.members.length === 0;
      if (this.selectedCharacterId.length === 0) {
        this.isInitializing = false;
        this.loadState = GroupCharacterMemoryLoadState.Ready;
        return;
      }
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = GroupCharacterMemoryLoadState.Error;
      this.errorMessage = '记忆数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.activate();
    await this.loadSnapshot();
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  private async loadSnapshot(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const groupConversationId: string = this.viewModel.expectedGroupConversationIdOfPage();
    const characterId: string = this.viewModel.expectedCharacterIdOfPage();
    if (groupConversationId.length === 0 || characterId.length === 0) {
      return;
    }
    await this.viewModel.loadSnapshot(groupConversationId, characterId, this.filter);
    this.syncFromViewModel();
    // G-MEMORY-UI-2: 同步选中角色(防止角色被删除后 ViewModel 自动切换)
    this.selectedCharacterId = this.viewModel.selectedCharacterId;
    this.members = this.viewModel.members;
    // G-GROUP-AUTO-SUMMARY-1A: 加载当前角色自动总结计划(诊断显示)
    await this.viewModel.loadAutoSummaryPlan();
    this.syncAutoSummaryFromViewModel();
  }

  /**
   * 同步 ViewModel 状态到页面 @State。
   * G-MEMORY-1A-FIX-UI:本方法只同步数据相关字段(loadState/errorMessage/isSaving/isDeleting/memories/header),
   * 不重置 formVisible/formMode/draft,避免 load 后表单被意外关闭。
   *
   * G-MEMORY-AUTO-1A:不在此处同步 summaryError,避免 load 后覆盖正在显示的总结错误。
   * 总结错误由事件处理器(handleAutoSummary 等)单独同步到 actionError 或 summaryFormError。
   */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.isSaving = this.viewModel.isSaving;
    this.isDeleting = this.viewModel.isDeleting;
    const snapshot = this.viewModel.snapshot;
    if (snapshot === null) {
      this.memories = [];
      this.header = null;
      return;
    }
    this.memories = snapshot.memories;
    this.header = snapshot.header;
  }

  /** G-GROUP-AUTO-SUMMARY-1A: 同步 ViewModel 自动总结诊断状态到页面 */
  private syncAutoSummaryFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.autoSummarySettings = this.viewModel.autoSummarySettings;
    this.autoSummaryPlan = this.viewModel.autoSummaryPlan;
    this.isAutoSummaryLoading = this.viewModel.isAutoSummaryLoading;
    // 1B execution diagnostics
    this.autoSummaryExecutionStatus = this.viewModel.autoSummaryExecutionStatus;
    this.autoSummaryActiveCount = this.viewModel.autoSummaryActiveCount;
    this.autoSummaryConsolidationPerformed = this.viewModel.autoSummaryConsolidationPerformed;
    this.autoSummaryIsExecuting = this.viewModel.autoSummaryIsExecuting;
    this.autoSummaryExecutingLabel = this.viewModel.autoSummaryExecutingLabel;
  }

  build(): void {
    Stack() {
      // 主页面
      Column() {
        this.headerArea()
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.loadState === GroupCharacterMemoryLoadState.Loading) {
          this.loadingView()
        } else if (this.loadState === GroupCharacterMemoryLoadState.NotFound) {
          this.notFoundView()
        } else if (this.loadState === GroupCharacterMemoryLoadState.Error) {
          this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '记忆数据加载失败,请重试')
        } else {
          this.contentView()
        }
      }
      .width('100%')
      .height('100%')

      // 表单 Stack 覆盖层(G-MEMORY-1A-FIX-UI:替代 bindSheet)
      if (this.formVisible) {
        this.memoryFormOverlay()
      }

      // 删除确认 Stack 覆盖层(与表单互斥)
      if (this.deletingMemoryId.length > 0) {
        this.deleteConfirmOverlay()
      }

      // G-MEMORY-AUTO-1A 自动总结审核 Stack 覆盖层(与表单/删除互斥)
      if (this.summaryVisible) {
        this.summaryReviewOverlay()
      }

      // G-MEMORY-AUTO-1A-FIX-2 详情 Stack 覆盖层(与表单/删除/总结互斥)
      if (this.detailVisible) {
        this.memoryDetailOverlay()
      }

      // G-MEMORY-AUTO-1B 关系候选审核 Stack 覆盖层(与其他互斥)
      if (this.relationshipReviewVisible) {
        this.relationshipReviewOverlay()
      }

      // G-MEMORY-AUTO-1B 关系详情 Stack 覆盖层(与其他互斥)
      if (this.relationshipDetailVisible) {
        this.relationshipDetailOverlay()
      }

      // G-MEMORY-AUTO-1B 关系编辑表单 Stack 覆盖层(与其他互斥)
      if (this.relationshipEditVisible) {
        this.relationshipEditOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.group_cancel'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText('返回')
        .onClick(() => {
          router.back();
        })

      Text('角色记忆')
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress().width(40).height(40).color($r('app.color.app_accent'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      EmptyStateView({ title: '未找到角色记忆', description: '群聊或角色不存在' })
      Button($r('app.string.group_cancel'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => { router.back(); })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(msg: string): void {
    Column() {
      EmptyStateView({ title: '记忆数据加载失败', description: msg })
      Button('重新加载')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => { this.loadSnapshot(); })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  contentView(): void {
    Column() {
      // G-MEMORY-UI-2: 顶部角色横向切换区
      if (this.members.length > 1) {
        this.characterSwitcherArea()
      }

      // 没有成员空状态
      if (this.hasNoMembers) {
        Column() {
          EmptyStateView({ title: '当前群聊没有可设置记忆的角色', description: '' })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 角色头部
        this.characterHeaderArea()

        // G-MEMORY-AUTO-1B 视图切换栏:记忆 / 关系与经历
        this.viewModeBar()

        if (this.viewMode === PageViewMode.Relationship) {
          // 关系与经历视图
          this.relationshipContentView()
        } else if (this.viewMode === PageViewMode.ContextInspector) {
          // G-CONTEXT-INSPECTOR-1: 上下文检查视图
          this.contextInspectorContentView()
        } else {
          // 记忆视图(原有逻辑)
          // G-GROUP-AUTO-SUMMARY-1A: 自动总结诊断区
          this.autoSummaryDiagnosticSection()
          this.filterBar()

          // 错误提示
          if (this.actionError.length > 0) {
            Text(this.actionError)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          }

          // 列表
          if (this.memories.length === 0) {
            this.emptyMemoryView()
          } else {
            List() {
              ForEach(this.memories, (m: GroupCharacterMemoryItemUiModel) => {
                ListItem() {
                  this.memoryCard(m)
                }
              }, (m: GroupCharacterMemoryItemUiModel) => m.id)
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .scrollBar(BarState.Auto)
          }
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * G-MEMORY-AUTO-1B / G-CONTEXT-INSPECTOR-1 视图切换栏。
   * 在角色头部下方显示三个切换按钮:记忆 / 关系与经历 / 上下文检查。
   * 切换时加载对应数据。
   */
  @Builder
  viewModeBar(): void {
    Row() {
      Button('记忆')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.viewMode === PageViewMode.Memory
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
        .backgroundColor(this.viewMode === PageViewMode.Memory
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(30)
        .padding({ left: 14, right: 14 })
        .enabled(!this.isSaving && !this.isDeleting
          && !this.isSummarizing && !this.isApprovingSummaryState
          && !this.isPreparingRelationship && !this.isApprovingRelationship)
        .onClick(() => { this.switchViewMode(PageViewMode.Memory); })

      Button('关系')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.viewMode === PageViewMode.Relationship
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
        .backgroundColor(this.viewMode === PageViewMode.Relationship
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(30)
        .padding({ left: 14, right: 14 })
        .margin({ left: 8 })
        .enabled(!this.isSaving && !this.isDeleting
          && !this.isSummarizing && !this.isApprovingSummaryState
          && !this.isPreparingRelationship && !this.isApprovingRelationship)
        .accessibilityText('关系与经历')
        .onClick(() => { this.switchViewMode(PageViewMode.Relationship); })

      Button('上下文')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.viewMode === PageViewMode.ContextInspector
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
        .backgroundColor(this.viewMode === PageViewMode.ContextInspector
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(30)
        .padding({ left: 14, right: 14 })
        .margin({ left: 8 })
        .enabled(!this.isSaving && !this.isDeleting
          && !this.isSummarizing && !this.isApprovingSummaryState
          && !this.isPreparingRelationship && !this.isApprovingRelationship)
        .accessibilityText('上下文检查')
        .key('groupMemory.tab.context')
        .onClick(() => { this.switchViewMode(PageViewMode.ContextInspector); })

      Blank().layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * G-MEMORY-UI-2: 顶部角色横向切换区。
   * 横向滚动列表,每项为"圆形头像 + 角色名"垂直布局。
   * 选中:头像 2vp 主题色描边 + 角色名主题色 Medium 字重。
   * 未选中:无描边 + 角色名普通文字色。
   * 不显示底部小横条/ScrollBar/分页指示器。
   */
  @Builder
  characterSwitcherArea(): void {
    Scroll() {
      Row() {
        ForEach(this.members, (member: GroupCharacterSwitcherItemUiModel) => {
          Column() {
            Stack() {
              CharacterImageView({
                imageUri: member.avatarUri,
                fallbackName: member.displayName,
                imgWidth: 48,
                imgHeight: 48,
                imgBorderRadius: 24,
                displayMode: 'thumbnail'
              })
              if (this.selectedCharacterId === member.characterId) {
                Column()
                  .width(52)
                  .height(52)
                  .borderRadius(26)
                  .border({ width: 2, color: $r('app.color.app_accent') })
              }
            }
            .width(52)
            .height(52)
            .alignContent(Alignment.Center)

            Text(member.displayName)
              .fontSize(12)
              .fontWeight(this.selectedCharacterId === member.characterId
                ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.selectedCharacterId === member.characterId
                ? $r('app.color.app_accent') : $r('app.color.app_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(68)
              .textAlign(TextAlign.Center)
              .margin({ top: 6 })
          }
          .width(68)
          .alignItems(HorizontalAlign.Center)
          .margin({ right: 10 })
          .opacity(member.isCharacterMissing ? 0.5 : 1)
          .onClick(() => {
            this.handleSwitchCharacter(member.characterId);
          })
        }, (member: GroupCharacterSwitcherItemUiModel) => member.characterId)
      }
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Start)
    .padding({ top: 8, bottom: 4 })
  }

  @Builder
  characterHeaderArea(): void {
    Row() {
      CharacterImageView({
        imageUri: this.header !== null ? this.header.avatarUri : '',
        fallbackName: this.header !== null ? this.header.fallbackName : '角色已删除',
        imgWidth: 44,
        imgHeight: 44,
        imgBorderRadius: 22,
        displayMode: 'thumbnail'
      })

      Column() {
        Text(this.header !== null ? this.header.displayName : '角色已删除')
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          // 成员状态徽标
          Text(this.header !== null ? this.header.memberStatusLabel : '')
            .fontSize(10)
            .fontColor(this.memberStatusColor(this.header))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })

          // 所属群聊名称
          Text(this.header !== null ? this.header.groupTitle : '')
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 160 })
        }
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)

        Text('共 ' + (this.header !== null ? this.header.memoryCount : 0).toString() + ' 条记忆')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .alignItems(VerticalAlign.Center)
  }

  /**
   * G-GROUP-AUTO-SUMMARY-1A: 自动总结诊断区。
   * 显示:开关状态 / 档位 / 最近总结边界 / 新增可见消息统计 / 触发判定。
   * 本阶段不提供"立即总结"按钮;显示"自动执行将在下一阶段接入"。
   */
  @Builder
  autoSummaryDiagnosticSection(): void {
    Column() {
      Row() {
        Text('自动总结')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (this.isAutoSummaryLoading) {
          LoadingProgress().width(16).height(16)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 6 })

      if (this.autoSummarySettings !== null) {
        this.autoSummaryDiagnosticRow('状态',
          this.autoSummarySettings.enabled ? '开启' : '关闭')
        this.autoSummaryDiagnosticRow('档位',
          getGroupAutoSummaryLevelSpec(this.autoSummarySettings.detailLevel).label)
      } else {
        this.autoSummaryDiagnosticRow('状态', '未加载')
      }

      if (this.autoSummaryPlan !== null) {
        if (this.autoSummaryPlan.previousSummaryBoundaryMessageId.length > 0) {
          this.autoSummaryDiagnosticRow('最近总结边界消息',
            this.autoSummaryPlan.previousSummaryBoundaryMessageId.length > 12
              ? this.autoSummaryPlan.previousSummaryBoundaryMessageId.substring(0, 12) + '…'
              : this.autoSummaryPlan.previousSummaryBoundaryMessageId)
          this.autoSummaryDiagnosticRow('最近总结边界轮次',
            this.autoSummaryPlan.previousSummaryBoundaryRoundId.length > 0
              ? (this.autoSummaryPlan.previousSummaryBoundaryRoundId.length > 12
                ? this.autoSummaryPlan.previousSummaryBoundaryRoundId.substring(0, 12) + '…'
                : this.autoSummaryPlan.previousSummaryBoundaryRoundId) : '无')
        } else {
          this.autoSummaryDiagnosticRow('最近总结边界', '尚无(首次总结)')
        }
        this.autoSummaryDiagnosticRow('新增可见消息',
          String(this.autoSummaryPlan.completedVisibleMessageCount) + ' 条')
        this.autoSummaryDiagnosticRow('新增估算 Token',
          String(this.autoSummaryPlan.estimatedInputTokens))
        this.autoSummaryDiagnosticRow('用户消息',
          String(this.autoSummaryPlan.userMessageCount) + ' 条')
        this.autoSummaryDiagnosticRow('角色消息',
          String(this.autoSummaryPlan.characterMessageCount) + ' 条')
        this.autoSummaryDiagnosticRow('旁白消息',
          String(this.autoSummaryPlan.narrationMessageCount) + ' 条')
        this.autoSummaryDiagnosticRow('达到触发条件',
          this.autoSummaryPlan.eligible ? '是' : '否')
        if (!this.autoSummaryPlan.eligible && this.autoSummaryPlan.ineligibleReason.length > 0) {
          this.autoSummaryDiagnosticRow('未触发原因',
            this.autoSummaryReasonLabel(this.autoSummaryPlan.ineligibleReason))
        }
      } else if (!this.isAutoSummaryLoading) {
        this.autoSummaryDiagnosticRow('计划', '未生成')
      }

      Divider().color($r('app.color.app_divider')).margin({ top: 8, bottom: 8 })

      // G-GROUP-AUTO-SUMMARY-1B: 执行状态诊断
      if (this.autoSummaryIsExecuting) {
        Text(this.autoSummaryExecutingLabel.length > 0
          ? this.autoSummaryExecutingLabel : '正在自动整理该角色的记忆…')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      if (this.autoSummaryExecutionStatus.length > 0) {
        this.autoSummaryDiagnosticRow('最近执行状态', this.autoSummaryExecutionStatus)
      }
      if (this.autoSummaryActiveCount > 0) {
        this.autoSummaryDiagnosticRow('旧 Active 总结', String(this.autoSummaryActiveCount) + ' 条')
      }
      if (this.autoSummaryConsolidationPerformed) {
        this.autoSummaryDiagnosticRow('旧数据归并', '已执行')
      }

      Text('自动总结将在本轮对话结束后执行')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
  }

  /** 自动总结诊断单行 */
  @Builder
  autoSummaryDiagnosticRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
      Text(value)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .fontWeight(FontWeight.Medium)
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
    .alignItems(VerticalAlign.Center)
  }

  /** 自动总结未触发原因标签 */
  private autoSummaryReasonLabel(reason: string): string {
    if (reason === 'auto_summary_disabled') {
      return '自动总结已关闭';
    }
    if (reason === 'no_new_messages') {
      return '没有新增可见消息';
    }
    if (reason === 'below_threshold') {
      return '未达到触发阈值';
    }
    if (reason === 'no_user_message') {
      return '缺少用户消息';
    }
    if (reason === 'no_character_message') {
      return '缺少角色消息';
    }
    if (reason === 'multiple_active_self_summaries') {
      return '存在多条活跃总结记录';
    }
    if (reason === 'boundary_message_missing') {
      return '上次总结边界消息缺失';
    }
    return reason;
  }

  @Builder
  filterBar(): void {
    Row() {
      Button('全部')        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.filter === GroupCharacterMemoryListFilter.All
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
        .backgroundColor(this.filter === GroupCharacterMemoryListFilter.All
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => { this.changeFilter(GroupCharacterMemoryListFilter.All); })
      Button('活跃')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.filter === GroupCharacterMemoryListFilter.Active
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
        .backgroundColor(this.filter === GroupCharacterMemoryListFilter.Active
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ left: 8 })
        .onClick(() => { this.changeFilter(GroupCharacterMemoryListFilter.Active); })
      Button('已归档')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.filter === GroupCharacterMemoryListFilter.Archived
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
        .backgroundColor(this.filter === GroupCharacterMemoryListFilter.Archived
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ left: 8 })
        .onClick(() => { this.changeFilter(GroupCharacterMemoryListFilter.Archived); })

      Blank().layoutWeight(1)

      // G-MEMORY-AUTO-1A 自动总结入口(放在新增记忆左侧)
      // - 正常:可点击
      // - 运行中:显示"正在总结…",禁用
      // - 保存中:禁用(避免与保存冲突)
      // - 无可用模型:仍可点击,点击后 prepareSelfSummary 返回 NoModelConfig 错误,显示在 actionError
      Button(this.isSummarizing ? '正在总结…' : '自动总结')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ right: 8 })
        .enabled(!this.isSummarizing && !this.isApprovingSummary()
          && !this.isSaving && !this.isDeleting)
        .accessibilityText('自动总结')
        .onClick(() => { this.handleAutoSummary(); })

      Button('新增记忆')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .enabled(this.canCreateMemory() && !this.isSaving && !this.isDeleting)
        .accessibilityText('新增记忆')
        .onClick(() => { this.openCreateForm(); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  emptyMemoryView(): void {
    Column() {
      EmptyStateView({
        title: '暂无记忆',
        description: this.canCreateMemory() ? '点击新增第一条角色记忆' : '该角色当前无法新增记忆'
      })
      if (this.canCreateMemory()) {
        Button('新增记忆')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .padding({ left: 24, right: 24 })
          .margin({ top: 12 })
          .enabled(!this.isSaving && !this.isDeleting)
          .onClick(() => { this.openCreateForm(); })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  memoryCard(m: GroupCharacterMemoryItemUiModel): void {
    Column() {
      // 第一行:标题 + 来源标签 + 状态
      Row() {
        Text(m.title)
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(m.originLabel)
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 6 })

        Text(m.statusLabel)
          .fontSize(11)
          .fontColor(m.status === GroupCharacterMemoryStatus.Active
            ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 内容摘要
      Text(m.contentPreview)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 6 })
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)

      // 重要度 + 关键词
      Row() {
        Text(this.importanceLabel(m.importance))
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })

        if (m.keywordsText.length > 0) {
          Text(m.keywordsText)
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 180 })
        }

        Blank().layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      // 来源摘要(仅 Interaction 显示)
      if (m.sourceSummary.length > 0) {
        Text(m.sourceSummary)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 4 })
      }

      // 时间
      Row() {
        Text('创建: ' + m.createdAtLabel)
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
        if (m.updatedAt !== m.createdAt && m.updatedAtLabel.length > 0) {
          Text(' · 更新: ' + m.updatedAtLabel)
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      // 来源提示
      // G-MEMORY-AUTO-1A-FIX-2:
      // - Manual:无提示
      // - self_summary_v1:显示"自动总结 · 可修改"(允许编辑/归档)
      // - 其他 Interaction:显示"交互记忆由消息来源管理"(只读)
      // - Invalidated:显示"来源已失效"(只读)
      if (m.isInvalidated) {
        Text('来源已失效')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 6 })
      } else if (m.isSelfSummary) {
        Text('自动总结 · 可修改内容')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 6 })
      } else if (m.isInteraction) {
        Text('交互记忆由消息来源管理')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 6 })
      }

      // G-MEMORY-AUTO-1A-FIX-2: 卡片不显示操作按钮
      // 整卡点击打开详情,详情内提供 修改/归档/删除 入口
      // 避免卡片按钮与整卡点击冲突
    }
    .width('100%')
    .padding({
      left: 12, right: 12, top: 10, bottom: 10
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => { this.openDetail(m.id); })
  }

  /**
   * 记忆表单 Stack 覆盖层(G-MEMORY-1A-FIX-UI:替代 bindSheet)。
   * 参考 MemoryManagementPage.clearConfirmDialog 的模式:
   * - 外层 Stack 充当 Scrim,点击关闭表单
   * - 内层 Column 是表单卡片,拦截点击不冒泡到 Scrim
   * - 使用 hitTestBehavior(Default) 确保子组件可接收点击
   */
  @Builder
  memoryFormOverlay(): void {
    Stack() {
      // 表单卡片(拦截点击,不冒泡到外层 Stack)
      Column() {
        // 标题栏
        // G-MEMORY-AUTO-1A-FIX-2: 根据编辑类型显示不同标题
        // - 新增 → "新增手动记忆"
        // - 编辑 Manual → "编辑手动记忆"
        // - 编辑 self_summary_v1 → "修改自动总结"
        Row() {
          Text(this.formMode === GroupMemoryFormMode.Edit
            ? (this.editingMemoryIsSelfSummary ? '修改自动总结' : '编辑手动记忆')
            : '新增手动记忆')
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)

          Text('关闭')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => { this.closeForm(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.app_divider'))

        // 可滚动表单内容
        Scroll() {
          Column() {
            // 标题
            Text('标题')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4, top: 8 })
            TextInput({
              placeholder: '请输入记忆标题',
              text: this.formTitle
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(44)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(GROUP_MEMORY_TITLE_MAX)
              .onChange((v: string) => {
                this.formTitle = v;
              })
            Text(this.formTitle.length.toString() + ' / ' + GROUP_MEMORY_TITLE_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 内容
            Text('内容')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextArea({
              text: this.formContent,
              placeholder: '请输入记忆内容'
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(140)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(GROUP_MEMORY_CONTENT_MAX)
              .onChange((v: string) => {
                this.formContent = v;
              })
            Text(this.formContent.length.toString() + ' / ' + GROUP_MEMORY_CONTENT_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 重要度
            Text('重要度')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            Row() {
              ForEach(this.importanceOptions(), (n: number) => {
                Button(n.toString())
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(this.formImportance === n
                    ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
                  .backgroundColor(this.formImportance === n
                    ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
                  .borderRadius($r('app.float.app_radius_sm'))
                  .height(32)
                  .width(44)
                  .margin({ right: 6 })
                  .onClick(() => { this.formImportance = n; })
              }, (n: number) => n.toString())
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
            .alignItems(VerticalAlign.Center)

            // 关键词
            Text('关键词')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextInput({
              placeholder: '逗号分隔,例如:身份、约定、喜好',
              text: this.formKeywords
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(44)
              .margin({ left: 16, right: 16, bottom: 8 })
              .onChange((v: string) => {
                this.formKeywords = v;
              })

            // 表单内错误提示
            if (this.formError.length > 0) {
              Text(this.formError)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 8 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)

        // 底部固定操作区(不被键盘遮挡)
        Row() {
          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ right: 8 })
            .enabled(!this.isSaving)
            .onClick(() => { this.closeForm(); })
          Button(this.isSaving ? '保存中…' : (this.formMode === GroupMemoryFormMode.Edit
            ? (this.editingMemoryIsSelfSummary ? '保存修改' : '保存')
            : '创建'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .enabled(!this.isSaving
              && this.formTitle.trim().length > 0
              && this.formContent.trim().length > 0)
            .onClick(() => { this.submitForm(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .width('90%')
      .constraintSize({ maxHeight: '80%' })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
      // 拦截点击,不冒泡到外层 Stack(避免点击表单内部关闭表单)
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    // 点击遮罩关闭表单
    .onClick(() => { this.closeForm(); })
  }

  /**
   * 删除确认 Stack 覆盖层(参考 MemoryManagementPage.deleteConfirmDialog)。
   */
  @Builder
  deleteConfirmOverlay(): void {
    Stack() {
      Column() {
        Text(this.deletingMemoryIsSelfSummary ? '删除自动总结' : '删除记忆')
          .fontSize($r('app.float.app_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ top: 16, bottom: 8 })

        Text(this.deletingMemoryIsSelfSummary
          ? '删除后无法恢复。来源消息不会被删除,下次总结不会重复生成已删除的内容。'
          : '删除后无法恢复,确定删除吗?')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 16 })

        Divider().color($r('app.color.app_divider'))

        Row() {
          Button('取消')
            .fontSize($r('app.float.app_font_body'))
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .height(48)
            .onClick(() => { this.deletingMemoryId = ''; })

          Divider().vertical(true).height(24).color($r('app.color.app_divider'))

          Button(this.isDeleting ? '删除中…' : '删除')
            .fontSize($r('app.float.app_font_body'))
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .height(48)
            .enabled(!this.isDeleting)
            .onClick(() => { this.handleDelete(this.deletingMemoryId); })
        }
        .width('100%')
      }
      .width('80%')
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
      // 拦截点击,不冒泡到外层 Stack
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    // 点击遮罩关闭确认
    .onClick(() => { this.deletingMemoryId = ''; })
  }

  /**
   * G-MEMORY-AUTO-1A 自动总结审核 Stack 覆盖层。
   *
   * 显示:
   * - 标题(自动总结结果)
   * - 来源角色 / 来源消息数量 / 来源起止位置 / sourceHash 短码
   * - 摘要标题(可编辑)
   * - 摘要正文(可多行编辑)
   * - 重要度(可调整)
   * - 关键词(可填写)
   * - 错误提示
   * - 按钮:取消 / 重新生成 / 批准保存
   *
   * 状态:
   * - 总结中(isSummarizing):按钮禁用,显示"正在总结…"
   * - 保存中(isApprovingSummary):按钮禁用,显示"保存中…",审核窗口不关闭
   * - 失败:保持打开,显示错误,用户编辑内容不丢失
   */
  @Builder
  summaryReviewOverlay(): void {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Text('自动总结结果')
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)

          Text('关闭')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => { this.closeSummary(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.app_divider'))

        // 可滚动表单内容
        Scroll() {
          Column() {
            // 来源说明(G-MEMORY-AUTO-1A-FIX:文案扩展为包含用户发言)
            Text('根据该角色可见的用户发言和该角色自己的发言生成')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 4 })
            // 来源信息(只读)
            Text(this.buildSummarySourceInfo())
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 0, bottom: 8 })

            // 标题
            Text('标题')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextInput({
              placeholder: '请输入记忆标题',
              text: this.summaryTitle
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(44)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(GROUP_MEMORY_TITLE_MAX)
              .onChange((v: string) => { this.summaryTitle = v; })
            Text(this.summaryTitle.length.toString() + ' / ' + GROUP_MEMORY_TITLE_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 正文
            Text('正文')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextArea({
              text: this.summaryContent,
              placeholder: '模型生成的摘要(可编辑)'
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(180)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(GROUP_MEMORY_CONTENT_MAX)
              .onChange((v: string) => { this.summaryContent = v; })
            Text(this.summaryContent.length.toString() + ' / ' + GROUP_MEMORY_CONTENT_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 重要度
            Text('重要度')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            Row() {
              ForEach(this.importanceOptions(), (n: number) => {
                Button(n.toString())
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(this.summaryImportance === n
                    ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
                  .backgroundColor(this.summaryImportance === n
                    ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
                  .borderRadius($r('app.float.app_radius_sm'))
                  .height(32)
                  .width(44)
                  .margin({ right: 6 })
                  .onClick(() => { this.summaryImportance = n; })
              }, (n: number) => n.toString())
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
            .alignItems(VerticalAlign.Center)

            // 关键词
            Text('关键词')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextInput({
              placeholder: '逗号分隔,例如:身份、约定、喜好',
              text: this.summaryKeywords
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(44)
              .margin({ left: 16, right: 16, bottom: 8 })
              .onChange((v: string) => { this.summaryKeywords = v; })

            // 表单内错误提示
            if (this.summaryFormError.length > 0) {
              Text(this.summaryFormError)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 8 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)

        // 底部固定操作区
        Row() {
          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ right: 6 })
            .enabled(!this.isApprovingSummary())
            .onClick(() => { this.closeSummary(); })
          Button(this.isSummarizing ? '生成中…' : '重新生成')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ right: 6 })
            .enabled(!this.isSummarizing && !this.isApprovingSummary())
            .onClick(() => { this.handleRegenerateSummary(); })
          Button(this.isApprovingSummary() ? '保存中…' : '批准保存')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .enabled(!this.isSummarizing && !this.isApprovingSummary()
              && this.summaryTitle.trim().length > 0
              && this.summaryContent.trim().length > 0)
            .onClick(() => { this.handleApproveSummary(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .width('92%')
      .constraintSize({ maxHeight: '85%' })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
      // 拦截点击,不冒泡到外层 Stack
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    // 点击遮罩关闭(保存中不允许关闭,防止中断)
    .onClick(() => {
      if (!this.isApprovingSummary()) {
        this.closeSummary();
      }
    })
  }

  /**
   * 记忆详情 Stack 覆盖层(G-MEMORY-AUTO-1A-FIX-2)。
   * 点击卡片整卡打开,显示完整详情和操作入口。
   * 不使用 bindSheet(避免自动关闭问题),采用 Stack 覆盖层。
   *
   * 显示字段:
   * - 标题
   * - 完整正文
   * - 重要度
   * - 关键词
   * - 来源类型(自动总结/交互/手动)
   * - 来源摘要(来源消息/来源轮次)
   * - 状态(活跃/已归档/已失效)
   * - 创建时间
   * - 更新时间
   *
   * 操作入口:
   * - Manual:编辑/归档/恢复/删除
   * - self_summary_v1 且非 Invalidated:修改/归档/恢复
   * - 其他 Interaction 或 Invalidated:只读
   */
  @Builder
  memoryDetailOverlay(): void {
    Stack() {
      Column() {
        if (this.detailMemory === null) {
          // 记忆不存在(可能已被删除),显示提示并关闭
            Text('记忆不存在或已删除')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_secondary'))
              .margin({ top: 24, bottom: 24 })
          Button('关闭')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .padding({ left: 24, right: 24 })
            .margin({ bottom: 16 })
            .onClick(() => { this.closeDetail(); })
        } else {
          // 标题栏
          Row() {
            Text(this.detailMemory.isSelfSummary ? '自动总结详情' : (this.detailMemory.isInteraction ? '交互记忆详情' : '记忆详情'))
              .fontSize($r('app.float.app_font_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)

            Button('关闭')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_accent'))
              .backgroundColor(Color.Transparent)
              .height(32)
              .accessibilityText('关闭详情')
              .onClick(() => { this.closeDetail(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 12 })

          // 可滚动内容区
          Scroll() {
            Column() {
              // 标题
              Text(this.detailMemory.title)
                .fontSize($r('app.float.app_font_title'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_text_primary'))
                .width('100%')
                .textAlign(TextAlign.Start)

              // 来源标签 + 状态标签
              Row() {
                Text(this.detailMemory.originLabel)
                  .fontSize(11)
                  .fontColor($r('app.color.app_text_tertiary'))
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })

                Text(this.detailMemory.statusLabel)
                  .fontSize(11)
                  .fontColor(this.detailMemory.status === GroupCharacterMemoryStatus.Active
                    ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .margin({ left: 6 })

                Text(this.importanceLabel(this.detailMemory.importance))
                  .fontSize(11)
                  .fontColor($r('app.color.app_text_secondary'))
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .margin({ left: 6 })
              }
              .width('100%')
              .margin({ top: 8 })
              .alignItems(VerticalAlign.Center)

              // 完整正文
              Text('正文')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .margin({ top: 16 })
                .textAlign(TextAlign.Start)
              Text(this.detailMemory.content)
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_text_primary'))
                .width('100%')
                .margin({ top: 4 })
                .textAlign(TextAlign.Start)

              // 关键词
              if (this.detailMemory.keywordsText.length > 0) {
                Text('关键词')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 16 })
                  .textAlign(TextAlign.Start)
                Text(this.detailMemory.keywordsText)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 来源摘要
              if (this.detailMemory.sourceSummary.length > 0) {
                Text('来源')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 16 })
                  .textAlign(TextAlign.Start)
                Text(this.detailMemory.sourceSummary)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 自动总结修改提示
              if (this.detailMemory.isSelfSummary && !this.detailMemory.isInvalidated) {
                Text('你可以修正总结内容,但不能修改其来源消息。')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 12 })
                  .textAlign(TextAlign.Start)
              }

              // 时间信息
              Text('创建: ' + this.detailMemory.createdAtLabel)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .margin({ top: 16 })
                .textAlign(TextAlign.Start)
              if (this.detailMemory.updatedAt !== this.detailMemory.createdAt
                && this.detailMemory.updatedAtLabel.length > 0) {
                Text('更新: ' + this.detailMemory.updatedAtLabel)
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 操作按钮
              if (this.detailMemory.canEdit || this.detailMemory.canDelete) {
                Row() {
                  if (this.detailMemory.canEdit) {
                    Button(this.detailMemory.isSelfSummary ? '修改' : '编辑')
                      .fontSize($r('app.float.app_font_body'))
                      .backgroundColor($r('app.color.app_accent'))
                      .fontColor($r('app.color.app_on_accent'))
                      .borderRadius($r('app.float.app_radius_sm'))
                      .height(40)
                      .padding({ left: 16, right: 16 })
                      .layoutWeight(1)
                      .enabled(!this.isSaving && !this.isDeleting)
                      .accessibilityText(this.detailMemory.isSelfSummary ? '修改自动总结' : '编辑记忆')
                      .onClick(() => {
                        if (this.detailMemory !== null) {
                          this.openEditForm(this.detailMemory);
                        }
                      })
                  }

                  if (this.detailMemory.canArchive) {
                    if (this.detailMemory.status === GroupCharacterMemoryStatus.Active) {
                      Button('归档')
                        .fontSize($r('app.float.app_font_body'))
                        .backgroundColor($r('app.color.app_surface_2'))
                        .fontColor($r('app.color.app_text_secondary'))
                        .borderRadius($r('app.float.app_radius_sm'))
                        .height(40)
                        .padding({ left: 16, right: 16 })
                        .margin({ left: 8 })
                        .layoutWeight(1)
                        .enabled(!this.isSaving && !this.isDeleting)
                        .accessibilityText('归档记忆')
                        .onClick(() => {
                          if (this.detailMemory !== null) {
                            this.handleArchive(this.detailMemory);
                          }
                        })
                    } else if (this.detailMemory.status === GroupCharacterMemoryStatus.Archived) {
                      Button('恢复')
                        .fontSize($r('app.float.app_font_body'))
                        .backgroundColor($r('app.color.app_surface_2'))
                        .fontColor($r('app.color.app_accent'))
                        .borderRadius($r('app.float.app_radius_sm'))
                        .height(40)
                        .padding({ left: 16, right: 16 })
                        .margin({ left: 8 })
                        .layoutWeight(1)
                        .enabled(!this.isSaving && !this.isDeleting)
                        .accessibilityText('恢复记忆')
                        .onClick(() => {
                          if (this.detailMemory !== null) {
                            this.handleArchive(this.detailMemory);
                          }
                        })
                    }
                  }

                  if (this.detailMemory.canDelete) {
                    Button('删除')
                      .fontSize($r('app.float.app_font_body'))
                      .backgroundColor($r('app.color.app_surface_2'))
                      .fontColor($r('app.color.app_danger'))
                      .borderRadius($r('app.float.app_radius_sm'))
                      .height(40)
                      .padding({ left: 16, right: 16 })
                      .margin({ left: 8 })
                      .layoutWeight(1)
                      .enabled(!this.isSaving && !this.isDeleting)
                      .accessibilityText('删除记忆')
                      .onClick(() => {
                        if (this.detailMemory !== null) {
                          this.openDeleteConfirm(this.detailMemory.id, this.detailMemory.isSelfSummary);
                        }
                      })
                  }
                }
                .width('100%')
                .margin({ top: 24 })
                .justifyContent(FlexAlign.SpaceBetween)
                .alignItems(VerticalAlign.Center)
              }

              // 底部留白
              Blank().height(16)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)

          // 错误提示(操作失败时显示)
          if (this.actionError.length > 0) {
            Text(this.actionError)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .margin({ top: 8 })
              .padding({ top: 8, bottom: 8, left: 12, right: 12 })
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .textAlign(TextAlign.Start)
          }
        }
      }
      .width('90%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_16')
      })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_lg'))
      .constraintSize({ maxHeight: '85%' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    // 点击遮罩关闭(保存中不允许关闭,防止中断)
    .onClick(() => { this.closeDetail(); })
  }

  // ===== 事件处理 =====

  private async changeFilter(filter: GroupCharacterMemoryListFilter): Promise<void> {
    if (this.filter === filter) {
      return;
    }
    this.filter = filter;
    await this.loadSnapshot();
  }

  /**
   * G-MEMORY-UI-2: 切换当前选中角色。
   * 更新 ViewModel,关闭所有覆盖层,加载新角色数据。
   */
  private async handleSwitchCharacter(characterId: string): Promise<void> {
    if (this.viewModel === null || characterId.length === 0) {
      return;
    }
    if (this.selectedCharacterId === characterId) {
      return;
    }
    // 关闭所有覆盖层
    this.formVisible = false;
    this.deletingMemoryId = '';
    this.summaryVisible = false;
    this.detailVisible = false;
    this.relationshipReviewVisible = false;
    this.relationshipDetailVisible = false;
    this.relationshipEditVisible = false;
    this.actionError = '';
    this.relationshipActionError = '';

    this.viewModel.switchCharacter(characterId);
    this.selectedCharacterId = characterId;
    await this.loadSnapshot();
    // 如果在关系视图,重新加载关系列表
    if (this.viewMode === PageViewMode.Relationship) {
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
    } else if (this.viewMode === PageViewMode.ContextInspector) {
      this.viewModel.loadInspectionSnapshot();
      this.syncInspectionFromViewModel();
      await this.viewModel.loadContextAdjustment();
      this.syncInspectionFromViewModel();
    }
  }

  /**
   * 打开新增表单。
   * G-MEMORY-1A-FIX-UI:只设置一次状态,不触发 load,不修改筛选。
   */
  private openCreateForm(): void {
    if (!this.canCreateMemory()) {
      this.actionError = '该角色已移出群聊,无法新增记忆';
      return;
    }
    this.actionError = '';
    this.formError = '';
    this.editingMemoryId = '';
    this.editingMemoryIsSelfSummary = false;
    this.formTitle = '';
    this.formContent = '';
    this.formImportance = GROUP_MEMORY_IMPORTANCE_DEFAULT;
    this.formKeywords = '';
    this.formMode = GroupMemoryFormMode.Create;
    this.formVisible = true;
  }

  /**
   * 打开编辑表单。
   * G-MEMORY-1A-FIX-UI:不重新查询覆盖 draft,只从卡片数据预填。
   * G-MEMORY-AUTO-1A-FIX-2:允许 Manual 和 self_summary_v1(非 Invalidated)进入编辑。
   */
  private openEditForm(m: GroupCharacterMemoryItemUiModel): void {
    if (!m.canEdit) {
      // 只读记忆(其他 Interaction 或 Invalidated)不打开编辑表单
      return;
    }
    // 打开编辑前先关闭详情(避免重叠)
    this.detailVisible = false;
    this.actionError = '';
    this.formError = '';
    this.editingMemoryId = m.id;
    this.editingMemoryIsSelfSummary = m.isSelfSummary;
    this.formTitle = m.title;
    this.formContent = m.content;
    this.formImportance = m.importance;
    this.formKeywords = m.keywordsText;
    this.formMode = GroupMemoryFormMode.Edit;
    this.formVisible = true;
  }

  /**
   * 关闭表单(取消/关闭按钮/遮罩点击/保存成功)。
   * G-MEMORY-1A-FIX-UI:不立即清空 draft,避免关闭动画期间闪烁;
   * draft 在下次 openCreateForm/openEditForm 时重置。
   */
  private closeForm(): void {
    if (this.isSaving) {
      // 保存中不允许关闭(防止中断)
      return;
    }
    this.formVisible = false;
    this.formError = '';
  }

  /**
   * 打开删除确认(先关闭表单,避免重叠)。
   */
  private openDeleteConfirm(memoryId: string, isSelfSummary: boolean = false): void {
    if (memoryId.length === 0) {
      return;
    }
    // 先关闭表单和详情(如果在打开状态)
    this.formVisible = false;
    this.detailVisible = false;
    this.deletingMemoryId = memoryId;
    this.deletingMemoryIsSelfSummary = isSelfSummary;
  }

  /**
   * 打开记忆详情覆盖层(G-MEMORY-AUTO-1A-FIX-2)。
   * 点击卡片整卡调用,显示完整详情和操作入口。
   */
  private openDetail(memoryId: string): void {
    if (memoryId.length === 0) {
      return;
    }
    this.detailMemoryId = memoryId;
    this.detailMemory = this.findMemoryById(memoryId);
    this.detailVisible = true;
  }

  /** 关闭详情覆盖层 */
  private closeDetail(): void {
    if (this.isSaving) {
      // 保存中不允许关闭(防止中断)
      return;
    }
    this.detailVisible = false;
    this.detailMemoryId = '';
    this.detailMemory = null;
  }

  /**
   * 从 memories 数组中刷新详情中的记忆数据。
   * 在 loadSnapshot 后调用,确保详情显示最新内容。
   */
  private refreshDetailMemory(): void {
    if (!this.detailVisible || this.detailMemoryId.length === 0) {
      return;
    }
    this.detailMemory = this.findMemoryById(this.detailMemoryId);
  }

  /** 从 memories 数组查找指定 ID 的记忆 */
  private findMemoryById(memoryId: string): GroupCharacterMemoryItemUiModel | null {
    if (memoryId.length === 0) {
      return null;
    }
    for (let i = 0; i < this.memories.length; i++) {
      if (this.memories[i].id === memoryId) {
        return this.memories[i];
      }
    }
    return null;
  }

  /**
   * 提交表单(新增或编辑)。
   * G-MEMORY-1A-FIX-UI:
   * - 校验失败时保持表单打开,显示 formError
   * - 保存成功后关闭表单并刷新列表
   * - 保存失败时保持表单打开,保留输入
   * - isSaving 由 ViewModel 管理,防重复提交
   */
  private async submitForm(): Promise<void> {
    if (this.viewModel === null || this.isSaving) {
      return;
    }
    const title: string = this.formTitle.trim();
    const content: string = this.formContent.trim();
    if (title.length === 0) {
      this.formError = '记忆标题不能为空';
      return;
    }
    if (title.length > GROUP_MEMORY_TITLE_MAX) {
      this.formError = '记忆标题超过长度上限';
      return;
    }
    if (content.length === 0) {
      this.formError = '记忆内容不能为空';
      return;
    }
    if (content.length > GROUP_MEMORY_CONTENT_MAX) {
      this.formError = '记忆内容超过长度上限';
      return;
    }
    this.formError = '';

    const isEdit: boolean = this.formMode === GroupMemoryFormMode.Edit;
    if (isEdit) {
      const input: UpdateGroupMemoryFormInput = {
        memoryId: this.editingMemoryId,
        title: title,
        content: content,
        importance: this.formImportance,
        keywordsText: this.formKeywords
      };
      // G-MEMORY-AUTO-1A-FIX-2: 根据记忆类型调用不同 Service 方法
      // - self_summary_v1 → updateApprovedSelfSummary(保留来源字段)
      // - Manual → updateMemory
      const result = this.editingMemoryIsSelfSummary
        ? await this.viewModel.updateApprovedSelfSummary(input)
        : await this.viewModel.updateMemory(input);
      if (result.success) {
        this.formVisible = false;
        await this.loadSnapshot();
        // 若详情仍打开,同步更新详情中的记忆数据
        if (this.detailVisible && this.detailMemoryId === this.editingMemoryId) {
          this.refreshDetailMemory();
        }
      } else {
        this.formError = result.errorMessage;
      }
    } else {
      const input: CreateGroupMemoryFormInput = {
        title: title,
        content: content,
        importance: this.formImportance,
        keywordsText: this.formKeywords
      };
      const result = await this.viewModel.createMemory(input);
      if (result.success) {
        this.formVisible = false;
        await this.loadSnapshot();
      } else {
        this.formError = result.errorMessage;
      }
    }
  }

  /**
   * 归档/恢复记忆。
   * G-MEMORY-AUTO-1A-FIX-2:根据记忆类型调用不同 Service 方法
   * - self_summary_v1 → setApprovedSelfSummaryArchived
   * - Manual → setMemoryArchived
   */
  private async handleArchive(m: GroupCharacterMemoryItemUiModel): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const archived: boolean = m.status === GroupCharacterMemoryStatus.Active;
    this.actionError = '';
    const result = m.isSelfSummary
      ? await this.viewModel.setApprovedSelfSummaryArchived(m.id, archived)
      : await this.viewModel.setMemoryArchived(m.id, archived);
    if (result.success) {
      await this.loadSnapshot();
      // 若详情仍打开,同步更新详情中的记忆数据
      if (this.detailVisible && this.detailMemoryId === m.id) {
        this.refreshDetailMemory();
      }
    } else {
      this.actionError = result.errorMessage;
    }
  }

  private async handleDelete(memoryId: string): Promise<void> {
    if (this.viewModel === null || memoryId.length === 0) {
      return;
    }
    this.actionError = '';
    // G-MEMORY-AUTO-1A-FIX-2: 根据记忆类型调用不同 Service 方法
    // - self_summary_v1 → deleteApprovedSelfSummary
    // - Manual → deleteMemory
    const result = this.deletingMemoryIsSelfSummary
      ? await this.viewModel.deleteApprovedSelfSummary(memoryId)
      : await this.viewModel.deleteMemory(memoryId);
    if (result.success) {
      this.deletingMemoryId = '';
      this.deletingMemoryIsSelfSummary = false;
      // 若详情仍打开,同步关闭(已删除的记忆不再显示)
      if (this.detailVisible && this.detailMemoryId === memoryId) {
        this.detailVisible = false;
        this.detailMemoryId = '';
        this.detailMemory = null;
      }
      await this.loadSnapshot();
    } else {
      this.actionError = result.errorMessage;
    }
  }

  // ===== G-MEMORY-AUTO-1A 自动总结事件处理 =====

  /**
   * 点击"自动总结"按钮。
   * 流程:
   * 1. 防重复(isSummarizing / isApprovingSummary)
   * 2. 清空错误状态
   * 3. 调用 ViewModel.prepareSelfSummary
   * 4. 同步 isSummarizing
   * 5. 成功:从 draft 初始化本地编辑字段,打开审核窗口
   * 6. 失败:将 summaryError 显示在 actionError(主页面错误提示区)
   */
  private async handleAutoSummary(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isSummarizing || this.isApprovingSummaryState) {
      return;
    }
    this.actionError = '';
    this.summaryFormError = '';
    // 先设置 isSummarizing=true,防止 await 期间重复点击
    this.isSummarizing = true;
    await this.viewModel.prepareSelfSummary();
    this.syncSummaryState();

    const draft = this.viewModel.summaryDraft;
    if (draft !== null) {
      // 成功:初始化本地编辑字段,打开审核窗口
      this.summaryTitle = draft.title;
      this.summaryContent = draft.content;
      this.summaryImportance = draft.importance;
      this.summaryKeywords = draft.keywords.length > 0 ? draft.keywords.join(', ') : '';
      this.summaryFormError = '';
      this.summaryVisible = true;
    } else {
      // 失败:显示错误到主页面 actionError
      this.actionError = this.viewModel.summaryError;
    }
  }

  /**
   * 点击"重新生成"按钮。
   * 使用同一批来源消息再次调用模型,不写数据库。
   * 保留用户已编辑的 title/importance/keywords,只更新 content。
   */
  private async handleRegenerateSummary(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isSummarizing || this.isApprovingSummaryState) {
      return;
    }
    this.summaryFormError = '';
    this.isSummarizing = true;
    await this.viewModel.regenerateSelfSummary();
    this.syncSummaryState();

    const draft = this.viewModel.summaryDraft;
    if (draft !== null) {
      // 成功:只更新 content,保留用户编辑的 title/importance/keywords
      this.summaryContent = draft.content;
    } else {
      // 失败:在审核窗口内显示错误
      this.summaryFormError = this.viewModel.summaryError;
    }
  }

  /**
   * 点击"批准保存"按钮。
   * 调用 ViewModel.approveSelfSummary 写入 group_character_memories。
   * 成功:关闭审核窗口,刷新列表。
   * 失败:保持审核窗口打开,用户编辑内容不丢失,显示错误。
   */
  private async handleApproveSummary(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isSummarizing || this.isApprovingSummaryState) {
      return;
    }
    const title: string = this.summaryTitle.trim();
    const content: string = this.summaryContent.trim();
    if (title.length === 0) {
      this.summaryFormError = '记忆标题不能为空';
      return;
    }
    if (content.length === 0) {
      this.summaryFormError = '记忆内容不能为空';
      return;
    }
    const keywords: string[] = this.parseKeywords(this.summaryKeywords);

    this.summaryFormError = '';
    this.isApprovingSummaryState = true;
    const result = await this.viewModel.approveSelfSummary(
      title, content, this.summaryImportance, keywords
    );
    this.syncSummaryState();

    if (result.success) {
      this.summaryVisible = false;
      this.summaryFormError = '';
      await this.loadSnapshot();
    } else {
      // 保存失败:保持审核窗口打开,用户编辑内容不丢失
      this.summaryFormError = result.errorMessage;
    }
  }

  /**
   * 关闭审核窗口(取消 / 关闭按钮 / 遮罩点击)。
   * 保存中不允许关闭(防止中断)。
   */
  private closeSummary(): void {
    if (this.isApprovingSummaryState) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.clearSummaryDraft();
    }
    this.summaryVisible = false;
    this.summaryFormError = '';
    this.syncSummaryState();
  }

  /**
   * 同步 ViewModel 的总结状态到页面 @State。
   * 在每次 summary 操作前后调用,确保按钮状态正确。
   */
  private syncSummaryState(): void {
    if (this.viewModel === null) {
      return;
    }
    this.isSummarizing = this.viewModel.isSummarizing;
    this.isApprovingSummaryState = this.viewModel.isApprovingSummary;
  }

  /** 是否正在批准保存(供 Builder 调用) */
  private isApprovingSummary(): boolean {
    return this.isApprovingSummaryState;
  }

  /**
   * 构建来源信息文本(供审核窗口显示)。
   * 包含:来源角色 / 来源消息数量 / 来源起止位置 / sourceHash 短码
   * 不暴露完整 ID / 完整 hash。
   *
   * G-MEMORY-AUTO-1A-FIX:文案改为"根据该角色可见的用户发言和该角色自己的发言生成",
   * 分别显示用户消息 / 角色发言数量。
   */
  private buildSummarySourceInfo(): string {
    if (this.viewModel === null) {
      return '';
    }
    const charName: string = this.viewModel.summarySourceCharacterName();
    const count: number = this.viewModel.summarySourceCount();
    const userCount: number = this.viewModel.summaryUserMessageCount();
    const charCount: number = this.viewModel.summaryCharacterMessageCount();
    const startSeq: number = this.viewModel.summarySourceStartSequence();
    const endSeq: number = this.viewModel.summarySourceEndSequence();
    const hashShort: string = this.viewModel.summarySourceHashShort();
    if (count === 0) {
      return '';
    }
    const parts: string[] = [];
    if (charName.length > 0) {
      parts.push('来源角色:' + charName);
    }
    // 分别显示用户消息 / 角色发言数量(G-MEMORY-AUTO-1A-FIX)
    parts.push('用户消息:' + userCount.toString() + ' 条');
    parts.push('角色发言:' + charCount.toString() + ' 条');
    if (startSeq > 0 && endSeq >= startSeq) {
      parts.push('位置:#' + startSeq.toString() + ' - #' + endSeq.toString());
    }
    if (hashShort.length > 0) {
      parts.push('哈希:' + hashShort);
    }
    return parts.join('  ·  ');
  }

  /** 解析关键词文本(逗号分隔)为数组 */
  private parseKeywords(text: string): string[] {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return [];
    }
    const parts: string[] = trimmed.split(/[,，]/);
    const result: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const k: string = parts[i].trim();
      if (k.length > 0 && result.indexOf(k) < 0) {
        result.push(k);
      }
    }
    return result;
  }

  // ===== 辅助方法 =====

  private canCreateMemory(): boolean {
    return this.header !== null && this.header.canCreateMemory;
  }

  private memberStatusColor(header: GroupCharacterMemoryHeaderUiModel | null): ResourceColor {
    if (header === null) {
      return $r('app.color.app_text_tertiary');
    }
    if (header.memberStatus === GroupCharacterMemberStatus.ActiveMember) {
      return $r('app.color.app_accent');
    }
    if (header.memberStatus === GroupCharacterMemberStatus.CharacterMissing) {
      return $r('app.color.app_danger');
    }
    return $r('app.color.app_text_tertiary');
  }

  private importanceLabel(importance: number): string {
    return '重要度 ' + importance.toString();
  }

  // ===== G-CONTEXT-MEMORY-SELECTION-1 选择详情辅助 =====

  private memoryExclusionLabel(reason: GroupCharacterMemoryExclusionReason): string {
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_ARCHIVED) {
      return '已归档';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_EMPTY_CONTENT) {
      return '空正文';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_OWNER_MISMATCH) {
      return '所有权不符';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_CHAT_MISMATCH) {
      return '群聊不符';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_DUPLICATE) {
      return '重复';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_COUNT_BUDGET) {
      return '数量预算';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_TOKEN_BUDGET) {
      return 'Token预算';
    }
    if (reason === GroupCharacterMemoryExclusionReason.EXCLUDED_LOWER_PRIORITY) {
      return '优先级低';
    }
    return '查询失败';
  }

  private relationshipExclusionLabel(reason: GroupCharacterRelationshipExclusionReason): string {
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_REVERSE_RELATIONSHIP) {
      return '反向关系';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_UNRELATED_TARGET) {
      return '目标无关';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_NO_RELIABLE_TARGET) {
      return '无可靠结构化目标';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_REPLY_TARGET_NOT_RELATION_TARGET) {
      return '回复目标非关系目标';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_ARCHIVED) {
      return '已归档';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_OWNER_MISMATCH) {
      return '所有权不符';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_CHAT_MISMATCH) {
      return '群聊不符';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_SELF_TARGET) {
      return '自身目标';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_INVALID_TARGET) {
      return '目标无效';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_COUNT_BUDGET) {
      return '数量预算';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_TOKEN_BUDGET) {
      return 'Token预算';
    }
    if (reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_DUPLICATE) {
      return '重复';
    }
    return '查询失败';
  }

  private relationshipSourceLabel(source: RelationshipSelectionTargetSource): string {
    if (source === RelationshipSelectionTargetSource.USER_RELATION_DEFAULT) {
      return 'USER_RELATION_DEFAULT';
    }
    if (source === RelationshipSelectionTargetSource.EXPLICIT_STRUCTURED_TARGET) {
      return 'EXPLICIT_STRUCTURED_TARGET';
    }
    if (source === RelationshipSelectionTargetSource.REPLY_TARGET_DERIVED) {
      return 'REPLY_TARGET_DERIVED';
    }
    return 'UNKNOWN';
  }

  private relationshipDirectionLabel(r: GroupCharacterRelationshipMemory): string {
    const target: string = r.targetType === GroupRelationshipTargetType.User
      ? '用户' : r.targetId;
    return r.ownerCharacterId + ' → ' + target;
  }

  private relationshipSummaryPreview(r: GroupCharacterRelationshipMemory): string {
    const parts: string[] = [];
    if (r.relationshipSummary.length > 0) {
      parts.push(r.relationshipSummary);
    }
    if (r.attitudeSummary.length > 0) {
      parts.push(r.attitudeSummary);
    }
    if (r.experienceSummary.length > 0) {
      parts.push(r.experienceSummary);
    }
    return parts.join(' · ');
  }

  private importanceOptions(): number[] {
    const opts: number[] = [];
    for (let n: number = GROUP_MEMORY_IMPORTANCE_MIN; n <= GROUP_MEMORY_IMPORTANCE_MAX; n++) {
      opts.push(n);
    }
    return opts;
  }

  // ===== G-MEMORY-AUTO-1B 关系与经历 =====

  /**
   * 关系视图主内容。
   * - 顶部视角提示
   * - 操作栏(总结新关系按钮)
   * - 关系列表
   */
  @Builder
  relationshipContentView(): void {
    Column() {
      // 视角提示
      Text(this.buildRelationshipPerspectiveHint())
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        .textAlign(TextAlign.Start)

      // 操作栏
      Row() {
        Text('关系记录: ' + this.relationshipList.length.toString() + ' 条')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)

        Button(this.isPreparingRelationship ? '总结中…' : '总结新关系')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(this.canUseRelationship()
            && !this.isPreparingRelationship
            && !this.isApprovingRelationship
            && !this.isSaving && !this.isDeleting
            && !this.isSummarizing && !this.isApprovingSummaryState)
          .accessibilityText('总结新关系')
          .onClick(() => { this.handlePrepareRelationship(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      // 错误提示
      if (this.relationshipActionError.length > 0) {
        Text(this.relationshipActionError)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      // 列表
      if (this.isRelationshipListLoading) {
        Column() {
          LoadingProgress().width(32).height(32).color($r('app.color.app_accent'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.relationshipList.length === 0) {
        Column() {
          EmptyStateView({
            title: '暂无关系记录',
            description: this.canUseRelationship() ? '点击"总结新关系"生成关系记忆' : '关系总结服务未初始化'
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.relationshipList, (r: RelationshipListItemUiModel) => {
            ListItem() {
              this.relationshipCard(r)
            }
          }, (r: RelationshipListItemUiModel) => r.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 关系视角提示文本 */
  private buildRelationshipPerspectiveHint(): string {
    const name: string = this.header !== null ? this.header.displayName : '角色';
    return '以下内容以 ' + name + ' 的视角记录';
  }

  /** 是否可以使用关系功能 */
  private canUseRelationship(): boolean {
    return this.viewModel !== null && this.viewModel.canUseRelationship();
  }

  /**
   * G-CONTEXT-INSPECTOR-1: 上下文检查视图。
   * 只读诊断显示,不改变任何业务语义。
   * G-CONTEXT-MEMORY-SELECTION-1: 记忆已完成选择(selected>=0),尚未注入(injected=0)。
   */
  @Builder
  contextInspectorContentView(): void {
    Scroll() {
      Column() {
        if (this.isInspectionLoading) {
          Row() {
            LoadingProgress().width(20).height(20)
            Text('加载中…')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 32, bottom: 32 })
        } else if (this.inspectionSnapshot === null) {
          Column() {
            Text('暂无上下文快照')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_secondary'))
              .textAlign(TextAlign.Center)
            Text('发送消息后会自动捕获最近一次的 Prompt 诊断数据')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .textAlign(TextAlign.Center)
              .margin({ top: 8 })
              .padding({ left: 32, right: 32 })
          }
          .width('100%')
          .padding({ top: 48, bottom: 48 })
          .alignItems(HorizontalAlign.Center)
        } else {
          this.inspectionOverviewSection()
          this.contextAdjustmentSection()
          this.inspectionHistoryVisibilitySection()
          this.inspectionMemorySelectionStatusSection()
          this.inspectionMemorySelectionSection()
          this.inspectionRelationshipSelectionSection()
          this.inspectionMemoryInjectionSection()
          this.inspectionRelationshipInjectionSection()
          this.inspectionMemorySection()
          this.inspectionRelationshipSection()
          this.inspectionTokenBudgetSection()
          this.inspectionPromptMessagesSection()
          this.inspectionGroupConstraintSection()
        }
      }
      .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
  }

  /** 快照概览 */
  @Builder
  inspectionOverviewSection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
        Text('快照概览')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ bottom: 6 })

        Row() {
          Text('角色:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(this.inspectionSnapshot.speakerCharacterName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .fontWeight(FontWeight.Medium)
            .margin({ left: 4 })
        }
        .width('100%')

        Row() {
          Text('回复模式:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(this.inspectionSnapshot.replyTargetMode)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4 })
        }
        .width('100%')
        .margin({ top: 4 })

        Row() {
          Text('参与者:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(this.inspectionSnapshot.participantNames.join('、'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4 })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_md'))
      .margin({ left: 12, right: 12, top: 8 })
    }
  }

  /**
   * G-CONTEXT-INSPECTOR-1: 调整上下文窗口。
   * 持久化到当前 ProviderConfig,仅修改 contextWindow 字段。
   * 新的一轮对话生效;已运行中的轮次不受影响。
   */
  @Builder
  contextAdjustmentSection(): void {
    Column() {
      Text('调整上下文窗口')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      // 当前生效值(来自快照,只读)
      Row() {
        Text('当前生效:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        if (this.inspectionSnapshot !== null) {
          Text(String(this.inspectionSnapshot.tokenBudget.contextWindow))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .fontWeight(FontWeight.Medium)
            .margin({ left: 4 })
        } else {
          Text('-')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 配置值(可编辑)
      Row() {
        Text('配置值:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))

        TextInput({ text: this.contextWindowInput, placeholder: '如 65536' })
          .fontSize($r('app.float.app_font_caption'))
          .type(InputType.Number)
          .layoutWeight(1)
          .height(34)
          .margin({ left: 8 })
          .onChange((value: string) => {
            this.contextWindowInput = value;
          })
          .accessibilityText('上下文窗口输入')

        Button(this.isSavingContextWindow ? '保存中…' : '保存')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .enabled(!this.isSavingContextWindow)
          .accessibilityText('保存上下文窗口')
          .key('groupMemory.context.saveContextWindow')
          .onClick(() => { this.handleSaveContextWindow(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      Text('范围 1024 ~ 1048576,持久化到当前模型配置,下一轮对话生效')
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)

      if (this.contextAdjustMessage.length > 0) {
        Text(this.contextAdjustMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.contextAdjustIsError
            ? $r('app.color.app_danger') : $r('app.color.app_accent'))
          .width('100%')
          .margin({ top: 4 })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
  }

  /**
   * G-CONTEXT-VISIBILITY-1: 历史消息可见性诊断。
   * 显示每条原始历史消息是否进入 Prompt 及原因。
   * 本地页面显示完整正文;不持久化。
   */
  @Builder
  inspectionHistoryVisibilitySection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
        Text('历史可见性 (' + String(this.inspectionSnapshot.historyVisibility !== undefined
          ? this.inspectionSnapshot.historyVisibility.length : 0) + ' 条)')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ bottom: 6 })

        Row() {
          Text('输入:')
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.visibilitySummary !== undefined
            ? this.inspectionSnapshot.visibilitySummary.inputCount : 0))
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 2, right: 10 })

          Text('进入:')
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.visibilitySummary !== undefined
            ? this.inspectionSnapshot.visibilitySummary.includedCount : 0))
            .fontSize(11)
            .fontColor($r('app.color.app_accent'))
            .margin({ left: 2, right: 10 })

          Text('排除:')
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.visibilitySummary !== undefined
            ? this.inspectionSnapshot.visibilitySummary.excludedCount : 0))
            .fontSize(11)
            .fontColor($r('app.color.app_danger'))
            .margin({ left: 2 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 6 })

        if (this.inspectionSnapshot.historyVisibility !== undefined) {
          ForEach(
            this.inspectionSnapshot.historyVisibility,
            (item: HistoryVisibilityInspectionItem, index: number) => {
              Column() {
                Row() {
                  Text('[' + String(index) + ']')
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                    .width(28)

                  Text(item.visibleToCurrentCharacter ? '进入' : '排除')
                    .fontSize(11)
                    .fontColor(item.visibleToCurrentCharacter
                      ? $r('app.color.app_accent') : $r('app.color.app_danger'))
                    .backgroundColor($r('app.color.app_surface_1'))
                    .borderRadius(3)
                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    .width(34)
                    .textAlign(TextAlign.Center)

                  Text(item.senderType === 'narrator' ? '旁白' : item.senderType)
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                    .margin({ left: 4 })

                  Text(item.status)
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                    .margin({ left: 4 })

                  Text(item.visibility)
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                    .margin({ left: 4 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                Text(item.decisionReason)
                  .fontSize(11)
                  .fontColor(item.visibleToCurrentCharacter
                    ? $r('app.color.app_accent') : $r('app.color.app_danger'))
                  .width('100%')
                  .margin({ top: 2 })
                  .textAlign(TextAlign.Start)

                if (!item.enteredFinalPrompt && item.visibleToCurrentCharacter) {
                  Text('可见但被裁剪,未进入最终 Prompt')
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }

                Text(item.content)
                  .fontSize(11)
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Start)
                  .margin({ top: 2 })
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            },
            (item: HistoryVisibilityInspectionItem, index: number) => item.messageId
          )
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_md'))
      .margin({ left: 12, right: 12, top: 8 })
    }
  }

  /**
   * G-CONTEXT-MEMORY-SELECTION-1: 当前事实横幅。
   * 醒目显示"本阶段已完成记忆选择,尚未注入最终 Prompt"。
   */
  @Builder
  inspectionMemorySelectionStatusSection(): void {
    if (this.inspectionSnapshot !== null
      && this.inspectionSnapshot.memorySelection !== undefined) {
      this.inspectionMemorySelectionStatusBody(this.inspectionSnapshot.memorySelection)
    } else {
      Column() {
        Text('本阶段已完成记忆选择,尚未注入最终 Prompt')
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_on_accent'))
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 4 })
    }
  }

  @Builder
  inspectionMemorySelectionStatusBody(sel: GroupCharacterMemorySelection): void {
    Column() {
      Row() {
        Text('已选择,尚未注入 Prompt')
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_on_accent'))
        Text(String(sel.selectedPersonalMemories.length) + ' 条记忆 · '
          + String(sel.selectedRelationships.length) + ' 条关系')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .margin({ left: 8 })
        Blank().layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.app_accent'))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(VerticalAlign.Center)

      if (sel.personalQueryFailed || sel.relationshipQueryFailed || sel.reverseQueryFailed) {
        Text('记忆或关系查询失败,已安全降级,未影响角色生成')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 4 })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 4 })
  }

  /**
   * G-CONTEXT-MEMORY-SELECTION-1: 个人记忆选择详情。
   * 展示全部记忆 / 实际选择 / 未选择原因。
   */
  @Builder
  inspectionMemorySelectionSection(): void {
    if (this.inspectionSnapshot !== null
      && this.inspectionSnapshot.memorySelection !== undefined) {
      this.inspectionMemorySelectionSectionBody(this.inspectionSnapshot.memorySelection)
    }
  }

  @Builder
  inspectionMemorySelectionSectionBody(sel: GroupCharacterMemorySelection): void {
    Column() {
      Text('记忆选择详情 (' + String(sel.allPersonalMemories.length) + ' 条全部 / '
        + String(sel.eligiblePersonalMemories.length) + ' 条合格 / '
        + String(sel.selectedPersonalMemories.length) + ' 条选中)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      // 实际选择
      if (sel.selectedPersonalMemories.length > 0) {
        Text('实际选择')
          .fontSize(11)
          .fontColor($r('app.color.app_accent'))
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        ForEach(sel.selectedPersonalMemories, (s: SelectedPersonalMemory) => {
          Column() {
            Row() {
              Text('#' + String(s.finalRank))
                .fontSize(11)
                .fontColor($r('app.color.app_accent'))
              Text(s.memory.title)
                .fontSize(11)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 6 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Text(s.memory.content)
              .fontSize(11)
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
              .margin({ top: 2 })
            Row() {
              Text(s.selectionReason)
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
              Text('关键词命中 ' + String(s.keywordHitCount))
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .margin({ left: 6 })
              Text('估 ' + String(s.estimatedTokens) + ' / 累计 '
                + String(s.cumulativeTokens))
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .margin({ left: 6 })
            }
            .width('100%')
            .margin({ top: 2 })
            Text('ID: ' + s.memory.id)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }, (s: SelectedPersonalMemory) => s.memory.id)
      }

      // 未选择
      if (sel.excludedPersonalMemories.length > 0) {
        Text('未选择 (' + String(sel.excludedPersonalMemories.length) + ')')
          .fontSize(11)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        ForEach(sel.excludedPersonalMemories, (e: ExcludedPersonalMemory) => {
          Column() {
            Row() {
              Text(this.memoryExclusionLabel(e.reason))
                .fontSize(10)
                .fontColor($r('app.color.app_danger'))
                .backgroundColor($r('app.color.app_surface_1'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              Text(e.memory.title)
                .fontSize(11)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 6 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            if (e.reason === GroupCharacterMemoryExclusionReason.EXCLUDED_DUPLICATE
              && e.duplicateOfMemoryId.length > 0) {
              Text('重复,保留 ID: ' + e.duplicateOfMemoryId)
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            Text(e.memory.content)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ top: 3, bottom: 3 })
        }, (e: ExcludedPersonalMemory) => e.memory.id)
      }

      // 全部个人记忆
      Text('全部记忆 (' + String(sel.allPersonalMemories.length) + ')')
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 4 })
      ForEach(sel.allPersonalMemories, (m: GroupCharacterMemory) => {
        Column() {
          Row() {
            Text(m.origin === GroupCharacterMemoryOrigin.Manual ? '手动' : '自动')
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .backgroundColor($r('app.color.app_surface_1'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            Text(m.status)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .backgroundColor($r('app.color.app_surface_1'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 4 })
            Text(m.title)
              .fontSize(11)
              .fontColor($r('app.color.app_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text(m.content)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Start)
            .margin({ top: 2 })
          Row() {
            Text('ID: ' + m.id)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
            if (m.sourceMessageId !== undefined && m.sourceMessageId.length > 0) {
              Text(' · 来源消息: ' + m.sourceMessageId)
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .margin({ left: 4 })
            }
            if (m.sourceType !== undefined && m.sourceType.length > 0) {
              Text(' · ' + m.sourceType)
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .margin({ left: 4 })
            }
          }
          .width('100%')
          .margin({ top: 2 })
        }
        .width('100%')
        .padding({ top: 3, bottom: 3 })
      }, (m: GroupCharacterMemory) => m.id)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
  }

  /**
   * G-CONTEXT-MEMORY-SELECTION-1 / -1B: 关系选择详情。
   * 展示全部拥有关系 / 实际选择(含来源) / 未选择原因 / 反向关系(仅诊断)。
   */
  @Builder
  inspectionRelationshipSelectionSection(): void {
    if (this.inspectionSnapshot !== null
      && this.inspectionSnapshot.memorySelection !== undefined) {
      this.inspectionRelationshipSelectionSectionBody(this.inspectionSnapshot.memorySelection)
    }
  }

  @Builder
  inspectionRelationshipSelectionSectionBody(sel: GroupCharacterMemorySelection): void {
    Column() {
      Text('关系选择详情 (' + String(sel.allOwnedRelationships.length) + ' 条拥有 / '
        + String(sel.selectedRelationships.length) + ' 条选中 / 反向 '
        + String(sel.reverseRelationships.length) + ' 条)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      // G-CONTEXT-MEMORY-SELECTION-1B: 回复目标诊断说明
      if (this.inspectionSnapshot !== null
        && this.inspectionSnapshot.replyTargetCharacterIds !== undefined
        && this.inspectionSnapshot.replyTargetCharacterIds.length > 0) {
        Text('本轮回复目标: ' + this.inspectionSnapshot.replyTargetCharacterIds.join('、'))
          .fontSize(10)
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      Text('回复目标只控制发言者,不用于选择关系记忆')
        .fontSize(10)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 2 })

      // 实际选择
      if (sel.selectedRelationships.length > 0) {
        Text('实际选择')
          .fontSize(11)
          .fontColor($r('app.color.app_accent'))
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        ForEach(sel.selectedRelationships, (r: SelectedRelationshipMemory) => {
          Column() {
            Row() {
              Text('#' + String(r.finalRank))
                .fontSize(11)
                .fontColor($r('app.color.app_accent'))
              Text(this.relationshipDirectionLabel(r.memory))
                .fontSize(11)
                .fontColor($r('app.color.app_text_primary'))
                .layoutWeight(1)
                .margin({ left: 6 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Text('来源: ' + this.relationshipSourceLabel(r.source)
              + ' · ' + r.selectionReason)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .margin({ top: 2 })
              .textAlign(TextAlign.Start)
            Text('估 ' + String(r.estimatedTokens) + ' / 累计 '
              + String(r.cumulativeTokens))
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
            Text('ID: ' + r.memory.id)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }, (r: SelectedRelationshipMemory) => r.memory.id)
      }

      // 未选择
      if (sel.excludedRelationships.length > 0) {
        Text('未选择 (' + String(sel.excludedRelationships.length) + ')')
          .fontSize(11)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        ForEach(sel.excludedRelationships, (e: ExcludedRelationshipMemory) => {
          Column() {
            Row() {
              Text(this.relationshipExclusionLabel(e.reason))
                .fontSize(10)
                .fontColor($r('app.color.app_danger'))
                .backgroundColor($r('app.color.app_surface_1'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              Text(this.relationshipDirectionLabel(e.memory))
                .fontSize(11)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 6 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            if (e.reason === GroupCharacterRelationshipExclusionReason.EXCLUDED_DUPLICATE
              && e.duplicateOfId.length > 0) {
              Text('重复,保留 ID: ' + e.duplicateOfId)
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
          }
          .width('100%')
          .padding({ top: 3, bottom: 3 })
        }, (e: ExcludedRelationshipMemory) => e.memory.id)
      }

      // 全部拥有关系
      Text('全部拥有关系 (' + String(sel.allOwnedRelationships.length) + ')')
        .fontSize(11)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 4, bottom: 4 })
      ForEach(sel.allOwnedRelationships, (r: GroupCharacterRelationshipMemory) => {
        Column() {
          Row() {
            Text(this.relationshipDirectionLabel(r))
              .fontSize(11)
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)
            Text(r.status)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .backgroundColor($r('app.color.app_surface_1'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Text(this.relationshipSummaryPreview(r))
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Start)
            .margin({ top: 2 })
          Text('ID: ' + r.id)
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ top: 3, bottom: 3 })
      }, (r: GroupCharacterRelationshipMemory) => r.id)

      // 反向关系(仅诊断)
      if (sel.reverseRelationships.length > 0) {
        Text('反向关系(仅诊断,不属于当前角色,不进入 Prompt)')
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 4, bottom: 4 })
        ForEach(sel.reverseRelationships, (r: GroupCharacterRelationshipMemory) => {
          Column() {
            Text(this.relationshipDirectionLabel(r))
              .fontSize(11)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
            Text('ID: ' + r.id)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        }, (r: GroupCharacterRelationshipMemory) => r.id)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
  }

  /**
   * G-CONTEXT-PROMPT-INJECTION-1: 个人记忆注入详情。
   * 展示 selected/formatted/injected 逐条状态 + 最终注入段完整正文。
   */
  @Builder
  inspectionMemoryInjectionSection(): void {
    if (this.inspectionSnapshot !== null
      && this.inspectionSnapshot.memoryInjectionItems !== undefined) {
      this.inspectionMemoryInjectionSectionBody(this.inspectionSnapshot)
    }
  }

  @Builder
  inspectionMemoryInjectionSectionBody(snap: GroupPromptInspectionSnapshot): void {
    Column() {
      Text('个人记忆注入 (' + String(snap.totalMemoriesFormatted !== undefined
        ? snap.totalMemoriesFormatted : 0) + ' 格式化 / '
        + String(snap.totalMemoriesInjected) + ' 注入)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      ForEach(snap.memoryInjectionItems !== undefined ? snap.memoryInjectionItems : [],
        (item: MemoryInjectionInspectionItem) => {
          Column() {
            Row() {
              Text(item.injected ? '注入' : (item.formatted ? '已格式化' : '未格式化'))
                .fontSize(10)
                .fontColor(item.injected
                  ? $r('app.color.app_accent')
                  : (item.formatted ? $r('app.color.app_text_secondary') : $r('app.color.app_danger')))
                .backgroundColor($r('app.color.app_surface_1'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              Text(item.title)
                .fontSize(11)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 6 })
              Text('msg#' + (item.messageIndex >= 0 ? String(item.messageIndex) : '-'))
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            if (item.failureReason.length > 0) {
              Text('未注入: ' + item.failureReason)
                .fontSize(10)
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            Text('估 ' + String(item.estimatedTokens) + ' Token · ID: ' + item.memoryId)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ top: 3, bottom: 3 })
        },
        (item: MemoryInjectionInspectionItem) => item.memoryId
      )

      if (snap.personalMemorySegmentText !== undefined
        && snap.personalMemorySegmentText.length > 0) {
        Text('最终注入段完整正文')
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 6, bottom: 4 })
        Text(snap.personalMemorySegmentText)
          .fontSize(10)
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .lineHeight(14)
      } else {
        Text('本阶段未注入个人记忆段(无选中或段被裁剪)')
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
  }

  /**
   * G-CONTEXT-PROMPT-INJECTION-1: 关系注入详情。
   * 展示 selected/formatted/injected 逐条状态 + 来源 + 最终注入段完整正文。
   */
  @Builder
  inspectionRelationshipInjectionSection(): void {
    if (this.inspectionSnapshot !== null
      && this.inspectionSnapshot.relationshipInjectionItems !== undefined) {
      this.inspectionRelationshipInjectionSectionBody(this.inspectionSnapshot)
    }
  }

  @Builder
  inspectionRelationshipInjectionSectionBody(snap: GroupPromptInspectionSnapshot): void {
    Column() {
      Text('关系注入 (' + String(snap.totalRelationshipsFormatted !== undefined
        ? snap.totalRelationshipsFormatted : 0) + ' 格式化 / '
        + String(snap.totalRelationshipsInjected) + ' 注入)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      ForEach(snap.relationshipInjectionItems !== undefined ? snap.relationshipInjectionItems : [],
        (item: RelationshipInjectionInspectionItem) => {
          Column() {
            Row() {
              Text(item.injected ? '注入' : (item.formatted ? '已格式化' : '未格式化'))
                .fontSize(10)
                .fontColor(item.injected
                  ? $r('app.color.app_accent')
                  : (item.formatted ? $r('app.color.app_text_secondary') : $r('app.color.app_danger')))
                .backgroundColor($r('app.color.app_surface_1'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              Text(item.direction)
                .fontSize(11)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 6 })
              Text('msg#' + (item.messageIndex >= 0 ? String(item.messageIndex) : '-'))
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            if (item.failureReason.length > 0) {
              Text('未注入: ' + item.failureReason)
                .fontSize(10)
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            Text('来源: ' + item.source + ' · 估 ' + String(item.estimatedTokens)
              + ' Token · ID: ' + item.relationshipId)
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ top: 3, bottom: 3 })
        },
        (item: RelationshipInjectionInspectionItem) => item.relationshipId
      )

      if (snap.relationshipMemorySegmentText !== undefined
        && snap.relationshipMemorySegmentText.length > 0) {
        Text('最终注入段完整正文')
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 6, bottom: 4 })
        Text(snap.relationshipMemorySegmentText)
          .fontSize(10)
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .lineHeight(14)
      } else {
        Text('本阶段未注入关系段(无选中或段被裁剪)')
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
  }

  /** 记忆诊断 */
  @Builder
  inspectionMemorySection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
        Text('记忆注入状态')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ bottom: 6 })

        Row() {
          Text('已存储:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.totalMemoriesStored))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .fontWeight(FontWeight.Medium)
            .margin({ left: 4, right: 16 })

          Text('活跃:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.totalMemoriesActive))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4, right: 16 })

          Text('已选:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.totalMemoriesSelected))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .margin({ left: 4, right: 16 })

          Text('已注入:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.totalMemoriesInjected))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.inspectionSnapshot.totalMemoriesInjected > 0
              ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
            .margin({ left: 4 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.inspectionSnapshot.totalMemoriesStored > 0
          && this.inspectionSnapshot.totalMemoriesInjected === 0) {
          Text('本阶段已完成选择,尚未注入最终 Prompt')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .margin({ top: 6 })
            .textAlign(TextAlign.Start)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_md'))
      .margin({ left: 12, right: 12, top: 8 })
    }
  }

  /** 关系诊断 */
  @Builder
  inspectionRelationshipSection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
      Text('关系注入状态')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      Row() {
        Text('已存储:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        Text(String(this.inspectionSnapshot.totalRelationshipsStored))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .fontWeight(FontWeight.Medium)
          .margin({ left: 4, right: 16 })

        Text('活跃:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        Text(String(this.inspectionSnapshot.totalRelationshipsActive))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ left: 4, right: 16 })

        Text('已选:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        Text(String(this.inspectionSnapshot.totalRelationshipsSelected))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .margin({ left: 4, right: 16 })

        Text('已注入:')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        Text(String(this.inspectionSnapshot.totalRelationshipsInjected))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.inspectionSnapshot.totalRelationshipsInjected > 0
            ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
          .margin({ left: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.inspectionSnapshot.reverseRelationships.length > 0) {
        Text('反向关系(不会作为当前角色的关系注入):')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 8 })

        ForEach(
          this.inspectionSnapshot.reverseRelationships,
          (rel: RelationshipInspectionItem) => {
            Row() {
              Text(rel.ownerCharacterName + ' → ' + rel.targetName)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
            }
            .width('100%')
            .padding({ left: 8, top: 2, bottom: 2 })
          },
          (rel: RelationshipInspectionItem) => rel.id
        )
      }

      if (this.inspectionSnapshot.totalRelationshipsStored > 0
        && this.inspectionSnapshot.totalRelationshipsInjected === 0) {
        Text('本阶段已完成选择,尚未注入最终 Prompt')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 6 })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
    }
  }

  /** Token 预算 */
  @Builder
  inspectionTokenBudgetSection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
        Text('Token 预算')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ bottom: 6 })

        Row() {
          Text('上下文窗口:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.tokenBudget.contextWindow))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4, right: 16 })

          Text('输入预算:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.tokenBudget.availableInputTokens))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4, right: 16 })

          Text('估算使用:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.tokenBudget.estimatedTotalTokens)
            + ' (' + String(this.inspectionSnapshot.tokenBudget.usagePercent) + '%)')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.inspectionSnapshot.tokenBudget.usagePercent > 90
              ? $r('app.color.app_danger') : $r('app.color.app_text_secondary'))
            .margin({ left: 4 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Text('裁剪前:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.tokenBudget.totalMessagesBeforeTrim) + ' 条')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4, right: 16 })

          Text('裁剪后:')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(String(this.inspectionSnapshot.tokenBudget.totalMessagesAfterTrim) + ' 条')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4, right: 16 })

          if (this.inspectionSnapshot.tokenBudget.trimmedMessageCount > 0) {
            Text('裁剪:')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
            Text('-' + String(this.inspectionSnapshot.tokenBudget.trimmedMessageCount) + ' 条')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .margin({ left: 4 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4 })

        Progress({
          value: this.inspectionSnapshot.tokenBudget.estimatedTotalTokens,
          total: this.inspectionSnapshot.tokenBudget.availableInputTokens
        })
          .width('100%')
          .height(6)
          .borderRadius(3)
          .margin({ top: 8 })
          .color(this.inspectionSnapshot.tokenBudget.usagePercent > 90
            ? $r('app.color.app_danger') : $r('app.color.app_accent'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_md'))
      .margin({ left: 12, right: 12, top: 8 })
    }
  }

  /** Prompt 消息列表 */
  @Builder
  inspectionPromptMessagesSection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
      Text('Prompt 消息 (' + String(this.inspectionSnapshot.promptMessages.length) + ' 条)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      ForEach(
        this.inspectionSnapshot.promptMessages,
        (msg: PromptMessageInspectionItem, index: number) => {
          Row() {
            Text('[' + String(index) + ']')
              .fontSize(11)
              .fontColor($r('app.color.app_text_tertiary'))
              .width(28)

            Text(msg.category)
              .fontSize(11)
              .fontColor($r('app.color.app_accent'))
              .backgroundColor($r('app.color.app_surface_1'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .width(52)
              .textAlign(TextAlign.Center)

            Text(msg.contentPreview)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 3, bottom: 3 })
        },
        (msg: PromptMessageInspectionItem, index: number) => String(index)
      )

      Row() {
        Text('世界书匹配: ' + String(this.inspectionSnapshot.lorebook.matchedEntryCount) + ' 条')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8 })
    }
  }

  /** 群聊约束 */
  @Builder
  inspectionGroupConstraintSection(): void {
    if (this.inspectionSnapshot !== null) {
      Column() {
      Text('群聊约束指令')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 6 })

      if (this.inspectionSnapshot.presetSystemPromptPreview.length > 0) {
        Text('预设 System Prompt:')
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ bottom: 2 })
        Text(this.inspectionSnapshot.presetSystemPromptPreview)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
          .margin({ bottom: 8 })
      }

      Text('群聊约束:')
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 2 })
      Text(this.inspectionSnapshot.groupConstraintPreview)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .maxLines(10)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ left: 12, right: 12, top: 8, bottom: 16 })
    }
  }

  /**
   * 关系卡片。
   * 显示:对象头像/名称、方向标签、关系摘要、态度摘要、重要度、关键词、更新时间、状态。
   */
  @Builder
  relationshipCard(r: RelationshipListItemUiModel): void {
    Column() {
      // 第一行:对象头像 + 名称 + 方向标签
      Row() {
        CharacterImageView({
          imageUri: r.targetAvatarUri,
          fallbackName: r.targetName,
          imgWidth: 32,
          imgHeight: 32,
          imgBorderRadius: 16,
          displayMode: 'thumbnail'
        })

        Column() {
          Text(r.targetName)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(r.directionLabel)
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })

        // 状态标签
        Text(r.statusLabel)
          .fontSize(11)
          .fontColor(r.status === GroupRelationshipMemoryStatus.Active
            ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })

        if (r.isTargetRemoved) {
          Text('已移出群聊')
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 关系摘要
      if (r.relationshipSummary.length > 0) {
        Text(r.relationshipSummary)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 6 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
      }

      // 态度摘要
      if (r.attitudeSummary.length > 0) {
        Text('态度:' + r.attitudePreview)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
      }

      // 重要度 + 关键词 + 时间
      Row() {
        Text(this.importanceLabel(r.importance))
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })

        if (r.keywordsText.length > 0) {
          Text(r.keywordsText)
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 140 })
        }

        Blank().layoutWeight(1)

        Text(r.updatedAtLabel)
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => { this.openRelationshipDetail(r.id); })
  }

  /**
   * 关系详情 Stack 覆盖层。
   * 显示完整关系信息,提供 修改 / 归档 / 恢复 入口。
   */
  @Builder
  relationshipDetailOverlay(): void {
    Stack() {
      Column() {
        if (this.relationshipDetail === null) {
          Text('关系记录不存在或已删除')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ top: 24, bottom: 24 })
          Button('关闭')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .padding({ left: 24, right: 24 })
            .margin({ bottom: 16 })
            .onClick(() => { this.closeRelationshipDetail(); })
        } else {
          // 标题栏
          Row() {
            Text('关系详情')
              .fontSize($r('app.float.app_font_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)

            Button('关闭')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_accent'))
              .backgroundColor(Color.Transparent)
              .height(32)
              .accessibilityText('关闭关系详情')
              .onClick(() => { this.closeRelationshipDetail(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 12 })

          // 可滚动内容区
          Scroll() {
            Column() {
              // 视角提示
              Text(this.buildRelationshipPerspectiveHint())
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .margin({ top: 0, bottom: 12 })
                .textAlign(TextAlign.Start)

              // 对象信息 + 方向
              Row() {
                CharacterImageView({
                  imageUri: this.relationshipDetail.targetAvatarUri,
                  fallbackName: this.relationshipDetail.targetName,
                  imgWidth: 40,
                  imgHeight: 40,
                  imgBorderRadius: 20,
                  displayMode: 'thumbnail'
                })
                Column() {
                  Text(this.relationshipDetail.targetName)
                    .fontSize($r('app.float.app_font_body'))
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.app_text_primary'))
                  Text(this.relationshipDetail.directionLabel)
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 10 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              // 状态标签
              Row() {
                Text(this.relationshipDetail.statusLabel)
                  .fontSize(11)
                  .fontColor(this.relationshipDetail.status === GroupRelationshipMemoryStatus.Active
                    ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })

                Text(this.importanceLabel(this.relationshipDetail.importance))
                  .fontSize(11)
                  .fontColor($r('app.color.app_text_secondary'))
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .margin({ left: 6 })

                if (this.relationshipDetail.isTargetRemoved) {
                  Text('已移出群聊')
                    .fontSize(11)
                    .fontColor($r('app.color.app_text_tertiary'))
                    .backgroundColor($r('app.color.app_surface_2'))
                    .borderRadius(3)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .margin({ left: 6 })
                }
              }
              .width('100%')
              .margin({ top: 8 })
              .alignItems(VerticalAlign.Center)

              // 共同经历
              if (this.relationshipDetail.experienceSummary.length > 0) {
                Text('共同经历')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 16 })
                  .textAlign(TextAlign.Start)
                Text(this.relationshipDetail.experienceSummary)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_text_primary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 态度
              if (this.relationshipDetail.attitudeSummary.length > 0) {
                Text('态度')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 16 })
                  .textAlign(TextAlign.Start)
                Text(this.relationshipDetail.attitudeSummary)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_text_primary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 关系
              if (this.relationshipDetail.relationshipSummary.length > 0) {
                Text('当前关系')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 16 })
                  .textAlign(TextAlign.Start)
                Text(this.relationshipDetail.relationshipSummary)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_text_primary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 关键词
              if (this.relationshipDetail.keywordsText.length > 0) {
                Text('关键词')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 16 })
                  .textAlign(TextAlign.Start)
                Text(this.relationshipDetail.keywordsText)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_text_secondary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 来源消息数量
              Text('来源消息:' + this.relationshipDetail.sourceMessageCount.toString() + ' 条')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .margin({ top: 16 })
                .textAlign(TextAlign.Start)

              // 时间信息
              Text('创建:' + this.relationshipDetail.createdAtLabel)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .margin({ top: 8 })
                .textAlign(TextAlign.Start)
              if (this.relationshipDetail.updatedAt !== this.relationshipDetail.createdAt
                && this.relationshipDetail.updatedAtLabel.length > 0) {
                Text('更新:' + this.relationshipDetail.updatedAtLabel)
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_text_tertiary'))
                  .width('100%')
                  .margin({ top: 4 })
                  .textAlign(TextAlign.Start)
              }

              // 操作按钮
              if (this.relationshipDetail.canEdit || this.relationshipDetail.canArchive) {
                Row() {
                  if (this.relationshipDetail.canEdit) {
                    Button('修改')
                      .fontSize($r('app.float.app_font_body'))
                      .backgroundColor($r('app.color.app_accent'))
                      .fontColor($r('app.color.app_on_accent'))
                      .borderRadius($r('app.float.app_radius_sm'))
                      .height(40)
                      .padding({ left: 16, right: 16 })
                      .layoutWeight(1)
                      .enabled(!this.isSaving && !this.isDeleting)
                      .accessibilityText('修改关系')
                      .onClick(() => {
                        if (this.relationshipDetail !== null) {
                          this.openRelationshipEdit(this.relationshipDetail);
                        }
                      })
                  }

                  if (this.relationshipDetail.canArchive) {
                    if (this.relationshipDetail.status === GroupRelationshipMemoryStatus.Active) {
                      Button('归档')
                        .fontSize($r('app.float.app_font_body'))
                        .backgroundColor($r('app.color.app_surface_2'))
                        .fontColor($r('app.color.app_text_secondary'))
                        .borderRadius($r('app.float.app_radius_sm'))
                        .height(40)
                        .padding({ left: 16, right: 16 })
                        .margin({ left: 8 })
                        .layoutWeight(1)
                        .enabled(!this.isSaving && !this.isDeleting)
                        .accessibilityText('归档关系')
                        .onClick(() => {
                          if (this.relationshipDetail !== null) {
                            this.handleRelationshipArchive(this.relationshipDetail);
                          }
                        })
                    } else if (this.relationshipDetail.status === GroupRelationshipMemoryStatus.Archived) {
                      Button('恢复')
                        .fontSize($r('app.float.app_font_body'))
                        .backgroundColor($r('app.color.app_surface_2'))
                        .fontColor($r('app.color.app_accent'))
                        .borderRadius($r('app.float.app_radius_sm'))
                        .height(40)
                        .padding({ left: 16, right: 16 })
                        .margin({ left: 8 })
                        .layoutWeight(1)
                        .enabled(!this.isSaving && !this.isDeleting)
                        .accessibilityText('恢复关系')
                        .onClick(() => {
                          if (this.relationshipDetail !== null) {
                            this.handleRelationshipArchive(this.relationshipDetail);
                          }
                        })
                    }
                  }
                }
                .width('100%')
                .margin({ top: 24 })
                .justifyContent(FlexAlign.SpaceBetween)
                .alignItems(VerticalAlign.Center)
              }

              // 错误提示
              if (this.relationshipActionError.length > 0) {
                Text(this.relationshipActionError)
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.app_danger'))
                  .width('100%')
                  .margin({ top: 12 })
                  .padding({ top: 8, bottom: 8, left: 12, right: 12 })
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius($r('app.float.app_radius_sm'))
                  .textAlign(TextAlign.Start)
              }

              Blank().height(16)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
        }
      }
      .width('90%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_16')
      })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_lg'))
      .constraintSize({ maxHeight: '85%' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => { this.closeRelationshipDetail(); })
  }

  /**
   * 关系编辑表单 Stack 覆盖层。
   * 允许修改:共同经历 / 态度 / 关系 / 重要度 / 关键词。
   * 不可修改:targetType / targetId / owner / sourceMessageIds / sourceHash。
   */
  @Builder
  relationshipEditOverlay(): void {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Text('修改关系')
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)

          Text('关闭')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => { this.closeRelationshipEdit(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.app_divider'))

        // 可滚动表单内容
        Scroll() {
          Column() {
            // 对象信息(只读)
            if (this.relationshipDetail !== null) {
              Text('对象:' + this.relationshipDetail.targetName
                + '  方向:' + this.relationshipDetail.directionLabel)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }

            // 共同经历
            Text('共同经历')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextArea({ text: this.relFormExperience, placeholder: '双方发生过什么' })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(100)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(RELATIONSHIP_EXPERIENCE_MAX)
              .onChange((v: string) => { this.relFormExperience = v; })
            Text(this.relFormExperience.length.toString() + ' / ' + RELATIONSHIP_EXPERIENCE_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 态度
            Text('态度')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextArea({ text: this.relFormAttitude, placeholder: 'owner 对对方的态度' })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(100)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(RELATIONSHIP_ATTITUDE_MAX)
              .onChange((v: string) => { this.relFormAttitude = v; })
            Text(this.relFormAttitude.length.toString() + ' / ' + RELATIONSHIP_ATTITUDE_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 关系
            Text('当前关系')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextArea({ text: this.relFormRelationship, placeholder: '当前关系的谨慎概括' })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(100)
              .margin({ left: 16, right: 16, bottom: 4 })
              .maxLength(RELATIONSHIP_SUMMARY_MAX)
              .onChange((v: string) => { this.relFormRelationship = v; })
            Text(this.relFormRelationship.length.toString() + ' / ' + RELATIONSHIP_SUMMARY_MAX.toString())
              .fontSize(10)
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 8 })

            // 重要度
            Text('重要度')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            Row() {
              ForEach(this.relationshipImportanceOptions(), (n: number) => {
                Button(n.toString())
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(this.relFormImportance === n
                    ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
                  .backgroundColor(this.relFormImportance === n
                    ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
                  .borderRadius($r('app.float.app_radius_sm'))
                  .height(32)
                  .width(44)
                  .margin({ right: 6 })
                  .onClick(() => { this.relFormImportance = n; })
              }, (n: number) => n.toString())
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
            .alignItems(VerticalAlign.Center)

            // 关键词
            Text('关键词')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .width('100%')
              .padding({ left: 16, bottom: 4 })
            TextInput({ placeholder: '逗号分隔', text: this.relFormKeywords })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(44)
              .margin({ left: 16, right: 16, bottom: 8 })
              .onChange((v: string) => { this.relFormKeywords = v; })

            // 表单内错误提示
            if (this.relFormError.length > 0) {
              Text(this.relFormError)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 8 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)

        // 底部固定操作区
        Row() {
          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ right: 8 })
            .enabled(!this.isSaving)
            .onClick(() => { this.closeRelationshipEdit(); })
          Button(this.isSaving ? '保存中…' : '保存修改')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .enabled(!this.isSaving)
            .onClick(() => { this.submitRelationshipEdit(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .width('92%')
      .constraintSize({ maxHeight: '85%' })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => { this.closeRelationshipEdit(); })
  }

  /**
   * 关系候选审核 Stack 覆盖层。
   * 显示模型生成的所有候选,用户可逐条编辑、批准、拒绝。
   */
  @Builder
  relationshipReviewOverlay(): void {
    Stack() {
      Column() {
        // 标题栏
        Row() {
          Text('关系总结结果')
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)

          Text('关闭')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => { this.closeRelationshipReview(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.app_divider'))

        // 来源信息(只读)
        Text(this.buildRelationshipSourceInfo())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        // 候选列表
        if (this.relationshipCandidates.length === 0) {
          Column() {
            Text('没有形成明确的关系记忆')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_secondary'))
              .margin({ top: 24, bottom: 24 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Scroll() {
            Column() {
              ForEach(this.relationshipCandidates, (c: RelationshipCandidateUiModel) => {
                this.relationshipCandidateCard(c)
              }, (c: RelationshipCandidateUiModel) => c.targetType + '_' + c.targetId)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }

        // 审核错误提示
        if (this.relationshipReviewError.length > 0) {
          Text(this.relationshipReviewError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
        }

        // 底部固定操作区
        Row() {
          Button('全部拒绝')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ right: 6 })
            .enabled(!this.isApprovingRelationship)
            .onClick(() => { this.handleRejectAllCandidates(); })
          Button('全部批准')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ right: 6 })
            .enabled(!this.isApprovingRelationship && this.hasPendingCandidates())
            .onClick(() => { this.handleApproveAllCandidates(); })
          Button('完成')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .enabled(!this.isApprovingRelationship)
            .onClick(() => { this.handleFinishReview(); })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .width('92%')
      .constraintSize({ maxHeight: '90%' })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      if (!this.isApprovingRelationship) {
        this.closeRelationshipReview();
      }
    })
  }

  /**
   * 单个关系候选卡片(审核窗口内)。
   * 可编辑:experienceSummary / attitudeSummary / relationshipSummary / importance / keywords。
   * 操作:批准 / 拒绝。
   */
  @Builder
  relationshipCandidateCard(c: RelationshipCandidateUiModel): void {
    Column() {
      // 对象信息 + 方向 + 审核状态
      Row() {
        CharacterImageView({
          imageUri: c.targetAvatarUri,
          fallbackName: c.targetName,
          imgWidth: 32,
          imgHeight: 32,
          imgBorderRadius: 16,
          displayMode: 'thumbnail'
        })
        Column() {
          Text(c.targetName)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(c.directionLabel)
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })

        // 审核状态徽标
        if (c.reviewState === 'approved') {
          Text('已批准')
            .fontSize(11)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        } else if (c.reviewState === 'rejected') {
          Text('已拒绝')
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 来源消息数量(只读)
      Text('来源消息:' + c.sourceMessageIds.length.toString() + ' 条')
        .fontSize(10)
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ top: 4 })
        .textAlign(TextAlign.Start)

      // 共同经历(可编辑)
      Text('共同经历')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 8 })
        .textAlign(TextAlign.Start)
      TextArea({ text: c.experienceSummary, placeholder: '双方发生过什么' })
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .height(70)
        .margin({ top: 2 })
        .maxLength(RELATIONSHIP_EXPERIENCE_MAX)
        .enabled(c.reviewState === 'pending')
        .onChange((v: string) => {
          this.updateCandidateExperience(c, v);
        })

      // 态度(可编辑)
      Text('态度')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 8 })
        .textAlign(TextAlign.Start)
      TextArea({ text: c.attitudeSummary, placeholder: 'owner 对对方的态度' })
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .height(70)
        .margin({ top: 2 })
        .maxLength(RELATIONSHIP_ATTITUDE_MAX)
        .enabled(c.reviewState === 'pending')
        .onChange((v: string) => {
          this.updateCandidateAttitude(c, v);
        })

      // 关系(可编辑)
      Text('当前关系')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 8 })
        .textAlign(TextAlign.Start)
      TextArea({ text: c.relationshipSummary, placeholder: '当前关系的谨慎概括' })
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .height(70)
        .margin({ top: 2 })
        .maxLength(RELATIONSHIP_SUMMARY_MAX)
        .enabled(c.reviewState === 'pending')
        .onChange((v: string) => {
          this.updateCandidateRelationship(c, v);
        })

      // 重要度(可编辑)
      Text('重要度')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 8 })
        .textAlign(TextAlign.Start)
      Row() {
        ForEach(this.relationshipImportanceOptions(), (n: number) => {
          Button(n.toString())
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(c.importance === n
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
            .backgroundColor(c.importance === n
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(28)
            .width(40)
            .margin({ right: 4 })
            .enabled(c.reviewState === 'pending')
            .onClick(() => { this.updateCandidateImportance(c, n); })
        }, (n: number) => n.toString())
      }
      .width('100%')
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)

      // 关键词(可编辑)
      Text('关键词')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 8 })
        .textAlign(TextAlign.Start)
      TextInput({ placeholder: '逗号分隔', text: c.keywordsText })
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .height(36)
        .margin({ top: 2 })
        .enabled(c.reviewState === 'pending')
        .onChange((v: string) => {
          this.updateCandidateKeywords(c, v);
        })

      // 操作按钮
      Row() {
        Button('拒绝')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .layoutWeight(1)
          .margin({ right: 6 })
          .enabled(c.reviewState === 'pending' && !this.isApprovingRelationship)
          .onClick(() => { this.handleRejectCandidate(c); })
        Button('批准')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .layoutWeight(1)
          .enabled(c.reviewState === 'pending' && !this.isApprovingRelationship)
          .onClick(() => { this.handleApproveCandidate(c); })
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 关系事件处理 =====

  /** 切换视图模式 */
  private async switchViewMode(mode: PageViewMode): Promise<void> {
    if (this.viewMode === mode) {
      return;
    }
    this.viewMode = mode;
    this.actionError = '';
    this.relationshipActionError = '';
    if (mode === PageViewMode.Relationship && this.viewModel !== null) {
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
    } else if (mode === PageViewMode.ContextInspector && this.viewModel !== null) {
      this.viewModel.loadInspectionSnapshot();
      this.syncInspectionFromViewModel();
      await this.viewModel.loadContextAdjustment();
      this.syncInspectionFromViewModel();
    }
  }

  /** 同步 ViewModel 关系状态到页面 @State */
  private syncRelationshipFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.relationshipList = this.viewModel.relationshipList;
    this.isRelationshipListLoading = this.viewModel.isRelationshipListLoading;
    this.isPreparingRelationship = this.viewModel.isPreparingRelationship;
    this.isApprovingRelationship = this.viewModel.isApprovingRelationship;
    // 同步候选列表(从 ViewModel 获取最新数据)
    this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
    if (this.viewModel.relationshipError.length > 0) {
      this.relationshipActionError = this.viewModel.relationshipError;
    }
  }

  /** G-CONTEXT-INSPECTOR-1: 同步 ViewModel 上下文检查状态到页面 @State */
  private syncInspectionFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.inspectionSnapshot = this.viewModel.inspectionSnapshot;
    this.isInspectionLoading = this.viewModel.isInspectionLoading;
    this.isContextAdjustLoaded = this.viewModel.isContextAdjustLoaded;
    this.isSavingContextWindow = this.viewModel.isSavingContextWindow;
    this.contextAdjustMessage = this.viewModel.contextAdjustMessage;
    this.contextAdjustIsError = this.viewModel.contextAdjustIsError;
    if (this.contextWindowInput.length === 0
      && this.viewModel.configuredContextWindow !== undefined) {
      this.contextWindowInput = String(this.viewModel.configuredContextWindow);
    }
  }

  /** G-CONTEXT-INSPECTOR-1: 保存上下文窗口调整 */
  private async handleSaveContextWindow(): Promise<void> {
    if (this.viewModel === null || this.isSavingContextWindow) {
      return;
    }
    const trimmed: string = this.contextWindowInput.trim();
    const parsed: number = parseInt(trimmed, 10);
    if (isNaN(parsed) || trimmed.length === 0) {
      this.contextAdjustMessage = '请输入有效的上下文窗口数值';
      this.contextAdjustIsError = true;
      return;
    }
    const saved: boolean = await this.viewModel.saveContextWindow(parsed);
    if (saved) {
      this.contextWindowInput = String(parsed);
    }
    this.syncInspectionFromViewModel();
  }

  /** 点击"总结新关系"按钮 */
  private async handlePrepareRelationship(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isPreparingRelationship || this.isApprovingRelationship) {
      return;
    }
    this.relationshipActionError = '';
    this.relationshipReviewError = '';
    this.isPreparingRelationship = true;
    await this.viewModel.prepareRelationshipSummary();
    this.syncRelationshipFromViewModel();

    if (this.viewModel.relationshipDraft !== null) {
      this.relationshipReviewVisible = true;
    } else {
      this.relationshipActionError = this.viewModel.relationshipError;
    }
  }

  /** 批准单个候选 */
  private async handleApproveCandidate(c: RelationshipCandidateUiModel): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isApprovingRelationship) {
      return;
    }
    this.relationshipReviewError = '';
    const result = await this.viewModel.approveRelationshipCandidate(c);
    this.syncRelationshipFromViewModel();
    if (!result.success) {
      this.relationshipReviewError = result.errorMessage;
    } else {
      // 批准成功后刷新关系列表(后台刷新,不关闭窗口)
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
    }
  }

  /** 拒绝单个候选 */
  private handleRejectCandidate(c: RelationshipCandidateUiModel): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.rejectRelationshipCandidate(c);
    this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
  }

  /** 全部批准 */
  private async handleApproveAllCandidates(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isApprovingRelationship) {
      return;
    }
    if (!this.hasPendingCandidates()) {
      this.relationshipReviewError = '没有待批准的候选';
      return;
    }
    this.relationshipReviewError = '';
    this.isApprovingRelationship = true;
    const result = await this.viewModel.approveAllPendingCandidates();
    this.syncRelationshipFromViewModel();
    if (!result.success) {
      this.relationshipReviewError = result.errorMessage;
    } else {
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
    }
  }

  /** 全部拒绝 */
  private handleRejectAllCandidates(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.rejectAllPendingCandidates();
    this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
  }

  /** 完成审核(关闭窗口) */
  private async handleFinishReview(): Promise<void> {
    this.closeRelationshipReview();
    // 刷新关系列表
    if (this.viewModel !== null) {
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
    }
  }

  /** 关闭审核窗口 */
  private closeRelationshipReview(): void {
    if (this.isApprovingRelationship) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.clearRelationshipDraft();
    }
    this.relationshipReviewVisible = false;
    this.relationshipReviewError = '';
    this.relationshipCandidates = [];
    this.syncRelationshipFromViewModel();
  }

  /** 打开关系详情 */
  private openRelationshipDetail(id: string): void {
    if (id.length === 0) {
      return;
    }
    this.relationshipDetailId = id;
    this.relationshipDetail = this.findRelationshipById(id);
    this.relationshipActionError = '';
    this.relationshipDetailVisible = true;
  }

  /** 关闭关系详情 */
  private closeRelationshipDetail(): void {
    if (this.isSaving) {
      return;
    }
    this.relationshipDetailVisible = false;
    this.relationshipDetailId = '';
    this.relationshipDetail = null;
    this.relationshipActionError = '';
  }

  /** 打开关系编辑表单 */
  private openRelationshipEdit(r: RelationshipListItemUiModel): void {
    if (!r.canEdit) {
      return;
    }
    // 先关闭详情(避免重叠)
    this.relationshipDetailVisible = false;
    this.relationshipActionError = '';
    this.relFormError = '';
    this.editingRelationshipId = r.id;
    this.relFormExperience = r.experienceSummary;
    this.relFormAttitude = r.attitudeSummary;
    this.relFormRelationship = r.relationshipSummary;
    this.relFormImportance = r.importance;
    this.relFormKeywords = r.keywordsText;
    this.relationshipEditVisible = true;
  }

  /** 关闭关系编辑表单 */
  private closeRelationshipEdit(): void {
    if (this.isSaving) {
      return;
    }
    this.relationshipEditVisible = false;
    this.relFormError = '';
  }

  /** 提交关系编辑 */
  private async submitRelationshipEdit(): Promise<void> {
    if (this.viewModel === null || this.isSaving) {
      return;
    }
    const experience: string = this.relFormExperience.trim();
    const attitude: string = this.relFormAttitude.trim();
    const relationship: string = this.relFormRelationship.trim();
    if (experience === '' && attitude === '' && relationship === '') {
      this.relFormError = '至少填写一项摘要内容';
      return;
    }
    this.relFormError = '';
    const input: UpdateRelationshipMemoryFormInput = {
      memoryId: this.editingRelationshipId,
      experienceSummary: experience,
      attitudeSummary: attitude,
      relationshipSummary: relationship,
      importance: this.relFormImportance,
      keywordsText: this.relFormKeywords
    };
    const result = await this.viewModel.updateRelationshipMemory(input);
    this.syncRelationshipFromViewModel();
    if (result.success) {
      this.relationshipEditVisible = false;
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
    } else {
      this.relFormError = result.errorMessage;
    }
  }

  /** 归档 / 恢复关系 */
  private async handleRelationshipArchive(r: RelationshipListItemUiModel): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const archived: boolean = r.status === GroupRelationshipMemoryStatus.Active;
    this.relationshipActionError = '';
    const result = await this.viewModel.setRelationshipArchived(r.id, archived);
    this.syncRelationshipFromViewModel();
    if (result.success) {
      await this.viewModel.loadRelationshipList();
      this.syncRelationshipFromViewModel();
      // 若详情仍打开,同步更新
      if (this.relationshipDetailVisible && this.relationshipDetailId === r.id) {
        this.relationshipDetail = this.findRelationshipById(r.id);
      }
    } else {
      this.relationshipActionError = result.errorMessage;
    }
  }

  // ===== 关系辅助方法 =====

  /** 从 relationshipList 查找指定 ID 的关系 */
  private findRelationshipById(id: string): RelationshipListItemUiModel | null {
    if (id.length === 0) {
      return null;
    }
    for (let i = 0; i < this.relationshipList.length; i++) {
      if (this.relationshipList[i].id === id) {
        return this.relationshipList[i];
      }
    }
    return null;
  }

  /** 是否还有 pending 候选 */
  private hasPendingCandidates(): boolean {
    for (let i = 0; i < this.relationshipCandidates.length; i++) {
      if (this.relationshipCandidates[i].reviewState === 'pending') {
        return true;
      }
    }
    return false;
  }

  /** 关系重要度选项(1-5) */
  private relationshipImportanceOptions(): number[] {
    const opts: number[] = [];
    for (let n: number = RELATIONSHIP_MEMORY_IMPORTANCE_MIN;
      n <= RELATIONSHIP_MEMORY_IMPORTANCE_MAX; n++) {
      opts.push(n);
    }
    return opts;
  }

  /** 构建关系来源信息文本 */
  private buildRelationshipSourceInfo(): string {
    if (this.viewModel === null) {
      return '';
    }
    const count: number = this.viewModel.relationshipSourceCount();
    const hashShort: string = this.viewModel.relationshipSourceHashShort();
    const targetCount: number = this.viewModel.relationshipTargetCount();
    if (count === 0) {
      return '';
    }
    const parts: string[] = [];
    parts.push('来源消息:' + count.toString() + ' 条');
    parts.push('对象白名单:' + targetCount.toString() + ' 个');
    if (hashShort.length > 0) {
      parts.push('哈希:' + hashShort);
    }
    return parts.join('  ·  ');
  }

  /** 更新候选的共同经历(本地编辑) */
  private updateCandidateExperience(c: RelationshipCandidateUiModel, v: string): void {
    if (this.viewModel === null) {
      return;
    }
    for (let i = 0; i < this.viewModel.relationshipCandidates.length; i++) {
      if (this.viewModel.relationshipCandidates[i].targetType === c.targetType
        && this.viewModel.relationshipCandidates[i].targetId === c.targetId) {
        this.viewModel.relationshipCandidates[i].experienceSummary = v;
        this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
        return;
      }
    }
  }

  /** 更新候选的态度(本地编辑) */
  private updateCandidateAttitude(c: RelationshipCandidateUiModel, v: string): void {
    if (this.viewModel === null) {
      return;
    }
    for (let i = 0; i < this.viewModel.relationshipCandidates.length; i++) {
      if (this.viewModel.relationshipCandidates[i].targetType === c.targetType
        && this.viewModel.relationshipCandidates[i].targetId === c.targetId) {
        this.viewModel.relationshipCandidates[i].attitudeSummary = v;
        this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
        return;
      }
    }
  }

  /** 更新候选的关系(本地编辑) */
  private updateCandidateRelationship(c: RelationshipCandidateUiModel, v: string): void {
    if (this.viewModel === null) {
      return;
    }
    for (let i = 0; i < this.viewModel.relationshipCandidates.length; i++) {
      if (this.viewModel.relationshipCandidates[i].targetType === c.targetType
        && this.viewModel.relationshipCandidates[i].targetId === c.targetId) {
        this.viewModel.relationshipCandidates[i].relationshipSummary = v;
        this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
        return;
      }
    }
  }

  /** 更新候选的重要度(本地编辑) */
  private updateCandidateImportance(c: RelationshipCandidateUiModel, n: number): void {
    if (this.viewModel === null) {
      return;
    }
    for (let i = 0; i < this.viewModel.relationshipCandidates.length; i++) {
      if (this.viewModel.relationshipCandidates[i].targetType === c.targetType
        && this.viewModel.relationshipCandidates[i].targetId === c.targetId) {
        this.viewModel.relationshipCandidates[i].importance = n;
        this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
        return;
      }
    }
  }

  /** 更新候选的关键词(本地编辑) */
  private updateCandidateKeywords(c: RelationshipCandidateUiModel, v: string): void {
    if (this.viewModel === null) {
      return;
    }
    for (let i = 0; i < this.viewModel.relationshipCandidates.length; i++) {
      if (this.viewModel.relationshipCandidates[i].targetType === c.targetType
        && this.viewModel.relationshipCandidates[i].targetId === c.targetId) {
        this.viewModel.relationshipCandidates[i].keywordsText = v;
        this.relationshipCandidates = this.viewModel.relationshipCandidates.slice();
        return;
      }
    }
  }
}
