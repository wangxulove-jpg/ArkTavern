/**
 * WorldCharacterManagePage 世界角色管理页(W-CONTROL-1A)
 *
 * 分为两个区域:
 * - 已加入世界:展示角色实例列表,可设置初始地点(未放置时)、启用/停用、移除
 * - 可加入角色:展示候选角色列表,可选择初始地点后加入
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
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_CHARACTER_MANAGE_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { CharacterImageView } from '../../components/CharacterImageView';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterManagePage';

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
  /** 当前页面绑定的 worldId(用于跳转移动页) */
  @State private currentWorldId: string = '';

  /** 当前正在选择初始地点的候选角色 ID */
  @State private selectingLocationForCandidate: string = '';
  /** 当前正在选择初始地点的实例 ID */
  @State private selectingLocationForInstance: string = '';
  /** 当前正在确认移除的实例 ID */
  @State private removingInstanceId: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 角色管理页刷新令牌:WorldCharacterMovePage 移动成功后递增,@Watch 触发 loadSnapshot */
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
    // aboutToDisappear 可能在 pushUrl 覆盖页面时触发并 dispose,
    // 返回页面时必须先 activate,否则 loadSnapshot 会被静默跳过,
    // 导致移动角色返回后角色管理页仍显示旧位置。
    this.viewModel.activate();
    await this.loadSnapshot();
  }

  /**
   * 角色管理页刷新令牌变化时触发:WorldCharacterMovePage 移动/强制移动成功后递增。
   * 比 onPageShow 更可靠,确保 router.back() 后即使 onPageShow 不触发也能刷新。
   */
  onManageRefreshTokenChange(): void {
    Logger.info(LOG_TAG, 'onManageRefreshTokenChange: token=' + this.manageRefreshToken);
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    // aboutToDisappear 可能在覆盖页面时 dispose,refresh 回调到达时先激活。
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
  }

  build(): void {
    Column() {
      this.headerArea();
      this.contentArea();
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_cancel'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText($r('app.string.world_back_to_list'))
        .onClick(() => {
          // 返回前递增世界详情刷新令牌,确保 WorldDetailPage 重新加载地点图。
          // WorldCharacterMovePage 移动成功后已递增过一次,但 @StorageProp 在
          // WorldDetailPage 不可见时可能未同步,@Watch 可能未触发。
          // 这里在返回前再递增一次,确保 WorldDetailPage 回到前台时收到刷新信号。
          this.triggerWorldDetailRefresh();
          router.back();
        })

      Text($r('app.string.world_character_manage_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
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
  errorView(): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.world_home_load_failed'),
        description: this.errorMessage.length > 0 ? this.errorMessage : '世界角色数据加载失败,请重试'
      })
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => { this.loadSnapshot(); })
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
        // 错误提示
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_12'),
              right: $r('app.float.app_spacing_12'),
              top: $r('app.float.app_spacing_8'),
              bottom: $r('app.float.app_spacing_8')
            })
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_sm'))
            .margin({ bottom: $r('app.float.app_spacing_12') })
        }

        // 1. 已加入世界
        this.joinedSection()

        // 2. 可加入角色
        this.candidateSection()

        Column().width('100%').height(120)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 0,
      bottom: 0
    })

    // 选择初始地点弹窗(候选角色)
    if (this.selectingLocationForCandidate.length > 0) {
      this.selectLocationForCandidateDialog();
    }
    // 选择初始地点弹窗(已加入实例)
    if (this.selectingLocationForInstance.length > 0) {
      this.selectLocationForInstanceDialog();
    }
    // 移除确认弹窗
    if (this.removingInstanceId.length > 0) {
      this.removeConfirmDialog();
    }
  }

  /** 已加入世界角色区 */
  @Builder
  joinedSection(): void {
    Column() {
      Text($r('app.string.world_character_added_section'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      if (this.instances.length === 0) {
        Text($r('app.string.world_character_none_added'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        ForEach(this.instances, (inst: WorldCharacterInstanceManageUiModel) => {
          this.instanceCard(inst)
        }, (inst: WorldCharacterInstanceManageUiModel) => inst.id)
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

  /** 单个已加入角色实例卡片 */
  @Builder
  instanceCard(inst: WorldCharacterInstanceManageUiModel): void {
    Column() {
      // 头像 + 名称 + 状态
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
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row() {
            // 启用/停用
            Text(inst.isActive
              ? $r('app.string.world_character_active')
              : $r('app.string.world_character_inactive'))
              .fontSize(10)
              .fontColor(inst.isActive
                ? $r('app.color.app_accent')
                : $r('app.color.app_text_tertiary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })

            // 角色卡缺失
            if (inst.characterCardMissing) {
              Text($r('app.string.world_character_card_missing'))
                .fontSize(10)
                .fontColor($r('app.color.app_danger'))
                .backgroundColor($r('app.color.app_surface_2'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ left: 4 })
            }

            // 位置信息
            Text(this.resolveLocationLabel(inst))
              .fontSize(10)
              .fontColor(inst.currentLocationId.length === 0
                ? $r('app.color.app_text_tertiary')
                : $r('app.color.app_text_secondary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 4 })
          }
          .margin({ top: 4 })
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 操作按钮
      Row() {
        // 设置初始地点(仅未放置时)
        if (inst.currentLocationId.length === 0 && !inst.characterCardMissing) {
          Button($r('app.string.world_character_set_location'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_accent'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_set_character_location'))
            .onClick(() => {
              this.selectingLocationForInstance = inst.id;
            })
        }

        // 移动角色(仅已放置时显示,进入移动页)
        if (inst.currentLocationId.length > 0) {
          Button($r('app.string.world_character_move'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_accent'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_character_move'))
            .onClick(() => {
              this.openCharacterMove(inst.id);
            })
        }

        // 启用/停用
        if (inst.isActive) {
          Button($r('app.string.world_character_deactivate'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_secondary'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_deactivate_character'))
            .onClick(() => {
              this.handleSetInstanceActive(inst.id, false);
            })
        } else {
          Button($r('app.string.world_character_activate'))
            .fontSize(12)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_accent'))
            .borderRadius(6)
            .height(32)
            .padding({ left: 10, right: 10 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_activate_character'))
            .onClick(() => {
              this.handleSetInstanceActive(inst.id, true);
            })
        }

        // 从世界移除(危险操作)
        Button($r('app.string.world_character_remove'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_danger'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 10, right: 10 })
          .enabled(!this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_remove_character_from_world'))
          .onClick(() => {
            this.removingInstanceId = inst.id;
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 可加入角色区 */
  @Builder
  candidateSection(): void {
    Column() {
      Text($r('app.string.world_character_available_section'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      if (this.candidates.length === 0) {
        Text($r('app.string.world_character_no_available'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        ForEach(this.candidates, (c: CandidateCharacterUiModel) => {
          this.candidateCard(c)
        }, (c: CandidateCharacterUiModel) => c.id)
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
    .margin({ top: $r('app.float.app_spacing_12') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 单个候选角色卡片 */
  @Builder
  candidateCard(c: CandidateCharacterUiModel): void {
    Column() {
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
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (c.description.length > 0) {
            Text(c.description)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })

        Button($r('app.string.world_character_add_to_world'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_accent'))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(!this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_add_character_to_world'))
          .onClick(() => {
            this.handleAddCandidate(c.id);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ top: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 候选角色选择初始地点弹窗 */
  @Builder
  selectLocationForCandidateDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_character_select_location'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 16 })

        // 暂不放置
        Button($r('app.string.world_character_no_location'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_text_secondary'))
          .borderRadius(8)
          .height(40)
          .width('100%')
          .margin({ bottom: 8 })
          .enabled(!this.isSaving)
          .onClick(() => {
            const candidateId: string = this.selectingLocationForCandidate;
            this.selectingLocationForCandidate = '';
            this.handleAddCandidateWithLocation(candidateId, '');
          })

        // Active 地点列表
        ForEach(this.activeLocations, (loc: ActiveLocationOptionUiModel) => {
          Button(loc.name)
            .fontSize(14)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_primary'))
            .borderRadius(8)
            .height(40)
            .width('100%')
            .margin({ bottom: 8 })
            .enabled(!this.isSaving)
            .onClick(() => {
              const candidateId: string = this.selectingLocationForCandidate;
              this.selectingLocationForCandidate = '';
              this.handleAddCandidateWithLocation(candidateId, loc.id);
            })
        }, (loc: ActiveLocationOptionUiModel) => loc.id)

        // 取消
        Button($r('app.string.world_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_text_secondary'))
          .borderRadius(8)
          .height(40)
          .width('100%')
          .margin({ top: 8 })
          .onClick(() => {
            this.selectingLocationForCandidate = '';
          })
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.selectingLocationForCandidate = '';
    })
  }

  /** 已加入实例选择初始地点弹窗 */
  @Builder
  selectLocationForInstanceDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_character_select_location'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 16 })

        // Active 地点列表
        ForEach(this.activeLocations, (loc: ActiveLocationOptionUiModel) => {
          Button(loc.name)
            .fontSize(14)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_primary'))
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

        // 取消
        Button($r('app.string.world_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_text_secondary'))
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
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.selectingLocationForInstance = '';
    })
  }

  /** 移除确认弹窗 */
  @Builder
  removeConfirmDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_character_remove'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 12 })

        Text($r('app.string.world_character_remove_confirm'))
          .fontSize(14)
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ bottom: 20 })

        Row() {
          Button($r('app.string.world_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              this.removingInstanceId = '';
            })

          Button($r('app.string.world_character_remove'))
            .fontSize(14)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .enabled(!this.isDeleting)
            .onClick(() => {
              const instanceId: string = this.removingInstanceId;
              this.removingInstanceId = '';
              this.handleRemoveInstance(instanceId);
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.removingInstanceId = '';
    })
  }

  /** 解析角色位置标签 */
  private resolveLocationLabel(inst: WorldCharacterInstanceManageUiModel): string {
    if (inst.currentLocationId.length === 0) {
      return '未放置';
    }
    return inst.currentLocationName.length > 0 ? inst.currentLocationName : '未知地点';
  }

  /** 候选角色加入按钮:打开选择初始地点弹窗 */
  private handleAddCandidate(characterId: string): void {
    if (this.activeLocations.length === 0) {
      // 无 Active 地点,直接以"暂不放置"加入
      this.handleAddCandidateWithLocation(characterId, '');
    } else {
      this.selectingLocationForCandidate = characterId;
    }
  }

  /** 候选角色带初始地点加入 */
  private async handleAddCandidateWithLocation(
    characterId: string,
    locationId: string
  ): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.clearError();
    }
    const ok: boolean = await this.viewModel.addCharacterToWorld(characterId, locationId);
    this.syncFromViewModel();
    if (ok && this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  /** 已加入实例设置初始地点 */
  private async handlePlaceCharacter(
    instanceId: string,
    locationId: string
  ): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.clearError();
    }
    await this.viewModel.placeCharacter(instanceId, locationId);
    this.syncFromViewModel();
    if (this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  /** 启用/停用实例 */
  private async handleSetInstanceActive(
    instanceId: string,
    active: boolean
  ): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.clearError();
    }
    await this.viewModel.setInstanceActive(instanceId, active);
    this.syncFromViewModel();
    if (this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  /** 从世界移除实例 */
  private async handleRemoveInstance(instanceId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.clearError();
    }
    await this.viewModel.removeCharacterFromWorld(instanceId);
    this.syncFromViewModel();
    if (this.errorMessage.length === 0) {
      this.triggerWorldDetailRefresh();
    }
  }

  /** 打开角色移动页(传 worldId + instanceId) */
  private openCharacterMove(instanceId: string): void {
    if (this.currentWorldId.length === 0 || instanceId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_WORLD_ID_KEY, this.currentWorldId);
    AppStorage.setOrCreate<string>(PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY, instanceId);
    router.pushUrl({ url: 'pages/world/WorldCharacterMovePage' });
  }

  /** 递增刷新令牌,通知 WorldDetailPage 重新加载 */
  private triggerWorldDetailRefresh(): void {
    const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
    AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
  }
}
