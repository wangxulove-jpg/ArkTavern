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
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldBottomActionBar } from '../../components/world/WorldBottomActionBar';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';

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
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;

  /** 场景启动器 Sheet */
  @State private sceneLauncherVisible: boolean = false;
  /** 位置选择 dialog */
  @State private locationSelectVisible: boolean = false;
  /** 位置选择用途: 'place' | 'adjust' */
  @State private locationSelectMode: string = '';
  /** 从地图撤下确认 */
  @State private unplaceConfirmVisible: boolean = false;
  /** 从世界移除确认 */
  @State private removeFromWorldConfirmVisible: boolean = false;
  /** 实例已被移除(导航回退标记) */
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
  }

  build(): void {
    Column() {
      this.topNav()
      this.contentArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.sceneLauncherVisible, this.sceneLauncherSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        this.sceneLauncherVisible = false;
      }
    })
    .bindSheet(this.locationSelectVisible, this.locationSelectSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        this.locationSelectVisible = false;
      }
    })
    .bindSheet(this.unplaceConfirmVisible, this.unplaceConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        this.unplaceConfirmVisible = false;
      }
    })
    .bindSheet(this.removeFromWorldConfirmVisible, this.removeFromWorldConfirmSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        this.removeFromWorldConfirmVisible = false;
      }
    })
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

      Text($r('app.string.world_char_detail_title'))
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
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
      this.readyView(this.detail)
    }
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
  readyView(d: WorldCharacterInstanceDetailUiModel): void {
    Column() {
      Scroll() {
        Column() {
          this.headerCard(d)

          WorldSurfaceCard({}) {
            Column() {
              this.infoField($r('app.string.world_char_detail_world_identity'), '尚未建立')
              this.infoField($r('app.string.world_char_detail_current_status'),
                d.isActive ? '活跃 · 位于 ' + (d.currentLocationName.length > 0 ? d.currentLocationName : '未放置') : '已停用')
              this.infoField($r('app.string.world_char_detail_current_goal'), '尚未建立')
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_recent_activity') })
              Text(formatWorldTimestamp(d.updatedAt))
                .fontSize($r('app.float.world_font_caption'))
                .fontColor($r('app.color.world_text_secondary'))
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
                .fontColor($r('app.color.world_text_tertiary'))
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
                .fontColor($r('app.color.world_text_tertiary'))
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
                .fontColor($r('app.color.world_text_tertiary'))
                .margin({ top: 8 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          // 诊断区:世界实例 ID
          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_world_instance_id') })
              Text(d.instanceId.substring(d.instanceId.length - 16))
                .fontSize($r('app.float.world_font_micro'))
                .fontColor($r('app.color.world_text_tertiary'))
                .margin({ top: 4 })
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
          }

          // 原始角色卡入口
          WorldSurfaceCard({}) {
            Column() {
              WorldSectionHeader({ title: $r('app.string.world_char_detail_original_card') })
              if (d.characterCardMissing) {
                Text($r('app.string.world_character_card_missing'))
                  .fontSize($r('app.float.world_font_caption'))
                  .fontColor($r('app.color.world_error'))
                  .margin({ top: 8 })
              } else {
                Text(d.displayName)
                  .fontSize($r('app.float.world_font_body'))
                  .fontColor($r('app.color.world_gold'))
                  .margin({ top: 8 })
                  .onClick(() => {
                    this.openOriginalCharacterCard(d.characterId);
                  })
              }
            }
            .padding(14)
            .alignItems(HorizontalAlign.Start)
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

      this.bottomActionBar(d)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  headerCard(d: WorldCharacterInstanceDetailUiModel): void {
    WorldSurfaceCard({ elevated: true }) {
      Column() {
        Row() {
          CharacterImageView({
            imageUri: d.avatarUri,
            fallbackName: d.fallbackName,
            imgWidth: 64,
            imgHeight: 64,
            imgBorderRadius: 32,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })

          Column() {
            Text(d.displayName)
              .fontSize($r('app.float.world_font_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.world_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(d.worldName)
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_text_secondary'))
              .margin({ top: 2 })

            Row() {
              WorldStatusChip({
                label: d.isActive ? '活跃' : '已停用',
                isActive: d.isActive
              })
              if (d.currentLocationId.length > 0) {
                Text(d.currentLocationName.length > 0 ? d.currentLocationName : '(未知地点)')
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor(d.locationMissing
                    ? $r('app.color.world_error')
                    : $r('app.color.world_text_secondary'))
                  .backgroundColor($r('app.color.world_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .margin({ left: 6 })
              } else {
                Text('未放置')
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor($r('app.color.world_text_tertiary'))
                  .backgroundColor($r('app.color.world_surface_2'))
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
  infoField(label: ResourceStr, value: string): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_primary'))
      Text(value.length > 0 ? value : '—')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 4 })
    }
    .width('100%')
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  bottomActionBar(d: WorldCharacterInstanceDetailUiModel): void {
    WorldBottomActionBar({}) {
      Column() {
        Row() {
          WorldSecondaryButton({
            label: $r('app.string.world_char_detail_view_memory'),
            onButtonClick: (): void => {
              this.openCharacterMemory(d.instanceId, d.worldId);
            }
          })
            .layoutWeight(1)
            .margin({ right: 6 })

          if (d.currentLocationId.length > 0) {
            WorldSecondaryButton({
              label: '调整位置',
              isEnabled: !this.isOperating,
              onButtonClick: (): void => {
                this.locationSelectMode = 'adjust';
                this.locationSelectVisible = true;
              }
            })
              .layoutWeight(1)
              .margin({ right: 6 })
          } else {
            WorldSecondaryButton({
              label: '放置到地点',
              isEnabled: !this.isOperating && this.activeLocations.length > 0,
              onButtonClick: (): void => {
                this.locationSelectMode = 'place';
                this.locationSelectVisible = true;
              }
            })
              .layoutWeight(1)
              .margin({ right: 6 })
          }

          WorldPrimaryButton({
            label: $r('app.string.world_char_detail_start_conversation'),
            onButtonClick: (): void => {
              this.sceneLauncherVisible = true;
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          if (d.currentLocationId.length > 0) {
            WorldSecondaryButton({
              label: '从地图撤下',
              isEnabled: !this.isOperating,
              onButtonClick: (): void => {
                this.unplaceConfirmVisible = true;
              }
            })
              .layoutWeight(1)
              .margin({ right: 6 })
          }

          WorldSecondaryButton({
            label: '从世界移除',
            isEnabled: !this.isOperating,
            onButtonClick: (): void => {
              this.removeFromWorldConfirmVisible = true;
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
    }
  }

  @Builder
  sceneLauncherSheet(): void {
    Scroll() {
      Column() {
        Text($r('app.string.world_scene_launcher_title'))
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.world_text_primary'))
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

            Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })

            // 可用操作:查看现有场景 / 创建新场景
            this.sceneLauncherAction($r('app.string.world_scene_launcher_view_scenes'), false,
              (): void => {
                this.openSceneManage();
              })
            this.sceneLauncherAction($r('app.string.world_scene_launcher_create_new_scene'), false,
              (): void => {
                this.openSceneManage();
              })

            Divider().color($r('app.color.world_border')).margin({ top: 12, bottom: 8 })

            // 尚未实现的操作(禁用,标记"即将支持")
            this.sceneLauncherAction($r('app.string.world_scene_launcher_solo_talk'), true, (): void => {})
            this.sceneLauncherAction($r('app.string.world_scene_launcher_group_talk'), true, (): void => {})
            this.sceneLauncherAction($r('app.string.world_scene_launcher_select_participants'), true, (): void => {})
            this.sceneLauncherAction($r('app.string.world_scene_launcher_continue_last'), true, (): void => {})
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
        .fontColor($r('app.color.world_text_tertiary'))
        .layoutWeight(1)
      Text(value)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
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
          ? $r('app.color.world_text_tertiary')
          : $r('app.color.world_text_primary'))
        .layoutWeight(1)
      if (disabled) {
        Text($r('app.string.world_scene_launcher_coming_soon'))
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_2'))
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
          .fontColor($r('app.color.world_text_primary'))
          .width('100%')
          .padding({ top: 12, bottom: 8 })

        if (this.activeLocations.length === 0) {
          Text('没有可用地点')
            .fontSize($r('app.float.world_font_body'))
            .fontColor($r('app.color.world_text_tertiary'))
            .margin({ top: 8, bottom: 16 })
        } else {
          ForEach(this.activeLocations, (loc: ActiveLocationOptionUiModel) => {
            Button(loc.name)
              .fontSize(14)
              .backgroundColor($r('app.color.world_surface_2'))
              .fontColor($r('app.color.world_text_primary'))
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
          .fontColor($r('app.color.world_text_secondary'))
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
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .padding({ top: 12, bottom: 8 })

      Text('角色将从当前地点撤下,但仍保留在世界中。可随时重新放置。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
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
  removeFromWorldConfirmSheet(): void {
    Column() {
      Text('从世界移除')
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_error'))
        .width('100%')
        .padding({ top: 12, bottom: 8 })

      Text('此操作将永久移除角色实例及其全部世界记忆。角色卡本身不会被删除。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ bottom: 16 })

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
        WorldPrimaryButton({
          label: '移除',
          isEnabled: !this.isOperating,
          onButtonClick: (): void => {
            this.handleRemoveFromWorld();
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