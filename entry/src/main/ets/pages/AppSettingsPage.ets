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

  private preferences: AppPreferences | null = null;

  aboutToAppear(): void {
    this.preferences = AppServices.getAppPreferences();
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
