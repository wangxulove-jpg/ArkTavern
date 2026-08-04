/**
 * WorldDetailPage 世界详情页(W-UI-1)
 *
 * 只读展示一个世界的完整信息,包含:
 * - 世界头部:名称 / 状态 / 描述
 * - 数据概览:地点 / 连接 / 角色 / 事件 数量
 * - 异常连接提示
 * - 地点节点关系图(确定性布局,Polyline + 节点组件)
 * - 地点只读详情(选中节点后展示)
 * - 角色实例摘要(已放置 + 未放置)
 * - 最近事件(本地化类型 + 摘要 + 时间)
 *
 * 生命周期保护:
 * - aboutToAppear:读取 PENDING_WORLD_ID_KEY,创建 ViewModel 并 loadSnapshot
 * - onPageShow:页面重新显示时调用幂等 reload(同世界)
 * - aboutToDisappear:dispose,拒绝迟到结果
 * - loadOperationId + expectedWorldId 防止快速切换时旧请求覆盖新请求
 *
 * 路由:
 * - 仅通过 AppStorage 读取 PENDING_WORLD_ID_KEY
 * - 不接收完整 World 对象 / Repository / ViewModel
 *
 * 不依赖:
 * - WorldStateService 写方法
 * - 直接 Repository 调用
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
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import {
  WorldLocationGraphLayout,
  WorldLocationNodeLayout,
  WorldLocationEdgeLayout,
  computeWorldLocationGraphLayout
} from '../../viewmodels/world/WorldLocationGraphLayout';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldLocationNode } from '../../components/world/WorldLocationNode';
import { EmptyStateView } from '../../components/EmptyStateView';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldDetailPage';

@Entry
@Component
struct WorldDetailPage {
  /** ViewModel */
  @State private viewModel: WorldDetailViewModel | null = null;
  /** 当前页面绑定的 worldId */
  @State private currentWorldId: string = '';
  /** 是否正在初始化 */
  @State private isInitializing: boolean = true;
  /** 初始化错误 */
  @State private initError: string = '';
  /** 加载状态 */
  @State private state: WorldDetailLoadState = WorldDetailLoadState.Loading;
  /** 安全错误消息 */
  @State private errorMessage: string = '';
  /** 详情 UI 模型 */
  @State private detail: WorldDetailUiModel | null = null;
  /** 图布局(Ready 时计算) */
  @State private graphLayout: WorldLocationGraphLayout | null = null;
  /** 当前选中的地点 ID */
  @State private selectedLocationId: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      // 从 AppStorage 读取 worldId(由 WorldHomePage 写入)
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: pendingWorldId empty');
        this.isInitializing = false;
        this.state = WorldDetailLoadState.NotFound;
        return;
      }
      // 读取后立即清除,避免下次进入复用旧 ID
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
      this.isInitializing = false;
      await this.loadDetail(worldId);
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.initError = '世界数据加载失败,请重试';
      this.state = WorldDetailLoadState.Error;
    }
  }

  /** 页面重新显示时:如果已有 worldId,幂等重新加载(同世界) */
  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    if (this.currentWorldId.length === 0) {
      return;
    }
    await this.loadDetail(this.currentWorldId);
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  /** 加载世界详情快照 */
  private async loadDetail(worldId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    // 切换世界时清除选中态,避免显示前一个世界的选中
    if (this.currentWorldId !== worldId) {
      this.selectedLocationId = '';
      this.currentWorldId = worldId;
    }
    await this.viewModel.loadSnapshot(worldId);
    this.state = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
    // Ready 时计算图布局
    if (this.state === WorldDetailLoadState.Ready && this.detail !== null) {
      this.graphLayout = computeWorldLocationGraphLayout(
        this.detail.locations,
        this.detail.edges
      );
      // 如果之前选中的地点不在新数据中,清除选中
      if (this.selectedLocationId.length > 0
        && !this.containsLocation(this.detail.locations, this.selectedLocationId)) {
        this.selectedLocationId = '';
      }
    } else {
      this.graphLayout = null;
      this.selectedLocationId = '';
    }
  }

  /** 判断地点列表中是否包含指定 ID */
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
      this.headerArea();
      this.contentArea();
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 顶部标题区 */
  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_home_back'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText($r('app.string.world_back_to_list'))
        .onClick(() => {
          router.back();
        })

      Text($r('app.string.world_detail_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .accessibilityText($r('app.string.world_reload_data'))
        .onClick(() => {
          if (this.currentWorldId.length > 0) {
            this.loadDetail(this.currentWorldId);
          }
        })
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

  /** 内容区:按状态切换 */
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
      this.detailView(this.detail!)
    }
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.app_accent'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.world_detail_not_found'),
        description: ''
      })

      Button($r('app.string.world_back_to_list'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          router.back();
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
      EmptyStateView({
        title: $r('app.string.world_home_load_failed'),
        description: message
      })

      Row() {
        Button($r('app.string.world_back_to_list'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .padding({ left: 20, right: 20 })
          .onClick(() => {
            router.back();
          })

        Button($r('app.string.world_home_reload'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .padding({ left: 20, right: 20 })
          .margin({ left: 12 })
          .onClick(() => {
            if (this.currentWorldId.length > 0) {
              this.loadDetail(this.currentWorldId);
            }
          })
      }
      .margin({ top: $r('app.float.app_spacing_16') })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 详情主体:可滚动 */
  @Builder
  detailView(detail: WorldDetailUiModel): void {
    Scroll() {
      Column() {
        // 1. 世界头部
        this.worldHeaderSection(detail.world)

        // 2. 数据概览
        this.overviewSection(detail)

        // 3. 异常连接提示
        if (detail.anomalousEdgeCount > 0) {
          this.anomalousEdgeBanner(detail.anomalousEdgeCount)
        }

        // 4. 地点关系图
        this.graphSection(detail)

        // 5. 选中地点详情
        if (this.selectedLocationId.length > 0) {
          this.selectedLocationDetailSection(detail)
        }

        // 6. 角色实例摘要
        this.characterSection(detail)

        // 7. 最近事件
        this.eventSection(detail)

        // 末尾空白
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
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 0,
      bottom: 0
    })
  }

  /** 世界头部 */
  @Builder
  worldHeaderSection(world: WorldSummaryUiModel): void {
    Column() {
      // 第1行:名称 + 状态标签
      Row() {
        Text(world.name.length > 0 ? world.name : '(未命名世界)')
          .fontSize($r('app.float.app_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.resolveWorldStatusLabel(world.status))
          .fontSize(11)
          .fontColor(world.status === WorldStatus.Active
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 描述
      if (world.description.length > 0) {
        Text(world.description)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      // 更新时间
      Text('更新于 ' + formatWorldTimestamp(world.updatedAt))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 8 })

      // 管理操作按钮行(归档世界禁用子数据写入,但管理世界按钮始终可用)
      Row() {
        // 管理世界:始终允许(可编辑/归档/激活/硬删除)
        Button($r('app.string.world_manage'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .accessibilityText($r('app.string.world_edit_world'))
          .onClick(() => {
            this.openWorldEdit();
          })

        // 添加地点:归档世界禁用
        Button($r('app.string.world_add_location'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(world.status === WorldStatus.Archived
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText($r('app.string.world_add_location'))
          .enabled(world.status !== WorldStatus.Archived)
          .onClick(() => {
            this.openLocationCreate();
          })

        // 管理角色:归档世界禁用
        Button($r('app.string.world_character_manage'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(world.status === WorldStatus.Archived
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText($r('app.string.world_manage_characters'))
          .enabled(world.status !== WorldStatus.Archived)
          .onClick(() => {
            this.openCharacterManage();
          })
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 数据概览 */
  @Builder
  overviewSection(detail: WorldDetailUiModel): void {
    Column() {
      Text($r('app.string.world_detail_overview_section'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 8 })

      Row() {
        this.overviewItem($r('app.string.world_location_count_label'), detail.world.locationCount)
        this.overviewItem($r('app.string.world_edge_count_label'), detail.edgeCount)
        this.overviewItem($r('app.string.world_character_count_label'), detail.characters.length)
        this.overviewItem($r('app.string.world_event_count_label'), detail.eventCount)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 单个概览项(垂直:数字 + 标签) */
  @Builder
  overviewItem(label: ResourceStr, count: number): void {
    Column() {
      Text(count.toString())
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
  }

  /** 异常连接横幅 */
  @Builder
  anomalousEdgeBanner(count: number): void {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(16)
        .fontColor([$r('app.color.app_danger')])
      Text($r('app.string.world_detail_anomalous_edges') + ': ' + count.toString())
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_danger'))
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(VerticalAlign.Center)
  }

  /** 地点关系图区域 */
  @Builder
  graphSection(detail: WorldDetailUiModel): void {
    Column() {
      // 标题
      Row() {
        Text($r('app.string.world_detail_graph_section'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .layoutWeight(1)

        // 提示
        if (detail.locations.length > 0 && this.selectedLocationId.length === 0) {
          Text($r('app.string.world_graph_select_hint'))
            .fontSize(11)
            .fontColor($r('app.color.app_text_tertiary'))
        }
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (detail.locations.length === 0) {
        // 无地点
        Text($r('app.string.world_detail_no_locations'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_24'),
            bottom: $r('app.float.app_spacing_24')
          })
      } else if (this.graphLayout !== null) {
        // 图渲染
        this.graphCanvas(this.graphLayout!, detail)
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 图画布:Stack 内部按坐标布局
   * - 底层:边(Polyline + 方向标签)
   * - 上层:节点(WorldLocationNode)
   *
   * 使用 Stack 容器 + position 绝对定位实现稳定坐标。
   * 不使用 Canvas,避免当前 SDK 兼容问题。
   */
  @Builder
  graphCanvas(layout: WorldLocationGraphLayout, detail: WorldDetailUiModel): void {
    Stack({ alignContent: Alignment.TopStart }) {
      // ===== 边层 =====
      ForEach(layout.edges, (edge: WorldLocationEdgeLayout) => {
        this.edgeView(edge, layout.canvasWidth, layout.canvasHeight)
      }, (edge: WorldLocationEdgeLayout) => edge.edgeId)

      // ===== 节点层 =====
      ForEach(layout.nodes, (node: WorldLocationNodeLayout) => {
        this.nodeView(node, detail)
      }, (node: WorldLocationNodeLayout) => node.locationId)
    }
    .width(layout.canvasWidth)
    .height(layout.canvasHeight)
    .clip(false)
  }

  /**
   * 单条边渲染:Polyline 折线 + 方向标签。
   * 外层 Stack 尺寸与画布一致,子元素用 position 绝对定位,
   * 这样多个 edgeView 的 Stack 在 graphCanvas 中叠加对齐。
   */
  @Builder
  edgeView(edge: WorldLocationEdgeLayout, canvasWidth: number, canvasHeight: number): void {
    Stack({ alignContent: Alignment.TopStart }) {
      // 折线:从 (fromX, fromY) → 中间 → (toX, toY)
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

      // 方向标签:中点附近显示"单"/"双"小标签
      Text(this.resolveEdgeDirectionLabel(edge))
        .fontSize(9)
        .fontColor($r('app.color.app_text_tertiary'))
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius(3)
        .padding({ left: 3, right: 3, top: 1, bottom: 1 })
        .position({
          x: (edge.fromX + edge.toX) / 2 - 8,
          y: (edge.fromY + edge.toY) / 2 - 8
        })
    }
    .width(canvasWidth)
    .height(canvasHeight)
  }

  /** 单个节点渲染:用 WorldLocationNode 组件 + position 定位 */
  @Builder
  nodeView(node: WorldLocationNodeLayout, detail: WorldDetailUiModel): void {
    Column() {
      WorldLocationNode({
        locationId: node.locationId,
        name: this.resolveLocationName(node.locationId, detail.locations),
        status: this.resolveLocationStatus(node.locationId, detail.locations),
        characterCount: this.countCharactersAt(node.locationId, detail.characters),
        outgoingEdgeCount: this.countOutgoingEdges(node.locationId, detail.edges),
        isSelected: this.selectedLocationId === node.locationId,
        onTap: (locationId: string): void => {
          this.onLocationTapped(locationId);
        }
      })
    }
    .width(node.width)
    .height(node.height)
    .position({ x: node.x, y: node.y })
  }

  /** 选中地点详情 */
  @Builder
  selectedLocationDetailSection(detail: WorldDetailUiModel): void {
    Column() {
      // 标题 + 编辑按钮
      Row() {
        Text(this.resolveLocationName(this.selectedLocationId, detail.locations))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 编辑地点:归档世界禁用
        Button($r('app.string.world_location_edit'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(detail.world.status === WorldStatus.Archived
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText($r('app.string.world_edit_location'))
          .enabled(detail.world.status !== WorldStatus.Archived)
          .onClick(() => {
            this.openLocationEdit(this.selectedLocationId);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 状态标签
      Text(this.resolveLocationStatusLabel(this.selectedLocationId, detail.locations))
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius(4)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .margin({ top: 6 })

      // 描述
      if (this.resolveLocationDescription(this.selectedLocationId, detail.locations).length > 0) {
        Text(this.resolveLocationDescription(this.selectedLocationId, detail.locations))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Divider().color($r('app.color.app_divider')).margin({ top: 12, bottom: 12 })

      // 当前角色
      Text($r('app.string.world_location_current_characters'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 6 })

      this.currentCharactersList(this.selectedLocationId, detail.characters)

      Divider().color($r('app.color.app_divider')).margin({ top: 12, bottom: 12 })

      // 出发连接
      Text($r('app.string.world_location_outgoing_edges'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 6 })

      this.edgeList(this.selectedLocationId, detail, true)

      Divider().color($r('app.color.app_divider')).margin({ top: 12, bottom: 12 })

      // 到达连接
      Text($r('app.string.world_location_incoming_edges'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 6 })

      this.edgeList(this.selectedLocationId, detail, false)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 当前角色列表 */
  @Builder
  currentCharactersList(locationId: string, characters: WorldCharacterInstanceUiModel[]): void {
    if (this.filterCharactersAt(locationId, characters).length === 0) {
      Text($r('app.string.world_location_no_characters'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
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
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              // 角色状态标签
              Row() {
                Text(c.isActive ? '活跃' : '已停用')
                  .fontSize(10)
                  .fontColor(c.isActive
                    ? $r('app.color.app_accent')
                    : $r('app.color.app_text_tertiary'))
                  .backgroundColor($r('app.color.app_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })

                if (c.characterCardMissing) {
                  Text($r('app.string.world_character_card_missing'))
                    .fontSize(10)
                    .fontColor($r('app.color.app_danger'))
                    .backgroundColor($r('app.color.app_surface_2'))
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

  /** 连接列表(outgoing=true 出发,false 到达) */
  @Builder
  edgeList(locationId: string, detail: WorldDetailUiModel, outgoing: boolean): void {
    if (this.filterEdgesForLocation(locationId, detail.edges, outgoing).length === 0) {
      Text('无')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
    } else {
      Column() {
        ForEach(this.filterEdgesForLocation(locationId, detail.edges, outgoing), (edge: WorldEdgeUiModel) => {
          this.edgeItemRow(edge, outgoing)
        }, (edge: WorldEdgeUiModel) => edge.id + '|' + (outgoing ? 'out' : 'in'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 单个连接行 */
  @Builder
  edgeItemRow(edge: WorldEdgeUiModel, outgoing: boolean): void {
    Column() {
      Row() {
        // 目标地点名(出边显示 to,入边显示 from)
        Text(this.resolveEdgeTargetName(edge, outgoing))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(edge.toLocationMissing || edge.fromLocationMissing
            ? $r('app.color.app_danger')
            : $r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 单/双 标签
        Text(edge.isBidirectional
          ? $r('app.string.world_edge_bidirectional')
          : $r('app.string.world_edge_unidirectional'))
          .fontSize(10)
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 8 })

        // 启用/停用
        if (!edge.isEnabled) {
          Text($r('app.string.world_edge_disabled'))
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 方向 + 旅行描述
      if (edge.directionLabel.length > 0 || edge.travelDescription.length > 0) {
        Text(this.composeEdgeDescription(edge))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
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

  /** 角色实例摘要(已放置 + 未放置) */
  @Builder
  characterSection(detail: WorldDetailUiModel): void {
    Column() {
      Text($r('app.string.world_detail_character_section'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 8 })

      if (detail.characters.length === 0) {
        Text($r('app.string.world_detail_no_characters'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        // 未放置角色分组
        this.characterSubSection(
          $r('app.string.world_detail_unplaced_characters'),
          this.filterUnplacedCharacters(detail.characters)
        )

        // 已放置角色分组(仅显示数量与位置摘要)
        ForEach(this.collectPlacedLocationSummaries(detail), (summary: PlacedLocationSummary) => {
          this.placedLocationSummaryRow(summary)
        }, (summary: PlacedLocationSummary) => summary.locationId + '|' + String(summary.characterCount))
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 角色子分组 */
  @Builder
  characterSubSection(title: ResourceStr, characters: WorldCharacterInstanceUiModel[]): void {
    if (characters.length > 0) {
      Column() {
        Text(title)
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 8, bottom: 4 })

        ForEach(characters, (c: WorldCharacterInstanceUiModel) => {
          this.characterRow(c)
        }, (c: WorldCharacterInstanceUiModel) => c.id)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 已放置角色按地点摘要行 */
  @Builder
  placedLocationSummaryRow(summary: PlacedLocationSummary): void {
    Row() {
      SymbolGlyph($r('sys.symbol.circle'))
        .fontSize(14)
        .fontColor([$r('app.color.app_accent')])
      Text(summary.locationName + ' · ' + summary.characterCount.toString() + ' 角色')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ left: 6 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /** 单个角色行 */
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
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(c.isActive ? '活跃' : '已停用')
            .fontSize(10)
            .fontColor(c.isActive
              ? $r('app.color.app_accent')
              : $r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })

          if (c.characterCardMissing) {
            Text($r('app.string.world_character_card_missing'))
              .fontSize(10)
              .fontColor($r('app.color.app_danger'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 4 })
          }

          // 位置信息
          Text(this.resolveCharacterLocationLabel(c))
            .fontSize(10)
            .fontColor(c.locationMissing
              ? $r('app.color.app_danger')
              : $r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
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

  /** 最近事件 */
  @Builder
  eventSection(detail: WorldDetailUiModel): void {
    Column() {
      Text($r('app.string.world_detail_event_section'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 8 })

      if (detail.recentEvents.length === 0) {
        Text($r('app.string.world_detail_no_events'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        ForEach(detail.recentEvents, (ev: WorldEventUiModel) => {
          this.eventRow(ev)
        }, (ev: WorldEventUiModel) => ev.id)
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 单个事件行 */
  @Builder
  eventRow(ev: WorldEventUiModel): void {
    Column() {
      Row() {
        Text(ev.localizedType)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })

        Text(formatWorldTimestamp(ev.occurredAt))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (ev.summary.length > 0) {
        Text(ev.summary)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
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

  // ===== 事件处理 =====

  /** 节点点击:切换选中 */
  private onLocationTapped(locationId: string): void {
    if (this.selectedLocationId === locationId) {
      this.selectedLocationId = '';
    } else {
      this.selectedLocationId = locationId;
    }
  }

  /** 打开世界编辑页(编辑当前世界) */
  private openWorldEdit(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldEditPage' });
  }

  /** 打开地点编辑页(创建模式) */
  private openLocationCreate(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_LOCATION_ID_KEY, '');
    router.pushUrl({ url: 'pages/world/WorldLocationEditPage' });
  }

  /** 打开地点编辑页(编辑模式) */
  private openLocationEdit(locationId: string): void {
    if (this.currentWorldId.length === 0 || locationId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_LOCATION_ID_KEY, locationId);
    router.pushUrl({ url: 'pages/world/WorldLocationEditPage' });
  }

  /** 打开世界角色管理页 */
  private openCharacterManage(): void {
    if (this.currentWorldId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    router.pushUrl({ url: 'pages/world/WorldCharacterManagePage' });
  }

  // ===== 辅助方法 =====

  /** 计算边折线点(Polyline 用相对坐标) */
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

  /** 边颜色:停用边用次文字色,启用边用次文字色 */
  private resolveEdgeColor(edge: WorldLocationEdgeLayout): ResourceColor {
    return $r('app.color.app_text_secondary');
  }

  /** 边虚线:停用边虚线 */
  private resolveEdgeDash(edge: WorldLocationEdgeLayout): number[] {
    if (!edge.isEnabled) {
      return [4, 4];
    }
    return [];
  }

  /** 边透明度:停用边弱化 */
  private resolveEdgeOpacity(edge: WorldLocationEdgeLayout): number {
    if (!edge.isEnabled) {
      return 0.45;
    }
    return 0.85;
  }

  /** 边方向标签:单/双 */
  private resolveEdgeDirectionLabel(edge: WorldLocationEdgeLayout): string {
    return edge.isBidirectional ? '双向' : '单向';
  }

  /** 解析地点名称 */
  private resolveLocationName(locationId: string, locations: WorldLocationUiModel[]): string {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return locations[i].name;
      }
    }
    return '(未知地点)';
  }

  /** 解析地点状态 */
  private resolveLocationStatus(locationId: string, locations: WorldLocationUiModel[]): WorldLocationStatus {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return locations[i].status;
      }
    }
    return WorldLocationStatus.Active;
  }

  /** 解析地点描述 */
  private resolveLocationDescription(locationId: string, locations: WorldLocationUiModel[]): string {
    for (let i: number = 0; i < locations.length; i++) {
      if (locations[i].id === locationId) {
        return locations[i].description;
      }
    }
    return '';
  }

  /** 解析地点状态标签文字 */
  private resolveLocationStatusLabel(locationId: string, locations: WorldLocationUiModel[]): string {
    const status: WorldLocationStatus = this.resolveLocationStatus(locationId, locations);
    return status === WorldLocationStatus.Archived ? '已归档' : '活跃';
  }

  /** 计算某地点的角色数量 */
  private countCharactersAt(locationId: string, characters: WorldCharacterInstanceUiModel[]): number {
    let count: number = 0;
    for (let i: number = 0; i < characters.length; i++) {
      if (characters[i].currentLocationId === locationId) {
        count = count + 1;
      }
    }
    return count;
  }

  /** 筛选某地点的角色 */
  private filterCharactersAt(locationId: string, characters: WorldCharacterInstanceUiModel[]): WorldCharacterInstanceUiModel[] {
    const result: WorldCharacterInstanceUiModel[] = [];
    for (let i: number = 0; i < characters.length; i++) {
      if (characters[i].currentLocationId === locationId) {
        result.push(characters[i]);
      }
    }
    return result;
  }

  /** 计算从某地点出发的连接数 */
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

  /** 筛选某地点的连接(outgoing=true 出发,false 到达) */
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

  /** 解析连接目标名称(出边显示 to,入边显示 from) */
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

  /** 组合连接描述(方向 + 旅行描述) */
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

  /** 解析世界状态标签 */
  private resolveWorldStatusLabel(status: WorldStatus): string {
    return status === WorldStatus.Archived ? '已归档' : '活跃';
  }

  /** 解析角色位置标签 */
  private resolveCharacterLocationLabel(c: WorldCharacterInstanceUiModel): string {
    if (c.currentLocationId.length === 0) {
      return '未放置';
    }
    if (c.locationMissing) {
      return '地点数据缺失';
    }
    return c.currentLocationName.length > 0 ? c.currentLocationName : '未知地点';
  }

  /** 筛选未放置角色 */
  private filterUnplacedCharacters(characters: WorldCharacterInstanceUiModel[]): WorldCharacterInstanceUiModel[] {
    const result: WorldCharacterInstanceUiModel[] = [];
    for (let i: number = 0; i < characters.length; i++) {
      if (characters[i].currentLocationId.length === 0) {
        result.push(characters[i]);
      }
    }
    return result;
  }

  /** 收集已放置角色的按地点摘要 */
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

/** 已放置角色按地点汇总 */
interface PlacedLocationSummary {
  locationId: string;
  locationName: string;
  characterCount: number;
}
