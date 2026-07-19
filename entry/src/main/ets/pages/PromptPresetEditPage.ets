/**
 * PromptPresetEditPage 预设编辑页面
 *
 * 支持新建和编辑预设。
 * 路由参数通过 aboutToAppear 中的 router.getParams() 稳定获取。
 * 表单状态通过 @State formState 快照实现响应式,不依赖 ViewModel 的 @Observed 字段。
 * 每个页面实例持有独立 ViewModel,支持新建和编辑模式切换。
 */

import { PromptPresetEditViewModel, PromptPresetEditFormState, emptyFormState, copyFormState, parsePresetEditRouteParam } from '../viewmodels/PromptPresetEditViewModel';
import { AppServices } from '../services/AppServices';
import { router } from '@kit.ArkUI';

const LOG_TAG: string = 'PromptPresetEditPage';

@Entry
@Component
struct PromptPresetEditPage {
  @State formState: PromptPresetEditFormState = emptyFormState();
  @State isLoading: boolean = true;
  @State isEditing: boolean = false;
  @State errorMessage: string = '';
  @State fieldErrors: Record<string, string> = {};
  @State isSaving: boolean = false;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  private viewModel: PromptPresetEditViewModel = new PromptPresetEditViewModel(
    AppServices.getPromptPresetService()
  );
  private presetId: string | undefined = undefined;
  private readyHandled: boolean = false;

