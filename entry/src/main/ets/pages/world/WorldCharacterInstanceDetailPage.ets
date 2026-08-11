/**
 * WorldCharacterInstanceDetailPage 角色实例详情页(W-UI-1B → W2A2)
 *
 * 展示世界角色实例信息(非角色卡编辑页)。包含:
 * - 世界内身份、当前状态、当前目标
 * - 近期活动、记忆摘要、关系摘要、参与场景
 * - 底部操作:开始对话(场景启动器)、查看记忆、调整位置、从地图撤下、放置到地点
 * - 危险操作:从世界移除
 *
 * 未实现的数据明确标记"尚未建立",不伪造。
 *
 * 路由:通过 AppStorage PENDING_WORLD_INSTANCE_DETAIL_ID_KEY 传 instanceId
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { WorldCharacterInstanceDetailViewModel } from '../../viewmodels/world/WorldCharacterInstanceDetailViewModel';
import {
  ActiveLocationOptionUiModel
} from '../../viewmodels/world/WorldCharacterManageViewModel';
import {
  WorldCharacterInstanceDetailUiModel,
  WorldInstanceDetailLoadState,
  PENDING_WORLD_INSTANCE_DETAIL_ID_KEY,
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_WORLD_ID_KEY,
  PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY,
  PENDING_WORLD_SCENE_CHAT_ID_KEY,
  PENDING_WORLD_SESSION_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import { TravelOption } from '../../services/world/WorldCharacterMovementService';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG: string = 'WorldCharInstanceDetailPage';

@Entry
@Component
struct WorldCharacterInstanceDetailPage {
  @State private viewModel: WorldCharacterInstanceDetailViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldInstanceDetailLoadState = WorldInstanceDetailLoadState.Loading;
  @State private errorMessage: string = '';
  @State private detail: WorldCharacterInstanceDetailUiModel | null = null;
  @State private activeLocations: ActiveLocationOptionUiModel[] = [];
  @State private isOperating: boolean = false;
  @State private isTravelling: boolean = false;
  @State private travelOptions: TravelOption[] = [];
  @State private coPresentDisplayNames: string[] = [];
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  @State private sceneLauncherVisible: boolean = false;
  @State private soloTalkError: string = '';
  @State private locationSelectVisible: boolean = false;
  @State private locationSelectMode: string = '';
  @State private unplaceConfirmVisible: boolean = false;
  @State private travelDestinationVisible: boolean = false;
  @State private removeFromWorldConfirmVisible: boolean = false;
  @State private instanceRemoved: boolean = false;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const instanceId: string = AppStorage.get<string>(PENDING_WORLD_INSTANCE_DETAIL_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_INSTANCE_DETAIL_ID_KEY, '');
      if (instanceId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: instanceId empty');
        this.isInitializing = false;
        this.loadState = WorldInstanceDetailLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldCharacterInstanceDetailViewModel(
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldStateService(),
        AppServices.getWorldCharacterMovementService(),
        AppServices.getWorldPerceptionService(),
        AppServices.getCharacterService()
      );
      this.isInitializing = false;
      await this.viewModel.loadSnapshot(instanceId);
      this.syncFromViewModel();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldInstanceDetailLoadState.Error;
      this.errorMessage = '角色实例详情加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null || this.detail === null) {
      return;
    }
    this.viewModel.activate();
    await this.viewModel.loadSnapshot(this.detail.instanceId);
    this.syncFromViewModel();
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.loadState;
    this.errorMessage = this.viewModel.errorMessage;
    this.detail = this.viewModel.detail;
    this.activeLocations = this.viewModel.activeLocations;
    this.isOperating = this.viewModel.isOperating;
    this.isTravelling = this.viewModel.isTravelling;
    this.travelOptions = this.viewModel.travelOptions;
    this.coPresentDisplayNames = this.viewModel.coPresentDisplayNames;
  }

  build(): void {
    Stack() {
      Column() {
        this.topNav()
        this.contentArea()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .bindSheet(this.sceneLauncherVisible, this.sceneLauncherSheet, {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
        onDisappear: () => {
          this.sceneLauncherVisible = false;
        }
      })

      Column()
        .width(0)
        .height(0)
        .bindSheet(this.locationSelectVisible, this.locationSelectSheet, {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
          onDisappear: () => {
            this.locationSelectVisible = false;
          }
        })

      Column()
        .width(0)
        .height(0)
        .bindSheet(this.unplaceConfirmVisible, this.unplaceConfirmSheet, {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
          onDisappear: () => {
            this.unplaceConfirmVisible = false;
          }
        })

      Column()
        .width(0)
        .height(0)
        .bindSheet(this.travelDestinationVisible, this.travelDestinationSheet, {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
          onDisappear: () => {
            this.travelDestinationVisible = false;
          }
        })

      Column()
        .width(0)
        .height(0)
        .bindSheet(this.removeFromWorldConfirmVisible, this.removeFromWorldConfirmSheet, {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          backgroundColor: ThemePalette.worldSurfaceColor(this.effectiveTheme),
          onDisappear: () => {
            this.removeFromWorldConfirmVisible = false;
          }
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  topNav(): void {
    Row() {
      Button('←')
        .fontSize(22)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .width(40)
        .height(40)
        .padding(0)
        .onClick(() => {
          router.back();
        })

      Text($r('app.string.world_char_detail_title'))
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })
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
  contentArea(): void {
    if (this.isInitializing || this.loadState === WorldInstanceDetailLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldInstanceDetailLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldInstanceDetailLoadState.Error) {
      this.errorView();
    } else if (this.loadState === WorldInstanceDetailLoadState.Ready && this.detail !== null) {
      this.readyView()
    }
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress().width(40).height(40).color(ThemePalette.accentColor(this.effectiveTheme))
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
          if (this.viewModel !== null && this.detail !== null) {
            this.viewModel.loadSnapshot(this.detail.instanceId).then((): void => {
              this.syncFromViewModel();
            });
          }
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  readyView(): void {
    Column() {
      Scroll() {
        Column() {
          this.headerCard()

          this.actionButtons()

          WorldSurfaceCard({}) {
            Column() {
              this.infoField($r('app.string.world_char_detail_world_identity'), '尚未建立')
              this.infoField($r('app.string.world_char_detail_current_status'),
                this.detail!.isActive ? '活跃 · 位于 ' + (this.detail!.currentLocationName.length > 0 ? this.detail!.currentLocationName : '未放置') : '已停用')
              this.infoField($r('app.string.world_char_detail_current_goal'), '尚未建立')
              if (this.coPresentDisplayNames.length > 0) {
                Column() {
                  Text('同地点角色')
                    .fontSize($r('app.float.world_font_body'))
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  Text(this.coPresentDisplayNames.join('、'))
                    .fontSize($r('app.float.world_font_caption'))
                    .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                    .margin({ top: 4 })
                }
                .width('100%')
                .margin({ top: 12 })
                .alignItems(HorizontalAlign.Start)
              }
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_recent_activity') })
              Text(formatWorldTimestamp(this.detail!.updatedAt))
                .fontSize($r('app.float.world_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .margin({ top: 8 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_memory_summary') })
              Text($r('app.string.world_char_detail_not_established'))
                .fontSize($r('app.float.world_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ top: 8 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_relationships') })
              Text($r('app.string.world_char_detail_not_established'))
                .fontSize($r('app.float.world_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ top: 8 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_scenes') })
              Text($r('app.string.world_char_detail_not_established'))
                .fontSize($r('app.float.world_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ top: 8 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_world_instance_id') })
              Text(this.detail!.instanceId.substring(this.detail!.instanceId.length - 16))
                .fontSize($r('app.float.world_font_micro'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ top: 4 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_original_card') })
              if (this.detail!.characterCardMissing) {
                Text($r('app.string.world_character_card_missing'))
                  .fontSize($r('app.float.world_font_caption'))
                  .fontColor($r('app.color.world_error'))
                  .margin({ top: 8 })
              } else {
                Text(this.detail!.displayName)
                  .fontSize($r('app.float.world_font_body'))
                  .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                  .margin({ top: 8 })
                  .onClick(() => {
                    this.openOriginalCharacterCard(this.detail!.characterId);
                  })
              }
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          Column().width('100%').height($r('app.float.world_page_padding'))
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
    .width('100%')
    .height('100%')
  }

  @Builder
  headerCard(): void {
    WorldSurfaceCard({ elevated: true }) {
      Column() {
        Row() {
          CharacterImageView({
            imageUri: this.detail!.avatarUri,
            fallbackName: this.detail!.fallbackName,
            imgWidth: 64,
            imgHeight: 64,
            imgBorderRadius: 32,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })

          Column() {
            Text(this.detail!.displayName)
              .fontSize($r('app.float.world_font_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(this.detail!.worldName)
              .fontSize($r('app.float.world_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 2 })

            Row() {
              WorldStatusChip({
                label: this.detail!.isActive ? '活跃' : '已停用',
                isActive: this.detail!.isActive
              })
              if (this.detail!.currentLocationId.length > 0) {
                Text(this.detail!.currentLocationName.length > 0 ? this.detail!.currentLocationName : '(未知地点)')
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(this.detail!.locationMissing
                    ? $r('app.color.world_error')
                    : ThemePalette.textSecondaryColor(this.effectiveTheme))
                  .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .margin({ left: 6 })
              } else {
                Text('未放置')
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .margin({ left: 6 })
              }
            }
            .margin({ top: 6 })
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .margin({ left: 14 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  actionButtons(): void {
    Column() {
      Row() {
        Button($r('app.string.world_char_detail_view_memory'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_button'))
          .height(34)
          .layoutWeight(1)
          .margin({ right: 6 })
          .onClick(() => { this.openCharacterMemory(this.detail!.instanceId, this.detail!.worldId); })

        Button($r('app.string.world_char_detail_start_conversation'))
          .fontSize($r('app.float.world_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_button'))
          .height(34)
          .layoutWeight(1)
          .onClick(() => { this.sceneLauncherVisible = true; })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        if (this.detail!.currentLocationId.length > 0) {
          Button('前往')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.world_radius_button'))
            .height(34)
            .layoutWeight(1)
            .margin({ right: 6 })
            .enabled(!this.isOperating && !this.isTravelling && this.travelOptions.length > 0)
            .onClick(() => { this.travelDestinationVisible = true; })
          Button('调整位置')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.world_radius_button'))
            .height(34)
            .layoutWeight(1)
            .enabled(!this.isOperating)
            .onClick(() => { this.locationSelectMode = 'adjust'; this.locationSelectVisible = true; })
        } else {
          Button('放置到地点')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.world_radius_button'))
            .height(34)
            .layoutWeight(1)
            .enabled(!this.isOperating && this.activeLocations.length > 0)
            .onClick(() => { this.locationSelectMode = 'place'; this.locationSelectVisible = true; })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 4 })

      Row() {
        if (this.detail!.currentLocationId.length > 0) {
          Button('从地图撤下')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.world_radius_button'))
            .height(34)
            .layoutWeight(1)
            .margin({ right: 6 })
            .enabled(!this.isOperating)
            .onClick(() => { this.unplaceConfirmVisible = true; })
        }

        Button('从世界移除')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.world_radius_button'))
          .height(34)
          .layoutWeight(1)
          .enabled(!this.isOperating)
          .onClick(() => { this.removeFromWorldConfirmVisible = true; })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 4 })
    }
    .width('100%')
    .margin({ top: 12, bottom: 4 })
  }

  @Builder
  infoField(label: ResourceStr, value: string): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.world_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      Text(value.length > 0 ? value : '—')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ top: 4 })
    }
    .width('100%')
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sceneLauncherSheet(): void {
    Scroll() {
      Column() {
        Text($r('app.string.world_scene_launcher_title'))
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 12, bottom: 8 })

        if (this.detail !== null) {
          Column() {
            this.sceneLauncherItem($r('app.string.world_scene_launcher_current_location'),
              this.detail.currentLocationId.length > 0
                ? (this.detail.currentLocationName.length > 0 ? this.detail.currentLocationName : '(未知地点)')
                : '未放置')
            this.sceneLauncherItem($r('app.string.world_scene_launcher_current_character'), this.detail.displayName)
            this.sceneLauncherItem($r('app.string.world_scene_launcher_same_location_chars'), '待加载')

            Divider().color(ThemePalette.worldBorderColor(this.effectiveTheme)).margin({ top: 12, bottom: 8 })

            this.sceneLauncherAction($r('app.string.world_scene_launcher_view_scenes'), false,
              (): void => {
                this.openSceneManage();
              })
            this.sceneLauncherAction($r('app.string.world_scene_launcher_create_new_scene'), false,
              (): void => {
                this.openSceneManage();
              })

            Divider().color(ThemePalette.worldBorderColor(this.effectiveTheme)).margin({ top: 12, bottom: 8 })

            this.sceneLauncherAction($r('app.string.world_scene_launcher_solo_talk'), false,
              (): void => {
                this.handleSoloTalk();
              })
            this.sceneLauncherAction($r('app.string.world_scene_launcher_group_talk'), true, (): void => {})
            this.sceneLauncherAction($r('app.string.world_scene_launcher_select_participants'), true, (): void => {})
            this.sceneLauncherAction($r('app.string.world_scene_launcher_continue_last'), true, (): void => {})

            if (this.soloTalkError.length > 0) {
              Text(this.soloTalkError)
                .fontSize($r('app.float.world_font_caption'))
                .fontColor($r('app.color.world_error'))
                .width('100%')
                .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: this.navBarHeight + 16 })
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  sceneLauncherItem(label: ResourceStr, value: string): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .layoutWeight(1)
      Text(value)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  sceneLauncherAction(label: ResourceStr, disabled: boolean, action: () => void): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.world_font_body'))
        .fontColor(disabled
          ? ThemePalette.textTertiaryColor(this.effectiveTheme)
          : ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
      if (disabled) {
        Text($r('app.string.world_scene_launcher_coming_soon'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(3)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
      .enabled(!disabled)
      .onClick(action)
  }

  @Builder
  locationSelectSheet(): void {
    Scroll() {
      Column() {
        Text(this.locationSelectMode === 'adjust' ? '调整位置' : '放置到地点')
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 12, bottom: 8 })

        if (this.activeLocations.length === 0) {
          Text('没有可用地点')
            .fontSize($r('app.float.world_font_body'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 8, bottom: 16 })
        } else {
          ForEach(this.activeLocations, (loc: ActiveLocationOptionUiModel) => {
            Button(loc.name)
              .fontSize(14)
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .borderRadius(8)
              .height(40)
              .width('100%')
              .margin({ bottom: 8 })
              .enabled(!this.isOperating)
              .onClick(() => {
                if (this.locationSelectMode === 'adjust') {
                  this.handleAdjustLocation(loc.id);
                } else {
                  this.handlePlaceAtLocation(loc.id);
                }
              })
          }, (loc: ActiveLocationOptionUiModel) => loc.id)
        }

        Button($r('app.string.world_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .borderRadius(8)
          .height(40)
          .width('100%')
          .margin({ top: 8 })
          .onClick(() => {
            this.locationSelectVisible = false;
          })

        Column().width('100%').height(this.navBarHeight + 8)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  unplaceConfirmSheet(): void {
    Column() {
      Text('从地图撤下')
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ top: 12, bottom: 8 })

      Text('角色将从当前地点撤下,但仍保留在世界中。可随时重新放置。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ bottom: 16 })

      Row() {
        WorldSecondaryButton({
          label: $r('app.string.world_cancel'),
          fullWidth: true,
          onButtonClick: (): void => {
            this.unplaceConfirmVisible = false;
          }
        })
          .layoutWeight(1)
          .margin({ right: 8 })
        WorldPrimaryButton({
          label: '撤下',
          isEnabled: !this.isOperating,
          onButtonClick: (): void => {
            this.handleUnplaceCharacter();
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column().width('100%').height(this.navBarHeight + 8)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  travelDestinationSheet(): void {
    Scroll() {
      Column() {
        Text('前往')
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 12, bottom: 8 })

        if (this.travelOptions.length === 0) {
          Text('当前地点没有可通行的连接')
            .fontSize($r('app.float.world_font_body'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 8, bottom: 16 })
        } else {
          ForEach(this.travelOptions, (option: TravelOption) => {
            Row() {
              Column() {
                Text(option.targetLocationName)
                  .fontSize($r('app.float.world_font_body'))
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(option.directionLabel + (option.isBidirectional ? ' · 双向' : ' · 单向'))
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              WorldPrimaryButton({
                label: '前往',
                isEnabled: !this.isTravelling,
                onButtonClick: (): void => {
                  this.handleTravelCharacter(option.targetLocationId);
                }
              })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .alignItems(VerticalAlign.Center)
          }, (option: TravelOption) => option.edgeId)
        }

        Button($r('app.string.world_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .borderRadius(8)
          .height(40)
          .width('100%')
          .margin({ top: 8 })
          .onClick(() => {
            this.travelDestinationVisible = false;
          })

        Column().width('100%').height(this.navBarHeight + 8)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  removeFromWorldConfirmSheet(): void {
    Column() {
      Text('⚠')
        .fontSize(40)
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({ top: 8 })

      Text('从世界移除')
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 4 })

      Text('此操作将永久移除角色实例及其全部世界记忆。角色卡本身不会被删除。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .margin({ top: 8, bottom: 16 })

      Row() {
        WorldSecondaryButton({
          label: $r('app.string.world_cancel'),
          fullWidth: true,
          onButtonClick: (): void => {
            this.removeFromWorldConfirmVisible = false;
          }
        })
          .layoutWeight(1)
          .margin({ right: 8 })

        Button('确认移除')
          .fontSize($r('app.float.world_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.world_error'))
          .borderRadius($r('app.float.world_radius_button'))
          .height(40)
          .layoutWeight(1)
          .enabled(!this.isOperating)
          .onClick(() => { this.handleRemoveFromWorld(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column().width('100%').height(this.navBarHeight + 8)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Center)
  }

  private openCharacterMemory(instanceId: string, worldId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_WORLD_ID_KEY, worldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_MEMORY_CHARACTER_INSTANCE_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterMemoryPage' });
  }

  private openSceneManage(): void {
    if (this.detail === null) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.detail.worldId);
    this.sceneLauncherVisible = false;
    router.pushUrl({ url: 'pages/world/WorldSceneManagePage' });
  }

  /** 与该角色在当前地点开启 1:1 单人会话。 */
  private async handleSoloTalk(): Promise<void> {
    if (this.viewModel === null || this.detail === null) {
      return;
    }
    const detail: WorldCharacterInstanceDetailUiModel = this.detail;
    if (detail.currentLocationId.length === 0) {
      this.soloTalkError = '该角色尚未放置到地点,无法开始对话';
      return;
    }
    if (!detail.isActive) {
      this.soloTalkError = '该角色已撤下,无法开始对话';
      return;
    }
    this.soloTalkError = '';
    try {
      const launchService = AppServices.getWorldSceneLaunchService();
      const result = await launchService.launchSceneSession({
        worldId: detail.worldId,
        locationId: detail.currentLocationId,
        participantCharacterInstanceIds: [detail.instanceId]
      });
      this.sceneLauncherVisible = false;
      this.soloTalkError = '';
      AppStorage.setOrCreate<string>(PENDING_WORLD_SCENE_CHAT_ID_KEY, result.scene.id);
      AppStorage.setOrCreate<string>(PENDING_WORLD_SESSION_ID_KEY, result.session.id);
      this.triggerWorldDetailRefresh();
      router.pushUrl({ url: 'pages/world/WorldSceneChatPage' });
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      this.soloTalkError = msg.length > 0 ? msg : '启动对话失败,请重试';
    }
  }

  private openOriginalCharacterCard(characterId: string): void {
    AppStorage.setOrCreate<string>('characterEditId', characterId);
    router.pushUrl({ url: 'pages/CharacterEditPage' });
  }

  private async handleUnplaceCharacter(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.unplaceConfirmVisible = false;
    this.viewModel.clearError();
    const ok: boolean = await this.viewModel.unplaceCharacter();
    this.syncFromViewModel();
    if (ok) {
      this.triggerWorldDetailRefresh();
    }
  }

  private async handleTravelCharacter(targetLocationId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.travelDestinationVisible = false;
    this.viewModel.clearError();
    const ok: boolean = await this.viewModel.travelCharacter(targetLocationId);
    this.syncFromViewModel();
    if (ok) {
      this.triggerWorldDetailRefresh();
    }
  }

  private async handleAdjustLocation(targetLocationId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.locationSelectVisible = false;
    this.viewModel.clearError();
    const ok: boolean = await this.viewModel.adjustLocation(targetLocationId);
    this.syncFromViewModel();
    if (ok) {
      this.triggerWorldDetailRefresh();
    }
  }

  private async handlePlaceAtLocation(locationId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.locationSelectVisible = false;
    this.viewModel.clearError();
    const ok: boolean = await this.viewModel.placeAtLocation(locationId);
    this.syncFromViewModel();
    if (ok) {
      this.triggerWorldDetailRefresh();
    }
  }

  private async handleRemoveFromWorld(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.removeFromWorldConfirmVisible = false;
    this.viewModel.clearError();
    const ok: boolean = await this.viewModel.removeFromWorld();
    if (ok) {
      this.instanceRemoved = true;
      this.triggerWorldDetailRefresh();
      router.back();
    } else {
      this.syncFromViewModel();
    }
  }

  private triggerWorldDetailRefresh(): void {
    const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
  }
}
