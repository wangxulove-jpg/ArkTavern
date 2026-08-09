/**
 * WorldCharacterAnalysisPreviewPage 角色分析预览页(W-UI-1B)
 *
 * 展示角色卡信息 + 确定性本地预览草案,用户确认后加入世界。
 * 不调用 ModelService / AI,不修改原 Character。
 *
 * 路由:通过 AppStorage 传入 PENDING_WORLD_ID_KEY + PENDING_WORLD_ANALYSIS_CHARACTER_ID_KEY
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { WorldCharacterAnalysisPreviewViewModel } from '../../viewmodels/world/WorldCharacterAnalysisPreviewViewModel';
import {
  CharacterAnalysisPreviewUiModel,
  CharacterPreviewLoadState,
  PENDING_WORLD_ID_KEY,
  PENDING_WORLD_ANALYSIS_CHARACTER_ID_KEY,
  WORLD_DETAIL_REFRESH_TOKEN_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldPrimaryButton } from '../../components/world/WorldPrimaryButton';
import { WorldSecondaryButton } from '../../components/world/WorldSecondaryButton';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { CharacterImageView } from '../../components/CharacterImageView';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG: string = 'WorldCharAnalysisPreviewPage';

@Entry
@Component
struct WorldCharacterAnalysisPreviewPage {
  @State private viewModel: WorldCharacterAnalysisPreviewViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: CharacterPreviewLoadState = CharacterPreviewLoadState.Loading;
  @State private errorMessage: string = '';
  @State private preview: CharacterAnalysisPreviewUiModel | null = null;
  @State private isJoining: boolean = false;
  @State private activeLocationIds: string[] = [];
  @State private activeLocationNames: string[] = [];
  @State private selectedLocationId: string = '';
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
      const characterId: string = AppStorage.get<string>(PENDING_WORLD_ANALYSIS_CHARACTER_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_ANALYSIS_CHARACTER_ID_KEY, '');
      if (worldId.length === 0 || characterId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: missing IDs');
        this.isInitializing = false;
        this.loadState = CharacterPreviewLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldCharacterAnalysisPreviewViewModel(
        AppServices.getCharacterService(),
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldStateService()
      );
      this.isInitializing = false;
      await this.viewModel.loadPreview(worldId, characterId);
      this.syncFromViewModel();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = CharacterPreviewLoadState.Error;
      this.errorMessage = '角色分析预览加载失败,请重试';
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
    this.preview = this.viewModel.preview;
    this.isJoining = this.viewModel.isJoining;
    this.activeLocationIds = this.viewModel.activeLocationIds;
    this.activeLocationNames = this.viewModel.activeLocationNames;
    this.selectedLocationId = this.viewModel.selectedLocationId;
  }

  build(): void {
    Column() {
      this.topNav();
      this.contentArea();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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

      Text($r('app.string.world_char_analysis_title'))
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
    if (this.isInitializing || this.loadState === CharacterPreviewLoadState.Loading) {
      this.loadingView();
    } else if (this.loadState === CharacterPreviewLoadState.NotFound) {
      this.notFoundView();
    } else if (this.loadState === CharacterPreviewLoadState.Error) {
      this.errorView();
    } else if (this.loadState === CharacterPreviewLoadState.Ready && this.preview !== null) {
      this.readyView(this.preview)
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
          if (this.viewModel !== null) {
            const worldId: string = AppStorage.get<string>(PENDING_WORLD_ID_KEY) ?? '';
            const characterId: string = this.preview !== null ? this.preview.characterId : '';
            if (worldId.length > 0 && characterId.length > 0) {
              this.viewModel.loadPreview(worldId, characterId).then((): void => {
                this.syncFromViewModel();
              });
            }
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
  readyView(p: CharacterAnalysisPreviewUiModel): void {
    Scroll() {
      Column() {
        // AI 未接入提示
        Row() {
          Text($r('app.string.world_char_analysis_ai_not_connected'))
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_warning'))
            .backgroundColor((this.effectiveTheme === 'tavern' ? '#3D3220' : $r('app.color.app_accent_surface')))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderWidth(1)
            .borderColor($r('app.color.world_warning'))
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 原始角色卡信息
        WorldSurfaceCard({}) {
          Column() {
            WorldSectionHeader({ title: $r('app.string.world_char_analysis_original_card') })

            Row() {
              CharacterImageView({
                imageUri: p.avatarUri,
                fallbackName: p.fallbackName,
                imgWidth: 56,
                imgHeight: 56,
                imgBorderRadius: 28,
                displayMode: 'thumbnail',
                objectFit: ImageFit.Cover
              })

              Column() {
                Text(p.characterName)
                  .fontSize($r('app.float.world_font_title'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                if (p.tags.length > 0) {
                  Text(p.tags.join(' · '))
                    .fontSize($r('app.float.world_font_micro'))
                    .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
              }
              .layoutWeight(1)
              .margin({ left: 12 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .margin({ top: 10 })

            if (p.description.length > 0) {
              Text(p.description)
                .fontSize($r('app.float.world_font_body'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .maxLines(6)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 10 })
                .width('100%')
            }
          }
          .padding(14)
          .alignItems(HorizontalAlign.Start)
        }

        // 世界实例草案
        WorldSurfaceCard({ elevated: true }) {
          Column() {
            WorldSectionHeader({ title: $r('app.string.world_char_analysis_world_draft') })

            this.infoField($r('app.string.world_char_analysis_suggested_identity'), p.suggestedWorldIdentity)

            // 地点选择
            Text($r('app.string.world_char_analysis_suggested_location'))
              .fontSize($r('app.float.world_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .margin({ top: 12 })
            if (this.activeLocationIds.length === 0) {
              Text($r('app.string.world_char_analysis_no_locations'))
                .fontSize($r('app.float.world_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ top: 4 })
            } else {
              Column() {
                // 暂不设置
                this.locationOption($r('app.string.world_char_analysis_no_location'),
                  '', this.selectedLocationId.length === 0)
                ForEach(this.activeLocationIds, (locId: string, idx: number) => {
                  this.locationOption(this.activeLocationNames[idx],
                    locId, this.selectedLocationId === locId)
                }, (locId: string) => locId)
              }
              .width('100%')
              .margin({ top: 6 })
            }

            this.infoField($r('app.string.world_char_analysis_icon_style'), p.iconStyle)
            this.infoField($r('app.string.world_char_analysis_initial_state'), p.initialState)
            this.infoField($r('app.string.world_char_analysis_initial_goal'), p.initialGoal)
          }
          .padding(14)
          .alignItems(HorizontalAlign.Start)
        }

        // 错误提示
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_error'))
            .width('100%')
            .padding(10)
            .backgroundColor(ThemePalette.worldSurfaceColor(this.effectiveTheme))
            .borderRadius($r('app.float.world_radius_chip'))
            .margin({ top: 12 })
        }

        // 底部确认按钮
        Row() {
          WorldSecondaryButton({
            label: $r('app.string.world_back_to_list'),
            fullWidth: true,
            onButtonClick: (): void => {
              router.back();
            }
          })
            .layoutWeight(1)
            .margin({ right: 12 })
          WorldPrimaryButton({
            label: $r('app.string.world_char_analysis_join_world'),
            fullWidth: true,
            isEnabled: !this.isJoining,
            onButtonClick: (): void => {
              this.handleJoinWorld();
            }
          })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 16, bottom: this.navBarHeight + 16 })
        .alignItems(VerticalAlign.Center)

        Column().width('100%').height(60)
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
  locationOption(label: ResourceStr, locId: string, isSelected: boolean): void {
    Text(label)
      .fontSize($r('app.float.world_font_body'))
      .fontColor(isSelected
        ? (this.effectiveTheme === 'tavern' ? '#1A1510' : $r('app.color.app_on_accent'))
        : ThemePalette.textPrimaryColor(this.effectiveTheme))
      .backgroundColor(isSelected
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.world_radius_chip'))
      .height(40)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ bottom: 6 })
      .onClick(() => {
        this.selectedLocationId = locId;
        if (this.viewModel !== null) {
          this.viewModel.selectedLocationId = locId;
        }
      })
  }

  private async handleJoinWorld(): Promise<void> {
    if (this.viewModel === null || this.isJoining) {
      return;
    }
    this.viewModel.clearError();
    const ok: boolean = await this.viewModel.confirmJoinWorld();
    this.syncFromViewModel();
    if (ok) {
      // 递增刷新令牌
      const token: number = AppStorage.get<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY) ?? 0;
      AppStorage.setOrCreate<number>(WORLD_DETAIL_REFRESH_TOKEN_KEY, token + 1);
      router.back();
    }
  }
}