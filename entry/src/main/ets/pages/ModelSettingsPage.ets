/**
 * ModelSettingsPage 模型设置页面
 *
 * 正式模型配置页面,提供:
 * - 配置列表(显示全部配置,当前配置有标记)
 * - 编辑表单(名称/Provider/Base URL/Model/API Key/参数)
 * - 操作(保存/测试连接/设为当前/删除)
 *
 * 页面只通过 ModelSettingsViewModel 调用 ModelService,不直接接触 Store/Provider。
 * API Key 使用密码输入控件,不显示原密钥,保存/测试后立即清空。
 */

import { ModelSettingsViewModel } from '../viewmodels/ModelSettingsViewModel';
import { AppServices } from '../services/AppServices';
import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';

/** Provider 类型选项 */
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
        this.mainView(this.viewModel)
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
  mainView(vm: ModelSettingsViewModel) {
    Scroll() {
      Column() {
        this.configListSection(vm)
        this.formSection(vm)
        this.actionsSection(vm)
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
  configListSection(vm: ModelSettingsViewModel) {
    Column() {
      Text($r('app.string.model_settings_config_list'))
        .fontSize($r('app.float.nav_body_font_size'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.page_primary_text'))
        .margin({ top: 12, bottom: 8 })

      if (vm.configs.length === 0) {
        Text($r('app.string.model_settings_no_configs'))
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .padding(12)
      } else {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(vm.configs, (config: ProviderConfig) => {
              this.configChip(vm, config)
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
          vm.startCreate();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  configChip(vm: ModelSettingsViewModel, config: ProviderConfig) {
    Column() {
      Row() {
        Text(config.name)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor(vm.selectedConfigId === config.id
            ? $r('app.color.model_settings_accent') : $r('app.color.page_primary_text'))
          .fontWeight(vm.selectedConfigId === config.id ? FontWeight.Bold : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (vm.currentConfigId === config.id) {
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
    .backgroundColor(vm.selectedConfigId === config.id
      ? $r('app.color.model_settings_selected_bg') : $r('app.color.model_settings_chip_bg'))
    .borderRadius(8)
    .onClick(() => {
      vm.selectConfig(config.id);
    })
  }

  @Builder
  formSection(vm: ModelSettingsViewModel) {
    Column() {
      Text($r('app.string.model_settings_form_title'))
        .fontSize($r('app.float.nav_body_font_size'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.page_primary_text'))
        .margin({ top: 20, bottom: 8 })

      this.fieldLabel($r('app.string.model_settings_name'))
      TextInput({ text: vm.name, placeholder: $r('app.string.model_settings_name_placeholder') })
        .width('100%')
        .height(44)
        .fontSize($r('app.float.home_body_font_size'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onChange((v: string) => { vm.name = v; })

      this.fieldLabel($r('app.string.model_settings_provider_type'))
      Select(TYPE_OPTIONS.map((opt: TypeOption): SelectOption => {
        return { value: opt.label };
      }))
        .selected(this.typeIndex(vm.providerType))
        .width('100%')
        .height(44)
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onSelect((index: number) => {
          if (index >= 0 && index < TYPE_OPTIONS.length) {
            vm.providerType = TYPE_OPTIONS[index].value;
          }
        })

      this.fieldLabel($r('app.string.model_settings_base_url'))
      TextInput({ text: vm.baseUrl, placeholder: 'https://api.example.com' })
        .width('100%')
        .height(44)
        .fontSize($r('app.float.home_body_font_size'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onChange((v: string) => { vm.baseUrl = v; })

      this.fieldLabel($r('app.string.model_settings_model'))
      TextInput({ text: vm.modelName, placeholder: 'gpt-4o / deepseek-chat' })
        .width('100%')
        .height(44)
        .fontSize($r('app.float.home_body_font_size'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onChange((v: string) => { vm.modelName = v; })

      this.fieldLabel($r('app.string.model_settings_api_key'))
      if (vm.apiKeyConfigured && vm.selectedConfigId !== null) {
        Text($r('app.string.model_settings_api_key_configured'))
          .fontSize($r('app.float.home_caption_font_size'))
          .fontColor($r('app.color.page_secondary_text'))
          .margin({ bottom: 4 })
      }
      TextInput({ text: vm.apiKey, placeholder: $r('app.string.model_settings_api_key_placeholder') })
        .type(InputType.Password)
        .width('100%')
        .height(44)
        .fontSize($r('app.float.home_body_font_size'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.model_settings_field_bg'))
        .borderRadius(8)
        .onChange((v: string) => { vm.apiKey = v; })

      this.fieldLabel($r('app.string.model_settings_temperature'))
      this.numberInput(vm.temperature.toString(), (v: string) => {
        const n: number = parseFloat(v);
        if (!isNaN(n)) { vm.temperature = n; }
      })

      this.fieldLabel($r('app.string.model_settings_top_p'))
      this.numberInput(vm.topP.toString(), (v: string) => {
        const n: number = parseFloat(v);
        if (!isNaN(n)) { vm.topP = n; }
      })

      this.fieldLabel($r('app.string.model_settings_max_tokens'))
      this.numberInput(vm.maxTokens.toString(), (v: string) => {
        const n: number = parseInt(v, 10);
        if (!isNaN(n)) { vm.maxTokens = n; }
      })

      Row() {
        Text($r('app.string.model_settings_stream'))
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: vm.stream })
          .onChange((on: boolean) => { vm.stream = on; })
      }
      .width('100%')
      .height(44)
      .margin({ top: 12 })

      Row() {
        Text($r('app.string.model_settings_enabled'))
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: vm.enabled })
          .onChange((on: boolean) => { vm.enabled = on; })
      }
      .width('100%')
      .height(44)
      .margin({ top: 8 })
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
  actionsSection(vm: ModelSettingsViewModel) {
    Column() {
      if (vm.statusMessage.length > 0) {
        Text(vm.statusMessage)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.model_settings_success'))
          .margin({ top: 16, bottom: 4 })
      }
      if (vm.errorMessage.length > 0) {
        Text(vm.errorMessage)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.model_settings_danger'))
          .margin({ top: 16, bottom: 4 })
      }

      Row({ space: 8 }) {
        Button($r('app.string.model_settings_save'))
          .width('50%')
          .height(48)
          .fontSize($r('app.float.home_entry_font_size'))
          .fontColor($r('app.color.model_settings_button_text'))
          .backgroundColor($r('app.color.model_settings_accent'))
          .borderRadius(8)
          .enabled(!vm.isSaving && !vm.isTesting)
          .onClick(() => { vm.save(); })

        Button($r('app.string.model_settings_test'))
          .width('50%')
          .height(48)
          .fontSize($r('app.float.home_entry_font_size'))
          .fontColor($r('app.color.model_settings_button_text'))
          .backgroundColor($r('app.color.model_settings_accent'))
          .borderRadius(8)
          .enabled(!vm.isSaving && !vm.isTesting)
          .onClick(() => { vm.testConnection(); })
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
          .enabled(!vm.isSaving && !vm.isTesting && vm.selectedConfigId !== null)
          .onClick(() => { vm.setCurrent(); })

        Button($r('app.string.model_settings_delete'))
          .width('50%')
          .height(44)
          .fontSize($r('app.float.home_body_font_size'))
          .fontColor($r('app.color.model_settings_danger'))
          .backgroundColor($r('app.color.model_settings_field_bg'))
          .borderRadius(8)
          .enabled(!vm.isSaving && !vm.isTesting && vm.selectedConfigId !== null)
          .onClick(() => {
            AlertDialog.show({
              title: $r('app.string.model_settings_delete'),
              message: $r('app.string.model_settings_delete_confirm'),
              confirm: {
                value: $r('app.string.model_settings_delete'),
                action: () => {
                  vm.deleteSelected();
                }
              },
              cancel: () => {}
            });
          })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 根据 ProviderType 返回选项索引。
   */
  private typeIndex(type: ProviderType): number {
    for (let i = 0; i < TYPE_OPTIONS.length; i++) {
      if (TYPE_OPTIONS[i].value === type) {
        return i;
      }
    }
    return 0;
  }
}
