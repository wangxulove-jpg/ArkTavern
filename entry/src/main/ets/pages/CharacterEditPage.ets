/**
 * CharacterEditPage 全屏角色编辑页(UI-3B-2)
 * 顶部:返回 + 分段切换(角色/对话) + 保存
 * 角色:图片 / 名称 / 描述 / 性格
 * 对话:System Prompt / 场景 / 开场白
 * 路由参数:{ characterId: string } 编辑模式;undefined 新建模式。
 */

import { CharacterEditViewModel, CharacterEditFormState, emptyFormState, copyFormState, parseCharacterEditRouteParam } from '../viewmodels/CharacterEditViewModel';
import { AppServices } from '../services/AppServices';
import { CharacterImageView } from '../components/CharacterImageView';
import { promptAction, router } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';

const TAB_CHARACTER: number = 0;
const TAB_CONVERSATION: number = 1;

@Entry
@Component
struct CharacterEditPage {
  @State formState: CharacterEditFormState = emptyFormState();
  @State isLoading: boolean = true;
  @State isSaving: boolean = false;
  @State errorMessage: string = '';
  @State activeTab: number = TAB_CHARACTER;
  @State showDiscardDialog: boolean = false;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  private viewModel: CharacterEditViewModel = new CharacterEditViewModel(
    AppServices.getCharacterService()
  );
  private readyHandled: boolean = false;

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  aboutToAppear(): void {
    this.handleReady();
  }

  onBackPress(): boolean {
    if (this.showDiscardDialog) {
      this.showDiscardDialog = false;
      return true;
    }
    if (this.isDirty()) {
      this.showDiscardDialog = true;
      return true;
    }
    return false;
  }

  build() {
    Column() {
        this.topBar()

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
          this.loadingView()
        } else {
          this.contentArea()
        }

        if (this.showDiscardDialog) {
          this.discardDialog()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private handleReady(): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      const params = router.getParams() as Record<string, Object>;
      const param = params?.['param'];
      this.handleDestinationReady(param);
    } catch (e) {
      this.errorMessage = '页面参数错误';
      this.isLoading = false;
    }
  }

  private async handleDestinationReady(param: Object | undefined): Promise<void> {
    const parsed = parseCharacterEditRouteParam(param);

    if (parsed.error !== undefined) {
      this.errorMessage = parsed.error;
      this.isLoading = false;
      return;
    }

    try {
      await this.viewModel.initialize(parsed.characterId);
      this.formState = this.viewModel.getFormState();
      this.isLoading = false;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '加载失败';
      this.isLoading = false;
    }
  }

