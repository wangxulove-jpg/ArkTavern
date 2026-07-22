/**
 * AppSettingsPage 应用设置页面
 *
 * v9: 全局用户称呼设置入口。
 * - 通过 AppPreferences 读写 GLOBAL_USER_NAME_KEY
 * - 用于所有未单独设置称呼的角色
 * - 留空时调用方回退到 'User'
 * - 不存储 API Key / Authorization / 敏感数据
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { GLOBAL_USER_NAME_KEY } from '../services/ChatService';
import { Chat3DDisplaySettings } from '../utils/Chat3DDisplaySettings';

@Entry
@Component
struct AppSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前输入的全局用户称呼(从 AppPreferences 加载) */
  @State globalUserName: string = '';
  /** 保存中 */
  @State isSaving: boolean = false;
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 错误提示(空表示无错误) */
  @State errorMessage: string = '';
  /** T-3D.5: 3D 显示开关(从 Chat3DDisplaySettings 加载) */
  @State chat3DEnabled: boolean = false;

  private preferences: AppPreferences | null = null;
  private chat3DSettings: Chat3DDisplaySettings | null = null;

  aboutToAppear(): void {
    this.preferences = AppServices.getAppPreferences();
    try {
      this.chat3DSettings = AppServices.getChat3DDisplaySettings();
      this.chat3DEnabled = this.chat3DSettings.isEnabled();
    } catch (_e) {
      // Chat3DDisplaySettings 未初始化时保持默认关闭
    }
    this.loadGlobalUserName();
  }

  private async loadGlobalUserName(): Promise<void> {
    if (this.preferences === null) {
      this.errorMessage = 'AppPreferences 未初始化';
      this.isLoading = false;
      return;
    }
    try {
      const value: string = await this.preferences.getString(GLOBAL_USER_NAME_KEY, '');
      this.globalUserName = value;
    } catch (e) {
      this.errorMessage = '加载失败';
    } finally {
      this.isLoading = false;
    }
  }

  private async saveGlobalUserName(): Promise<void> {
    if (this.preferences === null) {
      this.errorMessage = 'AppPreferences 未初始化';
      return;
    }
    this.isSaving = true;
    try {
      await this.preferences.putString(GLOBAL_USER_NAME_KEY, this.globalUserName.trim());
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_saved') });
    } catch (e) {
      this.errorMessage = '保存失败';
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_save_failed') });
    } finally {
      this.isSaving = false;
    }
  }

  /**
   * T-3D.5: 切换 3D 显示开关。
   * 写入成功后通过 AppStorage 通知 ChatPage 刷新。
   */
  private async toggleChat3D(enabled: boolean): Promise<void> {
    if (this.chat3DSettings === null) {
      this.errorMessage = 'Chat3DDisplaySettings 未初始化';
      return;
    }
    try {
      await this.chat3DSettings.setEnabled(enabled);
      this.chat3DEnabled = enabled;
    } catch (e) {
      // 写入失败时回滚 UI 状态
      this.chat3DEnabled = !enabled;
      this.errorMessage = '保存失败';
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_save_failed') });
    }
  }

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.page_primary_text')])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.nav_app_settings_title'))
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ right: 40 })
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // 错误提示
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_4'),
            bottom: $r('app.float.app_spacing_4')
          })
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('app.color.page_secondary_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // 全局用户称呼分区
            Text($r('app.string.settings_global_user_name_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 12 })

            Text($r('app.string.settings_global_user_name_label'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 8 })

            TextInput({
              placeholder: $r('app.string.settings_global_user_name_placeholder'),
              text: this.globalUserName
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .height(48)
              .padding({ left: 16, right: 16 })
              .width('100%')
              .onChange((value: string) => {
                this.globalUserName = value;
              })

            Text($r('app.string.settings_global_user_name_hint'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ top: 8 })

            Button($r('app.string.character_edit_save'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .width('100%')
              .margin({ top: 24 })
              .enabled(!this.isSaving)
              .onClick(() => {
                this.saveGlobalUserName();
              })

            // T-3D.5: 聊天显示分区
            Text($r('app.string.settings_chat_3d_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 32, bottom: 12 })

            Row() {
              Column() {
                Text($r('app.string.settings_chat_3d_enable_label'))
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.page_primary_text'))
                  .width('100%')
                Text($r('app.string.settings_chat_3d_enable_hint'))
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.page_secondary_text'))
                  .width('100%')
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.chat3DEnabled })
                .onChange((isOn: boolean) => {
                  this.toggleChat3D(isOn);
                })
            }
            .width('100%')
            .padding({
              top: $r('app.float.app_spacing_12'),
              bottom: $r('app.float.app_spacing_12')
            })
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_16'),
            bottom: 100
          })
        }
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
