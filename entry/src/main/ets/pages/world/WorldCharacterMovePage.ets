/**
 * WorldCharacterMovePage 世界角色移动页(W-CONTROL-1B)
 *
 * 职责:
 * - 显示角色当前位置
 * - 显示正常可达地点(存在启用边、目标 Active、非当前位置)
 * - 执行正常移动(WorldStateService.moveCharacter)
 * - 提供主持者强制移动入口(WorldStateService.forceMoveCharacter)
 *
 * 路由:通过 AppStorage 传 worldId + characterInstanceId
 * 写入全部调用 WorldStateService。
 *
 * 归档世界:正常移动与强制移动按钮全部禁用,但仍可只读查看。
 * Inactive 实例:正常移动禁用,强制移动可用。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldCharacterMoveViewModel,
  WorldCharacterMoveLoadState,
  WorldCharacterMoveSnapshotUiModel,
  NormalMoveOptionUiModel,
  ForceMoveOptionUiModel
} from '../../viewmodels/world/WorldCharacterMoveViewModel';
import {
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  WORLD_CHARACTER_MANAGE_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { WorldStatus } from '../../models/world/World';
import { CharacterImageView } from '../../components/CharacterImageView';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCharacterMovePage';

/** 移动类型(用于确认弹窗) */
enum MoveDialogKind {
  None = '',
  Normal = 'normal',
  Force = 'force'
}

@Entry
@Component
struct WorldCharacterMovePage {
  @State private viewModel: WorldCharacterMoveViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldCharacterMoveLoadState = WorldCharacterMoveLoadState.Loading;
  @State private errorMessage: string = '';
  @State private snapshot: WorldCharacterMoveSnapshotUiModel | null = null;
  @State private isMoving: boolean = false;
  /** 当前正在确认的移动类型 */
  @State private moveDialogKind: MoveDialogKind = MoveDialogKind.None;
  /** 当前正在确认的目标地点 ID */
  @State private pendingTargetLocationId: string = '';
  /** 当前正在确认的目标地点名称 */
  @State private pendingTargetLocationName: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      const instanceId: string =
        AppStorage.get<string>(PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      AppStorage.set<string>(PENDING_WORLD_CHARACTER_INSTANCE_ID_KEY, '');
      if (worldId.length === 0 || instanceId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId or instanceId empty');
        this.isInitializing = false;
        this.loadState = WorldCharacterMoveLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldCharacterMoveViewModel(
        AppServices.getWorldStateService(),
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldLocationEdgeRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        worldId,
        instanceId
      );
      this.isInitializing = false;
      await this.loadSnapshot();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldCharacterMoveLoadState.Error;
      this.errorMessage = '角色移动数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    await this.loadSnapshot();
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
    this.snapshot = this.viewModel.snapshot;
    this.isMoving = this.viewModel.isMoving;
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
          router.back();
        })

      Text($r('app.string.world_character_move_title'))
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
    if (this.isInitializing || this.loadState === WorldCharacterMoveLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldCharacterMoveLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldCharacterMoveLoadState.Error) {
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
        description: this.errorMessage.length > 0 ? this.errorMessage : '角色移动数据加载失败,请重试'
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

        if (this.snapshot !== null) {
          this.characterCard(this.snapshot!)
          this.normalMoveSection(this.snapshot!)
          this.forceMoveSection(this.snapshot!)
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
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 0,
      bottom: 0
    })

