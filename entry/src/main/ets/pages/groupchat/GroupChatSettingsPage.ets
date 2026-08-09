/**
 * GroupChatSettingsPage 群聊设置(G-DATA-1B 正式版)
 *
 * 数据来源:GroupConversationPersistenceService(真实数据库)。
 *
 * 功能:
 * - 显示群聊名称(查看 + 重新命名)
 * - 回复方式(固定说明"按成员顺序回复",不可切换)
 * - 失败处理方式(尚无正式 Schema,显示为"尚未开放")
 * - 管理成员入口
 * - 删除群聊(二次确认 + 调用正式删除事务)
 *
 * 不依赖:GroupChatPreviewStore / GroupFailurePolicy(预览枚举)。
 * 本阶段不持久化的设置不展示为可切换状态。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { GroupChatSettingsViewModel } from '../../viewmodels/groupchat/GroupChatSettingsViewModel';
import {
  GroupChatDetailState,
  PENDING_GROUP_CHAT_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import {
  GroupAutoSummaryDetailLevel,
  getGroupAutoSummaryLevelSpec
} from '../../models/groupchat/GroupAutoSummaryModels';
import { ThemePalette } from '../../theme/ThemePalette';

@Entry
@Component
struct GroupChatSettingsPage {
  /** 当前群聊 ID */
  @State chatId: string = '';
  /** 当前群聊标题 */
  @State title: string = '';
  /** 详情页状态 */
  @State state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 是否正在重命名 */
  @State isRenaming: boolean = false;
  /** 是否正在删除 */
  @State isDeleting: boolean = false;
  /** 是否正在清空消息 */
  @State isClearing: boolean = false;
  /** G-RUNTIME-1C: 是否正在生成(生成中禁止清空/删除) */
  @State isGenerating: boolean = false;
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 删除确认弹窗是否可见 */
  @State deleteConfirmVisible: boolean = false;
  /** 清空消息确认弹窗是否可见 */
  @State clearConfirmVisible: boolean = false;
  /** GROUP-CHAT-TARGET-1: @角色回复模式('one_shot'|'persistent') */
  @State replyTargetMode: string = 'one_shot';
  /** GROUP-CHAT-TARGET-1: 回复模式选择 Sheet 是否可见 */
  @State replyModePickerVisible: boolean = false;
  /** GROUP-NARRATION-1A: 旁白开关 */
  @State narrationEnabled: boolean = false;
  /** GROUP-NARRATION-1A: 旁白 token 数 */
  @State narrationMaxTokens: number = 256;
  /** GROUP-NARRATION-1A: 旁白 token 编辑时临时值 */
  @State narrationTokensInput: string = '256';
  /** G-GROUP-AUTO-SUMMARY-1A: 自动记忆总结开关 */
  @State autoSummaryEnabled: boolean = false;
  /** G-GROUP-AUTO-SUMMARY-1A: 自动总结详细程度档位 */
  @State autoSummaryDetailLevel: GroupAutoSummaryDetailLevel = GroupAutoSummaryDetailLevel.Medium;
  /** G-GROUP-AUTO-SUMMARY-1A: 档位选择 Sheet 是否可见 */
  @State autoSummaryLevelPickerVisible: boolean = false;
  /** G-GROUP-USER-IDENTITY-1: 该群聊的用户显示名称(空=使用全局) */
  @State userName: string = '';
  /** G-GROUP-USER-IDENTITY-1: 用户名称输入中(用于 TextInput 联动) */
  @State userNameInput: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private viewModel: GroupChatSettingsViewModel | null = null;

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
      this.viewModel = new GroupChatSettingsViewModel();
      await this.viewModel.load(id);
      // G-RUNTIME-1C: 刷新生成状态,生成中禁止清空/删除
      this.viewModel.refreshGeneratingState();
      this.syncFromViewModel();
    } catch (e) {
      this.state = GroupChatDetailState.Error;
    }
  }

  /** G-RUNTIME-1C: 页面重新显示时刷新生成状态(从设置返回或从其他页返回) */
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
    this.title = this.viewModel.title;
    this.state = this.viewModel.state;
    this.isRenaming = this.viewModel.isRenaming;
    this.isDeleting = this.viewModel.isDeleting;
    this.isClearing = this.viewModel.isClearing;
    this.isGenerating = this.viewModel.isGenerating;
    this.replyTargetMode = this.viewModel.replyTargetMode;
    this.narrationEnabled = this.viewModel.narrationEnabled;
    this.narrationMaxTokens = this.viewModel.narrationMaxTokens;
    this.narrationTokensInput = String(this.viewModel.narrationMaxTokens);
    this.autoSummaryEnabled = this.viewModel.autoSummaryEnabled;
    this.autoSummaryDetailLevel = this.viewModel.autoSummaryDetailLevel;
    this.userName = this.viewModel.userName;
    this.userNameInput = this.viewModel.userName;
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
          this.settingsListArea()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.renameVisible) {
        this.renameDialog()
      }
      if (this.deleteConfirmVisible) {
        this.deleteConfirmDialog()
      }
      if (this.clearConfirmVisible) {
        this.clearConfirmDialog()
      }
      // GROUP-CHAT-TARGET-1: @角色回复模式选择 Sheet
      if (this.replyModePickerVisible) {
        this.replyModePickerDialog()
      }
      // G-GROUP-AUTO-SUMMARY-1A: 自动总结档位选择 Sheet
      if (this.autoSummaryLevelPickerVisible) {
        this.autoSummaryLevelPickerDialog()
      }
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

      Text($r('app.string.group_settings_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
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

  /** 设置列表区 */
  @Builder
  settingsListArea(): void {
    Scroll() {
      Column() {
        // 群聊名称
        this.nameSection()
        // G-GROUP-USER-IDENTITY-1: 用户名称
        this.userIdentitySection()
        // 回复方式(固定说明)
        this.replyModeSection()
        // G-GROUP-AUTO-SUMMARY-1A: 自动记忆总结设置
        this.autoSummarySection()
        // 失败处理方式(尚未开放)
        this.failurePolicySection()
        // 管理成员入口
        this.manageMembersEntry()
        // 清空聊天记录
        this.clearMessagesEntry()
        // 删除群聊
        this.deleteSessionEntry()

        // 末尾空白
        Column().width('100%').height(40)
      }
      .width('100%')
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

  /** 群聊名称区 */
  @Builder
  nameSection(): void {
    Column() {
      Text($r('app.string.group_settings_name'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(this.title)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button($r('app.string.group_rename'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(!this.isRenaming)
          .onClick(() => {
            this.renameInput = this.title;
            this.renameVisible = true;
          })
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
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_12') })
  }

  /** G-GROUP-USER-IDENTITY-1: 用户名称设置 */
  @Builder
  userIdentitySection(): void {
    Column() {
      Text('用户身份')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text('我的名称')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)

        TextInput({ text: this.userNameInput, placeholder: '使用全局设置' })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .textAlign(TextAlign.End)
          .width(140)
          .backgroundColor(Color.Transparent)
          .border({ width: 0 })
          .onChange((value: string) => {
            this.userNameInput = value;
          })
          .onSubmit(() => {
            const trimmed: string = this.userNameInput.trim();
            this.userName = trimmed;
            this.userNameInput = trimmed;
            if (this.viewModel !== null && this.viewModel.chatId.length > 0) {
              this.viewModel.setAndPersistUserName(trimmed);
            }
          })
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
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_12') })
  }

  /** 回复设置区标题 + @角色回复模式 */
  @Builder
  replyModeSection(): void {
    Column() {
      Text('回复设置')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      // @角色回复模式
      Row() {
        Text('@角色回复模式')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)

        Text(this.replyTargetMode === 'persistent' ? '持续对话' : '仅回复一次')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ right: 4 })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
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
        this.replyModePickerVisible = true;
      })

      // GROUP-NARRATION-1A: 旁白开关
      Row() {
        Column() {
          Text('旁白')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text('描述其他在场角色的动作')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.narrationEnabled })
          .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
          .onChange((isOn: boolean) => {
            if (this.viewModel !== null) {
              this.viewModel.setAndPersistNarrationEnabled(isOn);
              this.narrationEnabled = isOn;
            }
          })
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
      .margin({ top: $r('app.float.app_spacing_8') })

      // GROUP-NARRATION-1A: 旁白 reply token 数
      Row() {
        Text('旁白回复 token 数')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

        Blank()

        TextInput({ text: this.narrationTokensInput })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .textAlign(TextAlign.End)
          .type(InputType.Normal)
          .width(60)
          .onChange((value: string) => {
            this.narrationTokensInput = value;
          })
          .onSubmit(() => {
            const n: number = parseInt(this.narrationTokensInput);
            if (!isNaN(n) && n >= 16 && this.viewModel !== null) {
              this.viewModel.setAndPersistNarrationMaxTokens(n);
              this.narrationMaxTokens = n;
            }
          })
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
      .margin({ top: $r('app.float.app_spacing_8') })
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
  }

  /** G-GROUP-AUTO-SUMMARY-1A: 自动记忆总结设置区 */
  @Builder
  autoSummarySection(): void {
    Column() {
      Text('记忆总结')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      // 自动记忆总结开关
      Row() {
        Column() {
          Text('自动记忆总结')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text('聊天积累到一定程度后自动更新角色记忆')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.autoSummaryEnabled })
          .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
          .onChange((isOn: boolean) => {
            if (this.viewModel !== null) {
              this.viewModel.setAndPersistAutoSummaryEnabled(isOn);
              this.autoSummaryEnabled = isOn;
            }
          })
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

      // 总结详细程度(关闭时禁用但保留当前值)
      Row() {
        Text('总结详细程度')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.autoSummaryEnabled
            ? ThemePalette.textPrimaryColor(this.effectiveTheme) : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .layoutWeight(1)

        Text(this.autoSummaryLevelLabel(this.autoSummaryDetailLevel))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.autoSummaryEnabled
            ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ right: 4 })

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
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
      .margin({ top: $r('app.float.app_spacing_8') })
      .enabled(this.autoSummaryEnabled)
      .onClick(() => {
        this.autoSummaryLevelPickerVisible = true;
      })
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
  }

  /** G-GROUP-AUTO-SUMMARY-1A: 档位选择底部 Sheet(Stack 覆盖层) */
  @Builder
  autoSummaryLevelPickerDialog(): void {
    Stack() {
      Column() {
        Blank().layoutWeight(1)
        Column() {
          Column()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor(ThemePalette.dividerColor(this.effectiveTheme))
            .margin({ top: 8, bottom: 12 })

          Text('总结详细程度')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 4, left: 16, right: 16 })
            .width('100%')

          Text('档位只影响总结深度和输出长度,不改变角色可见性规则')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ bottom: 12, left: 16, right: 16 })
            .width('100%')

          // 简洁
          this.autoSummaryLevelOption(GroupAutoSummaryDetailLevel.Concise)
          // 中等
          this.autoSummaryLevelOption(GroupAutoSummaryDetailLevel.Medium)
          // 详细
          this.autoSummaryLevelOption(GroupAutoSummaryDetailLevel.Detailed)

          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .margin({ top: 12, left: 16, right: 16 })
            .accessibilityText('关闭详细程度选择')
            .onClick(() => {
              this.autoSummaryLevelPickerVisible = false;
            })
        }
        .width('100%')
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 0, bottomRight: 0 })
        .padding({ top: 0, bottom: this.navBarHeight + 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.autoSummaryLevelPickerVisible = false;
    })
    .transition(TransitionEffect.OPACITY)
  }

  /** 单个档位选项行 */
  @Builder
  autoSummaryLevelOption(level: GroupAutoSummaryDetailLevel): void {
    Row() {
      Column() {
        Text(getGroupAutoSummaryLevelSpec(level).label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.autoSummaryDetailLevel === level
            ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
        Text(this.autoSummaryLevelDescription(level))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.autoSummaryDetailLevel === level) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(16)
          .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .margin({ left: 16, right: 16 })
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      this.handleSelectAutoSummaryLevel(level);
    })
  }

  private handleSelectAutoSummaryLevel(level: GroupAutoSummaryDetailLevel): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.setAndPersistAutoSummaryDetailLevel(level);
    this.autoSummaryLevelPickerVisible = false;
    this.syncFromViewModel();
  }

  private autoSummaryLevelLabel(level: GroupAutoSummaryDetailLevel): string {
    return getGroupAutoSummaryLevelSpec(level).label;
  }

  private autoSummaryLevelDescription(level: GroupAutoSummaryDetailLevel): string {
    if (level === GroupAutoSummaryDetailLevel.Concise) {
      return '适合节省上下文,只保留关键事实';
    }
    if (level === GroupAutoSummaryDetailLevel.Detailed) {
      return '保留更多事件和长期细节';
    }
    return '兼顾连续性和上下文长度';
  }

  /** 失败处理方式区(尚无正式 Schema,显示为尚未开放) */
  @Builder
  failurePolicySection(): void {    Column() {
      Text($r('app.string.group_settings_failure_policy'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text('尚未开放')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .layoutWeight(1)
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
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
  }

  /** 管理成员入口 */
  @Builder
  manageMembersEntry(): void {
    Row() {
      Text($r('app.string.group_settings_manage_members'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
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
    .margin({ top: $r('app.float.app_spacing_16') })
    .onClick(() => {
      AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
      router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
    })
  }

  /** 清空聊天记录入口 */
  @Builder
  clearMessagesEntry(): void {
    Row() {
      Text($r('app.string.group_settings_clear_messages'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
      // G-RUNTIME-1C: 生成中显示禁用提示
      if (this.isGenerating) {
        Text('生成中')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
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
    .margin({ top: $r('app.float.app_spacing_16') })
    .enabled(!this.isClearing && !this.isDeleting && !this.isGenerating)
    .onClick(() => {
      this.clearConfirmVisible = true;
    })
  }

  /** 删除群聊入口 */
  @Builder
  deleteSessionEntry(): void {
    Row() {
      Text($r('app.string.group_settings_delete'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
      // G-RUNTIME-1C: 生成中显示禁用提示
      if (this.isGenerating) {
        Text('生成中')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
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
    .margin({ top: $r('app.float.app_spacing_16') })
    .enabled(!this.isDeleting && !this.isGenerating)
    .onClick(() => {
      this.deleteConfirmVisible = true;
    })
  }

  /** 重命名弹窗 */
  @Builder
  renameDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_rename'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })
            .width('100%')

          TextInput({ placeholder: $r('app.string.group_rename_placeholder'), text: this.renameInput })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.renameInput = value;
            })

          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.renameVisible = false;
                this.renameInput = '';
              })
            Button($r('app.string.group_save'))
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .enabled(!this.isRenaming)
              .onClick(() => {
                this.confirmRename();
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
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
  }

  /** 删除确认弹窗 */
  @Builder
  deleteConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_settings_delete'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_danger'))
            .margin({ bottom: 12 })
            .width('100%')

          Text($r('app.string.group_settings_delete_confirm'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')

          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.deleteConfirmVisible = false;
              })
            Button($r('app.string.group_confirm'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.confirmDeleteSession();
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
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
  }

  /** 清空消息确认弹窗 */
  @Builder
  clearConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_settings_clear_messages'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_danger'))
            .margin({ bottom: 12 })
            .width('100%')

          Text($r('app.string.group_settings_clear_confirm'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')

          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isClearing)
              .onClick(() => {
                this.clearConfirmVisible = false;
              })
            Button($r('app.string.group_confirm'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .enabled(!this.isClearing)
              .onClick(() => {
                this.confirmClearMessages();
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
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
  }

  /** 确认重命名 */
  private async confirmRename(): Promise<void> {
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.rename(trimmed);
      this.syncFromViewModel();
      this.renameVisible = false;
      this.renameInput = '';
      promptAction.showToast({ message: '已保存', duration: 1200 });
    } catch (e) {
      promptAction.showToast({ message: '重命名失败', duration: 1500 });
    }
  }

  /** 确认删除群聊 */
  private async confirmDeleteSession(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.delete();
      this.deleteConfirmVisible = false;
      promptAction.showToast({ message: '已删除群聊', duration: 1500 });
      // 替换页面栈为多人聊天首页,避免返回到已删除群聊的设置页
      router.replaceUrl({ url: 'pages/groupchat/GroupChatHomePage' });
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法删除群聊', duration: 1500 });
      } else {
        promptAction.showToast({ message: '删除失败', duration: 1500 });
      }
    }
  }

  /** 确认清空消息 */
  private async confirmClearMessages(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.clearMessages();
      this.syncFromViewModel();
      this.clearConfirmVisible = false;
      promptAction.showToast({ message: '已清空消息', duration: 1500 });
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法清空消息', duration: 1500 });
      } else {
        promptAction.showToast({ message: '清空失败', duration: 1500 });
      }
    }
  }

  /** GROUP-CHAT-TARGET-1: @角色回复模式选择 Sheet(底部锚定) */
  @Builder
  replyModePickerDialog(): void {
    Stack() {
      Column() {
        Blank().layoutWeight(1)
        Column() {
          Column()
            .width(36)
            .height(4)
            .borderRadius(2)
            .backgroundColor(ThemePalette.dividerColor(this.effectiveTheme))
            .margin({ top: 8, bottom: 12 })

          Text('@角色回复模式')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12, left: 16, right: 16 })
            .width('100%')

          // 选项:仅回复一次
          Row() {
            Text('仅回复一次')
              .fontSize($r('app.float.app_font_body'))
              .fontColor(this.replyTargetMode === 'one_shot'
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
              .layoutWeight(1)
            if (this.replyTargetMode === 'one_shot') {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
          .margin({ left: 16, right: 16 })
          .borderRadius($r('app.float.app_radius_sm'))
          .onClick(() => {
            this.handleSelectOneShotMode();
          })

          // 选项:持续与该角色对话
          Row() {
            Text('持续与该角色对话')
              .fontSize($r('app.float.app_font_body'))
              .fontColor(this.replyTargetMode === 'persistent'
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
              .layoutWeight(1)
            if (this.replyTargetMode === 'persistent') {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)
          .margin({ left: 16, right: 16 })
          .borderRadius($r('app.float.app_radius_sm'))
          .onClick(() => {
            this.handleSelectPersistentMode();
          })

          Button($r('app.string.group_cancel'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .margin({ top: 12, left: 16, right: 16 })
            .accessibilityText('关闭回复模式选择')
            .onClick(() => {
              this.replyModePickerVisible = false;
            })
        }
        .width('100%')
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 0, bottomRight: 0 })
        .padding({ top: 0, bottom: this.navBarHeight + 16 })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.replyModePickerVisible = false;
    })
    .transition(TransitionEffect.OPACITY)
  }

  private handleSelectOneShotMode(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.setAndPersistReplyTargetMode('one_shot');
    this.replyModePickerVisible = false;
    this.syncFromViewModel();
  }

  private handleSelectPersistentMode(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.setAndPersistReplyTargetMode('persistent');
    this.replyModePickerVisible = false;
    this.syncFromViewModel();
  }
}
