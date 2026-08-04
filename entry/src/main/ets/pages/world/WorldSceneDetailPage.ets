/**
 * WorldSceneDetailPage 场景详情页(W-SCENE-1B)
 *
 * 职责:
 * - 显示场景状态、地点、开始/结束时间
 * - 显示当前地点 Active 角色
 * - 按顺序展示消息列表(区分 sender / visibility / recipient / witness / replyTarget)
 * - 结束场景(Ended Scene 只读)
 * - 手动添加 User / Character / Narrator 消息(三个独立表单)
 *
 * 路由:通过 AppStorage PENDING_WORLD_SCENE_ID_KEY 传 sceneId
 * 写入调用 WorldSceneService。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldSceneDetailViewModel,
  WorldSceneDetailLoadState,
  WorldSceneDetailUiModel,
  SceneMessageUiModel,
  SceneCharacterUiModel,
  UserMessageFormInput,
  CharacterMessageFormInput,
  NarratorMessageFormInput,
  formatSceneTimestamp
} from '../../viewmodels/world/WorldSceneDetailViewModel';
import {
  PENDING_WORLD_SCENE_ID_KEY,
  WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import {
  WorldSceneMessageVisibility,
  WorldSceneMessageSenderType
} from '../../models/world/WorldSceneMessage';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneDetailPage';

/** 手动消息表单类型 */
enum MessageFormType {
  None,
  User,
  Character,
  Narrator
}

@Entry
@Component
struct WorldSceneDetailPage {
  @State private viewModel: WorldSceneDetailViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldSceneDetailLoadState = WorldSceneDetailLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldSceneDetailUiModel | null = null;
  @State private actionError: string = '';
  @State private currentForm: MessageFormType = MessageFormType.None;

  // User 消息表单
  @State private userContent: string = '';
  @State private userVisibility: WorldSceneMessageVisibility = WorldSceneMessageVisibility.Public;
  @State private userRecipientIds: string[] = [];
  @State private userReplyTargetIds: string[] = [];

  // Character 消息表单
  @State private charSenderId: string = '';
  @State private charContent: string = '';
  @State private charVisibility: WorldSceneMessageVisibility = WorldSceneMessageVisibility.Public;
  @State private charRecipientIds: string[] = [];

