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
import { GroupMessageRenderState } from '../../viewmodels/groupchat/GroupMessageRenderState';
import { GroupRoundState } from '../../services/groupchat/GroupRoundTypes';
import { CharacterImageView } from '../../components/CharacterImageView';
import { GroupMessageBubble } from '../../components/groupchat/GroupMessageBubble';
import { GroupGenerationErrorCard } from '../../components/groupchat/GroupGenerationErrorCard';
import { ChatRole } from '../../models/ChatRole';
import { ChatMessageStatus } from '../../models/ChatMessage';
import { ChatTextStyle } from '../../utils/ChatTextStyleSettings';
import { Logger } from '../../utils/Logger';

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
  /**
   * 稳定渲染状态列表(G-RUNTIME-1C-FIX)。
   * @Observed GroupMessageRenderState,ForEach 数据源,key 固定为 messageId。
   * 与单聊 ChatPage.messageStates 采用完全相同的模式:
   * - 同一 messageId 始终复用已有 RenderState 实例
   * - 已有实例就地调用 applyMessage,@Observed 字段赋值触发 @ObjectLink 响应式重建
   * - 新消息才创建新 RenderState
   */
  @State messageStates: GroupMessageRenderState[] = [];
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
  /** G-RUNTIME-1C: 是否正在重试 */
  @State isRetrying: boolean = false;
  /** G-RUNTIME-1C: 是否正在结束本轮 */
  @State isEndingRound: boolean = false;
  /** G-RUNTIME-1D: 是否有另一个群聊正在运行(跨群聊隔离提示) */
  @State isAnotherChatRunning: boolean = false;
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
  /** G-CONTROL-2A: 选中目标成员 UI 模型列表(空数组表示全员回复) */
  @State selectedReplyTargetMembers: GroupMemberUiModel[] = [];
  /** G-CONTROL-2A: @选择器是否可见 */
  @State isMentionPickerVisible: boolean = false;
  /** G-CONTROL-2A: @选择器候选成员 */
  @State mentionCandidates: GroupMemberUiModel[] = [];
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  /**
   * 聊天文本样式设置(G-RUNTIME-1C-FIX)。
   * 复用单聊同一套 ChatTextStyleSettings,确保多人消息字体/行距/Markdown
   * 与单聊保持一致。从 AppServices.chatTextStyleSettings 加载。
   */
  @State chatTextStyle: ChatTextStyle | null = null;

  private viewModel: GroupChatViewModel | null = null;
  private messageScroller: Scroller = new Scroller();
  /** ViewModel 状态轮询定时器(G-RUNTIME-1B) */
  private syncTimerId: number = -1;
  /**
   * RenderState 缓存(G-RUNTIME-1C-FIX)。
   * key=messageId,value=GroupMessageRenderState 实例。
   * 与单聊 ChatPage.stateMap 采用相同模式,保证 ForEach 稳定复用气泡组件。
   */
  private stateMap: Map<string, GroupMessageRenderState> = new Map();

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
      // 加载聊天文本样式(复用单聊同一套 ChatTextStyleSettings)
      this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
      this.viewModel = new GroupChatViewModel();
      // 设置消息更新回调(即时同步 RenderState,不依赖 200ms 轮询)
      this.viewModel.onMessagesUpdate = (msgs: GroupMessageUiModel[]): void => {
        this.messages = msgs;
        this.syncRenderStates(msgs);
      };
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
    // 刷新聊天文本样式(用户可能在设置页修改了显示偏好)
    this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
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
    // 同步稳定 RenderState 列表(与单聊 ChatPage.syncRenderStates 相同模式)
    this.syncRenderStates(this.viewModel.messages);
    this.messageState = this.viewModel.messageState;
    this.inputText = this.viewModel.inputText;
    this.isSending = this.viewModel.isSending;
    this.errorMessage = this.viewModel.errorMessage;
    this.roundState = this.viewModel.roundState;
    this.isGenerating = this.viewModel.isGenerating;
    this.isStopping = this.viewModel.isStopping;
    this.isRetrying = this.viewModel.isRetrying;
    this.isEndingRound = this.viewModel.isEndingRound;
    // G-RUNTIME-1D: 同步跨群聊运行状态(用于显示隔离提示)
    this.isAnotherChatRunning = this.viewModel.isAnotherChatRunning();
    this.roundErrorMessage = this.viewModel.roundErrorMessage;
    this.currentSpeakerIndex = this.viewModel.currentSpeakerIndex;
    this.completedSpeakerCount = this.viewModel.completedSpeakerCount;
    this.totalSpeakerCount = this.viewModel.totalSpeakerCount;
    this.currentSpeakerCharacterId = this.viewModel.currentSpeakerCharacterId;
    this.memberRuntimeStates = this.viewModel.memberRuntimeStates;
    // G-CONTROL-2A: 同步草稿回复目标状态(多目标)
    this.selectedReplyTargetMembers = [...this.viewModel.selectedReplyTargetMembers];
    this.isMentionPickerVisible = this.viewModel.isMentionPickerVisible;
    this.mentionCandidates = this.viewModel.mentionCandidates;
  }

  /**
   * 同步最新消息到稳定 RenderState 列表(G-RUNTIME-1C-FIX)。
   *
   * 与单聊 ChatPage.syncRenderStates 采用完全相同的模式:
   * - 同一 messageId 始终复用已有 RenderState 实例,保证 ForEach 稳定复用气泡
   * - 已有实例就地调用 applyMessage,@Observed 字段赋值触发 @ObjectLink 响应式重建
   * - 新消息才创建新 RenderState
   * - 已不存在于最新消息中的旧状态从缓存中移除
   * - 始终按最新消息顺序生成新 messageStates 数组(不原地修改)
   *
   * 这是解决"消息正文不刷新、需退出重进"根因的关键:
   * ForEach 在固定 key(messageId)下复用 GroupMessageBubble 时,
   * 普通参数传递不触发重渲染;通过 @Observed + @ObjectLink,
   * applyMessage 的字段赋值直接触发气泡重建。
   */
  private syncRenderStates(messages: GroupMessageUiModel[]): void {
    const nextStates: GroupMessageRenderState[] = [];
    const newIds: Set<string> = new Set<string>();
    for (let i: number = 0; i < messages.length; i++) {
      const msg: GroupMessageUiModel = messages[i];
      newIds.add(msg.id);
      let state: GroupMessageRenderState | undefined = this.stateMap.get(msg.id);
      if (state === undefined) {
        state = new GroupMessageRenderState(msg);
        this.stateMap.set(msg.id, state);
      } else {
        state.applyMessage(msg);
      }
      nextStates.push(state);
    }
    // 清理已不在最新消息列表中的旧状态
    const oldIds: string[] = Array.from(this.stateMap.keys());
    for (let i: number = 0; i < oldIds.length; i++) {
      if (!newIds.has(oldIds[i])) {
        this.stateMap.delete(oldIds[i]);
      }
    }
    this.messageStates = nextStates;
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
      // 不在生成/重试/结束本轮中时停止轮询
      if (!this.viewModel.isGenerating && !this.viewModel.isSending
        && !this.viewModel.isRetrying && !this.viewModel.isEndingRound) {
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
        this.crossChatBanner()
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
   * G-RUNTIME-1D: 跨群聊运行隔离提示。
   *
   * 当另一个群聊正在生成时,当前页面显示提示横幅:
   * - 不显示 A 的停止按钮(本页 isGenerating=false,停止按钮不会出现)
   * - 不允许发送新一轮(输入区禁用)
   * - 提示用户先结束另一个群聊的回复
   */
  @Builder
  crossChatBanner(): void {
    if (this.isAnotherChatRunning) {
      Row() {
        Text('另一个多人聊天正在回复,请先结束当前回复')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.app_surface_2'))
      .alignItems(VerticalAlign.Center)
    }
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
                } else if (this.isMemberReplyTarget(member.characterId)) {
                  // G-CONTROL-1: 被选为回复目标的成员显示靶心标记
                  Text('◎')
                    .fontSize(14)
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
                .fontColor(this.memberTextColor(member))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(56)
                .textAlign(TextAlign.Center)
                .margin({ top: 4 })
                .opacity(this.memberOpacity(member))
            }
            .margin({ left: 8, right: 8 })
            .opacity(member.isEnabled && member.characterExists ? 1 : 0.6)
            .onClick(() => {
              this.handleMemberClick(member);
            })
          }, (member: GroupMemberUiModel) => member.characterId + '|' + String(member.speakerOrder) + '|' + String(member.isEnabled) + '|' + (this.isMemberReplyTarget(member.characterId) ? '1' : '0'))
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
    // G-CONTROL-2A: 有限成员轮次中未选中的启用成员,半透明显示
    if (state === GroupMemberRuntimeState.NotParticipating) {
      return 0.4;
    }
    return 1;
  }

  // ===== G-CONTROL-2A 成员栏点击与目标选择 =====

  /** G-CONTROL-2A: 判断成员是否为当前回复目标(多选,检查数组) */
  private isMemberReplyTarget(characterId: string): boolean {
    for (let i = 0; i < this.selectedReplyTargetMembers.length; i++) {
      if (this.selectedReplyTargetMembers[i].characterId === characterId) {
        return true;
      }
    }
    return false;
  }

  /** G-CONTROL-1: 成员栏文字颜色(非生成态) */
  private memberTextColor(member: GroupMemberUiModel): ResourceColor {
    if (this.isMemberReplyTarget(member.characterId)) {
      return $r('app.color.app_accent');
    }
    if (!member.isEnabled) {
      return $r('app.color.app_text_tertiary');
    }
    return $r('app.color.app_text_primary');
  }

  /** G-CONTROL-1: 成员栏透明度(非生成态) */
  private memberOpacity(member: GroupMemberUiModel): number {
    if (!member.isEnabled || !member.characterExists) {
      return 0.5;
    }
    return 1;
  }

  /**
   * G-CONTROL-2A: 构建输入栏目标 Chip 文案。
   *
   * 规则:
   * - 1 个目标:仅{name}回复
   * - 2+ 个目标:指定 N 位角色回复
   * - 空数组:返回空(不会进入此分支,全员显示提示文案)
   */
  private composeTargetChipText(): string {
    const members: GroupMemberUiModel[] = this.selectedReplyTargetMembers;
    if (members.length === 0) {
      return '';
    }
    if (members.length === 1) {
      return '仅' + members[0].name + '回复';
    }
    return '指定 ' + String(members.length) + ' 位角色回复';
  }

  /** G-CONTROL-1: 处理成员栏点击 */
  private handleMemberClick(member: GroupMemberUiModel): void {
    if (this.viewModel === null) {
      return;
    }
    // 生成中不允许切换目标
    if (this.isGenerating || this.isSending) {
      return;
    }
    const ok: boolean = this.viewModel.toggleMemberReplyTarget(member.characterId);
    if (!ok) {
      // 校验失败,显示错误提示
      if (this.viewModel.errorMessage.length > 0) {
        promptAction.showToast({ message: this.viewModel.errorMessage, duration: 1500 });
      }
      return;
    }
    this.syncFromViewModel();
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
    } else if (this.messageStates.length === 0) {
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
        ForEach(this.messageStates, (state: GroupMessageRenderState) => {
          ListItem() {
            Column() {
              // 复用单聊同款 ChatRichText 渲染,@ObjectLink 响应式刷新
              GroupMessageBubble({
                renderState: state,
                settings: this.chatTextStyle
              })
              // G-RUNTIME-1C-FIX: 最近一条 Failed/Cancelled 角色消息下方显示重试/结束本轮卡片
              if (this.shouldShowErrorCard(state)) {
                GroupGenerationErrorCard({
                  errorText: this.composeErrorCardText(state),
                  isRetrying: this.isRetrying,
                  isEndingRound: this.isEndingRound,
                  onRetry: () => {
                    this.handleRetrySpeaker(state);
                  },
                  onEndRound: () => {
                    this.handleEndRound();
                  }
                })
                  .margin({ top: 6 })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .margin({ left: 12, right: 12, top: 6, bottom: 6 })
        }, (state: GroupMessageRenderState) => state.messageId)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange(() => {
        // 消息列表变化后滚动到底部
        if (this.messageStates.length > 0) {
          this.messageScroller.scrollEdge(Edge.Bottom);
        }
      })
    }
  }

  /**
   * G-RUNTIME-1C-FIX: 判断指定消息是否应该显示重试/结束本轮卡片。
   *
   * 修复要点(与用户实机问题 1 对齐):
   * - 不再依赖 roundState(页面重入后 roundState 重置为 Idle,导致重试入口消失)
   * - 改为基于消息自身真实状态(Failed/Cancelled)判断
   * - 退出重进后只要数据库消息仍为可重试状态,重试入口正确出现
   *
   * 规则:
   * - 仅角色消息(role !== User, senderCharacterId 存在)
   * - 消息状态为 Failed 或 Cancelled
   * - 角色仍存在(characterExists)
   * - 当前无活动生成/重试/结束本轮
   * - 仅最近一条可重试的角色消息显示大型错误卡
   */
  private shouldShowErrorCard(state: GroupMessageRenderState): boolean {
    // 生成/重试/结束本轮进行中:隐藏卡片(新 Streaming 已在底部)
    if (this.isGenerating || this.isRetrying || this.isEndingRound) {
      return false;
    }
    // 仅角色消息
    if (state.role === ChatRole.User) {
      return false;
    }
    if (state.senderCharacterId.length === 0) {
      return false;
    }
    if (state.status !== ChatMessageStatus.Failed && state.status !== ChatMessageStatus.Cancelled) {
      return false;
    }
    // 缺失角色无法重试
    if (!state.characterExists) {
      return false;
    }
    // 仅最近一条 Failed/Cancelled 角色消息
    return this.findLatestRetryableMessageId() === state.messageId;
  }

  /** 查找最近一条可重试的角色消息 ID */
  private findLatestRetryableMessageId(): string {
    for (let i: number = this.messageStates.length - 1; i >= 0; i--) {
      const s: GroupMessageRenderState = this.messageStates[i];
      if (s.role === ChatRole.User) {
        continue;
      }
      if (s.senderCharacterId.length === 0) {
        continue;
      }
      if (!s.characterExists) {
        continue;
      }
      if (s.status === ChatMessageStatus.Failed || s.status === ChatMessageStatus.Cancelled) {
        return s.messageId;
      }
    }
    return '';
  }

  /** 构建错误卡片文案 */
  private composeErrorCardText(state: GroupMessageRenderState): string {
    const name: string = state.senderName;
    if (state.status === ChatMessageStatus.Failed) {
      return name + ' 回复失败';
    }
    if (state.status === ChatMessageStatus.Cancelled) {
      return name + ' 已停止,可重试当前角色';
    }
    return '回复失败';
  }

  /** G-RUNTIME-1C-FIX: 处理重试当前角色 */
  private async handleRetrySpeaker(state: GroupMessageRenderState): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isGenerating || this.isRetrying || this.isEndingRound) {
      return;
    }
    // 构造 GroupMessageUiModel 用于 canRetryMessage 校验
    const msg: GroupMessageUiModel = {
      id: state.messageId,
      role: state.role,
      content: state.content,
      status: state.status,
      senderCharacterId: state.senderCharacterId.length > 0 ? state.senderCharacterId : undefined,
      senderName: state.senderName,
      senderAvatarUri: state.senderAvatarUri.length > 0 ? state.senderAvatarUri : undefined,
      characterExists: state.characterExists,
      generationBatchId: state.generationBatchId.length > 0 ? state.generationBatchId : undefined,
      sequenceNumber: 0,
      createdAt: state.createdAt,
      updatedAt: state.updatedAt,
      replyTargetCharacterIds: [],
      replyTargetNames: []
    };
    if (!this.viewModel.canRetryMessage(msg)) {
      promptAction.showToast({ message: '当前消息无法重试', duration: 1500 });
      return;
    }
    Logger.info('GroupChatPage', 'handleRetrySpeaker msgId=' + state.messageId);
    // 先启动轮询,确保 await retrySpeakerMessage 期间状态即时同步
    this.startSyncPolling();
    await this.viewModel.retrySpeakerMessage(state.messageId);
    this.syncFromViewModel();
    // 重试已启动,确保轮询运行
    if (this.viewModel.isGenerating) {
      this.startSyncPolling();
    }
  }

  /** G-RUNTIME-1C: 处理结束本轮 */
  private async handleEndRound(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.isRetrying || this.isEndingRound) {
      return;
    }
    Logger.info('GroupChatPage', 'handleEndRound');
    await this.viewModel.endRound();
    this.syncFromViewModel();
  }

  /** 输入区(启用真实发送,G-CONTROL-1 增加目标 Chip 与 @选择器) */
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

      // G-CONTROL-2A: 目标 Chip(多选摘要)+ 输入提示
      Row() {
        if (this.selectedReplyTargetMembers.length > 0) {
          // 指定角色:显示目标摘要 Chip + 选中数量
          Row() {
            Text(this.composeTargetChipText())
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_on_accent'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(12)
                .fontColor([$r('app.color.app_on_accent')])
            }
            .type(ButtonType.Circle)
            .backgroundColor(Color.Transparent)
            .width(20)
            .height(20)
            .margin({ left: 4 })
            .accessibilityText('取消全部指定角色')
            .enabled(!this.isGenerating && !this.isSending)
            .onClick(() => {
              this.handleClearReplyTarget();
            })
          }
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .alignItems(VerticalAlign.Center)
        } else {
          // 全员:显示提示文案
          Text('所有启用角色将按顺序回复')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })

      Row() {
        TextInput({ placeholder: '发送消息(输入 @ 指定角色)', text: this.inputText })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(40)
          .padding({ left: 12, right: 12 })
          .layoutWeight(1)
          .enabled(!this.isSending && !this.isGenerating && !this.isAnotherChatRunning)
          .onChange((value: string) => {
            this.inputText = value;
            if (this.viewModel !== null) {
              this.viewModel.inputText = value;
            }
            this.handleMentionDetection(value);
          })
          .onSubmit(() => {
            this.handleSend();
          })

        if (this.isGenerating) {
          // 生成中:发送按钮置灰
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
          .enabled(!this.isSending && !this.isAnotherChatRunning && this.inputText.trim().length > 0)
          .onClick(() => {
            this.handleSend();
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // G-CONTROL-1: @选择器浮层(紧贴输入框下方)
      if (this.isMentionPickerVisible && this.mentionCandidates.length > 0) {
        this.mentionPickerPanel()
      }
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

  /** G-CONTROL-2A: @选择器面板(显示已选中状态) */
  @Builder
  mentionPickerPanel(): void {
    Column() {
      List() {
        ForEach(this.mentionCandidates, (member: GroupMemberUiModel) => {
          ListItem() {
            Row() {
              CharacterImageView({
                imageUri: member.avatarUri,
                fallbackName: member.name,
                imgWidth: 28,
                imgHeight: 28,
                imgBorderRadius: 14,
                displayMode: 'thumbnail',
                objectFit: ImageFit.Cover
              })
              Text(member.name)
                .fontSize($r('app.float.app_font_body'))
                .fontColor(this.isMemberReplyTarget(member.characterId)
                  ? $r('app.color.app_accent')
                  : $r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 8 })
                .layoutWeight(1)
              // G-CONTROL-2A: 已选中的角色显示 ✓ 标记
              if (this.isMemberReplyTarget(member.characterId)) {
                Text('✓')
                  .fontSize(14)
                  .fontColor($r('app.color.app_accent'))
                  .margin({ left: 4 })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .alignItems(VerticalAlign.Center)
          }
          .onClick(() => {
            this.handleSelectMention(member);
          })
        }, (member: GroupMemberUiModel) => member.characterId + '|' + (this.isMemberReplyTarget(member.characterId) ? '1' : '0'))
      }
      .width('100%')
      .height(200)
      .scrollBar(BarState.Auto)
      .borderRadius($r('app.float.app_radius_md'))
      .backgroundColor($r('app.color.app_surface_2'))
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /** G-CONTROL-1: 检测输入框中的 @触发点 */
  private handleMentionDetection(value: string): void {
    if (this.viewModel === null) {
      return;
    }
    // 生成中不处理 @检测
    if (this.isGenerating || this.isSending) {
      return;
    }
    // 查找最后一个 @
    const atIdx: number = value.lastIndexOf('@');
    if (atIdx < 0) {
      // 没有 @,关闭选择器
      if (this.viewModel.isMentionPickerVisible) {
        this.viewModel.closeMentionPicker();
        this.syncFromViewModel();
      }
      return;
    }
    // @ 必须在行首或前面是空白
    if (atIdx > 0) {
      const prevChar: string = value.charAt(atIdx - 1);
      if (prevChar !== ' ' && prevChar !== '\n' && prevChar !== '\t') {
        // @不在词首,关闭选择器
        if (this.viewModel.isMentionPickerVisible) {
          this.viewModel.closeMentionPicker();
          this.syncFromViewModel();
        }
        return;
      }
    }
    // 提取 @ 后的查询文本(直到空白或结尾)
    let query: string = '';
    for (let i: number = atIdx + 1; i < value.length; i++) {
      const ch: string = value.charAt(i);
      if (ch === ' ' || ch === '\n' || ch === '\t') {
        break;
      }
      query = query + ch;
    }
    // 更新或打开选择器
    if (this.viewModel.isMentionPickerVisible) {
      this.viewModel.updateMentionQuery(query);
    } else {
      this.viewModel.openMentionPicker(query);
    }
    this.syncFromViewModel();
  }

  /** G-CONTROL-1: 选择 @角色 */
  private handleSelectMention(member: GroupMemberUiModel): void {
    if (this.viewModel === null) {
      return;
    }
    const insertText: string = this.viewModel.selectMentionTarget(member.characterId);
    if (insertText.length === 0) {
      this.syncFromViewModel();
      return;
    }
    // 替换输入框中的 @查询 为 @角色名
    const value: string = this.inputText;
    const atIdx: number = value.lastIndexOf('@');
    if (atIdx >= 0) {
      const before: string = value.substring(0, atIdx);
      this.inputText = before + insertText;
      if (this.viewModel !== null) {
        this.viewModel.inputText = this.inputText;
      }
    }
    // 显示多次 @提示(如有)
    if (this.viewModel.errorMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.errorMessage, duration: 1500 });
    }
    this.syncFromViewModel();
  }

  /** G-CONTROL-1: 取消回复目标 */
  private handleClearReplyTarget(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearReplyTarget();
    this.syncFromViewModel();
  }

  /**
   * 处理发送(G-RUNTIME-1C-FIX)。
   *
   * 关键修复:
   * - 在 await sendUserMessage 之前先启动轮询。
   * - sendUserMessage 内部 await startRound 会阻塞直到整轮完成,
   *   如果轮询在 await 之后启动,整个生成期间页面状态不会刷新。
   * - 先启动轮询,确保 await 期间 ViewModel 状态变化(轮次/消息)即时同步到页面。
   * - onMessagesUpdate 回调负责消息即时刷新,轮询负责 roundState 等其他状态。
   */
  private async handleSend(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const content: string = this.inputText.trim();
    if (content.length === 0 || this.isSending || this.isGenerating) {
      return;
    }
    // 先启动轮询,确保 await sendUserMessage 期间状态即时同步
    this.startSyncPolling();
    await this.viewModel.sendUserMessage(content);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0 && this.viewModel.inputText.length === 0) {
      // 发送成功,清空本地输入框
      this.inputText = '';
    }
    // 生成已启动,确保轮询运行
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
