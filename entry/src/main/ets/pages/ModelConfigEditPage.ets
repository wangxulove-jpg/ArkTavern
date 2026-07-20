/**
 * ModelConfigEditPage 模型配置编辑页
 *
 * UI-2 新增页面,负责新建/编辑模型配置的完整表单。
 * 页面只通过 ModelSettingsViewModel 访问业务,不直接调用 Store/网络。
 *
 * 结构:
 * - 顶部导航栏:返回、标题(新建/编辑)、保存按钮
 * - 一级 Tab 切换:连接 / 参数
 * - 连接区域:名称、服务商(Sheet)、API Key、模型(Sheet/输入)、Base URL、测试连接
 * - 参数区域:Temperature、Top P、Max Tokens、流式请求、启用
 * - 底部危险操作区:删除(仅编辑)
 *
 * 安全:
 * - API Key 不回显,编辑时只显示"已配置"
 * - 不在页面状态中长期保留历史 Key
 * - 不显示完整 Base URL
 */

import { ModelSettingsViewModel } from '../viewmodels/ModelSettingsViewModel';
import { ProviderType } from '../models/ProviderType';
import { ModelOption } from '../models/ProviderPreset';
import { router } from '@kit.ArkUI';

interface ProviderOption {
  readonly type: ProviderType;
  readonly displayName: string;
}

const PROVIDER_OPTIONS: ProviderOption[] = [
  { type: ProviderType.OpenAICompatible, displayName: 'OpenAI Compatible' },
  { type: ProviderType.DeepSeek, displayName: 'DeepSeek' }
];

const MAX_NAME_LENGTH: number = 32;

@Entry
@Component
struct ModelConfigEditPage {
  @State viewModel: ModelSettingsViewModel | null = null;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  aboutToAppear(): void {
    this.viewModel = AppStorage.get<ModelSettingsViewModel>('ModelSettingsViewModel') ?? null;
  }

