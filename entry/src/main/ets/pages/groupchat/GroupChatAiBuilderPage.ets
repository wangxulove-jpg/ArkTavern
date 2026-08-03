/**
 * GroupChatAiBuilderPage AI 建群页面(G-AI-BUILDER-1)
 *
 * 三个区域:
 * 1. 群聊描述输入
 * 2. 候选角色选择(2~12)
 * 3. 草案结果(标题/成员顺序/推荐理由/开场消息)
 *
 * 流程:
 * - 用户输入描述 + 选择候选 → 点击"生成草案"
 * - AI 从候选中筛选 2~8 位成员,生成标题/顺序/理由/开场消息
 * - 用户可编辑标题、调整顺序、增删成员、编辑开场消息
 * - 点击"确认创建" → 调用 createGroupConversation → 进入 GroupChatPage
 *
 * 草案与正式数据隔离:
 * - 生成结果只在 ViewModel 内存,不写数据库
 * - 确认创建才写入,路由只传 chatId
 * - 开场消息不会自动发送,仅在草案区显示供用户参考
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { CharacterImageView } from '../../components/CharacterImageView';
import {
  GroupChatAiBuilderViewModel,
  DraftMemberItem
} from '../../viewmodels/groupchat/GroupChatAiBuilderViewModel';
import {
  CharacterPickState,
  PENDING_GROUP_CHAT_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { GroupChatDraftState } from '../../services/groupchat/builder/GroupChatDraftTypes';
import { Character } from '../../models/Character';
import { Logger } from '../../utils/Logger';

@Entry
@Component
struct GroupChatAiBuilderPage {
  /** 全部角色列表 */
  @State characters: Character[] = [];
  /** 角色列表加载状态 */
  @State pickState: CharacterPickState = CharacterPickState.Loading;
  /** 已选候选角色 ID 列表 */
  @State selectedCandidateIds: string[] = [];
  /** 群聊描述输入 */
  @State description: string = '';
  /** 草案状态 */
  @State draftState: GroupChatDraftState = GroupChatDraftState.Idle;
  /** 草案标题 */
  @State draftTitle: string = '';
  /** 草案成员 */
  @State draftMembers: DraftMemberItem[] = [];
  /** 推荐理由 */
  @State draftRationale: string = '';
  /** 开场消息草案 */
  @State draftOpeningMessage: string = '';
  /** 错误提示 */
  @State errorMessage: string = '';
  /** 是否正在创建 */
  @State isCreating: boolean = false;
  /** 搜索关键词 */
  @State searchKeyword: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  private viewModel: GroupChatAiBuilderViewModel | null = null;
  private scroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupChatAiBuilderViewModel();
      await this.viewModel.loadCharacters();
      this.syncFromViewModel();
    } catch (e) {
      this.pickState = CharacterPickState.Error;
    }
  }

  /** 页面销毁时停止生成 */
  async aboutToDisappear(): Promise<void> {
    if (this.viewModel !== null) {
      this.viewModel.disposeWithStop();
      this.viewModel = null;
    }
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.characters = this.viewModel.characters;
    this.pickState = this.viewModel.pickState;
    this.selectedCandidateIds = this.viewModel.selectedCandidateIds;
    this.description = this.viewModel.description;
    this.draftState = this.viewModel.draftState;
    this.draftTitle = this.viewModel.draftTitle;
    this.draftMembers = this.viewModel.draftMembers;
    this.draftRationale = this.viewModel.draftRationale;
    this.draftOpeningMessage = this.viewModel.draftOpeningMessage;
    this.errorMessage = this.viewModel.errorMessage;
    this.isCreating = this.viewModel.isCreating;
  }

  /** 获取过滤后的角色列表 */
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

  /** 判断角色是否已选为候选 */
  private isCandidateSelected(characterId: string): boolean {
    return this.selectedCandidateIds.indexOf(characterId) >= 0;
  }

  /** 判断角色是否已在草案成员中 */
  private isDraftMember(characterId: string): boolean {
    for (let i = 0; i < this.draftMembers.length; i++) {
      if (this.draftMembers[i].characterId === characterId) {
        return true;
      }
    }
    return false;
  }

  build(): void {
    Column() {
      this.headerArea()
      this.contentArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 顶部标题栏 */
  @Builder
  headerArea(): void {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('返回')
      .onClick(() => {
        router.back();
      })

      Text($r('app.string.group_ai_builder_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })
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

  /** 主内容区 */
  @Builder
  contentArea(): void {
    if (this.pickState === CharacterPickState.Loading) {
      this.loadingView()
    } else if (this.pickState === CharacterPickState.Error) {
      this.errorView()
    } else if (this.pickState === CharacterPickState.Empty || this.characters.length === 0) {
      this.emptyView()
    } else {
      this.mainContent()
    }
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
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
        .fontColor($r('app.color.app_text_secondary'))
      Button('重新加载')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
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
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
        .width('100%')
      Text('请先创建或导入至少两个角色。')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
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

  /** 主内容:描述 + 候选 + 草案 */
  @Builder
  mainContent(): void {
    Scroll(this.scroller) {
      Column() {
        this.descriptionSection()
        this.candidateSection()
        this.actionSection()
        if (this.draftState === GroupChatDraftState.Ready) {
          this.draftSection()
        }
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .align(Alignment.TopStart)
  }

  /** 描述输入区 */
  @Builder
  descriptionSection(): void {
    Column() {
      Text($r('app.string.group_ai_builder_description_hint'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')

      TextArea({ placeholder: $r('app.string.group_ai_builder_description_placeholder'), text: this.description })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(80)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .margin({ top: 8 })
        .enabled(this.draftState !== GroupChatDraftState.Generating && !this.isCreating)
        .onChange((value: string) => {
          if (this.viewModel !== null) {
            this.viewModel.updateDescription(value);
            this.description = value;
          }
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
  }

  /** 候选角色选择区 */
  @Builder
  candidateSection(): void {
    Column() {
      Row() {
        Text($r('app.string.group_ai_builder_candidates'))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Text('已选 ' + String(this.selectedCandidateIds.length) + ' / 12')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
      .width('100%')

      Text($r('app.string.group_ai_builder_candidates_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 4 })

      // 搜索框
      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor([$r('app.color.app_text_tertiary')])
          .margin({ right: 8 })
        TextInput({ placeholder: $r('app.string.group_create_search_placeholder'), text: this.searchKeyword })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchKeyword = value;
          })
      }
      .width('100%')
      .height(40)
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 12, right: 12 })
      .margin({ top: 8 })

      // 角色列表
      List() {
        ForEach(this.getFilteredCharacters(), (c: Character) => {
          ListItem() {
            this.candidateItem(c)
          }
        }, (c: Character) => c.id)
      }
      .width('100%')
      .margin({ top: 8 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .margin({ top: 8 })
  }

  /** 单个候选角色项 */
  @Builder
  candidateItem(c: Character): void {
    Row() {
      CharacterImageView({
        imageUri: c.avatarUri,
        fallbackName: c.name,
        imgWidth: 36,
        imgHeight: 36,
        imgBorderRadius: 18,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })
      Column() {
        Text(c.name)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (c.description.trim().length > 0) {
          Text(c.description.trim())
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignItems(HorizontalAlign.Start)

      // 选中标记
      if (this.isCandidateSelected(c.id)) {
        Text('✓')
          .fontSize(16)
          .fontColor($r('app.color.app_accent'))
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.handleToggleCandidate(c.id);
    })
  }

  /** 操作区:生成/停止 */
  @Builder
  actionSection(): void {
    Column() {
      // 错误提示
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ bottom: 8 })
      }

      if (this.draftState === GroupChatDraftState.Generating) {
        // 生成中:进度 + 停止按钮
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.app_text_tertiary'))
            .margin({ right: 8 })
          Text($r('app.string.group_ai_builder_generating'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
          Button($r('app.string.group_ai_builder_stop'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(40)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.handleCancelGeneration();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        // 生成按钮
        Button($r('app.string.group_ai_builder_generate'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(this.selectedCandidateIds.length >= 2 ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(44)
          .width('100%')
          .enabled(this.selectedCandidateIds.length >= 2 && !this.isCreating)
          .onClick(() => {
            this.handleGenerate();
          })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navBarHeight + 12
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .margin({ top: 8 })
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
  }

  /** 草案结果区 */
  @Builder
  draftSection(): void {
    Column() {
      Text($r('app.string.group_ai_builder_draft_title'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .margin({ bottom: 8 })

      // 群聊名称
      Text($r('app.string.group_ai_builder_draft_chat_name'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
      TextInput({ text: this.draftTitle })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .padding({ left: 12, right: 12 })
        .margin({ top: 4 })
        .onChange((value: string) => {
          this.handleUpdateDraftTitle(value);
        })

      // 成员与发言顺序
      Text($r('app.string.group_ai_builder_draft_members'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 12 })

      ForEach(this.draftMembers, (m: DraftMemberItem, index: number) => {
        this.draftMemberItem(m, index)
      }, (m: DraftMemberItem) => m.characterId)

      // 推荐理由
      if (this.draftRationale.length > 0) {
        Text($r('app.string.group_ai_builder_draft_rationale'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .margin({ top: 12 })
        Text(this.draftRationale)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 4 })
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
      }

      // 开场消息草案
      Text($r('app.string.group_ai_builder_draft_opening'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 12 })
      Text($r('app.string.group_ai_builder_draft_opening_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ top: 2 })
      TextArea({ text: this.draftOpeningMessage })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(70)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .margin({ top: 4 })
        .onChange((value: string) => {
          this.handleUpdateOpeningMessage(value);
        })

      // 确认创建 / 重新生成
      Row() {
        Button($r('app.string.group_ai_builder_regenerate'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(44)
          .layoutWeight(1)
          .margin({ right: 8 })
          .enabled(!this.isCreating)
          .onClick(() => {
            this.handleGenerate();
          })
        Button($r('app.string.group_ai_builder_confirm'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(44)
          .layoutWeight(1)
          .enabled(!this.isCreating)
          .onClick(() => {
            this.handleConfirmCreate();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navBarHeight + 12
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .margin({ top: 8 })
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
  }

  /** 草案成员项(含上移/下移/移除) */
  @Builder
  draftMemberItem(m: DraftMemberItem, index: number): void {
    Row() {
      // 顺序编号
      Text(String(index + 1))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width(20)
        .textAlign(TextAlign.Center)

      CharacterImageView({
        imageUri: m.avatarUri,
        fallbackName: m.name,
        imgWidth: 30,
        imgHeight: 30,
        imgBorderRadius: 15,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })
        .margin({ left: 8 })

      Text(m.name)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 8 })

      // 上移
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(14)
          .fontColor([$r('app.color.app_text_secondary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(28)
      .height(28)
      .enabled(index > 0)
      .onClick(() => {
        this.handleMoveUp(m.characterId);
      })

      // 下移
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(14)
          .fontColor([$r('app.color.app_text_secondary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(28)
      .height(28)
      .margin({ left: 4 })
      .enabled(index < this.draftMembers.length - 1)
      .onClick(() => {
        this.handleMoveDown(m.characterId);
      })

      // 移除
      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(14)
          .fontColor([$r('app.color.app_text_secondary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(28)
      .height(28)
      .margin({ left: 4 })
      .enabled(this.draftMembers.length > 2)
      .onClick(() => {
        this.handleRemoveMember(m.characterId);
      })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 事件处理 =====

  private handleToggleCandidate(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.toggleCandidate(characterId);
    this.syncFromViewModel();
  }

  private handleGenerate(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.selectedCandidateIds.length < 2) {
      promptAction.showToast({ message: '请先选择至少 2 个候选角色', duration: 1500 });
      return;
    }
    this.handleGenerateAsync();
  }

  private async handleGenerateAsync(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.draftState = GroupChatDraftState.Generating;
    this.errorMessage = '';
    await this.viewModel.generateDraft();
    this.syncFromViewModel();
  }

  private handleCancelGeneration(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.cancelGeneration();
    this.syncFromViewModel();
  }

  private handleUpdateDraftTitle(value: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.updateDraftTitle(value);
    this.draftTitle = this.viewModel.draftTitle;
  }

  private handleUpdateOpeningMessage(value: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.updateOpeningMessage(value);
    this.draftOpeningMessage = this.viewModel.draftOpeningMessage;
  }

  private handleMoveUp(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.moveMemberUp(characterId);
    this.syncFromViewModel();
  }

  private handleMoveDown(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.moveMemberDown(characterId);
    this.syncFromViewModel();
  }

  private handleRemoveMember(characterId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.removeMember(characterId);
    this.syncFromViewModel();
  }

  private handleConfirmCreate(): void {
    if (this.viewModel === null) {
      return;
    }
    this.handleConfirmCreateAsync();
  }

  private async handleConfirmCreateAsync(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.isCreating = true;
    try {
      const chatId: string = await this.viewModel.confirmCreate();
      AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, chatId);
      // 替换页面栈为 GroupChatPage,避免返回时回到建群页
      router.replaceUrl({ url: 'pages/groupchat/GroupChatPage' });
    } catch (e) {
      this.syncFromViewModel();
      const msg: string = this.errorMessage.length > 0 ? this.errorMessage : '创建失败';
      promptAction.showToast({ message: msg, duration: 1500 });
    } finally {
      this.isCreating = false;
    }
  }
}
