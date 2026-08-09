/**
 * GroupChatCreatePage 创建多人聊天(G-DATA-1B 正式版)
 *
 * 数据来源:
 * - 角色列表:CharacterService(真实数据库)
 * - 创建群聊:GroupConversationPersistenceService.createGroupConversation
 *
 * 两步式创建流程:
 * - 步骤 1:选择角色(最少 2,最多 8,按选择顺序确定 speakerOrder)
 * - 步骤 2:群聊名称 + 顺序调整 + 创建并进入聊天
 *
 * 不依赖:GroupChatPreviewStore / PREVIEW_CHARACTERS。
 * 创建成功后路由只传 chatId(通过 AppStorage),不传完整对象。
 */

import { router, promptAction } from '@kit.ArkUI';
import { CharacterImageView } from '../../components/CharacterImageView';
import { AppServices } from '../../services/AppServices';
import {
  GroupChatCreateViewModel,
  MIN_MEMBER_COUNT,
  MAX_MEMBER_COUNT
} from '../../viewmodels/groupchat/GroupChatCreateViewModel';
import { CharacterPickState, PENDING_GROUP_CHAT_ID_KEY } from '../../viewmodels/groupchat/GroupChatUiModels';
import { Character } from '../../models/Character';
import { ThemePalette } from '../../theme/ThemePalette';

