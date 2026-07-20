/**
 * MarketPage 市场 Tab 内容视图
 *
 * 替换原 MarketPlaceholderView,作为 HdsTabs 第三个 Tab 的内容。
 *
 * 结构:
 * - 顶部标题栏:标题"角色市场"
 * - 搜索框(防抖 350ms)
 * - 排序切换(推荐 / 最新 / 热门)+ 翻译开关
 * - 筛选切换(显示成人 / 隐藏已导入)
 * - 内容区:
 *   - 加载中:LoadingProgress
 *   - 加载失败:EmptyStateView + 重试按钮
 *   - 空状态:EmptyStateView
 *   - 列表:Grid 双列 + 下拉刷新 + 滚动到底部加载更多
 * - NSFW 二次确认弹窗
 * - 翻译隐私提示弹窗(首次开启翻译时)
 *
 * 本地化:
 * - 所有 UI 文案通过 $r('app.string.market_*') 资源引用
 * - 不使用 String($r(...)) / 资源字符串拼接 / as string
 *
 * 不直接:
 * - 调用 network / Provider
 * - 操作 Preferences
 * - 持久化数据
 */

import { AppServices } from '../../services/AppServices';
import { MarketViewModel } from '../../viewmodels/MarketViewModel';
import { MarketSort } from '../../models/MarketQuery';
import { MarketCharacter, marketCharacterKey } from '../../models/MarketCharacter';
import { MarketCharacterCard, MarketCardClickParams } from '../../components/MarketCharacterCard';
import { EmptyStateView } from '../../components/EmptyStateView';
import { router } from '@kit.ArkUI';

