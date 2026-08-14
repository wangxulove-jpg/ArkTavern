/**
 * PromptPresetListPage 预设列表页面
 *
 * 显示所有预设,支持设为当前、新建、编辑、删除。
 * 通过 PromptPresetListViewModel 操作,不直接访问 Repository 或 Service。
 *
 * 主题适配:
 * - 页面背景使用 ThemePalette.pageBackgroundColor(this.effectiveTheme)(浅色 #F5F5F5 / 深色 #121212)
 * - 标题栏使用 ThemePalette.surface1Color(this.effectiveTheme)
 * - 文字使用 ThemePalette.textPrimaryColor(this.effectiveTheme) / ThemePalette.textSecondaryColor(this.effectiveTheme)
 * - 主操作按钮使用 ThemePalette.accentColor(this.effectiveTheme) + $r('app.color.app_on_accent')
 * - 删除按钮使用 $r('app.color.app_danger')
 * - 分隔线使用 ThemePalette.dividerColor(this.effectiveTheme)
 * - 不在组件中散落十六进制颜色,浅色/深色模式自动切换
 *
 * 系统状态栏:
 * - 由 EntryAbility 全局处理(状态栏背景透明,图标颜色随 colorMode 切换)
 * - 页面只需保证根容器背景色与主题一致,深色模式下状态栏区域透出深色背景
 * - 不在页面层硬编码系统栏颜色
 */

import { PromptPresetListViewModel } from '../viewmodels/PromptPresetListViewModel';
import { AppServices } from '../services/AppServices';
import { PromptPreset } from '../models/PromptPreset';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

interface PresetEditRouteParam {
  presetId: string;
}

@Entry
@Component
struct PromptPresetListPage {
  @State viewModel: PromptPresetListViewModel = AppServices.createPromptPresetListViewModel();
  @State refreshKey: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 标记是否已完成首次加载,用于区分 onPageShow 是首次还是从子页返回 */
  private hasInitialized: boolean = false;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    // 首次加载由 onPageShow 统一触发,避免与 onPageShow 重复调用
  }

  onPageShow(): void {
    // 页面每次显示都会触发(包括从编辑页 router.back() 返回)
    // 首次:执行 initialize(内部含 refresh);后续:仅 refresh 以拉取新增/编辑后的数据
    if (this.hasInitialized) {
      this.viewModel.refresh();
    } else {
      this.hasInitialized = true;
      this.viewModel.initialize();
    }
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  build() {
    Column() {
      // 标题栏(复用设置子页面规范:app_surface_1 背景 + app_text_primary 文字)
      Row() {
        Button('返回')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .onClick(() => {
            router.back();
          })

        Blank()

        Text('提示词预设')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

        Blank()

        Button('清除选择')
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .onClick(() => {
            this.viewModel.clearAll();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: this.statusBarHeight + 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

      // 已选预设状态区(标签:次级文字,值:主文字)
      Row() {
        Text('已选预设：')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Text(this.viewModel.getSelectedCount() > 0
          ? this.viewModel.getSelectedCount().toString() + ' 个'
          : '未选择')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.viewModel.getSelectedCount() > 0
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })

      // 错误提示
      if (this.viewModel.errorMessage.length > 0) {
        Text(this.viewModel.errorMessage)
          .fontSize(13)
          .fontColor($r('app.color.app_danger'))
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      Divider()
        .height(1)
        .color(ThemePalette.dividerColor(this.effectiveTheme))

      // 新建按钮(品牌蓝背景 + 完全不透明白色文字)
      Row() {
        Button('+ 新建预设')
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(20)
          .height(40)
          .padding({ left: 24, right: 24 })
          .onClick(() => {
            router.pushUrl({
              url: 'pages/PromptPresetEditPage',
              params: { presetId: '' } as PresetEditRouteParam
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 16 })
      .justifyContent(FlexAlign.Center)

      if (this.viewModel.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(ThemePalette.accentColor(this.effectiveTheme))
          Text('加载中...')
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.viewModel.presets.length === 0) {
        // 空状态:标题用主文字色,说明用次级文字色(深色模式下均清晰可见)
        Column() {
          Text('暂无预设')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text('点击上方按钮创建第一个预设')
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.viewModel.presets, (preset: PromptPreset, index: number) => {
            ListItem() {
              this.presetItem(preset)
            }
          }, (preset: PromptPreset) => preset.id + '_' + this.refreshKey.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .divider({
          strokeWidth: 1,
          color: ThemePalette.dividerColor(this.effectiveTheme),
          startMargin: 16,
          endMargin: 16
        })
      }

      // 底部安全区避让
      Blank().height(this.navigationBarHeight)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  presetItem(preset: PromptPreset) {
    Column() {
      Row() {
        Column() {
          Row() {
            Text(preset.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (preset.description.length > 0) {
            Text(preset.description)
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }

          Text(this.viewModel.getPresetSummary(preset))
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 操作按钮
        Row() {
          Button(this.viewModel.isSelected(preset.id) ? '已选' : '选择')
            .fontSize(12)
            .backgroundColor(this.viewModel.isSelected(preset.id)
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.viewModel.isSelected(preset.id)
              ? $r('app.color.app_on_accent')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(6)
            .height(28)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.viewModel.toggle(preset.id);
            })

          Button('编辑')
            .fontSize(12)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(6)
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ left: 6 })
            .onClick(() => {
              router.pushUrl({
                url: 'pages/PromptPresetEditPage',
                params: { presetId: preset.id } as PresetEditRouteParam
              });
            })

          Button('删除')
            .fontSize(12)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(6)
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ left: 6 })
            .onClick(() => {
              AlertDialog.show({
                title: '删除确认',
                message: '删除该提示词预设？\n此操作无法撤销。',
                autoCancel: true,
                alignment: DialogAlignment.Center,
                primaryButton: {
                  value: '取消',
                  action: () => {}
                },
                secondaryButton: {
                  value: '删除',
                  fontColor: $r('app.color.app_danger'),
                  action: () => {
                    this.viewModel.confirmDelete(preset.id);
                  }
                }
              });
            })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }
}
