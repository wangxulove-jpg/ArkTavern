import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  WorldCuratorViewModel,
  CuratorLoadState,
  CuratorTab,
  ConsistencyRiskLevel,
  CuratorSnapshotUiModel,
  CuratorSummaryUiModel,
  CuratorOverviewItemUiModel,
  ConsistencyIssueUiModel
} from '../../viewmodels/world/WorldCuratorViewModel';
import { PENDING_WORLD_CURATOR_WORLD_ID_KEY } from '../../viewmodels/world/WorldUiModels';
import { WorldSurfaceCard } from '../../components/world/WorldSurfaceCard';
import { WorldSectionHeader } from '../../components/world/WorldSectionHeader';
import { WorldEmptyState } from '../../components/world/WorldEmptyState';
import { WorldColors } from '../../components/world/WorldDesignTokens';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldCuratorPage';

@Entry
@Component
struct WorldCuratorPage {
  @State private viewModel: WorldCuratorViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private loadState: CuratorLoadState = CuratorLoadState.Loading;
  @State private errorMessage: string = '';
  @State private currentWorldId: string = '';
  @State private snapshot: CuratorSnapshotUiModel | null = null;
  @State private selectedTab: CuratorTab = CuratorTab.Overview;
  @State private ignoredIssueIds: string[] = [];
  @State private detailSheetIssueId: string = '';
  @State private detailSheetVisible: boolean = false;
  @State private detailSheetIssue: ConsistencyIssueUiModel | null = null;

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_CURATOR_WORLD_ID_KEY) ?? '';
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId empty');
        this.isInitializing = false;
        this.loadState = CuratorLoadState.NotFound;
        return;
      }
      AppStorage.set<string>(PENDING_WORLD_CURATOR_WORLD_ID_KEY, '');
      this.currentWorldId = worldId;

      this.viewModel = new WorldCuratorViewModel(
        AppServices.getWorldRepository(),
        AppServices.getWorldLocationRepository(),
        AppServices.getWorldCharacterInstanceRepository(),
        AppServices.getWorldSceneRepository(),
        AppServices.getWorldSceneMessageRepository(),
        AppServices.getWorldCharacterMemoryRepository(),
        AppServices.getWorldEventRepository(),
        AppServices.getCharacterService()
      );
      this.isInitializing = false;
      await this.loadSnapshot(worldId);
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
      this.loadState = CuratorLoadState.Error;
      this.errorMessage = '档案管理员数据加载失败';
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  private async loadSnapshot(worldId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.loadSnapshot(worldId);
    this.syncFromViewModel();
  }

  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.loadState = this.viewModel.state;
    this.errorMessage = this.viewModel.errorMessage;
    this.snapshot = this.viewModel.snapshot;
  }

  private resolveWorldName(): string {
    if (this.snapshot !== null) {
      return this.snapshot.summary.worldName;
    }
    return '';
  }

  private isIgnored(id: string): boolean {
    for (let i = 0; i < this.ignoredIssueIds.length; i++) {
      if (this.ignoredIssueIds[i] === id) {
        return true;
      }
    }
    return false;
  }

  private visibleIssues(): ConsistencyIssueUiModel[] {
    if (this.snapshot === null) {
      return [];
    }
    const result: ConsistencyIssueUiModel[] = [];
    for (let i = 0; i < this.snapshot.issues.length; i++) {
      if (!this.isIgnored(this.snapshot.issues[i].id)) {
        result.push(this.snapshot.issues[i]);
      }
    }
    return result;
  }

  private findIssueById(id: string): ConsistencyIssueUiModel | null {
    if (this.snapshot === null) {
      return null;
    }
    for (let i = 0; i < this.snapshot.issues.length; i++) {
      if (this.snapshot.issues[i].id === id) {
        return this.snapshot.issues[i];
      }
    }
    return null;
  }

  private riskColor(level: ConsistencyRiskLevel): string {
    if (level === ConsistencyRiskLevel.Critical) {
      return WorldColors.ERROR;
    }
    if (level === ConsistencyRiskLevel.Warning) {
      return WorldColors.WARNING;
    }
    if (level === ConsistencyRiskLevel.Notice) {
      return WorldColors.INFO;
    }
    return WorldColors.TEXT_TERTIARY;
  }

  private riskBgColor(level: ConsistencyRiskLevel): string {
    if (level === ConsistencyRiskLevel.Critical) {
      return '#3D2020';
    }
    if (level === ConsistencyRiskLevel.Warning) {
      return '#3D3220';
    }
    if (level === ConsistencyRiskLevel.Notice) {
      return '#1E2D3D';
    }
    return WorldColors.SURFACE_2;
  }

  private truncateId(id: string): string {
    if (id.length <= 12) {
      return id;
    }
    return id.substring(0, 6) + '...' + id.substring(id.length - 4);
  }

  build(): void {
    Column() {
      this.headerArea()
      this.bannerArea()
      this.contentArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.world_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.detailSheetVisible, this.issueDetailSheet, {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.world_surface_1'),
      onDisappear: () => {
        this.detailSheetVisible = false;
        this.detailSheetIssueId = '';
        this.detailSheetIssue = null;
      }
    })
  }

  @Builder
  headerArea(): void {
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

      Column() {
        Text('世界档案管理员')
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.world_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.resolveWorldName())
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
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
  bannerArea(): void {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(14)
          .fontColor([$r('app.color.world_warning')])
        Text('当前为规则检查模式')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_warning'))
          .fontWeight(FontWeight.Medium)
          .margin({ left: 6 })
      }
      .width('100%')

      Text('AI 档案管理员尚未接入')
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 4 })
        .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_card'))
    .borderWidth(1)
    .borderColor($r('app.color.world_warning'))
    .margin({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding'),
      top: 4,
      bottom: 8
    })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  contentArea(): void {
    if (this.isInitializing) {
      this.loadingView()
    } else if (this.loadState === CuratorLoadState.Loading) {
      this.loadingView()
    } else if (this.loadState === CuratorLoadState.NotFound) {
      this.notFoundView()
    } else if (this.loadState === CuratorLoadState.Error) {
      this.errorView()
    } else if (this.loadState === CuratorLoadState.Ready && this.snapshot !== null) {
      this.readyView(this.snapshot)
    }
  }

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.world_gold'))
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
        title: '世界不存在',
        primaryLabel: '返回',
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
        title: '加载失败',
        description: this.errorMessage.length > 0 ? this.errorMessage : '档案管理员数据加载失败',
        primaryLabel: '重试',
        secondaryLabel: '返回',
        onPrimary: (): void => {
          if (this.viewModel !== null && this.currentWorldId.length > 0) {
            this.loadSnapshot(this.currentWorldId);
          }
        },
        onSecondary: (): void => {
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
  readyView(snap: CuratorSnapshotUiModel): void {
    Column() {
      this.summaryBar(snap.summary)
      this.tabBar()
      this.tabContent(snap)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  summaryBar(summary: CuratorSummaryUiModel): void {
    Scroll() {
      Row() {
        this.summaryMetric('角色', summary.characterCount)
        this.summaryMetric('地点', summary.locationCount)
        this.summaryMetric('场景', summary.sceneCount)
        this.summaryMetric('记忆', summary.memoryCount)
        this.summaryMetric('待检', summary.pendingCheckCount)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding'),
      top: 8,
      bottom: 8
    })
    .backgroundColor($r('app.color.world_surface_1'))
    .borderWidth({ bottom: 1 })
    .borderColor($r('app.color.world_border'))
  }

  @Builder
  summaryMetric(label: string, count: number): void {
    Column() {
      Text(count.toString())
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(label === '待检' && count > 0
          ? $r('app.color.world_error')
          : $r('app.color.world_text_primary'))
      Text(label)
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .margin({ right: 20 })
  }

  @Builder
  tabBar(): void {
    Row() {
      this.tabItem('概览', CuratorTab.Overview)
      this.tabItem('一致性问题', CuratorTab.Issues)
      this.tabItem('修正建议', CuratorTab.Suggestions)
      this.tabItem('审计记录', CuratorTab.AuditLog)
    }
    .width('100%')
    .padding({
      left: $r('app.float.world_page_padding'),
      right: $r('app.float.world_page_padding')
    })
    .backgroundColor($r('app.color.world_bg'))
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  tabItem(label: string, tab: CuratorTab): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.world_font_body'))
        .fontColor(this.selectedTab === tab
          ? $r('app.color.world_gold')
          : $r('app.color.world_text_secondary'))
        .fontWeight(this.selectedTab === tab ? FontWeight.Medium : FontWeight.Normal)
        .padding({ top: 10, bottom: 8 })

      Divider()
        .width(this.selectedTab === tab ? 24 : 0)
        .height(2)
        .color($r('app.color.world_gold'))
        .borderRadius(1)
    }
    .margin({ right: 16 })
    .onClick(() => {
      this.selectedTab = tab;
    })
  }

  @Builder
  tabContent(snap: CuratorSnapshotUiModel): void {
    Scroll() {
      Column() {
        if (this.selectedTab === CuratorTab.Overview) {
          this.overviewTab(snap.overviewItems)
        } else if (this.selectedTab === CuratorTab.Issues) {
          this.issuesTab()
        } else if (this.selectedTab === CuratorTab.Suggestions) {
          this.suggestionsTab()
        } else {
          this.auditLogTab()
        }
        Column().width('100%').height(100)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: $r('app.float.world_page_padding'),
        right: $r('app.float.world_page_padding'),
        top: 12
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  overviewTab(items: CuratorOverviewItemUiModel[]): void {
    WorldSectionHeader({ title: '数据健康概览' })

    ForEach(items, (item: CuratorOverviewItemUiModel) => {
      this.overviewCard(item)
    }, (item: CuratorOverviewItemUiModel) => item.category)
  }

  @Builder
  overviewCard(item: CuratorOverviewItemUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        Text(item.category)
          .fontSize($r('app.float.world_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.world_text_primary'))
          .width('100%')

        Divider().color($r('app.color.world_border')).margin({ top: 8, bottom: 8 })

        Row() {
          this.overviewMetric('总数', item.total, $r('app.color.world_text_primary'))
          this.overviewMetric('有效', item.valid, $r('app.color.world_success'))
          this.overviewMetric('缺失引用', item.missingRef, $r('app.color.world_error'))
          this.overviewMetric('待检', item.pendingCheck, $r('app.color.world_warning'))
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  overviewMetric(label: string, value: number, color: ResourceColor): void {
    Column() {
      Text(value.toString())
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
      Text(label)
        .fontSize($r('app.float.world_font_micro'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
  }

  @Builder
  issuesTab(): void {
    WorldSectionHeader({
      title: '一致性问题',
      subtitle: this.visibleIssues().length.toString() + ' 项'
    })

    if (this.visibleIssues().length === 0) {
      Column() {
        Text('未发现一致性问题')
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ top: 24 })
        Text('所有数据引用完整,世界数据结构健康')
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_tertiary'))
          .margin({ top: 6 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 48, bottom: 48 })
    } else {
      ForEach(this.visibleIssues(), (issue: ConsistencyIssueUiModel) => {
        this.issueCard(issue)
      }, (issue: ConsistencyIssueUiModel) => issue.id + '|' + String(this.isIgnored(issue.id)))
    }
  }

  @Builder
  issueCard(issue: ConsistencyIssueUiModel): void {
    WorldSurfaceCard({}) {
      Column() {
        Row() {
          Text(issue.issueTypeLabel)
            .fontSize($r('app.float.world_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.world_text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(issue.riskLabel)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor(this.riskColor(issue.riskLevel))
            .backgroundColor(this.riskBgColor(issue.riskLevel))
            .borderRadius($r('app.float.world_radius_chip'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderWidth(1)
            .borderColor(this.riskColor(issue.riskLevel))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(issue.description)
          .fontSize($r('app.float.world_font_caption'))
          .fontColor($r('app.color.world_text_secondary'))
          .margin({ top: 8 })
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          if (issue.affectedCharacterName.length > 0) {
            Text('角色: ' + issue.affectedCharacterName)
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ right: 4 })
          }
          if (issue.affectedLocationName.length > 0) {
            Text('地点: ' + issue.affectedLocationName)
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ right: 4 })
          }
          if (issue.affectedSceneId.length > 0) {
            Text('场景: ' + this.truncateId(issue.affectedSceneId))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .backgroundColor($r('app.color.world_surface_2'))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)

        Divider().color($r('app.color.world_border')).margin({ top: 8, bottom: 6 })

        Row() {
          Text('记录: ' + this.truncateId(issue.affectedRecordId))
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .layoutWeight(1)

          Text(issue.checkMethod)
            .fontSize($r('app.float.world_font_micro'))
            .fontColor($r('app.color.world_text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Button('查看详情')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_gold'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .height(30)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.detailSheetIssueId = issue.id;
              this.detailSheetIssue = this.findIssueById(issue.id);
              this.detailSheetVisible = true;
            })

          Button('忽略')
            .fontSize($r('app.float.world_font_caption'))
            .fontColor($r('app.color.world_text_tertiary'))
            .backgroundColor($r('app.color.world_surface_2'))
            .borderRadius($r('app.float.world_radius_chip'))
            .height(30)
            .padding({ left: 10, right: 10 })
            .margin({ left: 8 })
            .onClick(() => {
              const updated: string[] = [...this.ignoredIssueIds, issue.id];
              this.ignoredIssueIds = updated;
            })
        }
        .width('100%')
        .margin({ top: 10 })
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  issueDetailSheet(): void {
    Column() {
      Row() {
        Text('问题详情')
          .fontSize($r('app.float.world_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.world_text_primary'))
          .layoutWeight(1)

        Button('×')
          .fontSize(18)
          .fontColor($r('app.color.world_text_secondary'))
          .backgroundColor(Color.Transparent)
          .width(32)
          .height(32)
          .padding(0)
          .align(Alignment.Center)
          .onClick(() => {
            this.detailSheetVisible = false;
            this.detailSheetIssueId = '';
            this.detailSheetIssue = null;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.detailSheetIssue !== null) {
        this.issueDetailContent(this.detailSheetIssue)
      } else {
        Text('问题不存在')
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_secondary'))
          .padding(24)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
  }

  @Builder
  issueDetailContent(issue: ConsistencyIssueUiModel): void {
    Scroll() {
      Column() {
        this.detailRow('问题类型', issue.issueTypeLabel)
        this.detailRow('风险等级', issue.riskLabel)
        this.detailRow('描述', issue.description)

        if (issue.affectedCharacterName.length > 0) {
          this.detailRow('涉及角色', issue.affectedCharacterName)
        }
        if (issue.affectedLocationName.length > 0) {
          this.detailRow('涉及地点', issue.affectedLocationName)
        }
        if (issue.affectedSceneId.length > 0) {
          this.detailRow('涉及场景', this.truncateId(issue.affectedSceneId))
        }

        this.detailRow('记录 ID', this.truncateId(issue.affectedRecordId))
        this.detailRow('检查方式', issue.checkMethod)
        this.detailRow('发现时间', issue.discoveredAtLabel)

        Column().width('100%').height(24)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
  }

  @Builder
  detailRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width(72)
        .flexShrink(0)
      Text(value)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_secondary'))
        .layoutWeight(1)
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ top: 8 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  suggestionsTab(): void {
    WorldSectionHeader({ title: '修正建议' })

    Column() {
      Text('尚无 AI 修正建议')
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.world_text_primary'))
        .textAlign(TextAlign.Center)

      Text('未来接入 Curator AI 后,将基于一致性问题自动生成修正建议。当前仅提供规则检查与问题展示。')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      this.skeletonCard()
      this.skeletonCard()
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 32, bottom: 32 })
  }

  @Builder
  skeletonCard(): void {
    Column() {
      Row() {
        Column()
          .width(120)
          .height(14)
          .borderRadius(4)
          .backgroundColor($r('app.color.world_surface_2'))
        Column()
          .width(48)
          .height(18)
          .borderRadius(8)
          .backgroundColor($r('app.color.world_surface_2'))
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column()
        .width('100%')
        .height(12)
        .borderRadius(4)
        .backgroundColor($r('app.color.world_surface_2'))
        .margin({ top: 8 })
      Column()
        .width('70%')
        .height(12)
        .borderRadius(4)
        .backgroundColor($r('app.color.world_surface_2'))
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius($r('app.float.world_radius_card'))
    .borderWidth(1)
    .borderColor($r('app.color.world_border'))
    .margin({ top: 8 })
    .opacity(0.5)
  }

  @Builder
  auditLogTab(): void {
    WorldSectionHeader({ title: '审计记录' })

    Column() {
      Text('尚未接入审计记录')
        .fontSize($r('app.float.world_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.world_text_primary'))
        .textAlign(TextAlign.Center)

      Text('未来审计记录将包含以下结构:')
        .fontSize($r('app.float.world_font_body'))
        .fontColor($r('app.color.world_text_secondary'))
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)

      Column() {
        this.auditFieldDescription('检查时间')
        this.auditFieldDescription('检查方式(规则检查 / AI 审计)')
        this.auditFieldDescription('问题数量')
        this.auditFieldDescription('处理数量')
        this.auditFieldDescription('操作者(用户 / AI)')
      }
      .width('100%')
      .margin({ top: 12 })
      .padding(14)
      .backgroundColor($r('app.color.world_surface_2'))
      .borderRadius($r('app.float.world_radius_card'))
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 32, bottom: 32 })
  }

  @Builder
  auditFieldDescription(field: string): void {
    Row() {
      SymbolGlyph($r('sys.symbol.circle'))
        .fontSize(8)
        .fontColor([$r('app.color.world_text_tertiary')])
      Text(field)
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .margin({ left: 6 })
    }
    .margin({ top: 4 })
    .alignItems(VerticalAlign.Center)
  }
}
