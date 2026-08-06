/**
 * WorldSceneManagePage 历史会话页(W-UI-1C 重构)
 *
 * 重构:深色酒馆质感,场景扁平列表(不再按地点分组),
 * 搜索 + 筛选(全部/活动中/已结束),历史会话卡片,
 * 新建会话入口(选择地点),Active 场景可继续/查看,Ended 场景只读。
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
  HistorySceneCardUiModel,
  StartSceneResult
} from '../../viewmodels/world/WorldSceneManageViewModel';
import {
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_SCENE_ID_KEY,
  PENDING_WORLD_SCENE_CHAT_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import { World, WorldStatus } from '../../models/world/World';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneManagePage';

type HistoryFilter = 'all' | 'active' | 'ended';

@Entry
@Component
struct WorldSceneManagePage {
  @State private viewModel: WorldSceneManageViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldSceneManageLoadState = WorldSceneManageLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldSceneManageUiModel | null = null;
  @State private worldStatus: WorldStatus = WorldStatus.Active;
  @State private actionError: string = '';

  @State private searchText: string = '';
  @State private currentFilter: HistoryFilter = 'all';
  @State private filteredScenes: HistorySceneCardUiModel[] = [];

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
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
      AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, worldId);

      this.viewModel = new WorldSceneManageViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneMessageRepository(),
        AppServices.getWorldSceneService()
      );
      this.viewModel.setWorldId(worldId);
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldSceneManageLoadState.Error;
      this.errorMessage = '历史会话数据加载失败';
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
    this.updateFilteredScenes();
  }

  private updateFilteredScenes(): void {
    if (this.detail === null) {
      this.filteredScenes = [];
      return;
    }
    let scenes: HistorySceneCardUiModel[] = this.detail.scenes;
    if (this.searchText.length > 0) {
      const q: string = this.searchText;
      scenes = scenes.filter((s: HistorySceneCardUiModel): boolean =>
        s.sceneName.includes(q) || s.locationName.includes(q));
    }
    if (this.currentFilter === 'active') {
      scenes = scenes.filter((s: HistorySceneCardUiModel): boolean =>
        s.sceneStatus === WorldSceneStatus.Active);
    } else if (this.currentFilter === 'ended') {
      scenes = scenes.filter((s: HistorySceneCardUiModel): boolean =>
        s.sceneStatus === WorldSceneStatus.Ended);
    }
    this.filteredScenes = scenes;
  }

  build(): void {
    Column() {
      this.topNav()
      this.searchAndFilterArea()
      this.contentArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  topNav(): void {
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

      Text($r('app.string.world_scene_history_title'))
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })

      if (this.worldStatus === WorldStatus.Active) {
        Button($r('app.string.world_scene_history_new_scene'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_on_gold'))
          .backgroundColor($r('app.color.world_gold'))
          .borderRadius($r('app.float.world_radius_button'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            router.back();
          })
      }
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
  searchAndFilterArea(): void {
    Column() {
      Row() {
        TextInput({
          text: this.searchText,
          placeholder: $r('app.string.world_scene_history_search_placeholder')
        })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_1'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(40)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchText = value;
            this.updateFilteredScenes();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: $r('app.float.world_card_spacing'),
        bottom: $r('app.float.world_card_spacing')
      })

      Row() {
        this.filterTab($r('app.string.world_scene_history_filter_all'), 'all')
        this.filterTab($r('app.string.world_scene_history_filter_active'), 'active')
        this.filterTab($r('app.string.world_scene_history_filter_ended'), 'ended')
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        bottom: $r('app.float.world_card_spacing')
      })
    }
  }

  @Builder
  filterTab(label: ResourceStr, filter: HistoryFilter): void {
    Text(label)
      .fontSize($r('app.float.world_font_caption'))
      .fontColor(this.currentFilter === filter
        ? $r('app.color.world_on_gold')
        : $r('app.color.world_text_secondary'))
      .backgroundColor(this.currentFilter === filter
        ? $r('app.color.world_gold')
        : $r('app.color.world_surface_1'))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .margin({ right: 8 })
      .onClick(() => {
        this.currentFilter = filter;
        this.updateFilteredScenes();
      })
  }

  @Builder
  contentArea(): void {
    if (this.isInitializing || this.loadState === WorldSceneManageLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldSceneManageLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldSceneManageLoadState.Error) {
      this.errorView();
    } else if (this.loadState === WorldSceneManageLoadState.Ready && this.detail !== null) {
      this.contentView();
    }
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
  errorView(): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_home_load_failed'),
        description: this.errorMessage.length > 0 ? this.errorMessage : '',
        primaryLabel: $r('app.string.world_home_reload'),
        onPrimary: (): void => {
          this.loadSnapshot();
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
    if (this.actionError.length > 0) {
      Text(this.actionError)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_error'))
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.world_surface_1'))
        .borderRadius($r('app.float.world_radius_chip'))
        .margin({
          left: $r('app.float.world_page_padding'),
          right: $r('app.float.world_page_padding'),
          bottom: 8
        })
    }

    if (this.filteredScenes.length === 0) {
      Column() {
        WorldEmptyState({
          title: $r('app.string.world_scene_history_no_scenes'),
          primaryLabel: this.worldStatus === WorldStatus.Active
            ? $r('app.string.world_scene_history_new_scene') : '',
          onPrimary: (): void => {
            if (this.worldStatus === WorldStatus.Active) {
              router.back();
            }
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      Scroll() {
        Column() {
          ForEach(this.filteredScenes, (sc: HistorySceneCardUiModel) => {
            this.sceneHistoryCard(sc)
          }, (sc: HistorySceneCardUiModel) => sc.sceneId + '|' + sc.messageCount.toString())

          Column().width('100%').height(120)
        }
        .width('100%')
        .padding({
          left: $r('app.float.world_page_padding'),
          right: $r('app.float.world_page_padding')
        })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  sceneHistoryCard(sc: HistorySceneCardUiModel): void {
    WorldSurfaceCard({ elevated: sc.sceneStatus === WorldSceneStatus.Active }) {
      Column() {
        // 第1行:场景名称 + 状态标签
        Row() {
          Text(sc.locationName)
            .fontSize($r('app.float.world_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.world_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          WorldStatusChip({
            label: sc.sceneStatus === WorldSceneStatus.Active ? '活动中' : '已结束',
            isActive: sc.sceneStatus === WorldSceneStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 第2行:时间信息
        Column() {
          Text('开始: ' + formatWorldTimestamp(sc.startedAt))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .width('100%')

          if (sc.endedAt > 0) {
            Text('结束: ' + formatWorldTimestamp(sc.endedAt))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .width('100%')
              .margin({ top: 2 })
          }

          if (sc.lastMessageTime > 0) {
            Text('最近消息: ' + formatWorldTimestamp(sc.lastMessageTime))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .width('100%')
              .margin({ top: 2 })
          }
        }
        .margin({ top: 6 })
        .alignItems(HorizontalAlign.Start)

        Divider().color($r('app.color.world_border')).margin({ top: 8, bottom: 8 })

        // 第3行:统计信息
        Row() {
          Text(sc.messageCount.toString() + ' 条消息')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_secondary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })

          Text($r('app.string.world_scene_history_card_no_summary'))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 第4行:操作入口
        Row() {
          if (sc.sceneStatus === WorldSceneStatus.Active) {
            WorldPrimaryButton({
              label: $r('app.string.world_scene_history_card_continue'),
              onButtonClick: (): void => {
                this.openSceneChat(sc.sceneId);
              }
            })
            WorldSecondaryButton({
              label: $r('app.string.world_scene_history_card_view_record'),
              onButtonClick: (): void => {
                this.openSceneDetail(sc.sceneId);
              }
            })
              .margin({ left: 8 })
          } else {
            WorldSecondaryButton({
              label: $r('app.string.world_scene_history_card_view_record'),
              onButtonClick: (): void => {
                this.openSceneDetail(sc.sceneId);
              }
            })
            WorldPrimaryButton({
              label: $r('app.string.world_scene_history_card_create_from'),
              isEnabled: this.worldStatus === WorldStatus.Active,
              onButtonClick: (): void => {
                this.createNewFromEnded(sc);
              }
            })
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .margin({ top: 10 })
        .alignItems(VerticalAlign.Center)
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  private openSceneChat(sceneId: string): void {
    if (sceneId.length === 0 || this.viewModel === null) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_SCENE_CHAT_ID_KEY, sceneId);
    router.pushUrl({ url: 'pages/world/WorldSceneChatPage' });
  }

  private openSceneDetail(sceneId: string): void {
    if (sceneId.length === 0 || this.viewModel === null) {
      return;
    }
    const worldId: string = this.viewModel.expectedWorldIdOfPage();
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_SCENE_ID_KEY, sceneId);
    router.pushUrl({ url: 'pages/world/WorldSceneDetailPage' });
  }

  private async createNewFromEnded(sc: HistorySceneCardUiModel): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.actionError = '';
    const result: StartSceneResult = await this.viewModel.startScene(sc.locationId);
    if (result.success) {
      this.openSceneChat(result.sceneId);
    } else {
      this.actionError = result.errorMessage;
    }
    this.syncFromViewModel();
  }
}