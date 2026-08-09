import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldMemoryEvidenceViewModel,
  EvidenceLoadState,
  EvidenceMessageUiModel,
  EvidenceSnapshotUiModel
} from '../../viewmodels/world/WorldMemoryEvidenceViewModel';
import {
  PENDING_WORLD_MEMORY_EVIDENCE_ID_KEY
} from '../../viewmodels/world/WorldUiModels';
import {
  WorldCharacterMemoryStatus,
  WorldCharacterMemoryType
} from '../../models/world/WorldCharacterMemory';
import { EmptyStateView } from '../../components/EmptyStateView';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldStatusChip } from '../../components/world/WorldStatusChip';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG: string = 'WorldMemoryEvidencePage';

@Entry
@Component
struct WorldMemoryEvidencePage {
  @State private viewModel: WorldMemoryEvidenceViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: EvidenceLoadState = EvidenceLoadState.Loading;
  @State private errorMessage: string = '';
  @State private headerMemoryId: string = '';
  @State private headerContent: string = '';
  @State private headerType: WorldCharacterMemoryType = WorldCharacterMemoryType.Episodic;
  @State private headerTypeLabel: string = '';
  @State private headerStatus: WorldCharacterMemoryStatus = WorldCharacterMemoryStatus.Active;
  @State private headerStatusLabel: string = '';
  @State private headerOwnerName: string = '';
  @State private sourceWorldName: string = '';
  @State private sourceLocationName: string = '';
  @State private sourceLocationMissing: boolean = false;
  @State private sourceSceneName: string = '';
  @State private sourceSceneMissing: boolean = false;
  @State private sourceSceneTime: string = '';
  @State private sourceTypeLabel: string = '';
  @State private messages: EvidenceMessageUiModel[] = [];
  @State private hasSourceData: boolean = false;
  @State private noSourceMessage: string = '';

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const memoryId: string = AppStorage.get<string>(PENDING_WORLD_MEMORY_EVIDENCE_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_MEMORY_EVIDENCE_ID_KEY, '');
      if (memoryId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: memoryId empty');
        this.isInitializing = false;
        this.loadState = EvidenceLoadState.NotFound;
        return;
      }
      this.viewModel = new WorldMemoryEvidenceViewModel(
        AppServices.getWorldCharacterMemoryRepository(),
        AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneMessageRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldRepository(),
        AppServices.getCharacterService()
      );
      this.isInitializing = false;
      await this.viewModel.loadEvidence(memoryId);
      this.syncFromViewModel();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = EvidenceLoadState.Error;
      this.errorMessage = '证据数据加载失败,请重试';
    }
  }

  async onPageShow(): Promise<void> {
    if (this.isInitializing || this.viewModel === null) {
      return;
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
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    const snapshot: EvidenceSnapshotUiModel | null = this.viewModel.snapshot;
    if (snapshot === null) {
      this.headerMemoryId = '';
      this.headerContent = '';
      this.headerType = WorldCharacterMemoryType.Episodic;
      this.headerTypeLabel = '';
      this.headerStatus = WorldCharacterMemoryStatus.Active;
      this.headerStatusLabel = '';
      this.headerOwnerName = '';
      this.sourceWorldName = '';
      this.sourceLocationName = '';
      this.sourceLocationMissing = false;
      this.sourceSceneName = '';
      this.sourceSceneMissing = false;
      this.sourceSceneTime = '';
      this.sourceTypeLabel = '';
      this.messages = [];
      this.hasSourceData = false;
      this.noSourceMessage = '';
      return;
    }
    this.headerMemoryId = snapshot.header.memoryId;
    this.headerContent = snapshot.header.memoryContent;
    this.headerType = snapshot.header.memoryType;
    this.headerTypeLabel = snapshot.header.memoryTypeLabel;
    this.headerStatus = snapshot.header.memoryStatus;
    this.headerStatusLabel = snapshot.header.memoryStatusLabel;
    this.headerOwnerName = snapshot.header.ownerDisplayName;
    this.sourceWorldName = snapshot.source.worldName;
    this.sourceLocationName = snapshot.source.locationName;
    this.sourceLocationMissing = snapshot.source.locationMissing;
    this.sourceSceneName = snapshot.source.sceneName;
    this.sourceSceneMissing = snapshot.source.sceneMissing;
    this.sourceSceneTime = snapshot.source.sceneStartedAtLabel;
    this.sourceTypeLabel = snapshot.source.sourceTypeLabel;
    this.messages = snapshot.messages;
    this.hasSourceData = snapshot.hasSourceData;
    this.noSourceMessage = snapshot.noSourceMessage;
  }

  build(): void {
    Column() {
      this.headerArea()
      if (this.isInitializing) {
        this.loadingView()
      } else if (this.loadState === EvidenceLoadState.Loading) {
        this.loadingView()
      } else if (this.loadState === EvidenceLoadState.NotFound) {
        this.notFoundView()
      } else if (this.loadState === EvidenceLoadState.Error) {
        this.errorView(this.errorMessage.length > 0 ? this.errorMessage : '证据数据加载失败,请重试')
      } else {
        this.contentView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  headerArea(): void {
    Row() {
      Button($r('app.string.world_home_back'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .height(36)
        .padding({ left: 0, right: 8 })
        .accessibilityText($r('app.string.world_home_back'))
        .onClick(() => {
          router.back();
        })

      Text('来源证据')
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
      EmptyStateView({ title: $r('app.string.world_memory_not_found'), description: '' })
      Button($r('app.string.world_home_back'))
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
  errorView(msg: string): void {
    Column() {
      EmptyStateView({ title: $r('app.string.world_memory_load_error'), description: msg })
      Button($r('app.string.world_home_reload'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => { this.reload(); })
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
        this.memorySummaryCard()
        this.sourceInformationSection()
        if (this.hasSourceData) {
          this.originalMessagesSection()
        } else {
          this.noSourceSection()
        }
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: this.navBarHeight + 16
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  @Builder
  memorySummaryCard(): void {
    WorldSurfaceCard() {
      Column() {
        Row() {
          Text(this.headerTypeLabel)
            .fontSize(11)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(3)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })

          Blank().layoutWeight(1)

          WorldStatusChip({
            label: this.headerStatusLabel,
            isActive: this.headerStatus === WorldCharacterMemoryStatus.Active
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.headerOwnerName)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 8 })

        Scroll() {
          Text(this.headerContent)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .margin({ top: 8 })
        .constraintSize({ maxHeight: 200 })
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .padding($r('app.float.app_spacing_12'))
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  sourceInformationSection(): void {
    Column() {
      WorldSectionHeader({ title: '来源信息' })

      Column() {
        this.sourceRow('世界', this.sourceWorldName.length > 0 ? this.sourceWorldName : '未记录')

        if (this.sourceLocationMissing) {
          this.sourceRow('地点', '地点已删除')
        } else {
          this.sourceRow('地点', this.sourceLocationName.length > 0 ? this.sourceLocationName : '未记录')
        }

        if (this.sourceSceneMissing) {
          this.sourceRow('场景', '场景已删除')
        } else {
          this.sourceRow('场景', this.sourceSceneName.length > 0 ? this.sourceSceneName : '未记录')
        }

        if (this.sourceSceneTime.length > 0) {
          this.sourceRow('时间', this.sourceSceneTime)
        }

        this.sourceRow('来源类型', this.sourceTypeLabel)
      }
      .width('100%')
      .padding($r('app.float.app_spacing_12'))
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
      .margin({ top: $r('app.float.app_spacing_8') })
    }
    .width('100%')
    .margin({ bottom: $r('app.float.app_spacing_12') })
  }

  @Builder
  sourceRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width(72)
        .flexShrink(0)

      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 6, bottom: 6 })
  }

  @Builder
  originalMessagesSection(): void {
    Column() {
      WorldSectionHeader({ title: '原始证据' })

      Column() {
        ForEach(this.messages, (msg: EvidenceMessageUiModel) => {
          this.messageCard(msg)
        }, (msg: EvidenceMessageUiModel) => msg.messageId)
      }
      .width('100%')
      .margin({ top: $r('app.float.app_spacing_8') })
    }
    .width('100%')
  }

  @Builder
  messageCard(msg: EvidenceMessageUiModel): void {
    Column() {
      Row() {
        Text('#' + msg.messageId.substring(0, 8))
          .fontSize(9)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))

        Blank().layoutWeight(1)

        Text(msg.sentAtLabel)
          .fontSize(9)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        this.speakerBadge(msg)

        Text(msg.visibilityLabel)
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ top: 6 })
      .alignItems(VerticalAlign.Center)

      if (msg.participantNames.length > 0) {
        Text(msg.participantNames.join(', '))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Text(msg.content)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)

      if (msg.status !== 'completed') {
        Row() {
          WorldStatusChip({
            label: msg.status,
            isActive: false
          })
        }
        .width('100%')
        .margin({ top: 4 })
      }

      if (msg.isOriginalEvidence) {
        Row() {
          Text('原始证据')
            .fontSize(10)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding($r('app.float.app_spacing_12'))
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .borderWidth(msg.isOriginalEvidence ? 1.5 : 1)
    .borderColor(msg.isOriginalEvidence
      ? ThemePalette.accentColor(this.effectiveTheme)
      : ThemePalette.surface2Color(this.effectiveTheme))
    .margin({ bottom: $r('app.float.app_spacing_8') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  speakerBadge(msg: EvidenceMessageUiModel): void {
    if (msg.speakerType === 'user') {
      Text('[玩家]')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius(3)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    } else if (msg.speakerType === 'character') {
      Text('[角色·' + msg.speakerName + ']')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(3)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    } else {
      Text('[旁白]')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(3)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
    }
  }

  @Builder
  noSourceSection(): void {
    Column() {
      WorldEmptyState({ title: this.noSourceMessage, description: '' })
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_8') })
  }

  private async reload(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const memoryId: string = this.headerMemoryId;
    if (memoryId.length === 0) {
      return;
    }
    try {
      await this.viewModel.loadEvidence(memoryId);
      this.syncFromViewModel();
    } catch (e) {
      Logger.error(LOG_TAG, 'reload failed: ' + (e as Error).message);
      this.loadState = EvidenceLoadState.Error;
      this.errorMessage = '证据数据加载失败';
    }
  }
}
