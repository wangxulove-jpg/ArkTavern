/**
 * WorldDetailPage 世界详情页(W-UI-1A 重构)
 *
 * 重构:深色奇幻酒馆质感视觉,map-centric 工作台布局,
 * 浮动地图工具栏,FAB,管理菜单(bottom sheet),底部摘要栏。
 *
 * 保留全部路由逻辑、弹窗逻辑、数据加载逻辑、刷新令牌机制。
 *
 * 只读展示一个世界的完整信息,包含:
 * - 顶部导航栏:返回 / 世界名 / 更多菜单
 * - 地图视口(2.5D):地点节点关系图 + 浮动工具栏 + FAB
 * - 可滚动的信息区:世界描述 / 异常连接 / 选中地点 / 角色 / 事件
 * - 底部摘要栏:地点 / 连接 / 角色 / 事件 数量
 *
 * 生命周期保护 / 路由 / 不依赖:同 W-UI-1 原始约束。
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
  WorldLocationGraphLayout,
  WorldLocationNodeLayout,
  WorldLocationEdgeLayout,
  computeWorldLocationGraphLayout
} from '../../viewmodels/world/WorldLocationGraphLayout';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldLocationNode } from '../../components/world/WorldLocationNode';
import { WorldMapToolbar } from '../../components/world/WorldMapToolbar';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';
import { WorldMetrics } from '../../components/world/WorldDesignTokens';

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
  @State private currentWorldId: string = '';
  @State private isInitializing: boolean = true;
  @State private initError: string = '';
  @State private state: WorldDetailLoadState = WorldDetailLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldDetailUiModel | null = null;
  @State private graphLayout: WorldLocationGraphLayout | null = null;
  @State private selectedLocationId: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  @StorageProp(WORLD_DETAIL_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  refreshToken: number = 0;

  // ===== 地点人物弹窗(W-UX-1) =====
  @State private sheetViewModel: WorldLocationSceneSheetViewModel | null = null;
  @State private locationSheetVisible: boolean = false;
  @State private sheetLoadState: LocationSheetLoadState = LocationSheetLoadState.Loading;
  @State private sheetErrorMessage: string = '';
  @State private sheetDetail: LocationSheetUiModel | null = null;
  @State private sheetWorldId: string = '';
  @State private sheetLocationId: string = '';
  @State private sheetActionError: string = '';
  @State private sheetStartConfirmVisible: boolean = false;

  // ===== 管理菜单 =====
  @State private moreMenuVisible: boolean = false;

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
      Logger.info(LOG_TAG, 'aboutToAppear: pageInstance=' + this.pageInstanceShortId
        + ', vmInstance=' + this.viewModel.instanceShortId
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
    if (this.currentWorldId.length === 0) {
      return;
    }
    await this.loadDetail(this.currentWorldId);
  }

  onRefreshTokenChange(): void {
    Logger.info(LOG_TAG, 'onRefreshTokenChange: token=' + this.refreshToken
      + ', isInitializing=' + String(this.isInitializing)
      + ', currentWorldId=' + this.currentWorldId.substring(this.currentWorldId.length - 8)
      + ', pageInstance=' + this.pageInstanceShortId
      + (this.viewModel !== null ? ', vmInstance=' + this.viewModel.instanceShortId : ', vmInstance=null'));
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    if (this.currentWorldId.length === 0) {
      return;
    }
    this.viewModel.activate();
    this.loadDetail(this.currentWorldId);
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
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
    const selectedShort: string = this.selectedLocationId.length > 0
      ? this.selectedLocationId.substring(this.selectedLocationId.length - 8) : '(none)';
    Logger.info(LOG_TAG, 'apply snapshot: pageInstance=' + this.pageInstanceShortId
      + (this.viewModel !== null ? ', vmInstance=' + this.viewModel.instanceShortId : '')
      + ', state=' + this.state
      + ', detailNull=' + String(this.detail === null)
      + ', locationCount=' + (this.detail !== null ? this.detail.locations.length : 0)
      + ', charCount=' + (this.detail !== null ? this.detail.characters.length : 0)
      + ', selectedLocation=' + selectedShort);
    if (this.state === WorldDetailLoadState.Ready && this.detail !== null) {
      this.graphLayout = computeWorldLocationGraphLayout(
        this.detail.locations,
        this.detail.edges
      );
      if (this.selectedLocationId.length > 0
        && !this.containsLocation(this.detail.locations, this.selectedLocationId)) {
        this.selectedLocationId = '';
      }
    } else {
      this.graphLayout = null;
      this.selectedLocationId = '';
    }
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

  // ===== 管理菜单叠层 =====

  @Builder
  moreMenuOverlay(): void {
    Column() {
      // scrim
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.world_scrim'))
        .onClick(() => {
          this.moreMenuVisible = false;
        })

      // menu panel
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

  // ===== 顶部导航栏 =====

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

  // ===== 内容区 =====

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
      this.detailView(this.detail, this.selectedLocationId)
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

  /** 详情主体:map-centric 布局 */
  @Builder
  detailView(detail: WorldDetailUiModel, selectedLocationId: string): void {
    Column() {
      Scroll() {
        Column() {
          this.mapViewportSection(detail, selectedLocationId)

          if (detail.anomalousEdgeCount > 0) {
            this.anomalousEdgeBanner(detail.anomalousEdgeCount)
          }

          if (selectedLocationId.length > 0) {
            this.selectedLocationDetailSection(selectedLocationId, detail)
          }

          if (detail.world.description.length > 0) {
            this.worldDescriptionSection(detail.world)
          }

          this.characterSection(detail)
          this.eventSection(detail)

          Column().width('100%').height(120)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding')
      })

      this.bottomSummaryBar(detail)
    }
    .width('100%')
    .height('100%')
  }

  // ===== 地图视口 =====

  @Builder
  mapViewportSection(detail: WorldDetailUiModel, selectedLocationId: string): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (detail.locations.length === 0) {
          this.mapEmptyState(detail)
        } else if (this.graphLayout !== null) {
          Scroll() {
            this.graphCanvas(this.graphLayout!, detail, selectedLocationId)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1)
          .clip(true)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.world_map_bg'))
      .borderRadius($r('app.float.world_radius_card'))
      .borderWidth(1)
      .borderColor($r('app.color.world_border'))

      // 浮动地图工具栏
      Row() {
        WorldMapToolbar({
          onLayers: (): void => {},
          onFilter: (): void => {},
          onLocate: (): void => {
            this.selectedLocationId = '';
          },
          onCompass: (): void => {},
          onZoomIn: (): void => {},
          onZoomOut: (): void => {},
          onReset: (): void => {
            this.selectedLocationId = '';
          }
        })
          .width('100%')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8 })

      // FAB(添加角色,仅活跃世界)
      if (detail.world.status === WorldStatus.Active) {
        Stack({ alignContent: Alignment.Center }) {
          Button('+')
            .fontSize(28)
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .width($r('app.float.world_fab_size'))
            .height($r('app.float.world_fab_size'))
            .borderRadius(WorldMetrics.FAB_SIZE / 2)
            .shadow({ radius: 8, color: '#4DD4A843', offsetX: 0, offsetY: 4 })
            .accessibilityText($r('app.string.world_ui_fab_add_character_a11y'))
            .onClick(() => {
              this.openCharacterManage();
            })
        }
        .width($r('app.float.world_fab_size'))
        .height($r('app.float.world_fab_size'))
        .position({ x: '100%', y: '100%' })
        .markAnchor({
          x: WorldMetrics.FAB_SIZE + 16,
          y: WorldMetrics.FAB_SIZE + 16
        })
      }
    }
    .width('100%')
    .height(360)
    .clip(true)
    .borderRadius($r('app.float.world_radius_card'))
    .margin({ top: 4, bottom: 12 })
  }

  @Builder
  mapEmptyState(detail: WorldDetailUiModel): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_ui_map_empty_title'),
        description: $r('app.string.world_ui_map_empty_desc'),
        primaryLabel: detail.world.status === WorldStatus.Archived
          ? '' : $r('app.string.world_ui_map_empty_add_character'),
        secondaryLabel: detail.world.status === WorldStatus.Archived
          ? '' : $r('app.string.world_ui_map_empty_create_location'),
        onPrimary: (): void => {
          if (detail.world.status !== WorldStatus.Archived) {
            this.openCharacterManage();
          }
        },
        onSecondary: (): void => {
          if (detail.world.status !== WorldStatus.Archived) {
            this.openLocationCreate();
          }
        }
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  graphCanvas(
    layout: WorldLocationGraphLayout,
    detail: WorldDetailUiModel,
    selectedLocationId: string
  ): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(layout.edges, (edge: WorldLocationEdgeLayout) => {
          this.edgeView(edge)
        }, (edge: WorldLocationEdgeLayout) => edge.edgeId)
      }
      .width(layout.canvasWidth)
      .height(layout.canvasHeight)
      .hitTestBehavior(HitTestMode.Transparent)

      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(layout.nodes, (node: WorldLocationNodeLayout) => {
          this.nodeView(node, detail, selectedLocationId)
        }, (node: WorldLocationNodeLayout) => this.nodeKey(node, detail, selectedLocationId))
      }
      .width(layout.canvasWidth)
      .height(layout.canvasHeight)
    }
    .width(layout.canvasWidth)
    .height(layout.canvasHeight)
    .clip(true)
  }

  private nodeKey(
    node: WorldLocationNodeLayout,
    detail: WorldDetailUiModel,
    selectedLocationId: string
  ): string {
    const charCount: number = this.countCharactersAt(node.locationId, detail.characters);
    const selected: boolean = selectedLocationId === node.locationId;
    return node.locationId + '|' + charCount.toString() + '|' + (selected ? '1' : '0');
  }

  @Builder
  edgeView(edge: WorldLocationEdgeLayout): void {
    Polyline()
      .width(Math.abs(edge.toX - edge.fromX) + 4)
      .height(Math.abs(edge.toY - edge.fromY) + 4)
      .position({
        x: Math.min(edge.fromX, edge.toX) - 2,
        y: Math.min(edge.fromY, edge.toY) - 2
      })
      .points(this.computeEdgePoints(edge))
      .fillOpacity(0)
      .stroke(this.resolveEdgeColor(edge))
      .strokeWidth(1.5)
      .strokeLineJoin(LineJoinStyle.Round)
      .strokeLineCap(LineCapStyle.Round)
      .strokeDashArray(this.resolveEdgeDash(edge))
      .opacity(this.resolveEdgeOpacity(edge))

    Text(this.resolveEdgeDirectionLabel(edge))
      .fontSize(9)
      .fontColor($r('app.color.world_text_tertiary'))
      .backgroundColor($r('app.color.world_map_bg'))
      .borderRadius(3)
      .padding({ left: 3, right: 3, top: 1, bottom: 1 })
      .position({
        x: (edge.fromX + edge.toX) / 2 - 8,
        y: (edge.fromY + edge.toY) / 2 - 8
      })
  }

  @Builder
  nodeView(node: WorldLocationNodeLayout, detail: WorldDetailUiModel, selectedLocationId: string): void {
    Column() {
      WorldLocationNode({
        locationId: node.locationId,
        name: this.resolveLocationName(node.locationId, detail.locations),
        status: this.resolveLocationStatus(node.locationId, detail.locations),
        characterCount: this.countCharactersAt(node.locationId, detail.characters),
        outgoingEdgeCount: this.countOutgoingEdges(node.locationId, detail.edges),
        isSelected: selectedLocationId === node.locationId,
        onTap: (locationId: string): void => {
          this.onLocationTapped(locationId);
        }
      })
    }
    .width(node.width)
    .height(node.height)
    .position({ x: node.x, y: node.y })
    .onClick(() => {
      this.onLocationTapped(node.locationId);
    })
  }

  // ===== 选中地点详情 =====

  @Builder
  selectedLocationDetailSection(locationId: string, detail: WorldDetailUiModel): void {
    WorldSurfaceCard({
      elevated: true,
      onPress: (): void => {}
    }) {
      Column() {
        Row() {
          Text(this.resolveLocationName(locationId, detail.locations))
            .fontSize($r('app.float.world_font_title'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.world_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          WorldStatusChip({
            label: this.resolveLocationStatusLabel(locationId, detail.locations),
            isActive: this.resolveLocationStatus(locationId, detail.locations) === WorldLocationStatus.Active
          })

          if (detail.world.status !== WorldStatus.Archived) {
            Button($r('app.string.world_location_edit'))
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_gold'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius($r('app.float.world_radius_chip'))
              .height(30)
              .padding({ left: 10, right: 10 })
              .margin({ left: 8 })
              .accessibilityText($r('app.string.world_edit_location'))
              .onClick(() => {
                this.openLocationEdit(locationId);
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.resolveLocationDescription(locationId, detail.locations).length > 0) {
          Text(this.resolveLocationDescription(locationId, detail.locations))
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_text_secondary'))
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 8 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })

        Text($r('app.string.world_location_current_characters'))
          .fontSize($r('app.float.world_font_section'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ bottom: 6 })

        this.currentCharactersList(locationId, detail.characters)

        Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })

        Text($r('app.string.world_location_outgoing_edges'))
          .fontSize($r('app.float.world_font_section'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ bottom: 6 })

        this.edgeList(locationId, detail.edges, true)

        Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })

        Text($r('app.string.world_location_incoming_edges'))
          .fontSize($r('app.float.world_font_section'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ bottom: 6 })

        this.edgeList(locationId, detail.edges, false)
      }
      .width('100%')
      .padding({
        left: 14,
        right: 14,
        top: 14,
        bottom: 14
      })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  currentCharactersList(locationId: string, characters: WorldCharacterInstanceUiModel[]): void {
    if (this.filterCharactersAt(locationId, characters).length === 0) {
      Text($r('app.string.world_location_no_characters'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
    } else {
      Column() {
        ForEach(this.filterCharactersAt(locationId, characters), (c: WorldCharacterInstanceUiModel) => {
          Row() {
            CharacterImageView({
              imageUri: c.avatarUri,
              fallbackName: c.fallbackName,
              imgWidth: 32,
              imgHeight: 32,
              imgBorderRadius: 16,
              displayMode: 'thumbnail',
              objectFit: ImageFit.Cover
            })

            Column() {
              Text(c.displayName)
                .fontSize($r('app.float.world_font_body'))
                .fontColor($r('app.color.world_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              Row() {
                Text(c.isActive ? '活跃' : '已停用')
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(c.isActive
                    ? $r('app.color.world_gold')
                    : $r('app.color.world_text_tertiary'))
                  .backgroundColor($r('app.color.world_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })

                if (c.characterCardMissing) {
                  Text($r('app.string.world_character_card_missing'))
                    .fontSize($r('app.float.world_font_micro'))
                    .fontColor($r('app.color.world_error'))
                    .backgroundColor($r('app.color.world_surface_2'))
                    .borderRadius(3)
                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    .margin({ left: 4 })
                }
              }
              .margin({ top: 4 })
              .alignItems(VerticalAlign.Center)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })
        }, (c: WorldCharacterInstanceUiModel) => c.id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  edgeList(locationId: string, edges: WorldEdgeUiModel[], outgoing: boolean): void {
    if (this.filterEdgesForLocation(locationId, edges, outgoing).length === 0) {
      Text('无')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
    } else {
      Column() {
        ForEach(this.filterEdgesForLocation(locationId, edges, outgoing), (edge: WorldEdgeUiModel) => {
          this.edgeItemRow(edge, outgoing)
        }, (edge: WorldEdgeUiModel) => edge.id + '|' + (outgoing ? 'out' : 'in'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  edgeItemRow(edge: WorldEdgeUiModel, outgoing: boolean): void {
    Column() {
      Row() {
        Text(this.resolveEdgeTargetName(edge, outgoing))
          .fontSize($r('app.float.world_font_body'))
          .fontColor(edge.toLocationMissing || edge.fromLocationMissing
            ? $r('app.color.world_error')
            : $r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(edge.isBidirectional
          ? $r('app.string.world_edge_bidirectional')
          : $r('app.string.world_edge_unidirectional'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_gold'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 8 })

        if (!edge.isEnabled) {
          Text($r('app.string.world_edge_disabled'))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (edge.directionLabel.length > 0 || edge.travelDescription.length > 0) {
        Text(this.composeEdgeDescription(edge))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
          .width('100%')
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 世界描述 =====

  @Builder
  worldDescriptionSection(world: WorldSummaryUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        WorldSectionHeader({ title: $r('app.string.world_detail_overview_section') })

        Text(world.description)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_secondary'))
          .maxLines(8)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text('更新于 ' + formatWorldTimestamp(world.updatedAt))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ top: 8 })
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  // ===== 异常连接横幅 =====

  @Builder
  anomalousEdgeBanner(count: number): void {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(16)
        .fontColor([$r('app.color.world_error')])
      Text($r('app.string.world_detail_anomalous_edges') + ': ' + count.toString())
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_error'))
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({
      left: 14,
      right: 14,
      top: 10,
      bottom: 10
    })
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_card'))
    .borderWidth(1)
    .borderColor($r('app.color.world_error'))
    .margin({ bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 角色实例摘要 =====

  @Builder
  characterSection(detail: WorldDetailUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        WorldSectionHeader({ title: $r('app.string.world_detail_character_section') })

        if (detail.characters.length === 0) {
          Text($r('app.string.world_detail_no_characters'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 16, bottom: 16 })
        } else {
          this.characterSubSection(
            $r('app.string.world_detail_unplaced_characters'),
            this.filterUnplacedCharacters(detail.characters)
          )

          ForEach(this.collectPlacedLocationSummaries(detail), (summary: PlacedLocationSummary) => {
            this.placedLocationSummaryRow(summary)
          }, (summary: PlacedLocationSummary) => summary.locationId + '|' + String(summary.characterCount))
        }
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  characterSubSection(title: ResourceStr, characters: WorldCharacterInstanceUiModel[]): void {
    if (characters.length > 0) {
      Column() {
        Text(title)
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ top: 8, bottom: 4 })

        ForEach(characters, (c: WorldCharacterInstanceUiModel) => {
          this.characterRow(c)
        }, (c: WorldCharacterInstanceUiModel) => c.id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  placedLocationSummaryRow(summary: PlacedLocationSummary): void {
    Row() {
      SymbolGlyph($r('sys.symbol.circle'))
        .fontSize(14)
        .fontColor([$r('app.color.world_gold')])
      Text(summary.locationName + ' · ' + summary.characterCount.toString() + ' 角色')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ left: 6 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  characterRow(c: WorldCharacterInstanceUiModel): void {
    Row() {
      CharacterImageView({
        imageUri: c.avatarUri,
        fallbackName: c.fallbackName,
        imgWidth: 32,
        imgHeight: 32,
        imgBorderRadius: 16,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })

      Column() {
        Text(c.displayName)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(c.isActive ? '活跃' : '已停用')
            .fontSize($r('app.float.world_font_micro'))
            .fontColor(c.isActive
              ? $r('app.color.world_gold')
              : $r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })

          if (c.characterCardMissing) {
            Text($r('app.string.world_character_card_missing'))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_error'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 4 })
          }

          Text(this.resolveCharacterLocationLabel(c))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor(c.locationMissing
              ? $r('app.color.world_error')
              : $r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 6 })
  }

  // ===== 最近事件 =====

  @Builder
  eventSection(detail: WorldDetailUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        WorldSectionHeader({
          title: $r('app.string.world_detail_event_section'),
          subtitle: formatWorldTimestamp(detail.world.updatedAt)
        })

        if (detail.recentEvents.length === 0) {
          Text($r('app.string.world_detail_no_events'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 16, bottom: 16 })
        } else {
          ForEach(detail.recentEvents, (ev: WorldEventUiModel) => {
            this.eventRow(ev)
          }, (ev: WorldEventUiModel) => ev.id)
        }
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  eventRow(ev: WorldEventUiModel): void {
    Column() {
      Row() {
        Text(ev.localizedType)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_gold'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })

        Text(formatWorldTimestamp(ev.occurredAt))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ left: 8 })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (ev.summary.length > 0) {
        Text(ev.summary)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }
    }
    .width('100%')
    .margin({ top: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 底部摘要栏 =====

  @Builder
  bottomSummaryBar(detail: WorldDetailUiModel): void {
    Row() {
      this.summaryItem($r('app.string.world_ui_locations_label'), detail.world.locationCount)
      this.summaryItem($r('app.string.world_ui_characters_label'), detail.characters.length)
      this.summaryItem($r('app.string.world_edge_count_label'), detail.edgeCount)
      this.summaryItem($r('app.string.world_event_count_label'), detail.eventCount)
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

  // ===== 地点人物弹窗(W-UX-1) =====

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

  // ===== 事件处理 =====

  private onLocationTapped(locationId: string): void {
    if (this.currentWorldId.length === 0 || locationId.length === 0) {
      return;
    }
    this.openLocationSheet(this.currentWorldId, locationId);
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

  // ===== 辅助方法 =====

  private resolveWorldName(): string {
    if (this.detail !== null) {
      return this.detail.world.name.length > 0 ? this.detail.world.name : '(未命名世界)';
    }
    return '世界详情';
  }

  private computeEdgePoints(edge: WorldLocationEdgeLayout): number[][] {
    const polyLeft: number = Math.min(edge.fromX, edge.toX) - 2;
    const polyTop: number = Math.min(edge.fromY, edge.toY) - 2;
    const midY: number = (edge.fromY + edge.toY) / 2;
    return [
      [edge.fromX - polyLeft, edge.fromY - polyTop],
      [edge.fromX - polyLeft, midY - polyTop],
      [edge.toX - polyLeft, midY - polyTop],
      [edge.toX - polyLeft, edge.toY - polyTop]
    ];
  }

  private resolveEdgeColor(edge: WorldLocationEdgeLayout): ResourceColor {
    return $r('app.color.world_edge');
  }

  private resolveEdgeDash(edge: WorldLocationEdgeLayout): number[] {
    if (!edge.isEnabled) {
      return [4, 4];
    }
    return [];
  }

  private resolveEdgeOpacity(edge: WorldLocationEdgeLayout): number {
    if (!edge.isEnabled) {
      return 0.45;
    }
    return 0.85;
  }

  private resolveEdgeDirectionLabel(edge: WorldLocationEdgeLayout): string {
    return edge.isBidirectional ? '双向' : '单向';
  }

  private resolveLocationName(locationId: string, locations: WorldLocationUiModel[]): string {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return locations[i].name;
      }
    }
    return '(未知地点)';
  }

  private resolveLocationStatus(locationId: string, locations: WorldLocationUiModel[]): WorldLocationStatus {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return locations[i].status;
      }
    }
    return WorldLocationStatus.Active;
  }

  private resolveLocationDescription(locationId: string, locations: WorldLocationUiModel[]): string {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return locations[i].description;
      }
    }
    return '';
  }

  private resolveLocationStatusLabel(locationId: string, locations: WorldLocationUiModel[]): string {
    const status: WorldLocationStatus = this.resolveLocationStatus(locationId, locations);
    return status === WorldLocationStatus.Archived ? '已归档' : '活跃';
  }

  private countCharactersAt(locationId: string, characters: WorldCharacterInstanceUiModel[]): number {
    let count: number = 0;
    for (let i: number = 0; i < characters.length; i++) {
      if (characters[i].currentLocationId === locationId) {
        count = count + 1;
      }
    }
    return count;
  }

  private filterCharactersAt(locationId: string, characters: WorldCharacterInstanceUiModel[]): WorldCharacterInstanceUiModel[] {
    const result: WorldCharacterInstanceUiModel[] = [];
    for (let i: number = 0; i < characters.length; i++) {
      if (characters[i].currentLocationId === locationId) {
        result.push(characters[i]);
      }
    }
    return result;
  }

  private countOutgoingEdges(locationId: string, edges: WorldEdgeUiModel[]): number {
    let count: number = 0;
    for (let i: number = 0; i < edges.length; i++) {
      if (edges[i].isAnomalous) {
        continue;
      }
      if (edges[i].fromLocationId === locationId) {
        count = count + 1;
      }
    }
    return count;
  }

  private filterEdgesForLocation(locationId: string, edges: WorldEdgeUiModel[], outgoing: boolean): WorldEdgeUiModel[] {
    const result: WorldEdgeUiModel[] = [];
    for (let i: number = 0; i < edges.length; i++) {
      const e: WorldEdgeUiModel = edges[i];
      if (e.isAnomalous) {
        continue;
      }
      if (outgoing && e.fromLocationId === locationId) {
        result.push(e);
      } else if (!outgoing && e.toLocationId === locationId) {
        result.push(e);
      }
    }
    return result;
  }

  private resolveEdgeTargetName(edge: WorldEdgeUiModel, outgoing: boolean): string {
    if (outgoing) {
      if (edge.toLocationMissing) {
        return '连接目标缺失';
      }
      return edge.toLocationName.length > 0 ? edge.toLocationName : '(未知地点)';
    } else {
      if (edge.fromLocationMissing) {
        return '连接来源缺失';
      }
      return edge.fromLocationName.length > 0 ? edge.fromLocationName : '(未知地点)';
    }
  }

  private composeEdgeDescription(edge: WorldEdgeUiModel): string {
    const parts: string[] = [];
    if (edge.directionLabel.length > 0) {
      parts.push(edge.directionLabel);
    }
    if (edge.travelDescription.length > 0) {
      parts.push(edge.travelDescription);
    }
    return parts.join(' · ');
  }

  private resolveWorldStatusLabel(status: WorldStatus): string {
    return status === WorldStatus.Archived ? '已归档' : '活跃';
  }

  private resolveCharacterLocationLabel(c: WorldCharacterInstanceUiModel): string {
    if (c.currentLocationId.length === 0) {
      return '未放置';
    }
    if (c.locationMissing) {
      return '地点数据缺失';
    }
    return c.currentLocationName.length > 0 ? c.currentLocationName : '未知地点';
  }

  private filterUnplacedCharacters(characters: WorldCharacterInstanceUiModel[]): WorldCharacterInstanceUiModel[] {
    const result: WorldCharacterInstanceUiModel[] = [];
    for (let i: number = 0; i < characters.length; i++) {
      if (characters[i].currentLocationId.length === 0) {
        result.push(characters[i]);
      }
    }
    return result;
  }

  private collectPlacedLocationSummaries(detail: WorldDetailUiModel): PlacedLocationSummary[] {
    const map: Map<string, PlacedLocationSummary> = new Map<string, PlacedLocationSummary>();
    for (let i: number = 0; i < detail.characters.length; i++) {
      const c: WorldCharacterInstanceUiModel = detail.characters[i];
      if (c.currentLocationId.length === 0) {
        continue;
      }
      const locName: string = c.locationMissing
        ? '地点数据缺失'
        : (c.currentLocationName.length > 0 ? c.currentLocationName : '未知地点');
      const existing: PlacedLocationSummary | undefined = map.get(c.currentLocationId);
      if (existing !== undefined) {
        existing.characterCount = existing.characterCount + 1;
      } else {
        const summary: PlacedLocationSummary = {
          locationId: c.currentLocationId,
          locationName: locName,
          characterCount: 1
        };
        map.set(c.currentLocationId, summary);
      }
    }
    return Array.from(map.values());
  }
}

interface PlacedLocationSummary {
  locationId: string;
  locationName: string;
  characterCount: number;
}