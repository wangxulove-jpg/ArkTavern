/**
 * PromptPresetListPage 预设列表页面
 *
 * 显示所有预设,支持设为当前、新建、编辑、删除。
 * 通过 PromptPresetListViewModel 操作,不直接访问 Repository 或 Service。
 */

import { PromptPresetListViewModel } from '../viewmodels/PromptPresetListViewModel';
import { AppServices } from '../services/AppServices';
import { PromptPreset } from '../models/PromptPreset';
import { promptAction } from '@kit.ArkUI';

interface PresetEditRouteParam {
  presetId: string;
}

@Entry
@Component
export struct PromptPresetListPage {
  @State viewModel: PromptPresetListViewModel = AppServices.createPromptPresetListViewModel();
  @State refreshKey: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  aboutToAppear(): void {
    this.viewModel.initialize();
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  build() {
    NavDestination() {
      Column() {
        // 标题栏
        Row() {
          Button('返回')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              const navInfo = this.queryNavigationInfo();
              if (navInfo !== undefined) {
                navInfo.pathStack.pop();
              }
            })

          Blank()

          Text('提示词预设')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)

          Blank()

          Button('清除当前')
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.viewModel.clearCurrent();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: this.statusBarHeight + 8, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        // 当前状态
        Row() {
          Text(this.viewModel.currentPresetId.length > 0
            ? '当前预设已启用'
            : '未使用预设')
            .fontSize(13)
            .fontColor(this.viewModel.currentPresetId.length > 0
              ? '#007AFF'
              : '#999999')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })

        // 错误提示
        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(13)
            .fontColor('#FF3B30')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }

        Divider()
          .height(1)
          .color('#E0E0E0')

        // 新建按钮
        Row() {
          Button('+ 新建预设')
            .fontSize(14)
            .backgroundColor('#007AFF')
            .fontColor(Color.White)
            .borderRadius(8)
            .onClick(() => {
              const navInfo = this.queryNavigationInfo();
              if (navInfo !== undefined) {
                navInfo.pathStack.pushPathByName('PromptPresetEditPage', { presetId: '' } as PresetEditRouteParam, () => {
                  this.viewModel.refresh();
                });
              }
            })
        }
        .width('100%')
        .padding(16)
        .justifyContent(FlexAlign.Center)

        if (this.viewModel.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
            Text('加载中...')
              .fontSize(14)
              .fontColor('#999999')
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.viewModel.presets.length === 0) {
          Column() {
            Text('暂无预设')
              .fontSize(16)
              .fontColor('#999999')
            Text('点击上方按钮创建第一个预设')
              .fontSize(13)
              .fontColor('#CCCCCC')
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
            color: '#F0F0F0',
            startMargin: 16,
            endMargin: 16
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .title('')
    .hideTitleBar(true)
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
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.viewModel.isCurrentPreset(preset.id)) {
              Text('当前')
                .fontSize(10)
                .fontColor('#007AFF')
                .backgroundColor('#E8F4FD')
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ left: 8 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (preset.description.length > 0) {
            Text(preset.description)
              .fontSize(12)
              .fontColor('#999999')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }

          Text(this.viewModel.getPresetSummary(preset))
            .fontSize(12)
            .fontColor('#666666')
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 操作按钮
        Row() {
          Button('设为当前')
            .fontSize(12)
            .backgroundColor('#007AFF')
            .fontColor(Color.White)
            .borderRadius(4)
            .height(28)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.viewModel.setCurrent(preset.id);
            })

          Button('编辑')
            .fontSize(12)
            .backgroundColor('#F5F5F5')
            .fontColor('#333333')
            .borderRadius(4)
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ left: 6 })
            .onClick(() => {
              const navInfo = this.queryNavigationInfo();
              if (navInfo !== undefined) {
                navInfo.pathStack.pushPathByName('PromptPresetEditPage', { presetId: preset.id } as PresetEditRouteParam, () => {
                  this.viewModel.refresh();
                });
              }
            })

          Button('删除')
            .fontSize(12)
            .backgroundColor('#FF3B30')
            .fontColor(Color.White)
            .borderRadius(4)
            .height(28)
            .padding({ left: 8, right: 8 })
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
                  fontColor: '#FF3B30',
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