    // 移动确认弹窗
    if (this.moveDialogKind !== MoveDialogKind.None) {
      this.moveConfirmDialog();
    }
  }

  /** 角色信息卡 */
  @Builder
  characterCard(snap: WorldCharacterMoveSnapshotUiModel): void {
    Column() {
      Row() {
        CharacterImageView({
          imageUri: snap.avatarUri,
          fallbackName: snap.fallbackName,
          imgWidth: 48,
          imgHeight: 48,
          imgBorderRadius: 24,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })

        Column() {
          Text(snap.displayName)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row() {
            // 启用 / 停用
            Text(snap.isActive ? '活跃' : '已停用')
              .fontSize(10)
              .fontColor(snap.isActive
                ? $r('app.color.app_accent')
                : $r('app.color.app_text_tertiary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })

            // 归档世界
            if (snap.worldStatus === WorldStatus.Archived) {
              Text('世界已归档')
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .backgroundColor($r('app.color.app_surface_2'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ left: 4 })
            }
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

      // 当前位置
      Divider().color($r('app.color.app_divider')).margin({ top: 12, bottom: 8 })

      Row() {
        Text($r('app.string.world_character_current_location'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))

        Text(this.resolveCurrentLocationLabel(snap))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(snap.locationMissing
            ? $r('app.color.app_danger')
            : $r('app.color.app_text_primary'))
          .margin({ left: 8 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // Inactive 提示
      if (!snap.isActive) {
        Text($r('app.string.world_character_move_inactive_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 8 })
          .width('100%')
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

  /** 正常移动区 */
  @Builder
  normalMoveSection(snap: WorldCharacterMoveSnapshotUiModel): void {
    Column() {
      Text($r('app.string.world_character_normal_move'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      // 不可正常移动的提示
      if (!this.canNormalMove(snap)) {
        Text($r('app.string.world_character_move_no_path'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else if (snap.normalMoveOptions.length === 0) {
        Text($r('app.string.world_character_move_no_path'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        ForEach(snap.normalMoveOptions, (opt: NormalMoveOptionUiModel) => {
          this.normalMoveOptionRow(opt, snap)
        }, (opt: NormalMoveOptionUiModel) => opt.viaEdgeId + '|' + opt.targetLocationId)
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

  /** 正常移动候选行 */
  @Builder
  normalMoveOptionRow(opt: NormalMoveOptionUiModel, snap: WorldCharacterMoveSnapshotUiModel): void {
    Column() {
      Row() {
        Column() {
          Text(opt.targetLocationName)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // 连接类型 + 方向标签
          Row() {
            Text(opt.isBidirectional
              ? $r('app.string.world_edge_bidirectional')
              : $r('app.string.world_edge_unidirectional'))
              .fontSize(10)
              .fontColor($r('app.color.app_accent'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })

            if (opt.directionLabel.length > 0) {
              Text(opt.directionLabel)
                .fontSize(10)
                .fontColor($r('app.color.app_text_tertiary'))
                .backgroundColor($r('app.color.app_surface_2'))
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ left: 4 })
            }
          }
          .margin({ top: 4 })
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 移动按钮
        Button($r('app.string.world_character_move'))
          .fontSize(12)
          .backgroundColor($r('app.color.app_accent'))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(6)
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(this.canMoveNow(snap))
          .accessibilityText($r('app.string.world_confirm_normal_move'))
          .onClick(() => {
            this.openMoveConfirm(opt.targetLocationId, opt.targetLocationName, MoveDialogKind.Normal);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 旅行描述
      if (opt.travelDescription.length > 0) {
        Text($r('app.string.world_character_move_via_edge') + ' · ' + opt.travelDescription)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }
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

  /** 强制移动区 */
  @Builder
  forceMoveSection(snap: WorldCharacterMoveSnapshotUiModel): void {
    Column() {
      Text($r('app.string.world_character_force_move'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 4 })

      Text($r('app.string.world_character_move_force_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      if (snap.forceMoveOptions.length === 0) {
        Text('当前世界没有其他可用地点')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_16')
          })
      } else {
        ForEach(snap.forceMoveOptions, (opt: ForceMoveOptionUiModel) => {
          this.forceMoveOptionRow(opt, snap)
        }, (opt: ForceMoveOptionUiModel) => opt.targetLocationId)
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

  /** 强制移动候选行 */
  @Builder
  forceMoveOptionRow(opt: ForceMoveOptionUiModel, snap: WorldCharacterMoveSnapshotUiModel): void {
    Row() {
      Text(opt.targetLocationName)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Button($r('app.string.world_force_move_character'))
        .fontSize(12)
        .backgroundColor($r('app.color.app_surface_2'))
        .fontColor(this.canForceMoveNow(snap)
          ? $r('app.color.app_danger')
          : $r('app.color.app_text_tertiary'))
        .borderRadius(6)
        .height(32)
        .padding({ left: 12, right: 12 })
        .enabled(this.canForceMoveNow(snap))
        .accessibilityText($r('app.string.world_confirm_force_move'))
        .onClick(() => {
          this.openMoveConfirm(opt.targetLocationId, opt.targetLocationName, MoveDialogKind.Force);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_2'))
    .borderRadius($r('app.float.app_radius_sm'))
    .margin({ top: $r('app.float.app_spacing_8') })
  }

  /** 移动确认弹窗(区分普通 / 强制) */
  @Builder
  moveConfirmDialog(): void {
    Column() {
      Column() {
        Text(this.moveDialogKind === MoveDialogKind.Force
          ? $r('app.string.world_character_force_move')
          : $r('app.string.world_character_normal_move'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 12 })

        Text(this.composeConfirmMessage())
          .fontSize(14)
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ bottom: 20 })
          .width('100%')

        Row() {
          Button($r('app.string.world_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              this.closeMoveConfirm();
            })

          Button(this.moveDialogKind === MoveDialogKind.Force
            ? $r('app.string.world_confirm_force_move')
            : $r('app.string.world_confirm_normal_move'))
            .fontSize(14)
            .backgroundColor(this.moveDialogKind === MoveDialogKind.Force
              ? $r('app.color.app_danger') : $r('app.color.app_accent'))
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .enabled(!this.isMoving)
            .onClick(() => {
              this.handleMoveConfirmed();
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
      this.closeMoveConfirm();
    })
  }

  // ===== 状态判定 =====

  /** 是否允许正常移动(实例 Active + 世界 Active + 已放置) */
  private canNormalMove(snap: WorldCharacterMoveSnapshotUiModel): boolean {
    if (snap.worldStatus === WorldStatus.Archived) {
      return false;
    }
    if (!snap.isActive) {
      return false;
    }
    if (snap.currentLocationId.length === 0) {
      return false;
    }
    return true;
  }

  /** 是否允许强制移动(世界 Active 即可,实例可 Inactive) */
  private canForceMove(snap: WorldCharacterMoveSnapshotUiModel): boolean {
    if (snap.worldStatus === WorldStatus.Archived) {
      return false;
    }
    return true;
  }

  /** 是否在当前操作状态下允许点击正常移动 */
  private canMoveNow(snap: WorldCharacterMoveSnapshotUiModel): boolean {
    return this.canNormalMove(snap) && !this.isMoving;
  }

  /** 是否在当前操作状态下允许点击强制移动 */
  private canForceMoveNow(snap: WorldCharacterMoveSnapshotUiModel): boolean {
    return this.canForceMove(snap) && !this.isMoving;
  }

  /** 解析当前位置标签 */
  private resolveCurrentLocationLabel(snap: WorldCharacterMoveSnapshotUiModel): string {
    if (snap.currentLocationId.length === 0) {
      return '未放置';
    }
    if (snap.locationMissing) {
      return '地点数据缺失';
    }
    return snap.currentLocationName.length > 0 ? snap.currentLocationName : '未知地点';
  }

  /** 组合确认弹窗消息 */
  private composeConfirmMessage(): string {
    if (this.snapshot === null) {
      return '';
    }
    const src: string = this.resolveCurrentLocationLabel(this.snapshot!);
    const dst: string = this.pendingTargetLocationName.length > 0
      ? this.pendingTargetLocationName : '(未知地点)';
    if (this.moveDialogKind === MoveDialogKind.Force) {
      return '主持者将强制把角色从"' + src + '"移动到"' + dst + '"。';
    }
    return '将角色从"' + src + '"移动到"' + dst + '"。';
  }

  // ===== 事件处理 =====

  /** 打开移动确认弹窗 */
  private openMoveConfirm(
    targetLocationId: string,
    targetLocationName: string,
    kind: MoveDialogKind
  ): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.clearError();
    this.pendingTargetLocationId = targetLocationId;
    this.pendingTargetLocationName = targetLocationName;
    this.moveDialogKind = kind;
  }

  /** 关闭移动确认弹窗 */
  private closeMoveConfirm(): void {
    this.moveDialogKind = MoveDialogKind.None;
    this.pendingTargetLocationId = '';
    this.pendingTargetLocationName = '';
  }

  /** 确认移动后执行 */
  private async handleMoveConfirmed(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const targetId: string = this.pendingTargetLocationId;
    const kind: MoveDialogKind = this.moveDialogKind;
    this.closeMoveConfirm();
    if (targetId.length === 0) {
      return;
    }
    if (kind === MoveDialogKind.Force) {
      await this.viewModel.forceMoveCharacter(targetId);
    } else {
      await this.viewModel.moveCharacter(targetId);
    }
    this.syncFromViewModel();
    // 移动成功后递增刷新令牌并返回上一页
    if (this.errorMessage.length === 0) {
      const detailToken: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
      AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, detailToken + 1);
      const manageToken: number = AppStorage.get<number>(WORLD_CHARACTER_MANAGE_REFRESH_TOKEN_KEY) ?? 0;
      AppStorage.setOrCreate<number>(WORLD_CHARACTER_MANAGE_REFRESH_TOKEN_KEY, manageToken + 1);
      Logger.info(LOG_TAG, 'move success, tokens: detail=' + (detailToken + 1)
        + ' manage=' + (manageToken + 1));
      router.back();
    }
  }
}
