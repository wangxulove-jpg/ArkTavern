/**
 * ModelSettingsPage 模型设置页面
 *
 * 正式模型配置页面,提供:
 * - 配置列表(显示全部配置,当前配置有标记)
 * - 编辑表单(名称/Provider/Base URL/Model/API Key/参数)
 * - 操作(保存/测试连接/设为当前/删除)
 * - DeepSeek 预设模式:自动填充 URL/Model,选择模型即可
 *
 * 页面只通过 ModelSettingsViewModel 调用 ModelService。
 * API Key 使用普通输入框+页面自行掩码,不触发系统安全键盘。
 * 修复:不再通过 @Builder 参数传递 ViewModel,直接使用 @State 绑定。
 */

import { ModelSettingsViewModel } from '../viewmodels/ModelSettingsViewModel';
import { AppServices } from '../services/AppServices';
import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';
import { ModelOption } from '../models/ProviderPreset';
import { getPreset } from '../models/ProviderPreset';

interface TypeOption {
  readonly value: ProviderType;
  readonly label: string;
  readonly supported: boolean;
}

const TYPE_OPTIONS: TypeOption[] = [
  { value: ProviderType.OpenAICompatible, label: 'OpenAI Compatible', supported: true },
  { value: ProviderType.OpenAI, label: 'OpenAI', supported: true },
  { value: ProviderType.DeepSeek, label: 'DeepSeek', supported: true },
  { value: ProviderType.OpenRouter, label: 'OpenRouter', supported: true },
  { value: ProviderType.Claude, label: 'Claude(暂未支持)', supported: false },
  { value: ProviderType.Gemini, label: 'Gemini(暂未支持)', supported: false }
];

@Component
export struct ModelSettingsPage {
  pathStack: NavPathStack = new NavPathStack();
  @State viewModel: ModelSettingsViewModel | null = null;
  @State initError: string = '';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const ms = AppServices.getInstance().modelService;
      this.viewModel = new ModelSettingsViewModel(ms);
      await this.viewModel.initialize();
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
          .fontSize($r('app.float.nav_body_font_size'))
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
      Column() {
        // 状态消息置顶
        if (this.viewModel !== null) {
          if (this.viewModel.errorMessage.length > 0) {
            Text(this.viewModel.errorMessage)
              .fontSize($r('app.float.home_body_font_size'))
              .fontColor($r('app.color.model_settings_danger'))
              .padding(12)
              .width('100%')
              .backgroundColor('#FFE0E0')
              .borderRadius(8)
              .margin({ top: 8 })
          }
          if (this.viewModel.statusMessage.length > 0) {
            Text(this.viewModel.statusMessage)
              .fontSize($r('app.float.home_body_font_size'))
              .fontColor($r('app.color.model_settings_success'))
              .padding(12)
              .width('100%')
              .backgroundColor('#E0FFE0')
              .borderRadius(8)
              .margin({ top: 8 })
          }
        }
        this.configListSection()
        this.formSection()
        this.actionsSection()
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
  }

