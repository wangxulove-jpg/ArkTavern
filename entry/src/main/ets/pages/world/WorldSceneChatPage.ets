import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldSceneChatViewModel,
  WorldSceneChatLoadState,
  WorldSceneChatUiModel,
  ChatMessageUiModel,
  ChatCharacterUiModel,
  formatChatTimestamp
} from '../../viewmodels/world/WorldSceneChatViewModel';
import {
  PENDING_WORLD_SCENE_CHAT_ID_KEY,
  PENDING_WORLD_SESSION_ID_KEY,
  PENDING_WORLD_MEMORY_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY,
  WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldConversationSessionStatus } from '../../models/world/WorldConversationSession';
import {
  WorldSceneMessageVisibility,
  WorldSceneMessageSenderType,
  WorldSceneMessageStatus
} from '../../models/world/WorldSceneMessage';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { CharacterImageView } from '../../components/CharacterImageView';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneChatPage';

@Entry
@Component
struct WorldSceneChatPage {
  @State private viewModel: WorldSceneChatViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldSceneChatLoadState = WorldSceneChatLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldSceneChatUiModel | null = null;
  @State private actionError: string = '';
  @State private endConfirmVisible: boolean = false;

  @State private inputContent: string = '';
  @State private isGenerating: boolean = false;
  @State private isStopping: boolean = false;
  @State private isSending: boolean = false;
  @State private runtimeError: string = '';
  @State private streamingMessageId: string = '';
  @State private streamingContent: string = '';

  @State private characterSheetInstanceId: string = '';

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp(WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  sceneRefreshToken: number = 0;

  private scroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const sceneId: string = AppStorage.get<string>(PENDING_WORLD_SCENE_CHAT_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_SCENE_CHAT_ID_KEY, '');
      const sessionId: string = AppStorage.get<string>(PENDING_WORLD_SESSION_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_SESSION_ID_KEY, '');
      if (sceneId.length === 0 || sessionId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: sceneId or sessionId empty');
        this.isInitializing = false;
        this.loadState = WorldSceneChatLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldSceneChatViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneMessageRepository(),
        AppServices.getWorldConversationSessionRepository(),
        AppServices.getCharacterService(),
        AppServices.getWorldSceneService(),
        AppServices.getWorldSceneRuntimeService()
      );
      this.viewModel.setSceneId(sceneId);
      this.viewModel.setSessionId(sessionId);
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldSceneChatLoadState.Error;
      this.errorMessage = '场景数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.activate();
    await this.loadSnapshot();
  }

  onRefreshTokenChange(): void {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.activate();
    this.loadSnapshot();
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  private async loadSnapshot(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.loadSnapshot(this.viewModel.expectedSceneIdOfPage());
    this.syncFromViewModel();
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
    this.isGenerating = this.viewModel.isGenerating;
    this.isStopping = this.viewModel.isStopping;
    this.isSending = this.viewModel.isSending;
    this.runtimeError = this.viewModel.runtimeError;
    this.streamingMessageId = this.viewModel.streamingMessageId;
    this.streamingContent = this.viewModel.streamingContent;
  }

  private isSessionActive(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sessionStatus === WorldConversationSessionStatus.Active;
  }

  private isSessionEnded(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sessionStatus === WorldConversationSessionStatus.Ended;
  }

  private isSceneWritable(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sceneStatus === WorldSceneStatus.Active
      && this.detail.worldStatus === WorldStatus.Active
      && this.detail.locationStatus === WorldLocationStatus.Active;
  }

  private canSend(): boolean {
    if (this.viewModel === null) {
      return false;
    }
    if (this.isGenerating || this.isSending) {
      return false;
    }
    if (!this.isSessionActive()) {
      return false;
    }
    if (!this.isSceneWritable()) {
      return false;
    }
    if (!this.viewModel.isSingleParticipant()) {
      return false;
    }
    return true;
  }

  build(): void {
    Column() {
      this.headerArea()
      if (this.isInitializing || this.loadState === WorldSceneChatLoadState.Loading) {
        this.loadingView()
      } else if (this.loadState === WorldSceneChatLoadState.NotFound) {
        this.notFoundView()
      } else if (this.loadState === WorldSceneChatLoadState.Error) {
        this.errorView()
      } else if (this.loadState === WorldSceneChatLoadState.Ready && this.detail !== null) {
        this.contentView(this.detail)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.endConfirmVisible, this.endConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => { this.endConfirmVisible = false; }
    })
    .bindSheet(this.characterSheetInstanceId.length > 0, this.characterInfoSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => { this.characterSheetInstanceId = ''; }
    })
  }