@Entry
@Component
struct GroupChatCreatePage {
  /** 当前步骤:1=选择角色,2=群聊配置 */
  @State step: number = 1;
  /** 搜索关键词 */
  @State searchKeyword: string = '';
  /** 已选角色 ID 列表(按选择顺序) */
  @State selectedIds: string[] = [];
  /** 步骤二:群聊名称输入值 */
  @State chatNameInput: string = '';
  /** 步骤二:是否已用自定义名称(为 true 时不自动覆盖) */
  @State nameCustomized: boolean = false;
  /** 角色列表 */
  @State characters: Character[] = [];
  /** 角色列表加载状态 */
  @State pickState: CharacterPickState = CharacterPickState.Loading;
  /** 是否正在创建(防止重复提交) */
  @State isCreating: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private viewModel: GroupChatCreateViewModel | null = null;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupChatCreateViewModel();
      await this.viewModel.loadCharacters();
      this.syncFromViewModel();
    } catch (e) {
      this.pickState = CharacterPickState.Error;
    }
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.characters = this.viewModel.characters;
    this.pickState = this.viewModel.pickState;
    this.selectedIds = this.viewModel.selectedIds;
    this.isCreating = this.viewModel.isCreating;
  }

  /** 获取过滤后的角色列表(按搜索关键词) */
  private getFilteredCharacters(): Character[] {
    const keyword: string = this.searchKeyword.trim();
    if (keyword.length === 0) {
      return this.characters;
    }
    const result: Character[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      const c: Character = this.characters[i];
      if (c.name.indexOf(keyword) >= 0 || c.description.indexOf(keyword) >= 0) {
        result.push(c);
      }
    }
    return result;
  }

  /** 按 ID 查找角色 */
  private findCharacterById(id: string): Character | null {
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].id === id) {
        return this.characters[i];
      }
    }
    return null;
  }

  /** 获取已选角色(按选择顺序) */
  private getSelectedCharacters(): Character[] {
    const result: Character[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      const c: Character | null = this.findCharacterById(this.selectedIds[i]);
      if (c !== null) {
        result.push(c);
      }
    }
    return result;
  }

  /** 切换角色选择状态 */
  private toggleSelect(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.toggleSelect(characterId);
    this.syncFromViewModel();
  }

  /** 进入步骤二 */
  private goStepTwo(): void {
    if (this.selectedIds.length < MIN_MEMBER_COUNT) {
      promptAction.showToast({ message: '最少选择 ' + String(MIN_MEMBER_COUNT) + ' 位角色', duration: 1500 });
      return;
    }
    if (!this.nameCustomized && this.chatNameInput.trim().length === 0) {
      this.chatNameInput = this.composeDefaultTitle();
    }
    this.step = 2;
  }

  /** 返回步骤一 */
  private goStepOne(): void {
    this.step = 1;
  }

  /** 上移成员(步骤二) */
  private moveUp(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.moveUp(characterId);
    this.syncFromViewModel();
    this.refreshDefaultName();
  }

  /** 下移成员(步骤二) */
  private moveDown(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.moveDown(characterId);
    this.syncFromViewModel();
    this.refreshDefaultName();
  }

  /** 名称输入变化 */
  private onNameInput(value: string): void {
    this.chatNameInput = value;
    this.nameCustomized = value.trim().length > 0;
  }

  /** 当未自定义名称时,根据当前选择重新生成默认名称 */
  private refreshDefaultName(): void {
    if (this.nameCustomized) {
      return;
    }
    this.chatNameInput = this.composeDefaultTitle();
  }

  /** 根据已选角色生成默认群聊名称 */
  private composeDefaultTitle(): string {
    const selected: Character[] = this.getSelectedCharacters();
    if (selected.length === 0) {
      return '';
    }
    const names: string[] = selected.map((c: Character): string => c.name);
    if (names.length === 2) {
      return names[0] + ' 与 ' + names[1];
    }
    return names[0] + ' 等 ' + String(names.length) + ' 人';
  }

  /** 确认创建并进入聊天 */
  private confirmCreate(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.selectedIds.length < MIN_MEMBER_COUNT) {
      promptAction.showToast({ message: '最少选择 ' + String(MIN_MEMBER_COUNT) + ' 位角色', duration: 1500 });
      return;
    }
    const title: string = this.chatNameInput.trim();
    this.createGroupChat(title);
  }

  /** 异步创建群聊 */
  private async createGroupChat(title: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.isCreating = true;
    try {
      const chatId: string = await this.viewModel.create(title);
      AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, chatId);
      // 替换当前页面栈为 GroupChatPage,避免返回时回到创建页
      router.replaceUrl({ url: 'pages/groupchat/GroupChatPage' });
    } catch (e) {
      this.syncFromViewModel();
      const msg: string = this.viewModel.errorMessage.length > 0 ? this.viewModel.errorMessage : '创建失败';
      promptAction.showToast({ message: msg, duration: 1500 });
    } finally {
      this.isCreating = false;
    }
  }

  build(): void {
    Column() {
      this.headerArea()
      if (this.step === 1) {
        this.stepOneArea()
      } else {
        this.stepTwoArea()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 顶部标题栏 */
  @Builder
  headerArea(): void {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('返回')
      .onClick(() => {
        if (this.step === 2) {
          this.goStepOne();
        } else {
          router.back();
        }
      })

      Column() {
        Text($r('app.string.group_create_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.step === 1 ? $r('app.string.group_create_step_1') : $r('app.string.group_create_step_2'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4 })

      // G-AI-BUILDER-1: AI 帮我组建入口(仅步骤一显示,与手动创建并列)
      if (this.step === 1) {
        Button($r('app.string.group_ai_builder_entry'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .height(32)
          .padding({ left: 8, right: 8 })
          .accessibilityText('AI 帮我组建多人聊天')
          .onClick(() => {
            router.pushUrl({ url: 'pages/groupchat/GroupChatAiBuilderPage' });
          })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_8'),
      right: $r('app.float.app_spacing_20'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 步骤一:选择角色 */
  @Builder
  stepOneArea(): void {
    Column() {
      if (this.pickState === CharacterPickState.Loading) {
        this.loadingView()
      } else if (this.pickState === CharacterPickState.Error) {
        this.errorView()
      } else if (this.pickState === CharacterPickState.Empty || this.characters.length === 0) {
        this.emptyView()
      } else {
        this.characterListArea()
      }
      this.bottomBarStepOne()
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      Text('角色加载失败')
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      Button('重新加载')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ top: 16 })
        .onClick(() => {
          this.reloadCharacters();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyView(): void {
    Column() {
      Text('还没有角色')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text('请先创建或导入至少两个角色。')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 6 })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private async reloadCharacters(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.loadCharacters();
    this.syncFromViewModel();
  }

  /** 角色列表区 */
  @Builder
  characterListArea(): void {
    // 搜索框
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
          .margin({ right: 8 })

        TextInput({ placeholder: $r('app.string.group_create_search_placeholder'), text: this.searchKeyword })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchKeyword = value;
          })
      }
      .width('100%')
      .height(44)
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 12, right: 12 })
      .margin({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
      .alignItems(VerticalAlign.Center)

      // 提示信息
      Row() {
        Text($r('app.string.group_create_min_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        Text('  ·  ')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        Text($r('app.string.group_create_max_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })

      // 角色列表
      List() {
        ForEach(this.getFilteredCharacters(), (character: Character) => {
          ListItem() {
            this.characterRow(character)
          }
          .margin({ bottom: $r('app.float.app_spacing_8') })
        }, (character: Character) => character.id)

        // 末尾空白
        ListItem() {
          Column().width('100%').height(120)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: 0,
        bottom: 0
      })
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 单个角色行 */
  @Builder
  characterRow(character: Character): void {
    Row() {
      // 头像
      CharacterImageView({
        imageUri: character.avatarUri,
        fallbackName: character.name,
        imgWidth: 44,
        imgHeight: 44,
        imgBorderRadius: 22,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })

      // 名称 + 描述
      Column() {
        Text(character.name)
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(character.description)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      // 选择状态
      if (this.selectedIds.indexOf(character.id) >= 0) {
        Text(String(this.selectedIds.indexOf(character.id) + 1))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(10)
          .width(20)
          .height(20)
          .textAlign(TextAlign.Center)
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.toggleSelect(character.id);
    })
  }

  /** 步骤一底部固定栏 */
  @Builder
  bottomBarStepOne(): void {
    Row() {
      Text('已选择 ' + String(this.selectedIds.length) + ' 位角色')
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .layoutWeight(1)

      Button($r('app.string.group_create_next'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(this.selectedIds.length >= MIN_MEMBER_COUNT ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .enabled(this.selectedIds.length >= MIN_MEMBER_COUNT)
        .onClick(() => {
          this.goStepTwo();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navBarHeight + 12
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .border({ width: { top: 0.5 }, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .alignItems(VerticalAlign.Center)
  }

  /** 步骤二:群聊配置 */
  @Builder
  stepTwoArea(): void {
    Column() {
      Scroll() {
        Column() {
          // 群聊名称
          Column() {
            Text($r('app.string.group_create_chat_name'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .width('100%')

            TextInput({ placeholder: $r('app.string.group_create_chat_name_placeholder'), text: this.chatNameInput })
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(44)
              .padding({ left: 12, right: 12 })
              .margin({ top: 8 })
              .onChange((value: string) => {
                this.onNameInput(value);
              })
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

          // 已选成员 + 发言顺序
          Column() {
            Text($r('app.string.group_create_speak_order'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ bottom: 8 })

            ForEach(this.getSelectedCharacters(), (character: Character, index: number) => {
              this.memberOrderRow(character, index)
            }, (character: Character, index: number) => character.id + '_' + String(index))
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .margin({ top: 8 })

          // 回复方式(本阶段固定说明,不可切换)
          Column() {
            Text($r('app.string.group_create_reply_mode'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ bottom: 8 })

            Row() {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(20)
                .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
              Text($r('app.string.group_create_reply_mode_sequential'))
                .fontSize($r('app.float.app_font_body'))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .margin({ left: 8 })
                .layoutWeight(1)
            }
            .width('100%')
            .height(44)
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .margin({ top: 8 })

          // 末尾空白
          Column().width('100%').height(120)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // 底部固定栏
      this.bottomBarStepTwo()
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 成员顺序行(步骤二) */
  @Builder
  memberOrderRow(character: Character, index: number): void {
    Row() {
      // 顺序号
      Text(String(index + 1))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius(12)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)

      // 头像
      CharacterImageView({
        imageUri: character.avatarUri,
        fallbackName: character.name,
        imgWidth: 36,
        imgHeight: 36,
        imgBorderRadius: 18,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })
        .margin({ left: 8 })

      // 名称
      Text(character.name)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
        .margin({ left: 8 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 上移按钮
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(18)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('上移角色')
      .enabled(index > 0)
      .onClick(() => {
        this.moveUp(character.id);
      })

      // 下移按钮
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(18)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('下移角色')
      .enabled(index < this.selectedIds.length - 1)
      .onClick(() => {
        this.moveDown(character.id);
      })
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
  }

  /** 步骤二底部固定栏 */
  @Builder
  bottomBarStepTwo(): void {
    Row() {
      Button($r('app.string.group_create_prev'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .enabled(!this.isCreating)
        .onClick(() => {
          this.goStepOne();
        })

      Button($r('app.string.group_create_confirm'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(this.isCreating ? ThemePalette.surface2Color(this.effectiveTheme) : ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ left: 12 })
        .layoutWeight(1)
        .enabled(!this.isCreating)
        .onClick(() => {
          this.confirmCreate();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navBarHeight + 12
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .border({ width: { top: 0.5 }, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .alignItems(VerticalAlign.Center)
  }
}
