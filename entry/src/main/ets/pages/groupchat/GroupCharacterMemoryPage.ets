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
  GROUP_MEMORY_IMPORTANCE_MIN,
  GROUP_MEMORY_IMPORTANCE_MAX,
  GROUP_MEMORY_IMPORTANCE_DEFAULT,
  GROUP_MEMORY_TITLE_MAX,
  GROUP_MEMORY_CONTENT_MAX
} from '../../viewmodels/groupchat/GroupCharacterMemoryViewModel';
import {
  PENDING_GROUP_MEMORY_GROUP_ID_KEY,
  PENDING_GROUP_MEMORY_CHARACTER_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { GroupCharacterMemoryStatus } from '../../models/groupchat/GroupCharacterMemory';
import { CharacterImageView } from '../../components/CharacterImageView';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharacterMemoryPage';

/** 表单模式(仅当 formVisible=true 时有意义) */
enum GroupMemoryFormMode {
  Create,
  Edit
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
      if (groupConversationId.length === 0 || characterId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: groupConversationId or characterId empty');
        this.isInitializing = false;
        this.loadState = GroupCharacterMemoryLoadState.NotFound;
        return;
      }
      this.viewModel = new GroupCharacterMemoryViewModel(
        AppServices.getGroupConversationPersistenceService(),
        AppServices.getCharacterService(),
        AppServices.getGroupCharacterMemoryService(),
        AppServices.getGroupCharacterSelfSummaryService()
      );
      this.viewModel.setTarget(groupConversationId, characterId);
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
      // 角色头部
      this.characterHeaderArea()

      // 筛选
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
    .width('100%')
    .layoutWeight(1)
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

  @Builder
  filterBar(): void {
    Row() {
      Button('全部')
        .fontSize($r('app.float.app_font_caption'))
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

  private importanceOptions(): number[] {
    const opts: number[] = [];
    for (let n: number = GROUP_MEMORY_IMPORTANCE_MIN; n <= GROUP_MEMORY_IMPORTANCE_MAX; n++) {
      opts.push(n);
    }
    return opts;
  }
}
