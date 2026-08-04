/**
 * WorldEdgeManagePage 世界地点连接管理页(W-CONTROL-1B)
 *
 * 职责:
 * - 列出当前世界的全部连接(已解析端点名称)
 * - 创建连接入口(进入 WorldEdgeEditPage)
 * - 编辑连接入口(进入 WorldEdgeEditPage,异常连接禁止编辑)
 * - 启用 / 停用连接
 * - 删除连接(二次确认)
 * - 异常连接安全降级展示,允许删除
 *
 * 路由:通过 AppStorage PENDING_WORLD_ID_KEY 传 worldId
 * 写入全部调用 WorldStateService。
 *
 * 归档世界:仍可只读查看,创建/编辑/启停/删除按钮禁用。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldEdgeManageViewModel,
  WorldEdgeManageLoadState,
  WorldEdgeManageItemUiModel,
  WorldEdgeManageSnapshotUiModel
} from '../../viewmodels/world/WorldEdgeManageViewModel';
import {
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_EDGE_ID_KEY,
  PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { World, WorldStatus } from '../../models/world/World';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldEdgeManagePage';

@Entry
@Component
struct WorldEdgeManagePage {
  @State private viewModel: WorldEdgeManageViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldEdgeManageLoadState = WorldEdgeManageLoadState.Loading;
  @State private errorMessage: string = '';
  @State private edges: WorldEdgeManageItemUiModel[] = [];
  @State private snapshot: WorldEdgeManageSnapshotUiModel | null = null;
  @State private isSaving: boolean = false;
  @State private isDeleting: boolean = false;
  @State private worldStatus: WorldStatus = WorldStatus.Active;
  /** 待删除的 edgeId(非空时显示确认弹窗) */
  @State private deletingEdgeId: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId empty');
        this.isInitializing = false;
        this.loadState = WorldEdgeManageLoadState.NotFound;
        return;
      }
      // 只读加载 World 状态(用于判断归档)
      const worldRepo: WorldRepository = AppServices.getWorldRepository();
      const world: World | null = await worldRepo.getById(worldId);
      if (world === null) {
        this.isInitializing = false;
        this.loadState = WorldEdgeManageLoadState.NotFound;
        return;
      }
      this.worldStatus = world.status;

      this.viewModel = new WorldEdgeManageViewModel(
        AppServices.getWorldStateService(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldLocationEdgeRepository(),
        worldId
      );
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldEdgeManageLoadState.Error;
      this.errorMessage = '连接数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
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
    await this.viewModel.loadSnapshot();
    this.syncFromViewModel();
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.loadState;
    this.errorMessage = this.viewModel.errorMessage;
    this.edges = this.viewModel.edges;
    this.snapshot = this.viewModel.snapshot;
    this.isSaving = this.viewModel.isSaving;
    this.isDeleting = this.viewModel.isDeleting;
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

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_cancel'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText($r('app.string.world_back_to_list'))
        .onClick(() => {
          router.back();
        })

      Text($r('app.string.world_edge_manage_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 创建连接(归档世界禁用)
      Button($r('app.string.world_edge_create'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.worldStatus === WorldStatus.Archived
          ? $r('app.color.app_text_tertiary')
          : $r('app.color.app_on_accent'))
        .backgroundColor(this.worldStatus === WorldStatus.Archived
          ? $r('app.color.app_surface_2')
          : $r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 12, right: 12 })
        .enabled(this.worldStatus !== WorldStatus.Archived)
        .accessibilityText($r('app.string.world_create_edge'))
        .onClick(() => {
          this.openEdgeCreate();
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

  @Builder
  contentArea(): void {
    if (this.isInitializing || this.loadState === WorldEdgeManageLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldEdgeManageLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldEdgeManageLoadState.Error) {
      this.errorView();
    } else {
      this.contentView();
    }
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
      EmptyStateView({ title: $r('app.string.world_detail_not_found'), description: '' })
      Button($r('app.string.world_back_to_list'))
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
  errorView(): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.world_home_load_failed'),
        description: this.errorMessage.length > 0 ? this.errorMessage : '连接数据加载失败,请重试'
      })
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
    Scroll() {
      Column() {
        // 错误提示
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_12'),
              right: $r('app.float.app_spacing_12'),
              top: $r('app.float.app_spacing_8'),
              bottom: $r('app.float.app_spacing_8')
            })
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_sm'))
            .margin({ bottom: $r('app.float.app_spacing_12') })
        }

        // 概览 + 创建按钮
        if (this.snapshot !== null) {
          this.overviewSection(this.snapshot!)
        }

        // 异常连接横幅
        if (this.snapshot !== null && this.snapshot!.anomalousEdgeCount > 0) {
          this.anomalousBanner(this.snapshot!.anomalousEdgeCount)
        }

        // 连接列表
        this.edgeListSection()

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

    // 删除确认弹窗
    if (this.deletingEdgeId.length > 0) {
      this.deleteConfirmDialog();
    }
  }

  @Builder
  overviewSection(snapshot: WorldEdgeManageSnapshotUiModel): void {
    Column() {
      Row() {
        this.overviewItem($r('app.string.world_location_count_label'), snapshot.locationCount)
        this.overviewItem($r('app.string.world_edge_count_label'), snapshot.edgeCount)
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
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

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

  @Builder
  anomalousBanner(count: number): void {
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

  @Builder
  edgeListSection(): void {
    Column() {
      Text($r('app.string.world_edge_count_label'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      if (this.edges.length === 0) {
        Text($r('app.string.world_edge_no_edges'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        ForEach(this.edges, (edge: WorldEdgeManageItemUiModel) => {
          this.edgeCard(edge)
        }, (edge: WorldEdgeManageItemUiModel) => edge.id)
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

  @Builder
  edgeCard(edge: WorldEdgeManageItemUiModel): void {
    Column() {
      // 第1行:起点 → 终点 + 方向标签
      Row() {
        Text(this.resolveFromLabel(edge))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(edge.fromLocationMissing
            ? $r('app.color.app_danger')
            : $r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(edge.isBidirectional ? ' ↔ ' : ' → ')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_tertiary'))

        Text(this.resolveToLabel(edge))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(edge.toLocationMissing
            ? $r('app.color.app_danger')
            : $r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第2行:状态标签(单向/双向 + 启用/停用 + 异常)
      Row() {
        Text(edge.isBidirectional
          ? $r('app.string.world_edge_bidirectional')
          : $r('app.string.world_edge_unidirectional'))
          .fontSize(10)
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })

        if (!edge.isEnabled) {
          Text($r('app.string.world_edge_disabled'))
            .fontSize(10)
            .fontColor($r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }

        if (edge.isAnomalous) {
          Text($r('app.string.world_edge_anomalous'))
            .fontSize(10)
            .fontColor($r('app.color.app_danger'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }
      }
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      // 第3行:方向 + 旅行描述
      if (edge.directionLabel.length > 0 || edge.travelDescription.length > 0) {
        Text(this.composeDescription(edge))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }

      // 操作按钮
      Row() {
        // 编辑(异常连接禁用)
        Button($r('app.string.world_edge_edit'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor(edge.isAnomalous || this.worldStatus === WorldStatus.Archived
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_accent'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 10, right: 10 })
          .enabled(!edge.isAnomalous
            && this.worldStatus !== WorldStatus.Archived
            && !this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_edit_edge'))
          .onClick(() => {
            this.openEdgeEdit(edge.id);
          })

        // 启用 / 停用
        if (edge.isEnabled) {
          Button($r('app.string.world_edge_disable'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor(this.worldStatus === WorldStatus.Archived
              ? $r('app.color.app_text_tertiary')
              : $r('app.color.app_text_secondary'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .margin({ left: 8 })
            .enabled(this.worldStatus !== WorldStatus.Archived
              && !this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_disable_edge'))
            .onClick(() => {
              this.handleSetEdgeEnabled(edge.id, false);
            })
        } else {
          Button($r('app.string.world_edge_enable'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor(this.worldStatus === WorldStatus.Archived
              ? $r('app.color.app_text_tertiary')
              : $r('app.color.app_accent'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .margin({ left: 8 })
            .enabled(this.worldStatus !== WorldStatus.Archived
              && !this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_enable_edge'))
            .onClick(() => {
              this.handleSetEdgeEnabled(edge.id, true);
            })
        }

        // 删除(危险操作,归档世界也禁用)
        Button($r('app.string.world_edge_delete'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor(this.worldStatus === WorldStatus.Archived
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_danger'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 10, right: 10 })
          .margin({ left: 8 })
          .enabled(this.worldStatus !== WorldStatus.Archived
            && !this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_delete_edge'))
          .onClick(() => {
            this.deletingEdgeId = edge.id;
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  deleteConfirmDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_edge_delete'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 12 })

        Text($r('app.string.world_edge_delete_confirm'))
          .fontSize(14)
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ bottom: 20 })

        Row() {
          Button($r('app.string.world_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              this.deletingEdgeId = '';
            })

          Button($r('app.string.world_edge_delete'))
            .fontSize(14)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .enabled(!this.isDeleting)
            .onClick(() => {
              const edgeId: string = this.deletingEdgeId;
              this.deletingEdgeId = '';
              this.handleDeleteEdge(edgeId);
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.deletingEdgeId = '';
    })
  }

  /** 解析起点标签 */
  private resolveFromLabel(edge: WorldEdgeManageItemUiModel): string {
    if (edge.fromLocationMissing) {
      return '起点地点缺失';
    }
    if (edge.isSelfLoop) {
      return '异常自连接';
    }
    return edge.fromLocationName.length > 0 ? edge.fromLocationName : '(未知地点)';
  }

  /** 解析终点标签 */
  private resolveToLabel(edge: WorldEdgeManageItemUiModel): string {
    if (edge.toLocationMissing) {
      return '终点地点缺失';
    }
    if (edge.isSelfLoop) {
      return '异常自连接';
    }
    return edge.toLocationName.length > 0 ? edge.toLocationName : '(未知地点)';
  }

  /** 组合方向 + 旅行描述 */
  private composeDescription(edge: WorldEdgeManageItemUiModel): string {
    const parts: string[] = [];
    if (edge.directionLabel.length > 0) {
      parts.push(edge.directionLabel);
    }
    if (edge.travelDescription.length > 0) {
      parts.push(edge.travelDescription);
    }
    return parts.join(' · ');
  }

  /** 打开创建连接页 */
  private openEdgeCreate(): void {
    if (this.viewModel === null) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_EDGE_ID_KEY, '');
    AppStorage.setOrCreate<string>(PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY, '');
    router.pushUrl({ url: 'pages/world/WorldEdgeEditPage' });
  }

  /** 打开编辑连接页 */
  private openEdgeEdit(edgeId: string): void {
    if (this.viewModel === null || edgeId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_EDGE_ID_KEY, edgeId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY, '');
    router.pushUrl({ url: 'pages/world/WorldEdgeEditPage' });
  }

  /** 启用 / 停用连接 */
  private async handleSetEdgeEnabled(edgeId: string, enabled: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearError();
    await this.viewModel.setEdgeEnabled(edgeId, enabled);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  /** 删除连接 */
  private async handleDeleteEdge(edgeId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearError();
    await this.viewModel.deleteEdge(edgeId);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  /** 递增刷新令牌,通知 WorldDetailPage 重新加载 */
  private triggerWorldDetailRefresh(): void {
    const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
  }
}