  @Builder
  headerArea(): void {
    Column() {
      Row() {
        Button('←')
          .fontSize(22)
          .fontColor($r('app.color.world_text_secondary'))
          .backgroundColor(Color.Transparent)
          .width(40)
          .height(40)
          .padding(0)
          .onClick(() => { router.back(); })

        Column() {
          if (this.detail !== null) {
            Text(this.detail.sceneName)
              .fontSize($r('app.float.world_font_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.world_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row() {
              WorldStatusChip({
                label: this.detail.sessionStatus === WorldConversationSessionStatus.Active ? '进行中' : '已结束',
                isActive: this.detail.sessionStatus === WorldConversationSessionStatus.Active
              })
              Text('会话 #' + this.detail.sessionSequenceNumber.toString())
                .fontSize($r('app.float.world_font_micro'))
                .fontColor($r('app.color.world_text_tertiary'))
                .margin({ left: 6 })
              if (this.detail.characters.length > 0) {
                Text(this.detail.characters[0].displayName)
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor($r('app.color.world_text_secondary'))
                  .margin({ left: 6 })
              }
            }
            .margin({ top: 2 })
          } else {
            Text($r('app.string.world_scene_chat_title'))
              .fontSize($r('app.float.world_font_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.world_text_primary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 4 })

        if (this.detail !== null && this.isSceneWritable() && this.isSessionActive()
          && !this.isGenerating) {
          Text('⋯')
            .fontSize(22)
            .fontColor($r('app.color.world_text_secondary'))
            .backgroundColor($r('app.color.world_surface_1'))
            .borderRadius($r('app.float.world_radius_chip'))
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.endConfirmVisible = true; })
        }
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: this.statusBarHeight + 4,
        bottom: 4
      })
      .alignItems(VerticalAlign.Center)

      if (this.detail !== null) {
        this.characterStripArea(this.detail.characters)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  characterStripArea(characters: ChatCharacterUiModel[]): void {
    if (characters.length === 0) {
      Text($r('app.string.world_scene_no_characters'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 8, bottom: 8 })
    } else {
      Scroll() {
        Row() {
          ForEach(characters, (c: ChatCharacterUiModel) => {
            this.characterChip(c)
          }, (c: ChatCharacterUiModel) => c.instanceId + '|' + (c.isActive ? '1' : '0'))
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(64)
      .padding({ top: 4, bottom: 4 })
    }
  }

  @Builder
  characterChip(c: ChatCharacterUiModel): void {
    Column() {
      Stack() {
        CharacterImageView({
          imageUri: c.avatarUri,
          fallbackName: c.fallbackName,
          imgWidth: 36,
          imgHeight: 36,
          imgBorderRadius: 18,
          displayMode: 'thumbnail'
        })
        if (!c.isActive) {
          Circle({ width: 10, height: 10 })
            .fill($r('app.color.world_text_tertiary'))
            .position({ x: 26, y: 26 })
        }
      }
      .width(36)
      .height(36)
      Text(c.displayName)
        .fontSize(10)
        .fontColor(c.isActive ? $r('app.color.world_text_primary') : $r('app.color.world_text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .width(48)
    .margin({ right: 8 })
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { this.characterSheetInstanceId = c.instanceId; })
  }

  @Builder
  contentView(detail: WorldSceneChatUiModel): void {
    Column() {
      if (this.viewModel !== null && this.viewModel.isZeroParticipant()) {
        this.participantErrorView('会话参与者数据异常')
      } else if (this.viewModel !== null && this.viewModel.isMultiParticipant()) {
        this.multiParticipantView()
      } else {
        if (detail.messages.length === 0) {
          this.emptyMessageView()
        } else {
          List({ scroller: this.scroller }) {
            ForEach(detail.messages, (m: ChatMessageUiModel) => {
              ListItem() {
                this.messageBubble(m)
              }
            }, (m: ChatMessageUiModel) => m.id + '|' + m.messageStatus)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .scrollBar(BarState.Auto)
        }
      }

      if (this.actionError.length > 0) {
        Text(this.actionError)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_error'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      if (this.runtimeError.length > 0) {
        Text(this.runtimeError)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_error'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 4 })
      }

      if (this.isSessionEnded()) {
        this.endedSessionBar()
      } else if (!this.isSceneWritable()) {
        this.endedSceneBar()
      } else if (this.viewModel !== null && this.viewModel.isMultiParticipant()) {
        this.multiParticipantBar()
      } else if (this.viewModel !== null && this.viewModel.isZeroParticipant()) {
        this.participantErrorBar()
      } else if (this.isSessionActive()) {
        this.runtimeInputArea()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  emptyMessageView(): void {
    Column() {
      Text($r('app.string.world_scene_empty_messages'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 40 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  participantErrorView(msg: string): void {
    Column() {
      Text(msg)
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_error'))
        .margin({ top: 40 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  multiParticipantView(): void {
    Column() {
      if (this.detail !== null && this.detail.messages.length > 0) {
        List({ scroller: this.scroller }) {
          ForEach(this.detail.messages, (m: ChatMessageUiModel) => {
            ListItem() {
              this.messageBubble(m)
            }
          }, (m: ChatMessageUiModel) => m.id + '|' + m.messageStatus)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .scrollBar(BarState.Auto)
      } else {
        this.emptyMessageView()
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  messageBubble(m: ChatMessageUiModel): void {
    Column() {
      Row() {
        if (m.senderType === WorldSceneMessageSenderType.Character && m.senderAvatarUri.length > 0) {
          CharacterImageView({
            imageUri: m.senderAvatarUri,
            fallbackName: m.senderFallbackName,
            imgWidth: 24,
            imgHeight: 24,
            imgBorderRadius: 12,
            displayMode: 'thumbnail'
          })
          .margin({ right: 6 })
        }

        Text(this.senderLabel(m))
          .fontSize($r('app.float.world_font_micro'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.senderLabelColor(m.senderType))
          .backgroundColor(this.senderLabelBg(m.senderType))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })

        if (m.messageStatus !== 'completed') {
          Text(this.statusTag(m.messageStatus))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor(this.statusColor(m.messageStatus))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 4 })
        }

        Text(formatChatTimestamp(m.createdAt))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ left: 6 })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (m.id === this.streamingMessageId && this.streamingContent.length > 0) {
        Text(this.streamingContent)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .width('100%')
          .margin({ top: 4 })
          .textAlign(TextAlign.Start)
      } else if (m.messageStatus === 'streaming') {
        Row() {
          LoadingProgress().width(14).height(14).color($r('app.color.world_gold'))
          Text('生成中')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ left: 6 })
        }
        .margin({ top: 4 })
      } else {
        Text(m.content)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .width('100%')
          .margin({ top: 4 })
          .textAlign(TextAlign.Start)
      }

      if (m.messageStatus === 'failed') {
        Row() {
          Text('角色回复失败')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
          Text('重试')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ left: 8 })
            .enabled(this.canSend())
            .onClick(() => { this.retryFailed(m.id); })
        }
        .margin({ top: 6 })
      }

      if (m.messageStatus === 'cancelled') {
        Text('已停止')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_card'))
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  runtimeInputArea(): void {
    Column() {
      Row() {
        TextArea({ text: this.inputContent, placeholder: '输入消息...' })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .layoutWeight(1)
          .height(44)
          .onChange((v: string) => { this.inputContent = v; })

        if (this.isGenerating && !this.isStopping) {
          Text('停止')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_on_danger'))
            .backgroundColor($r('app.color.world_error'))
            .borderRadius($r('app.float.world_radius_button'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ left: 6 })
            .onClick(() => { this.stopGeneration(); })
        } else if (this.isStopping) {
          Text('停止中')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_button'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ left: 6 })
        } else {
          Text('发送')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .borderRadius($r('app.float.world_radius_button'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ left: 6 })
            .enabled(this.canSend() && this.inputContent.trim().length > 0)
            .onClick(() => { this.sendUserMessage(); })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 + this.navBarHeight })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  endedSceneBar(): void {
    Column() {
      Text($r('app.string.world_scene_ended_hint'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 + this.navBarHeight })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  endedSessionBar(): void {
    Column() {
      Text('该会话已结束')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 + this.navBarHeight })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  multiParticipantBar(): void {
    Column() {
      Text('当前会话包含多名角色,多人世界聊天将在下一阶段接入')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 + this.navBarHeight })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  participantErrorBar(): void {
    Column() {
      Text('会话参与者数据异常')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_error'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 + this.navBarHeight })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress().width(40).height(40).color($r('app.color.world_gold'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      Text($r('app.string.world_scene_not_found'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_tertiary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      Text(this.errorMessage.length > 0 ? this.errorMessage : '场景数据加载失败,请重试')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_error'))
      Text('重试')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_on_gold'))
        .backgroundColor($r('app.color.world_gold'))
        .borderRadius($r('app.float.world_radius_button'))
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .margin({ top: 12 })
        .onClick(() => { this.loadSnapshot(); })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  endConfirmSheet(): void {
    Column() {
      Text($r('app.string.world_scene_end_confirm_title'))
        .fontSize($r('app.float.world_font_subtitle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_scene_end_confirm_desc'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })

      Row() {
        WorldSecondaryButton({
          label: $r('app.string.world_scene_cancel'),
          onButtonClick: (): void => { this.endConfirmVisible = false; }
        })
          .layoutWeight(1)
        Text($r('app.string.world_scene_end'))
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_on_danger'))
          .backgroundColor($r('app.color.world_error'))
          .borderRadius($r('app.float.world_radius_button'))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .onClick(() => { this.endScene(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  characterInfoSheet(): void {
    Column() {
      Text($r('app.string.world_memory_character_sheet_title'))
        .fontSize($r('app.float.world_font_subtitle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      if (this.detail !== null) {
        Row() {
          CharacterImageView({
            imageUri: this.resolveCharacterAvatar(this.characterSheetInstanceId),
            fallbackName: this.resolveCharacterFallback(this.characterSheetInstanceId),
            imgWidth: 44,
            imgHeight: 44,
            imgBorderRadius: 22,
            displayMode: 'thumbnail'
          })

          Column() {
            Text(this.resolveCharacterName(this.characterSheetInstanceId))
              .fontSize($r('app.float.world_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.world_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Row() {
              WorldStatusChip({
                label: this.resolveCharacterActive(this.characterSheetInstanceId) ? '活跃' : '停用',
                isActive: this.resolveCharacterActive(this.characterSheetInstanceId)
              })
              if (this.resolveCharacterCardMissing(this.characterSheetInstanceId)) {
                Text($r('app.string.world_character_card_missing'))
                  .fontSize(10)
                  .fontColor($r('app.color.world_error'))
                  .backgroundColor($r('app.color.world_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .margin({ left: 4 })
              }
              Text(this.detail.locationName)
                .fontSize(10)
                .fontColor($r('app.color.world_text_secondary'))
                .backgroundColor($r('app.color.world_surface_2'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ left: 4 })
            }
            .margin({ top: 4 })
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        WorldPrimaryButton({
          label: $r('app.string.world_memory_view_entry'),
          onButtonClick: (): void => {
            this.openCharacterMemoryFromScene(this.characterSheetInstanceId);
          }
        })
          .width('100%')
          .margin({ left: 16, right: 16, bottom: 8 })

        Text($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .margin({ left: 16, right: 16, bottom: 16 })
          .textAlign(TextAlign.Center)
          .onClick(() => { this.characterSheetInstanceId = ''; })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  private async sendUserMessage(): Promise<void> {
    if (this.viewModel === null || this.detail === null) {
      return;
    }
    const content: string = this.inputContent.trim();
    if (content.length === 0) {
      this.actionError = '消息不能为空';
      return;
    }
    this.actionError = '';
    this.runtimeError = '';
    this.inputContent = '';
    const errorMsg: string = await this.viewModel.sendMessage(content);
    if (errorMsg.length > 0) {
      this.actionError = errorMsg;
    }
    this.syncFromViewModel();
  }

  private stopGeneration(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.stopGeneration();
    this.syncFromViewModel();
  }

  private async retryFailed(messageId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.actionError = '';
    this.runtimeError = '';
    const errorMsg: string = await this.viewModel.retryFailedMessage(messageId);
    if (errorMsg.length > 0) {
      this.actionError = errorMsg;
    }
    this.syncFromViewModel();
  }

  private async endScene(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.actionError = '';
    const errorMsg: string = await this.viewModel.endScene();
    if (errorMsg.length > 0) {
      this.actionError = errorMsg;
    } else {
      this.endConfirmVisible = false;
    }
    this.syncFromViewModel();
  }

  private senderLabel(m: ChatMessageUiModel): string {
    if (m.senderType === WorldSceneMessageSenderType.User) {
      if (this.detail !== null && this.detail.playerDisplayNameSnapshot.length > 0) {
        return '[玩家·' + this.detail.playerDisplayNameSnapshot + ']';
      }
      return '[玩家]';
    }
    if (m.senderType === WorldSceneMessageSenderType.Character) {
      if (m.senderRemoved) {
        return '[角色·已移除]';
      }
      return '[角色·' + (m.senderDisplayName.length > 0 ? m.senderDisplayName : '未命名') + ']';
    }
    return '[旁白]';
  }

  private senderLabelColor(t: WorldSceneMessageSenderType): ResourceColor {
    if (t === WorldSceneMessageSenderType.User) {
      return $r('app.color.world_on_gold');
    }
    if (t === WorldSceneMessageSenderType.Character) {
      return $r('app.color.world_text_primary');
    }
    return $r('app.color.world_text_tertiary');
  }

  private senderLabelBg(t: WorldSceneMessageSenderType): ResourceColor {
    if (t === WorldSceneMessageSenderType.User) {
      return $r('app.color.world_gold');
    }
    if (t === WorldSceneMessageSenderType.Character) {
      return $r('app.color.world_surface_2');
    }
    return $r('app.color.world_surface_1');
  }

  private statusTag(s: string): string {
    if (s === 'streaming') {
      return '生成中';
    }
    if (s === 'cancelled') {
      return '已停止';
    }
    if (s === 'failed') {
      return '失败';
    }
    return '已完成';
  }

  private statusColor(s: string): ResourceColor {
    if (s === 'streaming') {
      return $r('app.color.world_gold');
    }
    if (s === 'cancelled') {
      return $r('app.color.world_text_tertiary');
    }
    if (s === 'failed') {
      return $r('app.color.world_error');
    }
    return $r('app.color.world_text_secondary');
  }

  private resolveCharacterName(instanceId: string): string {
    if (this.detail === null || instanceId.length === 0) {
      return '';
    }
    return this.resolveInstanceName(this.detail, instanceId);
  }

  private resolveInstanceName(detail: WorldSceneChatUiModel, instanceId: string): string {
    for (let i = 0; i < detail.characters.length; i++) {
      if (detail.characters[i].instanceId === instanceId) {
        return detail.characters[i].displayName;
      }
    }
    return '已移除角色';
  }

  private resolveCharacterAvatar(instanceId: string): string {
    if (this.detail === null) {
      return '';
    }
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].avatarUri;
      }
    }
    return '';
  }

  private resolveCharacterFallback(instanceId: string): string {
    if (this.detail === null) {
      return '';
    }
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].fallbackName;
      }
    }
    return '';
  }

  private resolveCharacterActive(instanceId: string): boolean {
    if (this.detail === null) {
      return false;
    }
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].isActive;
      }
    }
    return false;
  }

  private resolveCharacterCardMissing(instanceId: string): boolean {
    if (this.detail === null) {
      return false;
    }
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].characterCardMissing;
      }
    }
    return false;
  }

  private openCharacterMemoryFromScene(instanceId: string): void {
    if (this.detail === null || instanceId.length === 0) {
      return;
    }
    const worldId: string = this.detail.worldId;
    if (worldId.length === 0) {
      return;
    }
    this.characterSheetInstanceId = '';
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterMemoryPage' });
  }
}
