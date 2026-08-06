/**
 * WorldSceneDetailPage 场景详情页(W-UI-1C 重构)
 *
 * 重构:深色酒馆质感,场景头+状态标签+消息时间线,
 * [玩家]/[角色·name]/[旁白] 标签,消息状态徽章,
 * Ended Scene 只读横幅,Active Scene 操作表单。
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
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneDetailPage';

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

  @State private userContent: string = '';
  @State private userVisibility: WorldSceneMessageVisibility = WorldSceneMessageVisibility.Public;
  @State private userRecipientIds: string[] = [];
  @State private userReplyTargetIds: string[] = [];

  @State private charSenderId: string = '';
  @State private charContent: string = '';
  @State private charVisibility: WorldSceneMessageVisibility = WorldSceneMessageVisibility.Public;
  @State private charRecipientIds: string[] = [];

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
    if (this.detail !== null && this.detail.sceneStatus !== WorldSceneStatus.Active) {
      this.currentForm = MessageFormType.None;
    }
  }

  build(): void {
    Column() {
      this.topNav()
      if (this.isInitializing || this.loadState === WorldSceneDetailLoadState.Loading) {
        this.loadingView();
      } else if (this.loadState === WorldSceneDetailLoadState.NotFound) {
        this.notFoundView();
      } else if (this.loadState === WorldSceneDetailLoadState.Error) {
        this.errorView();
      } else if (this.loadState === WorldSceneDetailLoadState.Ready && this.detail !== null) {
        this.contentView(this.detail)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  topNav(): void {
    Row() {
      Button('←')
        .fontSize(22)
        .fontColor($r('app.color.world_text_secondary'))
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .padding(0)
        .onClick(() => {
          router.back();
        })

      Text($r('app.string.world_scene_detail_title'))
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })

      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .backgroundColor($r('app.color.world_surface_1'))
        .borderRadius($r('app.float.world_radius_chip'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.loadSnapshot();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding'),
      top: this.statusBarHeight + 4,
      bottom: 4
    })
    .alignItems(VerticalAlign.Center)
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
      WorldEmptyState({
        title: $r('app.string.world_detail_not_found'),
        primaryLabel: $r('app.string.world_back_to_list'),
        onPrimary: (): void => {
          router.back();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      WorldEmptyState({
        title: $r('app.string.world_home_load_failed'),
        description: this.errorMessage.length > 0 ? this.errorMessage : '',
        primaryLabel: $r('app.string.world_home_reload'),
        onPrimary: (): void => {
          this.loadSnapshot();
        }
      })
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
        this.sceneHeaderCard(detail)
        if (this.actionError.length > 0) {
          this.actionErrorBanner()
        }
        if (detail.sceneStatus === WorldSceneStatus.Ended) {
          this.endedBanner()
        }
        if (detail.sceneStatus === WorldSceneStatus.Active) {
          this.actionButtonsSection(detail)
        }
        this.characterSection(detail)
        this.messageListSection(detail)
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
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding')
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  sceneHeaderCard(detail: WorldSceneDetailUiModel): void {
    WorldSurfaceCard({ elevated: detail.sceneStatus === WorldSceneStatus.Active }) {
      Column() {
        Row() {
          Text(detail.locationName.length > 0 ? detail.locationName : '(未命名地点)')
            .fontSize($r('app.float.world_font_subtitle'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.world_text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          WorldStatusChip({
            label: detail.sceneStatus === WorldSceneStatus.Active ? '活动中' : '已结束',
            isActive: detail.sceneStatus === WorldSceneStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Text('所属世界: ' + detail.worldName)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ top: 6 })
        Text('开始: ' + formatSceneTimestamp(detail.startedAt))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ top: 4 })
        if (detail.endedAt > 0) {
          Text('结束: ' + formatSceneTimestamp(detail.endedAt))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ top: 2 })
        }
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  endedBanner(): void {
    Row() {
      Text($r('app.string.world_scene_ended_hint'))
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_card'))
    .margin({ top: $r('app.float.world_card_spacing') })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  actionErrorBanner(): void {
    Row() {
      Text(this.actionError)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_error'))
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .fontColor($r('app.color.world_text_tertiary'))
        .backgroundColor(Color.Transparent)
        .height(24)
        .width(24)
        .padding(0)
        .onClick(() => { this.actionError = ''; })
    }
    .width('100%')
    .padding(10)
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_chip'))
    .margin({ top: $r('app.float.world_card_spacing') })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  actionButtonsSection(detail: WorldSceneDetailUiModel): void {
    WorldSurfaceCard({ elevated: false }) {
      Column() {
        Row() {
          this.formTabButton('用户消息', MessageFormType.User)
          this.formTabButton('角色台词', MessageFormType.Character)
          this.formTabButton('旁白', MessageFormType.Narrator)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Button($r('app.string.world_scene_end'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_on_danger'))
          .backgroundColor($r('app.color.world_error'))
          .borderRadius($r('app.float.world_radius_button'))
          .height(36)
          .margin({ top: 8 })
          .width('100%')
          .enabled(this.viewModel !== null && !this.viewModel.isEnding)
          .onClick(() => { this.confirmEndScene(); })
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  formTabButton(label: string, formType: MessageFormType): void {
    Text(label)
      .fontSize($r('app.float.world_font_caption'))
      .fontColor(this.currentForm === formType
        ? $r('app.color.world_on_gold')
        : $r('app.color.world_text_secondary'))
      .backgroundColor(this.currentForm === formType
        ? $r('app.color.world_gold')
        : $r('app.color.world_surface_2'))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8 })
      .onClick(() => {
        this.currentForm = this.currentForm === formType ? MessageFormType.None : formType;
        this.actionError = '';
      })
  }

  @Builder
  characterSection(detail: WorldSceneDetailUiModel): void {
    WorldSectionHeader({ title: '当前角色' })
    WorldSurfaceCard({ elevated: false }) {
      Column() {
        if (detail.characters.length === 0) {
          Text($r('app.string.world_scene_no_characters'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
        } else {
          ForEach(detail.characters, (c: SceneCharacterUiModel) => {
            Row() {
              Text(c.displayName.length > 0 ? c.displayName : '(未命名)')
                .fontSize($r('app.float.world_font_body'))
                .fontColor($r('app.color.world_text_primary'))
                .layoutWeight(1)
              WorldStatusChip({
                label: c.isActive ? '活跃' : '停用',
                isActive: c.isActive
              })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .alignItems(VerticalAlign.Center)
          }, (c: SceneCharacterUiModel) => c.instanceId + '|' + (c.isActive ? '1' : '0'))
        }
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  messageListSection(detail: WorldSceneDetailUiModel): void {
    WorldSectionHeader({ title: '消息记录', subtitle: detail.messages.length.toString() + ' 条' })
    if (detail.messages.length === 0) {
      WorldSurfaceCard({ elevated: false }) {
        Text($r('app.string.world_scene_no_messages'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 16 })
      }
    } else {
      ForEach(detail.messages, (m: SceneMessageUiModel) => {
        this.messageCard(m)
      }, (m: SceneMessageUiModel) => m.id + '|' + m.sequenceNumber.toString() + '|' + m.messageStatus)
    }
  }

  @Builder
  messageCard(m: SceneMessageUiModel): void {
    WorldSurfaceCard({ elevated: m.senderType === WorldSceneMessageSenderType.User }) {
      Column() {
        Row() {
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

          Text('#' + m.sequenceNumber.toString())
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ left: 6 })

          Text(formatSceneTimestamp(m.createdAt))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(m.content)
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .width('100%')
          .margin({ top: 6 })
          .textAlign(TextAlign.Start)

        if (m.recipientNames.length > 0) {
          Text('接收者: ' + m.recipientNames.join('、'))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ top: 4 })
        }
        if (m.witnessNames.length > 0) {
          Text('目击者: ' + m.witnessNames.join('、'))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ top: 2 })
        }
        if (m.replyTargetNames.length > 0) {
          Text('回复目标: ' + m.replyTargetNames.join('、'))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ top: 2 })
        }
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  userMessageForm(detail: WorldSceneDetailUiModel): void {
    WorldSurfaceCard({ elevated: true }) {
      Column() {
        Text('用户消息')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 8 })

        TextArea({ text: this.userContent, placeholder: '请输入用户消息正文' })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(80)
          .padding(8)
          .onChange((v: string) => { this.userContent = v; })

        Row() {
          Text('可见性')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_secondary'))
            .margin({ right: 8 })
          this.visibilityToggle('公开', WorldSceneMessageVisibility.Public, this.userVisibility,
            () => {
              this.userVisibility = WorldSceneMessageVisibility.Public;
              this.userRecipientIds = [];
            })
          this.visibilityToggle('私下', WorldSceneMessageVisibility.Private, this.userVisibility,
            () => {
              this.userVisibility = WorldSceneMessageVisibility.Private;
              this.userReplyTargetIds = [];
            })
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)

        if (this.userVisibility === WorldSceneMessageVisibility.Private) {
          this.instanceMultiSelect('接收者', detail.characters, this.userRecipientIds,
            (id: string) => {
              this.toggleIdInArray(id, this.userRecipientIds, (newArr: string[]) => { this.userRecipientIds = newArr; });
            })
        }
        if (this.userVisibility === WorldSceneMessageVisibility.Public) {
          this.instanceMultiSelect('回复目标', detail.characters, this.userReplyTargetIds,
            (id: string) => {
              this.toggleIdInArray(id, this.userReplyTargetIds, (newArr: string[]) => { this.userReplyTargetIds = newArr; });
            })
        }

        Row() {
          WorldSecondaryButton({
            label: $r('app.string.world_scene_cancel'),
            onButtonClick: (): void => { this.cancelForm(); }
          })
          WorldPrimaryButton({
            label: $r('app.string.world_scene_save'),
            isEnabled: this.viewModel !== null && !this.viewModel.isSaving,
            onButtonClick: (): void => { this.saveUserMessage(); }
          })
        }
        .width('100%')
        .margin({ top: 10 })
        .justifyContent(FlexAlign.End)
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  characterMessageForm(detail: WorldSceneDetailUiModel): void {
    WorldSurfaceCard({ elevated: true }) {
      Column() {
        Text('角色台词(手工)')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 8 })

        Text('发言角色')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ bottom: 4 })
        this.activeInstanceSingleSelect(detail.characters, this.charSenderId, (id: string) => {
          this.charSenderId = id;
        })

        TextArea({ text: this.charContent, placeholder: '请输入角色台词' })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(80)
          .padding(8)
          .margin({ top: 8 })
          .onChange((v: string) => { this.charContent = v; })

        Row() {
          Text('可见性')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_secondary'))
            .margin({ right: 8 })
          this.visibilityToggle('公开', WorldSceneMessageVisibility.Public, this.charVisibility,
            () => {
              this.charVisibility = WorldSceneMessageVisibility.Public;
              this.charRecipientIds = [];
            })
          this.visibilityToggle('私下', WorldSceneMessageVisibility.Private, this.charVisibility,
            () => {
              this.charVisibility = WorldSceneMessageVisibility.Private;
            })
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)

        if (this.charVisibility === WorldSceneMessageVisibility.Private) {
          this.instanceMultiSelect('接收者',
            this.filterOutSender(detail.characters, this.charSenderId),
            this.charRecipientIds,
            (id: string) => {
              this.toggleIdInArray(id, this.charRecipientIds, (newArr: string[]) => { this.charRecipientIds = newArr; });
            })
        }

        Row() {
          WorldSecondaryButton({
            label: $r('app.string.world_scene_cancel'),
            onButtonClick: (): void => { this.cancelForm(); }
          })
          WorldPrimaryButton({
            label: $r('app.string.world_scene_save'),
            isEnabled: this.viewModel !== null && !this.viewModel.isSaving
              && this.charSenderId.length > 0,
            onButtonClick: (): void => { this.saveCharacterMessage(); }
          })
        }
        .width('100%')
        .margin({ top: 10 })
        .justifyContent(FlexAlign.End)
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  narratorMessageForm(detail: WorldSceneDetailUiModel): void {
    WorldSurfaceCard({ elevated: true }) {
      Column() {
        Text('旁白/动作')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_primary'))
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 8 })

        TextArea({ text: this.narratorContent, placeholder: '请输入旁白或动作描述' })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(80)
          .padding(8)
          .onChange((v: string) => { this.narratorContent = v; })

        this.instanceMultiSelect('目击者', detail.characters, this.narratorWitnessIds,
          (id: string) => {
            this.toggleIdInArray(id, this.narratorWitnessIds, (newArr: string[]) => { this.narratorWitnessIds = newArr; });
          })

        Row() {
          WorldSecondaryButton({
            label: $r('app.string.world_scene_cancel'),
            onButtonClick: (): void => { this.cancelForm(); }
          })
          WorldPrimaryButton({
            label: $r('app.string.world_scene_save'),
            isEnabled: this.viewModel !== null && !this.viewModel.isSaving,
            onButtonClick: (): void => { this.saveNarratorMessage(); }
          })
        }
        .width('100%')
        .margin({ top: 10 })
        .justifyContent(FlexAlign.End)
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  visibilityToggle(label: string, value: WorldSceneMessageVisibility, current: WorldSceneMessageVisibility,
    onSelect: () => void): void {
    Text(label)
      .fontSize($r('app.float.world_font_caption'))
      .fontColor(current === value ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
      .backgroundColor(current === value ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .margin({ right: 6 })
      .onClick(() => { onSelect(); })
  }

  @Builder
  instanceMultiSelect(label: string, instances: SceneCharacterUiModel[], selectedIds: string[],
    onToggle: (id: string) => void): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 8, bottom: 4 })
      if (instances.length === 0) {
        Text('无可用角色')
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .padding({ top: 4, bottom: 4 })
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(instances, (c: SceneCharacterUiModel) => {
            Text(c.displayName.length > 0 ? c.displayName : '(未命名)')
              .fontSize($r('app.float.world_font_micro'))
              .fontColor(this.isIdSelected(c.instanceId, selectedIds)
                ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
              .backgroundColor(this.isIdSelected(c.instanceId, selectedIds)
                ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
              .borderRadius($r('app.float.world_radius_chip'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .margin({ right: 4, bottom: 4 })
              .onClick(() => { onToggle(c.instanceId); })
          }, (c: SceneCharacterUiModel) => c.instanceId)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  activeInstanceSingleSelect(instances: SceneCharacterUiModel[], selectedId: string,
    onSelect: (id: string) => void): void {
    if (instances.length === 0) {
      Text('无可用角色')
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_tertiary'))
        .padding({ top: 4, bottom: 4 })
    } else {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(instances, (c: SceneCharacterUiModel) => {
          Text(c.displayName.length > 0 ? c.displayName : '(未命名)')
            .fontSize($r('app.float.world_font_micro'))
            .fontColor(selectedId === c.instanceId
              ? $r('app.color.world_on_gold') : $r('app.color.world_text_secondary'))
            .backgroundColor(selectedId === c.instanceId
              ? $r('app.color.world_gold') : $r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => { onSelect(c.instanceId); })
        }, (c: SceneCharacterUiModel) => c.instanceId)
      }
      .width('100%')
    }
  }

  private senderLabel(m: SceneMessageUiModel): string {
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