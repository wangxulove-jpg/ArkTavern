/**
 * WorldEditPage 世界编辑页(W-CONTROL-1A)
 *
 * 创建模式:worldId 为空,调用 WorldStateService.createWorld
 * 编辑模式:worldId 非空,加载真实 World,支持:
 *   - 编辑名称和描述(updateWorld)
 *   - 归档 / 重新激活(setWorldArchived)
 *   - 硬删除(deleteWorld,二次确认)
 *
 * 路由:通过 AppStorage PENDING_WORLD_ID_KEY 传 worldId(创建模式为空)
 * 写入成功后 router.back(),由上一页 onPageShow 重新加载。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { WorldEditViewModel, WorldEditLoadState } from '../../viewmodels/world/WorldEditViewModel';
import { PENDING_WORLD_ID_KEY, WORLD_DETAIL_REFRESH_TOKEN_KEY } from '../../viewmodels/world/WorldUiModels';
import { WorldStatus } from '../../models/world/World';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldEditPage';

@Entry
@Component
struct WorldEditPage {
  @State private viewModel: WorldEditViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldEditLoadState = WorldEditLoadState.Loading;
  @State private nameInput: string = '';
  @State private descriptionInput: string = '';
  @State private currentStatus: WorldStatus = WorldStatus.Active;
  @State private isSaving: boolean = false;
  @State private isDeleting: boolean = false;
  @State private errorMessage: string = '';
  @State private showDeleteConfirm: boolean = false;
  @State private showArchiveConfirm: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      this.viewModel = new WorldEditViewModel(
        AppServices.getWorldStateService(),
        AppServices.getWorldRepository(),
        worldId
      );
      this.isInitializing = false;
      await this.viewModel.loadWorld();
      this.syncFromViewModel();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldEditLoadState.Error;
      this.errorMessage = '世界数据加载失败,请重试';
    }
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
    this.nameInput = this.viewModel.nameInput;
    this.descriptionInput = this.viewModel.descriptionInput;
    this.currentStatus = this.viewModel.currentStatus;
    this.isSaving = this.viewModel.isSaving;
    this.isDeleting = this.viewModel.isDeleting;
    this.errorMessage = this.viewModel.errorMessage;
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

      Text(this.viewModel !== null && this.viewModel.isCreateMode
        ? $r('app.string.world_edit_title_create')
        : $r('app.string.world_edit_title_edit'))
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
    if (this.isInitializing || this.loadState === WorldEditLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldEditLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldEditLoadState.Error) {
      this.errorView();
    } else {
      this.formView();
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
        description: this.errorMessage.length > 0 ? this.errorMessage : '世界数据加载失败,请重试'
      })
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          if (this.viewModel !== null) {
            this.viewModel.loadWorld().then(() => { this.syncFromViewModel(); });
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  formView(): void {
    Scroll() {
      Column() {
        // 名称
        Text($r('app.string.world_name_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ bottom: 6 })

        TextInput({ text: this.nameInput, placeholder: $r('app.string.world_name_placeholder') })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .maxLength(this.viewModel !== null ? this.viewModel.getNameMax() : 100)
          .onChange((value: string) => {
            this.nameInput = value;
            if (this.viewModel !== null) {
              this.viewModel.nameInput = value;
              this.viewModel.clearError();
              this.errorMessage = '';
            }
          })

        // 描述
        Text($r('app.string.world_desc_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .margin({ top: 16, bottom: 6 })

        TextArea({ text: this.descriptionInput, placeholder: $r('app.string.world_desc_placeholder') })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_1'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(120)
          .maxLength(this.viewModel !== null ? this.viewModel.getDescriptionMax() : 5000)
          .onChange((value: string) => {
            this.descriptionInput = value;
            if (this.viewModel !== null) {
              this.viewModel.descriptionInput = value;
              this.viewModel.clearError();
              this.errorMessage = '';
            }
          })

        // 状态标签(编辑模式)
        if (this.viewModel !== null && !this.viewModel.isCreateMode) {
          Row() {
            Text($r('app.string.world_status_active'))
              .fontSize(11)
              .fontColor(this.currentStatus === WorldStatus.Active
                ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(4)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          }
          .width('100%')
          .margin({ top: 12 })
        }

        // 错误提示
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .margin({ top: 12 })
        }

        // 保存按钮
        Button($r('app.string.world_save'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .width('100%')
          .margin({ top: 20 })
          .enabled(!this.isSaving && !this.isDeleting)
          .accessibilityText($r('app.string.world_save'))
          .onClick(() => {
            this.handleSave();
          })

        // 编辑模式:归档/激活/删除
        if (this.viewModel !== null && !this.viewModel.isCreateMode) {
          // 归档 / 重新激活
          if (this.currentStatus === WorldStatus.Active) {
            Button($r('app.string.world_archive'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_secondary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(44)
              .width('100%')
              .margin({ top: 12 })
              .enabled(!this.isSaving && !this.isDeleting)
              .accessibilityText($r('app.string.world_archive_world'))
              .onClick(() => {
                this.showArchiveConfirm = true;
              })
          } else {
            Button($r('app.string.world_activate'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_accent'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(44)
              .width('100%')
              .margin({ top: 12 })
              .enabled(!this.isSaving && !this.isDeleting)
              .accessibilityText($r('app.string.world_activate_world'))
              .onClick(() => {
                this.handleSetArchived(false);
              })
          }

          // 硬删除(危险操作)
          Button($r('app.string.world_delete'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .width('100%')
            .margin({ top: 12 })
            .enabled(!this.isSaving && !this.isDeleting)
            .accessibilityText($r('app.string.world_delete_world'))
            .onClick(() => {
              this.showDeleteConfirm = true;
            })
        }

        Column().width('100%').height(80)
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

    // 删除确认弹窗
    if (this.showDeleteConfirm) {
      this.deleteConfirmDialog();
    }
    // 归档确认弹窗
    if (this.showArchiveConfirm) {
      this.archiveConfirmDialog();
    }
  }

  @Builder
  deleteConfirmDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_confirm_delete'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 12 })

        Text($r('app.string.world_delete_confirm'))
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
              this.showDeleteConfirm = false;
            })

          Button($r('app.string.world_delete'))
            .fontSize(14)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .enabled(!this.isDeleting)
            .onClick(() => {
              this.showDeleteConfirm = false;
              this.handleDelete();
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
      this.showDeleteConfirm = false;
    })
  }

  @Builder
  archiveConfirmDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_archive'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ bottom: 12 })

        Text($r('app.string.world_archive_confirm'))
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
              this.showArchiveConfirm = false;
            })

          Button($r('app.string.world_archive'))
            .fontSize(14)
            .backgroundColor($r('app.color.app_accent'))
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .enabled(!this.isSaving)
            .onClick(() => {
              this.showArchiveConfirm = false;
              this.handleSetArchived(true);
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
      this.showArchiveConfirm = false;
    })
  }

  private async handleSave(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.save();
    this.syncFromViewModel();
    if (this.viewModel.saveSucceeded) {
      const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
      AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
      router.back();
    }
  }

  private async handleSetArchived(archived: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.setArchived(archived);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0) {
      const current: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
      AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, current + 1);
    }
  }

  private async handleDelete(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.deleteWorld();
    this.syncFromViewModel();
    if (this.viewModel.deleteSucceeded) {
      // 清理 PENDING_WORLD_ID 避免详情页重新加载已删除世界
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      router.back();
    }
  }
}