  // Narrator 消息表单
  @State private narratorContent: string = '';
  @State private narratorWitnessIds: string[] = [];

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp(WORLD_SCENE_DETAIL_REFRESH_TOKEN_KEY) @Watch('onRefreshTokenChange')
  sceneRefreshToken: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const sceneId: string = AppStorage.get<string>(PENDING_WORLD_SCENE_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_SCENE_ID_KEY, '');
      if (sceneId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: sceneId empty');
        this.isInitializing = false;
        this.loadState = WorldSceneDetailLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldSceneDetailViewModel(
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
      this.loadState = WorldSceneDetailLoadState.Error;
      this.errorMessage = '场景详情加载失败,请重试';
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
    // 重置表单(防止旧选择残留)
    if (this.detail !== null && this.detail.sceneStatus !== WorldSceneStatus.Active) {
      this.currentForm = MessageFormType.None;
    }
  }

  build(): void {
    Column() {
      this.headerArea();
      if (this.isInitializing) {
        this.loadingView();
      } else if (this.loadState === WorldSceneDetailLoadState.Loading) {
        this.loadingView();
      } else if (this.loadState === WorldSceneDetailLoadState.NotFound) {
        this.notFoundView();
      } else if (this.loadState === WorldSceneDetailLoadState.Error) {
        this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '场景详情加载失败,请重试');
      } else if (this.loadState === WorldSceneDetailLoadState.Ready && this.detail !== null) {
        this.contentView(this.detail)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_home_back'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .onClick(() => {
          router.back();
        })
      Text($r('app.string.world_scene_detail_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.loadSnapshot();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress().width(40).height(40).color($r('app.color.app_accent'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      EmptyStateView({ title: $r('app.string.world_detail_not_found'), description: '' })
      Button($r('app.string.world_back_to_list'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => { router.back(); })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(message: string): void {
    Column() {
      EmptyStateView({ title: $r('app.string.world_home_load_failed'), description: message })
      Row() {
        Button($r('app.string.world_back_to_list'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .padding({ left: 20, right: 20 })
          .onClick(() => { router.back(); })
        Button($r('app.string.world_home_reload'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .padding({ left: 20, right: 20 })
          .margin({ left: 12 })
          .onClick(() => { this.loadSnapshot(); })
      }
      .margin({ top: $r('app.float.app_spacing_16') })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  contentView(detail: WorldSceneDetailUiModel): void {
    Scroll() {
      Column() {
        this.sceneHeaderSection(detail)
        if (this.actionError.length > 0) {
          this.actionErrorBanner(this.actionError)
        }
        // 操作区(Active Scene 才显示)
        if (detail.sceneStatus === WorldSceneStatus.Active) {
          this.actionButtonsSection(detail)
        }
        // 当前地点 Active 角色
        this.characterSection(detail)
        // 消息列表
        this.messageListSection(detail)
        // 手动消息表单(根据 currentForm 显示)
        if (detail.sceneStatus === WorldSceneStatus.Active && this.currentForm !== MessageFormType.None) {
          if (this.currentForm === MessageFormType.User) {
            this.userMessageForm(detail)
          } else if (this.currentForm === MessageFormType.Character) {
            this.characterMessageForm(detail)
          } else if (this.currentForm === MessageFormType.Narrator) {
            this.narratorMessageForm(detail)
          }
        }
        Column().width('100%').height(120)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ left: $r('app.float.app_spacing_16'), right: $r('app.float.app_spacing_16'), top: 0, bottom: 0 })
  }

  @Builder
  sceneHeaderSection(detail: WorldSceneDetailUiModel): void {
    Column() {
      Row() {
        Text(detail.locationName.length > 0 ? detail.locationName : '(未命名地点)')
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(detail.sceneStatus === WorldSceneStatus.Active ? '进行中' : '已结束')
          .fontSize(11)
          .fontColor(detail.sceneStatus === WorldSceneStatus.Active
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_tertiary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text('所属世界:' + detail.worldName)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 6 })
      Text('开始时间:' + formatSceneTimestamp(detail.startedAt))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 4 })
      if (detail.endedAt > 0) {
        Text('结束时间:' + formatSceneTimestamp(detail.endedAt))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  actionErrorBanner(message: string): void {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(16)
        .fontColor([$r('app.color.app_danger')])
      Text(message)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_danger'))
        .margin({ left: 8 })
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .fontColor($r('app.color.app_text_tertiary'))
        .backgroundColor(Color.Transparent)
        .height(24)
        .width(24)
        .padding(0)
        .onClick(() => { this.actionError = ''; })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  actionButtonsSection(detail: WorldSceneDetailUiModel): void {
    Column() {
      Row() {
        Button($r('app.string.world_scene_add_user_message'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.currentForm === MessageFormType.User
            ? $r('app.color.app_on_accent')
            : $r('app.color.app_accent'))
          .backgroundColor(this.currentForm === MessageFormType.User
            ? $r('app.color.app_accent')
            : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.currentForm = this.currentForm === MessageFormType.User
              ? MessageFormType.None : MessageFormType.User;
            this.actionError = '';
          })
        Button($r('app.string.world_scene_add_character_message'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.currentForm === MessageFormType.Character
            ? $r('app.color.app_on_accent')
            : $r('app.color.app_accent'))
          .backgroundColor(this.currentForm === MessageFormType.Character
            ? $r('app.color.app_accent')
            : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .onClick(() => {
            this.currentForm = this.currentForm === MessageFormType.Character
              ? MessageFormType.None : MessageFormType.Character;
            this.actionError = '';
          })
        Button($r('app.string.world_scene_add_narrator_message'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.currentForm === MessageFormType.Narrator
            ? $r('app.color.app_on_accent')
            : $r('app.color.app_accent'))
          .backgroundColor(this.currentForm === MessageFormType.Narrator
            ? $r('app.color.app_accent')
            : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .onClick(() => {
            this.currentForm = this.currentForm === MessageFormType.Narrator
              ? MessageFormType.None : MessageFormType.Narrator;
            this.actionError = '';
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 结束场景按钮
      Button($r('app.string.world_scene_end'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_danger'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 12, right: 12 })
        .margin({ top: 8 })
        .width('100%')
        .enabled(this.viewModel !== null && !this.viewModel.isEnding)
        .onClick(() => { this.confirmEndScene(); })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  characterSection(detail: WorldSceneDetailUiModel): void {
    Column() {
      Text($r('app.string.world_scene_active_characters'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 8 })
      if (detail.characters.length === 0) {
        Text($r('app.string.world_scene_no_characters'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
      } else {
        ForEach(detail.characters, (c: SceneCharacterUiModel) => {
          Row() {
            Text(c.displayName.length > 0 ? c.displayName : '(未命名)')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)
            Text(c.isActive ? '活跃' : '停用')
              .fontSize(11)
              .fontColor(c.isActive ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        }, (c: SceneCharacterUiModel) => c.instanceId + '|' + (c.isActive ? '1' : '0'))
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  messageListSection(detail: WorldSceneDetailUiModel): void {
    Column() {
      Text($r('app.string.world_scene_messages'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 8 })
      if (detail.messages.length === 0) {
        Text($r('app.string.world_scene_no_messages'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 16 })
      } else {
        ForEach(detail.messages, (m: SceneMessageUiModel) => {
          this.messageCard(m)
        }, (m: SceneMessageUiModel) => m.id + '|' + m.sequenceNumber.toString())
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  messageCard(m: SceneMessageUiModel): void {
    Column() {
      // 第1行:序号 + 发送者类型标签 + 可见性标签
      Row() {
        Text('#' + m.sequenceNumber.toString())
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
        Text(this.senderTypeLabel(m.senderType))
          .fontSize(11)
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 6 })
        Text(this.visibilityLabel(m.visibility))
          .fontSize(11)
          .fontColor(this.visibilityColor(m.visibility))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 4 })
        Text(formatSceneTimestamp(m.createdAt))
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第2行:发送者名称
      if (m.senderType === WorldSceneMessageSenderType.Character) {
        Text(this.senderDisplayLabel(m))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(m.senderRemoved ? $r('app.color.app_text_tertiary') : $r('app.color.app_text_secondary'))
          .margin({ top: 4 })
      }

      // 第3行:消息正文
      Text(m.content)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .width('100%')
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)

      // 第4行:接收者/目击者/回复目标(可选)
      if (m.recipientNames.length > 0) {
        Text('接收者:' + m.recipientNames.join('、'))
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
      if (m.witnessNames.length > 0) {
        Text('目击者:' + m.witnessNames.join('、'))
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
      if (m.replyTargetNames.length > 0) {
        Text('回复目标:' + m.replyTargetNames.join('、'))
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
    .backgroundColor($r('app.color.app_bg'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ top: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 手动消息表单 =====

  @Builder
  userMessageForm(detail: WorldSceneDetailUiModel): void {
    Column() {
      Text($r('app.string.world_scene_user_message_form_title'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })

      // 正文输入
      TextArea({ text: this.userContent, placeholder: '请输入用户消息正文' })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(80)
        .padding(8)
        .onChange((v: string) => { this.userContent = v; })

      // 可见性选择(Public / Private 互斥)
      Row() {
        Text('可见性')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ right: 8 })
        Button('公开')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.userVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.app_on_accent') : $r('app.color.app_accent'))
          .backgroundColor(this.userVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.userVisibility = WorldSceneMessageVisibility.Public;
            this.userRecipientIds = [];
          })
        Button('私下')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.userVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.app_on_accent') : $r('app.color.app_accent'))
          .backgroundColor(this.userVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .onClick(() => {
            this.userVisibility = WorldSceneMessageVisibility.Private;
            this.userReplyTargetIds = [];
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)

      // Private:接收者多选
      if (this.userVisibility === WorldSceneMessageVisibility.Private) {
        this.instanceMultiSelect($r('app.string.world_scene_recipients'), detail.characters, this.userRecipientIds,
          (id: string) => {
            this.toggleIdInArray(id, this.userRecipientIds, (newArr: string[]) => { this.userRecipientIds = newArr; });
          })
      }
      // Public:回复目标多选(可选)
      if (this.userVisibility === WorldSceneMessageVisibility.Public) {
        this.instanceMultiSelect($r('app.string.world_scene_reply_targets'), detail.characters, this.userReplyTargetIds,
          (id: string) => {
            this.toggleIdInArray(id, this.userReplyTargetIds, (newArr: string[]) => { this.userReplyTargetIds = newArr; });
          })
      }

      // 保存 + 取消
      Row() {
        Button($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .layoutWeight(1)
          .onClick(() => { this.cancelForm(); })
        Button($r('app.string.world_scene_save'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .margin({ left: 8 })
          .layoutWeight(1)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving)
          .onClick(() => { this.saveUserMessage(); })
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  characterMessageForm(detail: WorldSceneDetailUiModel): void {
    Column() {
      Text($r('app.string.world_scene_character_message_form_title'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })

      // 发言角色选择(只能是当前地点 Active 实例)
      Text('发言角色')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ bottom: 4 })
      this.activeInstanceSingleSelect(detail.characters, this.charSenderId, (id: string) => {
        this.charSenderId = id;
      })

      // 正文输入
      TextArea({ text: this.charContent, placeholder: '请输入角色台词' })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(80)
        .padding(8)
        .margin({ top: 8 })
        .onChange((v: string) => { this.charContent = v; })

      // 可见性
      Row() {
        Text('可见性')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ right: 8 })
        Button('公开')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.charVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.app_on_accent') : $r('app.color.app_accent'))
          .backgroundColor(this.charVisibility === WorldSceneMessageVisibility.Public
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.charVisibility = WorldSceneMessageVisibility.Public;
            this.charRecipientIds = [];
          })
        Button('私下')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.charVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.app_on_accent') : $r('app.color.app_accent'))
          .backgroundColor(this.charVisibility === WorldSceneMessageVisibility.Private
            ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .onClick(() => {
            this.charVisibility = WorldSceneMessageVisibility.Private;
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)

      // Private:接收者多选(排除 sender)
      if (this.charVisibility === WorldSceneMessageVisibility.Private) {
        this.instanceMultiSelect($r('app.string.world_scene_recipients'),
          this.filterOutSender(detail.characters, this.charSenderId),
          this.charRecipientIds,
          (id: string) => {
            this.toggleIdInArray(id, this.charRecipientIds, (newArr: string[]) => { this.charRecipientIds = newArr; });
          })
      }

      Row() {
        Button($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .layoutWeight(1)
          .onClick(() => { this.cancelForm(); })
        Button($r('app.string.world_scene_save'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .margin({ left: 8 })
          .layoutWeight(1)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving)
          .onClick(() => { this.saveCharacterMessage(); })
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  narratorMessageForm(detail: WorldSceneDetailUiModel): void {
    Column() {
      Text($r('app.string.world_scene_narrator_message_form_title'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })

      TextArea({ text: this.narratorContent, placeholder: '请输入旁白或动作描述' })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(80)
        .padding(8)
        .onChange((v: string) => { this.narratorContent = v; })

      // 目击者多选(可为空)
      Text($r('app.string.world_scene_witnesses'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 8, bottom: 4 })
      this.instanceMultiSelect($r('app.string.world_scene_witnesses'), detail.characters, this.narratorWitnessIds,
        (id: string) => {
          this.toggleIdInArray(id, this.narratorWitnessIds, (newArr: string[]) => { this.narratorWitnessIds = newArr; });
        })

      Row() {
        Button($r('app.string.world_scene_cancel'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .layoutWeight(1)
          .onClick(() => { this.cancelForm(); })
        Button($r('app.string.world_scene_save'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .margin({ left: 8 })
          .layoutWeight(1)
          .enabled(this.viewModel !== null && !this.viewModel.isSaving)
          .onClick(() => { this.saveNarratorMessage(); })
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 实例多选列表 */
  @Builder
  instanceMultiSelect(
    label: ResourceStr,
    instances: SceneCharacterUiModel[],
    selectedIds: string[],
    onToggle: (id: string) => void
  ): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 8, bottom: 4 })
      if (instances.length === 0) {
        Text($r('app.string.world_scene_no_active_instances'))
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
          .padding({ top: 4, bottom: 4 })
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(instances, (c: SceneCharacterUiModel) => {
            Button(c.displayName.length > 0 ? c.displayName : '(未命名)')
              .fontSize(11)
              .fontColor(this.isIdSelected(c.instanceId, selectedIds)
                ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
              .backgroundColor(this.isIdSelected(c.instanceId, selectedIds)
                ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
              .borderRadius(12)
              .height(28)
              .padding({ left: 10, right: 10 })
              .margin({ right: 6, bottom: 6 })
              .onClick(() => { onToggle(c.instanceId); })
          }, (c: SceneCharacterUiModel) => c.instanceId)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Active 实例单选列表(用于发言角色选择) */
  @Builder
  activeInstanceSingleSelect(
    instances: SceneCharacterUiModel[],
    selectedId: string,
    onSelect: (id: string) => void
  ): void {
    if (instances.length === 0) {
      Text($r('app.string.world_scene_no_active_instances'))
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .padding({ top: 4, bottom: 4 })
    } else {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(instances, (c: SceneCharacterUiModel) => {
          Button(c.displayName.length > 0 ? c.displayName : '(未命名)')
            .fontSize(11)
            .fontColor(selectedId === c.instanceId
              ? $r('app.color.app_on_accent') : $r('app.color.app_text_secondary'))
            .backgroundColor(selectedId === c.instanceId
              ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius(12)
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ right: 6, bottom: 6 })
            .onClick(() => { onSelect(c.instanceId); })
        }, (c: SceneCharacterUiModel) => c.instanceId)
      }
      .width('100%')
    }
  }

  // ===== 辅助方法 =====

  private senderTypeLabel(t: WorldSceneMessageSenderType): string {
    if (t === WorldSceneMessageSenderType.User) return '用户';
    if (t === WorldSceneMessageSenderType.Character) return '角色';
    return '旁白';
  }

  private visibilityLabel(v: WorldSceneMessageVisibility): string {
    if (v === WorldSceneMessageVisibility.Public) return '公开';
    if (v === WorldSceneMessageVisibility.Private) return '私下';
    return '旁白';
  }

  private visibilityColor(v: WorldSceneMessageVisibility): ResourceColor {
    if (v === WorldSceneMessageVisibility.Private) return $r('app.color.app_danger');
    return $r('app.color.app_text_secondary');
  }

  private senderDisplayLabel(m: SceneMessageUiModel): string {
    if (m.senderRemoved) {
      return '已移除角色';
    }
    return m.senderDisplayName.length > 0 ? m.senderDisplayName : '(未命名)';
  }

  private isIdSelected(id: string, selectedIds: string[]): boolean {
    for (let i = 0; i < selectedIds.length; i++) {
      if (selectedIds[i] === id) return true;
    }
    return false;
  }

  private toggleIdInArray(id: string, current: string[], setter: (newArr: string[]) => void): void {
    const newArr: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < current.length; i++) {
      if (current[i] === id) {
        found = true;
      } else {
        newArr.push(current[i]);
      }
    }
    if (!found) {
      newArr.push(id);
    }
    setter(newArr);
  }

  private filterOutSender(instances: SceneCharacterUiModel[], senderId: string): SceneCharacterUiModel[] {
    const result: SceneCharacterUiModel[] = [];
    for (let i = 0; i < instances.length; i++) {
      if (instances[i].instanceId !== senderId) {
        result.push(instances[i]);
      }
    }
    return result;
  }

  private cancelForm(): void {
    this.currentForm = MessageFormType.None;
    this.actionError = '';
    this.userContent = '';
    this.userRecipientIds = [];
    this.userReplyTargetIds = [];
    this.charSenderId = '';
    this.charContent = '';
    this.charRecipientIds = [];
    this.narratorContent = '';
    this.narratorWitnessIds = [];
  }

  private async saveUserMessage(): Promise<void> {
    if (this.viewModel === null) return;
    this.actionError = '';
    const input: UserMessageFormInput = {
      content: this.userContent,
      visibility: this.userVisibility,
      recipientInstanceIds: this.userRecipientIds,
      replyTargetInstanceIds: this.userReplyTargetIds
    };
    const result = await this.viewModel.addUserMessage(input);
    if (!result.success) {
      this.actionError = result.errorMessage;
      return;
    }
    this.cancelForm();
    this.syncFromViewModel();
  }

  private async saveCharacterMessage(): Promise<void> {
    if (this.viewModel === null) return;
    this.actionError = '';
    const input: CharacterMessageFormInput = {
      senderInstanceId: this.charSenderId,
      content: this.charContent,
      visibility: this.charVisibility,
      recipientInstanceIds: this.charRecipientIds
    };
    const result = await this.viewModel.addCharacterMessage(input);
    if (!result.success) {
      this.actionError = result.errorMessage;
      return;
    }
    this.cancelForm();
    this.syncFromViewModel();
  }

  private async saveNarratorMessage(): Promise<void> {
    if (this.viewModel === null) return;
    this.actionError = '';
    const input: NarratorMessageFormInput = {
      content: this.narratorContent,
      witnessInstanceIds: this.narratorWitnessIds
    };
    const result = await this.viewModel.addNarratorMessage(input);
    if (!result.success) {
      this.actionError = result.errorMessage;
      return;
    }
    this.cancelForm();
    this.syncFromViewModel();
  }

  private confirmEndScene(): void {
    if (this.viewModel === null) return;
    // 简单确认:直接调用结束(没有 AlertDialog,因为 ArkUI 的 AlertDialog 在 @Builder 外使用复杂,
    // 这里采用直接调用 + 错误反馈的方式,用户可通过按钮状态判断)
    this.actionError = '';
    this.viewModel.endScene().then((result) => {
      if (!result.success) {
        this.actionError = result.errorMessage;
        return;
      }
      this.syncFromViewModel();
    });
  }
}
