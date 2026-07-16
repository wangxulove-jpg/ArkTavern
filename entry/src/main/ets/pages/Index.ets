/**
 * Index 方舟酒馆首页
 *
 * 正式应用首页,使用 Navigation + NavPathStack 管理页面导航。
 * 包含:
 * - 应用标题区
 * - 最近会话(空状态)
 * - 主要功能入口网格(开始聊天/角色/世界书/模型设置)
 * - 模型连接状态卡片
 * - 应用设置入口
 * - 开发工具折叠区(真实 SSE 测试)
 *
 * 临时 PoC 入口(RealSsePocPage)同样通过 NavPathStack 访问,与正式功能导航一致。
 * Phase 1 正式功能完成后删除 PoC 入口。
 */

import { ChatPage } from './ChatPage';
import { CharacterListPage } from './CharacterListPage';
import { LorebookPage } from './LorebookPage';
import { ModelSettingsPage } from './ModelSettingsPage';
import { AppSettingsPage } from './AppSettingsPage';
import { RealSsePocPage } from './RealSsePocPage';

@Entry
@Component
struct Index {
  @State pathStack: NavPathStack = new NavPathStack();
  @State isDevToolsExpanded: boolean = false;

  /**
   * NavDestination 页面构建器。
   * 根据 name 映射到对应的页面组件。
   */
  @Builder
  pageMap(name: string) {
    if (name === 'ChatPage') {
      ChatPage()
    } else if (name === 'CharacterListPage') {
      CharacterListPage()
    } else if (name === 'LorebookPage') {
      LorebookPage()
    } else if (name === 'ModelSettingsPage') {
      ModelSettingsPage()
    } else if (name === 'AppSettingsPage') {
      AppSettingsPage()
    } else if (name === 'RealSsePocPage') {
      RealSsePocPage()
    }
  }

  /**
   * 主要功能入口按钮。
   * @param label 按钮文字资源
   * @param targetPage 目标页面名称
   */
  @Builder
  entryButton(label: Resource, targetPage: string) {
    Button(label)
      .width('100%')
      .height(56)
      .fontSize($r('app.float.home_entry_font_size'))
      .fontColor($r('app.color.home_primary_text'))
      .backgroundColor($r('app.color.home_card_background'))
      .borderRadius(12)
      .onClick(() => {
        this.pathStack.pushPath({ name: targetPage });
      })
  }

  build() {
    Navigation(this.pathStack) {
      Scroll() {
        Column() {
          // ===== 顶部标题区 =====
          Column() {
            Text($r('app.string.home_app_name'))
              .fontSize($r('app.float.home_title_font_size'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.home_primary_text'))

            Text($r('app.string.home_app_subtitle'))
              .fontSize($r('app.float.home_subtitle_font_size'))
              .fontColor($r('app.color.home_accent'))
              .margin({ top: 4 })

            Text($r('app.string.home_description'))
              .fontSize($r('app.float.home_caption_font_size'))
              .fontColor($r('app.color.home_secondary_text'))
              .margin({ top: 8 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 20, right: 20, top: 24, bottom: 20 })

          // ===== 最近会话卡片 =====
          Column() {
            Text($r('app.string.home_no_sessions'))
              .fontSize($r('app.float.home_body_font_size'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.home_primary_text'))

            Text($r('app.string.home_no_sessions_desc'))
              .fontSize($r('app.float.home_caption_font_size'))
              .fontColor($r('app.color.home_secondary_text'))
              .margin({ top: 6 })
          }
          .width('100%')
          .padding(20)
          .margin({ left: 16, right: 16 })
          .backgroundColor($r('app.color.home_card_background'))
          .borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          // ===== 主要功能入口网格 =====
          Grid() {
            GridItem() {
              this.entryButton($r('app.string.home_start_chat'), 'ChatPage')
            }

            GridItem() {
              this.entryButton($r('app.string.home_characters'), 'CharacterListPage')
            }

            GridItem() {
              this.entryButton($r('app.string.home_lorebook'), 'LorebookPage')
            }

            GridItem() {
              this.entryButton($r('app.string.home_model_settings'), 'ModelSettingsPage')
            }
          }
          .columnsTemplate('1fr 1fr')
          .rowsGap(12)
          .columnsGap(12)
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 16 })
          .height(124)

          // ===== 模型连接状态卡片 =====
          Row() {
            Column() {
              Text($r('app.string.home_model_not_configured'))
                .fontSize($r('app.float.home_body_font_size'))
                .fontColor($r('app.color.home_secondary_text'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 点击进入模型设置
            Blank()
              .width(0)
              .height(0)
          }
          .width('100%')
          .padding(20)
          .margin({ left: 16, right: 16, top: 16 })
          .backgroundColor($r('app.color.home_card_background'))
          .borderRadius(12)
          .onClick(() => {
            this.pathStack.pushPath({ name: 'ModelSettingsPage' });
          })

          // ===== 应用设置入口 =====
          Row() {
            Text($r('app.string.home_app_settings'))
              .fontSize($r('app.float.home_entry_font_size'))
              .fontColor($r('app.color.home_primary_text'))
              .layoutWeight(1)

            Text('›')
              .fontSize(20)
              .fontColor($r('app.color.home_secondary_text'))
          }
          .width('100%')
          .height(56)
          .padding({ left: 20, right: 20 })
          .margin({ left: 16, right: 16, top: 16 })
          .backgroundColor($r('app.color.home_card_background'))
          .borderRadius(12)
          .onClick(() => {
            this.pathStack.pushPath({ name: 'AppSettingsPage' });
          })

          // ===== 开发工具区域(与正式入口隔离) =====
          Column() {
            // 开发工具标题行(可折叠)
            Row() {
              Text($r('app.string.home_dev_tools'))
                .fontSize($r('app.float.home_caption_font_size'))
                .fontColor($r('app.color.home_dev_text'))
                .layoutWeight(1)

              Text(this.isDevToolsExpanded ? '▾' : '▸')
                .fontSize(14)
                .fontColor($r('app.color.home_dev_text'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 8 })
            .onClick(() => {
              this.isDevToolsExpanded = !this.isDevToolsExpanded;
            })

            // 开发工具内容(折叠时隐藏)
            if (this.isDevToolsExpanded) {
              Row() {
                Text($r('app.string.home_dev_sse_test'))
                  .fontSize($r('app.float.home_body_font_size'))
                  .fontColor($r('app.color.home_dev_text'))
                  .layoutWeight(1)

                Text($r('app.string.common_dev_test_label'))
                  .fontSize($r('app.float.home_caption_font_size'))
                  .fontColor($r('app.color.home_dev_text'))
              }
              .width('100%')
              .height(52)
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.home_dev_background'))
              .borderRadius(8)
              .margin({ left: 16, right: 16, bottom: 8 })
              .onClick(() => {
                // 临时 PoC 入口:通过 NavPathStack 访问 RealSsePocPage
                // Phase 1 正式功能完成后删除
                this.pathStack.pushPath({ name: 'RealSsePocPage' });
              })
            }
          }
          .width('100%')
          .margin({ top: 24 })

          // ===== 版本信息 =====
          Text($r('app.string.home_version'))
            .fontSize($r('app.float.home_caption_font_size'))
            .fontColor($r('app.color.home_secondary_text'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ top: 24, bottom: 32 })
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.home_background'))
      .scrollBar(BarState.Off)
    }
    .navDestination(this.pageMap)
    .hideTitleBar(true)
    .backgroundColor($r('app.color.home_background'))
  }
}