  build() {
    Stack() {
      if (this.viewModel === null) {
        this.loadingView()
      } else {
        this.mainView()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  mainView() {
    // 用 Stack 包裹 Column,把 Provider Sheet 与 Model Sheet 拆到不同容器上,
    // 避免同一组件挂多个 bindSheet 时后定义者覆盖前者的状态绑定。
    Stack() {
      Column() {
        // 顶部标题栏:返回 + 标题 + 保存
        Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.page_primary_text')])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Text(this.pageTitle())
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8, right: 8 })

        Button({ type: ButtonType.Capsule }) {
          Text(this.viewModel!.isSaving ? $r('app.string.model_settings_saving') : $r('app.string.model_settings_save'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
        }
        .height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.app_accent'))
        .enabled(this.isFormReady() && !this.viewModel!.isSaving && !this.viewModel!.isTesting)
        .onClick(async () => {
          if (!this.viewModel!.checkFormValid()) {
            return;
          }
          await this.viewModel!.save();
          if (this.viewModel!.errorMessage.length === 0) {
            router.back();
          }
        })
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Tabs({ barPosition: BarPosition.Start, index: this.viewModel!.activeEditTab }) {
        TabContent() {
          this.connectionTabContent()
        }
        .tabBar($r('app.string.model_settings_connection'))

        TabContent() {
          this.parametersTabContent()
        }
        .tabBar($r('app.string.model_settings_parameters'))
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barHeight(48)
      .width('100%')
      .layoutWeight(1)
      .backgroundColor($r('app.color.page_background'))
      .onChange((index: number) => {
        this.viewModel!.setActiveEditTab(index);
      })

      this.dangerActionArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet(this.viewModel!.modelSheetOpen, this.modelSheetBuilder, {
      height: SheetSize.MEDIUM,
      mode: SheetMode.EMBEDDED,
      dragBar: false,
      showClose: false,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        this.viewModel!.closeModelSheet();
      }
    })
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.viewModel!.providerSheetOpen, this.providerSheetBuilder, {
      height: SheetSize.MEDIUM,
      mode: SheetMode.EMBEDDED,
      dragBar: false,
      showClose: false,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        this.viewModel!.closeProviderSheet();
      }
    })
  }

  @Builder
  connectionTabContent() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        // 配置名称
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_name'))
          TextInput({
            text: this.viewModel!.name,
            placeholder: $r('app.string.model_settings_name_placeholder')
          })
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .maxLength(MAX_NAME_LENGTH)
            .showError(this.viewModel!.nameError.length > 0 ? this.viewModel!.nameError : undefined)
            .onChange((v: string) => {
              this.viewModel!.name = v;
              if (this.viewModel!.nameError.length > 0) {
                this.viewModel!.nameError = '';
              }
            })
        }

        // API 服务商
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_provider'))
          this.selectableRow(
            () => this.providerDisplayName(),
            () => {
              this.viewModel!.openProviderSheet();
            }
          )
        }

        // API Key
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_api_key'))
          if (this.viewModel!.selectedConfigId !== null && this.viewModel!.apiKeyConfigured) {
            Text($r('app.string.model_settings_api_key_status_configured'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .margin({ bottom: 4 })
          }
          Row() {
            TextInput({
              text: this.viewModel!.apiKey,
              placeholder: this.viewModel!.selectedConfigId === null
                ? $r('app.string.model_settings_api_key_placeholder')
                : $r('app.string.model_settings_api_key_configured')
            })
              .type(this.viewModel!.showApiKey ? InputType.Normal : InputType.Password)
              .width('100%')
              .height(48)
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 12, right: 12 })
              .copyOption(CopyOptions.None)
              .layoutWeight(1)
              .showError(this.viewModel!.apiKeyError.length > 0 ? this.viewModel!.apiKeyError : undefined)
              .onChange((v: string) => {
                this.viewModel!.apiKey = v;
                if (this.viewModel!.apiKeyError.length > 0) {
                  this.viewModel!.apiKeyError = '';
                }
              })

            Button(this.viewModel!.showApiKey ? $r('app.string.model_settings_hide_key') : $r('app.string.model_settings_show_key'))
              .width(72)
              .height(48)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .margin({ left: 8 })
              .onClick(() => {
                this.viewModel!.showApiKey = !this.viewModel!.showApiKey;
              })
          }
          .width('100%')
        }

