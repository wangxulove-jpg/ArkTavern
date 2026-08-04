/**
 * WorldSceneManagePage 世界场景管理页(W-SCENE-1B)
 *
 * 职责:
 * - 显示世界名称
 * - 列出全部地点
 * - 每个地点显示:Active Scene / 已结束场景数量 / 开始场景按钮 / 查看 Active Scene 入口
 * - Archived World 只读
 * - Archived Location 不能开始场景
 * - 已有 Active Scene 的地点不能再次开始
 *
 * 路由:通过 AppStorage PENDING_WORLD_ID_KEY 传 worldId
 * 写入调用 WorldSceneService.startScene。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldSceneManageViewModel,
  WorldSceneManageLoadState,
  WorldSceneManageUiModel,
  LocationSceneUiModel
} from '../../viewmodels/world/WorldSceneManageViewModel';
import {
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_SCENE_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { World, WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneManagePage';

@Entry
@Component
struct WorldSceneManagePage {
  @State private viewModel: WorldSceneManageViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldSceneManageLoadState = WorldSceneManageLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldSceneManageUiModel | null = null;
  @State private worldStatus: WorldStatus = WorldStatus.Active;
  /** 错误提示(开始场景失败等) */
  @State private actionError: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp(WORLD_DETAIL_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  refreshToken: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId empty');
        this.isInitializing = false;
        this.loadState = WorldSceneManageLoadState.NotFound;
        return;
      }
      const worldRepo = AppServices.getWorldRepository();
      const world: World | null = await worldRepo.getById(worldId);
      if (world === null) {
        this.isInitializing = false;
        this.loadState = WorldSceneManageLoadState.NotFound;
        return;
      }
      this.worldStatus = world.status;

      this.viewModel = new WorldSceneManageViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneService()
      );
      this.viewModel.setWorldId(worldId);
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldSceneManageLoadState.Error;
      this.errorMessage = '场景数据加载失败,请重试';
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
    await this.viewModel.loadSnapshot(this.viewModel.expectedWorldIdOfPage());
    this.syncFromViewModel();
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
  }

  private async startScene(locationId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.actionError = '';
    const result = await this.viewModel.startScene(locationId);
    if (!result.success) {
      this.actionError = result.errorMessage;
      return;
    }
    this.syncFromViewModel();
  }

  private openSceneDetail(sceneId: string): void {
    if (sceneId.length === 0) {
      return;
    }
    if (this.viewModel === null) {
      return;
    }
    const worldId: string = this.viewModel.expectedWorldIdOfPage();
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_SCENE_ID_KEY, sceneId);
    router.pushUrl({ url: 'pages/world/WorldSceneDetailPage' });
  }

  build(): void {
    Column() {
      this.headerArea();
      if (this.isInitializing) {
        this.loadingView();
      } else if (this.loadState === WorldSceneManageLoadState.Loading) {
        this.loadingView();
      } else if (this.loadState === WorldSceneManageLoadState.NotFound) {
        this.notFoundView();
      } else if (this.loadState === WorldSceneManageLoadState.Error) {
        this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '场景数据加载失败,请重试');
      } else if (this.loadState === WorldSceneManageLoadState.Ready && this.detail !== null) {
        this.contentView(this.detail)
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
      Button($r('app.string.world_home_back'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .onClick(() => {
          router.back();
        })

      Text($r('app.string.world_scene_manage_title'))
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
        .onClick(() => {
          this.loadSnapshot();
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
            this.loadSnapshot();
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

  @Builder
  contentView(detail: WorldSceneManageUiModel): void {
    Scroll() {
      Column() {
        // 世界头部
        this.worldHeaderSection(detail)
        // 操作错误提示
        if (this.actionError.length > 0) {
          this.actionErrorBanner(this.actionError)
        }
        // 地点列表
        if (detail.locations.length === 0) {
          this.emptyLocationsView()
        } else {
          ForEach(detail.locations, (loc: LocationSceneUiModel) => {
            this.locationSceneCard(loc, detail.worldStatus)
          }, (loc: LocationSceneUiModel) => loc.locationId + '|' + (loc.activeScene !== null ? loc.activeScene.id : '') + '|' + loc.endedSceneCount.toString())
        }
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

  @Builder
  worldHeaderSection(detail: WorldSceneManageUiModel): void {
    Column() {
      Row() {
        Text(detail.worldName.length > 0 ? detail.worldName : '(未命名世界)')
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(detail.worldStatus === WorldStatus.Active ? '活跃' : '已归档')
          .fontSize(11)
          .fontColor(detail.worldStatus === WorldStatus.Active
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      Text($r('app.string.world_scene_manage_subtitle'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 6 })
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
  actionErrorBanner(message: string): void {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(16)
        .fontColor([$r('app.color.app_danger')])
      Text(message)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_danger'))
        .margin({ left: 8 })
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .fontColor($r('app.color.app_text_tertiary'))
        .backgroundColor(Color.Transparent)
        .height(24)
        .width(24)
        .padding(0)
        .onClick(() => {
          this.actionError = '';
        })
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
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  emptyLocationsView(): void {
    Column() {
      Text($r('app.string.world_detail_no_locations'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({
          top: $r('app.float.app_spacing_24'),
          bottom: $r('app.float.app_spacing_24')
        })
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
  }

  @Builder
  locationSceneCard(loc: LocationSceneUiModel, worldStatus: WorldStatus): void {
    Column() {
      // 第1行:地点名称 + 状态标签
      Row() {
        Text(loc.locationName.length > 0 ? loc.locationName : '(未命名地点)')
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(loc.locationStatus === WorldLocationStatus.Active ? '活跃' : '已归档')
          .fontSize(11)
          .fontColor(loc.locationStatus === WorldLocationStatus.Active
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第2行:场景状态
      if (loc.activeScene !== null) {
        Row() {
          Circle({ width: 8, height: 8 })
            .fill($r('app.color.app_accent'))
          Text($r('app.string.world_scene_active_label'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .margin({ left: 6 })
          Text(this.formatStartedAt(loc.activeScene.startedAt))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
      } else {
        Text($r('app.string.world_scene_no_active_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 8 })
      }

      // 第3行:已结束场景数量
      if (loc.endedSceneCount > 0) {
        Text(this.formatEndedCount(loc.endedSceneCount))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }

      // 操作按钮行
      Row() {
        // 查看 Active Scene
        if (loc.activeScene !== null) {
          Button($r('app.string.world_scene_view_active'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.openSceneDetail(loc.activeScene!.id);
            })
        }
        // 开始场景(条件:World Active + Location Active + 无 Active Scene)
        if (loc.activeScene === null) {
          Button($r('app.string.world_scene_start'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.canStartScene(worldStatus, loc) ? $r('app.color.app_on_accent') : $r('app.color.app_text_tertiary'))
            .backgroundColor(this.canStartScene(worldStatus, loc) ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 12, right: 12 })
            .enabled(this.canStartScene(worldStatus, loc) && this.viewModel !== null && !this.viewModel.isStarting)
            .onClick(() => {
              this.startScene(loc.locationId);
            })
        }
      }
      .width('100%')
      .margin({ top: 10 })
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

  private canStartScene(worldStatus: WorldStatus, loc: LocationSceneUiModel): boolean {
    if (worldStatus !== WorldStatus.Active) {
      return false;
    }
    if (loc.locationStatus !== WorldLocationStatus.Active) {
      return false;
    }
    return loc.activeScene === null;
  }

  private formatStartedAt(ts: number): string {
    if (!Number.isFinite(ts) || ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return '开始于 ' + month + '-' + day + ' ' + hour + ':' + minute;
  }

  private formatEndedCount(count: number): string {
    return '已结束场景:' + count.toString();
  }
}
