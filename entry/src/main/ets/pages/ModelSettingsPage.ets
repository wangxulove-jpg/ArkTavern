/**
 * ModelSettingsPage 模型设置主页
 *
 * UI-2 重构后只负责配置管理:
 * - 当前配置摘要卡
 * - 配置列表
 * - 新建配置入口
 * - 空状态、加载状态、错误状态
 *
 * 编辑表单拆分到 ModelConfigEditPage。
 * 页面通过 AppStorage 与编辑页共享同一个 ModelSettingsViewModel 实例。
 */

import { ModelSettingsViewModel } from '../viewmodels/ModelSettingsViewModel';
import { AppServices } from '../services/AppServices';
import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';

const APP_STORAGE_VM_KEY: string = 'ModelSettingsViewModel';

@Component
export struct ModelSettingsPage {
  @State viewModel: ModelSettingsViewModel | null = null;
  @State initError: string = '';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const ms = AppServices.getInstance().modelService;
      this.viewModel = new ModelSettingsViewModel(ms);
      await this.viewModel.initialize();
      AppStorage.setOrCreate(APP_STORAGE_VM_KEY, this.viewModel);
    } catch (e) {
      this.initError = '初始化失败,请重试';
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  build() {
    NavDestination() {
      if (this.viewModel === null) {
        this.loadingView()
      } else {
        this.mainView()
      }
    }
    .title($r('app.string.nav_model_settings_title'))
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  loadingView() {
    Column() {
      if (this.initError.length > 0) {
        Text(this.initError)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_secondary_text'))
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  mainView() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        if (this.viewModel!.configs.length === 0) {
          this.emptyState()
        } else {
          this.currentConfigCard()
          this.configListSection()
        }

        // 新建配置按钮
        Button($r('app.string.model_settings_add_config'))
          .width('100%')
          .height(48)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .margin({ top: 8, bottom: 32 })
          .onClick(() => {
            this.viewModel!.startCreate();
            this.viewModel!.setActiveEditTab(0);
            this.getPathStack()?.pushPathByName('ModelConfigEditPage', null);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
  }

  @Builder
  currentConfigCard() {
    if (this.currentConfig !== undefined) {
      Column({ space: 8 }) {
        Row() {
          Text($r('app.string.model_settings_current_config_title'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
          Blank()
          if (this.currentConfig.enabled) {
            Text($r('app.string.model_settings_config_enabled'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.model_settings_success'))
          } else {
            Text($r('app.string.model_settings_config_disabled'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
          }
        }
        .width('100%')

        Text(this.currentConfig.name)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(this.providerDisplayName(this.currentConfig.type))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
          Text(' · ')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(this.currentConfig.modelName)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row() {
          SymbolGlyph($r('sys.symbol.key'))
            .fontSize(16)
            .fontColor([$r('app.color.app_text_tertiary')])
          Text(this.viewModel!.currentConfigKeyConfigured
            ? $r('app.string.model_settings_api_key_status_configured')
            : $r('app.string.model_settings_api_key_status_not_configured'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ left: 4 })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  configListSection() {
    Column({ space: 12 }) {
      Text($r('app.string.model_settings_config_list'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')

      List({ space: 8 }) {
        ForEach(this.viewModel!.configs, (config: ProviderConfig) => {
          ListItem() {
            this.configListItem(config)
          }
        })
      }
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  configListItem(config: ProviderConfig) {
    Row() {
      Column({ space: 4 }) {
        Row() {
          Text(config.name)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.viewModel!.currentConfigId === config.id) {
            Text($r('app.string.model_settings_current_badge'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_accent'))
              .margin({ left: 8 })
          }
        }
        .width('100%')

        Row() {
          Text(this.providerDisplayName(config.type))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
          Text(' · ')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
          Text(config.modelName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('app.color.app_text_tertiary')])
        .margin({ left: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .onClick(() => {
      this.viewModel!.selectConfig(config.id);
      this.viewModel!.setActiveEditTab(0);
      this.getPathStack()?.pushPathByName('ModelConfigEditPage', null);
    })
  }

  @Builder
  emptyState() {
    Column({ space: 8 }) {
      Text($r('app.string.model_settings_empty_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
      Text($r('app.string.model_settings_empty_desc'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 48, bottom: 48 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  statusBanner() {
    if (this.viewModel!.errorMessage.length > 0) {
      Text(this.viewModel!.errorMessage)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .padding(12)
        .width('100%')
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
    }
    if (this.viewModel!.statusMessage.length > 0) {
      Text(this.viewModel!.statusMessage)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.model_settings_success'))
        .padding(12)
        .width('100%')
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
    }
  }

  private get currentConfig(): ProviderConfig | undefined {
    if (this.viewModel === null || this.viewModel!.currentConfigId === null) {
      return undefined;
    }
    return this.findConfig(this.viewModel!.currentConfigId);
  }

  private findConfig(id: string): ProviderConfig | undefined {
    const configs: ProviderConfig[] = this.viewModel!.configs;
    for (let i = 0; i < configs.length; i++) {
      if (configs[i].id === id) {
        return configs[i];
      }
    }
    return undefined;
  }

  private providerDisplayName(type: ProviderType): string {
    switch (type) {
      case ProviderType.DeepSeek:
        return 'DeepSeek';
      case ProviderType.OpenAICompatible:
        return 'OpenAI Compatible';
      case ProviderType.OpenAI:
        return 'OpenAI';
      case ProviderType.OpenRouter:
        return 'OpenRouter';
      case ProviderType.Claude:
        return 'Claude';
      case ProviderType.Gemini:
        return 'Gemini';
      default:
        return 'Unknown';
    }
  }

  private getPathStack(): NavPathStack | null {
    try {
      const navInfo: NavigationInfo | undefined = this.queryNavigationInfo();
      if (navInfo !== undefined) {
        return navInfo.pathStack;
      }
    } catch (_e) {
      // ignore
    }
    return null;
  }
}
