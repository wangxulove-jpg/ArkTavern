/**
 * WorldEdgeEditPage 世界地点连接编辑页(W-CONTROL-1B)
 *
 * 创建模式:edgeId 为空,调用 WorldStateService.createEdge
 * 编辑模式:edgeId 非空,加载真实连接,端点只读,支持:
 *   - 编辑方向标签和旅行描述(updateEdge)
 *   - 切换单向 / 双向(updateEdge,Service 重新执行冲突检查)
 *   - 切换启用 / 停用(updateEdge)
 *
 * 路由:通过 AppStorage
 *   PENDING_WORLD_ID_KEY 传 worldId
 *   PENDING_WORLD_EDGE_ID_KEY 传 edgeId(创建模式为空)
 *   PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY 传 fromLocationId(创建模式预填,可为空)
 * 写入成功后 router.back(),由上一页 onPageShow 重新加载。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldEdgeEditViewModel,
  WorldEdgeEditLoadState,
  WorldEdgeLocationOptionUiModel
} from '../../viewmodels/world/WorldEdgeEditViewModel';
import {
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_EDGE_ID_KEY,
  PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY
} from '../../viewmodels/world/WorldUiModels';
import { WorldStatus } from '../../models/world/World';
import { EmptyStateView } from '../../components/EmptyStateView';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG: string = 'WorldEdgeEditPage';

@Entry
@Component
struct WorldEdgeEditPage {
  @State private viewModel: WorldEdgeEditViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: WorldEdgeEditLoadState = WorldEdgeEditLoadState.Loading;
  @State private errorMessage: string = '';
  @State private isSaving: boolean = false;
  @State private isCreateMode: boolean = true;
  @State private worldStatus: WorldStatus = WorldStatus.Active;
  @State private fromLocationId: string = '';
  @State private toLocationId: string = '';
  @State private directionLabelInput: string = '';
  @State private travelDescriptionInput: string = '';
  @State private isBidirectional: boolean = false;
  @State private isEnabled: boolean = true;
  @State private locationOptions: WorldEdgeLocationOptionUiModel[] = [];
  /** 选择起点弹窗 */
  @State private showFromPicker: boolean = false;
  /** 选择终点弹窗 */
  @State private showToPicker: boolean = false;
  @State private fromLocationName: string = '';
  @State private toLocationName: string = '';
  @State private fromMissing: boolean = false;
  @State private toMissing: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      const edgeId: string = AppStorage.get<string>(PENDING_WORLD_EDGE_ID_KEY) ?? '';
      const fromLocationId: string = AppStorage.get<string>(PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ID_KEY, '');
      AppStorage.set<string>(PENDING_WORLD_EDGE_ID_KEY, '');
      AppStorage.set<string>(PENDING_WORLD_EDGE_FROM_LOCATION_ID_KEY, '');
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId empty');
        this.isInitializing = false;
        this.loadState = WorldEdgeEditLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldEdgeEditViewModel(
        AppServices.getWorldStateService(),
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldLocationEdgeRepository(),
        worldId,
        edgeId,
        fromLocationId
      );
      this.isCreateMode = this.viewModel.isCreateMode;
      this.isInitializing = false;
      await this.viewModel.loadForm();
      this.syncFromViewModel();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = WorldEdgeEditLoadState.Error;
      this.errorMessage = '连接数据加载失败,请重试';
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
    this.errorMessage = this.viewModel.errorMessage;
    this.isSaving = this.viewModel.isSaving;
    this.worldStatus = this.viewModel.worldStatus;
    this.fromLocationId = this.viewModel.fromLocationId;
    this.toLocationId = this.viewModel.toLocationId;
    this.directionLabelInput = this.viewModel.directionLabelInput;
    this.travelDescriptionInput = this.viewModel.travelDescriptionInput;
    this.isBidirectional = this.viewModel.isBidirectional;
    this.isEnabled = this.viewModel.isEnabled;
    this.locationOptions = this.viewModel.locationOptions;
    // 解析端点显示名称
    if (this.viewModel.fromEndpoint !== null) {
      this.fromLocationName = this.viewModel.fromEndpoint.name;
      this.fromMissing = this.viewModel.fromEndpoint.missing;
    } else {
      this.fromLocationName = this.resolveOptionName(this.fromLocationId);
      this.fromMissing = false;
    }
    if (this.viewModel.toEndpoint !== null) {
      this.toLocationName = this.viewModel.toEndpoint.name;
      this.toMissing = this.viewModel.toEndpoint.missing;
    } else {
      this.toLocationName = this.resolveOptionName(this.toLocationId);
      this.toMissing = false;
    }
  }

  /** 从候选列表解析地点名称(创建模式) */
  private resolveOptionName(locationId: string): string {
    if (locationId.length === 0) {
      return '';
    }
    for (let i: number = 0; i < this.locationOptions.length; i++) {
      if (this.locationOptions[i].id === locationId) {
        return this.locationOptions[i].name;
      }
    }
    return '';
  }

  build(): void {
    Column() {
      this.headerArea();
      this.contentArea();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_cancel'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText($r('app.string.world_back_to_list'))
        .onClick(() => {
          router.back();
        })

      Text(this.isCreateMode
        ? $r('app.string.world_edge_edit_title_create')
        : $r('app.string.world_edge_edit_title_edit'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
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
    if (this.isInitializing || this.loadState === WorldEdgeEditLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === WorldEdgeEditLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === WorldEdgeEditLoadState.Error) {
      this.errorView();
    } else {
      this.formView();
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
      EmptyStateView({ title: $r('app.string.world_detail_not_found'), description: '' })
      Button($r('app.string.world_back_to_list'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
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
        description: this.errorMessage.length > 0 ? this.errorMessage : '连接数据加载失败,请重试'
      })
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          if (this.viewModel !== null) {
            this.viewModel.loadForm().then(() => { this.syncFromViewModel(); });
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
        // 起点地点
        Text($r('app.string.world_edge_from_location_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 6 })

        Button(this.resolveFromButtonLabel())
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.fromMissing
            ? $r('app.color.app_danger')
            : (this.fromLocationId.length === 0
              ? ThemePalette.textTertiaryColor(this.effectiveTheme)
              : ThemePalette.textPrimaryColor(this.effectiveTheme)))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .width('100%')
          .padding({ left: 12, right: 12 })
          .enabled(this.isCreateMode
            && this.worldStatus !== WorldStatus.Archived
            && !this.isSaving)
          .accessibilityText($r('app.string.world_edge_select_from'))
          .onClick(() => {
            this.showFromPicker = true;
          })

        // 终点地点
        Text($r('app.string.world_edge_to_location_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 16, bottom: 6 })

        Button(this.resolveToButtonLabel())
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.toMissing
            ? $r('app.color.app_danger')
            : (this.toLocationId.length === 0
              ? ThemePalette.textTertiaryColor(this.effectiveTheme)
              : ThemePalette.textPrimaryColor(this.effectiveTheme)))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .width('100%')
          .padding({ left: 12, right: 12 })
          .enabled(this.isCreateMode
            && this.worldStatus !== WorldStatus.Archived
            && !this.isSaving)
          .accessibilityText($r('app.string.world_edge_select_to'))
          .onClick(() => {
            this.showToPicker = true;
          })

        // 连接类型:单向 / 双向
        Text($r('app.string.world_edge_bidirectional'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 16, bottom: 6 })

        Row() {
          Button($r('app.string.world_edge_unidirectional'))
            .fontSize($r('app.float.app_font_caption'))
            .backgroundColor(!this.isBidirectional
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(!this.isBidirectional
              ? $r('app.color.app_on_accent')
              : ThemePalette.textSecondaryColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .enabled(this.worldStatus !== WorldStatus.Archived && !this.isSaving)
            .onClick(() => {
              this.isBidirectional = false;
              if (this.viewModel !== null) {
                this.viewModel.isBidirectional = false;
                this.viewModel.clearError();
                this.errorMessage = '';
              }
            })

          Button($r('app.string.world_edge_bidirectional'))
            .fontSize($r('app.float.app_font_caption'))
            .backgroundColor(this.isBidirectional
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.isBidirectional
              ? $r('app.color.app_on_accent')
              : ThemePalette.textSecondaryColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(40)
            .layoutWeight(1)
            .margin({ left: 8 })
            .enabled(this.worldStatus !== WorldStatus.Archived && !this.isSaving)
            .onClick(() => {
              this.isBidirectional = true;
              if (this.viewModel !== null) {
                this.viewModel.isBidirectional = true;
                this.viewModel.clearError();
                this.errorMessage = '';
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 编辑模式:启用 / 停用切换
        if (!this.isCreateMode) {
          Text($r('app.string.model_settings_enabled'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 16, bottom: 6 })

          Row() {
            Button($r('app.string.world_edge_enable'))
              .fontSize($r('app.float.app_font_caption'))
              .backgroundColor(this.isEnabled
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(this.isEnabled
                ? $r('app.color.app_on_accent')
                : ThemePalette.textSecondaryColor(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .enabled(this.worldStatus !== WorldStatus.Archived && !this.isSaving)
              .onClick(() => {
                this.isEnabled = true;
                if (this.viewModel !== null) {
                  this.viewModel.isEnabled = true;
                  this.viewModel.clearError();
                  this.errorMessage = '';
                }
              })

            Button($r('app.string.world_edge_disable'))
              .fontSize($r('app.float.app_font_caption'))
              .backgroundColor(!this.isEnabled
                ? ThemePalette.textSecondaryColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(!this.isEnabled
                ? $r('app.color.app_on_accent')
                : ThemePalette.textSecondaryColor(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 8 })
              .enabled(this.worldStatus !== WorldStatus.Archived && !this.isSaving)
              .onClick(() => {
                this.isEnabled = false;
                if (this.viewModel !== null) {
                  this.viewModel.isEnabled = false;
                  this.viewModel.clearError();
                  this.errorMessage = '';
                }
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }

        // 方向标签
        Text($r('app.string.world_edge_direction_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 16, bottom: 6 })

        TextInput({ text: this.directionLabelInput, placeholder: $r('app.string.world_edge_direction_placeholder') })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .maxLength(this.viewModel !== null ? this.viewModel.getDirectionLabelMax() : 100)
          .enabled(this.worldStatus !== WorldStatus.Archived && !this.isSaving)
          .onChange((value: string) => {
            this.directionLabelInput = value;
            if (this.viewModel !== null) {
              this.viewModel.directionLabelInput = value;
              this.viewModel.clearError();
              this.errorMessage = '';
            }
          })

        // 旅行描述
        Text($r('app.string.world_edge_travel_label'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 16, bottom: 6 })

        TextArea({ text: this.travelDescriptionInput, placeholder: $r('app.string.world_edge_travel_placeholder') })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(96)
          .maxLength(this.viewModel !== null ? this.viewModel.getTravelDescriptionMax() : 2000)
          .enabled(this.worldStatus !== WorldStatus.Archived && !this.isSaving)
          .onChange((value: string) => {
            this.travelDescriptionInput = value;
            if (this.viewModel !== null) {
              this.viewModel.travelDescriptionInput = value;
              this.viewModel.clearError();
              this.errorMessage = '';
            }
          })

        // 归档世界提示
        if (this.worldStatus === WorldStatus.Archived) {
          Text('世界已归档,不能修改连接')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
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
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(48)
          .width('100%')
          .margin({ top: 20 })
          .enabled(!this.isSaving && this.worldStatus !== WorldStatus.Archived)
          .accessibilityText($r('app.string.world_save'))
          .onClick(() => {
            this.handleSave();
          })

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

    // 选择起点弹窗
    if (this.showFromPicker) {
      this.fromPickerDialog();
    }
    // 选择终点弹窗
    if (this.showToPicker) {
      this.toPickerDialog();
    }
  }

  @Builder
  fromPickerDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_edge_select_from'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ bottom: 16 })

        if (this.locationOptions.length === 0) {
          Text('当前世界没有 Active 地点')
            .fontSize(14)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })
        } else {
          ForEach(this.locationOptions, (loc: WorldEdgeLocationOptionUiModel) => {
            Button(loc.name)
              .fontSize(14)
              .backgroundColor(this.fromLocationId === loc.id
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(this.fromLocationId === loc.id
                ? $r('app.color.app_on_accent')
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
              .borderRadius(8)
              .height(40)
              .width('100%')
              .margin({ bottom: 8 })
              .enabled(!this.isSaving)
              .onClick(() => {
                this.fromLocationId = loc.id;
                this.fromLocationName = loc.name;
                this.fromMissing = false;
                if (this.viewModel !== null) {
                  this.viewModel.fromLocationId = loc.id;
                  this.viewModel.clearError();
                  this.errorMessage = '';
                }
                this.showFromPicker = false;
              })
          }, (loc: WorldEdgeLocationOptionUiModel) => loc.id)
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
            this.showFromPicker = false;
          })
      }
      .width('80%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showFromPicker = false;
    })
  }

  @Builder
  toPickerDialog(): void {
    Column() {
      Column() {
        Text($r('app.string.world_edge_select_to'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ bottom: 16 })

        if (this.locationOptions.length === 0) {
          Text('当前世界没有 Active 地点')
            .fontSize(14)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })
        } else {
          ForEach(this.locationOptions, (loc: WorldEdgeLocationOptionUiModel) => {
            Button(loc.name)
              .fontSize(14)
              .backgroundColor(this.toLocationId === loc.id
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(this.toLocationId === loc.id
                ? $r('app.color.app_on_accent')
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
              .borderRadius(8)
              .height(40)
              .width('100%')
              .margin({ bottom: 8 })
              .enabled(!this.isSaving && loc.id !== this.fromLocationId)
              .onClick(() => {
                this.toLocationId = loc.id;
                this.toLocationName = loc.name;
                this.toMissing = false;
                if (this.viewModel !== null) {
                  this.viewModel.toLocationId = loc.id;
                  this.viewModel.clearError();
                  this.errorMessage = '';
                }
                this.showToPicker = false;
              })
          }, (loc: WorldEdgeLocationOptionUiModel) => loc.id)
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
            this.showToPicker = false;
          })
      }
      .width('80%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showToPicker = false;
    })
  }

  /** 起点按钮显示文字 */
  private resolveFromButtonLabel(): string {
    if (this.fromMissing) {
      return '起点地点缺失';
    }
    if (this.fromLocationId.length === 0) {
      return '请选择起点地点';
    }
    return this.fromLocationName.length > 0 ? this.fromLocationName : '(未知地点)';
  }

  /** 终点按钮显示文字 */
  private resolveToButtonLabel(): string {
    if (this.toMissing) {
      return '终点地点缺失';
    }
    if (this.toLocationId.length === 0) {
      return '请选择终点地点';
    }
    return this.toLocationName.length > 0 ? this.toLocationName : '(未知地点)';
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
}