  // ===== 顶部固定栏 =====
  @Builder
  topBar() {
    Row() {
      Button($r('app.string.character_edit_back'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_text_primary'))
        .height(40)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          this.handleBack();
        })

      Blank()
      this.segmentedControl()
      Blank()

      Button($r('app.string.character_edit_save'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.canSave() ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .fontColor(this.canSave() ? $r('app.color.app_on_accent') : $r('app.color.app_text_tertiary'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 16, right: 16 })
        .enabled(this.canSave())
        .onClick(() => {
          this.handleSave();
        })
    }
    .width('100%')
    .padding({ left: 8, right: 12, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  segmentedControl() {
    Row() {
      Text($r('app.string.character_edit_tab_character'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_CHARACTER ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_CHARACTER ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
        .backgroundColor(this.activeTab === TAB_CHARACTER ? $r('app.color.app_accent') : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32).padding({ left: 16, right: 16 }).textAlign(TextAlign.Center)
        .onClick(() => { this.activeTab = TAB_CHARACTER; })
      Text($r('app.string.character_edit_tab_conversation'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_CONVERSATION ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_CONVERSATION ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
        .backgroundColor(this.activeTab === TAB_CONVERSATION ? $r('app.color.app_accent') : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32).padding({ left: 16, right: 16 }).margin({ left: 4 }).textAlign(TextAlign.Center)
        .onClick(() => { this.activeTab = TAB_CONVERSATION; })
    }
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_md'))
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 主内容区 =====
  @Builder
  contentArea() {
    if (this.activeTab === TAB_CHARACTER) {
      this.characterTab()
    } else {
      this.conversationTab()
    }
  }

  // ===== "角色"分段 =====
  @Builder
  characterTab() {
    Scroll() {
      Column() {
        this.imageSection()

        this.textFieldRow(
          $r('app.string.character_edit_field_name'),
          $r('app.string.character_edit_field_name_placeholder'),
          true,
          this.formState.nameInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.nameInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_description'),
          $r('app.string.character_edit_field_description_placeholder'),
          $r('app.string.character_edit_field_description_hint'),
          this.formState.descriptionInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.descriptionInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_personality'),
          $r('app.string.character_edit_field_personality_placeholder'),
          undefined,
          this.formState.personalityInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.personalityInput = value;
            this.formState = updated;
          }
        )
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
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

  /** 角色图片区域 */
  @Builder
  imageSection() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.formState.avatarUriInput.length > 0) {
        CharacterImageView({
          imageUri: this.formState.avatarUriInput,
          fallbackName: this.formState.nameInput,
          imgWidth: 160,
          imgHeight: 220,
          imgBorderRadius: $r('app.float.app_radius_lg'),
          displayMode: 'portrait',
          objectFit: ImageFit.Cover
        })
      } else {
        Column() {
          Text($r('app.string.character_edit_image_placeholder'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .textAlign(TextAlign.Center)
        }
        .width(160)
        .height(220)
        .borderRadius($r('app.float.app_radius_lg'))
        .backgroundColor($r('app.color.app_surface_2'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Button() {
        Text('✎')
          .fontSize(18)
          .fontColor($r('app.color.app_on_accent'))
      }
      .width(36)
      .height(36)
      .backgroundColor($r('app.color.app_accent'))
      .borderRadius(18)
      .margin({ right: 8, bottom: 8 })
      .enabled(!this.isSaving && !this.isLoading && this.viewModel.isEditing)
      .onClick(() => {
        this.openAvatarPicker();
      })
    }
    .width(160)
    .height(220)
    .margin({ top: 8, bottom: 24 })
    .alignSelf(ItemAlign.Center)
  }

  // ===== "对话"分段 =====
  @Builder
  conversationTab() {
    Scroll() {
      Column() {
        this.multilineField(
          $r('app.string.character_edit_field_system_prompt'),
          $r('app.string.character_edit_field_system_prompt_placeholder'),
          $r('app.string.character_edit_field_system_prompt_hint'),
          this.formState.systemPromptInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.systemPromptInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_scenario'),
          $r('app.string.character_edit_field_scenario_placeholder'),
          $r('app.string.character_edit_field_scenario_hint'),
          this.formState.scenarioInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.scenarioInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_first_message'),
          $r('app.string.character_edit_field_first_message_placeholder'),
          $r('app.string.character_edit_field_first_message_hint'),
          this.formState.firstMessageInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.firstMessageInput = value;
            this.formState = updated;
          }
        )
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
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

  // ===== 字段组件 =====
  /** 单行文本字段 */
  @Builder
  textFieldRow(
    labelResource: Resource,
    placeholderResource: Resource,
    required: boolean,
    value: string,
    onChange: (value: string) => void
  ) {
    Column() {
      Row() {
        Text(labelResource)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
        if (required) {
          Text($r('app.string.character_edit_field_required_hint'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontColor($r('app.color.app_danger'))
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      TextInput({ placeholder: placeholderResource, text: value })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .padding({ left: 16, right: 16 })
        .onChange(onChange)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  /** 多行文本字段 */
  @Builder
  multilineField(
    labelResource: Resource,
    placeholderResource: Resource,
    hintResource: Resource | undefined,
    value: string,
    onChange: (value: string) => void
  ) {
    Column() {
      Row() {
        Text(labelResource)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      TextArea({ placeholder: placeholderResource, text: value })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(120)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onChange(onChange)

      if (hintResource !== undefined) {
        Text(hintResource)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 6 })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  // ===== 加载视图 =====
  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.app_accent'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 放弃修改确认弹窗 =====
  @Builder
  discardDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.character_edit_unsaved_title'))
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })
          Text($r('app.string.character_edit_unsaved_message'))
            .fontSize(14).fontColor($r('app.color.app_text_secondary'))
            .margin({ bottom: 20 })
          Row() {
            Button($r('app.string.character_edit_unsaved_stay'))
              .fontSize(14).backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1).height(40)
              .onClick(() => { this.showDiscardDialog = false; })
            Button($r('app.string.character_edit_unsaved_discard'))
              .fontSize(14).backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White).borderRadius(20)
              .layoutWeight(1).height(40).margin({ left: 12 })
              .onClick(() => { this.showDiscardDialog = false; this.popBack(); })
          }.width('100%')
        }
        .width('80%').padding(20).backgroundColor($r('app.color.app_surface_1')).borderRadius(16)
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 业务逻辑 =====
  private isDirty(): boolean {
    if (this.isLoading || this.isSaving) {
      return false;
    }
    return this.viewModel.isDirty(this.formState);
  }

  private canSave(): boolean {
    if (this.isSaving || this.isLoading) {
      return false;
    }
    return this.formState.nameInput.trim().length > 0;
  }

  /**
   * 打开系统文件选择器选择头像图片。
   * - 支持 PNG / JPG / JPEG / WebP / BMP / GIF,单选
   * - 取消返回空数组,不修改任何内容
   * - 选中后调 viewModel.changeAvatar 即时落库(CharacterAssetStore 保留源扩展名)
   * - 失败时旧头像仍可用,显示 errorMessage
   * - 新建模式下按钮已禁用,这里再防御性校验
   */
  private async openAvatarPicker(): Promise<void> {
    if (!this.viewModel.isEditing) {
      promptAction.showToast({
        message: $r('app.string.character_edit_image_edit_hint'),
        duration: 2000
      });
      return;
    }
    if (this.isSaving || this.isLoading) {
      return;
    }
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'];
      uris = await documentPicker.select(options);
    } catch (e) {
      // picker 调用本身失败(权限/系统错误),不修改任何内容
      this.errorMessage = '打开文件选择器失败: ' + (e as Error).message;
      return;
    }
    // 用户取消选择,不修改任何内容
    if (uris.length === 0) {
      return;
    }
    this.isSaving = true;
    try {
      await this.viewModel.changeAvatar(uris[0]);
      // 刷新表单头像 URI(originalCharacter 已更新,getFormState 返回新 avatarUri)
      this.formState = this.viewModel.getFormState();
      this.errorMessage = '';
      // 通知首页刷新(CharacterRootView 作为 TabContent 不会触发 onPageShow)
      this.bumpListVersion();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '头像更新失败';
    } finally {
      this.isSaving = false;
    }
  }

  /** 递增 characterListVersion,通知首页 CharacterRootView 重新 load() */
  private bumpListVersion(): void {
    const v: number = AppStorage.get<number>('characterListVersion') ?? 0;
    AppStorage.setOrCreate<number>('characterListVersion', v + 1);
  }

  private handleBack(): void {
    if (this.isDirty()) {
      this.showDiscardDialog = true;
      return;
    }
    this.popBack();
  }

  private async handleSave(): Promise<void> {
    if (!this.canSave() || this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      await this.viewModel.save(this.formState);
      this.bumpListVersion();
      this.popBack();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '保存失败';
    } finally {
      this.isSaving = false;
    }
  }

  private popBack(): void {
    router.back();
  }
}