        // 模型
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_model'))
          if (this.viewModel!.isPresetMode) {
            this.selectableRow(
              () => this.modelDisplayName(),
              () => {
                this.viewModel!.openModelSheet();
              }
            )
          } else {
            TextInput({
              text: this.viewModel!.modelName,
              placeholder: 'gpt-4o'
            })
              .width('100%')
              .height(48)
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => {
                this.viewModel!.modelName = v;
              })
          }
        }

        // Base URL
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_base_url_summary'))
          if (this.viewModel!.isPresetMode) {
            Row() {
              Text($r('app.string.model_settings_base_url_auto'))
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_text_secondary'))
              Blank()
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(18)
                .fontColor([$r('app.color.app_accent')])
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
          } else {
            TextInput({
              text: this.viewModel!.baseUrl,
              placeholder: 'https://api.example.com'
            })
              .width('100%')
              .height(48)
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => {
                this.viewModel!.baseUrl = v;
              })
          }
        }

        // 测试连接
        Button(this.viewModel!.isTesting ? $r('app.string.model_settings_testing') : $r('app.string.model_settings_test'))
          .width('100%')
          .height(48)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .enabled(this.isFormReady() && !this.viewModel!.isSaving && !this.viewModel!.isTesting)
          .margin({ top: 8 })
          .onClick(() => {
            if (this.viewModel!.checkFormValid()) {
              this.viewModel!.testConnection();
            }
          })

        // 设为当前(仅编辑非当前配置)
        if (this.viewModel!.selectedConfigId !== null
          && this.viewModel!.selectedConfigId !== this.viewModel!.currentConfigId) {
          Button($r('app.string.model_settings_set_current'))
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_accent'))
            .backgroundColor($r('app.color.app_accent_surface'))
            .borderRadius($r('app.float.app_radius_sm'))
            .enabled(!this.viewModel!.isSaving && !this.viewModel!.isTesting)
            .margin({ top: 8 })
            .onClick(async () => {
              await this.viewModel!.setCurrent();
            })
        }

        Blank().height(24)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  parametersTabContent() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        Text($r('app.string.model_settings_param_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .padding({ top: 4, bottom: 4 })

        // Temperature(需要小数,使用 Normal 输入类型并在 onChange 校验)
        FormSection() {
          this.fieldLabelWithHint($r('app.string.model_settings_temperature'), $r('app.string.model_settings_temperature_range'))
          TextInput({ text: this.viewModel!.temperature.toString() })
            .type(InputType.Normal)
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.viewModel!.temperature = n;
              }
            })
        }

        // Top P(需要小数,使用 Normal 输入类型)
        FormSection() {
          this.fieldLabelWithHint($r('app.string.model_settings_top_p'), $r('app.string.model_settings_top_p_range'))
          TextInput({ text: this.viewModel!.topP.toString() })
            .type(InputType.Normal)
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.viewModel!.topP = n;
              }
            })
        }

        // Max Tokens
        FormSection() {
          this.fieldLabelWithHint($r('app.string.model_settings_max_tokens'), $r('app.string.model_settings_max_tokens_desc'))
          TextInput({ text: this.viewModel!.maxTokens.toString() })
            .type(InputType.Number)
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              const n: number = parseInt(v, 10);
              if (!isNaN(n)) {
                this.viewModel!.maxTokens = n;
              }
            })
        }

        // 流式请求
        this.toggleRow(
          $r('app.string.model_settings_stream'),
          $r('app.string.model_settings_stream_desc'),
          this.viewModel!.stream,
          (on: boolean) => {
            this.viewModel!.stream = on;
          }
        )

        // 启用
        this.toggleRow(
          $r('app.string.model_settings_enabled'),
          $r('app.string.model_settings_enabled_desc'),
          this.viewModel!.enabled,
          (on: boolean) => {
            this.viewModel!.enabled = on;
          }
        )

        Blank().height(24)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  dangerActionArea() {
    if (this.viewModel!.selectedConfigId !== null) {
      Column() {
        Button($r('app.string.model_settings_delete'))
          .width('100%')
          .height(48)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_danger'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .enabled(!this.viewModel!.isSaving && !this.viewModel!.isTesting)
          .onClick(() => {
            AlertDialog.show({
              title: $r('app.string.model_settings_delete'),
              message: $r('app.string.model_settings_delete_confirm'),
              primaryButton: {
                value: $r('app.string.model_settings_delete'),
                fontColor: $r('app.color.app_danger'),
                action: async () => {
                  await this.viewModel!.deleteSelected();
                  if (this.viewModel!.errorMessage.length === 0) {
                    router.back();
                  }
                }
              },
              secondaryButton: {
                value: $r('app.string.character_form_cancel'),
                action: () => {}
              }
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.navigationBarHeight + 24 })
      .backgroundColor($r('app.color.page_background'))
    }
  }

  @Builder
  providerSheetBuilder() {
    Column() {
      Row() {
        Text($r('app.string.model_settings_provider_sheet_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_secondary')])
          .onClick(() => {
            this.viewModel!.closeProviderSheet();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      List({ space: 4 }) {
        ForEach(PROVIDER_OPTIONS, (option: ProviderOption) => {
          ListItem() {
            Row() {
              Column() {
                Text(option.displayName)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor(this.viewModel!.providerType === option.type
                    ? $r('app.color.app_accent') : $r('app.color.app_text_primary'))
                  .fontWeight(this.viewModel!.providerType === option.type
                    ? FontWeight.Medium : FontWeight.Normal)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.viewModel!.providerType === option.type) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(20)
                  .fontColor([$r('app.color.app_accent')])
              }
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.viewModel!.providerType === option.type
              ? $r('app.color.app_accent_surface') : $r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_sm'))
            .onClick(() => {
              this.viewModel!.selectProviderFromSheet(option.type);
            })
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_surface_1'))
    .padding({ bottom: 24 })
  }

  @Builder
  modelSheetBuilder() {
    Column() {
      Row() {
        Text($r('app.string.model_settings_model_sheet_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_secondary')])
          .onClick(() => {
            this.viewModel!.closeModelSheet();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel!.activePreset !== null) {
        List({ space: 4 }) {
          ForEach(this.viewModel!.activePreset.availableModels, (model: ModelOption, index: number) => {
            ListItem() {
              Row() {
                Column() {
                  Text(model.displayName)
                    .fontSize($r('app.float.app_font_body'))
                    .fontColor(index === this.viewModel!.selectedModelIndex
                      ? $r('app.color.app_accent') : $r('app.color.app_text_primary'))
                    .fontWeight(index === this.viewModel!.selectedModelIndex
                      ? FontWeight.Medium : FontWeight.Normal)
                  if (model.description !== undefined) {
                    Text(model.description)
                      .fontSize($r('app.float.app_font_caption'))
                      .fontColor($r('app.color.app_text_secondary'))
                      .margin({ top: 2 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (index === this.viewModel!.selectedModelIndex) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(20)
                    .fontColor([$r('app.color.app_accent')])
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor(index === this.viewModel!.selectedModelIndex
                ? $r('app.color.app_accent_surface') : $r('app.color.app_surface_1'))
              .borderRadius($r('app.float.app_radius_sm'))
              .onClick(() => {
                this.viewModel!.selectModelFromSheet(index);
              })
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_surface_1'))
    .padding({ bottom: 24 })
  }

  @Builder
  fieldLabel(label: Resource) {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_secondary'))
      .margin({ bottom: 6 })
  }

  @Builder
  fieldLabelWithHint(label: Resource, hint: Resource) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(' · ')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
      Text(hint)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
    }
    .margin({ bottom: 6 })
  }

  @Builder
  selectableRow(valueProvider: () => string, onClick: () => void) {
    Row() {
      if (valueProvider().length > 0) {
        Text(valueProvider())
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
      } else {
        Text($r('app.string.model_settings_select_provider_hint'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_tertiary'))
          .layoutWeight(1)
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([$r('app.color.app_text_tertiary')])
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(onClick)
  }

  @Builder
  toggleRow(title: Resource, desc: Resource, isOn: boolean, onChange: (on: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
        Text(desc)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .onClick(() => {
      onChange(!isOn);
    })
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

  private pageTitle(): Resource {
    return this.viewModel!.selectedConfigId === null
      ? $r('app.string.model_settings_new_title')
      : $r('app.string.model_settings_edit_title');
  }

  private providerDisplayName(): string {
    for (let i = 0; i < PROVIDER_OPTIONS.length; i++) {
      if (PROVIDER_OPTIONS[i].type === this.viewModel!.providerType) {
        return PROVIDER_OPTIONS[i].displayName;
      }
    }
    return '';
  }

  private modelDisplayName(): string {
    if (this.viewModel!.activePreset === null) {
      return this.viewModel!.modelName;
    }
    if (this.viewModel!.selectedModelIndex >= 0
      && this.viewModel!.selectedModelIndex < this.viewModel!.activePreset.availableModels.length) {
      return this.viewModel!.activePreset.availableModels[this.viewModel!.selectedModelIndex].displayName;
    }
    return this.viewModel!.modelName;
  }

  private isFormReady(): boolean {
    if (this.viewModel === null) {
      return false;
    }
    if (this.viewModel!.isSaving || this.viewModel!.isTesting) {
      return false;
    }
    if (this.viewModel!.name.trim().length === 0) {
      return false;
    }
    if (!this.viewModel!.isSupportedType(this.viewModel!.providerType)) {
      return false;
    }
    if (this.viewModel!.selectedConfigId === null && this.viewModel!.apiKey.trim().length === 0) {
      return false;
    }
    return true;
  }
}

/**
 * 表单分组容器组件。
 * 通过 @BuilderParam 接收子组件,避免 @Builder 方法传递 Builder 的语法限制。
 */
@Component
struct FormSection {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(HorizontalAlign.Start)
  }
}
