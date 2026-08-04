/**
 * WorldSceneChatPage 世界场景共享对话页(W-UX-1)
 *
 * 职责:
 * - 显示场景状态、地点名称、当前人物栏
 * - 按 sequenceNumber ASC 展示共享消息时间线
 * - 用户公开消息发送(含回复目标选择)
 * - 用户私下消息发送
 * - 手动角色发言 / 旁白(从更多菜单弹出)
 * - 结束场景
 * - Ended Scene 只读
 *
 * 路由:通过 AppStorage PENDING_WORLD_SCENE_CHAT_ID_KEY 传 sceneId
 * 写入调用 WorldSceneService。
 *
 * 视觉参考:GroupChatPage 的人物栏 + 消息列表 + 输入区,但数据完全来自 WorldScene。
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
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneChatPage';

/** 次级表单类型(从更多菜单触发) */
enum SecondaryFormType {
  None,
  Character,
  Narrator,
  EndConfirm
}

/** 回复目标选择面板 */
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

  // 主输入区
  @State private inputContent: string = '';
  @State private replyTargetPickerMode: ReplyTargetPickerMode = ReplyTargetPickerMode.Hidden;
  @State private selectedReplyTargetIds: string[] = [];
  @State private isPrivateMode: boolean = false;
  @State private selectedRecipientIds: string[] = [];

  // 角色消息表单
  @State private charSenderId: string = '';
  @State private charContent: string = '';
  @State private charVisibility: WorldSceneMessageVisibility = WorldSceneMessageVisibility.Public;
  @State private charRecipientIds: string[] = [];

  // 旁白消息表单
  @State private narratorContent: string = '';
  @State private narratorWitnessIds: string[] = [];

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
    // 加载完成后滚动到底部
    if (this.loadState === WorldSceneChatLoadState.Ready) {
      setTimeout(() => {
        try {
          this.scroller.scrollEdge(Edge.Bottom);
        } catch (e) {
          // 忽略滚动错误
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
    // Ended Scene 时关闭输入相关状态
    if (this.detail !== null && this.detail.sceneStatus !== WorldSceneStatus.Active) {
      this.secondaryForm = SecondaryFormType.None;
      this.replyTargetPickerMode = ReplyTargetPickerMode.Hidden;
      this.moreMenuVisible = false;
    }
  }

  /** 获取当前 Active 角色列表(用于回复目标/接收者选择) */
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

  /** 场景是否可写 */
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
      this.headerArea();
      if (this.isInitializing) {
        this.loadingView();
      } else if (this.loadState === WorldSceneChatLoadState.Loading) {
        this.loadingView();
      } else if (this.loadState === WorldSceneChatLoadState.NotFound) {
        this.notFoundView();
      } else if (this.loadState === WorldSceneChatLoadState.Error) {
        this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '场景数据加载失败,请重试');
      } else if (this.loadState === WorldSceneChatLoadState.Ready && this.detail !== null) {
        this.contentView(this.detail)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.moreMenuVisible, this.moreMenuSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        this.moreMenuVisible = false;
      }
    })
    .bindSheet(this.secondaryForm === SecondaryFormType.Character, this.characterFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        if (this.secondaryForm === SecondaryFormType.Character) {
          this.secondaryForm = SecondaryFormType.None;
        }
      }
    })
    .bindSheet(this.secondaryForm === SecondaryFormType.Narrator, this.narratorFormSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        if (this.secondaryForm === SecondaryFormType.Narrator) {
          this.secondaryForm = SecondaryFormType.None;
        }
      }
    })
    .bindSheet(this.secondaryForm === SecondaryFormType.EndConfirm, this.endConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.app_surface_1'),
      onDisappear: () => {
        if (this.secondaryForm === SecondaryFormType.EndConfirm) {
          this.secondaryForm = SecondaryFormType.None;
        }
      }
    })
  }

  @Builder
  headerArea(): void {
    Column() {
      Row() {
        Button($r('app.string.world_home_back'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .backgroundColor(Color.Transparent)
          .height(36)
          .padding({ left: 0, right: 8 })
          .accessibilityText($r('app.string.world_home_back'))
          .onClick(() => {
            router.back();
          })

        Column() {
          if (this.detail !== null) {
            Text(this.detail.locationName)
              .fontSize($r('app.float.app_font_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.app_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.sceneStatusText(this.detail.sceneStatus))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(this.detail.sceneStatus === WorldSceneStatus.Active
                ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
          } else {
            Text($r('app.string.world_scene_chat_title'))
              .fontSize($r('app.float.app_font_title'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.app_text_primary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 8 })

        if (this.detail !== null && this.isSceneWritable()) {
          Button($r('app.string.world_scene_more'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 12, right: 12 })
            .accessibilityText($r('app.string.world_scene_more'))
            .onClick(() => {
              this.moreMenuVisible = true;
            })
        }
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: this.statusBarHeight + 8,
        bottom: $r('app.float.app_spacing_8')
      })
      .alignItems(VerticalAlign.Center)

      // 当前人物栏
      if (this.detail !== null) {
        this.characterStripArea(this.detail.characters)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  characterStripArea(characters: ChatCharacterUiModel[]): void {
    if (characters.length === 0) {
      Text($r('app.string.world_scene_no_characters'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
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
            .fill($r('app.color.app_text_tertiary'))
            .position({ x: 26, y: 26 })
        }
      }
      .width(36)
      .height(36)
      Text(c.displayName)
        .fontSize(10)
        .fontColor(c.isActive ? $r('app.color.app_text_primary') : $r('app.color.app_text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .width(48)
    .margin({ right: 8 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  contentView(detail: WorldSceneChatUiModel): void {
    Column() {
      // 消息列表
      if (detail.messages.length === 0) {
        this.emptyMessageView()
      } else {
        List({ scroller: this.scroller }) {
          ForEach(detail.messages, (m: ChatMessageUiModel) => {
            ListItem() {
              this.messageBubble(m)
            }
          }, (m: ChatMessageUiModel) => m.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .scrollBar(BarState.Auto)
      }

      // 错误提示
      if (this.actionError.length > 0) {
        Text(this.actionError)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      // 输入区
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
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 40 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  messageBubble(m: ChatMessageUiModel): void {
    Column() {
      // 发送者行
      Row() {
        if (m.senderType === WorldSceneMessageSenderType.Character && m.senderAvatarUri.length > 0) {
          CharacterImageView({
            imageUri: m.senderAvatarUri,
            fallbackName: m.senderDisplayName,
            imgWidth: 24,
            imgHeight: 24,
            imgBorderRadius: 12,
            displayMode: 'thumbnail'
          })
          .margin({ right: 6 })
        }
        Text(m.senderDisplayName.length > 0 ? m.senderDisplayName : this.senderTypeLabel(m.senderType))
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.senderColor(m.senderType))
        // 可见性标签
        Text(this.visibilityLabel(m.visibility))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 消息正文
      Text(m.content)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .margin({ top: 4 })
        .textAlign(TextAlign.Start)

      // 回复目标 / 接收者 / 目击者
      if (m.replyTargetNames.length > 0) {
        Text($r('app.string.world_scene_reply_target_prefix') + m.replyTargetNames.join('、'))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 4 })
      }
      if (m.recipientNames.length > 0) {
        Text($r('app.string.world_scene_recipient_prefix') + m.recipientNames.join('、'))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 2 })
      }
      if (m.witnessNames.length > 0) {
        Text($r('app.string.world_scene_witness_prefix') + m.witnessNames.join('、'))
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 2 })
      }

      // 时间
      Text(formatChatTimestamp(m.createdAt))
        .fontSize(9)
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({
      left: 12, right: 12, top: 8, bottom: 8
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  inputArea(detail: WorldSceneChatUiModel): void {
    Column() {
      // 回复目标 / 私下接收者 Chip 行
      if (this.selectedReplyTargetIds.length > 0 || this.selectedRecipientIds.length > 0) {
        this.targetChipRow(detail)
      }

      // 选择面板
      if (this.replyTargetPickerMode === ReplyTargetPickerMode.PublicReply) {
        this.replyTargetPicker(detail)
      } else if (this.replyTargetPickerMode === ReplyTargetPickerMode.PrivateRecipient) {
        this.recipientPicker(detail)
      }

      // 输入框 + 发送
      Row() {
        TextInput({
          text: this.inputContent,
          placeholder: this.isPrivateMode
            ? $r('app.string.world_scene_private_input_placeholder')
            : $r('app.string.world_scene_public_input_placeholder')
        })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .layoutWeight(1)
          .onChange((v: string) => {
            this.inputContent = v;
          })

        // 模式切换:公开/私下
        Button(this.isPrivateMode
          ? $r('app.string.world_scene_mode_private')
          : $r('app.string.world_scene_mode_public'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 8, right: 8 })
          .margin({ left: 8 })
          .accessibilityText($r('app.string.world_scene_toggle_mode'))
          .onClick(() => {
            this.toggleMode();
          })

        // 选择目标按钮
        Button(this.isPrivateMode
          ? $r('app.string.world_scene_select_recipients')
          : $r('app.string.world_scene_select_reply_target'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor((this.isPrivateMode && this.selectedRecipientIds.length > 0)
            || (!this.isPrivateMode && this.selectedReplyTargetIds.length > 0)
            ? $r('app.color.app_accent') : $r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 8, right: 8 })
          .margin({ left: 4 })
          .accessibilityText($r('app.string.world_scene_select_reply_target'))
          .onClick(() => {
            this.openTargetPicker();
          })

        // 发送
        Button($r('app.string.world_scene_send'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ left: 4 })
          .accessibilityText($r('app.string.world_scene_send'))
          .enabled(this.viewModel !== null && !this.viewModel.isSending)
          .onClick(() => {
            this.sendUserMessage();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 + this.navBarHeight })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  targetChipRow(detail: WorldSceneChatUiModel): void {
    Row() {
      if (this.selectedReplyTargetIds.length > 0) {
        Text($r('app.string.world_scene_reply_target_prefix'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        ForEach(this.selectedReplyTargetIds, (id: string) => {
          Text(this.resolveInstanceName(detail, id))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 4 })
        }, (id: string) => id)
      }
      if (this.selectedRecipientIds.length > 0) {
        Text($r('app.string.world_scene_recipient_prefix'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ left: 8 })
        ForEach(this.selectedRecipientIds, (id: string) => {
          Text(this.resolveInstanceName(detail, id))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 4 })
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
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 12, top: 6, bottom: 4 })

      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Button(c.displayName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.selectedReplyTargetIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
            .backgroundColor(this.selectedReplyTargetIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 8, right: 8 })
            .margin({ right: 6, bottom: 4 })
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
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  recipientPicker(detail: WorldSceneChatUiModel): void {
    Column() {
      Text($r('app.string.world_scene_select_recipients'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 12, top: 6, bottom: 4 })

      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Button(c.displayName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.selectedRecipientIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
            .backgroundColor(this.selectedRecipientIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 8, right: 8 })
            .margin({ right: 6, bottom: 4 })
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
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  endedSceneBar(): void {
    Column() {
      Text($r('app.string.world_scene_ended_hint'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 + this.navBarHeight })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress().width(48).height(48)
      Text($r('app.string.world_scene_loading'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.world_scene_not_found'),
        description: $r('app.string.world_scene_not_found_desc')
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  errorView(msg: string): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.world_scene_load_error'),
        description: msg
      })
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 16, right: 16 })
        .margin({ top: 12 })
        .onClick(() => {
          this.loadSnapshot();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  // ===== 更多菜单和次级表单(用 bindSheet) =====

  @Builder
  moreMenuSheet(): void {
    Column() {
      Text($r('app.string.world_scene_more_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Button($r('app.string.world_scene_manual_character'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .width('100%')
        .margin({ left: 16, right: 16, bottom: 8 })
        .accessibilityText($r('app.string.world_scene_manual_character'))
        .onClick(() => {
          this.moreMenuVisible = false;
          this.charSenderId = '';
          this.charContent = '';
          this.charVisibility = WorldSceneMessageVisibility.Public;
          this.charRecipientIds = [];
          this.secondaryForm = SecondaryFormType.Character;
        })

      Button($r('app.string.world_scene_add_narrator'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .width('100%')
        .margin({ left: 16, right: 16, bottom: 8 })
        .accessibilityText($r('app.string.world_scene_add_narrator'))
        .onClick(() => {
          this.moreMenuVisible = false;
          this.narratorContent = '';
          this.narratorWitnessIds = [];
          this.secondaryForm = SecondaryFormType.Narrator;
        })

      Button($r('app.string.world_scene_end'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .width('100%')
        .margin({ left: 16, right: 16, bottom: 16 })
        .accessibilityText($r('app.string.world_scene_end'))
        .onClick(() => {
          this.moreMenuVisible = false;
          this.secondaryForm = SecondaryFormType.EndConfirm;
        })

      Button($r('app.string.world_scene_cancel'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .backgroundColor(Color.Transparent)
        .height(44)
        .width('100%')
        .margin({ left: 16, right: 16, bottom: 16 })
        .onClick(() => {
          this.moreMenuVisible = false;
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  characterFormSheet(): void {
    Column() {
      Text($r('app.string.world_scene_manual_character'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      // 发言角色选择
      Text($r('app.string.world_scene_sender'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Button(c.displayName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.charSenderId === c.instanceId
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
            .backgroundColor(this.charSenderId === c.instanceId
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 8, right: 8 })
            .margin({ right: 6, bottom: 4 })
            .onClick(() => {
              this.charSenderId = c.instanceId;
            })
        }, (c: ChatCharacterUiModel) => c.instanceId)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 可见性
      Row() {
        Button($r('app.string.world_scene_mode_public'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.charVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
          .backgroundColor(this.charVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ right: 8 })
          .onClick(() => {
            this.charVisibility = WorldSceneMessageVisibility.Public;
            this.charRecipientIds = [];
          })
        Button($r('app.string.world_scene_mode_private'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.charVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
          .backgroundColor(this.charVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.charVisibility = WorldSceneMessageVisibility.Private;
          })
      }
      .width('100%')
      .padding({ left: 16, bottom: 8 })

      // 私下接收者(仅 Private)
      if (this.charVisibility === WorldSceneMessageVisibility.Private) {
        Text($r('app.string.world_scene_select_recipients'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .width('100%')
          .padding({ left: 16, bottom: 4 })
        Row() {
          ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
            Button(c.displayName)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(this.charRecipientIds.indexOf(c.instanceId) >= 0
                ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
              .backgroundColor(this.charRecipientIds.indexOf(c.instanceId) >= 0
                ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(32)
              .padding({ left: 8, right: 8 })
              .margin({ right: 6, bottom: 4 })
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

      // 正文
      TextArea({
        text: this.charContent,
        placeholder: $r('app.string.world_scene_content_placeholder')
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .width('100%')
        .height(120)
        .margin({ left: 16, right: 16, bottom: 8 })
        .onChange((v: string) => {
          this.charContent = v;
        })

      // 操作按钮
      Row() {
        Button($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => {
            this.secondaryForm = SecondaryFormType.None;
          })
        Button($r('app.string.world_scene_save'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(this.viewModel !== null && !this.viewModel.isSending
            && this.charSenderId.length > 0 && this.charContent.trim().length > 0)
          .onClick(() => {
            this.sendCharacterMessage();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  narratorFormSheet(): void {
    Column() {
      Text($r('app.string.world_scene_add_narrator'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      // 目击者(可选)
      Text($r('app.string.world_scene_witness'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, bottom: 4 })
      Row() {
        ForEach(this.activeCharacters(), (c: ChatCharacterUiModel) => {
          Button(c.displayName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.narratorWitnessIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_primary'))
            .backgroundColor(this.narratorWitnessIds.indexOf(c.instanceId) >= 0
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .padding({ left: 8, right: 8 })
            .margin({ right: 6, bottom: 4 })
            .onClick(() => {
              this.toggleInArray(this.narratorWitnessIds, c.instanceId, (v) => {
                this.narratorWitnessIds = v;
              });
            })
        }, (c: ChatCharacterUiModel) => c.instanceId)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      TextArea({
        text: this.narratorContent,
        placeholder: $r('app.string.world_scene_content_placeholder')
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .width('100%')
        .height(120)
        .margin({ left: 16, right: 16, bottom: 8 })
        .onChange((v: string) => {
          this.narratorContent = v;
        })

      Row() {
        Button($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => {
            this.secondaryForm = SecondaryFormType.None;
          })
        Button($r('app.string.world_scene_save'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(this.viewModel !== null && !this.viewModel.isSending
            && this.narratorContent.trim().length > 0)
          .onClick(() => {
            this.sendNarratorMessage();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  endConfirmSheet(): void {
    Column() {
      Text($r('app.string.world_scene_end_confirm_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 12 })

      Text($r('app.string.world_scene_end_confirm_desc'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })

      Row() {
        Button($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => {
            this.secondaryForm = SecondaryFormType.None;
          })
        Button($r('app.string.world_scene_end'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(this.viewModel !== null && !this.viewModel.isEnding)
          .onClick(() => {
            this.endScene();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
  }

  // ===== 事件处理 =====

  private toggleMode(): void {
    this.isPrivateMode = !this.isPrivateMode;
    if (this.isPrivateMode) {
      // 切到私下:清空回复目标
      this.selectedReplyTargetIds = [];
    } else {
      // 切到公开:清空接收者
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
    if (this.viewModel === null || this.detail === null) {
      return;
    }
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
      // 公开模式下保留回复目标,私下模式清空接收者(可继续选)
      this.actionError = '';
    } else {
      this.actionError = result.errorMessage;
    }
    this.syncFromViewModel();
  }

  private async sendCharacterMessage(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
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
    if (this.viewModel === null) {
      return;
    }
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
    if (this.viewModel === null) {
      return;
    }
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

  // ===== 辅助方法 =====

  private sceneStatusText(status: WorldSceneStatus): string {
    if (status === WorldSceneStatus.Active) {
      return '进行中';
    }
    return '已结束';
  }

  private senderTypeLabel(t: WorldSceneMessageSenderType): string {
    if (t === WorldSceneMessageSenderType.User) {
      return '用户';
    }
    if (t === WorldSceneMessageSenderType.Character) {
      return '角色';
    }
    return '旁白';
  }

  private senderColor(t: WorldSceneMessageSenderType): ResourceColor {
    if (t === WorldSceneMessageSenderType.User) {
      return $r('app.color.app_accent');
    }
    if (t === WorldSceneMessageSenderType.Character) {
      return $r('app.color.app_text_primary');
    }
    return $r('app.color.app_text_tertiary');
  }

  private visibilityLabel(v: WorldSceneMessageVisibility): string {
    if (v === WorldSceneMessageVisibility.Public) {
      return '公开';
    }
    if (v === WorldSceneMessageVisibility.Private) {
      return '私下';
    }
    return '旁白';
  }

  private resolveInstanceName(detail: WorldSceneChatUiModel, instanceId: string): string {
    for (let i = 0; i < detail.characters.length; i++) {
      if (detail.characters[i].instanceId === instanceId) {
        return detail.characters[i].displayName;
      }
    }
    return '已移除角色';
  }
}