  aboutToAppear(): void {
    this.handleReady(router.getParams());
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button('取消')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            router.back();
          })

        Blank()

        Text(this.isEditing ? '编辑预设' : '新建预设')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)

        Blank()

        Button('保存')
          .fontSize(14)
          .backgroundColor('#007AFF')
          .fontColor(Color.White)
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .enabled(!this.isSaving && this.formState.nameInput.trim().length > 0)
          .onClick(async () => {
            await this.handleSave();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: this.statusBarHeight + 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .height(1)
        .color('#E0E0E0')

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage.length > 0) {
        // 未找到记录或参数错误:显示错误而非空表单
        Column() {
          Text(this.errorMessage)
            .fontSize(14)
            .fontColor('#FF3B30')
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding(16)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // 1. 名称
            this.fieldLabel('名称 *')
            TextInput({ placeholder: '输入预设名称', text: this.formState.nameInput })
              .maxLength(100)
              .onChange((value: string) => {
                const updated = copyFormState(this.formState);
                updated.nameInput = value;
                this.formState = updated;
              })
              .width('100%')
            this.fieldError('name')

            // 2. 描述
            TextInput({ placeholder: '输入描述(可选)', text: this.formState.descriptionInput })
              .maxLength(1000)
              .onChange((value: string) => {
                const updated = copyFormState(this.formState);
                updated.descriptionInput = value;
                this.formState = updated;
              })
              .width('100%')

            // 3. System Prompt
            TextArea({ placeholder: '输入附加 System Prompt(可选)', text: this.formState.systemPromptInput })
              .onChange((value: string) => {
                const updated = copyFormState(this.formState);
                updated.systemPromptInput = value;
                this.formState = updated;
              })
              .width('100%')
              .height(120)
              .maxLength(10000)

            Divider()
              .height(1)
              .color('#E0E0E0')
              .margin({ top: 16, bottom: 8 })

            Text('参数覆盖(可选)')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ bottom: 12 })

            // 4. Temperature
            this.toggleField(
              '覆盖 Temperature',
              '0 ~ 2',
              this.formState.overrideTemperature,
              this.formState.temperatureInput,
              (isOn: boolean) => {
                const updated = copyFormState(this.formState);
                updated.overrideTemperature = isOn;
                updated.temperatureInput = isOn ? this.formState.temperatureInput : '';
                this.formState = updated;
              },
              (value: string) => {
                const updated = copyFormState(this.formState);
                updated.temperatureInput = value;
                this.formState = updated;
              }
            )
            this.fieldError('temperature')

            // 5. Top P
            this.toggleField(
              '覆盖 Top P',
              '0 ~ 1',
              this.formState.overrideTopP,
              this.formState.topPInput,
              (isOn: boolean) => {
                const updated = copyFormState(this.formState);
                updated.overrideTopP = isOn;
                updated.topPInput = isOn ? this.formState.topPInput : '';
                this.formState = updated;
              },
              (value: string) => {
                const updated = copyFormState(this.formState);
                updated.topPInput = value;
                this.formState = updated;
              }
            )
            this.fieldError('topP')

            // 6. maxOutputTokens
            this.toggleField(
              '覆盖最大输出 Token',
              '正整数',
              this.formState.overrideMaxOutputTokens,
              this.formState.maxOutputTokensInput,
              (isOn: boolean) => {
                const updated = copyFormState(this.formState);
                updated.overrideMaxOutputTokens = isOn;
                updated.maxOutputTokensInput = isOn ? this.formState.maxOutputTokensInput : '';
                this.formState = updated;
              },
              (value: string) => {
                const updated = copyFormState(this.formState);
                updated.maxOutputTokensInput = value;
                this.formState = updated;
              }
            )
            this.fieldError('maxOutputTokens')

            // 7. contextWindow
            this.toggleField(
              '覆盖上下文窗口',
              '512 ~ 1000000',
              this.formState.overrideContextWindow,
              this.formState.contextWindowInput,
              (isOn: boolean) => {
                const updated = copyFormState(this.formState);
                updated.overrideContextWindow = isOn;
                updated.contextWindowInput = isOn ? this.formState.contextWindowInput : '';
                this.formState = updated;
              },
              (value: string) => {
                const updated = copyFormState(this.formState);
                updated.contextWindowInput = value;
                this.formState = updated;
              }
            )
            this.fieldError('contextWindow')

            // 全局错误
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor('#FF3B30')
                .width('100%')
                .margin({ top: 16 })
            }
          }
          .width('100%')
          .padding(16)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private handleReady(param: Object | undefined): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      this.handleDestinationReady(param);
    } catch (e) {
      this.errorMessage = '页面参数错误';
      this.isLoading = false;
    }
  }

  private async handleDestinationReady(param: Object | undefined): Promise<void> {
    const parsed = parsePresetEditRouteParam(param);

    if (parsed.error !== undefined) {
      this.errorMessage = parsed.error;
      this.isLoading = false;
      return;
    }

    this.presetId = parsed.presetId;

    // 初始化 ViewModel
    await this.viewModel.initialize(this.presetId);

    // 编辑模式:要检查是否找到记录
    if (this.presetId !== undefined && this.presetId.length > 0) {
      // 加载表单状态
      const fs: PromptPresetEditFormState = await this.viewModel.getFormState(this.presetId);
      // 检查是否为空表单(表示未找到记录)
      const isNotFound: boolean = fs.nameInput.length === 0 && this.presetId.length > 0;
      if (isNotFound) {
        this.errorMessage = '该预设不存在或已被删除';
        this.isEditing = false;
        this.isLoading = false;
        return;
      }
      this.formState = fs;
      this.isEditing = true;
    } else {
      this.formState = emptyFormState();
      this.isEditing = false;
    }

    this.isLoading = false;
  }

  private async handleSave(): Promise<void> {
    this.isSaving = true;
    this.errorMessage = '';
    this.fieldErrors = {};

    const success: boolean = await this.viewModel.save(this.formState);

    if (success) {
      router.back();
    } else {
      this.errorMessage = '保存失败,请检查输入';
    }

    this.isSaving = false;
  }

  @Builder
  fieldLabel(label: string) {
    Text(label)
      .fontSize(14)
      .fontColor('#333333')
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ top: 16, bottom: 6 })
  }

  @Builder
  fieldError(key: string) {
    if (this.fieldErrors[key] !== undefined) {
      Text(this.fieldErrors[key])
        .fontSize(12)
        .fontColor('#FF3B30')
        .width('100%')
        .margin({ top: 4 })
    }
  }

  @Builder
  toggleField(
    label: string,
    hint: string,
    enabled: boolean,
    inputValue: string,
    onToggle: (isOn: boolean) => void,
    onInputChange: (value: string) => void
  ) {
    Column() {
      Row() {
        Text(label)
          .fontSize(14)
          .fontColor('#333333')
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: enabled })
          .onChange((isOn: boolean) => {
            onToggle(isOn);
          })
      }
      .width('100%')
      .margin({ top: 12 })

      if (enabled) {
        TextInput({ placeholder: hint, text: inputValue })
          .type(InputType.Number)
          .onChange((value: string) => {
            onInputChange(value);
          })
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
  }
}
