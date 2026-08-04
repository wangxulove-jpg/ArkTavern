/**
 * WorldHomePage 世界列表页(W-UI-1)
 *
 * 世界模式正式入口页面。只读,本阶段不提供任何写操作。
 *
 * 职责:
 * - 通过 WorldHomeViewModel 加载真实世界列表
 * - 显示 Loading / Empty / Error / Ready 四种状态
 * - 每张卡片显示名称、状态标签、描述摘要、地点数 / 角色数、最近更新时间
 * - 点击卡片进入 WorldDetailPage(仅传 worldId)
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
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldHomePage';

@Entry
@Component
struct WorldHomePage {
  /** ViewModel(aboutToAppear 时创建) */
  @State private viewModel: WorldHomeViewModel | null = null;
  /** 是否正在初始化(AppServices 未就绪期间) */
  @State private isInitializing: boolean = true;
  /** 初始化错误(空字符串表示无错误) */
  @State private initError: string = '';
  /** 本地世界列表副本(@State 装饰数组,赋值新数组触发重渲染) */
  @State private worlds: WorldSummaryUiModel[] = [];
  /** 当前加载状态 */
  @State private state: WorldListState = WorldListState.Loading;
  /** 用户可见的安全错误消息 */
  @State private errorMessage: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

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

  /** 页面重新显示时刷新(从详情页返回) */
  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    await this.reload();
  }

  /** 页面销毁时标记 ViewModel disposed,拒绝迟到结果 */
  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  /** 幂等 reload,拒绝重复并发 */
  private async reload(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.reload();
    this.worlds = this.viewModel.worlds;
    this.state = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
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
      // 返回按钮
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

      // 标题 + 副标题
      Column() {
        Text($r('app.string.world_home_title'))
          .fontSize($r('app.float.app_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text($r('app.string.world_home_subtitle'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4 })

      // 创建世界按钮
      Button($r('app.string.world_create'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ right: 8 })
        .accessibilityText($r('app.string.world_create_world'))
        .onClick(() => {
          this.openWorldCreate();
        })

      // 刷新按钮
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .accessibilityText($r('app.string.world_reload_data'))
        .onClick(() => {
          this.reload();
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
    } else if (this.state === WorldListState.Loading) {
      this.loadingView();
    } else if (this.state === WorldListState.Error) {
      this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '世界数据加载失败,请重试');
    } else if (this.state === WorldListState.Empty || this.worlds.length === 0) {
      this.emptyView();
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
        .color($r('app.color.app_accent'))
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

      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .accessibilityText($r('app.string.world_reload_data'))
        .onClick(() => {
          this.reload();
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
      EmptyStateView({
        title: $r('app.string.world_home_empty_title'),
        description: $r('app.string.world_home_empty_desc')
      })

      Button($r('app.string.world_create'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .accessibilityText($r('app.string.world_create_world'))
        .onClick(() => {
          this.openWorldCreate();
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
      ForEach(this.worlds, (item: WorldSummaryUiModel) => {
        ListItem() {
          this.worldCard(item)
        }
        .margin({ bottom: $r('app.float.app_spacing_12') })
      }, (item: WorldSummaryUiModel) => item.id + '|' + String(item.updatedAt))

      // 末尾空白 ListItem,避免浮层 tab bar 遮挡最后一项
      ListItem() {
        Column().width('100%').height(160)
      }
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

  /** 单个世界卡片 */
  @Builder
  worldCard(item: WorldSummaryUiModel): void {
    PressableCard({
      onPress: (): void => {
        this.openWorldDetail(item.id);
      },
      surfaceColor: $r('app.color.app_surface_1')
    }) {
      Column() {
        // 第1行:名称 + 状态标签
        Row() {
          Text(item.name.length > 0 ? item.name : '(未命名世界)')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(this.resolveStatusLabel(item.status))
            .fontSize(11)
            .fontColor(item.status === WorldStatus.Active
              ? $r('app.color.app_accent')
              : $r('app.color.app_text_tertiary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 第2行:描述摘要(最多两行)
        if (item.description.length > 0) {
          Text(item.description)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        // 第3行:统计信息 + 时间
        Row() {
          Text(this.composeStatsLine(item))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(formatWorldTimestamp(item.updatedAt))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .margin({ left: 8 })
        }
        .width('100%')
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
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 打开世界详情(只传 worldId) */
  private openWorldDetail(worldId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, worldId);
    router.pushUrl({ url: 'pages/world/WorldDetailPage' });
  }

  /** 打开世界创建页(worldId 为空表示创建模式) */
  private openWorldCreate(): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, '');
    router.pushUrl({ url: 'pages/world/WorldEditPage' });
  }

  /** 解析状态标签文字 */
  private resolveStatusLabel(status: WorldStatus): string {
    if (status === WorldStatus.Archived) {
      return '已归档';
    }
    return '活跃';
  }

  /** 组合统计行:地点 N · 角色 N */
  private composeStatsLine(item: WorldSummaryUiModel): string {
    return item.locationCount.toString() + ' 地点 · '
      + item.characterCount.toString() + ' 角色';
  }
}
