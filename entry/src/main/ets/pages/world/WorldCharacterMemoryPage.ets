/**
 * WorldCharacterMemoryPage 世界角色记忆页(W-MEMORY-1A)
 *
 * 职责:
 * - 显示角色实例头部(头像/名称/Active/当前位置/记忆数量)
 * - 列出该实例的世界记忆(全部/活跃/已归档)
 * - 手动新增 / 编辑 / 归档 / 恢复 / 删除 记忆
 * - 来源地点/Scene/Message 失效时安全降级显示
 *
 * 路由:通过 AppStorage PENDING_WORLD_MEMORY_WORLD_ID_KEY +
 *      PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY 传参,读取后清除。
 *
 * 写入调用 WorldCharacterMemoryService(经 ViewModel),不直接访问 Repository。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldCharacterMemoryViewModel,
  WorldCharacterMemoryLoadState,
  WorldCharacterMemoryListFilter,
  MemoryItemUiModel,
  MemoryLocationOptionUiModel,
  MemoryCharacterHeaderUiModel,
  CreateMemoryFormInput,
  UpdateMemoryFormInput
} from '../../viewmodels/world/WorldCharacterMemoryViewModel';
import {
  PENDING_WORLD_MEMORY_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY,
  WORLD_CHARACTER_MEMORY_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import {
  WorldCharacterMemoryType,
  WorldCharacterMemoryOrigin,
  WorldCharacterMemoryStatus,
  WORLD_CHARACTER_MEMORY_IMPORTANCE_MIN,
  WORLD_CHARACTER_MEMORY_IMPORTANCE_MAX,
  WORLD_CHARACTER_MEMORY_CONTENT_MAX
} from '../../models/world/WorldCharacterMemory';
import { CharacterImageView } from '../../components/CharacterImageView';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterMemoryPage';

/** 表单模式 */
enum MemoryFormMode {
  None,
  Create,
  Edit
}

@Entry
@Component
struct WorldCharacterMemoryPage {
  @State private viewModel: WorldCharacterMemoryViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldCharacterMemoryLoadState = WorldCharacterMemoryLoadState.Loading;
  @State private errorMessage: string = '';
  @State private memories: MemoryItemUiModel[] = [];
  @State private locationOptions: MemoryLocationOptionUiModel[] = [];
  @State private memoryCount: number = 0;
  @State private displayName: string = '';
  @State private fallbackName: string = '';
  @State private avatarUri: string = '';
  @State private isActive: boolean = true;
  @State private characterCardMissing: boolean = false;
  @State private currentLocationLabel: string = '';

  @State private filter: WorldCharacterMemoryListFilter = WorldCharacterMemoryListFilter.Active;
  @State private formMode: MemoryFormMode = MemoryFormMode.None;
  @State private editingMemoryId: string = '';
  @State private formContent: string = '';
  @State private formType: WorldCharacterMemoryType = WorldCharacterMemoryType.Episodic;
  @State private formImportance: number = 3;
  @State private formLocationId: string = '';
  @State private formOccurredAt: number = 0;
  @State private isSaving: boolean = false;
  @State private isDeleting: boolean = false;
  @State private actionError: string = '';
  /** 删除确认弹窗(非空表示正在确认删除该 memoryId) */
  @State private deletingMemoryId: string = '';

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp(WORLD_CHARACTER_MEMORY_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  refreshToken: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_MEMORY_WORLD_ID_KEY) ?? '';
      const instanceId: string =
        AppStorage.get<string>(PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_MEMORY_WORLD_ID_KEY, '');
      AppStorage.set<string>(PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY, '');
      if (worldId.length === 0 || instanceId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId or instanceId empty');
        this.isInitializing = false;
        this.loadState = WorldCharacterMemoryLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldCharacterMemoryViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getCharacterService(),
        AppServices.getWorldCharacterMemoryService()
      );
      this.viewModel.setTarget(worldId, instanceId);
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldCharacterMemoryLoadState.Error;
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

