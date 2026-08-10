/**
 * GroupMemberManagePage 群聊成员管理(G-DATA-1B 正式版)
 *
 * 数据来源:GroupConversationPersistenceService(真实数据库)。
 *
 * 功能:
 * - 显示真实成员列表(顺序号 + 头像 + 名称 + 启用/停用状态)
 * - 上移 / 下移(调用 replaceParticipantOrder,顺序从 0 连续)
 * - 启用 / 停用(调用 setParticipantEnabled,处理"至少保留 2 个启用"规则)
 * - 移除成员(调用 removeParticipant,处理"至少保留 2 人"规则)
 * - 添加成员(从真实角色列表选择,调用 addParticipant,最多 8 人)
 *
 * 并发保护:
 * - isSaving 期间禁用所有操作按钮
 * - 操作失败时恢复 UI(重新加载正式成员)
 *
 * 不依赖:GroupChatPreviewStore / PREVIEW_CHARACTERS。
 */

import { router, promptAction } from '@kit.ArkUI';
import { CharacterImageView } from '../../components/CharacterImageView';
import { AppServices } from '../../services/AppServices';
import {
  GroupMemberManageViewModel,
  MIN_MEMBER_COUNT,
  MAX_MEMBER_COUNT
} from '../../viewmodels/groupchat/GroupMemberManageViewModel';
import {
  GroupMemberUiModel,
  AddableCharacterUiModel,
  GroupChatDetailState,
  CharacterPickState,
  PENDING_GROUP_CHAT_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { ThemePalette } from '../../theme/ThemePalette';
import { GroupCharacterOverrideEditSheet } from './GroupCharacterOverrideEditSheet';

@Entry
@Component
struct GroupMemberManagePage {
  /** 当前群聊 ID */
  @State chatId: string = '';
  /** 群聊标题(用于返回栏显示) */
  @State chatTitle: string = '';
  /** 有序成员列表 */
  @State members: GroupMemberUiModel[] = [];
  /** 可添加角色列表 */
  @State addableCharacters: AddableCharacterUiModel[] = [];
  /** 详情页状态 */
  @State state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 添加弹窗角色列表状态 */
  @State addableState: CharacterPickState = CharacterPickState.Loading;
  /** 是否正在执行成员操作(防止并发) */
  @State isSaving: boolean = false;
  /** G-RUNTIME-1C: 是否正在生成(生成中禁止修改成员) */
  @State isGenerating: boolean = false;
  /** G-OVERRIDE-1A: 正在编辑覆写的角色 ID */
  @State editingOverrideCharacterId: string = '';
  /** G-OVERRIDE-1A: 正在编辑覆写的角色名 */
  @State editingOverrideCharacterName: string = '';
  /** 添加角色弹窗是否可见 */
  @State addDialogVisible: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private viewModel: GroupMemberManageViewModel | null = null;

  async aboutToAppear(): Promise<void> {
    const id: string = AppStorage.get<string>(PENDING_GROUP_CHAT_ID_KEY) ?? '';
    if (id.length === 0) {
      promptAction.showToast({ message: '未找到群聊', duration: 1500 });
      router.back();
      return;
    }
    this.chatId = id;
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupMemberManageViewModel();
      await this.viewModel.load(id);
      // G-RUNTIME-1C: 刷新生成状态,生成中禁止修改成员
      this.viewModel.refreshGeneratingState();
      this.syncFromViewModel();
    } catch (e) {
      this.state = GroupChatDetailState.Error;
    }
  }

  /** G-RUNTIME-1C: 页面重新显示时刷新生成状态 */
  onPageShow(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.refreshGeneratingState();
    this.syncFromViewModel();
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.chatTitle = this.viewModel.chatTitle;
    this.members = this.viewModel.members;
    this.state = this.viewModel.state;
    this.isSaving = this.viewModel.isSaving;
    this.isGenerating = this.viewModel.isGenerating;
  }

  /** 同步可添加角色 */
  private syncAddable(): void {
    if (this.viewModel === null) {
      return;
    }
    this.addableCharacters = this.viewModel.addableCharacters;
    this.addableState = this.viewModel.addableState;
  }

  build(): void {
    Stack() {
      Column() {
        if (this.state === GroupChatDetailState.Loading) {
          this.loadingView()
        } else if (this.state === GroupChatDetailState.Error) {
          this.errorView()
        } else if (this.state === GroupChatDetailState.NotFound) {
          this.notFoundView()
        } else {
          this.headerArea()
          this.hintArea()
          this.memberListArea()
          this.bottomAddButton()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 添加角色弹窗
      if (this.addDialogVisible) {
        this.addDialog()
      }

      // G-OVERRIDE-1A: 角色覆写编辑 Sheet
      Column().width(0).height(0).bindSheet(
        this.editingOverrideCharacterId.length > 0,
        this.overrideEditSheet,
        {
          height: SheetSize.LARGE,
          dragBar: true,
          backgroundColor: ThemePalette.pageBackgroundColor(this.effectiveTheme),
          onDisappear: () => { this.editingOverrideCharacterId = ''; }
        }
      )
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      Text('加载失败')
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
          this.reloadCurrent();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      Text('多人聊天不存在或已被删除')
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('80%')
      Button('返回多人聊天首页')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ top: 16 })
        .onClick(() => {
          router.replaceUrl({ url: 'pages/groupchat/GroupChatHomePage' });
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private async reloadCurrent(): Promise<void> {
    if (this.viewModel === null || this.chatId.length === 0) {
      return;
    }
    await this.viewModel.load(this.chatId);
    this.syncFromViewModel();
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
        router.back();
      })

      Column() {
        Text($r('app.string.group_manage_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.chatTitle)
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

  /** 规则提示 */
  @Builder
  hintArea(): void {
    Text($r('app.string.group_member_min_hint'))
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
  }

  /** 成员列表 */
  @Builder
  memberListArea(): void {
    List() {
      ForEach(this.members, (member: GroupMemberUiModel, index: number) => {
        ListItem() {
          this.memberRow(member, index)
        }
        .margin({ bottom: $r('app.float.app_spacing_8') })
      }, (member: GroupMemberUiModel) => member.characterId + '|' + String(member.speakerOrder) + '|' + String(member.isEnabled) + '|' + String(member.characterExists))

      // 末尾空白
      ListItem() {
        Column().width('100%').height(100)
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

  /** 单个成员行 */
  @Builder
  memberRow(member: GroupMemberUiModel, index: number): void {
    Column() {
      // 第一行:顺序号 + 头像 + 名称 + 状态
      Row() {
        // 顺序号
        Text(String(index + 1))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(24)
          .textAlign(TextAlign.Center)

        // 头像
        CharacterImageView({
          imageUri: member.avatarUri,
          fallbackName: member.name,
          imgWidth: 40,
          imgHeight: 40,
          imgBorderRadius: 20,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
          .margin({ left: 8 })
          .opacity(member.isEnabled ? 1 : 0.5)

        // 名称 + 状态
        Column() {
          Text(member.name)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(member.isEnabled ? ThemePalette.textPrimaryColor(this.effectiveTheme) : ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.composeStatusText(member))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.composeStatusColor(member))
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.editingOverrideCharacterId = member.characterId;
        this.editingOverrideCharacterName = member.name;
      })

      // 第二行:操作按钮
      Row() {
        Button($r('app.string.group_create_move_up'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .accessibilityText('上移角色')
          .enabled(!this.isSaving && !this.isGenerating && index > 0)
          .onClick(() => {
            this.handleMoveUp(member.characterId);
          })

        Button($r('app.string.group_create_move_down'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText('下移角色')
          .enabled(!this.isSaving && !this.isGenerating && index < this.members.length - 1)
          .onClick(() => {
            this.handleMoveDown(member.characterId);
          })

        Button(member.isEnabled ? $r('app.string.group_manage_disable') : $r('app.string.group_manage_enable'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(member.isEnabled ? $r('app.color.app_danger') : ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText(member.isEnabled ? '停用角色' : '启用角色')
          .enabled(!this.isSaving && !this.isGenerating)
          .onClick(() => {
            this.handleToggleEnabled(member.characterId, member.isEnabled);
          })

        Button($r('app.string.group_manage_remove'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .enabled(!this.isSaving && !this.isGenerating && this.members.length > MIN_MEMBER_COUNT)
          .onClick(() => {
            this.handleRemove(member.characterId);
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Start)
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
  }

  /** 组合状态文本 */
  private composeStatusText(member: GroupMemberUiModel): string {
    if (!member.characterExists) {
      return '角色已删除';
    }
    return member.isEnabled ? '已启用' : '已停用';
  }

  /** 组合状态颜色 */
  private composeStatusColor(member: GroupMemberUiModel): ResourceColor {
    if (!member.characterExists) {
      return $r('app.color.app_danger');
    }
    return member.isEnabled ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textTertiaryColor(this.effectiveTheme);
  }

  /** 底部添加按钮 */
  @Builder
  bottomAddButton(): void {
    Row() {
      Button($r('app.string.group_manage_add'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(this.members.length >= MAX_MEMBER_COUNT ? ThemePalette.surface2Color(this.effectiveTheme) : ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .layoutWeight(1)
        .enabled(!this.isSaving && !this.isGenerating && this.members.length < MAX_MEMBER_COUNT)
        .onClick(() => {
          this.openAddDialog();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: this.navBarHeight + 8
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .border({ width: { top: 0.5 }, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .alignItems(VerticalAlign.Center)
  }

  private async openAddDialog(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.loadAddableCharacters();
    this.syncAddable();
    this.addDialogVisible = true;
  }

  /** 添加角色弹窗 */
  @Builder
  addDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_manage_add_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })
            .width('100%')

          if (this.addableState === CharacterPickState.Loading) {
            Text('加载中…')
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .height(280)
              .textAlign(TextAlign.Center)
          } else if (this.addableState === CharacterPickState.Empty) {
            Text('暂无可添加的角色')
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .height(280)
              .textAlign(TextAlign.Center)
          } else if (this.addableState === CharacterPickState.Error) {
            Text('加载可添加角色失败')
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%')
              .height(280)
              .textAlign(TextAlign.Center)
          } else {
            // 可添加角色列表
            List() {
              ForEach(this.addableCharacters, (char: AddableCharacterUiModel) => {
                ListItem() {
                  Row() {
                    CharacterImageView({
                      imageUri: char.avatarUri,
                      fallbackName: char.name,
                      imgWidth: 36,
                      imgHeight: 36,
                      imgBorderRadius: 18,
                      displayMode: 'thumbnail',
                      objectFit: ImageFit.Cover
                    })

                    Column() {
                      Text(char.name)
                        .fontSize($r('app.float.app_font_body'))
                        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(char.description)
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

                    Button($r('app.string.group_manage_add'))
                      .fontSize($r('app.float.app_font_caption'))
                      .fontColor($r('app.color.app_on_accent'))
                      .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
                      .borderRadius($r('app.float.app_radius_sm'))
                      .height(32)
                      .padding({ left: 12, right: 12 })
                      .enabled(!this.isSaving && !this.isGenerating)
                      .onClick(() => {
                        this.handleAddMember(char.characterId);
                      })
                  }
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
                  .alignItems(VerticalAlign.Center)
                }
              }, (char: AddableCharacterUiModel) => char.characterId)
            }
            .width('100%')
            .height(280)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
          }

          Button($r('app.string.group_cancel'))
            .fontSize(15)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.addDialogVisible = false;
            })
        }
        .width('85%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_scrim'))
    .onClick(() => {
      this.addDialogVisible = false;
    })
  }

  // ===== 操作处理 =====

  /** 上移成员 */
  private async handleMoveUp(characterId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.moveUp(characterId);
      this.syncFromViewModel();
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法修改成员', duration: 1500 });
      } else {
        promptAction.showToast({ message: '上移失败', duration: 1500 });
      }
      await this.reloadCurrent();
    }
  }

  /** 下移成员 */
  private async handleMoveDown(characterId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.moveDown(characterId);
      this.syncFromViewModel();
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法修改成员', duration: 1500 });
      } else {
        promptAction.showToast({ message: '下移失败', duration: 1500 });
      }
      await this.reloadCurrent();
    }
  }

  /** 切换启用/停用 */
  private async handleToggleEnabled(characterId: string, currentEnabled: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.setEnabled(characterId, !currentEnabled);
      this.syncFromViewModel();
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法修改成员', duration: 1500 });
      } else if (msg.indexOf('enabled') >= 0 || msg.indexOf('启用') >= 0) {
        promptAction.showToast({ message: '至少保留 ' + String(MIN_MEMBER_COUNT) + ' 个启用角色', duration: 1500 });
      } else {
        promptAction.showToast({ message: '操作失败', duration: 1500 });
      }
      await this.reloadCurrent();
    }
  }

  /** 移除成员 */
  private async handleRemove(characterId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.remove(characterId);
      this.syncFromViewModel();
      promptAction.showToast({ message: '已移除成员', duration: 1200 });
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法修改成员', duration: 1500 });
      } else if (msg.indexOf('min') >= 0 || msg.indexOf('成员') >= 0) {
        promptAction.showToast({ message: '最少保留 ' + String(MIN_MEMBER_COUNT) + ' 个成员', duration: 1500 });
      } else {
        promptAction.showToast({ message: '移除失败', duration: 1500 });
      }
      await this.reloadCurrent();
    }
  }

  /** 添加成员 */
  private async handleAddMember(characterId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.members.length >= MAX_MEMBER_COUNT) {
      promptAction.showToast({ message: '最多 ' + String(MAX_MEMBER_COUNT) + ' 位角色', duration: 1500 });
      return;
    }
    try {
      await this.viewModel.add(characterId);
      this.syncFromViewModel();
      this.addDialogVisible = false;
      promptAction.showToast({ message: '已添加成员', duration: 1200 });
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法修改成员', duration: 1500 });
      } else {
        promptAction.showToast({ message: '添加失败', duration: 1500 });
      }
      await this.reloadCurrent();
    }
  }

  /** G-OVERRIDE-1A: 角色覆写编辑 Sheet */
  @Builder overrideEditSheet(): void {
    GroupCharacterOverrideEditSheet({
      chatId: this.chatId,
      characterId: this.editingOverrideCharacterId,
      characterName: this.editingOverrideCharacterName
    })
  }
}
