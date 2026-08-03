/**
 * GroupChatPage 多人聊天主页面(G-DATA-1B / G-RUNTIME-1A / G-RUNTIME-1B)
 *
 * 数据来源:
 * - GroupConversationPersistenceService(真实数据库)
 * - GroupConversationMessageService(真实消息)
 * - GroupChatRuntimeService(严格顺序流式生成)
 *
 * 状态:
 * - Loading:加载中
 * - Ready:展示群聊标题、成员、真实消息列表、启用输入区
 * - NotFound:群聊不存在或已删除
 * - Error:加载失败
 *
 * 本轮状态(G-RUNTIME-1B):
 * - Idle:无活动轮次,输入可用
 * - Generating:本轮 N/M · 角色正在回复,输入禁用,显示停止按钮
 * - Completed:本轮完成 · M 位角色已回复,输入恢复
 * - Cancelled:本轮已停止 · N/M 位角色已完成,输入恢复
 * - Failed:角色回复失败,输入恢复
 *
 * 消息区域:
 * - 有消息:显示真实消息列表(用户右对齐,角色左对齐)
 * - Streaming 消息:实时显示当前角色生成内容
 * - Cancelled/Failed:保留部分正文并显示状态标记
 *
 * 输入区:
 * - 启用真实发送
 * - 发送期间禁用按钮(isSending)
 * - 生成期间禁用发送,显示停止按钮
 * - 失败时保留输入内容
 *
 * 不依赖:GroupChatPreviewStore / 预览种子数据。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { GroupChatViewModel } from '../../viewmodels/groupchat/GroupChatViewModel';
import {
  GroupConversationDetailUiModel,
  GroupMemberUiModel,
  GroupMessageUiModel,
  GroupChatDetailState,
  GroupMessageListState,
  GroupMemberRuntimeState,
  GroupMemberRuntimeUiModel,
  PENDING_GROUP_CHAT_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { GroupRoundState } from '../../services/groupchat/GroupRoundTypes';
import { CharacterImageView } from '../../components/CharacterImageView';
import { ChatRole } from '../../models/ChatRole';
import { ChatMessageStatus } from '../../models/ChatMessage';

@Entry
@Component
struct GroupChatPage {
  /** 当前群聊 ID */
  @State chatId: string = '';
  /** 群聊详情(Ready 状态下非 null) */
  @State detail: GroupConversationDetailUiModel | null = null;
  /** 页面状态 */
  @State state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 消息列表 */
  @State messages: GroupMessageUiModel[] = [];
  /** 消息列表状态 */
  @State messageState: GroupMessageListState = GroupMessageListState.Loading;
  /** 输入框文本 */
  @State inputText: string = '';
  /** 是否正在发送 */
  @State isSending: boolean = false;
  /** 错误提示 */
  @State errorMessage: string = '';
  /** 本轮状态 */
  @State roundState: GroupRoundState = GroupRoundState.Idle;
  /** 是否正在生成 */
  @State isGenerating: boolean = false;
  /** 是否正在停止 */
  @State isStopping: boolean = false;
  /** 本轮错误消息 */
  @State roundErrorMessage: string = '';
  /** 当前发言者索引 */
  @State currentSpeakerIndex: number = -1;
  /** 已完成发言者数 */
  @State completedSpeakerCount: number = 0;
  /** 总发言者数 */
  @State totalSpeakerCount: number = 0;
  /** 当前发言者角色 ID */
  @State currentSpeakerCharacterId: string = '';
  /** 成员运行时状态 */
  @State memberRuntimeStates: GroupMemberRuntimeUiModel[] = [];
  /** 更多菜单是否可见 */
  @State moreMenuVisible: boolean = false;
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  private viewModel: GroupChatViewModel | null = null;
  private messageScroller: Scroller = new Scroller();
  /** ViewModel 状态轮询定时器(G-RUNTIME-1B) */
  private syncTimerId: number = -1;

  async aboutToAppear(): Promise<void> {
    const id: string = AppStorage.get<string>(PENDING_GROUP_CHAT_ID_KEY) ?? '';
    if (id.length === 0) {
      promptAction.showToast({ message: '未找到群聊', duration: 1500 });
      router.back();
      return;
    }
    this.chatId = id;
    // 清除 pending,避免返回后误用
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupChatViewModel();
      await this.viewModel.load(id);
      this.syncFromViewModel();
      // 启动状态轮询(生成期间持续同步 ViewModel 状态)
      this.startSyncPolling();
    } catch (e) {
      this.state = GroupChatDetailState.Error;
    }
  }

  /** 页面销毁时停止整轮并清理 */
  async aboutToDisappear(): Promise<void> {
    this.stopSyncPolling();
    if (this.viewModel !== null) {
      await this.viewModel.disposeWithStop();
      this.viewModel = null;
    }
  }

  /** 页面重新显示时刷新(从设置/成员管理返回);生成中不重新加载 */
  async onPageShow(): Promise<void> {
    if (this.viewModel === null || this.chatId.length === 0) {
      return;
    }
    // 生成中不重新加载,避免破坏活动轮次状态
    if (this.viewModel.isGenerating) {
      return;
    }
    await this.viewModel.load(this.chatId);
    this.syncFromViewModel();
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.detail = this.viewModel.detail;
    this.state = this.viewModel.state;
    this.messages = this.viewModel.messages;
    this.messageState = this.viewModel.messageState;
    this.inputText = this.viewModel.inputText;
    this.isSending = this.viewModel.isSending;
    this.errorMessage = this.viewModel.errorMessage;
    this.roundState = this.viewModel.roundState;
    this.isGenerating = this.viewModel.isGenerating;
    this.isStopping = this.viewModel.isStopping;
    this.roundErrorMessage = this.viewModel.roundErrorMessage;
    this.currentSpeakerIndex = this.viewModel.currentSpeakerIndex;
    this.completedSpeakerCount = this.viewModel.completedSpeakerCount;
    this.totalSpeakerCount = this.viewModel.totalSpeakerCount;
    this.currentSpeakerCharacterId = this.viewModel.currentSpeakerCharacterId;
    this.memberRuntimeStates = this.viewModel.memberRuntimeStates;
  }

  /** 启动状态轮询(生成期间持续同步) */
  private startSyncPolling(): void {
    this.stopSyncPolling();
    this.syncTimerId = setInterval((): void => {
      if (this.viewModel === null) {
        this.stopSyncPolling();
        return;
      }
      this.syncFromViewModel();
      // 不在生成中时停止轮询
      if (!this.viewModel.isGenerating && !this.viewModel.isSending) {
        this.stopSyncPolling();
      }
    }, 200);
  }

  /** 停止状态轮询 */
  private stopSyncPolling(): void {
    if (this.syncTimerId !== -1) {
      clearInterval(this.syncTimerId);
      this.syncTimerId = -1;
    }
  }

  build(): void {
    Column() {
      if (this.state === GroupChatDetailState.Loading) {
        this.loadingView()
      } else if (this.state === GroupChatDetailState.Error) {
        this.errorView()
      } else if (this.state === GroupChatDetailState.NotFound || this.detail === null) {
        this.notFoundView()
      } else {
        this.chatLayout()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
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
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
        .width('80%')
      Button('返回多人聊天首页')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
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

  /** 主聊天布局 */
  @Builder
  chatLayout(): void {
    Stack() {
      Column() {
        this.headerArea()
        this.memberStripArea()
        this.roundStatusBar()
        this.messageArea()
        this.inputBarArea()
      }
      .width('100%')
      .height('100%')

      if (this.moreMenuVisible) {
        this.moreMenuDialog()
      }
      if (this.renameVisible) {
        this.renameDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 本轮状态栏(G-RUNTIME-1B)。
   *
   * - Generating:本轮 N/M · 角色名正在回复
   * - Completed:本轮完成 · M 位角色已回复
   * - Cancelled:本轮已停止 · N/M 位角色已完成
   * - Failed:角色名回复失败
   * - Idle:不显示
   */
  @Builder
  roundStatusBar(): void {
    if (this.roundState === GroupRoundState.Idle) {
      // Idle 不显示
    } else {
      Row() {
        Text(this.composeRoundStatusText())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.isGenerating) {
          Button() {
            Row() {
              if (this.isStopping) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color($r('app.color.app_on_accent'))
                  .margin({ right: 4 })
              } else {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([$r('app.color.app_on_accent')])
                  .margin({ right: 4 })
              }
              Text(this.isStopping ? '停止中' : '停止本轮')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_on_accent'))
            }
          }
          .type(ButtonType.Capsule)
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(30)
          .padding({ left: 12, right: 12 })
          .key('group.stop_round_btn')
          .accessibilityText('停止本轮')
          .enabled(!this.isStopping)
          .onClick(() => {
            this.handleStopRound();
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.app_surface_2'))
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 构建本轮状态文案 */
  private composeRoundStatusText(): string {
    const current: number = this.currentSpeakerIndex >= 0
      ? this.currentSpeakerIndex + 1 : 0;
    const total: number = this.totalSpeakerCount;
    const currentName: string = this.findMemberName(this.currentSpeakerCharacterId);

    if (this.roundState === GroupRoundState.Generating) {
      if (currentName.length > 0) {
        return '本轮 ' + String(current) + '/' + String(total) + ' · ' + currentName + '正在回复';
      }
      return '本轮 ' + String(current) + '/' + String(total) + ' · 正在回复';
    }
    if (this.roundState === GroupRoundState.Completed) {
      return '本轮完成 · ' + String(total) + ' 位角色已回复';
    }
    if (this.roundState === GroupRoundState.Cancelled) {
      return '本轮已停止 · ' + String(this.completedSpeakerCount) + '/' + String(total) + ' 位角色已完成';
    }
    if (this.roundState === GroupRoundState.Failed) {
      if (currentName.length > 0) {
        return currentName + '回复失败';
      }
      return '本轮失败';
    }
    return '';
  }

  /** 根据 characterId 查找成员名称 */
  private findMemberName(characterId: string): string {
    if (characterId.length === 0 || this.detail === null) {
      return '';
    }
    for (let i = 0; i < this.detail.members.length; i++) {
      if (this.detail.members[i].characterId === characterId) {
        return this.detail.members[i].name;
      }
    }
    return '';
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

      Column() {
        Text(this.detail!.title)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.composeMemberSubtitle())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4, right: 8 })

      Button() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('更多操作')
      .onClick(() => {
        this.moreMenuVisible = true;
      })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_8'),
      right: $r('app.float.app_spacing_12'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 构建成员副标题 */
  private composeMemberSubtitle(): string {
    const members: GroupMemberUiModel[] = this.detail !== null ? this.detail.members : [];
    const enabled: number = members.filter((m: GroupMemberUiModel): boolean => m.isEnabled).length;
    return String(members.length) + ' 位成员 · ' + String(enabled) + ' 位启用';
  }

  /**
   * 成员横向栏(G-RUNTIME-1B)。
   *
   * - 生成中:使用 memberRuntimeStates 显示运行状态(Completed/Generating/Waiting)
   * - 非生成中:显示 detail.members(包含停用成员)
   */
  @Builder
  memberStripArea(): void {
    Scroll() {
      Row() {
        if (this.isGenerating && this.memberRuntimeStates.length > 0) {
          ForEach(this.memberRuntimeStates, (member: GroupMemberRuntimeUiModel) => {
            Column() {
              Stack() {
                CharacterImageView({
                  imageUri: member.avatarUri,
                  fallbackName: member.name,
                  imgWidth: 44,
                  imgHeight: 44,
                  imgBorderRadius: 22,
                  displayMode: 'thumbnail',
                  objectFit: ImageFit.Cover
                })
                // 运行状态徽标
                if (member.runtimeState === GroupMemberRuntimeState.Generating) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color($r('app.color.app_accent'))
                    .position({ x: 30, y: -2 })
                } else if (member.runtimeState === GroupMemberRuntimeState.Completed) {
                  Text('✓')
                    .fontSize(12)
                    .fontColor($r('app.color.app_on_accent'))
                    .backgroundColor($r('app.color.app_accent'))
                    .borderRadius(8)
                    .width(16)
                    .height(16)
                    .textAlign(TextAlign.Center)
                    .position({ x: 30, y: -2 })
                }
              }
              .width(44)
              .height(44)

              Text(member.name)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(this.memberRuntimeTextColor(member.runtimeState))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(56)
                .textAlign(TextAlign.Center)
                .margin({ top: 4 })
                .opacity(this.memberRuntimeOpacity(member.runtimeState))
            }
            .margin({ left: 8, right: 8 })
          }, (member: GroupMemberRuntimeUiModel) => member.characterId + '|' + member.runtimeState)
        } else {
          ForEach(this.detail!.members, (member: GroupMemberUiModel) => {
            Column() {
              Stack() {
                CharacterImageView({
                  imageUri: member.avatarUri,
                  fallbackName: member.name,
                  imgWidth: 44,
                  imgHeight: 44,
                  imgBorderRadius: 22,
                  displayMode: 'thumbnail',
                  objectFit: ImageFit.Cover
                })
                if (!member.characterExists) {
                  // 缺失角色标记
                  Text('!')
                    .fontSize(12)
                    .fontColor($r('app.color.app_on_accent'))
                    .backgroundColor($r('app.color.app_danger'))
                    .borderRadius(8)
                    .width(16)
                    .height(16)
                    .textAlign(TextAlign.Center)
                    .position({ x: 30, y: -2 })
                }
              }
              .width(44)
              .height(44)

              Text(member.name)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(member.isEnabled ? $r('app.color.app_text_primary') : $r('app.color.app_text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(56)
                .textAlign(TextAlign.Center)
                .margin({ top: 4 })
                .opacity(member.isEnabled ? 1 : 0.5)
            }
            .margin({ left: 8, right: 8 })
          }, (member: GroupMemberUiModel) => member.characterId + '|' + String(member.speakerOrder) + '|' + String(member.isEnabled))
        }
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    }
    .width('100%')
    .height(78)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 成员运行时状态文字颜色 */
  private memberRuntimeTextColor(state: GroupMemberRuntimeState): ResourceColor {
    if (state === GroupMemberRuntimeState.Generating) {
      return $r('app.color.app_accent');
    }
    if (state === GroupMemberRuntimeState.Completed) {
      return $r('app.color.app_text_primary');
    }
    return $r('app.color.app_text_tertiary');
  }

  /** 成员运行时状态透明度 */
  private memberRuntimeOpacity(state: GroupMemberRuntimeState): number {
    if (state === GroupMemberRuntimeState.Waiting) {
      return 0.5;
    }
    if (state === GroupMemberRuntimeState.Idle) {
      return 0.4;
    }
    return 1;
  }

  /** 消息列表区 */
  @Builder
  messageArea(): void {
    if (this.messageState === GroupMessageListState.Loading) {
      Column() {
        Text('加载消息…')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.messages.length === 0) {
      Column() {
        Text('还没有消息')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ scroller: this.messageScroller }) {
        ForEach(this.messages, (msg: GroupMessageUiModel) => {
          ListItem() {
            this.messageBubble(msg)
          }
          .margin({ left: 12, right: 12, top: 6, bottom: 6 })
        }, (msg: GroupMessageUiModel) => msg.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange(() => {
        // 消息列表变化后滚动到底部
        if (this.messages.length > 0) {
          this.messageScroller.scrollEdge(Edge.Bottom);
        }
      })
    }
  }

  /** 单条消息气泡 */
  @Builder
  messageBubble(msg: GroupMessageUiModel): void {
    if (msg.role === ChatRole.User) {
      // 用户消息:右对齐
      Row() {
        Column() {
          Text(msg.content)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.chat_user_text'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.chat_user_bubble'))
        .borderRadius($r('app.float.app_radius_md'))
        .constraintSize({ maxWidth: '75%' })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    } else {
      // AI 角色消息:左对齐
      Row() {
        Column() {
          CharacterImageView({
            imageUri: msg.senderAvatarUri ?? '',
            fallbackName: msg.senderName,
            imgWidth: 32,
            imgHeight: 32,
            imgBorderRadius: 16,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })
            .margin({ right: 8 })
        }
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text(msg.senderName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(msg.characterExists ? $r('app.color.app_text_secondary') : $r('app.color.app_danger'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (msg.status === ChatMessageStatus.Streaming && msg.content.length === 0) {
            // Streaming 但尚无内容:显示等待提示
            Row() {
              LoadingProgress()
                .width(14)
                .height(14)
                .color($r('app.color.app_text_tertiary'))
                .margin({ right: 6 })
              Text('正在思考…')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
            }
            .margin({ top: 2 })
          } else {
            Text(msg.content)
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.chat_text_primary'))
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 2 })
          }

          if (msg.status === ChatMessageStatus.Streaming && msg.content.length > 0) {
            // Streaming 中且有内容:显示生成中标记
            Text('生成中…')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_accent'))
              .margin({ top: 2 })
          } else if (msg.status === ChatMessageStatus.Cancelled) {
            Text('已停止')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .margin({ top: 2 })
          } else if (msg.status === ChatMessageStatus.Failed) {
            Text('生成失败')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .margin({ top: 2 })
          }
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.chat_assistant_bubble'))
        .borderRadius($r('app.float.app_radius_md'))
        .constraintSize({ maxWidth: '75%' })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Top)
    }
  }

  /** 输入区(启用真实发送) */
  @Builder
  inputBarArea(): void {
    Column() {
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
      }
      if (this.roundErrorMessage.length > 0) {
        Text(this.roundErrorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
      }

      Row() {
        TextInput({ placeholder: '发送消息', text: this.inputText })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(40)
          .padding({ left: 12, right: 12 })
          .layoutWeight(1)
          .enabled(!this.isSending && !this.isGenerating)
          .onChange((value: string) => {
            this.inputText = value;
            if (this.viewModel !== null) {
              this.viewModel.inputText = value;
            }
          })
          .onSubmit(() => {
            this.handleSend();
          })

        if (this.isGenerating) {
          // 生成中:显示停止按钮(与状态栏的停止按钮同步,这里不重复显示)
          // 状态栏已有停止入口,这里保持发送按钮置灰
          Button() {
            SymbolGlyph($r('sys.symbol.paperplane_fill'))
              .fontSize(20)
              .fontColor([$r('app.color.app_text_tertiary')])
          }
          .type(ButtonType.Circle)
          .backgroundColor($r('app.color.app_text_tertiary'))
          .width(40)
          .height(40)
          .margin({ left: 8 })
          .enabled(false)
        } else {
          Button() {
            SymbolGlyph($r('sys.symbol.paperplane_fill'))
              .fontSize(20)
              .fontColor([$r('app.color.app_on_accent')])
          }
          .type(ButtonType.Circle)
          .backgroundColor(this.isSending ? $r('app.color.app_text_tertiary') : $r('app.color.app_accent'))
          .width(40)
          .height(40)
          .margin({ left: 8 })
          .enabled(!this.isSending && this.inputText.trim().length > 0)
          .onClick(() => {
            this.handleSend();
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: this.navBarHeight + 4
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
  }

  /** 处理发送 */
  private async handleSend(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const content: string = this.inputText.trim();
    if (content.length === 0 || this.isSending || this.isGenerating) {
      return;
    }
    await this.viewModel.sendUserMessage(content);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0 && this.viewModel.inputText.length === 0) {
      // 发送成功,清空本地输入框
      this.inputText = '';
    }
    // 生成已启动,启动状态轮询
    if (this.viewModel.isGenerating) {
      this.startSyncPolling();
    }
  }

  /** 处理停止本轮 */
  private async handleStopRound(): Promise<void> {
    if (this.viewModel === null || !this.isGenerating || this.isStopping) {
      return;
    }
    await this.viewModel.stopRound();
    this.syncFromViewModel();
  }

  /** 更多菜单弹窗 */
  @Builder
  moreMenuDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_more_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          Button($r('app.string.group_chat_menu_manage'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .onClick(() => {
              this.moreMenuVisible = false;
              this.goManageMembers();
            })

          Button($r('app.string.group_chat_menu_settings'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.moreMenuVisible = false;
              this.goSettings();
            })

          Button($r('app.string.group_chat_menu_rename'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.moreMenuVisible = false;
              this.renameInput = this.detail !== null ? this.detail.title : '';
              this.renameVisible = true;
            })

          Button($r('app.string.group_cancel'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 12 })
            .onClick(() => {
              this.moreMenuVisible = false;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
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
      this.moreMenuVisible = false;
    })
  }

  private goManageMembers(): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
  }

  private goSettings(): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupChatSettingsPage' });
  }

  /** 重命名弹窗 */
  @Builder
  renameDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_chat_menu_rename'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          TextInput({ placeholder: $r('app.string.group_rename_placeholder'), text: this.renameInput })
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
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
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.renameVisible = false;
                this.renameInput = '';
              })
            Button($r('app.string.group_save'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmRename();
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
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
}