  onRefreshTokenChange(): void {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.activate();
    this.loadSnapshot();
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
    const worldId: string = this.viewModel.expectedWorldIdOfPage();
    const instanceId: string = this.viewModel.expectedCharacterInstanceIdOfPage();
    if (worldId.length === 0 || instanceId.length === 0) {
      return;
    }
    await this.viewModel.loadSnapshot(worldId, instanceId, this.filter);
    this.syncFromViewModel();
  }

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
      this.locationOptions = [];
      this.memoryCount = 0;
      this.displayName = '';
      this.fallbackName = '';
      this.avatarUri = '';
      this.isActive = true;
      this.characterCardMissing = false;
      this.currentLocationLabel = '';
      return;
    }
    this.memories = snapshot.memories;
    this.locationOptions = snapshot.locationOptions;
    this.memoryCount = snapshot.header.memoryCount;
    this.displayName = snapshot.header.displayName;
    this.fallbackName = snapshot.header.fallbackName;
    this.avatarUri = snapshot.header.avatarUri;
    this.isActive = snapshot.header.isActive;
    this.characterCardMissing = snapshot.header.characterCardMissing;
    this.currentLocationLabel = this.resolveCurrentLocationLabel(snapshot.header);
  }

  build(): void {
    Column() {
      this.headerArea();
      if (this.isInitializing) {
        this.loadingView();
      } else if (this.loadState === WorldCharacterMemoryLoadState.Loading) {
        this.loadingView();
      } else if (this.loadState === WorldCharacterMemoryLoadState.NotFound) {
        this.notFoundView();
      } else if (this.loadState === WorldCharacterMemoryLoadState.Error) {
        this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '记忆数据加载失败,请重试');
      } else {
        this.contentView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.formMode === MemoryFormMode.Create, this.createFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        if (this.formMode === MemoryFormMode.Create) {
          this.formMode = MemoryFormMode.None;
        }
      }
    })
    .bindSheet(this.formMode === MemoryFormMode.Edit, this.editFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        if (this.formMode === MemoryFormMode.Edit) {
          this.formMode = MemoryFormMode.None;
        }
      }
    })
    .bindSheet(this.deletingMemoryId.length > 0, this.deleteConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        this.deletingMemoryId = '';
      }
    })
  }

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_home_back'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText($r('app.string.world_home_back'))
        .onClick(() => {
          router.back();
        })

      Text($r('app.string.world_memory_page_title'))
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
      EmptyStateView({ title: $r('app.string.world_memory_not_found'), description: '' })
      Button($r('app.string.world_home_back'))
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
      EmptyStateView({ title: $r('app.string.world_memory_load_error'), description: msg })
      Button($r('app.string.world_home_reload'))
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
          ForEach(this.memories, (m: MemoryItemUiModel) => {
            ListItem() {
              this.memoryCard(m)
            }
          }, (m: MemoryItemUiModel) => m.id)
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
        imageUri: this.avatarUri,
        fallbackName: this.fallbackName,
        imgWidth: 44,
        imgHeight: 44,
        imgBorderRadius: 22,
        displayMode: 'thumbnail'
      })

      Column() {
        Text(this.displayName)
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(this.isActive
            ? $r('app.string.world_character_active')
            : $r('app.string.world_character_inactive'))
            .fontSize(10)
            .fontColor(this.isActive
              ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })

          if (this.characterCardMissing) {
            Text($r('app.string.world_character_card_missing'))
              .fontSize(10)
              .fontColor($r('app.color.app_danger'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 4 })
          }

          Text(this.currentLocationLabel)
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.world_memory_count_label', this.memoryCount))
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
      Button($r('app.string.world_memory_filter_all'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.filter === WorldCharacterMemoryListFilter.All
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
        .backgroundColor(this.filter === WorldCharacterMemoryListFilter.All
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => { this.changeFilter(WorldCharacterMemoryListFilter.All); })
      Button($r('app.string.world_memory_filter_active'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.filter === WorldCharacterMemoryListFilter.Active
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
        .backgroundColor(this.filter === WorldCharacterMemoryListFilter.Active
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ left: 8 })
        .onClick(() => { this.changeFilter(WorldCharacterMemoryListFilter.Active); })
      Button($r('app.string.world_memory_filter_archived'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.filter === WorldCharacterMemoryListFilter.Archived
          ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
        .backgroundColor(this.filter === WorldCharacterMemoryListFilter.Archived
          ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ left: 8 })
        .onClick(() => { this.changeFilter(WorldCharacterMemoryListFilter.Archived); })

      Blank().layoutWeight(1)

      Button($r('app.string.world_memory_add'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .enabled(!this.isSaving && !this.isDeleting)
        .accessibilityText($r('app.string.world_memory_add'))
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
        title: $r('app.string.world_memory_empty_title'),
        description: $r('app.string.world_memory_empty_desc')
      })
      Button($r('app.string.world_memory_add'))
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
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  memoryCard(m: MemoryItemUiModel): void {
    Column() {
      // 第一行:类型 + 重要度 + 来源标签 + 状态
      Row() {
        Text(m.typeLabel)
          .fontSize(11)
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })

        Text(this.importanceLabel(m.importance))
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 6 })

        Text(m.originLabel)
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 6 })

        Blank().layoutWeight(1)

        Text(m.statusLabel)
          .fontSize(11)
          .fontColor(m.status === WorldCharacterMemoryStatus.Active
            ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文(最多 5 行,点击编辑)
      Text(m.content)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .margin({ top: 8 })
        .maxLines(5)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
        .onClick(() => { this.openEditForm(m); })

      // 来源摘要
      if (m.sourceSummary.length > 0) {
        Text(m.sourceSummary)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 6 })
      }

      // 时间
      Row() {
        if (m.occurredAtLabel.length > 0) {
          Text($r('app.string.world_memory_occurred_at_label', m.occurredAtLabel))
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        Text($r('app.string.world_memory_created_at_label', m.createdAtLabel))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: m.occurredAtLabel.length > 0 ? 8 : 0 })
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      // 操作按钮
      Row() {
        Button($r('app.string.world_memory_edit'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_accent'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 10, right: 10 })
          .enabled(!this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_memory_edit'))
          .onClick(() => { this.openEditForm(m); })

        if (m.status === WorldCharacterMemoryStatus.Active) {
          Button($r('app.string.world_memory_archive'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_secondary'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .margin({ left: 6 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_memory_archive'))
            .onClick(() => { this.handleArchive(m.id, true); })
        } else {
          Button($r('app.string.world_memory_restore'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_accent'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .margin({ left: 6 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_memory_restore'))
            .onClick(() => { this.handleArchive(m.id, false); })
        }

        Button($r('app.string.world_memory_delete'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_danger'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 10, right: 10 })
          .margin({ left: 6 })
          .enabled(!this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_memory_delete'))
          .onClick(() => { this.deletingMemoryId = m.id; })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: 12, right: 12, top: 10, bottom: 10
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  createFormSheet(): void {
    this.memoryFormSheet(false)
  }

  @Builder
  editFormSheet(): void {
    this.memoryFormSheet(true)
  }

  @Builder
  memoryFormSheet(isEdit: boolean): void {
    Column() {
      Text(isEdit
        ? $r('app.string.world_memory_edit_title')
        : $r('app.string.world_memory_create_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      // 正文
      Text($r('app.string.world_memory_form_content'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      TextArea({
        text: this.formContent,
        placeholder: $r('app.string.world_memory_form_content_placeholder')
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .width('100%')
        .height(120)
        .margin({ left: 16, right: 16, bottom: 4 })
        .maxLength(WORLD_CHARACTER_MEMORY_CONTENT_MAX)
        .onChange((v: string) => {
          this.formContent = v;
        })
      Text($r('app.string.world_memory_form_content_count',
        this.formContent.length, WORLD_CHARACTER_MEMORY_CONTENT_MAX))
        .fontSize(10)
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      // 类型
      Text($r('app.string.world_memory_form_type'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        Button($r('app.string.world_memory_type_episodic'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.formType === WorldCharacterMemoryType.Episodic
            ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
          .backgroundColor(this.formType === WorldCharacterMemoryType.Episodic
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => { this.formType = WorldCharacterMemoryType.Episodic; })
        Button($r('app.string.world_memory_type_semantic'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.formType === WorldCharacterMemoryType.Semantic
            ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
          .backgroundColor(this.formType === WorldCharacterMemoryType.Semantic
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 6 })
          .onClick(() => { this.formType = WorldCharacterMemoryType.Semantic; })
        Button($r('app.string.world_memory_type_reflection'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.formType === WorldCharacterMemoryType.Reflection
            ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
          .backgroundColor(this.formType === WorldCharacterMemoryType.Reflection
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 6 })
          .onClick(() => { this.formType = WorldCharacterMemoryType.Reflection; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 重要度
      Text($r('app.string.world_memory_form_importance'))
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

      // 发生地点(可选)
      Text($r('app.string.world_memory_form_location'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        Button(this.formLocationId.length === 0
          ? $r('app.string.world_memory_form_location_none')
          : this.resolveLocationName(this.formLocationId))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.formLocationId = '';
          })
        Text($r('app.string.world_memory_form_location_clear'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 4 })
      .alignItems(VerticalAlign.Center)
      // 地点候选列表
      Row() {
        ForEach(this.locationOptions, (loc: MemoryLocationOptionUiModel) => {
          Button(loc.name)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.formLocationId === loc.id
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
            .backgroundColor(this.formLocationId === loc.id
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 8, right: 8 })
            .margin({ right: 6, bottom: 4 })
            .onClick(() => { this.formLocationId = loc.id; })
        }, (loc: MemoryLocationOptionUiModel) => loc.id)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 发生时间(可选)
      Text($r('app.string.world_memory_form_occurred_at'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        Text(this.formOccurredAt > 0
          ? this.formatTimestamp(this.formOccurredAt)
          : '未指定')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .layoutWeight(1)
        Button(this.formOccurredAt > 0
          ? $r('app.string.world_memory_form_occurred_clear')
          : $r('app.string.world_memory_form_occurred_now'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 8, right: 8 })
          .margin({ left: 8 })
          .onClick(() => {
            if (this.formOccurredAt > 0) {
              this.formOccurredAt = 0;
            } else {
              this.formOccurredAt = Date.now();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // 操作按钮
      Row() {
        Button($r('app.string.world_memory_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => { this.formMode = MemoryFormMode.None; })
        Button(isEdit
          ? $r('app.string.world_memory_save')
          : $r('app.string.world_memory_create'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(!this.isSaving && this.formContent.trim().length > 0)
          .onClick(() => { this.submitForm(isEdit); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  deleteConfirmSheet(): void {
    Column() {
      Text($r('app.string.world_memory_delete_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_memory_delete_confirm'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })

      Row() {
        Button($r('app.string.world_memory_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => { this.deletingMemoryId = ''; })
        Button($r('app.string.world_memory_delete'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(!this.isDeleting)
          .onClick(() => { this.handleDelete(this.deletingMemoryId); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  // ===== 事件处理 =====

  private async changeFilter(filter: WorldCharacterMemoryListFilter): Promise<void> {
    if (this.filter === filter) {
      return;
    }
    this.filter = filter;
    await this.loadSnapshot();
  }

  private openCreateForm(): void {
    this.actionError = '';
    this.editingMemoryId = '';
    this.formContent = '';
    this.formType = WorldCharacterMemoryType.Episodic;
    this.formImportance = 3;
    this.formLocationId = '';
    this.formOccurredAt = 0;
    this.formMode = MemoryFormMode.Create;
  }

  private openEditForm(m: MemoryItemUiModel): void {
    this.actionError = '';
    this.editingMemoryId = m.id;
    this.formContent = m.content;
    this.formType = m.type;
    this.formImportance = m.importance;
    this.formLocationId = m.sourceLocationId;
    this.formOccurredAt = m.occurredAt;
    this.formMode = MemoryFormMode.Edit;
  }

  private async submitForm(isEdit: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const content: string = this.formContent.trim();
    if (content.length === 0) {
      this.actionError = '记忆正文不能为空';
      return;
    }
    if (content.length > WORLD_CHARACTER_MEMORY_CONTENT_MAX) {
      this.actionError = '记忆正文超过长度上限';
      return;
    }
    this.actionError = '';
    const locationId: string | undefined = this.formLocationId.length > 0
      ? this.formLocationId : undefined;
    const occurredAt: number | undefined = this.formOccurredAt > 0
      ? this.formOccurredAt : undefined;
    if (isEdit) {
      const input: UpdateMemoryFormInput = {
        memoryId: this.editingMemoryId,
        content: content,
        type: this.formType,
        importance: this.formImportance,
        sourceLocationId: locationId,
        occurredAt: occurredAt
      };
      const result = await this.viewModel.updateMemory(input);
      if (result.success) {
        this.formMode = MemoryFormMode.None;
        await this.loadSnapshot();
      } else {
        this.actionError = result.errorMessage;
      }
    } else {
      const input: CreateMemoryFormInput = {
        content: content,
        type: this.formType,
        importance: this.formImportance,
        sourceLocationId: locationId,
        occurredAt: occurredAt
      };
      const result = await this.viewModel.createMemory(input);
      if (result.success) {
        this.formMode = MemoryFormMode.None;
        await this.loadSnapshot();
      } else {
        this.actionError = result.errorMessage;
      }
    }
  }

  private async handleArchive(memoryId: string, archived: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.actionError = '';
    const result = await this.viewModel.setMemoryArchived(memoryId, archived);
    if (result.success) {
      await this.loadSnapshot();
    } else {
      this.actionError = result.errorMessage;
    }
  }

  private async handleDelete(memoryId: string): Promise<void> {
    if (this.viewModel === null || memoryId.length === 0) {
      return;
    }
    this.actionError = '';
    const result = await this.viewModel.deleteMemory(memoryId);
    if (result.success) {
      this.deletingMemoryId = '';
      await this.loadSnapshot();
    } else {
      this.actionError = result.errorMessage;
    }
  }

  // ===== 辅助方法 =====

  private resolveCurrentLocationLabel(header: MemoryCharacterHeaderUiModel): string {
    if (header.currentLocationId.length === 0) {
      return '未放置';
    }
    if (header.locationMissing) {
      return '地点已删除';
    }
    return header.currentLocationName.length > 0 ? header.currentLocationName : '未知地点';
  }

  private importanceLabel(importance: number): string {
    let stars: string = '';
    for (let i = 0; i < importance; i++) {
      stars += '★';
    }
    return '重要度 ' + stars;
  }

  private importanceOptions(): number[] {
    const arr: number[] = [];
    for (let n = WORLD_CHARACTER_MEMORY_IMPORTANCE_MIN; n <= WORLD_CHARACTER_MEMORY_IMPORTANCE_MAX; n++) {
      arr.push(n);
    }
    return arr;
  }

  private resolveLocationName(locationId: string): string {
    for (let i = 0; i < this.locationOptions.length; i++) {
      if (this.locationOptions[i].id === locationId) {
        return this.locationOptions[i].name;
      }
    }
    return '地点已删除';
  }

  private formatTimestamp(ts: number): string {
    if (!Number.isFinite(ts) || ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const year: number = d.getFullYear();
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return year + '-' + month + '-' + day + ' ' + hour + ':' + minute;
  }
}
