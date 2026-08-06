/**
 * WorldCharacterManagePage 世界角色管理页(W-UI-1B 重构)
 *
 * 重构:深色酒馆质感 + 搜索 + 筛选 + 分析预览入口 + 实例详情入口。
 * 候选角色点击"分析并加入"→ WorldCharacterAnalysisPreviewPage
 * 已加入角色点击"查看角色"→ WorldCharacterInstanceDetailPage
 * 保留所有管理操作(启用/停用/移除/移动/记忆/设置地点)
 *
 * 路由:通过 AppStorage PENDING_WORLD_ID_KEY 传 worldId
 * 所有写入调用 WorldStateService。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldCharacterManageViewModel,
  WorldCharacterManageLoadState,
  WorldCharacterInstanceManageUiModel,
  CandidateCharacterUiModel,
  ActiveLocationOptionUiModel
} from '../../viewmodels/world/WorldCharacterManageViewModel';
import {
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY,
  PENDING_WORLD_ANALYSIS_CHARACTER_ID_KEY,
  PENDING_WORLD_INSTANCE_DETAIL_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_CHARACTER_MANAGE_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { CharacterImageView } from '../../components/CharacterImageView';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterManagePage';

type ManageFilter = 'all' | 'not_joined' | 'joined';

@Entry
@Component
struct WorldCharacterManagePage {
  @State private viewModel: WorldCharacterManageViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldCharacterManageLoadState = WorldCharacterManageLoadState.Loading;
  @State private errorMessage: string = '';
  @State private instances: WorldCharacterInstanceManageUiModel[] = [];
  @State private candidates: CandidateCharacterUiModel[] = [];
  @State private activeLocations: ActiveLocationOptionUiModel[] = [];
  @State private isSaving: boolean = false;
  @State private isDeleting: boolean = false;
  @State private currentWorldId: string = '';

  @State private searchText: string = '';
  @State private currentFilter: ManageFilter = 'all';
  @State private filteredInstances: WorldCharacterInstanceManageUiModel[] = [];
  @State private filteredCandidates: CandidateCharacterUiModel[] = [];

  /** Set location dialog */
  @State private selectingLocationForInstance: string = '';
  /** Remove confirm */
  @State private removingInstanceId: string = '';

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  @StorageProp(WORLD_CHARACTER_MANAGE_REFRESH_TOKEN_KEY) @Watch('onManageRefreshTokenChange')
  manageRefreshToken: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId empty');
        this.isInitializing = false;
        this.loadState = WorldCharacterManageLoadState.NotFound;
        return;
      }
      this.currentWorldId = worldId;
      AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, worldId);
      this.viewModel = new WorldCharacterManageViewModel(
        AppServices.getWorldStateService(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getCharacterService(),
        worldId
      );
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldCharacterManageLoadState.Error;
      this.errorMessage = '世界角色数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    this.viewModel.activate();
    await this.loadSnapshot();
  }

  onManageRefreshTokenChange(): void {
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
    await this.viewModel.loadSnapshot();
    this.syncFromViewModel();
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.loadState;
    this.errorMessage = this.viewModel.errorMessage;
    this.instances = this.viewModel.instances;
    this.candidates = this.viewModel.candidates;
    this.activeLocations = this.viewModel.activeLocations;
    this.isSaving = this.viewModel.isSaving;
    this.isDeleting = this.viewModel.isDeleting;
    this.updateFilteredLists();
  }

  private updateFilteredLists(): void {
    let insts: WorldCharacterInstanceManageUiModel[] = this.instances;
    let cands: CandidateCharacterUiModel[] = this.candidates;
    if (this.searchText.length > 0) {
      const q: string = this.searchText;
      insts = insts.filter((w: WorldCharacterInstanceManageUiModel): boolean => w.displayName.includes(q));
      cands = cands.filter((c: CandidateCharacterUiModel): boolean => c.name.includes(q));
    }
    if (this.currentFilter === 'joined') {
      cands = [];
    } else if (this.currentFilter === 'not_joined') {
      insts = [];
    }
    this.filteredInstances = insts;
    this.filteredCandidates = cands;
  }

  build(): void {
    Column() {
      this.topNav()
      this.searchAndFilterArea()
      this.contentArea()
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
          this.triggerWorldDetailRefresh();
          router.back();
        })

      Text($r('app.string.world_character_manage_title'))
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
  searchAndFilterArea(): void {
    Column() {
      Row() {
        TextInput({
          text: this.searchText,
          placeholder: $r('app.string.world_char_manage_search_placeholder')
        })
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_primary'))
          .placeholderColor($r('app.color.world_text_tertiary'))
          .backgroundColor($r('app.color.world_surface_1'))
          .borderRadius($r('app.float.world_radius_chip'))
          .height(40)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchText = value;
            this.updateFilteredLists();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: $r('app.float.world_card_spacing'),
        bottom: $r('app.float.world_card_spacing')
      })

      Row() {
        this.filterTab($r('app.string.world_char_manage_filter_all'), 'all')
        this.filterTab($r('app.string.world_char_manage_filter_not_joined'), 'not_joined')
        this.filterTab($r('app.string.world_char_manage_filter_joined'), 'joined')
      }
      .width('100%')
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        bottom: $r('app.float.world_card_spacing')
      })
    }
  }

  @Builder
  filterTab(label: ResourceStr, filter: ManageFilter): void {
    Text(label)
      .fontSize($r('app.float.world_font_caption'))
      .fontColor(this.currentFilter === filter
        ? $r('app.color.world_on_gold')
        : $r('app.color.world_text_secondary'))
      .backgroundColor(this.currentFilter === filter
        ? $r('app.color.world_gold')
        : $r('app.color.world_surface_1'))
      .borderRadius($r('app.float.world_radius_chip'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .margin({ right: 8 })
      .onClick(() => {
        this.currentFilter = filter;
        this.updateFilteredLists();
      })
  }

  @Builder
  contentArea(): void {
    if (this.isInitializing || this.loadState === WorldCharacterManageLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldCharacterManageLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldCharacterManageLoadState.Error) {
      this.errorView();
    } else {
      this.contentView();
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
  contentView(): void {
    Scroll() {
      Column() {
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .width('100%')
            .padding(10)
            .backgroundColor($r('app.color.world_surface_1'))
            .borderRadius($r('app.float.world_radius_chip'))
            .margin({ bottom: 12 })
        }

        // 已加入角色区
        if (this.currentFilter === 'all' || this.currentFilter === 'joined') {
          this.joinedSection()
        }

        // 可加入角色区
        if (this.currentFilter === 'all' || this.currentFilter === 'not_joined') {
          this.candidateSection()
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

    if (this.selectingLocationForInstance.length > 0) {
      this.selectLocationForInstanceDialog();
    }
    if (this.removingInstanceId.length > 0) {
      this.removeConfirmDialog();
    }
  }

  @Builder
  joinedSection(): void {
    Column() {
      WorldSectionHeader({
        title: $r('app.string.world_character_added_section'),
        subtitle: this.filteredInstances.length.toString() + ' 个角色'
      })

      if (this.filteredInstances.length === 0) {
        Text($r('app.string.world_character_none_added'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 16 })
      } else {
        ForEach(this.filteredInstances, (inst: WorldCharacterInstanceManageUiModel) => {
          this.instanceCard(inst)
        }, (inst: WorldCharacterInstanceManageUiModel) => inst.id)
      }
    }
    .padding(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  instanceCard(inst: WorldCharacterInstanceManageUiModel): void {
    WorldSurfaceCard({ elevated: true }) {
      Column() {
        Row() {
          CharacterImageView({
            imageUri: inst.avatarUri,
            fallbackName: inst.fallbackName,
            imgWidth: 40,
            imgHeight: 40,
            imgBorderRadius: 20,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })

          Column() {
            Text(inst.displayName)
              .fontSize($r('app.float.world_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.world_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Row() {
              WorldStatusChip({
                label: inst.isActive ? '活跃' : '已停用',
                isActive: inst.isActive
              })

              if (inst.characterCardMissing) {
                Text($r('app.string.world_character_card_missing'))
                  .fontSize($r('app.float.world_font_micro'))
                  .fontColor($r('app.color.world_error'))
                  .backgroundColor($r('app.color.world_surface_2'))
                  .borderRadius(3)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .margin({ left: 4 })
              }

              Text(this.resolveLocationLabel(inst))
                .fontSize($r('app.float.world_font_micro'))
                .fontColor(inst.currentLocationId.length === 0
                  ? $r('app.color.world_text_tertiary')
                  : $r('app.color.world_text_secondary'))
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
          .margin({ left: 12 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 操作按钮
        Row() {
          // 查看角色
          WorldPrimaryButton({
            label: $r('app.string.world_char_manage_view_character'),
            onButtonClick: (): void => {
              this.openInstanceDetail(inst.id);
            }
          })

          Blank().layoutWeight(1)

          // 设置初始地点(仅未放置时)
          if (inst.currentLocationId.length === 0 && !inst.characterCardMissing) {
            WorldSecondaryButton({
              label: $r('app.string.world_character_set_location'),
              isEnabled: !this.isSaving && !this.isDeleting,
              onButtonClick: (): void => {
                this.selectingLocationForInstance = inst.id;
              }
            })
              .margin({ left: 8 })
          }

          // 移动角色(仅已放置时)
          if (inst.currentLocationId.length > 0) {
            WorldSecondaryButton({
              label: $r('app.string.world_character_move'),
              isEnabled: !this.isSaving && !this.isDeleting,
              onButtonClick: (): void => {
                this.openCharacterMove(inst.id);
              }
            })
              .margin({ left: 8 })
          }

          // 启用/停用
          WorldSecondaryButton({
            label: inst.isActive
              ? $r('app.string.world_character_deactivate')
              : $r('app.string.world_character_activate'),
            isEnabled: !this.isSaving && !this.isDeleting,
            onButtonClick: (): void => {
              this.handleSetInstanceActive(inst.id, !inst.isActive);
            }
          })
            .margin({ left: 8 })

          // 移除
          WorldSecondaryButton({
            label: $r('app.string.world_character_remove'),
            isEnabled: !this.isSaving && !this.isDeleting,
            onButtonClick: (): void => {
              this.removingInstanceId = inst.id;
            }
          })
            .margin({ left: 8 })
        }
        .width('100%')
        .margin({ top: 10 })
        .alignItems(VerticalAlign.Center)
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  candidateSection(): void {
    Column() {
      WorldSectionHeader({
        title: $r('app.string.world_character_available_section'),
        subtitle: this.filteredCandidates.length.toString() + ' 个候选'
      })

      if (this.candidates.length === 0 && this.instances.length === 0) {
        // 全系统没有角色卡
        WorldEmptyState({
          title: $r('app.string.world_char_manage_no_character_cards'),
          description: $r('app.string.world_char_manage_create_character_hint'),
          primaryLabel: $r('app.string.world_char_manage_go_to_character_management'),
          onPrimary: (): void => {
            router.pushUrl({ url: 'pages/CharacterListPage' });
          }
        })
      } else if (this.filteredCandidates.length === 0) {
        Text($r('app.string.world_character_no_available'))
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 16 })
      } else {
        ForEach(this.filteredCandidates, (c: CandidateCharacterUiModel) => {
          this.candidateCard(c)
        }, (c: CandidateCharacterUiModel) => c.id)
      }
    }
    .padding(12)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  candidateCard(c: CandidateCharacterUiModel): void {
    WorldSurfaceCard({}) {
      Row() {
        CharacterImageView({
          imageUri: c.avatarUri,
          fallbackName: c.fallbackName,
          imgWidth: 40,
          imgHeight: 40,
          imgBorderRadius: 20,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })

        Column() {
          Text(c.name)
            .fontSize($r('app.float.world_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.world_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (c.description.length > 0) {
            Text(c.description)
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_text_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        WorldPrimaryButton({
          label: $r('app.string.world_char_manage_analyze_and_join'),
          isEnabled: !this.isSaving && !this.isDeleting,
          onButtonClick: (): void => {
            this.openAnalysisPreview(c.id);
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  selectLocationForInstanceDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_character_select_location'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.world_text_primary'))
          .margin({ bottom: 16 })

        ForEach(this.activeLocations, (loc: ActiveLocationOptionUiModel) => {
          Button(loc.name)
            .fontSize(14)
            .backgroundColor($r('app.color.world_surface_2'))
            .fontColor($r('app.color.world_text_primary'))
            .borderRadius(8)
            .height(40)
            .width('100%')
            .margin({ bottom: 8 })
            .enabled(!this.isSaving)
            .onClick(() => {
              const instanceId: string = this.selectingLocationForInstance;
              this.selectingLocationForInstance = '';
              this.handlePlaceCharacter(instanceId, loc.id);
            })
        }, (loc: ActiveLocationOptionUiModel) => loc.id)

        Button($r('app.string.world_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.world_text_secondary'))
          .borderRadius(8)
          .height(40)
          .width('100%')
          .margin({ top: 8 })
          .onClick(() => {
            this.selectingLocationForInstance = '';
          })
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('app.color.world_surface_elevated'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.world_scrim'))
    .onClick(() => {
      this.selectingLocationForInstance = '';
    })
  }

  @Builder
  removeConfirmDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_character_remove'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.world_text_primary'))
          .margin({ bottom: 12 })

        Text($r('app.string.world_character_remove_confirm'))
          .fontSize(14)
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ bottom: 20 })

        Row() {
          WorldSecondaryButton({
            label: $r('app.string.world_cancel'),
            fullWidth: true,
            onButtonClick: (): void => {
              this.removingInstanceId = '';
            }
          })
            .layoutWeight(1)

          WorldPrimaryButton({
            label: $r('app.string.world_character_remove'),
            isEnabled: !this.isDeleting,
            onButtonClick: (): void => {
              const instanceId: string = this.removingInstanceId;
              this.removingInstanceId = '';
              this.handleRemoveInstance(instanceId);
            }
          })
            .layoutWeight(1)
            .margin({ left: 12 })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('app.color.world_surface_elevated'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.world_scrim'))
    .onClick(() => {
      this.removingInstanceId = '';
    })
  }

  private resolveLocationLabel(inst: WorldCharacterInstanceManageUiModel): string {
    if (inst.currentLocationId.length === 0) {
      return '未放置';
    }
    return inst.currentLocationName.length > 0 ? inst.currentLocationName : '未知地点';
  }

  private openAnalysisPreview(characterId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_ANALYSIS_CHARACTER_ID_KEY, characterId);
    router.pushUrl({ url: 'pages/world/WorldCharacterAnalysisPreviewPage' });
  }

  private openInstanceDetail(instanceId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_INSTANCE_DETAIL_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterInstanceDetailPage' });
  }

  private async handlePlaceCharacter(instanceId: string, locationId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearError();
    await this.viewModel.placeCharacter(instanceId, locationId);
    this.syncFromViewModel();
    if (this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  private async handleSetInstanceActive(instanceId: string, active: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearError();
    await this.viewModel.setInstanceActive(instanceId, active);
    this.syncFromViewModel();
    if (this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  private async handleRemoveInstance(instanceId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearError();
    await this.viewModel.removeCharacterFromWorld(instanceId);
    this.syncFromViewModel();
    if (this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  private openCharacterMove(instanceId: string): void {
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterMovePage' });
  }

  private triggerWorldDetailRefresh(): void {
    const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
  }
}