@Component
export struct MarketPage {
  @State viewModel: MarketViewModel | null = null;
  @State isInitializing: boolean = true;
  /** 下拉刷新状态(绑定到 Refresh 组件) */
  @State refreshing: boolean = false;
  /** NSFW 弹窗显示状态(ViewModel 触发后由本组件渲染) */
  @State showNsfwConfirm: boolean = false;
  /** 翻译隐私弹窗显示状态 */
  @State showTranslatePrivacy: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 跨页面刷新信号:导入成功后递增,触发列表刷新 */
  @StorageProp('marketListVersion') @Watch('onMarketListVersionChange') marketListVersion: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const translationService = AppServices.getMarketTranslationService();
      const vm: MarketViewModel = new MarketViewModel(
        AppServices.getMarketService(),
        translationService
      );
      this.viewModel = vm;
      await vm.load();
      this.isInitializing = false;
      this.syncDialogState();
    } catch (e) {
      this.isInitializing = false;
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  /**
   * marketListVersion 变化时刷新列表(从详情页导入成功后自动刷新)。
   */
  private onMarketListVersionChange(): void {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.refresh().catch((): void => {});
  }

  /**
   * 同步 ViewModel 弹窗状态到本组件 @State(触发 UI 重渲染)。
   */
  private syncDialogState(): void {
    if (this.viewModel === null) {
      return;
    }
    this.showNsfwConfirm = this.viewModel.showNsfwConfirm;
    this.showTranslatePrivacy = this.viewModel.showTranslatePrivacy;
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题栏 =====
        this.headerBar()

        // ===== 搜索框 =====
        this.searchBar()

        // ===== 排序 + 筛选 =====
        this.filterBar()

        // ===== 错误提示 =====
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          this.errorBanner()
        }

        // ===== 主内容区 =====
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.viewModel === null) {
          this.errorView($r('app.string.market_init_failed'), $r('app.string.market_not_initialized'))
        } else {
          this.marketContent()
        }
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // ===== NSFW 确认弹窗 =====
      if (this.showNsfwConfirm) {
        this.nsfwConfirmDialog()
      }

      // ===== 翻译隐私提示弹窗 =====
      if (this.showTranslatePrivacy) {
        this.translatePrivacyDialog()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  // ===== 顶部标题栏 =====

  @Builder
  headerBar(): void {
    Row() {
      Text($r('app.string.market_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()

      // 来源标识(第一版固定 chub)
      Text('Chub')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 搜索框 =====

  @Builder
  searchBar(): void {
    Row() {
      // 搜索图标
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([$r('app.color.app_text_tertiary')])
        .margin({ right: 8 })

      TextInput({
        placeholder: $r('app.string.market_search_placeholder'),
        text: this.viewModel !== null ? this.viewModel!.searchInput : ''
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor(Color.Transparent)
        .layoutWeight(1)
        .padding(0)
        .onChange((value: string) => {
          if (this.viewModel !== null) {
            this.viewModel!.onSearchInput(value);
          }
        })
        .onSubmit(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.submitSearch();
          }
        })

      // 清空按钮
      if (this.viewModel !== null && this.viewModel!.searchInput.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(16)
            .fontColor([$r('app.color.app_text_tertiary')])
        }
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .margin({ left: 4 })
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.clearSearch();
          }
        })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 排序 + 筛选条 =====

  @Builder
  filterBar(): void {
    Column() {
      // 第一行:排序 + 翻译开关
      Row() {
        this.sortChip($r('app.string.market_sort_recommended'), MarketSort.Recommended)
        this.sortChip($r('app.string.market_sort_latest'), MarketSort.Latest)
        this.sortChip($r('app.string.market_sort_top'), MarketSort.Top)

        Blank()

        // 翻译开关
        this.translateChip()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第二行:NSFW + 仅中文 + 隐藏已导入
      Row() {
        this.nsfwChip()
        this.chineseOnlyChip()
        this.hideImportedChip()

        Blank()
      }
      .width('100%')
      .margin({ top: $r('app.float.app_spacing_4') })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_4')
    })
  }

  @Builder
  sortChip(label: ResourceStr, sort: MarketSort): void {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(this.isSortActive(sort) ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
      .backgroundColor(this.isSortActive(sort) ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick(() => {
        if (this.viewModel !== null) {
          void this.viewModel!.setSort(sort);
        }
      })
  }

  @Builder
  translateChip(): void {
    Row() {
      Text($r('app.string.market_translate_toggle'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.isTranslateEnabled() ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .backgroundColor(this.isTranslateEnabled() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_sm'))
    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
    .onClick(() => {
      if (this.viewModel !== null) {
        this.viewModel!.setTranslateEnabled(!this.viewModel!.translateEnabled);
        setTimeout(() => {
          this.syncDialogState();
        }, 0);
      }
    })
  }

  @Builder
  nsfwChip(): void {
    Text(this.isNsfwShowing() ? $r('app.string.market_show_nsfw') : $r('app.string.market_hide_nsfw'))
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(this.isNsfwShowing() ? $r('app.color.app_danger') : $r('app.color.app_text_secondary'))
      .backgroundColor(this.isNsfwShowing() ? '#FFE5E5' : $r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick(() => {
        if (this.viewModel !== null) {
          // 切换 hideNsfw 状态
          this.viewModel!.setHideNsfw(!this.viewModel!.hideNsfw);
          // 同步弹窗状态
          setTimeout(() => {
            this.syncDialogState();
          }, 0);
        }
      })
  }

  @Builder
  hideImportedChip(): void {
    Text(this.isHidingImported() ? $r('app.string.market_hide_imported') : $r('app.string.market_show_imported'))
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(this.isHidingImported() ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
      .backgroundColor(this.isHidingImported() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .onClick(() => {
        if (this.viewModel !== null) {
          void this.viewModel!.setHideImported(!this.viewModel!.hideImported);
        }
      })
  }

  @Builder
  chineseOnlyChip(): void {
    Text($r('app.string.market_chinese_only'))
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(this.isChineseOnly() ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
      .backgroundColor(this.isChineseOnly() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick(() => {
        if (this.viewModel !== null) {
          void this.viewModel!.setChineseOnly(!this.viewModel!.chineseOnly);
        }
      })
  }

  /** sortChip 是否激活 */
  private isSortActive(sort: MarketSort): boolean {
    return this.viewModel !== null && this.viewModel!.sort === sort;
  }

  /** NSFW 当前是否显示中 */
  private isNsfwShowing(): boolean {
    return this.viewModel !== null && !this.viewModel!.hideNsfw;
  }

  /** 是否隐藏已导入 */
  private isHidingImported(): boolean {
    return this.viewModel !== null && this.viewModel!.hideImported;
  }

  /** 是否仅显示中文角色 */
  private isChineseOnly(): boolean {
    return this.viewModel !== null && this.viewModel!.chineseOnly;
  }

  /** 翻译开关是否已开启 */
  private isTranslateEnabled(): boolean {
    return this.viewModel !== null && this.viewModel!.translateEnabled;
  }

  // ===== 错误提示条 =====

  @Builder
  errorBanner(): void {
    Row() {
      Text(this.viewModel!.errorMessage)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Button($r('app.string.market_retry'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .padding({ left: 8, right: 8 })
        .height(28)
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.refresh();
          }
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_4')
    })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 主内容区 =====

  @Builder
  marketContent(): void {
    if (this.viewModel === null) {
      this.errorView($r('app.string.market_load_failed'), $r('app.string.market_not_initialized'))
    } else if (this.viewModel!.refreshing && this.viewModel!.items.length === 0) {
      this.loadingView()
    } else if (this.viewModel!.errorMessage.length > 0 && this.viewModel!.items.length === 0) {
      this.errorView($r('app.string.market_load_failed'), this.viewModel!.errorMessage)
    } else if (this.viewModel!.items.length === 0) {
      this.emptyView()
    } else {
      this.characterGrid()
    }
  }

  @Builder
  characterGrid(): void {
    Refresh({ refreshing: $$this.refreshing }) {
      Grid() {
        ForEach(this.viewModel!.items, (item: MarketCharacter, index: number) => {
          GridItem() {
            MarketCharacterCard({
              item: item,
              imported: this.viewModel!.isImported(item),
              translation: this.viewModel!.getTranslation(item),
              allowImageLoad: this.resolveAllowImageLoad(item),
              onPress: (params: MarketCardClickParams): void => {
                this.openDetail(params.item);
              }
            })
          }
        }, (item: MarketCharacter, index: number) => marketCharacterKey(item))
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap($r('app.float.app_spacing_12'))
      .rowsGap($r('app.float.app_spacing_12'))
      .width('100%')
      .height('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_8'),
        bottom: 200
      })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd(() => {
        if (this.viewModel !== null) {
          void this.viewModel!.loadMore();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => {
      if (this.viewModel !== null) {
        void this.viewModel!.refresh().then((): void => {
          this.refreshing = false;
        }).catch((): void => {
          this.refreshing = false;
        });
      } else {
        this.refreshing = false;
      }
    })
  }

  /**
   * 计算卡片是否允许加载图片。
   * NSFW 卡片仅在用户已确认显示 NSFW(hideNsfw=false)时加载大图,
   * 非 NSFW 卡片始终允许加载。
   */
  private resolveAllowImageLoad(item: MarketCharacter): boolean {
    if (!item.nsfw) {
      return true;
    }
    return this.viewModel !== null && !this.viewModel!.hideNsfw;
  }

  // ===== 加载 / 错误 / 空状态 =====

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.app_accent'))

      Text($r('app.string.market_loading'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: $r('app.float.app_spacing_8') })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(title: ResourceStr, description: ResourceStr): void {
    Column() {
      EmptyStateView({
        title: title,
        description: description
      })

      Button($r('app.string.market_retry'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('50%')
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.refresh();
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('app.float.app_spacing_32'), right: $r('app.float.app_spacing_32') })
  }

  @Builder
  emptyView(): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.market_empty'),
        description: this.resolveEmptyDescription()
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 根据当前搜索/筛选状态给出更友好的空状态描述。
   */
  private resolveEmptyDescription(): ResourceStr {
    if (this.viewModel === null) {
      return $r('app.string.market_no_results_default_desc');
    }
    if (this.viewModel!.appliedSearch.length > 0) {
      return $r('app.string.market_no_results_search_desc');
    }
    if (this.viewModel!.hideImported) {
      return $r('app.string.market_no_results_hide_imported_desc');
    }
    return $r('app.string.market_no_results_default_desc');
  }

  // ===== 详情页跳转 =====

  /**
   * 跳转到市场角色详情页。
   * 将 MarketCharacter 序列化为 JSON 传入。
   */
  private openDetail(item: MarketCharacter): void {
    try {
      const baseJson: string = JSON.stringify(item);
      router.pushUrl({
        url: 'pages/MarketDetailPage',
        params: { baseJson: baseJson }
      });
    } catch (e) {
      // 静默失败,不影响其他交互
    }
  }

  // ===== NSFW 二次确认弹窗 =====

  @Builder
  nsfwConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.market_content_warning'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          Text($r('app.string.market_nsfw_confirm_message'))
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ bottom: 20 })
            .textAlign(TextAlign.Center)
            .width('100%')

          Row() {
            Button($r('app.string.market_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel!.cancelShowNsfw();
                }
                this.showNsfwConfirm = false;
              })

            Button($r('app.string.market_confirm_show'))
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius(20)
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  void this.viewModel!.confirmShowNsfw();
                }
                this.showNsfwConfirm = false;
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 翻译隐私提示弹窗 =====

  @Builder
  translatePrivacyDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.market_translate_privacy_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          Text($r('app.string.market_translate_privacy_message'))
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ bottom: 20 })
            .textAlign(TextAlign.Start)
            .width('100%')

          Button($r('app.string.market_translate_privacy_confirm'))
            .fontSize(14)
            .backgroundColor($r('app.color.app_accent'))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .margin({ bottom: 8 })
            .onClick(() => {
              if (this.viewModel !== null) {
                void this.viewModel!.confirmEnableTranslate();
              }
              this.showTranslatePrivacy = false;
            })

          Button($r('app.string.market_translate_privacy_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_text_secondary'))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel!.cancelEnableTranslate();
              }
              this.showTranslatePrivacy = false;
            })
        }
        .width('85%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }
}
