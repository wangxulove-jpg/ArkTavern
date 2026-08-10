/**
 * WorldHomePage 世界列表页(W-UI-1A 重构)
 *
 * 世界模式正式入口页面。只读,本阶段不提供任何写操作。
 *
 * 重构 W-UI-1A:深色奇幻酒馆质感视觉,搜索栏、筛选标签、
 * 重新设计的卡片(含封面区、状态标签、统计行)。
 *
 * 职责:
 * - 通过 WorldHomeViewModel 加载真实世界列表
 * - 显示 Loading / Empty / Error / Ready 四种状态
 * - 搜索栏过滤世界名称,筛选标签(全部/进行中/已归档)
 * - 每张卡片显示名称、状态标签、描述摘要、地点数 / 角色数、最近更新时间
 * - 点击卡片进入 WorldDetailPage(仅传 worldId)
 * - 底部操作栏提供创建世界入口
 *
 * 生命周期:
 * - aboutToAppear:等待 AppServices 就绪后创建 ViewModel 并首次加载
 * - onPageShow:页面重新显示时调用幂等 reload()(从详情页返回时刷新)
 * - aboutToDisappear:标记 ViewModel.dispose() 拒绝迟到结果
 *
 * 路由:
 * - 进入 WorldDetailPage 通过 AppStorage.setOrCreate(PENDING_WORLD_ID_KEY, worldId)
 * - 不传完整 World 对象 / Repository / ViewModel
 *
 * 不依赖:
 * - WorldStateService 写方法
 * - 直接 Repository 调用
 * - 调试按钮 / 种子数据 / 预览数据
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { WorldHomeViewModel } from '../../viewmodels/world/WorldHomeViewModel';
import {
  WorldSummaryUiModel,
  WorldListState,
  PENDING_WORLD_ID_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import { WorldStatus } from '../../models/world/World';
import { Logger } from '../../utils/Logger';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG: string = 'WorldHomePage';

type WorldFilter = 'all' | 'active' | 'archived';

@Entry
@Component
struct WorldHomePage {
  @State private viewModel: WorldHomeViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private initError: string = '';
  @State private worlds: WorldSummaryUiModel[] = [];
  @State private state: WorldListState = WorldListState.Loading;
  @State private errorMessage: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  @State private searchText: string = '';
  @State private currentFilter: WorldFilter = 'all';
  @State private filteredWorlds: WorldSummaryUiModel[] = [];

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      this.viewModel = new WorldHomeViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldCharacterInstanceRepository()
      );
      this.isInitializing = false;
      await this.reload();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.initError = '世界数据加载失败,请重试';
      this.state = WorldListState.Error;
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    await this.reload();
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  private async reload(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.reload();
    this.worlds = this.viewModel.worlds;
    this.state = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.updateFilteredWorlds();
  }

  private updateFilteredWorlds(): void {
    let result: WorldSummaryUiModel[] = this.worlds;
    if (this.currentFilter === 'active') {
      result = result.filter((w: WorldSummaryUiModel): boolean => w.status === WorldStatus.Active);
    } else if (this.currentFilter === 'archived') {
      result = result.filter((w: WorldSummaryUiModel): boolean => w.status === WorldStatus.Archived);
    }
    if (this.searchText.length > 0) {
      const q: string = this.searchText;
      result = result.filter((w: WorldSummaryUiModel): boolean => w.name.includes(q));
    }
    this.filteredWorlds = result;
  }

  build(): void {
    Column() {
      this.headerArea();
      this.contentArea();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  headerArea(): void {
    Column() {
      Row() {
        // 返回按钮
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
          .padding(4)
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.world_home_title'))
          .fontSize($r('app.float.nav_title_font_size'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 4 })

        // AI创建世界(右上角)
        Button($r('app.string.world_ai_create'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor('#8B5CF6')
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 16, right: 16 })
          .margin({ right: 8 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/world/WorldAICreatePage' });
          })

        // 创建世界(右上角)
        Button($r('app.string.world_create'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 16, right: 16 })
          .accessibilityText($r('app.string.world_create'))
          .onClick(() => {
            this.openWorldCreate();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding')
      })

      // 搜索栏
      Row() {
        TextInput({
          text: this.searchText,
          placeholder: $r('app.string.world_ui_search_placeholder')
        })
          .fontSize($r('app.float.world_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.worldSurfaceColor(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(40)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchText = value;
            this.updateFilteredWorlds();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: $r('app.float.world_card_spacing'),
        bottom: $r('app.float.world_card_spacing')
      })
      .alignItems(VerticalAlign.Center)

      // 筛选标签
      Row() {
        this.filterTab($r('app.string.world_ui_filter_all'), 'all')
        this.filterTab($r('app.string.world_ui_filter_active'), 'active')
        this.filterTab($r('app.string.world_ui_filter_archived'), 'archived')
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        bottom: $r('app.float.world_card_spacing')
      })
      .alignItems(VerticalAlign.Center)
    }
    .padding({ top: this.statusBarHeight })
  }

  @Builder
  filterTab(label: ResourceStr, filter: WorldFilter): void {
    Text(label)
      .fontSize($r('app.float.world_font_caption'))
      .fontColor(this.currentFilter === filter
        ? (this.effectiveTheme === 'tavern' ? '#1A1510' : $r('app.color.app_on_accent'))
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(this.currentFilter === filter
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.worldSurfaceColor(this.effectiveTheme))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .margin({ right: 8 })
      .onClick(() => {
        this.currentFilter = filter;
        this.updateFilteredWorlds();
      })
  }

  @Builder
  contentArea(): void {
    if (this.isInitializing) {
      this.loadingView();
    } else if (this.initError.length > 0) {
      this.errorView(this.initError);
    } else if (this.state === WorldListState.Loading) {
      this.loadingView();
    } else if (this.state === WorldListState.Error) {
      this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '世界数据加载失败,请重试');
    } else if (this.state === WorldListState.Empty || this.worlds.length === 0) {
      this.emptyView();
    } else if (this.filteredWorlds.length === 0) {
      this.noResultsView();
    } else {
      this.listView();
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
  errorView(message: string): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_home_load_failed'),
        description: message,
        primaryLabel: $r('app.string.world_home_reload'),
        onPrimary: (): void => {
          this.reload();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyView(): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_home_empty_title'),
        description: $r('app.string.world_home_empty_desc'),
        primaryLabel: $r('app.string.world_create'),
        onPrimary: (): void => {
          this.openWorldCreate();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  noResultsView(): void {
    Column() {
      WorldEmptyState({
        title: '没有匹配的世界',
        description: '尝试调整搜索关键词或筛选条件'
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  listView(): void {
    List() {
      ForEach(this.filteredWorlds, (item: WorldSummaryUiModel) => {
        ListItem() {
          this.worldCard(item)
        }
        .margin({ bottom: $r('app.float.world_card_spacing') })
      }, (item: WorldSummaryUiModel) => item.id + '|' + String(item.updatedAt))

      ListItem() {
        Column().width('100%').height(100)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding')
    })
  }

  @Builder
  worldCard(item: WorldSummaryUiModel): void {
    WorldSurfaceCard({
      onPress: (): void => {
        this.openWorldDetail(item.id);
      }
    }) {
      Column() {
        Row() {
          Text(item.name.length > 0 ? item.name : '(未命名世界)')
            .fontSize($r('app.float.world_font_title'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          WorldStatusChip({
            label: this.resolveStatusLabel(item.status),
            isActive: item.status === WorldStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (item.description.length > 0) {
          Text(item.description)
            .fontSize($r('app.float.world_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 8 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        Row() {
          Text(this.composeStatsLine(item))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(formatWorldTimestamp(item.updatedAt))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ left: 8 })
        }
        .width('100%')
        .margin({ top: 10 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: 14,
        bottom: 14
      })
      .alignItems(HorizontalAlign.Start)
    }
  }

  private openWorldDetail(worldId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, worldId);
    router.pushUrl({ url: 'pages/world/WorldDetailPage' });
  }

  private openWorldCreate(): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, '');
    router.pushUrl({ url: 'pages/world/WorldEditPage' });
  }

  private resolveStatusLabel(status: WorldStatus): string {
    if (status === WorldStatus.Archived) {
      return '已归档';
    }
    return '活跃';
  }

  private composeStatsLine(item: WorldSummaryUiModel): string {
    return item.locationCount.toString() + ' 地点 · '
      + item.characterCount.toString() + ' 角色';
  }
}