  @Builder
  configListSection() {
    Column() {
      Text($r('app.string.model_settings_config_list'))
        .fontSize($r('app.float.nav_body_font_size'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.page_primary_text'))
        .margin({ top: 12, bottom: 8 })

      if (this.viewModel !== null && this.viewModel.configs.length === 0) {
        Text($r('app.string.model_settings_no_configs'))
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .padding(12)
      } else if (this.viewModel !== null) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.viewModel.configs, (config: ProviderConfig) => {
              this.configChip(config)
            })
          }
          .padding({ left: 2, right: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }

      Button($r('app.string.model_settings_new_config'))
        .width('100%')
        .height(44)
        .fontSize($r('app.float.home_body_font_size'))
        .fontColor($r('app.color.model_settings_accent'))
        .backgroundColor($r('app.color.model_settings_chip_bg'))
        .borderRadius(8)
        .margin({ top: 8 })
        .onClick(() => {
          if (this.viewModel !== null) {
            this.viewModel.startCreate();
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  configChip(config: ProviderConfig) {
    Column() {
      Row() {
        Text(config.name)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor(this.viewModel !== null && this.viewModel.selectedConfigId === config.id
            ? $r('app.color.model_settings_accent') : $r('app.color.page_primary_text'))
          .fontWeight(this.viewModel !== null && this.viewModel.selectedConfigId === config.id
            ? FontWeight.Bold : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (this.viewModel !== null && this.viewModel.currentConfigId === config.id) {
          Text($r('app.string.model_settings_current_badge'))
            .fontSize($r('app.float.home_caption_font_size'))
            .fontColor($r('app.color.model_settings_accent'))
            .margin({ left: 4 })
        }
      }
      .width('100%')

      Text(config.modelName)
        .fontSize($r('app.float.home_caption_font_size'))
        .fontColor($r('app.color.page_secondary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.viewModel !== null && this.viewModel.selectedConfigId === config.id
      ? $r('app.color.model_settings_selected_bg') : $r('app.color.model_settings_chip_bg'))
    .borderRadius(8)
    .onClick(() => {
      if (this.viewModel !== null) {
        this.viewModel.selectConfig(config.id);
      }
    })
  }

  @Builder
  formSection() {
    Column() {
      Text($r('app.string.model_settings_form_title'))
        .fontSize($r('app.float.nav_body_font_size'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.page_primary_text'))
        .margin({ top: 20, bottom: 8 })

      this.fieldLabel($r('app.string.model_settings_name'))
      TextInput({ text: this.viewModel !== null ? this.viewModel.name : '', placeholder: $r('app.string.model_settings_name_placeholder') })
        .width('100%')
        .height(44)
        .fontSize($r('app.float.home_body_font_size'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onChange((v: string) => { if (this.viewModel !== null) { this.viewModel.name = v; } })

      this.fieldLabel($r('app.string.model_settings_provider_type'))
      Select(TYPE_OPTIONS.map((opt: TypeOption): SelectOption => {
        return { value: opt.label };
      }))
        .selected(this.typeIndex())
        .width('100%')
        .height(44)
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onSelect((index: number) => {
          if (this.viewModel !== null && index >= 0 && index < TYPE_OPTIONS.length) {
            this.viewModel.onProviderTypeChange(TYPE_OPTIONS[index].value);
          }
        })

      // 预设模式:隐藏 Base URL,显示模型选择
      if (this.viewModel !== null && this.viewModel.isPresetMode) {
        this.modelSelectSection()
      } else {
        this.fieldLabel($r('app.string.model_settings_base_url'))
        TextInput({ text: this.viewModel !== null ? this.viewModel.baseUrl : '', placeholder: 'https://api.example.com' })
          .width('100%')
          .height(44)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .onChange((v: string) => { if (this.viewModel !== null) { this.viewModel.baseUrl = v; } })

        this.fieldLabel($r('app.string.model_settings_model'))
        TextInput({ text: this.viewModel !== null ? this.viewModel.modelName : '', placeholder: 'gpt-4o' })
          .width('100%')
          .height(44)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .onChange((v: string) => { if (this.viewModel !== null) { this.viewModel.modelName = v; } })
      }

      // API Key:普通输入框 + 页面自行掩码
      this.fieldLabel($r('app.string.model_settings_api_key'))
      if (this.viewModel !== null && this.viewModel.apiKeyConfigured && this.viewModel.selectedConfigId !== null) {
        Text($r('app.string.model_settings_api_key_configured'))
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .margin({ bottom: 4 })
      }
      Row() {
        TextInput({ text: this.getApiKeyDisplay(), placeholder: $r('app.string.model_settings_api_key_placeholder') })
          .type(InputType.Normal)
          .width('100%')
          .height(44)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .copyOption(CopyOptions.None)
          .layoutWeight(1)
          .onChange((v: string) => {
            if (this.viewModel !== null) {
              if (this.viewModel.showApiKey) {
                this.viewModel.apiKey = v;
              } else {
                // 掩码模式:新输入追加到 apiKey
                if (v.length > this.viewModel.apiKey.length) {
                  const added: string = v.substring(this.viewModel.apiKey.length);
                  this.viewModel.apiKey = this.viewModel.apiKey + added;
                } else if (v.length < this.viewModel.apiKey.length) {
                  this.viewModel.apiKey = this.viewModel.apiKey.substring(0, v.length);
                }
              }
            }
          })
        Button(this.viewModel !== null && this.viewModel.showApiKey ? '隐藏' : '显示')
          .width(52)
          .height(44)
          .fontSize(12)
          .fontColor($r('app.color.page_secondary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .margin({ left: 4 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showApiKey = !this.viewModel.showApiKey;
            }
          })
      }
      .width('100%')

      this.fieldLabel($r('app.string.model_settings_temperature'))
      this.numberInput(
        this.viewModel !== null ? this.viewModel.temperature.toString() : '0.7',
        (v: string) => {
          if (this.viewModel !== null) {
            const n: number = parseFloat(v);
            if (!isNaN(n)) { this.viewModel.temperature = n; }
          }
        })

      this.fieldLabel($r('app.string.model_settings_top_p'))
      this.numberInput(
        this.viewModel !== null ? this.viewModel.topP.toString() : '1.0',
        (v: string) => {
          if (this.viewModel !== null) {
            const n: number = parseFloat(v);
            if (!isNaN(n)) { this.viewModel.topP = n; }
          }
        })

      this.fieldLabel($r('app.string.model_settings_max_tokens'))
      this.numberInput(
        this.viewModel !== null ? this.viewModel.maxTokens.toString() : '1024',
        (v: string) => {
          if (this.viewModel !== null) {
            const n: number = parseInt(v, 10);
            if (!isNaN(n)) { this.viewModel.maxTokens = n; }
          }
        })

      Row() {
        Text($r('app.string.model_settings_stream'))
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.viewModel !== null ? this.viewModel.stream : true })
          .onChange((on: boolean) => { if (this.viewModel !== null) { this.viewModel.stream = on; } })
      }
      .width('100%')
      .height(44)
      .margin({ top: 12 })

      Row() {
        Text($r('app.string.model_settings_enabled'))
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.viewModel !== null ? this.viewModel.enabled : true })
          .onChange((on: boolean) => { if (this.viewModel !== null) { this.viewModel.enabled = on; } })
      }
      .width('100%')
      .height(44)
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  modelSelectSection() {
    Column() {
      Text('DeepSeek 模型')
        .fontSize($r('app.float.home_caption_font_size'))
        .fontColor($r('app.color.page_secondary_text'))
        .margin({ top: 12, bottom: 4 })

      if (this.viewModel !== null && this.viewModel.activePreset !== null) {
        ForEach(this.viewModel.activePreset.availableModels, (model: ModelOption, index: number) => {
          Row() {
            Column() {
              Text(model.displayName)
                .fontSize($r('app.float.home_body_font_size'))
                .fontColor(this.viewModel !== null && this.viewModel.selectedModelIndex === index
                  ? $r('app.color.model_settings_accent') : $r('app.color.page_primary_text'))
                .fontWeight(this.viewModel !== null && this.viewModel.selectedModelIndex === index
                  ? FontWeight.Bold : FontWeight.Normal)
              if (model.description !== undefined) {
                Text(model.description)
                  .fontSize($r('app.float.home_caption_font_size'))
                  .fontColor($r('app.color.page_secondary_text'))
                  .margin({ top: 2 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (this.viewModel !== null && this.viewModel.selectedModelIndex === index) {
              Text('✓')
                .fontSize(18)
                .fontColor($r('app.color.model_settings_accent'))
            }
          }
          .width('100%')
          .padding(12)
          .margin({ top: 4 })
          .backgroundColor(this.viewModel !== null && this.viewModel.selectedModelIndex === index
            ? $r('app.color.model_settings_selected_bg') : $r('app.color.model_settings_chip_bg'))
          .borderRadius(8)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.onModelSelect(index);
            }
          })
        })
      }

      // Base URL 只读显示
      Text('Base URL: ' + (this.viewModel !== null ? this.viewModel.baseUrl : ''))
        .fontSize($r('app.float.home_caption_font_size'))
        .fontColor($r('app.color.page_secondary_text'))
        .margin({ top: 8 })

      Text('Model: ' + (this.viewModel !== null ? this.viewModel.modelName : ''))
        .fontSize($r('app.float.home_caption_font_size'))
        .fontColor($r('app.color.page_secondary_text'))
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  fieldLabel(label: Resource) {
    Text(label)
      .fontSize($r('app.float.home_caption_font_size'))
      .fontColor($r('app.color.page_secondary_text'))
      .margin({ top: 12, bottom: 4 })
  }

  @Builder
  numberInput(value: string, onChange: (v: string) => void) {
    TextInput({ text: value })
      .type(InputType.Number)
      .width('100%')
      .height(44)
      .fontSize($r('app.float.home_body_font_size'))
      .fontColor($r('app.color.page_primary_text'))
      .backgroundColor($r('app.color.model_settings_field_bg'))
      .borderRadius(8)
      .onChange(onChange)
  }

  @Builder
  actionsSection() {
    Column() {
      Row({ space: 8 }) {
        Button(this.viewModel !== null && this.viewModel.isSaving ? '保存中…' : $r('app.string.model_settings_save'))
          .width('50%')
          .height(48)
          .fontSize($r('app.float.home_entry_font_size'))
          .fontColor($r('app.color.model_settings_button_text'))
          .backgroundColor($r('app.color.model_settings_accent'))
          .borderRadius(8)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving && !this.viewModel.isTesting)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.save();
            }
          })

        Button(this.viewModel !== null && this.viewModel.isTesting ? '测试中…' : $r('app.string.model_settings_test'))
          .width('50%')
          .height(48)
          .fontSize($r('app.float.home_entry_font_size'))
          .fontColor($r('app.color.model_settings_button_text'))
          .backgroundColor($r('app.color.model_settings_accent'))
          .borderRadius(8)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving && !this.viewModel.isTesting)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.testConnection();
            }
          })
      }
      .width('100%')
      .margin({ top: 16 })

      Row({ space: 8 }) {
        Button($r('app.string.model_settings_set_current'))
          .width('50%')
          .height(44)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving && !this.viewModel.isTesting
            && this.viewModel.selectedConfigId !== null)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.setCurrent();
            }
          })

        Button($r('app.string.model_settings_delete'))
          .width('50%')
          .height(44)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.model_settings_danger'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving && !this.viewModel.isTesting
            && this.viewModel.selectedConfigId !== null)
          .onClick(() => {
            if (this.viewModel !== null) {
              AlertDialog.show({
                title: $r('app.string.model_settings_delete'),
                message: $r('app.string.model_settings_delete_confirm'),
                confirm: {
                  value: $r('app.string.model_settings_delete'),
                  action: () => {
                    if (this.viewModel !== null) {
                      this.viewModel.deleteSelected();
                    }
                  }
                },
                cancel: () => {}
              });
            }
          })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private typeIndex(): number {
    if (this.viewModel === null) {
      return 0;
    }
    const type: ProviderType = this.viewModel.providerType;
    for (let i = 0; i < TYPE_OPTIONS.length; i++) {
      if (TYPE_OPTIONS[i].value === type) {
        return i;
      }
    }
    return 0;
  }

  private getApiKeyDisplay(): string {
    if (this.viewModel === null) {
      return '';
    }
    if (this.viewModel.showApiKey) {
      return this.viewModel.apiKey;
    }
    // 掩码显示圆点
    let result: string = '';
    for (let i = 0; i < this.viewModel.apiKey.length; i++) {
      result += '●';
    }
    return result;
  }
}