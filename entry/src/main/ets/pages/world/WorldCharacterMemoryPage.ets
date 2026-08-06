import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldCharacterMemoryViewModel,
  WorldCharacterMemoryLoadState,
  WorldCharacterMemoryListFilter,
  ArchiveTab,
  MemoryItemUiModel,
  MemoryLocationOptionUiModel,
  MemoryCharacterHeaderUiModel,
  CharacterSwitcherItemUiModel,
  ActivitySceneUiModel,
  ActivityMessageUiModel,
  ActivityMoveUiModel,
  DiagnosticSummaryUiModel,
  DiagnosticIssueUiModel,
  DiagnosticRiskLevel,
  CreateMemoryFormInput,
  UpdateMemoryFormInput
} from '../../viewmodels/world/WorldCharacterMemoryViewModel';
import {
  PENDING_WORLD_MEMORY_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY,
  PENDING_WORLD_MEMORY_EVIDENCE_ID_KEY,
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
import { WorldSceneStatus } from '../../models/world/WorldScene';
import { CharacterImageView } from '../../components/CharacterImageView';
import { EmptyStateView } from '../../components/EmptyStateView';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldColors } from '../../components/world/WorldDesignTokens';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterMemoryPage';

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
  @State private switcherItems: CharacterSwitcherItemUiModel[] = [];
  @State private selectedTab: ArchiveTab = ArchiveTab.Memory;
  @State private filter: WorldCharacterMemoryListFilter = WorldCharacterMemoryListFilter.Active;

  @State private activityScenes: ActivitySceneUiModel[] = [];
  @State private activityMessages: ActivityMessageUiModel[] = [];
  @State private activityMoves: ActivityMoveUiModel[] = [];
  @State private diagnostic: DiagnosticSummaryUiModel | null = null;

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
        AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneMessageRepository(),
        AppServices.getWorldEventRepository(),
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
      this.switcherItems = [];
      this.activityScenes = [];
      this.activityMessages = [];
      this.activityMoves = [];
      this.diagnostic = null;
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
    this.switcherItems = snapshot.characterSwitcherItems;
    this.activityScenes = snapshot.activityScenes;
    this.activityMessages = snapshot.activityMessages;
    this.activityMoves = snapshot.activityMoves;
    this.diagnostic = snapshot.diagnostic;
  }

  build(): void {
    Column() {
      this.headerArea()
      if (this.isInitializing) {
        this.loadingView()
      } else if (this.loadState === WorldCharacterMemoryLoadState.Loading) {
        this.loadingView()
      } else if (this.loadState === WorldCharacterMemoryLoadState.NotFound) {
        this.notFoundView()
      } else if (this.loadState === WorldCharacterMemoryLoadState.Error) {
        this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '记忆数据加载失败,请重试')
      } else {
        this.contentView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.formMode === MemoryFormMode.Create, this.createFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        if (this.formMode === MemoryFormMode.Create) {
          this.formMode = MemoryFormMode.None;
        }
      }
    })
    .bindSheet(this.formMode === MemoryFormMode.Edit, this.editFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        if (this.formMode === MemoryFormMode.Edit) {
          this.formMode = MemoryFormMode.None;
        }
      }
    })
    .bindSheet(this.deletingMemoryId.length > 0, this.deleteConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        this.deletingMemoryId = '';
      }
    })
  }

  @Builder
  headerArea(): void {
    Row() {
      Button('←')
        .fontSize(22)
        .fontColor($r('app.color.world_text_secondary'))
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .padding(0)
        .onClick(() => {
          router.back();
        })

      Column() {
        Text($r('app.string.world_archive_page_title'))
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.displayName)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding'),
      top: this.statusBarHeight + 4,
      bottom: 4
    })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress().width(40).height(40).color($r('app.color.world_gold'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_memory_not_found'),
        primaryLabel: $r('app.string.world_home_back'),
        onPrimary: (): void => {
          router.back();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(msg: string): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_memory_load_error'),
        description: msg,
        primaryLabel: $r('app.string.world_home_reload'),
        secondaryLabel: $r('app.string.world_home_back'),
        onPrimary: (): void => {
          this.loadSnapshot();
        },
        onSecondary: (): void => {
          router.back();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  contentView(): void {
    Column() {
      this.characterHeaderArea()
      this.characterSwitcherArea()
      this.tabBar()
      this.tabContent()
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
        imgWidth: 40,
        imgHeight: 40,
        imgBorderRadius: 20,
        displayMode: 'thumbnail'
      })

      Column() {
        Text(this.displayName)
          .fontSize($r('app.float.world_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          WorldStatusChip({
            label: this.isActive ? '活跃' : '已停用',
            isActive: this.isActive
          })

          if (this.characterCardMissing) {
            Text($r('app.string.world_character_card_missing'))
              .fontSize(10)
              .fontColor($r('app.color.world_error'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 4 })
          }

          Text(this.currentLocationLabel)
            .fontSize(10)
            .fontColor($r('app.color.world_text_secondary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)

        Text('记忆 ' + this.memoryCount.toString())
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_8')
    })
    .backgroundColor($r('app.color.world_surface_1'))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  characterSwitcherArea(): void {
    if (this.switcherItems.length > 1) {
      Scroll() {
        Row() {
          ForEach(this.switcherItems, (item: CharacterSwitcherItemUiModel) => {
            Row() {
              CharacterImageView({
                imageUri: item.avatarUri,
                fallbackName: item.fallbackName,
                imgWidth: 24,
                imgHeight: 24,
                imgBorderRadius: 12,
                displayMode: 'thumbnail'
              })
              Text(item.displayName)
                .fontSize($r('app.float.world_font_micro'))
                .fontColor(item.instanceId === this.viewModel?.expectedCharacterInstanceIdOfPage()
                  ? $r('app.color.world_gold') : $r('app.color.world_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 4 })
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius($r('app.float.world_radius_chip'))
            .backgroundColor(item.instanceId === this.viewModel?.expectedCharacterInstanceIdOfPage()
              ? $r('app.color.world_surface_2') : Color.Transparent)
            .borderWidth(item.instanceId === this.viewModel?.expectedCharacterInstanceIdOfPage() ? 1 : 0)
            .borderColor($r('app.color.world_gold'))
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.switchCharacter(item.instanceId);
            })
          }, (item: CharacterSwitcherItemUiModel) => item.instanceId)
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: 6,
        bottom: 6
      })
      .backgroundColor($r('app.color.world_surface_1'))
      .borderWidth({ top: 1 })
      .borderColor($r('app.color.world_border'))
    }
  }

  @Builder
  tabBar(): void {
    Row() {
      this.tabItem($r('app.string.world_archive_tab_memory'), ArchiveTab.Memory)
      this.tabItem($r('app.string.world_archive_tab_activity'), ArchiveTab.Activity)
      this.tabItem($r('app.string.world_archive_tab_relationship'), ArchiveTab.Relationship)
      this.tabItem($r('app.string.world_archive_tab_diagnostic'), ArchiveTab.Diagnostic)
    }
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding')
    })
    .backgroundColor($r('app.color.world_bg'))
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  tabItem(label: ResourceStr, tab: ArchiveTab): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.world_font_body'))
        .fontColor(this.selectedTab === tab
          ? $r('app.color.world_gold') : $r('app.color.world_text_secondary'))
        .fontWeight(this.selectedTab === tab ? FontWeight.Medium : FontWeight.Normal)
        .padding({ top: 10, bottom: 8 })

      Divider()
        .width(this.selectedTab === tab ? 24 : 0)
        .height(2)
        .color($r('app.color.world_gold'))
        .borderRadius(1)
    }
    .margin({ right: 16 })
    .onClick(() => {
      this.selectedTab = tab;
    })
  }

  @Builder
  tabContent(): void {
    Scroll() {
      Column() {
        if (this.selectedTab === ArchiveTab.Memory) {
          this.memoryTab()
        } else if (this.selectedTab === ArchiveTab.Activity) {
          this.activityTab()
        } else if (this.selectedTab === ArchiveTab.Relationship) {
          this.relationshipTab()
        } else {
          this.diagnosticTab()
        }
        Column().width('100%').height(100)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: 12
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  memoryTab(): void {
    this.filterBar()

    if (this.actionError.length > 0) {
      Text(this.actionError)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_error'))
        .width('100%')
        .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    }

    if (this.memories.length === 0) {
      Column() {
        WorldEmptyState({
          title: $r('app.string.world_memory_empty_title'),
          description: $r('app.string.world_memory_empty_desc'),
          primaryLabel: $r('app.string.world_memory_add'),
          onPrimary: (): void => {
            this.openCreateForm();
          }
        })
      }
      .width('100%')
      .padding({ top: 32, bottom: 32 })
    } else {
      ForEach(this.memories, (m: MemoryItemUiModel) => {
        this.memoryCard(m)
      }, (m: MemoryItemUiModel) => m.id)
    }
  }

  @Builder
  filterBar(): void {
    Row() {
      Button($r('app.string.world_memory_filter_all'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor(this.filter === WorldCharacterMemoryListFilter.All
          ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
        .backgroundColor(this.filter === WorldCharacterMemoryListFilter.All
          ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_chip'))
        .height(30)
        .padding({ left: 10, right: 10 })
        .onClick(() => { this.changeFilter(WorldCharacterMemoryListFilter.All); })
      Button($r('app.string.world_archive_filter_manual'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor(this.filter === WorldCharacterMemoryListFilter.Manual
          ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
        .backgroundColor(this.filter === WorldCharacterMemoryListFilter.Manual
          ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_chip'))
        .height(30)
        .padding({ left: 10, right: 10 })
        .margin({ left: 6 })
        .onClick(() => { this.changeFilter(WorldCharacterMemoryListFilter.Manual); })
      Button($r('app.string.world_archive_filter_scene'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor(this.filter === WorldCharacterMemoryListFilter.Scene
          ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
        .backgroundColor(this.filter === WorldCharacterMemoryListFilter.Scene
          ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_chip'))
        .height(30)
        .padding({ left: 10, right: 10 })
        .margin({ left: 6 })
        .onClick(() => { this.changeFilter(WorldCharacterMemoryListFilter.Scene); })

      Blank().layoutWeight(1)

      Button('+')
        .fontSize(18)
        .fontColor($r('app.color.world_on_gold'))
        .backgroundColor($r('app.color.world_gold'))
        .borderRadius(15)
        .width(30)
        .height(30)
        .padding(0)
        .enabled(!this.isSaving && !this.isDeleting)
        .onClick(() => { this.openCreateForm(); })
    }
    .width('100%')
    .padding({ top: 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  memoryCard(m: MemoryItemUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        Row() {
          Text(m.typeLabel)
            .fontSize(11)
            .fontColor($r('app.color.world_gold'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })

          Text(this.importanceLabel(m.importance))
            .fontSize(11)
            .fontColor($r('app.color.world_text_secondary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })

          Text(m.originLabel)
            .fontSize(11)
            .fontColor($r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })

          Blank().layoutWeight(1)

          WorldStatusChip({
            label: m.statusLabel,
            isActive: m.status === WorldCharacterMemoryStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(m.content)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .width('100%')
          .margin({ top: 8 })
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
          .onClick(() => { this.openEditForm(m); })

        if (m.sourceSummary.length > 0) {
          Text(m.sourceSummary)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .width('100%')
            .margin({ top: 6 })
        }

        Row() {
          if (m.occurredAtLabel.length > 0) {
            Text(m.occurredAtLabel)
              .fontSize(10)
              .fontColor($r('app.color.world_text_tertiary'))
          }
          Text(m.createdAtLabel)
            .fontSize(10)
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ left: m.occurredAtLabel.length > 0 ? 8 : 0 })
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.world_border')).margin({ top: 8, bottom: 6 })

        Row() {
          if (m.hasEvidence) {
            Button($r('app.string.world_archive_view_evidence'))
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_gold'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius($r('app.float.world_radius_chip'))
              .height(28)
              .padding({ left: 8, right: 8 })
              .onClick(() => { this.openEvidence(m.id); })
          }

          Blank().layoutWeight(1)

          Button($r('app.string.world_memory_edit'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_gold'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .height(28)
            .padding({ left: 8, right: 8 })
            .enabled(!this.isSaving && !this.isDeleting)
            .onClick(() => { this.openEditForm(m); })

          if (m.status === WorldCharacterMemoryStatus.Active) {
            Button($r('app.string.world_memory_archive'))
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_text_secondary'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius($r('app.float.world_radius_chip'))
              .height(28)
              .padding({ left: 8, right: 8 })
              .margin({ left: 4 })
              .enabled(!this.isSaving && !this.isDeleting)
              .onClick(() => { this.handleArchive(m.id, true); })
          } else {
            Button($r('app.string.world_memory_restore'))
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_gold'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius($r('app.float.world_radius_chip'))
              .height(28)
              .padding({ left: 8, right: 8 })
              .margin({ left: 4 })
              .enabled(!this.isSaving && !this.isDeleting)
              .onClick(() => { this.handleArchive(m.id, false); })
          }

          Button($r('app.string.world_memory_delete'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ left: 4 })
            .enabled(!this.isSaving && !this.isDeleting)
            .onClick(() => { this.deletingMemoryId = m.id; })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  activityTab(): void {
    WorldSectionHeader({ title: $r('app.string.world_archive_activity_scenes') })

    if (this.activityScenes.length === 0) {
      Text('该角色尚未参与任何场景')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 12 })
    } else {
      ForEach(this.activityScenes, (scene: ActivitySceneUiModel) => {
        this.activitySceneCard(scene)
      }, (scene: ActivitySceneUiModel) => scene.sceneId)
    }

    WorldSectionHeader({ title: $r('app.string.world_archive_activity_messages') })
      .margin({ top: 16 })

    if (this.activityMessages.length === 0) {
      Text('该角色尚未发送任何消息')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 12 })
    } else {
      ForEach(this.activityMessages.slice(0, 20), (msg: ActivityMessageUiModel) => {
        this.activityMessageCard(msg)
      }, (msg: ActivityMessageUiModel) => msg.messageId)
    }

    WorldSectionHeader({ title: $r('app.string.world_archive_activity_moves') })
      .margin({ top: 16 })

    if (this.activityMoves.length === 0) {
      Text($r('app.string.world_archive_no_move_history'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 8 })
    } else {
      ForEach(this.activityMoves, (move: ActivityMoveUiModel) => {
        this.activityMoveCard(move)
      }, (move: ActivityMoveUiModel) => move.eventId)
    }
  }

  @Builder
  activitySceneCard(scene: ActivitySceneUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        Row() {
          Text(scene.locationMissing ? '地点已删除' : scene.locationName)
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          WorldStatusChip({
            label: scene.statusLabel,
            isActive: scene.status === WorldSceneStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Text(scene.startedAtLabel)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
          if (scene.endedAtLabel.length > 0) {
            Text(' → ' + scene.endedAtLabel)
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
          }
        }
        .margin({ top: 4 })

        Row() {
          Text('消息 ' + scene.messageCount.toString())
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
          Text('参与 ' + scene.participantCount.toString())
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ left: 8 })
          if (scene.characterSpoke) {
            Text('已发言')
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_gold'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 8 })
          }
        }
        .margin({ top: 4 })
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  activityMessageCard(msg: ActivityMessageUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        Row() {
          Text(msg.locationMissing ? '地点已删除' : msg.locationName)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
          Text(msg.sentAtLabel)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ left: 8 })
          Text(msg.visibilityLabel)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(msg.contentPreview)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .width('100%')
          .margin({ top: 6 })
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (msg.coParticipantNames.length > 0) {
          Text('同场: ' + msg.coParticipantNames.join(', '))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  activityMoveCard(move: ActivityMoveUiModel): void {
    WorldSurfaceCard({}) {
      Row() {
        Text(move.fromLocationMissing ? '未知' : move.fromLocationName)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(' → ')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))

        Text(move.toLocationMissing ? '未知' : move.toLocationName)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(move.occurredAtLabel)
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding(14)
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  relationshipTab(): void {
    Column() {
      Text($r('app.string.world_archive_relationship_not_available'))
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.world_text_primary'))
        .textAlign(TextAlign.Center)

      Text('世界角色关系模型尚未建立,未来将支持角色间关系图谱、好感度追踪与认知分析。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)

      Text($r('app.string.world_archive_player_identity_not_available'))
        .fontSize($r('app.float.world_font_section'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 24 })
        .textAlign(TextAlign.Center)

      Text('世界玩家身份尚未接入,未来将支持玩家在世界中的角色定位、与 NPC 的关系记录。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)

      Divider().color($r('app.color.world_border')).margin({ top: 24, bottom: 16 })

      Text($r('app.string.world_archive_original_card'))
        .fontSize($r('app.float.world_font_section'))
        .fontColor($r('app.color.world_text_secondary'))

      if (this.characterCardMissing) {
        Text($r('app.string.world_character_card_missing'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_error'))
          .margin({ top: 6 })
      } else {
        Row() {
          CharacterImageView({
            imageUri: this.avatarUri,
            fallbackName: this.fallbackName,
            imgWidth: 36,
            imgHeight: 36,
            imgBorderRadius: 18,
            displayMode: 'thumbnail'
          })
          Text(this.displayName)
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_text_primary'))
            .margin({ left: 8 })
        }
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        Text($r('app.string.world_archive_world_instance'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width(72)
          .flexShrink(0)
        Text(this.isActive ? '活跃' : '已停用')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
      }
      .margin({ top: 8 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 32, bottom: 32 })
  }

  @Builder
  diagnosticTab(): void {
    if (this.diagnostic === null) {
      Text('诊断数据不可用')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 24 })
    } else {
      WorldSectionHeader({ title: $r('app.string.world_archive_diagnostic_title') })

      WorldSurfaceCard({}) {
        Column() {
          Row() {
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_total'),
              this.diagnostic.totalMemories, $r('app.color.world_text_primary'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_with_source'),
              this.diagnostic.withSourceCount, $r('app.color.world_success'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_without_source'),
              this.diagnostic.withoutSourceCount, $r('app.color.world_text_tertiary'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_archived'),
              this.diagnostic.archivedCount, $r('app.color.world_text_tertiary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .alignItems(VerticalAlign.Top)

          Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })

          Row() {
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_dup_source'),
              this.diagnostic.duplicateSourceMessageCount, $r('app.color.world_warning'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_owner_mismatch'),
              this.diagnostic.ownerMismatchCount, $r('app.color.world_error'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_world_mismatch'),
              this.diagnostic.worldMismatchCount, $r('app.color.world_error'))
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .alignItems(VerticalAlign.Top)

          Row() {
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_missing_scene'),
              this.diagnostic.missingSceneRefCount, $r('app.color.world_warning'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_missing_message'),
              this.diagnostic.missingMessageRefCount, $r('app.color.world_warning'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_missing_location'),
              this.diagnostic.missingLocationRefCount, $r('app.color.world_text_tertiary'))
            this.diagnosticMetric($r('app.string.world_archive_diagnostic_missing_character'),
              this.diagnostic.missingCharacterRefCount, $r('app.color.world_text_tertiary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .alignItems(VerticalAlign.Top)
          .margin({ top: 8 })
        }
        .width('100%')
        .padding(14)
        .alignItems(HorizontalAlign.Start)
      }

      if (this.diagnostic.issues.length === 0) {
        Column() {
          Text($r('app.string.world_archive_diagnostic_no_issues'))
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_success'))
            .margin({ top: 16 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      } else {
        ForEach(this.diagnostic.issues, (issue: DiagnosticIssueUiModel) => {
          this.diagnosticIssueCard(issue)
        }, (issue: DiagnosticIssueUiModel) => issue.id)
      }
    }
  }

  @Builder
  diagnosticMetric(label: ResourceStr, value: number, color: ResourceColor): void {
    Column() {
      Text(value.toString())
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
      Text(label)
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
  }

  @Builder
  diagnosticIssueCard(issue: DiagnosticIssueUiModel): void {
    WorldSurfaceCard({}) {
      Row() {
        Text(issue.issueType)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.riskLabel(issue.riskLevel))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor(this.riskColor(issue.riskLevel))
          .backgroundColor(this.riskBgColor(issue.riskLevel))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderWidth(1)
          .borderColor(this.riskColor(issue.riskLevel))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(issue.description)
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 4 })
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
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
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_memory_form_content'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      TextArea({
        text: this.formContent,
        placeholder: $r('app.string.world_memory_form_content_placeholder')
      })
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_primary'))
        .backgroundColor($r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_card'))
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
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      Text($r('app.string.world_memory_form_type'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        Button($r('app.string.world_memory_type_episodic'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(this.formType === WorldCharacterMemoryType.Episodic
            ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
          .backgroundColor(this.formType === WorldCharacterMemoryType.Episodic
            ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(30)
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.formType = WorldCharacterMemoryType.Episodic; })
        Button($r('app.string.world_memory_type_semantic'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(this.formType === WorldCharacterMemoryType.Semantic
            ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
          .backgroundColor(this.formType === WorldCharacterMemoryType.Semantic
            ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(30)
          .padding({ left: 10, right: 10 })
          .margin({ left: 6 })
          .onClick(() => { this.formType = WorldCharacterMemoryType.Semantic; })
        Button($r('app.string.world_memory_type_reflection'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(this.formType === WorldCharacterMemoryType.Reflection
            ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
          .backgroundColor(this.formType === WorldCharacterMemoryType.Reflection
            ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(30)
          .padding({ left: 10, right: 10 })
          .margin({ left: 6 })
          .onClick(() => { this.formType = WorldCharacterMemoryType.Reflection; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Text($r('app.string.world_memory_form_importance'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        ForEach(this.importanceOptions(), (n: number) => {
          Button(n.toString())
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(this.formImportance === n
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
            .backgroundColor(this.formImportance === n
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .height(30)
            .width(44)
            .margin({ right: 6 })
            .onClick(() => { this.formImportance = n; })
        }, (n: number) => n.toString())
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.world_memory_form_location'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        Button(this.formLocationId.length === 0
          ? $r('app.string.world_memory_form_location_none')
          : this.resolveLocationName(this.formLocationId))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(30)
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.formLocationId = '';
          })
        Text($r('app.string.world_memory_form_location_clear'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 4 })
      .alignItems(VerticalAlign.Center)
      Row() {
        ForEach(this.locationOptions, (loc: MemoryLocationOptionUiModel) => {
          Button(loc.name)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(this.formLocationId === loc.id
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_primary'))
            .backgroundColor(this.formLocationId === loc.id
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .height(30)
            .padding({ left: 8, right: 8 })
            .margin({ right: 6, bottom: 4 })
            .onClick(() => { this.formLocationId = loc.id; })
        }, (loc: MemoryLocationOptionUiModel) => loc.id)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Text($r('app.string.world_memory_form_occurred_at'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        Text(this.formOccurredAt > 0
          ? this.formatTimestamp(this.formOccurredAt) : '未指定')
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(30)
          .padding({ left: 10, right: 10 })
          .layoutWeight(1)
        Button(this.formOccurredAt > 0
          ? $r('app.string.world_memory_form_occurred_clear')
          : $r('app.string.world_memory_form_occurred_now'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_gold'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(30)
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

      Row() {
        Button($r('app.string.world_memory_cancel'))
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_secondary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(36)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => { this.formMode = MemoryFormMode.None; })
        Button(isEdit
          ? $r('app.string.world_memory_save')
          : $r('app.string.world_memory_create'))
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_on_gold'))
          .backgroundColor($r('app.color.world_gold'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(36)
          .layoutWeight(1)
          .enabled(!this.isSaving && this.formContent.trim().length > 0)
          .onClick(() => { this.submitForm(isEdit); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  deleteConfirmSheet(): void {
    Column() {
      Text($r('app.string.world_memory_delete_title'))
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_memory_delete_confirm'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })

      Row() {
        Button($r('app.string.world_memory_cancel'))
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_secondary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(36)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => { this.deletingMemoryId = ''; })
        Button($r('app.string.world_memory_delete'))
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_on_gold'))
          .backgroundColor($r('app.color.world_error'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(36)
          .layoutWeight(1)
          .enabled(!this.isDeleting)
          .onClick(() => { this.handleDelete(this.deletingMemoryId); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  private async changeFilter(filter: WorldCharacterMemoryListFilter): Promise<void> {
    if (this.filter === filter) {
      return;
    }
    this.filter = filter;
    await this.loadSnapshot();
  }

  private switchCharacter(instanceId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (instanceId === this.viewModel.expectedCharacterInstanceIdOfPage()) {
      return;
    }
    const worldId: string = this.viewModel.expectedWorldIdOfPage();
    this.viewModel.setTarget(worldId, instanceId);
    this.filter = WorldCharacterMemoryListFilter.Active;
    this.selectedTab = ArchiveTab.Memory;
    this.loadSnapshot();
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

  private openEvidence(memoryId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_EVIDENCE_ID_KEY, memoryId);
    router.pushUrl({ url: 'pages/world/WorldMemoryEvidencePage' });
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
    return stars;
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

  private riskLabel(level: DiagnosticRiskLevel): string {
    if (level === DiagnosticRiskLevel.Critical) {
      return '严重';
    }
    if (level === DiagnosticRiskLevel.Warning) {
      return '警告';
    }
    if (level === DiagnosticRiskLevel.Notice) {
      return '提醒';
    }
    return '信息';
  }

  private riskColor(level: DiagnosticRiskLevel): string {
    if (level === DiagnosticRiskLevel.Critical) {
      return WorldColors.ERROR;
    }
    if (level === DiagnosticRiskLevel.Warning) {
      return WorldColors.WARNING;
    }
    if (level === DiagnosticRiskLevel.Notice) {
      return WorldColors.INFO;
    }
    return WorldColors.TEXT_TERTIARY;
  }

  private riskBgColor(level: DiagnosticRiskLevel): string {
    if (level === DiagnosticRiskLevel.Critical) {
      return '#3D2020';
    }
    if (level === DiagnosticRiskLevel.Warning) {
      return '#3D3220';
    }
    if (level === DiagnosticRiskLevel.Notice) {
      return '#1E2D3D';
    }
    return WorldColors.SURFACE_2;
  }
}
