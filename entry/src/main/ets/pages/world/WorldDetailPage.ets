/**
 * WorldDetailPage 世界详情页(W1D 沉浸式地图重构)
 *
 * 重构为 map-centric 沉浸式布局:
 * - 顶部导航栏:返回 / 世界名 / 更多菜单(含"编辑地图"入口)
 * - 沉浸式地图视口(2.5D):地点节点 + 角色布告板 + 连接线 + 浮动工具栏 + FAB
 * - 底部摘要栏:地点 / 连接 / 角色 / 事件 数量
 * - 选中地点 → bindSheet 弹窗(保留原有地点弹窗逻辑)
 *
 * 浏览模式=默认,无编辑工具栏;编辑模式=⠇菜单切换,允许拖动节点
 *
 * 保留全部路由逻辑、弹窗逻辑、数据加载逻辑、刷新令牌机制。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { WorldDetailViewModel } from '../../viewmodels/world/WorldDetailViewModel';
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
  PENDING_WORLD_INSTANCE_DETAIL_ID_KEY,
  PENDING_WORLD_CURATOR_WORLD_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import {
  WorldLocationSceneSheetViewModel,
  LocationSheetLoadState,
  LocationSheetUiModel,
  SheetCharacterUiModel
} from '../../viewmodels/world/WorldLocationSceneSheetViewModel';
import {
  WorldImmersiveMapViewModel,
  MapEditMode,
  MapLoadState
} from '../../viewmodels/world/WorldImmersiveMapViewModel';
import { ImmersiveMapLayout, ImmersiveMapViewport, BILLBOARD_MAX_VISIBLE } from '../../viewmodels/world/WorldImmersiveMapLayout';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldImmersiveMap, NodeBillboardData } from '../../components/world/WorldImmersiveMap';
import { BillboardCharacterSlotData } from '../../components/world/WorldMapCharacterBillboard';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';

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
  @StorageProp(WORLD_DETAIL_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  refreshToken: number = 0;

  @State private isEditMode: boolean = false;
  @State private billboardData: NodeBillboardData[] = [];

  @State private sheetViewModel: WorldLocationSceneSheetViewModel | null = null;
  @State private locationSheetVisible: boolean = false;
  @State private sheetLoadState: LocationSheetLoadState = LocationSheetLoadState.Loading;
  @State private sheetErrorMessage: string = '';
  @State private sheetDetail: LocationSheetUiModel | null = null;
  @State private sheetWorldId: string = '';
  @State private sheetLocationId: string = '';
  @State private sheetActionError: string = '';
  @State private sheetStartConfirmVisible: boolean = false;

  @State private moreMenuVisible: boolean = false;
  @State private dragError: string = '';

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
        AppServices.getWorldMapInteractionService()
      );

      Logger.info(LOG_TAG, 'aboutToAppear: pageInstance=' + this.pageInstanceShortId
        + ', worldShortId=' + worldId.substring(worldId.length - 8));
      this.isInitializing = false;
      await this.loadDetail(worldId);
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
    Stack() {
      Column() {
        this.topNavArea();
        this.contentArea();
        this.bottomSummaryBar();
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.world_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.moreMenuVisible) {
        this.moreMenuOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.locationSheetVisible, this.locationSceneSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        if (this.sheetViewModel !== null) {
          this.sheetViewModel.dispose();
          this.sheetViewModel = null;
        }
        this.locationSheetVisible = false;
        this.sheetDetail = null;
        this.sheetActionError = '';
        this.sheetStartConfirmVisible = false;
      }
    })
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
          .fontColor($r('app.color.world_text_secondary'))
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

        Divider().color($r('app.color.world_border')).margin({ top: 4, bottom: 4 })

        this.moreMenuItem($r('app.string.world_ui_more_delete_world'), false, (): void => {
          this.moreMenuVisible = false;
          this.openWorldEdit();
        })

        Column().width('100%').height(this.navBarHeight + 8)
      }
      .width('100%')
      .backgroundColor($r('app.color.world_surface_elevated'))
      .borderRadius({ topLeft: 16, topRight: 16 })
      .borderWidth({ top: 1 })
      .borderColor($r('app.color.world_border'))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  moreMenuItem(label: ResourceStr, disabled: boolean, action: () => void): void {
    Text(label)
      .fontSize($r('app.float.world_font_body'))
      .fontColor(disabled
        ? $r('app.color.world_text_tertiary')
        : $r('app.color.world_text_primary'))
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
        .fontColor($r('app.color.world_text_secondary'))
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
          .fontColor($r('app.color.world_text_primary'))
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
          .fontColor($r('app.color.world_gold'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 4 })
      }

      Button('⋮')
        .fontSize(22)
        .fontColor($r('app.color.world_text_secondary'))
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
        .color($r('app.color.world_gold'))
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
          this.openCharacterManage();
        },
        onCharacterTap: (instanceId: string): void => {
          this.openInstanceDetail(instanceId);
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
          .backgroundColor($r('app.color.world_surface_1'))
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
        .backgroundColor($r('app.color.world_surface_1'))
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
      Row() {
        this.summaryItem($r('app.string.world_ui_locations_label'), this.detail.world.locationCount)
        this.summaryItem($r('app.string.world_ui_characters_label'), this.detail.characters.length)
        this.summaryItem($r('app.string.world_edge_count_label'), this.detail.edgeCount)
        this.summaryItem($r('app.string.world_event_count_label'), this.detail.eventCount)
      }
      .width('100%')
      .height($r('app.float.world_bottom_bar_height'))
      .backgroundColor($r('app.color.world_bg'))
      .borderWidth({ top: 1 })
      .borderColor($r('app.color.world_border'))
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        bottom: this.navBarHeight
      })
      .justifyContent(FlexAlign.SpaceAround)
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  summaryItem(label: ResourceStr, count: number): void {
    Column() {
      Text(count.toString())
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.world_text_primary'))
      Text(label)
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
  }

  @Builder
  locationSceneSheet(): void {
    Column() {
      Row() {
        Text($r('app.string.world_location_sheet_title'))
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.world_text_primary'))
          .layoutWeight(1)
        Button('×')
          .fontSize(18)
          .fontColor($r('app.color.world_text_secondary'))
          .backgroundColor(Color.Transparent)
          .width(32)
          .height(32)
          .padding(0)
          .align(Alignment.Center)
          .onClick(() => {
            this.closeLocationSheet();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.sheetLoadState === LocationSheetLoadState.Loading) {
        Column() {
          LoadingProgress().width(32).height(32).color($r('app.color.world_gold'))
          Text($r('app.string.world_location_sheet_loading'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_secondary'))
            .margin({ top: 8 })
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.sheetLoadState === LocationSheetLoadState.NotFound) {
        Column() {
          Text($r('app.string.world_detail_not_found'))
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_text_secondary'))
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.sheetLoadState === LocationSheetLoadState.Error) {
        Column() {
          Text(this.sheetErrorMessage.length > 0 ? this.sheetErrorMessage : '加载失败')
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_error'))
        }
        .width('100%')
        .padding({ top: 24, bottom: 24 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.sheetLoadState === LocationSheetLoadState.Ready && this.sheetDetail !== null) {
        this.locationSheetContent(this.sheetDetail)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  locationSheetContent(detail: LocationSheetUiModel): void {
    Scroll() {
      Column() {
        Row() {
          Text(detail.locationName.length > 0 ? detail.locationName : '(未命名地点)')
            .fontSize($r('app.float.world_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.world_text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          WorldStatusChip({
            label: detail.locationStatus === WorldLocationStatus.Active
              ? '活跃'
              : '已归档',
            isActive: detail.locationStatus === WorldLocationStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        if (detail.locationDescription.length > 0) {
          Text(detail.locationDescription)
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_text_secondary'))
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 8 })
            .width('100%')
        }

        Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })
        Row() {
          Text(detail.activeScene !== null
            ? $r('app.string.world_location_sheet_active_scene')
            : $r('app.string.world_location_sheet_no_active_scene'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(detail.activeScene !== null
              ? $r('app.color.world_gold') : $r('app.color.world_text_tertiary'))
            .layoutWeight(1)
          if (detail.endedSceneCount > 0) {
            Text($r('app.string.world_location_sheet_ended_count') + ': ' + detail.endedSceneCount.toString())
              .fontSize(11)
              .fontColor($r('app.color.world_text_tertiary'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })
        Text($r('app.string.world_scene_active_characters'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .width('100%')
        this.sheetCharactersList(detail.characters)

        if (this.sheetActionError.length > 0) {
          Text(this.sheetActionError)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .width('100%')
            .margin({ top: 8 })
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
        }

        if (this.sheetStartConfirmVisible) {
          Column() {
            Text($r('app.string.world_location_sheet_start_confirm_title'))
              .fontSize($r('app.float.world_font_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.world_text_primary'))
              .width('100%')
            Text($r('app.string.world_location_sheet_start_confirm_desc'))
              .fontSize($r('app.float.world_font_body'))
              .fontColor($r('app.color.world_text_secondary'))
              .margin({ top: 6 })
              .width('100%')
            Row() {
              WorldSecondaryButton({
                label: $r('app.string.world_scene_cancel'),
                fullWidth: true,
                onButtonClick: (): void => {
                  this.sheetStartConfirmVisible = false;
                }
              })
                .layoutWeight(1)
                .margin({ right: 8 })
              WorldPrimaryButton({
                label: $r('app.string.world_location_sheet_start_scene'),
                fullWidth: true,
                isEnabled: this.sheetViewModel !== null && !this.sheetViewModel.isStarting,
                onButtonClick: (): void => {
                  this.confirmStartScene();
                }
              })
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 12 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_card'))
          .margin({ top: 12 })
        }

        if (!this.sheetStartConfirmVisible) {
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
              label: $r('app.string.world_location_sheet_enter_scene'),
              fullWidth: true,
              isEnabled: detail.canStartScene || detail.activeScene !== null,
              onButtonClick: (): void => {
                this.onEnterSceneClick();
              }
            })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 16 })
          .alignItems(VerticalAlign.Center)
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

  @Builder
  sheetCharactersList(characters: SheetCharacterUiModel[]): void {
    if (characters.length === 0) {
      Text($r('app.string.world_scene_no_characters'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .margin({ top: 6 })
    } else {
      Column() {
        ForEach(characters, (c: SheetCharacterUiModel) => {
          Row() {
            CharacterImageView({
              imageUri: c.avatarUri,
              fallbackName: c.displayName,
              imgWidth: 32,
              imgHeight: 32,
              imgBorderRadius: 16,
              displayMode: 'thumbnail',
              objectFit: ImageFit.Cover
            })
            Column() {
              Text(c.displayName)
                .fontSize($r('app.float.world_font_body'))
                .fontColor(c.isActive
                  ? $r('app.color.world_text_primary') : $r('app.color.world_text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(c.isActive ? '活跃' : '停用')
                .fontSize($r('app.float.world_font_micro'))
                .fontColor(c.isActive
                  ? $r('app.color.world_gold') : $r('app.color.world_text_tertiary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 8 })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        }, (c: SheetCharacterUiModel) => c.instanceId + '|' + (c.isActive ? '1' : '0'))
      }
      .width('100%')
      .margin({ top: 4 })
    }
  }

  // ===== Event handlers =====

  private onLocationTapped(locationId: string): void {
    if (this.currentWorldId.length === 0 || locationId.length === 0) {
      return;
    }
    this.selectedLocationId = locationId;
    this.openLocationSheet(this.currentWorldId, locationId);
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

  private openLocationSheet(worldId: string, locationId: string): void {
    if (this.sheetViewModel !== null) {
      this.sheetViewModel.dispose();
    }
    const vm: WorldLocationSceneSheetViewModel = new WorldLocationSceneSheetViewModel(
      AppServices.getWorldRepository(),
      AppServices.getWorldLocationRepository(),
      AppServices.getWorldCharacterInstanceRepository(),
      AppServices.getWorldSceneRepository(),
      AppServices.getWorldSceneService(),
      AppServices.getCharacterService()
    );
    this.sheetViewModel = vm;
    this.sheetWorldId = worldId;
    this.sheetLocationId = locationId;
    this.sheetLoadState = LocationSheetLoadState.Loading;
    this.sheetErrorMessage = '';
    this.sheetDetail = null;
    this.sheetActionError = '';
    this.sheetStartConfirmVisible = false;
    this.selectedLocationId = locationId;
    this.locationSheetVisible = true;
    Logger.info(LOG_TAG, 'openLocationSheet: locShortId=' + locationId.substring(locationId.length - 8)
      + ', vmInstance=' + vm.instanceShortId);
    this.loadSheetSnapshot(worldId, locationId);
  }

  private closeLocationSheet(): void {
    if (this.sheetViewModel !== null) {
      this.sheetViewModel.dispose();
      this.sheetViewModel = null;
    }
    this.locationSheetVisible = false;
    this.sheetDetail = null;
    this.sheetLoadState = LocationSheetLoadState.Loading;
    this.sheetErrorMessage = '';
    this.sheetActionError = '';
    this.sheetStartConfirmVisible = false;
  }

  private async loadSheetSnapshot(worldId: string, locationId: string): Promise<void> {
    if (this.sheetViewModel === null) {
      return;
    }
    await this.sheetViewModel.loadSnapshot(worldId, locationId);
    if (this.sheetViewModel === null) {
      return;
    }
    this.sheetLoadState = this.sheetViewModel.state;
    this.sheetErrorMessage = this.sheetViewModel.errorMessage;
    this.sheetDetail = this.sheetViewModel.detail;
  }

  private async onEnterSceneClick(): Promise<void> {
    if (this.sheetViewModel === null || this.sheetDetail === null) {
      return;
    }
    if (this.sheetDetail.activeScene !== null) {
      this.navigateToSceneChat(this.sheetDetail.activeScene.id);
      return;
    }
    if (!this.sheetDetail.canStartScene) {
      this.sheetActionError = '当前世界或地点已归档,无法开始新场景';
      return;
    }
    this.sheetStartConfirmVisible = true;
  }

  private async confirmStartScene(): Promise<void> {
    if (this.sheetViewModel === null || this.sheetDetail === null) {
      return;
    }
    this.sheetActionError = '';
    const result = await this.sheetViewModel.enterScene();
    if (result.success) {
      this.sheetStartConfirmVisible = false;
      this.bumpSceneTokens();
      this.navigateToSceneChat(result.sceneId);
    } else {
      this.sheetActionError = result.errorMessage;
    }
  }

  private navigateToSceneChat(sceneId: string): void {
    if (sceneId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_SCENE_CHAT_ID_KEY, sceneId);
    this.closeLocationSheet();
    router.pushUrl({ url: 'pages/world/WorldSceneChatPage' });
  }

  private onViewSceneHistoryClick(): void {
    if (this.sheetWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.sheetWorldId);
    this.closeLocationSheet();
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

  private openInstanceDetail(instanceId: string): void {
    if (instanceId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSTANCE_DETAIL_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterInstanceDetailPage' });
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
