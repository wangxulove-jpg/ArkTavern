/**
 * AppSettingsPage 应用设置页面
 *
 * v9: 全局用户称呼设置入口。
 * v10 (ARK-UI-THEME-1): 新增"外观"区块,提供四种主题选择(跟随设备 / 浅色 / 深色 / 酒馆棕)。
 * - 通过 AppPreferences 读写 GLOBAL_USER_NAME_KEY
 * - 通过 ThemeManager(唯一主题 authority)读写主题模式,选择后立即应用
 * - 不存储 API Key / Authorization / 敏感数据
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { ThemeManager } from '../services/ThemeManager';
import { ThemeMode } from '../models/ThemeMode';
import { ThemePalette, ThemeColors } from '../theme/ThemePalette';
import { GLOBAL_USER_NAME_KEY } from '../services/ChatService';

/** 主题选项模型(供构建器使用) */
interface ThemeOption {
  mode: ThemeMode;
  title: Resource;
  desc: Resource;
}

@Entry
@Component
struct AppSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题(响应式,驱动预览色块) */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 当前输入的全局用户称呼(从 AppPreferences 加载) */
  @State globalUserName: string = '';
  /** 保存中 */
  @State isSaving: boolean = false;
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 错误提示(空表示无错误) */
  @State errorMessage: string = '';
  /** 当前选中的主题模式(内存镜像) */
  @State selectedThemeMode: ThemeMode = ThemeMode.FOLLOW_SYSTEM;

  private preferences: AppPreferences | null = null;
  private themeManager: ThemeManager | null = null;

  aboutToAppear(): void {
    this.preferences = AppServices.getAppPreferences();
    this.themeManager = AppServices.getThemeManager();
    this.selectedThemeMode = this.themeManager.getSelectedMode();
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

  /** 选择主题并立即应用(无需保存按钮) */
  private async selectTheme(mode: ThemeMode): Promise<void> {
    if (this.themeManager === null || this.selectedThemeMode === mode) {
      return;
    }
    this.selectedThemeMode = mode;
    await this.themeManager.setThemeMode(mode);
  }

  /** 根据模式获取标题资源 */
  private themeTitle(mode: ThemeMode): Resource {
    if (mode === ThemeMode.LIGHT) {
      return $r('app.string.settings_theme_light');
    }
    if (mode === ThemeMode.DARK) {
      return $r('app.string.settings_theme_dark');
    }
    if (mode === ThemeMode.TAVERN) {
      return $r('app.string.settings_theme_tavern');
    }
    return $r('app.string.settings_theme_follow_system');
  }

  /** 根据模式获取说明资源 */
  private themeDesc(mode: ThemeMode): Resource {
    if (mode === ThemeMode.LIGHT) {
      return $r('app.string.settings_theme_light_desc');
    }
    if (mode === ThemeMode.DARK) {
      return $r('app.string.settings_theme_dark_desc');
    }
    if (mode === ThemeMode.TAVERN) {
      return $r('app.string.settings_theme_tavern_desc');
    }
    return $r('app.string.settings_theme_follow_system_desc');
  }

  /** 获取预览色块色板(跟随设备按有效主题取色) */
  private previewColors(mode: ThemeMode): ThemeColors {
    let effective: string = this.effectiveTheme;
    if (mode === ThemeMode.LIGHT) {
      effective = 'light';
    } else if (mode === ThemeMode.DARK) {
      effective = 'dark';
    } else if (mode === ThemeMode.TAVERN) {
      effective = 'tavern';
    }
    return ThemePalette.forTheme(effective);
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
            // ===== 外观:主题选择 =====
            Text($r('app.string.settings_theme_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 12 })

            Text($r('app.string.settings_theme_title'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 4 })

            Text($r('app.string.settings_theme_desc'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ bottom: 12 })

            this.themeOptionCard(ThemeMode.FOLLOW_SYSTEM)
            this.themeOptionCard(ThemeMode.LIGHT)
            this.themeOptionCard(ThemeMode.DARK)
            this.themeOptionCard(ThemeMode.TAVERN)

            // ===== 全局用户称呼分区 =====
            Text($r('app.string.settings_global_user_name_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 24, bottom: 12 })

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
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 主题选项卡片:名称 + 说明 + 小型颜色预览 + 当前选择标记 */
  @Builder
  themeOptionCard(mode: ThemeMode) {
    Column() {
      Row() {
        // 小型颜色预览(背景 / 表面 / 文字 / Accent 四色块)
        Column() {
          Column() {
            Row() {
              this.previewSwatch(this.previewColors(mode).pageBg, 1.0)
              this.previewSwatch(this.previewColors(mode).surface1, 1.0)
              this.previewSwatch(this.previewColors(mode).textPrimary, 0.6)
              this.previewSwatch(this.previewColors(mode).accent, 1.0)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
          .width(64)
          .height(40)
          .borderRadius(8)
          .backgroundColor(this.previewColors(mode).pageBg)
          .justifyContent(FlexAlign.Center)
          .padding({ left: 6, right: 6 })
          .border({ width: 1, color: this.previewColors(mode).border })
        }
        .margin({ right: 12 })

        Column() {
          Row() {
            Text(this.themeTitle(mode))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))

            if (this.selectedThemeMode === mode) {
              Text('✓')
                .fontSize(14)
                .fontColor($r('app.color.app_accent'))
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.themeDesc(mode))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.page_secondary_text'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({
      width: this.selectedThemeMode === mode ? 2 : 1,
      color: this.selectedThemeMode === mode ? $r('app.color.app_accent') : $r('app.color.app_divider')
    })
    .margin({ bottom: 8 })
    .onClick(() => {
      this.selectTheme(mode);
    })
  }

  /** 单个预览色块 */
  @Builder
  previewSwatch(color: string, opacity: number) {
    Text('')
      .width(10)
      .height(10)
      .borderRadius(2)
      .backgroundColor(color)
      .opacity(opacity)
      .margin({ right: 4 })
  }
}
