import { router, window, display } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldSceneChatViewModel,
  WorldSceneChatLoadState,
  WorldSceneChatUiModel,
  ChatMessageUiModel,
  ChatCharacterUiModel,
  RoundProgressUiModel,
  WorldRoundUiStatus,
  formatChatTimestamp
} from '../../viewmodels/world/WorldSceneChatViewModel';
import {
  PENDING_WORLD_SCENE_CHAT_ID_KEY,
  PENDING_WORLD_SESSION_ID_KEY,
  PENDING_WORLD_MEMORY_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY,
  PENDING_WORLD_INSPECTOR_WORLD_ID_KEY,
  PENDING_WORLD_INSPECTOR_SCENE_ID_KEY,
  PENDING_WORLD_INSPECTOR_SESSION_ID_KEY,
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
import { WorldChatMessageBubble } from '../../components/world/WorldChatMessageBubble';
import { ChatTextStyle } from '../../utils/ChatTextStyleSettings';
import { loadBubbleOpacity, persistBubbleOpacity, DEFAULT_BUBBLE_OPACITY } from '../../utils/ChatBubbleAppearance';
import { ChatBackgroundConfig } from '../../services/ChatBackgroundService';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

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
  @State private roundProgress: RoundProgressUiModel | null = null;
  @State private roundStatus: WorldRoundUiStatus = WorldRoundUiStatus.Idle;

  @State chatBgConfig: ChatBackgroundConfig | null = null;
  @StorageProp('chatBgConfigVersion') @Watch('loadChatBackground') chatBgConfigVersion: number = 0;
  @State bubbleOpacity: number = DEFAULT_BUBBLE_OPACITY;
  @State isDarkMode: boolean = true;
  @State chatTextStyle: ChatTextStyle | null = null;
  @State appearancePanelVisible: boolean = false;
  @State characterStripExpanded: boolean = true;

  @State private characterSheetInstanceId: string = '';

  @State keyboardHeight: number = 0;
  private keyboardHeightChangeHandler: ((height: number) => void) | null = null;
  private mainWindow: window.Window | null = null;

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
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
        AppServices.getWorldRepository(), AppServices.getWorldLocationRepository(),
        AppServices.getWorldCharacterInstanceRepository(), AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneMessageRepository(), AppServices.getWorldConversationSessionRepository(),
        AppServices.getCharacterService(), AppServices.getWorldSceneService(),
        AppServices.getWorldConversationSessionService(), AppServices.getWorldSessionPostProcessingOrchestrator(),
        AppServices.getWorldSceneRuntimeService()
      );
      this.viewModel.setSceneId(sceneId);
      this.viewModel.setSessionId(sessionId);
      this.viewModel.onStateChanged = (): void => { this.syncFromViewModel(); };
      this.isInitializing = false;
      this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
      this.bubbleOpacity = await loadBubbleOpacity();
      this.registerKeyboardListener();
      await this.loadSnapshot();
      this.loadChatBackground();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldSceneChatLoadState.Error;
      this.errorMessage = '场景数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) { return; }
    this.viewModel.activate();
    await this.loadSnapshot();
  }

  onRefreshTokenChange(): void {
    if (this.isInitializing || this.viewModel === null) { return; }
    this.viewModel.activate();
    this.loadSnapshot();
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) { this.viewModel.dispose(); }
    this.unregisterKeyboardListener();
  }

  private async loadSnapshot(): Promise<void> {
    if (this.viewModel === null) { return; }
    await this.viewModel.loadSnapshot(this.viewModel.expectedSceneIdOfPage());
    this.syncFromViewModel();
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) { return; }
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
    this.isGenerating = this.viewModel.isGenerating;
    this.isStopping = this.viewModel.isStopping;
    this.isSending = this.viewModel.isSending;
    this.runtimeError = this.viewModel.runtimeError;
    this.streamingMessageId = this.viewModel.streamingMessageId;
    this.streamingContent = this.viewModel.streamingContent;
    this.roundProgress = this.viewModel.roundProgress;
    this.roundStatus = this.viewModel.roundStatus;
  }

  private isSessionActive(): boolean {
    return this.detail !== null && this.detail.sessionStatus === WorldConversationSessionStatus.Active;
  }
  private isSessionEnded(): boolean {
    return this.detail !== null && this.detail.sessionStatus === WorldConversationSessionStatus.Ended;
  }
  private isSceneWritable(): boolean {
    return this.detail !== null && this.detail.sceneStatus === WorldSceneStatus.Active
      && this.detail.worldStatus === WorldStatus.Active
      && this.detail.locationStatus === WorldLocationStatus.Active;
  }
  private canSend(): boolean {
    if (this.viewModel === null) { return false; }
    if (this.isGenerating || this.isSending) { return false; }
    if (!this.isSessionActive()) { return false; }
    if (!this.isSceneWritable()) { return false; }
    if (this.viewModel.isZeroParticipant()) { return false; }
    return true;
  }

  build(): void {
    Stack() {
      if (this.loadState === WorldSceneChatLoadState.Ready && this.detail !== null) {
        if (this.chatBgConfig !== null && this.chatBgConfig!.enabled && this.chatBgConfig!.imageUri.length > 0) {
          Image(this.chatBgConfig!.imageUri).width('100%').height('100%').objectFit(ImageFit.Cover)
            .blur(this.chatBgConfig!.blur).hitTestBehavior(HitTestMode.Transparent)
            .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
          Column().width('100%').height('100%')
            .backgroundColor('rgba(0,0,0,' + (this.chatBgConfig!.dim / 100).toString() + ')')
            .hitTestBehavior(HitTestMode.Transparent)
            .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
        }
        this.chatLayout()
        this.topBarLayer()
        this.inputBarLayer()
      } else if (this.isInitializing || this.loadState === WorldSceneChatLoadState.Loading) {
        this.loadingView()
      } else if (this.loadState === WorldSceneChatLoadState.NotFound) {
        this.notFoundView()
      } else if (this.loadState === WorldSceneChatLoadState.Error) {
        this.errorView()
      }

      if (this.appearancePanelVisible) { this.appearancePanel() }

      Column().width(0).height(0).bindSheet(this.endConfirmVisible, this.endConfirmSheet, {
        height: SheetSize.FIT_CONTENT, dragBar: true,
        backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
        onDisappear: () => { this.endConfirmVisible = false; } })
      Column().width(0).height(0).bindSheet(this.characterSheetInstanceId.length > 0, this.characterInfoSheet, {
        height: SheetSize.FIT_CONTENT, dragBar: true,
        backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
        onDisappear: () => { this.characterSheetInstanceId = ''; } })
    }
    .width('100%').height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder chatLayout(): void {
    Column() {
      if (this.detail !== null && this.detail.messages.length > 0) {
        List({ scroller: this.scroller }) {
          ForEach(this.detail.messages, (m: ChatMessageUiModel) => {
            ListItem() {
              WorldChatMessageBubble({ message: m, bubbleOpacity: this.bubbleOpacity,
                isDarkMode: this.isDarkMode, settings: this.chatTextStyle,
                isStreaming: m.id === this.streamingMessageId,
                streamingContent: m.id === this.streamingMessageId ? this.streamingContent : '' })
            }.margin({ left: 16, right: 16 })
          }, (m: ChatMessageUiModel) => m.id + '_' + m.messageStatus)

          if (this.isGenerating || this.isSending) {
            ListItem() {
              Row() {
                if (this.streamingContent.length > 0 && this.streamingMessageId.length > 0) {
                  Text('正在生成...').fontSize(11).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                    .fontStyle(FontStyle.Italic)
                } else {
                  Text('角色思考中...').fontSize(11).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                    .fontStyle(FontStyle.Italic)
                }
              }.width('100%').justifyContent(FlexAlign.Center).padding({ left: 16, right: 16, top: 8, bottom: 8 })
            }
          }

          ListItem() {
            Column().width('100%')
              .height(this.keyboardHeight > 0 ? 80 + this.keyboardHeight : 80 + this.navBarHeight)
          }
        }
        .width('100%').layoutWeight(1)
        .padding({ top: this.statusBarHeight + 60, bottom: 0 })
        .scrollBar(BarState.Auto)
      } else {
        Column() {
          Text('该场景暂无消息,发送第一条消息开始对话。')
            .fontSize($r('app.float.app_font_body')).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center).width('100%')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      }
    }.width('100%').height('100%')
    .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
  }

  @Builder topBarLayer(): void {
    Column() {
      this.topBarContent()
    }.width('100%').height('100%').justifyContent(FlexAlign.Start).hitTestBehavior(HitTestMode.Transparent)
    .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
  }

  @Builder topBarContent(): void {
    Column() {
      Row() {
        Button('←').fontSize(22).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent).width(40).height(40).onClick(() => { router.back(); })
        if (this.detail !== null) {
          Column() {
            Text(this.detail.sceneName).fontSize(13).fontWeight(FontWeight.Bold)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme)).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('会话 #' + this.detail.sessionSequenceNumber.toString() + ' · ' +
              this.detail.participantCount.toString() + '名角色')
              .fontSize(10).fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).maxLines(1)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 4, right: 4 })
        }
        Stack() { SymbolGlyph($r('sys.symbol.textformat')).fontSize(20)
          .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)]) }
          .width(40).height(40).margin({ right: 4 }).borderRadius($r('app.float.app_radius_sm'))
          .backgroundColor(this.appearancePanelVisible ? ThemePalette.surface2Color(this.effectiveTheme) : Color.Transparent)
          .onClick(() => { this.appearancePanelVisible = !this.appearancePanelVisible; })
        if (this.detail !== null && this.isSceneWritable() && this.isSessionActive() && !this.isGenerating) {
          Stack() { SymbolGlyph($r('sys.symbol.more')).fontSize(22)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)]) }
            .width(40).height(40).onClick(() => { this.endConfirmVisible = true; })
        }
      }.width('100%').padding({ left: 4, right: 4, top: this.statusBarHeight + 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      if (this.detail !== null && this.detail.characters.length > 0) {
        Row() {
          Text(this.detail.characters.length.toString() + '位角色').fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).layoutWeight(1).maxLines(1)
          Button(this.characterStripExpanded ? '收起 ▲' : '展开 ▼').fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).backgroundColor(Color.Transparent)
            .height(24).padding({ left: 8, right: 8 })
            .onClick(() => { this.characterStripExpanded = !this.characterStripExpanded; })
        }.width('100%').padding({ left: 12, right: 12, top: 2, bottom: 2 }).alignItems(VerticalAlign.Center)
        if (this.characterStripExpanded) {
          Scroll() {
            Row() {
              ForEach(this.detail.characters, (c: ChatCharacterUiModel) => {
                Column() {
                  Stack() {
                    CharacterImageView({ imageUri: c.avatarUri, fallbackName: c.fallbackName,
                      imgWidth: 36, imgHeight: 36, imgBorderRadius: 18, displayMode: 'thumbnail' })
                    if (!c.isActive) { Circle({ width: 8, height: 8 })
                      .fill(ThemePalette.textTertiaryColor(this.effectiveTheme)).position({ x: 28, y: 28 }) }
                  }.width(36).height(36)
                  Text(c.displayName).fontSize(9)
                    .fontColor(c.isActive ? ThemePalette.textSecondaryColor(this.effectiveTheme) : ThemePalette.textTertiaryColor(this.effectiveTheme))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
                }.width(48).margin({ right: 8 }).alignItems(HorizontalAlign.Center)
                .onClick(() => { this.characterSheetInstanceId = c.instanceId; })
              }, (c: ChatCharacterUiModel) => c.instanceId)
            }.padding({ left: 16, right: 16 })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').height(56)
        }
      }
    }.width('100%')
  }

  @Builder inputBarLayer(): void {
    Column() { this.inputBarContent() }.width('100%')
      .height('100%').justifyContent(FlexAlign.End).hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder inputBarContent(): void {
    Column() {
      if (this.actionError.length > 0) {
        Text(this.actionError).fontSize(11).fontColor($r('app.color.world_error')).width('100%')
          .textAlign(TextAlign.Center).padding({ bottom: 4 })
      }
      if (this.isSessionEnded()) {
        Text('该会话已结束').fontSize(12).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%').textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 + this.navBarHeight })
      } else if (!this.isSceneWritable()) {
        Text($r('app.string.world_scene_ended_hint')).fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).width('100%').textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 + this.navBarHeight })
      } else if (this.viewModel !== null && this.viewModel.isZeroParticipant()) {
        Text('会话参与者数据异常').fontSize(12).fontColor($r('app.color.world_error')).width('100%')
          .textAlign(TextAlign.Center).padding({ left: 16, right: 16, top: 8, bottom: 8 + this.navBarHeight })
      } else if (this.roundStatus === WorldRoundUiStatus.Resumable) {
        Row() {
          Text('上一轮未完成').fontSize(12).fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).layoutWeight(1)
          Button('续跑').fontSize(12).fontColor($r('app.color.app_on_accent')).backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(16).height(32).padding({ left: 14, right: 14 }).onClick(() => { this.resumeRound(); })
        }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 + this.navBarHeight }).alignItems(VerticalAlign.Center)
      } else if (this.isSessionActive()) {
        Row() {
          TextArea({ text: this.inputContent, placeholder: '发送消息…' }).fontSize(13)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme)).placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent).borderRadius(0).constraintSize({ minHeight: 36, maxHeight: 120 })
            .layoutWeight(1).onChange((v: string) => { this.inputContent = v; })
          if (this.isGenerating && !this.isStopping) {
            Button('✕').fontSize(18).fontColor($r('app.color.app_on_accent')).backgroundColor($r('app.color.world_error'))
              .borderRadius(24).width(44).height(44).margin({ left: 8 }).onClick(() => { this.stopGeneration(); })
          } else if (this.isStopping) {
            LoadingProgress().width(20).height(20).color(ThemePalette.accentColor(this.effectiveTheme)).margin({ left: 14 })
          } else {
            Button('↑').fontSize(20).fontColor($r('app.color.app_on_accent'))
              .backgroundColor(this.canSend() && this.inputContent.trim().length > 0 ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius(24).width(44).height(44).margin({ left: 8 })
              .enabled(this.canSend() && this.inputContent.trim().length > 0).onClick(() => { this.sendUserMessage(); })
          }
        }.width('100%').backgroundColor(ThemePalette.surface1Color(this.effectiveTheme)).borderRadius(28)
          .border({ width: 0.5, color: ThemePalette.surface2Color(this.effectiveTheme) })
          .padding({ left: 16, right: 8, top: 6, bottom: 6 }).margin({ left: 12, right: 12 }).alignItems(VerticalAlign.Center)
      }
    }.width('100%').padding({ bottom: this.keyboardHeight > 0 ? 12 : this.navBarHeight + 12 })
  }

  @Builder appearancePanel(): void {
    Column() {
      Column().width('100%').layoutWeight(1).onClick(() => { this.appearancePanelVisible = false; })
      Column() {
        Text('气泡透明度').fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%').textAlign(TextAlign.Center).padding({ top: 16, bottom: 8 })
        Row() {
          Text('淡').fontSize(11).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ right: 8 })
          Slider({ value: this.bubbleOpacity, min: 0.40, max: 0.90, step: 0.05, style: SliderStyle.InSet })
            .blockColor(ThemePalette.accentColor(this.effectiveTheme)).trackColor(ThemePalette.surface2Color(this.effectiveTheme))
            .selectedColor(ThemePalette.accentColor(this.effectiveTheme)).layoutWeight(1)
            .onChange((value: number) => { this.bubbleOpacity = value; })
          Text('深').fontSize(11).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ left: 8 })
        }.width('100%').padding({ left: 24, right: 24, bottom: 4 })
        Text((Math.round(this.bubbleOpacity * 100)).toString() + '%').fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).width('100%').textAlign(TextAlign.Center).margin({ bottom: 16 })

        Text('字体大小').fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%').textAlign(TextAlign.Center).padding({ bottom: 8 })
        Row() {
          Text('小').fontSize(11).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ right: 8 })
          Slider({ value: this.chatTextStyle !== null ? this.chatTextStyle!.fontSize : 16, min: 12, max: 24, step: 1, style: SliderStyle.InSet })
            .blockColor(ThemePalette.accentColor(this.effectiveTheme)).trackColor(ThemePalette.surface2Color(this.effectiveTheme))
            .selectedColor(ThemePalette.accentColor(this.effectiveTheme)).layoutWeight(1)
            .onChange((value: number) => { this.applyFontSize(value); })
          Text('大').fontSize(11).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)).margin({ left: 8 })
        }.width('100%').padding({ left: 24, right: 24, bottom: 4 })
        Text((this.chatTextStyle !== null ? this.chatTextStyle!.fontSize : 16).toString() + 'fp').fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).width('100%').textAlign(TextAlign.Center).margin({ bottom: 16 })

        Row() {
          Button('保存').fontSize(13).fontColor($r('app.color.app_on_accent')).backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(16).height(36).layoutWeight(1).margin({ right: 8 })
            .onClick(() => { persistBubbleOpacity(this.bubbleOpacity); this.appearancePanelVisible = false; })
          Button('取消').fontSize(13).fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme)).borderRadius(16).height(36).layoutWeight(1)
            .onClick(() => { this.appearancePanelVisible = false; })
        }.width('100%').padding({ left: 24, right: 24, bottom: 16 })
        Column().width('100%').height(this.navBarHeight)
      }.width('100%').backgroundColor(ThemePalette.surface2Color(this.effectiveTheme)).borderRadius({ topLeft: 16, topRight: 16 })
    }.width('100%').height('100%')
    .transition(TransitionEffect.translate({ y: 400 }).animation({ duration: 250, curve: Curve.EaseOut })
      .combine(TransitionEffect.OPACITY.animation({ duration: 200 })))
  }

  @Builder loadingView(): void {
    Column() { LoadingProgress().width(40).height(40).color(ThemePalette.accentColor(this.effectiveTheme)) }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }
  @Builder notFoundView(): void {
    Column() { Text($r('app.string.world_scene_not_found')).fontSize($r('app.float.world_font_body')).fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme)) }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }
  @Builder errorView(): void {
    Column() {
      Text(this.errorMessage.length > 0 ? this.errorMessage : '场景数据加载失败,请重试')
        .fontSize($r('app.float.world_font_body')).fontColor($r('app.color.world_error'))
      Text('重试').fontSize($r('app.float.world_font_caption'))
        .fontColor((this.effectiveTheme === 'tavern' ? '#1A1510' : $r('app.color.app_on_accent')))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme)).borderRadius($r('app.float.world_radius_button'))
        .padding({ left: 16, right: 16, top: 6, bottom: 6 }).margin({ top: 12 }).onClick(() => { this.loadSnapshot(); })
    }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  @Builder endConfirmSheet(): void {
    Column() {
      Text($r('app.string.world_scene_end_confirm_title')).fontSize($r('app.float.world_font_subtitle')).fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme)).width('100%').padding({ top: 12, bottom: 4 })
      Text($r('app.string.world_scene_end_confirm_desc')).fontSize($r('app.float.world_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).margin({ bottom: 12 })
      Row() {
        WorldSecondaryButton({ label: $r('app.string.world_scene_cancel'), onButtonClick: (): void => { this.endConfirmVisible = false; } }).layoutWeight(1)
        WorldPrimaryButton({ label: '结束', isEnabled: !this.isSending,
          onButtonClick: (): void => { this.endScene(); } }).layoutWeight(1).margin({ left: 8 })
      }.width('100%')
      Column().width('100%').height(this.navBarHeight + 8)
    }.width('100%').padding({ left: 16, right: 16 }).alignItems(HorizontalAlign.Start)
  }

  @Builder characterInfoSheet(): void {
    Column() {
      Text('角色信息').fontSize($r('app.float.world_font_title')).fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme)).width('100%').padding({ top: 12, bottom: 8 })
      WorldSecondaryButton({ label: $r('app.string.world_scene_cancel'), onButtonClick: (): void => { this.characterSheetInstanceId = ''; } }).width('100%').margin({ bottom: 8 })
      WorldPrimaryButton({ label: $r('app.string.world_memory_view_entry'), onButtonClick: (): void => {
          this.openCharacterMemoryFromScene(this.characterSheetInstanceId); this.characterSheetInstanceId = ''; } })
        .width('100%').margin({ bottom: 8 })
      WorldPrimaryButton({ label: '上下文检查', onButtonClick: (): void => { this.openContextInspector(); this.characterSheetInstanceId = ''; } })
        .width('100%').margin({ bottom: 8 })
      Column().width('100%').height(this.navBarHeight + 8)
    }.width('100%').padding({ left: 16, right: 16 }).alignItems(HorizontalAlign.Start)
  }

  private sendUserMessage(): void {
    if (this.viewModel === null || this.detail === null) { return; }
    const content: string = this.inputContent.trim();
    if (content.length === 0) { this.actionError = '消息不能为空'; return; }
    this.actionError = ''; this.runtimeError = ''; this.inputContent = '';

    // 先同步 VM 状态(isSending/roundStatus 等),再追加乐观消息
    this.syncFromViewModel();

    const optimisticMsg: ChatMessageUiModel = {
      id: 'opt_' + Date.now().toString(),
      sequenceNumber: this.detail.messages.length + 1,
      senderType: WorldSceneMessageSenderType.User,
      senderDisplayName: '你',
      senderInstanceId: '',
      senderAvatarUri: '',
      senderFallbackName: '你',
      content: content,
      visibility: WorldSceneMessageVisibility.Public,
      messageStatus: 'sending',
      recipientNames: [],
      witnessNames: [],
      replyTargetNames: [],
      createdAt: Date.now(),
      senderRemoved: false
    };
    this.detail = {
      sceneId: this.detail.sceneId,
      sceneName: this.detail.sceneName,
      worldId: this.detail.worldId,
      worldName: this.detail.worldName,
      worldStatus: this.detail.worldStatus,
      locationId: this.detail.locationId,
      locationName: this.detail.locationName,
      locationStatus: this.detail.locationStatus,
      sceneStatus: this.detail.sceneStatus,
      sessionId: this.detail.sessionId,
      sessionStatus: this.detail.sessionStatus,
      sessionSequenceNumber: this.detail.sessionSequenceNumber,
      sessionParticipantSnapshot: this.detail.sessionParticipantSnapshot,
      playerDisplayNameSnapshot: this.detail.playerDisplayNameSnapshot,
      startedAt: this.detail.startedAt,
      endedAt: this.detail.endedAt,
      participantCount: this.detail.participantCount,
      characters: this.detail.characters,
      messages: [...this.detail.messages, optimisticMsg]
    };

    this.viewModel.sendMessage(content).then((errorMsg: string): void => {
      if (errorMsg.length > 0) { this.actionError = errorMsg; }
      this.syncFromViewModel();
    });
    setTimeout((): void => {
      try { this.scroller.scrollEdge(Edge.Bottom); } catch (_e) { /* ignore */ }
    }, 100);
  }
  private stopGeneration(): void { if (this.viewModel !== null) { this.viewModel.stopGeneration(); this.syncFromViewModel(); } }
  private async retryFailed(messageId: string): Promise<void> {
    if (this.viewModel === null) { return; }
    this.actionError = ''; this.runtimeError = '';
    const errorMsg: string = await this.viewModel.retryFailedMessage(messageId);
    if (errorMsg.length > 0) { this.actionError = errorMsg; }
    this.syncFromViewModel();
  }
  private async resumeRound(): Promise<void> {
    if (this.viewModel === null) { return; }
    this.actionError = ''; this.runtimeError = '';
    const errorMsg: string = await this.viewModel.resumeRound();
    if (errorMsg.length > 0) { this.actionError = errorMsg; }
    this.syncFromViewModel();
  }
  private async endScene(): Promise<void> {
    if (this.viewModel === null) { return; }
    this.actionError = '';
    const errorMsg: string = await this.viewModel.endScene();
    if (errorMsg.length > 0) { this.actionError = errorMsg; }
    else { this.endConfirmVisible = false; }
    this.syncFromViewModel();
  }

  private openCharacterMemoryFromScene(instanceId: string): void {
    if (this.detail === null || instanceId.length === 0) { return; }
    const worldId: string = this.detail.worldId;
    if (worldId.length === 0) { return; }
    this.characterSheetInstanceId = '';
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterMemoryPage' });
  }
  private openContextInspector(): void {
    if (this.detail === null || this.viewModel === null) { return; }
    const worldId: string = this.detail.worldId;
    if (worldId.length === 0) { return; }
    const sceneId: string = this.viewModel.expectedSceneIdOfPage();
    const sessionId: string = this.viewModel.expectedSessionIdOfPage();
    this.characterSheetInstanceId = '';
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSPECTOR_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSPECTOR_SCENE_ID_KEY, sceneId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSPECTOR_SESSION_ID_KEY, sessionId);
    router.pushUrl({ url: 'pages/world/WorldInspectorPage' });
  }

  loadChatBackground(): void {
    if (this.viewModel === null) { return; }
    const sessionId: string = this.viewModel.expectedSessionIdOfPage();
    if (sessionId.length === 0) { return; }
    const service = AppServices.getChatBackgroundService();
    if (service === null) { return; }
    service.getConfig(sessionId).then((cfg: ChatBackgroundConfig): void => { this.chatBgConfig = cfg; })
      .catch((): void => { this.chatBgConfig = null; });
  }

  private applyFontSize(value: number): void {
    const fontSize: number = Math.round(value);
    const settings = AppServices.getInstance().chatTextStyleSettings;
    settings.update({ fontSize: fontSize }).then((): void => {
      this.chatTextStyle = settings.get();
    });
  }

  private registerKeyboardListener(): void {
    try {
      window.getLastWindow(getContext(this))
        .then((win: window.Window): void => {
          this.mainWindow = win;
          this.keyboardHeightChangeHandler = (height: number): void => {
            const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
            const density: number = densityPixels > 0 ? densityPixels : 3.0;
            this.keyboardHeight = height > 0 ? height / density : 0;
            if (height > 0) {
              setTimeout((): void => {
                try { this.scroller.scrollEdge(Edge.Bottom); } catch (_e) { /* ignore */ }
              }, 80);
            }
          };
          win.on('keyboardHeightChange', this.keyboardHeightChangeHandler);
        })
        .catch((e: Error): void => {
          Logger.warn(LOG_TAG, 'getLastWindow failed: ' + e.message);
        });
    } catch (e) {
      Logger.warn(LOG_TAG, 'registerKeyboardListener failed: ' + (e as Error).message);
    }
  }

  private unregisterKeyboardListener(): void {
    if (this.mainWindow !== null && this.keyboardHeightChangeHandler !== null) {
      try { this.mainWindow.off('keyboardHeightChange', this.keyboardHeightChangeHandler); } catch (_e) { /* ignore */ }
      this.keyboardHeightChangeHandler = null;
      this.keyboardHeight = 0;
    }
  }
}
