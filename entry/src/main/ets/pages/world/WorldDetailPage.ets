/**
 * WorldDetailPage 世界详情页(W1D 沉浸式地图重构 → W2A2)
 *
 * 重构为 map-centric 沉浸式布局:
 * - 顶部导航栏:返回 / 世界名 / 更多菜单(含"编辑地图"入口)
 * - 沉浸式地图视口(2.5D):地点节点 + 角色布告板 + 连接线 + 浮动工具栏 + FAB
 * - 底部摘要栏:地点 / 连接 / 角色 / 事件 数量 + 未放置角色入口
 * - 选中地点 → bindSheet 弹窗(保留原有地点弹窗逻辑)
 * - "+"FAB → 轻量菜单(添加角色 / 创建地点)
 * - 未放置角色 HUD → bindSheet 列表 + 放置操作
 *
 * 浏览模式=默认,无编辑工具栏;编辑模式=⠇菜单切换,允许拖动节点
 *
 * 保留全部路由逻辑、弹窗逻辑、数据加载逻辑、刷新令牌机制。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { WorldDetailViewModel } from '../../viewmodels/world/WorldDetailViewModel';
import { WorldStateService } from '../../services/world/WorldStateService';
import {
  WorldDetailUiModel,
  WorldSummaryUiModel,
  WorldLocationUiModel,
  WorldEdgeUiModel,
  WorldCharacterInstanceUiModel,
  WorldEventUiModel,
  WorldDetailLoadState,
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_LOCATION_ID_KEY,
  PENDING_WORLD_SCENE_CHAT_ID_KEY,
  PENDING_WORLD_SESSION_ID_KEY,
  PENDING_WORLD_INSTANCE_DETAIL_ID_KEY,
  PENDING_WORLD_CURATOR_WORLD_ID_KEY,
  PENDING_WORLD_INSPECTOR_WORLD_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import {
  WorldSceneLauncherViewModel,
  LauncherLoadState,
  LauncherUiModel,
  LauncherParticipantUiModel
} from '../../viewmodels/world/WorldSceneLauncherViewModel';
import { WorldCharacterMovementService, TravelOption } from '../../services/world/WorldCharacterMovementService';
import {
  WorldImmersiveMapViewModel,
  MapEditMode,
  MapLoadState,
  MapMovementPort
} from '../../viewmodels/world/WorldImmersiveMapViewModel';
import { ImmersiveMapLayout, ImmersiveMapViewport, BILLBOARD_MAX_VISIBLE } from '../../viewmodels/world/WorldImmersiveMapLayout';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldConversationSessionStatus } from '../../models/world/WorldConversationSession';
import { WorldImmersiveMap, NodeBillboardData } from '../../components/world/WorldImmersiveMap';
import { BillboardCharacterSlotData } from '../../components/world/WorldMapCharacterBillboard';
import { ActiveLocationOptionUiModel } from '../../viewmodels/world/WorldCharacterManageViewModel';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG: string = 'WorldDetailPage';

function generateShortId(): string {
  const ts: number = Date.now();
  const tail: number = Math.floor(ts % 0xffff);
  return tail.toString(16).padStart(4, '0');
}

@Entry
@Component
struct WorldDetailPage {
  @State private viewModel: WorldDetailViewModel | null = null;
  @State private mapViewModel: WorldImmersiveMapViewModel | null = null;
  @State private currentWorldId: string = '';
  @State private isInitializing: boolean = true;
  @State private initError: string = '';
  @State private state: WorldDetailLoadState = WorldDetailLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldDetailUiModel | null = null;
  @State private selectedLocationId: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @StorageProp(WORLD_DETAIL_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  refreshToken: number = 0;

  @State private isEditMode: boolean = false;
  @State private billboardData: NodeBillboardData[] = [];

  @State private launcherViewModel: WorldSceneLauncherViewModel | null = null;
  @State private launcherSheetVisible: boolean = false;
  @State private launcherLoadState: LauncherLoadState = LauncherLoadState.Loading;
  @State private launcherErrorMessage: string = '';
  @State private launcherDetail: LauncherUiModel | null = null;
  @State private launcherWorldId: string = '';
  @State private launcherLocationId: string = '';
  @State private launcherActionError: string = '';

  @State private moreMenuVisible: boolean = false;
  @State private dragError: string = '';
  @State private unplacedCharacters: WorldCharacterInstanceUiModel[] = [];
  @State private unplacedCount: number = 0;
  @State private addMenuVisible: boolean = false;
  @State private unplacedSheetVisible: boolean = false;
  @State private placeForInstanceId: string = '';
  @State private placeForInstanceName: string = '';
  @State private placeLocationSheetVisible: boolean = false;
  @State private placeActiveLocations: ActiveLocationOptionUiModel[] = [];
  @State private placeOperating: boolean = false;
  @State private placeError: string = '';
  @State private travelSheetVisible: boolean = false;
  @State private travelInstanceId: string = '';
  @State private travelInstanceName: string = '';
  @State private travelOptions: TravelOption[] = [];
  @State private travelOperating: boolean = false;
  @State private travelError: string = '';

  private stateService: WorldStateService | null = null;
  private movementService: WorldCharacterMovementService | null = null;

  private readonly pageInstanceShortId: string = generateShortId();

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: pendingWorldId empty');
        this.isInitializing = false;
        this.state = WorldDetailLoadState.NotFound;
        return;
      }
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      this.currentWorldId = worldId;

      this.viewModel = new WorldDetailViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldLocationEdgeRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getWorldEventRepository(),
        AppServices.getCharacterService()
      );

      this.mapViewModel = new WorldImmersiveMapViewModel(
        AppServices.getWorldMapInteractionService(),
        new MapMovementPortAdapter(AppServices.getWorldCharacterMovementService())
      );

      this.stateService = AppServices.getWorldStateService();
      this.movementService = AppServices.getWorldCharacterMovementService();

      Logger.info(LOG_TAG, 'aboutToAppear: pageInstance=' + this.pageInstanceShortId
        + ', worldShortId=' + worldId.substring(worldId.length - 8));
      this.isInitializing = false;
      await this.loadDetail(worldId);
      AppServices.getWorldSessionPostProcessingOrchestrator()
        .startResumeIncompleteForWorld(worldId);
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.initError = '世界数据加载失败,请重试';
      this.state = WorldDetailLoadState.Error;
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.activate();
    if (this.mapViewModel !== null) {
      this.mapViewModel.activate();
    }
    if (this.currentWorldId.length === 0) {
      return;
    }
    await this.loadDetail(this.currentWorldId);
  }

  onRefreshTokenChange(): void {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    if (this.currentWorldId.length === 0) {
      return;
    }
    this.viewModel.activate();
    if (this.mapViewModel !== null) {
      this.mapViewModel.activate();
    }
    this.loadDetail(this.currentWorldId);
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
    if (this.mapViewModel !== null) {
      this.mapViewModel.dispose();
    }
  }

  private async loadDetail(worldId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.currentWorldId !== worldId) {
      this.selectedLocationId = '';
      this.currentWorldId = worldId;
    }
    await this.viewModel.loadSnapshot(worldId);
    this.state = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
    this.unplacedCharacters = this.viewModel.unplacedCharacters;
    this.unplacedCount = this.viewModel.unplacedCount;
    if (this.state === WorldDetailLoadState.Ready && this.detail !== null) {
      if (this.selectedLocationId.length > 0
        && !this.containsLocation(this.detail.locations, this.selectedLocationId)) {
        this.selectedLocationId = '';
      }
    } else {
      this.selectedLocationId = '';
    }
    if (this.mapViewModel !== null) {
      await this.mapViewModel.loadSnapshot(worldId);
    }
    this.recomputeBillboardData();
  }

  private containsLocation(locations: WorldLocationUiModel[], id: string): boolean {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === id) {
        return true;
      }
    }
    return false;
  }

  build(): void {
    Column() {
      Stack() {
        Column() {
          this.topNavArea();
          this.contentArea();
          this.bottomSummaryBar();
        }
        .width('100%')
        .height('100%')
        .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        if (this.moreMenuVisible) {
          this.moreMenuOverlay()
        }
        if (this.addMenuVisible) {
          this.addMenuOverlay()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .bindSheet(this.unplacedSheetVisible, this.unplacedCharactersSheet, {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
        onDisappear: () => {
          this.unplacedSheetVisible = false;
        }
      })
      .bindSheet(this.placeLocationSheetVisible, this.placeLocationSelectSheet, {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
        onDisappear: () => {
          this.placeLocationSheetVisible = false;
          this.placeForInstanceId = '';
        }
      })
      .bindSheet(this.travelSheetVisible, this.travelDestinationSheet, {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
        onDisappear: () => {
          this.travelSheetVisible = false;
          this.travelInstanceId = '';
        }
      })

      // 独立宿主:隔离地图组件重建对 bindSheet 的影响
      Column()
        .width(0)
        .height(0)
        .bindSheet(this.launcherSheetVisible, this.sceneLauncherSheet, {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
          onDisappear: () => {
            if (this.launcherViewModel !== null) {
              this.launcherViewModel.dispose();
              this.launcherViewModel = null;
            }
            this.launcherSheetVisible = false;
            this.launcherDetail = null;
            this.launcherActionError = '';
          }
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  moreMenuOverlay(): void {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.world_scrim'))
        .onClick(() => {
          this.moreMenuVisible = false;
        })

      Column() {
        Text($r('app.string.world_ui_more_menu_title'))
          .fontSize($r('app.float.world_font_section'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 16, top: 16, bottom: 8 })

        this.moreMenuItem($r('app.string.world_ui_more_edit_world'), false, (): void => {
          this.moreMenuVisible = false;
          this.openWorldEdit();
        })
        this.moreMenuItem(this.isEditMode ? '退出编辑地图' : '编辑地图', false, (): void => {
          this.moreMenuVisible = false;
          this.isEditMode = !this.isEditMode;
          if (this.mapViewModel !== null) {
            this.mapViewModel.setEditMode(this.isEditMode ? MapEditMode.Edit : MapEditMode.Browse);
          }
        })
        this.moreMenuItem($r('app.string.world_ui_more_location_manage'), false, (): void => {
          this.moreMenuVisible = false;
          this.openLocationCreate();
        })
        this.moreMenuItem($r('app.string.world_ui_more_edge_manage'), false, (): void => {
          this.moreMenuVisible = false;
          this.openEdgeManage();
        })
        this.moreMenuItem($r('app.string.world_ui_more_character_manage'),
          this.detail !== null && this.detail.world.status === WorldStatus.Archived, (): void => {
            this.moreMenuVisible = false;
            this.openCharacterManage();
          })
        this.moreMenuItem($r('app.string.world_ui_more_scene_history'), false, (): void => {
          this.moreMenuVisible = false;
          this.openSceneManage();
        })
        this.moreMenuItem($r('app.string.world_curator_entry'), false, (): void => {
          this.moreMenuVisible = false;
          this.openCurator();
        })
        this.moreMenuItem($r('app.string.world_inspector_entry'), false, (): void => {
          this.moreMenuVisible = false;
          this.openInspector();
        })

        Divider().color(ThemePalette.worldBorderColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

        this.moreMenuItem($r('app.string.world_ui_more_delete_world'), false, (): void => {
          this.moreMenuVisible = false;
          this.openWorldEdit();
        })

        Column().width('100%').height(this.navBarHeight + 8)
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius({ topLeft: 16, topRight: 16 })
      .borderWidth({ top: 1 })
      .borderColor(ThemePalette.worldBorderColor(this.effectiveTheme))
      .transition(TransitionEffect.translate({ y: 400 })
        .animation({ duration: 250, curve: Curve.EaseOut })
        .combine(TransitionEffect.OPACITY.animation({ duration: 200 })))
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  @Builder
  moreMenuItem(label: ResourceStr, disabled: boolean, action: () => void): void {
    Text(label)
      .fontSize($r('app.float.world_font_body'))
      .fontColor(disabled
        ? ThemePalette.textTertiaryColor(this.effectiveTheme)
        : ThemePalette.textPrimaryColor(this.effectiveTheme))
      .width('100%')
      .height(52)
      .padding({ left: 16 })
      .textAlign(TextAlign.Start)
      .enabled(!disabled)
      .onClick(action)
  }

  @Builder
  topNavArea(): void {
    Row() {
      Button('←')
        .fontSize(22)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .padding(0)
        .accessibilityText($r('app.string.world_back_to_list'))
        .onClick(() => {
          router.back();
        })

      Column() {
        Text(this.resolveWorldName())
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail !== null) {
          WorldStatusChip({
            label: this.resolveWorldStatusLabel(this.detail.world.status),
            isActive: this.detail.world.status === WorldStatus.Active
          })
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4 })

      if (this.isEditMode) {
        Text('编辑中')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 4 })
      }

      Button('⋮')
        .fontSize(22)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .padding(0)
        .accessibilityText($r('app.string.world_ui_more_menu_title'))
        .onClick(() => {
          this.moreMenuVisible = true;
        })
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
  contentArea(): void {
    if (this.isInitializing) {
      this.loadingView();
    } else if (this.initError.length > 0) {
      this.errorView(this.initError);
    } else if (this.state === WorldDetailLoadState.Loading) {
      this.loadingView();
    } else if (this.state === WorldDetailLoadState.NotFound) {
      this.notFoundView();
    } else if (this.state === WorldDetailLoadState.Error) {
      this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '世界数据加载失败,请重试');
    } else if (this.state === WorldDetailLoadState.Ready && this.detail !== null) {
      this.immersiveMapView()
    }
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(ThemePalette.accentColor(this.effectiveTheme))
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
        title: $r('app.string.world_detail_not_found'),
        primaryLabel: $r('app.string.world_back_to_list'),
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
  errorView(message: string): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_home_load_failed'),
        description: message,
        primaryLabel: $r('app.string.world_home_reload'),
        secondaryLabel: $r('app.string.world_back_to_list'),
        onPrimary: (): void => {
          if (this.currentWorldId.length > 0) {
            this.loadDetail(this.currentWorldId);
          }
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
  immersiveMapView(): void {
    Stack({ alignContent: Alignment.BottomStart }) {
      WorldImmersiveMap({
        mapLayout: this.mapViewModel !== null ? this.mapViewModel.mapLayout : null,
        locations: this.mapViewModel !== null ? this.mapViewModel.locations : [],
        edges: this.mapViewModel !== null ? this.mapViewModel.edges : [],
        characters: this.mapViewModel !== null ? this.mapViewModel.characters : [],
        placements: this.mapViewModel !== null ? this.mapViewModel.placements : [],
        selectedLocationId: this.selectedLocationId,
        isEditMode: this.isEditMode,
        worldStatus: this.detail !== null ? this.detail.world.status : WorldStatus.Archived,
        viewport: this.mapViewModel !== null ? this.mapViewModel.viewport : { offsetX: 0, offsetY: 0, zoom: 1.0 },
        billboardData: this.billboardData,
        onLocationTap: (locationId: string): void => {
          this.onLocationTapped(locationId);
        },
        onLocationDragEnd: (locationId: string, worldX: number, worldY: number): void => {
          this.onLocationDragEnd(locationId, worldX, worldY);
        },
        onZoomIn: (): void => {
          if (this.mapViewModel !== null) {
            this.mapViewModel.zoomIn();
          }
        },
        onZoomOut: (): void => {
          if (this.mapViewModel !== null) {
            this.mapViewModel.zoomOut();
          }
        },
        onReset: (): void => {
          if (this.mapViewModel !== null) {
            this.mapViewModel.resetViewport();
          }
          this.selectedLocationId = '';
        },
        onLocate: (): void => {
          this.selectedLocationId = '';
        },
        onPan: (dx: number, dy: number): void => {
          if (this.mapViewModel !== null) {
            this.mapViewModel.panBy(dx, dy);
          }
        },
        onAddCharacter: (): void => {
          this.addMenuVisible = true;
        },
        onCharacterTap: (instanceId: string): void => {
          this.onCharacterTapped(instanceId);
        },
        onTravelTo: (instanceId: string, targetLocationId: string): void => {
          this.handleTravelFromMap(instanceId, targetLocationId);
        },
        onOverflowTap: (): void => {
          this.openCharacterManage();
        },
        onCreateLocation: (): void => {
          this.openLocationCreate();
        }
      })

      if (this.dragError.length > 0) {
        Text(this.dragError)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_error'))
          .backgroundColor(ThemePalette.worldSurfaceColor(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .margin({ left: 12, bottom: 8 })
          .borderWidth(1)
          .borderColor($r('app.color.world_error'))
      }

      if (this.detail !== null && this.detail.anomalousEdgeCount > 0) {
        Row() {
          Text($r('app.string.world_detail_anomalous_edges') + ': ' + this.detail.anomalousEdgeCount.toString())
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .margin({ left: 4 })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(ThemePalette.worldSurfaceColor(this.effectiveTheme))
        .borderRadius($r('app.float.world_radius_chip'))
        .borderWidth(1)
        .borderColor($r('app.color.world_error'))
        .margin({ left: 12, bottom: 4 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  bottomSummaryBar(): void {
    if (this.detail !== null) {
      Column() {
        if (this.unplacedCount > 0) {
          Row() {
            Text('未放置角色 · ' + this.unplacedCount.toString())
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .layoutWeight(1)
            Text('查看')
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .onClick(() => {
                this.unplacedSheetVisible = true;
              })
          }
          .width('100%')
          .padding({ left: $r('app.float.world_page_padding'), right: $r('app.float.world_page_padding'), top: 6, bottom: 6 })
          .backgroundColor(ThemePalette.worldSurfaceColor(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_chip'))
          .margin({ left: $r('app.float.world_page_padding'), right: $r('app.float.world_page_padding'), bottom: 4 })
          .alignItems(VerticalAlign.Center)
        }
        Row() {
          this.summaryItem($r('app.string.world_ui_locations_label'), this.detail.world.locationCount)
          this.summaryItem($r('app.string.world_ui_characters_label'), this.detail.characters.length)
          this.summaryItem($r('app.string.world_edge_count_label'), this.detail.edgeCount)
          this.summaryItem($r('app.string.world_event_count_label'), this.detail.eventCount)
        }
        .width('100%')
        .height($r('app.float.world_bottom_bar_height'))
        .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
        .borderWidth({ top: 1 })
        .borderColor(ThemePalette.worldBorderColor(this.effectiveTheme))
        .padding({
          left: $r('app.float.world_page_padding'),
          right: $r('app.float.world_page_padding'),
          bottom: this.navBarHeight
        })
        .justifyContent(FlexAlign.SpaceAround)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
    }
  }

  @Builder
  summaryItem(label: ResourceStr, count: number): void {
    Column() {
      Text(count.toString())
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      Text(label)
        .fontSize($r('app.float.world_font_micro'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
  }

  @Builder
  addMenuOverlay(): void {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.world_scrim'))
        .onClick(() => {
          this.addMenuVisible = false;
        })

      Column() {
        this.addMenuItem('添加角色', (): void => {
          this.addMenuVisible = false;
          this.openCharacterManage();
        })
        this.addMenuItem('创建地点', (): void => {
          this.addMenuVisible = false;
          this.openLocationCreate();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: this.navBarHeight + 80, top: 12 })
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  addMenuItem(label: string, action: () => void): void {
    Button(label)
      .fontSize($r('app.float.world_font_body'))
      .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius(8)
      .height(48)
      .width('100%')
      .margin({ bottom: 8 })
      .onClick(action)
  }

  @Builder
  unplacedCharactersSheet(): void {
    Column() {
      Text('未放置角色')
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ top: 12, bottom: 8 })

      if (this.unplacedCharacters.length === 0) {
        Text('没有未放置的角色')
          .fontSize($r('app.float.world_font_body'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: 8, bottom: 16 })
      } else {
        Column() {
          ForEach(this.unplacedCharacters, (c: WorldCharacterInstanceUiModel) => {
            Row() {
              CharacterImageView({
                imageUri: c.avatarUri,
                fallbackName: c.fallbackName,
                imgWidth: 36,
                imgHeight: 36,
                imgBorderRadius: 18,
                displayMode: 'thumbnail',
                objectFit: ImageFit.Cover
              })
              Column() {
                Text(c.displayName)
                  .fontSize($r('app.float.world_font_body'))
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text('未放置')
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .margin({ left: 10 })
              .alignItems(HorizontalAlign.Start)

              WorldSecondaryButton({
                label: '放置',
                onButtonClick: (): void => {
                  this.openPlaceLocationSelect(c.id, c.displayName);
                }
              })
                .margin({ left: 8 })

              WorldSecondaryButton({
                label: '查看',
                onButtonClick: (): void => {
                  this.unplacedSheetVisible = false;
                  this.openInstanceDetail(c.id);
                }
              })
                .margin({ left: 4 })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .alignItems(VerticalAlign.Center)
          }, (c: WorldCharacterInstanceUiModel) => c.id)
        }
        .width('100%')
      }

      Column().width('100%').height(this.navBarHeight + 16)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  placeLocationSelectSheet(): void {
    Column() {
      Text('放置角色: ' + this.placeForInstanceName)
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ top: 12, bottom: 8 })

      if (this.placeError.length > 0) {
        Text(this.placeError)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_error'))
          .width('100%')
          .margin({ bottom: 8 })
      }

      if (this.placeActiveLocations.length === 0) {
        Text('没有可用地点,请先创建地点')
          .fontSize($r('app.float.world_font_body'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: 8, bottom: 16 })
      } else {
        ForEach(this.placeActiveLocations, (loc: ActiveLocationOptionUiModel) => {
          Button(loc.name)
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(8)
            .height(40)
            .width('100%')
            .margin({ bottom: 8 })
            .enabled(!this.placeOperating)
            .onClick(() => {
              this.handlePlaceCharacter(this.placeForInstanceId, loc.id);
            })
        }, (loc: ActiveLocationOptionUiModel) => loc.id)
      }

      Button($r('app.string.world_cancel'))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .borderRadius(8)
        .height(40)
        .width('100%')
        .margin({ top: 8 })
        .onClick(() => {
          this.placeLocationSheetVisible = false;
          this.placeForInstanceId = '';
        })

      Column().width('100%').height(this.navBarHeight + 16)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sceneLauncherSheet(): void {
    Column() {
      Row() {
        Text($r('app.string.world_location_sheet_title'))
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Button('×')
          .fontSize(18)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .width(32)
          .height(32)
          .padding(0)
          .align(Alignment.Center)
          .onClick(() => {
            this.closeLauncherSheet();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.launcherLoadState === LauncherLoadState.Loading) {
        Column() {
          LoadingProgress().width(32).height(32).color(ThemePalette.accentColor(this.effectiveTheme))
          Text($r('app.string.world_location_sheet_loading'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.launcherLoadState === LauncherLoadState.NotFound) {
        Column() {
          Text($r('app.string.world_detail_not_found'))
            .fontSize($r('app.float.world_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.launcherLoadState === LauncherLoadState.Error) {
        Column() {
          Text(this.launcherErrorMessage.length > 0 ? this.launcherErrorMessage : '加载失败')
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_error'))
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.launcherLoadState === LauncherLoadState.Ready && this.launcherDetail !== null) {
        this.launcherContent(this.launcherDetail)
      }
    }
    .width('100%')
    .backgroundColor(ThemePalette.worldSurfaceColor(this.effectiveTheme))
  }

  @Builder
  launcherContent(detail: LauncherUiModel): void {
    Scroll() {
      Column() {
        Text(detail.locationName.length > 0 ? detail.locationName : '(未命名地点)')
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Divider().color(ThemePalette.worldBorderColor(this.effectiveTheme)).margin({ top: 12, bottom: 8 })

        if (detail.canContinueSession) {
          Row() {
            Text('当前有进行中的会话')
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .layoutWeight(1)
            WorldStatusChip({ label: '活动中', isActive: true })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          WorldPrimaryButton({
            label: '继续会话',
            fullWidth: true,
            onButtonClick: (): void => {
              this.onContinueSessionClick();
            }
          })
            .margin({ top: 12 })
        } else if (detail.hasActiveScene && detail.isSceneEnded) {
          Row() {
            Text('该地点场景已结束')
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .layoutWeight(1)
            WorldStatusChip({ label: '已结束', isActive: false })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else if (!detail.hasActiveScene) {
          Text('该地点尚无场景,选择角色后创建')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
        } else if (detail.hasActiveSession) {
          Row() {
            Text('会话已结束,可选择角色开启新会话')
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

        Divider().color(ThemePalette.worldBorderColor(this.effectiveTheme)).margin({ top: 12, bottom: 8 })
        Text('选择参与角色')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')

        if (detail.participants.length === 0) {
          Text($r('app.string.world_scene_no_characters'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 6 })
        } else {
          Scroll() {
            Row() {
              ForEach(detail.participants, (p: LauncherParticipantUiModel) => {
                Column() {
                  Stack() {
                    CharacterImageView({
                      imageUri: p.avatarUri,
                      fallbackName: p.displayName,
                      imgWidth: 36,
                      imgHeight: 36,
                      imgBorderRadius: 18,
                      displayMode: 'thumbnail',
                      objectFit: ImageFit.Cover
                    })
                    if (p.selected) {
                      Circle({ width: 10, height: 10 })
                        .fill(ThemePalette.accentColor(this.effectiveTheme))
                        .position({ x: 26, y: 26 })
                    }
                  }
                  .width(36)
                  .height(36)
                  Text(p.displayName)
                    .fontSize(10)
                    .fontColor(p.selected ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .width(48)
                .margin({ right: 8 })
                .alignItems(HorizontalAlign.Center)
                .onClick(() => {
                  if (this.launcherViewModel !== null) {
                    this.launcherViewModel.toggleParticipant(p.instanceId);
                    this.launcherDetail = this.launcherViewModel.detail;
                  }
                })
              }, (p: LauncherParticipantUiModel) => p.instanceId + '|' + (p.selected ? '1' : '0'))
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .height(64)
          .margin({ top: 4 })
        }

        if (this.launcherActionError.length > 0) {
          Text(this.launcherActionError)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .width('100%')
            .margin({ top: 8 })
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.world_radius_chip'))
        }

        if (detail.canLaunchNewSession && !detail.canContinueSession) {
          Row() {
            WorldSecondaryButton({
              label: $r('app.string.world_location_sheet_view_history'),
              fullWidth: true,
              onButtonClick: (): void => {
                this.onViewSceneHistoryClick();
              }
            })
              .layoutWeight(1)
              .margin({ right: 8 })
            WorldPrimaryButton({
              label: '开始会话',
              fullWidth: true,
              isEnabled: this.launcherViewModel !== null
                && !this.launcherViewModel.isLaunching
                && detail.participants.filter((p: LauncherParticipantUiModel): boolean => p.selected).length > 0,
              onButtonClick: (): void => {
                this.onLaunchNewSessionClick();
              }
            })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 16 })
          .alignItems(VerticalAlign.Center)
        } else if (!detail.canContinueSession) {
          WorldSecondaryButton({
            label: $r('app.string.world_location_sheet_view_history'),
            fullWidth: true,
            onButtonClick: (): void => {
              this.onViewSceneHistoryClick();
            }
          })
            .margin({ top: 16 })
        }

        Column().width('100%').height(24)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  // ===== Event handlers =====

  private onLocationTapped(locationId: string): void {
    if (this.currentWorldId.length === 0 || locationId.length === 0) {
      return;
    }
    this.selectedLocationId = locationId;
    this.openLauncherSheet(this.currentWorldId, locationId, '');
  }

  private async onLocationDragEnd(locationId: string, worldX: number, worldY: number): Promise<void> {
    if (this.mapViewModel === null) {
      return;
    }
    this.dragError = '';
    const error: string = await this.mapViewModel.endDrag(locationId, worldX, worldY);
    if (error.length > 0) {
      this.dragError = error;
      setTimeout((): void => {
        this.dragError = '';
      }, 3000);
    }
  }

  private onCharacterTapped(instanceId: string): void {
    if (this.currentWorldId.length === 0 || instanceId.length === 0) {
      return;
    }
    this.openTravelSheetForCharacter(instanceId);
  }

  private resolveCharacterLocationId(instanceId: string): string {
    if (this.detail === null) {
      return '';
    }
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].id === instanceId) {
        return this.detail.characters[i].currentLocationId;
      }
    }
    return '';
  }

  private openLauncherSheet(worldId: string, locationId: string, preselectedInstanceId: string): void {
    if (this.launcherViewModel !== null) {
      this.launcherViewModel.dispose();
    }
    const vm: WorldSceneLauncherViewModel = new WorldSceneLauncherViewModel(
      AppServices.getWorldSceneLaunchService(),
      AppServices.getCharacterService(),
      AppServices.getWorldCharacterInstanceRepository()
    );
    vm.setPreselectedInstanceId(preselectedInstanceId);
    this.launcherViewModel = vm;
    this.launcherWorldId = worldId;
    this.launcherLocationId = locationId;
    this.launcherLoadState = LauncherLoadState.Loading;
    this.launcherErrorMessage = '';
    this.launcherDetail = null;
    this.launcherActionError = '';
    this.selectedLocationId = locationId;
    this.launcherSheetVisible = true;
    Logger.info(LOG_TAG, 'openLauncherSheet: locShortId=' + locationId.substring(locationId.length - 8)
      + ', preselect=' + (preselectedInstanceId.length > 0 ? '1' : '0')
      + ', vmInstance=' + vm.instanceShortId);
    this.loadLauncherSnapshot(worldId, locationId);
  }

  private closeLauncherSheet(): void {
    if (this.launcherViewModel !== null) {
      this.launcherViewModel.dispose();
      this.launcherViewModel = null;
    }
    this.launcherSheetVisible = false;
    this.launcherDetail = null;
    this.launcherLoadState = LauncherLoadState.Loading;
    this.launcherErrorMessage = '';
    this.launcherActionError = '';
  }

  private async loadLauncherSnapshot(worldId: string, locationId: string): Promise<void> {
    if (this.launcherViewModel === null) {
      return;
    }
    await this.launcherViewModel.loadSnapshot(worldId, locationId);
    if (this.launcherViewModel === null) {
      return;
    }
    this.launcherLoadState = this.launcherViewModel.state;
    this.launcherErrorMessage = this.launcherViewModel.errorMessage;
    this.launcherDetail = this.launcherViewModel.detail;
  }

  private async onContinueSessionClick(): Promise<void> {
    if (this.launcherViewModel === null || this.launcherDetail === null) {
      return;
    }
    this.launcherActionError = '';
    const result = await this.launcherViewModel.continueActiveSession();
    if (result.success) {
      this.bumpSceneTokens();
      this.navigateToSceneChat(result.sceneId, result.sessionId);
    } else {
      this.launcherActionError = result.errorMessage;
    }
  }

  private async onLaunchNewSessionClick(): Promise<void> {
    if (this.launcherViewModel === null || this.launcherDetail === null) {
      return;
    }
    this.launcherActionError = '';
    const result = await this.launcherViewModel.launchNewSession();
    if (result.success) {
      this.bumpSceneTokens();
      this.navigateToSceneChat(result.sceneId, result.sessionId);
    } else {
      this.launcherActionError = result.errorMessage;
    }
  }

  private navigateToSceneChat(sceneId: string, sessionId: string): void {
    if (sceneId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_SCENE_CHAT_ID_KEY, sceneId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_SESSION_ID_KEY, sessionId);
    this.closeLauncherSheet();
    router.pushUrl({ url: 'pages/world/WorldSceneChatPage' });
  }

  private onViewSceneHistoryClick(): void {
    if (this.launcherWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.launcherWorldId);
    this.closeLauncherSheet();
    router.pushUrl({ url: 'pages/world/WorldSceneManagePage' });
  }

  private bumpSceneTokens(): void {
    const detailToken: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, detailToken + 1);
    const chatToken: number = AppStorage.get<number>(WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY, chatToken + 1);
  }

  private openWorldEdit(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldEditPage' });
  }

  private openLocationCreate(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_LOCATION_ID_KEY, '');
    router.pushUrl({ url: 'pages/world/WorldLocationEditPage' });
  }

  private openLocationEdit(locationId: string): void {
    if (this.currentWorldId.length === 0 || locationId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_LOCATION_ID_KEY, locationId);
    router.pushUrl({ url: 'pages/world/WorldLocationEditPage' });
  }

  private openCharacterManage(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldCharacterManagePage' });
  }

  private openPlaceLocationSelect(instanceId: string, displayName: string): void {
    this.placeForInstanceId = instanceId;
    this.placeForInstanceName = displayName;
    this.placeError = '';
    this.placeOperating = false;
    this.placeActiveLocations = this.resolveActiveLocations();
    this.unplacedSheetVisible = false;
    this.placeLocationSheetVisible = true;
  }

  private resolveActiveLocations(): ActiveLocationOptionUiModel[] {
    if (this.detail === null) {
      return [];
    }
    const result: ActiveLocationOptionUiModel[] = [];
    for (let i: number = 0; i < this.detail.locations.length; i++) {
      const loc: WorldLocationUiModel = this.detail.locations[i];
      if (loc.status === WorldLocationStatus.Active) {
        result.push({ id: loc.id, name: loc.name });
      }
    }
    return result;
  }

  private async handlePlaceCharacter(instanceId: string, locationId: string): Promise<void> {
    if (this.stateService === null) {
      return;
    }
    this.placeOperating = true;
    this.placeError = '';
    try {
      await this.stateService.placeCharacter(instanceId, locationId);
      this.placeLocationSheetVisible = false;
      this.placeForInstanceId = '';
      this.bumpSceneTokens();
      await this.loadDetail(this.currentWorldId);
    } catch (e) {
      this.placeError = '放置失败,请重试';
    } finally {
      this.placeOperating = false;
    }
  }

  private openEdgeManage(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldEdgeManagePage' });
  }

  private openSceneManage(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldSceneManagePage' });
  }

  private openCurator(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_CURATOR_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldCuratorPage' });
  }

  private openInspector(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSPECTOR_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldInspectorPage' });
  }

  private openInstanceDetail(instanceId: string): void {
    if (instanceId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSTANCE_DETAIL_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterInstanceDetailPage' });
  }

  @Builder
  travelDestinationSheet(): void {
    Scroll() {
      Column() {
        Text('前往 - ' + this.travelInstanceName)
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 12, bottom: 8 })

        if (this.travelError.length > 0) {
          Text(this.travelError)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .width('100%')
            .margin({ bottom: 8 })
        }

        if (this.travelOptions.length === 0) {
          Text('当前地点没有可通行的连接')
            .fontSize($r('app.float.world_font_body'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 8, bottom: 16 })
        } else {
          ForEach(this.travelOptions, (option: TravelOption) => {
            Row() {
              Column() {
                Text(option.targetLocationName)
                  .fontSize($r('app.float.world_font_body'))
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(option.directionLabel + (option.isBidirectional ? ' · 双向' : ' · 单向'))
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              WorldPrimaryButton({
                label: '前往',
                isEnabled: !this.travelOperating,
                onButtonClick: (): void => {
                  this.handleTravelCharacter(option.targetLocationId);
                }
              })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .alignItems(VerticalAlign.Center)
          }, (option: TravelOption) => option.edgeId)
        }

        Row() {
          WorldSecondaryButton({
            label: '查看详情',
            fullWidth: true,
            onButtonClick: (): void => {
              this.travelSheetVisible = false;
              this.openInstanceDetail(this.travelInstanceId);
            }
          })
            .layoutWeight(1)
            .margin({ right: 8 })
          Button($r('app.string.world_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .borderRadius(8)
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.travelSheetVisible = false;
            })
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)

        Column().width('100%').height(this.navBarHeight + 16)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  private async openTravelSheetForCharacter(instanceId: string): Promise<void> {
    if (this.movementService === null) {
      this.openInstanceDetail(instanceId);
      return;
    }
    const displayName: string = this.resolveCharacterDisplayName(instanceId);
    this.travelInstanceId = instanceId;
    this.travelInstanceName = displayName;
    this.travelError = '';
    this.travelOperating = false;
    try {
      this.travelOptions = await this.movementService.listTravelOptions(instanceId);
    } catch (e) {
      this.travelOptions = [];
    }
    if (this.travelOptions.length === 0) {
      this.openInstanceDetail(instanceId);
      return;
    }
    this.travelSheetVisible = true;
  }

  private resolveCharacterDisplayName(instanceId: string): string {
    if (this.detail === null) {
      return '';
    }
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].id === instanceId) {
        return this.detail.characters[i].displayName;
      }
    }
    return '';
  }

  private async handleTravelCharacter(targetLocationId: string): Promise<void> {
    if (this.movementService === null || this.travelInstanceId.length === 0) {
      return;
    }
    this.travelOperating = true;
    this.travelError = '';
    try {
      await this.movementService.travelCharacter(this.travelInstanceId, targetLocationId);
      this.travelSheetVisible = false;
      this.travelInstanceId = '';
      this.bumpSceneTokens();
      await this.loadDetail(this.currentWorldId);
    } catch (e) {
      this.travelError = '移动失败,请重试';
    } finally {
      this.travelOperating = false;
    }
  }

  private handleTravelFromMap(instanceId: string, targetLocationId: string): void {
    this.travelInstanceId = instanceId;
    this.handleTravelCharacter(targetLocationId);
  }

  private resolveWorldName(): string {
    if (this.detail !== null) {
      return this.detail.world.name.length > 0 ? this.detail.world.name : '(未命名世界)';
    }
    return '世界详情';
  }

  private resolveWorldStatusLabel(status: WorldStatus): string {
    return status === WorldStatus.Archived ? '已归档' : '活跃';
  }

  private recomputeBillboardData(): void {
    if (this.mapViewModel === null) {
      this.billboardData = [];
      return;
    }
    const chars: WorldCharacterInstanceUiModel[] = this.mapViewModel.characters;
    const locs: WorldLocationUiModel[] = this.mapViewModel.locations;
    const result: NodeBillboardData[] = [];
    for (let li: number = 0; li < locs.length; li++) {
      const locId: string = locs[li].id;
      const atLocation: WorldCharacterInstanceUiModel[] = [];
      for (let ci: number = 0; ci < chars.length; ci++) {
        if (chars[ci].currentLocationId === locId) {
          atLocation.push(chars[ci]);
        }
      }
      const visibleCount: number = Math.min(atLocation.length, BILLBOARD_MAX_VISIBLE);
      const overflowCount: number = atLocation.length > BILLBOARD_MAX_VISIBLE
        ? atLocation.length - BILLBOARD_MAX_VISIBLE : 0;
      const slots: BillboardCharacterSlotData[] = [];
      for (let si: number = 0; si < visibleCount; si++) {
        const c: WorldCharacterInstanceUiModel = atLocation[si];
        const dx: number = si * 24 - (visibleCount - 1) * 12;
        slots.push({
          instanceId: c.id,
          displayName: c.displayName,
          avatarUri: c.avatarUri,
          fallbackName: c.fallbackName,
          isActive: c.isActive,
          dx: dx,
          dy: 0
        });
      }
      result.push({ locationId: locId, slots: slots, overflowCount: overflowCount });
    }
    this.billboardData = result;
  }
}

class MapMovementPortAdapter implements MapMovementPort {
  private readonly service: WorldCharacterMovementService;

  constructor(service: WorldCharacterMovementService) {
    this.service = service;
  }

  async travelCharacter(instanceId: string, targetLocationId: string): Promise<void> {
    await this.service.travelCharacter(instanceId, targetLocationId);
  }

  async listTravelOptions(instanceId: string): Promise<TravelOption[]> {
    return await this.service.listTravelOptions(instanceId);
  }
}
