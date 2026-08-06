/**
 * WorldSceneChatPage 世界场景共享对话页(W-UI-1C 重构)
 *
 * 重构:深色酒馆质感,场景头+状态+参与者数,
 * [玩家]/[角色·name]/[旁白] 标签,消息状态徽章,
 * 输入区含发送者身份/可见性切换,Ended Scene 只读横幅。
 *
 * 路由:通过 AppStorage PENDING_WORLD_SCENE_CHAT_ID_KEY 传 sceneId
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldSceneChatViewModel,
  WorldSceneChatLoadState,
  WorldSceneChatUiModel,
  ChatMessageUiModel,
  ChatCharacterUiModel,
  ChatUserMessageInput,
  ChatCharacterMessageInput,
  ChatNarratorMessageInput,
  formatChatTimestamp
} from '../../viewmodels/world/WorldSceneChatViewModel';
import {
  PENDING_WORLD_SCENE_CHAT_ID_KEY,
  PENDING_WORLD_MEMORY_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY,
  WORLD_SCENE_CHAT_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import {
  WorldSceneMessageVisibility,
  WorldSceneMessageSenderType
} from '../../models/world/WorldSceneMessage';
import { WorldStatus } from '../../models/world/World';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { CharacterImageView } from '../../components/CharacterImageView';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneChatPage';

enum SecondaryFormType {
  None,
  Character,
  Narrator,
  EndConfirm
}

enum ReplyTargetPickerMode {
  Hidden,
  PublicReply,
  PrivateRecipient
}

@Entry
@Component
struct WorldSceneChatPage {
  @State private viewModel: WorldSceneChatViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldSceneChatLoadState = WorldSceneChatLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldSceneChatUiModel | null = null;
  @State private actionError: string = '';
  @State private moreMenuVisible: boolean = false;
  @State private secondaryForm: SecondaryFormType = SecondaryFormType.None;

  @State private inputContent: string = '';
  @State private replyTargetPickerMode: ReplyTargetPickerMode = ReplyTargetPickerMode.Hidden;
  @State private selectedReplyTargetIds: string[] = [];
  @State private isPrivateMode: boolean = false;
  @State private selectedRecipientIds: string[] = [];

  @State private charSenderId: string = '';
  @State private charContent: string = '';
  @State private charVisibility: WorldSceneMessageVisibility = WorldSceneMessageVisibility.Public;
  @State private charRecipientIds: string[] = [];

  @State private narratorContent: string = '';
  @State private narratorWitnessIds: string[] = [];

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
      if (sceneId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: sceneId empty');
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
        AppServices.getCharacterService(),
        AppServices.getWorldSceneService()
      );
      this.viewModel.setSceneId(sceneId);
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
    if (this.loadState === WorldSceneChatLoadState.Ready) {
      setTimeout(() => {
        try {
          this.scroller.scrollEdge(Edge.Bottom);
        } catch (e) {
          // ignore
        }
      }, 100);
    }
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
    if (this.detail !== null && this.detail.sceneStatus !== WorldSceneStatus.Active) {
      this.secondaryForm = SecondaryFormType.None;
      this.replyTargetPickerMode = ReplyTargetPickerMode.Hidden;
      this.moreMenuVisible = false;
    }
  }

  private activeCharacters(): ChatCharacterUiModel[] {
    if (this.detail === null) {
      return [];
    }
    const result: ChatCharacterUiModel[] = [];
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].isActive) {
        result.push(this.detail.characters[i]);
      }
    }
    return result;
  }

  private isSceneWritable(): boolean {
    if (this.detail === null) {
      return false;
    }
    return this.detail.sceneStatus === WorldSceneStatus.Active
      && this.detail.worldStatus === WorldStatus.Active
      && this.detail.locationStatus === WorldLocationStatus.Active;
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
    .bindSheet(this.moreMenuVisible, this.moreMenuSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => { this.moreMenuVisible = false; }
    })
    .bindSheet(this.secondaryForm === SecondaryFormType.Character, this.characterFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        if (this.secondaryForm === SecondaryFormType.Character) {
          this.secondaryForm = SecondaryFormType.None;
        }
      }
    })
    .bindSheet(this.secondaryForm === SecondaryFormType.Narrator, this.narratorFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        if (this.secondaryForm === SecondaryFormType.Narrator) {
          this.secondaryForm = SecondaryFormType.None;
        }
      }
    })
    .bindSheet(this.secondaryForm === SecondaryFormType.EndConfirm, this.endConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        if (this.secondaryForm === SecondaryFormType.EndConfirm) {
          this.secondaryForm = SecondaryFormType.None;
        }
      }
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
                label: this.detail.sceneStatus === WorldSceneStatus.Active ? '活动中' : '已结束',
                isActive: this.detail.sceneStatus === WorldSceneStatus.Active
              })
              Text(this.detail.participantCount.toString() + ' 位参与')
                .fontSize($r('app.float.world_font_micro'))
                .fontColor($r('app.color.world_text_tertiary'))
                .margin({ left: 6 })
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

        if (this.detail !== null && this.isSceneWritable()) {
          Text('⋯')
            .fontSize(22)
            .fontColor($r('app.color.world_text_secondary'))
            .backgroundColor($r('app.color.world_surface_1'))
            .borderRadius($r('app.float.world_radius_chip'))
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.moreMenuVisible = true; })
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

      if (this.actionError.length > 0) {
        Text(this.actionError)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_error'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      if (this.isSceneWritable()) {
        this.inputArea(detail)
      } else if (detail.sceneStatus === WorldSceneStatus.Ended) {
        this.endedSceneBar()
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

        Text(this.visibilityTag(m.visibility))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor(this.visibilityColor(m.visibility))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 4 })

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

      Text(m.content)
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .margin({ top: 4 })
        .textAlign(TextAlign.Start)

      if (m.replyTargetNames.length > 0) {
        Text($r('app.string.world_scene_reply_target_prefix') + m.replyTargetNames.join('、'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .margin({ top: 4 })
      }
      if (m.recipientNames.length > 0) {
        Text($r('app.string.world_scene_recipient_prefix') + m.recipientNames.join('、'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .margin({ top: 2 })
      }
      if (m.witnessNames.length > 0) {
        Text($r('app.string.world_scene_witness_prefix') + m.witnessNames.join('、'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .margin({ top: 2 })
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
  inputArea(detail: WorldSceneChatUiModel): void {
    Column() {
      if (this.selectedReplyTargetIds.length > 0 || this.selectedRecipientIds.length > 0) {
        this.targetChipRow(detail)
      }

      if (this.replyTargetPickerMode === ReplyTargetPickerMode.PublicReply) {
        this.replyTargetPicker(detail)
      } else if (this.replyTargetPickerMode === ReplyTargetPickerMode.PrivateRecipient) {
        this.recipientPicker(detail)
      }

      Row() {
        TextInput({
          text: this.inputContent,
          placeholder: this.isPrivateMode
            ? $r('app.string.world_scene_private_input_placeholder')
            : $r('app.string.world_scene_public_input_placeholder')
        })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .layoutWeight(1)
          .onChange((v: string) => { this.inputContent = v; })

        Text(this.isPrivateMode ? '私下' : '公开')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(this.isPrivateMode ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
          .backgroundColor(this.isPrivateMode ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .onClick(() => { this.toggleMode(); })

        Text(this.isPrivateMode ? '选接收' : '选回复')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor((this.isPrivateMode && this.selectedRecipientIds.length > 0)
            || (!this.isPrivateMode && this.selectedReplyTargetIds.length > 0)
            ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
          .backgroundColor((this.isPrivateMode && this.selectedRecipientIds.length > 0)
            || (!this.isPrivateMode && this.selectedReplyTargetIds.length > 0)
            ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ left: 4 })
          .onClick(() => { this.openTargetPicker(); })

        Text('发送')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_on_gold'))
          .backgroundColor($r('app.color.world_gold'))
          .borderRadius($r('app.float.world_radius_button'))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ left: 4 })
          .enabled(this.viewModel !== null && !this.viewModel.isSending)
          .onClick(() => { this.sendUserMessage(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 + this.navBarHeight })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  targetChipRow(detail: WorldSceneChatUiModel): void {
    Row() {
      if (this.selectedReplyTargetIds.length > 0) {
        Text($r('app.string.world_scene_reply_target_prefix'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_secondary'))
        ForEach(this.selectedReplyTargetIds, (id: string) => {
          Text(this.resolveInstanceName(detail, id))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .borderRadius(6)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 3 })
        }, (id: string) => id)
      }
      if (this.selectedRecipientIds.length > 0) {
        Text($r('app.string.world_scene_recipient_prefix'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ left: 6 })
        ForEach(this.selectedRecipientIds, (id: string) => {
          Text(this.resolveInstanceName(detail, id))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_on_gold'))
            .backgroundColor($r('app.color.world_gold'))
            .borderRadius(6)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 3 })
        }, (id: string) => id)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  replyTargetPicker(detail: WorldSceneChatUiModel): void {
    Column() {
      Text($r('app.string.world_scene_select_reply_target'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 12, top: 6, bottom: 4 })

      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Text(c.displayName)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(this.selectedReplyTargetIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
            .backgroundColor(this.selectedReplyTargetIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => {
              this.toggleInArray(this.selectedReplyTargetIds, c.instanceId, (v) => {
                this.selectedReplyTargetIds = v;
              });
            })
        }, (c: ChatCharacterUiModel) => c.instanceId)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 6 })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  recipientPicker(detail: WorldSceneChatUiModel): void {
    Column() {
      Text($r('app.string.world_scene_select_recipients'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 12, top: 6, bottom: 4 })

      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Text(c.displayName)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(this.selectedRecipientIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
            .backgroundColor(this.selectedRecipientIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => {
              this.toggleInArray(this.selectedRecipientIds, c.instanceId, (v) => {
                this.selectedRecipientIds = v;
              });
            })
        }, (c: ChatCharacterUiModel) => c.instanceId)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 6 })
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
  moreMenuSheet(): void {
    Column() {
      Text('更多操作')
        .fontSize($r('app.float.world_font_subtitle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      this.sheetMenuRow($r('app.string.world_scene_manual_character'), () => {
        this.moreMenuVisible = false;
        this.charSenderId = '';
        this.charContent = '';
        this.charVisibility = WorldSceneMessageVisibility.Public;
        this.charRecipientIds = [];
        this.secondaryForm = SecondaryFormType.Character;
      })

      this.sheetMenuRow($r('app.string.world_scene_add_narrator'), () => {
        this.moreMenuVisible = false;
        this.narratorContent = '';
        this.narratorWitnessIds = [];
        this.secondaryForm = SecondaryFormType.Narrator;
      })

      Text($r('app.string.world_scene_end'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_error'))
        .backgroundColor($r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_chip'))
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .margin({ left: 16, right: 16, bottom: 8 })
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.moreMenuVisible = false;
          this.secondaryForm = SecondaryFormType.EndConfirm;
        })

      Text($r('app.string.world_scene_cancel'))
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .margin({ left: 16, right: 16, bottom: 16 })
        .textAlign(TextAlign.Center)
        .onClick(() => { this.moreMenuVisible = false; })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  sheetMenuRow(label: ResourceStr, action: () => void): void {
    Text(label)
      .fontSize($r('app.float.world_font_body'))
      .fontColor($r('app.color.world_text_primary'))
      .backgroundColor($r('app.color.world_surface_2'))
      .borderRadius($r('app.float.world_radius_chip'))
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .margin({ left: 16, right: 16, bottom: 8 })
      .textAlign(TextAlign.Center)
      .onClick(() => { action(); })
  }

  @Builder
  characterFormSheet(): void {
    Column() {
      Text('角色台词(手工)')
        .fontSize($r('app.float.world_font_subtitle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_scene_sender'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Text(c.displayName)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(this.charSenderId === c.instanceId
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
            .backgroundColor(this.charSenderId === c.instanceId
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => { this.charSenderId = c.instanceId; })
        }, (c: ChatCharacterUiModel) => c.instanceId)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Row() {
        Text('公开')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(this.charVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
          .backgroundColor(this.charVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ right: 6 })
          .onClick(() => {
            this.charVisibility = WorldSceneMessageVisibility.Public;
            this.charRecipientIds = [];
          })
        Text('私下')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(this.charVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
          .backgroundColor(this.charVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => { this.charVisibility = WorldSceneMessageVisibility.Private; })
      }
      .width('100%')
      .padding({ left: 16, bottom: 8 })

      if (this.charVisibility === WorldSceneMessageVisibility.Private) {
        Text($r('app.string.world_scene_select_recipients'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .width('100%')
          .padding({ left: 16, bottom: 4 })
        Row() {
          ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
            Text(c.displayName)
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(this.charRecipientIds.indexOf(c.instanceId) >= 0
                ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
              .backgroundColor(this.charRecipientIds.indexOf(c.instanceId) >= 0
                ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
              .borderRadius($r('app.float.world_radius_chip'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .margin({ right: 4, bottom: 4 })
              .onClick(() => {
                this.toggleInArray(this.charRecipientIds, c.instanceId, (v) => {
                  this.charRecipientIds = v;
                });
              })
          }, (c: ChatCharacterUiModel) => c.instanceId)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
      }

      TextArea({ text: this.charContent, placeholder: $r('app.string.world_scene_content_placeholder') })
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_primary'))
        .placeholderColor($r('app.color.world_text_tertiary'))
        .backgroundColor($r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_chip'))
        .width('100%')
        .height(120)
        .margin({ left: 16, right: 16, bottom: 8 })
        .onChange((v: string) => { this.charContent = v; })

      Row() {
        WorldSecondaryButton({
          label: $r('app.string.world_scene_cancel'),
          onButtonClick: (): void => { this.secondaryForm = SecondaryFormType.None; }
        })
          .layoutWeight(1)
        WorldPrimaryButton({
          label: $r('app.string.world_scene_save'),
          isEnabled: this.viewModel !== null && !this.viewModel.isSending
            && this.charSenderId.length > 0,
          onButtonClick: (): void => { this.sendCharacterMessage(); }
        })
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  narratorFormSheet(): void {
    Column() {
      Text('旁白/动作')
        .fontSize($r('app.float.world_font_subtitle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_scene_witness'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Text(c.displayName)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(this.narratorWitnessIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
            .backgroundColor(this.narratorWitnessIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => {
              this.toggleInArray(this.narratorWitnessIds, c.instanceId, (v) => {
                this.narratorWitnessIds = v;
              });
            })
        }, (c: ChatCharacterUiModel) => c.instanceId)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      TextArea({ text: this.narratorContent, placeholder: $r('app.string.world_scene_content_placeholder') })
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_primary'))
        .placeholderColor($r('app.color.world_text_tertiary'))
        .backgroundColor($r('app.color.world_surface_2'))
        .borderRadius($r('app.float.world_radius_chip'))
        .width('100%')
        .height(120)
        .margin({ left: 16, right: 16, bottom: 8 })
        .onChange((v: string) => { this.narratorContent = v; })

      Row() {
        WorldSecondaryButton({
          label: $r('app.string.world_scene_cancel'),
          onButtonClick: (): void => { this.secondaryForm = SecondaryFormType.None; }
        })
          .layoutWeight(1)
        WorldPrimaryButton({
          label: $r('app.string.world_scene_save'),
          isEnabled: this.viewModel !== null && !this.viewModel.isSending,
          onButtonClick: (): void => { this.sendNarratorMessage(); }
        })
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
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
          onButtonClick: (): void => { this.secondaryForm = SecondaryFormType.None; }
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
          .enabled(this.viewModel !== null && !this.viewModel.isEnding)
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

  private toggleMode(): void {
    this.isPrivateMode = !this.isPrivateMode;
    if (this.isPrivateMode) {
      this.selectedReplyTargetIds = [];
    } else {
      this.selectedRecipientIds = [];
    }
    this.replyTargetPickerMode = ReplyTargetPickerMode.Hidden;
  }

  private openTargetPicker(): void {
    if (this.isPrivateMode) {
      this.replyTargetPickerMode = this.replyTargetPickerMode === ReplyTargetPickerMode.PrivateRecipient
        ? ReplyTargetPickerMode.Hidden : ReplyTargetPickerMode.PrivateRecipient;
    } else {
      this.replyTargetPickerMode = this.replyTargetPickerMode === ReplyTargetPickerMode.PublicReply
        ? ReplyTargetPickerMode.Hidden : ReplyTargetPickerMode.PublicReply;
    }
  }

  private toggleInArray(arr: string[], id: string, setter: (v: string[]) => void): void {
    const idx: number = arr.indexOf(id);
    const newArr: string[] = arr.slice();
    if (idx >= 0) {
      newArr.splice(idx, 1);
    } else {
      newArr.push(id);
    }
    setter(newArr);
  }

  private async sendUserMessage(): Promise<void> {
    if (this.viewModel === null || this.detail === null) return;
    const content: string = this.inputContent.trim();
    if (content.length === 0) {
      this.actionError = '消息不能为空';
      return;
    }
    if (this.isPrivateMode && this.selectedRecipientIds.length === 0) {
      this.actionError = '私下消息必须选择接收者';
      return;
    }
    this.actionError = '';
    const visibility: WorldSceneMessageVisibility = this.isPrivateMode
      ? WorldSceneMessageVisibility.Private : WorldSceneMessageVisibility.Public;
    const input: ChatUserMessageInput = {
      content: content,
      visibility: visibility,
      recipientInstanceIds: this.isPrivateMode ? this.selectedRecipientIds : [],
      replyTargetInstanceIds: !this.isPrivateMode ? this.selectedReplyTargetIds : []
    };
    const result = await this.viewModel.addUserMessage(input);
    if (result.success) {
      this.inputContent = '';
      this.actionError = '';
    } else {
      this.actionError = result.errorMessage;
    }
    this.syncFromViewModel();
  }

  private async sendCharacterMessage(): Promise<void> {
    if (this.viewModel === null) return;
    const content: string = this.charContent.trim();
    if (this.charSenderId.length === 0) {
      this.actionError = '请选择发言角色';
      return;
    }
    if (content.length === 0) {
      this.actionError = '消息不能为空';
      return;
    }
    if (this.charVisibility === WorldSceneMessageVisibility.Private && this.charRecipientIds.length === 0) {
      this.actionError = '私下消息必须选择接收者';
      return;
    }
    this.actionError = '';
    const input: ChatCharacterMessageInput = {
      senderInstanceId: this.charSenderId,
      content: content,
      visibility: this.charVisibility,
      recipientInstanceIds: this.charVisibility === WorldSceneMessageVisibility.Private ? this.charRecipientIds : []
    };
    const result = await this.viewModel.addCharacterMessage(input);
    if (result.success) {
      this.secondaryForm = SecondaryFormType.None;
      this.actionError = '';
    } else {
      this.actionError = result.errorMessage;
    }
    this.syncFromViewModel();
  }

  private async sendNarratorMessage(): Promise<void> {
    if (this.viewModel === null) return;
    const content: string = this.narratorContent.trim();
    if (content.length === 0) {
      this.actionError = '消息不能为空';
      return;
    }
    this.actionError = '';
    const input: ChatNarratorMessageInput = {
      content: content,
      witnessInstanceIds: this.narratorWitnessIds
    };
    const result = await this.viewModel.addNarratorMessage(input);
    if (result.success) {
      this.secondaryForm = SecondaryFormType.None;
      this.actionError = '';
    } else {
      this.actionError = result.errorMessage;
    }
    this.syncFromViewModel();
  }

  private async endScene(): Promise<void> {
    if (this.viewModel === null) return;
    this.actionError = '';
    const result = await this.viewModel.endScene();
    if (result.success) {
      this.secondaryForm = SecondaryFormType.None;
      this.actionError = '';
    } else {
      this.actionError = result.errorMessage;
    }
    this.syncFromViewModel();
  }

  private senderLabel(m: ChatMessageUiModel): string {
    if (m.senderType === WorldSceneMessageSenderType.User) {
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
    if (t === WorldSceneMessageSenderType.User) return $r('app.color.world_on_gold');
    if (t === WorldSceneMessageSenderType.Character) return $r('app.color.world_text_primary');
    return $r('app.color.world_text_tertiary');
  }

  private senderLabelBg(t: WorldSceneMessageSenderType): ResourceColor {
    if (t === WorldSceneMessageSenderType.User) return $r('app.color.world_gold');
    if (t === WorldSceneMessageSenderType.Character) return $r('app.color.world_surface_2');
    return $r('app.color.world_surface_1');
  }

  private visibilityTag(v: WorldSceneMessageVisibility): string {
    if (v === WorldSceneMessageVisibility.Public) return '公开';
    if (v === WorldSceneMessageVisibility.Private) return '私下';
    return '旁白';
  }

  private visibilityColor(v: WorldSceneMessageVisibility): ResourceColor {
    if (v === WorldSceneMessageVisibility.Private) return $r('app.color.world_error');
    return $r('app.color.world_text_secondary');
  }

  private statusTag(s: string): string {
    if (s === 'streaming') return '生成中';
    if (s === 'cancelled') return '已取消';
    if (s === 'failed') return '失败';
    return '已完成';
  }

  private statusColor(s: string): ResourceColor {
    if (s === 'streaming') return $r('app.color.world_gold');
    if (s === 'cancelled') return $r('app.color.world_text_tertiary');
    if (s === 'failed') return $r('app.color.world_error');
    return $r('app.color.world_text_secondary');
  }

  private resolveInstanceName(detail: WorldSceneChatUiModel, instanceId: string): string {
    for (let i = 0; i < detail.characters.length; i++) {
      if (detail.characters[i].instanceId === instanceId) {
        return detail.characters[i].displayName;
      }
    }
    return '已移除角色';
  }

  private resolveCharacterName(instanceId: string): string {
    if (this.detail === null || instanceId.length === 0) return '';
    return this.resolveInstanceName(this.detail, instanceId);
  }

  private resolveCharacterAvatar(instanceId: string): string {
    if (this.detail === null) return '';
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].avatarUri;
      }
    }
    return '';
  }

  private resolveCharacterFallback(instanceId: string): string {
    if (this.detail === null) return '';
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].fallbackName;
      }
    }
    return '';
  }

  private resolveCharacterActive(instanceId: string): boolean {
    if (this.detail === null) return false;
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].isActive;
      }
    }
    return false;
  }

  private resolveCharacterCardMissing(instanceId: string): boolean {
    if (this.detail === null) return false;
    for (let i = 0; i < this.detail.characters.length; i++) {
      if (this.detail.characters[i].instanceId === instanceId) {
        return this.detail.characters[i].characterCardMissing;
      }
    }
    return false;
  }

  private openCharacterMemoryFromScene(instanceId: string): void {
    if (this.detail === null || instanceId.length === 0) return;
    const worldId: string = this.detail.worldId;
    if (worldId.length === 0) return;
    this.characterSheetInstanceId = '';
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterMemoryPage' });
  }
}