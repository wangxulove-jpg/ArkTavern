import { router } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import {
  PENDING_WORLD_INSPECTOR_WORLD_ID_KEY,
  PENDING_WORLD_INSPECTOR_SCENE_ID_KEY,
  PENDING_WORLD_INSPECTOR_SESSION_ID_KEY,
  formatWorldTimestamp
} from '../../viewmodels/world/WorldUiModels';
import {
  WorldInspectorService,
  InspectorPipelineRun,
  InspectorSpeakerContext,
  InspectorSpeakerContextError,
  InspectorCharacterDossier,
  InspectorSessionInfo
} from '../../services/world/WorldInspectorService';
import {
  WorldSessionPostProcessRunStatus,
  WorldSessionPostProcessStepStatus,
  WorldSessionPostProcessResultCode,
  WorldSessionPostProcessState,
  WorldSessionPostProcessOwnerState,
  WorldSessionPostProcessRelationshipPairState
} from '../../models/world/WorldSessionPostProcessRun';
import {
  WorldCrossSessionContextSnapshot,
  WorldCrossSessionSummaryContextItem,
  WorldCrossSessionMemoryContextItem
} from '../../models/world/WorldCrossSessionContext';
import { WorldCharacterMemoryEntry } from '../../models/world/WorldCharacterMemoryEntry';
import { WorldKnownEventEntry } from '../../models/world/WorldKnownEventEntry';
import { WorldDirectionalRelationshipEntry } from '../../models/world/WorldDirectionalRelationshipEntry';
import { WorldEventEntry } from '../../models/world/WorldEventExtraction';
import { WorldSessionParticipantSnapshot } from '../../models/world/WorldConversationSession';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import { WorldColors, WorldMetrics } from '../../components/world/WorldDesignTokens';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldInspectorPage';

interface InspectorTabItem {
  tab: InspectorTab;
  label: string;
}

enum InspectorTab {
  Pipeline = 0,
  Context = 1,
  Dossier = 2
}

@Entry
@Component
struct WorldInspectorPage {
  @State private currentWorldId: string = '';
  @State private selectedTab: InspectorTab = InspectorTab.Pipeline;
  @State private isInitializing: boolean = true;

  @State private pipelineRuns: InspectorPipelineRun[] = [];
  @State private expandedRunIndex: number = -1;

  @State private activeSessionInfo: InspectorSessionInfo | null = null;
  @State private selectedSpeakerIndex: number = -1;
  @State private speakerContextResult: InspectorSpeakerContext | InspectorSpeakerContextError | null = null;
  @State private contextLoading: boolean = false;
  @State private contextIsError: boolean = false;
  @State private contextErrorCategory: string = '';

  @State private dossierInstances: WorldCharacterInstance[] = [];
  @State private selectedDossierIndex: number = -1;
  @State private dossierResult: InspectorCharacterDossier | null = null;
  @State private dossierLoading: boolean = false;
  @State private dossierEventEntries: WorldEventEntry[] = [];

  @State private expandedMemoryIndex: number = -1;
  @State private expandedRelationshipIndex: number = -1;
  @State private speakerSnapshot: WorldCrossSessionContextSnapshot | null = null;
  @State private speakerDisplayChars: number = 0;

  @State private tabItems: InspectorTabItem[] = [];

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navBarHeight: number = 0;

  private inspectorService: WorldInspectorService | null = null;
  private preselectSceneId: string = '';
  private preselectSessionId: string = '';

  async aboutToAppear(): Promise<void> {
    const tabs: InspectorTabItem[] = [
      { tab: InspectorTab.Pipeline, label: 'Pipeline' },
      { tab: InspectorTab.Context, label: 'Context' },
      { tab: InspectorTab.Dossier, label: 'Dossier' }
    ];
    this.tabItems = tabs;
    try {
      await AppServices.whenReady();
      const worldId: string = AppStorage.get<string>(PENDING_WORLD_INSPECTOR_WORLD_ID_KEY) ?? '';
      const sceneId: string = AppStorage.get<string>(PENDING_WORLD_INSPECTOR_SCENE_ID_KEY) ?? '';
      const sessionId: string = AppStorage.get<string>(PENDING_WORLD_INSPECTOR_SESSION_ID_KEY) ?? '';
      AppStorage.set<string>(PENDING_WORLD_INSPECTOR_WORLD_ID_KEY, '');
      AppStorage.set<string>(PENDING_WORLD_INSPECTOR_SCENE_ID_KEY, '');
      AppStorage.set<string>(PENDING_WORLD_INSPECTOR_SESSION_ID_KEY, '');
      if (worldId.length === 0) {
        Logger.warn(LOG_TAG, 'aboutToAppear: worldId empty');
        this.isInitializing = false;
        return;
      }
      this.currentWorldId = worldId;
      this.preselectSceneId = sceneId;
      this.preselectSessionId = sessionId;
      this.inspectorService = AppServices.getWorldInspectorService();

      await this.loadPipelineRuns();
      await this.loadActiveSession();
      await this.loadDossierInstances();
      this.isInitializing = false;
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
      this.isInitializing = false;
    }
  }

  private async loadPipelineRuns(): Promise<void> {
    if (this.inspectorService === null || this.currentWorldId.length === 0) {
      return;
    }
    try {
      this.pipelineRuns = await this.inspectorService.listRecentPipelineRuns(this.currentWorldId);
    } catch (_err) {
      this.pipelineRuns = [];
    }
  }

  private async loadActiveSession(): Promise<void> {
    if (this.inspectorService === null || this.currentWorldId.length === 0) {
      return;
    }
    try {
      if (this.preselectSessionId.length > 0) {
        const info: InspectorSessionInfo | null =
          await this.inspectorService.getSessionById(this.preselectSessionId);
        if (info !== null) {
          this.activeSessionInfo = info;
          return;
        }
      }
      if (this.preselectSceneId.length > 0) {
        const info: InspectorSessionInfo | null =
          await this.inspectorService.getActiveSessionForScene(this.currentWorldId, this.preselectSceneId);
        if (info !== null) {
          this.activeSessionInfo = info;
          return;
        }
      }
      this.activeSessionInfo = null;
    } catch (_err) {
      this.activeSessionInfo = null;
    }
  }

  private async loadDossierInstances(): Promise<void> {
    if (this.inspectorService === null || this.currentWorldId.length === 0) {
      return;
    }
    try {
      this.dossierInstances = await this.inspectorService.listWorldCharacterInstances(this.currentWorldId);
    } catch (_err) {
      this.dossierInstances = [];
    }
  }

  private async loadSpeakerContext(speakerId: string): Promise<void> {
    if (this.inspectorService === null || this.activeSessionInfo === null) {
      return;
    }
    this.contextLoading = true;
    this.speakerContextResult = null;
    this.contextIsError = false;
    this.contextErrorCategory = '';
    this.speakerSnapshot = null;
    this.speakerDisplayChars = 0;
    try {
      const result: InspectorSpeakerContext | InspectorSpeakerContextError =
        await this.inspectorService.prepareSpeakerContext(
          this.currentWorldId,
          this.activeSessionInfo.session.sceneId,
          this.activeSessionInfo.session.id,
          speakerId
        );
      this.speakerContextResult = result;
      const errResult: InspectorSpeakerContextError | null = this.asContextError(result);
      if (errResult !== null) {
        this.contextIsError = true;
        this.contextErrorCategory = errResult.errorCategory;
      } else {
        const ctx: InspectorSpeakerContext = result as InspectorSpeakerContext;
        this.speakerSnapshot = ctx.snapshot;
        this.speakerDisplayChars = ctx.totalDisplayChars;
      }
    } catch (_err) {
      this.speakerContextResult = null;
      this.contextIsError = true;
      this.contextErrorCategory = 'ContextUnavailable';
    }
    this.contextLoading = false;
  }

  private async loadDossier(instanceId: string): Promise<void> {
    if (this.inspectorService === null || this.currentWorldId.length === 0) {
      return;
    }
    this.dossierLoading = true;
    this.dossierResult = null;
    this.dossierEventEntries = [];
    try {
      const dossier: InspectorCharacterDossier | null =
        await this.inspectorService.getCharacterDossier(this.currentWorldId, instanceId);
      if (dossier !== null) {
        this.dossierResult = dossier;
        if (this.activeSessionInfo !== null) {
          this.dossierEventEntries = await this.inspectorService.listSessionEvents(
            this.currentWorldId, this.activeSessionInfo.session.id);
        }
      }
    } catch (_err) {
      this.dossierResult = null;
    }
    this.dossierLoading = false;
  }

  build(): void {
    Column() {
      this.topNavArea()
      if (this.isInitializing) {
        Column() {
          LoadingProgress().color(WorldColors.GOLD)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        this.tabBarArea()
        Column() {
          if (this.selectedTab === InspectorTab.Pipeline) {
            this.pipelineContent()
          } else if (this.selectedTab === InspectorTab.Context) {
            this.contextContent()
          } else {
            this.dossierContent()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(WorldColors.BG)
  }

  @Builder
  topNavArea(): void {
    Row() {
      Text('<')
        .fontSize(22)
        .fontColor(WorldColors.GOLD)
        .padding({ left: 16, right: 8 })
        .onClick((): void => {
          router.back();
        })
      Text('World Inspector')
        .fontSize(WorldMetrics.FONT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(WorldColors.TEXT_PRIMARY)
        .layoutWeight(1)
    }
    .width('100%')
    .height(WorldMetrics.TOP_NAV_HEIGHT + this.statusBarHeight)
    .padding({ top: this.statusBarHeight })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  tabBarArea(): void {
    Row() {
      ForEach(this.tabItems, (item: InspectorTabItem, index: number): void => {
        Text(item.label)
          .fontSize(WorldMetrics.FONT_BODY)
          .fontColor(this.selectedTab === item.tab ? WorldColors.GOLD : WorldColors.TEXT_SECONDARY)
          .fontWeight(this.selectedTab === item.tab ? FontWeight.Bold : FontWeight.Normal)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .onClick((): void => {
            this.selectedTab = item.tab;
          })
      }, (item: InspectorTabItem, index: number): string => {
        return index.toString();
      })
    }
    .width('100%')
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(8)
    .margin({ left: WorldMetrics.PAGE_PADDING, right: WorldMetrics.PAGE_PADDING, bottom: 8 })
  }

  @Builder
  pipelineContent(): void {
    Scroll() {
      Column() {
        if (this.pipelineRuns.length === 0) {
          Text('No Post-Process Run')
            .fontSize(WorldMetrics.FONT_BODY)
            .fontColor(WorldColors.TEXT_TERTIARY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(32)
        } else {
          ForEach(this.pipelineRuns, (item: InspectorPipelineRun, index: number): void => {
            this.pipelineRunCard(item, index)
          }, (item: InspectorPipelineRun, index: number): string => {
            return item.run.id;
          })
        }
      }
      .width('100%')
      .padding(WorldMetrics.PAGE_PADDING)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  pipelineRunCard(item: InspectorPipelineRun, index: number): void {
    Column() {
      Row() {
        Text(this.runStatusBadge(item.run.status))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(this.runStatusColor(item.run.status))
          .backgroundColor(this.runStatusBgColor(item.run.status))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        Text(formatWorldTimestamp(item.run.createdAt))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 8 })
        Text('v' + item.run.pipelineVersion)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 8 })
      }
      .width('100%')
      Row() {
        Text('session: ' + this.shortId(item.run.sessionId))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
          .layoutWeight(1)
        Text('rev=' + item.run.revision.toString() + ' attempts=' + item.run.attemptCount.toString())
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
      }
      .width('100%')
      .margin({ top: 4 })

      if (this.expandedRunIndex === index) {
        this.pipelineExpandedDetail(item)
      }

      Text(this.expandedRunIndex === index ? 'Collapse' : 'Expand')
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.GOLD)
        .margin({ top: 8 })
        .onClick((): void => {
          this.expandedRunIndex = this.expandedRunIndex === index ? -1 : index;
        })
    }
    .width('100%')
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
    .padding(12)
    .margin({ bottom: 8 })
  }

  @Builder
  pipelineExpandedDetail(item: InspectorPipelineRun): void {
    Column() {
      this.pipelineStepRow('Summary', item.state.summary.status, item.state.summary.resultCode, item.state.summary.errorKind)

      ForEach(item.state.memories, (mem: WorldSessionPostProcessOwnerState, memIndex: number): void => {
        this.pipelineStepRow('Memory ' + this.shortId(mem.ownerCharacterInstanceId), mem.status, mem.resultCode, mem.errorKind)
      }, (mem: WorldSessionPostProcessOwnerState, memIndex: number): string => {
        return mem.ownerCharacterInstanceId;
      })

      this.pipelineStepRow('Event', item.state.eventExtraction.status, item.state.eventExtraction.resultCode, item.state.eventExtraction.errorKind)
      this.pipelineStepRow('KnownEvent', item.state.knownEvents.status, item.state.knownEvents.resultCode, item.state.knownEvents.errorKind)

      ForEach(item.state.relationships, (rel: WorldSessionPostProcessRelationshipPairState, relIndex: number): void => {
        this.pipelineStepRow('Rel ' + this.shortId(rel.ownerCharacterInstanceId) + ' -> ' + this.shortId(rel.targetCharacterInstanceId), rel.status, rel.resultCode, rel.errorKind)
      }, (rel: WorldSessionPostProcessRelationshipPairState, relIndex: number): string => {
        return rel.ownerCharacterInstanceId + ':' + rel.targetCharacterInstanceId;
      })

      if (item.run.completedAt !== undefined) {
        Text('completed: ' + formatWorldTimestamp(item.run.completedAt))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .margin({ top: 8 })
    .padding({ left: 8, top: 8, bottom: 8 })
    .backgroundColor(WorldColors.SURFACE_2)
    .borderRadius(8)
  }

  @Builder
  pipelineStepRow(
    label: string,
    status: WorldSessionPostProcessStepStatus,
    resultCode: WorldSessionPostProcessResultCode | undefined,
    errorKind: string | undefined
  ): void {
    Row() {
      Text(label)
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.TEXT_SECONDARY)
        .layoutWeight(1)
      Text(this.stepStatusBadge(status))
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(this.stepStatusColor(status))
        .margin({ left: 4 })
      if (resultCode !== undefined) {
        Text(this.resultCodeBadge(resultCode))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
      }
      if (errorKind !== undefined) {
        Text('err:' + errorKind)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.ERROR)
          .margin({ left: 4 })
      }
    }
    .width('100%')
    .margin({ top: 4 })
  }

  @Builder
  contextContent(): void {
    Scroll() {
      Column() {
        if (this.activeSessionInfo === null) {
          Text('No active session available for runtime context inspection.')
            .fontSize(WorldMetrics.FONT_BODY)
            .fontColor(WorldColors.TEXT_TERTIARY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(32)
        } else {
          Text('Session: ' + this.shortId(this.activeSessionInfo.session.id) + ' (seq ' + this.activeSessionInfo.session.sequenceNumber.toString() + ')')
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_SECONDARY)
            .width('100%')
            .padding({ bottom: 8 })

          if (this.activeSessionInfo.participants.length === 0) {
            Text('No participants')
              .fontSize(WorldMetrics.FONT_CAPTION)
              .fontColor(WorldColors.TEXT_TERTIARY)
          } else {
            Text('Select Speaker:')
              .fontSize(WorldMetrics.FONT_CAPTION)
              .fontColor(WorldColors.TEXT_TERTIARY)
              .width('100%')
              .padding({ bottom: 4 })

            Scroll() {
              Row() {
                ForEach(this.activeSessionInfo.participants, (p: WorldSessionParticipantSnapshot, pi: number): void => {
                  Text(p.displayNameSnapshot)
                    .fontSize(WorldMetrics.FONT_CAPTION)
                    .fontColor(this.selectedSpeakerIndex === pi ? WorldColors.ON_GOLD : WorldColors.TEXT_PRIMARY)
                    .backgroundColor(this.selectedSpeakerIndex === pi ? WorldColors.GOLD : WorldColors.SURFACE_2)
                    .borderRadius(WorldMetrics.RADIUS_CHIP)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .margin({ right: 6 })
                    .onClick((): void => {
                      if (this.selectedSpeakerIndex !== pi) {
                        this.selectedSpeakerIndex = pi;
                        this.loadSpeakerContext(p.characterInstanceId);
                      }
                    })
                }, (p: WorldSessionParticipantSnapshot, pi: number): string => {
                  return p.characterInstanceId;
                })
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .width('100%')
            .margin({ bottom: 12 })
          }

          if (this.contextLoading) {
            LoadingProgress().color(WorldColors.GOLD).margin({ top: 16 })
          } else if (this.contextIsError) {
            this.contextErrorDetail()
          } else if (this.speakerContextResult !== null) {
            this.speakerContextDetail()
          }

          this.promptOrderHint()
        }
      }
      .width('100%')
      .padding(WorldMetrics.PAGE_PADDING)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  contextErrorDetail(): void {
    Row() {
      Text('ContextUnavailable')
        .fontSize(WorldMetrics.FONT_BODY)
        .fontColor(WorldColors.ERROR)
      Text(this.contextErrorCategory)
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.ERROR)
        .margin({ left: 8 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
  }

  @Builder
  speakerContextDetail(): void {
    Column() {
      Row() {
        Text('Summary: ' + (this.speakerSnapshot !== null ? this.speakerSnapshot.summaries.length.toString() : '0'))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
        Text('(omitted: ' + (this.speakerSnapshot !== null ? this.speakerSnapshot.omittedSummaryCount.toString() : '0') + ')')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 6 })
        Text('RUNTIME-INJECTED')
          .fontSize(10)
          .fontColor(WorldColors.SUCCESS)
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ top: 4 })

      if (this.speakerSnapshot !== null) {
        ForEach(this.speakerSnapshot.summaries as WorldCrossSessionSummaryContextItem[], (s: WorldCrossSessionSummaryContextItem, si: number): void => {
          this.contextSummaryItem(s)
        }, (s: WorldCrossSessionSummaryContextItem, si: number): string => {
          return s.summaryId;
        })
      }

      Row() {
        Text('Memory: ' + (this.speakerSnapshot !== null ? this.speakerSnapshot.memories.length.toString() : '0'))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
        Text('(omitted: ' + (this.speakerSnapshot !== null ? this.speakerSnapshot.omittedMemoryCount.toString() : '0') + ')')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 6 })
        Text('RUNTIME-INJECTED')
          .fontSize(10)
          .fontColor(WorldColors.SUCCESS)
          .margin({ left: 6 })
      }
      .width('100%')
      .margin({ top: 12 })

      if (this.speakerSnapshot !== null) {
        ForEach(this.speakerSnapshot.memories as WorldCrossSessionMemoryContextItem[], (m: WorldCrossSessionMemoryContextItem, mi: number): void => {
          this.contextMemoryItem(m)
        }, (m: WorldCrossSessionMemoryContextItem, mi: number): string => {
          return m.memoryId;
        })
      }

      Text('Display chars: ' + this.speakerDisplayChars.toString() + ' (not token count)')
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.TEXT_TERTIARY)
        .margin({ top: 8 })
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder
  contextSummaryItem(s: WorldCrossSessionSummaryContextItem): void {
    Column() {
      Row() {
        Text('session ' + s.sourceSessionSequenceNumber.toString())
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
        Text(this.shortId(s.sourceSessionId))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
      }
      .width('100%')
      Text(s.summaryText.length > 120 ? s.summaryText.substring(0, 120) + '...' : s.summaryText)
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.TEXT_PRIMARY)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .padding(8)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(8)
    .margin({ top: 4 })
  }

  @Builder
  contextMemoryItem(m: WorldCrossSessionMemoryContextItem): void {
    Column() {
      Row() {
        Text('session: ' + this.shortId(m.sourceSessionId))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
        Text('conf=' + m.confidence.toFixed(2))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 6 })
      }
      .width('100%')
      Text(m.memoryText.length > 120 ? m.memoryText.substring(0, 120) + '...' : m.memoryText)
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.TEXT_PRIMARY)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .padding(8)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(8)
    .margin({ top: 4 })
  }

  @Builder
  promptOrderHint(): void {
    Column() {
      Text('Prompt Order (current):')
        .fontSize(WorldMetrics.FONT_CAPTION)
        .fontColor(WorldColors.TEXT_TERTIARY)
        .margin({ top: 16 })
      Text('World Context -> Player Identity -> Preset/Lorebook/Character -> Dialogue Examples -> Memory -> Cross-session Context -> Current Conversation -> World Constraints -> Post-History')
        .fontSize(10)
        .fontColor(WorldColors.TEXT_TERTIARY)
        .margin({ top: 2 })
    }
    .width('100%')
  }

  @Builder
  dossierContent(): void {
    Scroll() {
      Column() {
        if (this.dossierInstances.length === 0) {
          Text('No character instances')
            .fontSize(WorldMetrics.FONT_BODY)
            .fontColor(WorldColors.TEXT_TERTIARY)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(32)
        } else {
          Text('Select Character:')
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_TERTIARY)
            .width('100%')
            .padding({ bottom: 4 })

          Scroll() {
            Row() {
              ForEach(this.dossierInstances, (inst: WorldCharacterInstance, ii: number): void => {
                Text(inst.displayNameSnapshot)
                  .fontSize(WorldMetrics.FONT_CAPTION)
                  .fontColor(this.selectedDossierIndex === ii ? WorldColors.ON_GOLD : WorldColors.TEXT_PRIMARY)
                  .backgroundColor(this.selectedDossierIndex === ii ? WorldColors.GOLD : WorldColors.SURFACE_2)
                  .borderRadius(WorldMetrics.RADIUS_CHIP)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .margin({ right: 6 })
                  .onClick((): void => {
                    if (this.selectedDossierIndex !== ii) {
                      this.selectedDossierIndex = ii;
                      this.expandedMemoryIndex = -1;
                      this.expandedRelationshipIndex = -1;
                      this.loadDossier(inst.id);
                    }
                  })
              }, (inst: WorldCharacterInstance, ii: number): string => {
                return inst.id;
              })
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .margin({ bottom: 12 })

          if (this.dossierLoading) {
            LoadingProgress().color(WorldColors.GOLD)
          } else if (this.dossierResult !== null) {
            this.dossierDetail()
          }
        }
      }
      .width('100%')
      .padding(WorldMetrics.PAGE_PADDING)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  dossierDetail(): void {
    Column() {
      this.dossierLocationSection()
      this.dossierMemorySection()
      this.dossierKnownEventSection()
      this.dossierRelationshipSection()
      this.dossierEventSection()
    }
    .width('100%')
  }

  @Builder
  dossierLocationSection(): void {
    Column() {
      Text('Current Location')
        .fontSize(WorldMetrics.FONT_SECTION)
        .fontColor(WorldColors.GOLD)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      if (this.dossierResult !== null) {
        Row() {
          Text('locationId: ')
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_TERTIARY)
          Text(this.dossierResult.instance.currentLocationId !== undefined
            ? this.shortId(this.dossierResult.instance.currentLocationId) : '(unplaced)')
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_PRIMARY)
          if (this.dossierResult.currentLocation !== null) {
            Text(' (' + this.dossierResult.currentLocation.title + ')')
              .fontSize(WorldMetrics.FONT_CAPTION)
              .fontColor(WorldColors.TEXT_SECONDARY)
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
    .margin({ bottom: 8 })
  }

  @Builder
  dossierMemorySection(): void {
    Column() {
      Row() {
        Text('Memory')
          .fontSize(WorldMetrics.FONT_SECTION)
          .fontColor(WorldColors.GOLD)
          .fontWeight(FontWeight.Medium)
        Text('(' + (this.dossierResult !== null ? this.dossierResult.memories.length.toString() : '0') + ')')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('RUNTIME-INJECTED')
          .fontSize(10)
          .fontColor(WorldColors.SUCCESS)
          .margin({ left: 6 })
      }
      .width('100%')

      if (this.dossierResult !== null && this.dossierResult.memories.length === 0) {
        Text('No active memories')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .width('100%')
          .padding({ top: 4 })
      } else if (this.dossierResult !== null) {
        ForEach(this.dossierResult.memories, (mem: WorldCharacterMemoryEntry, mi: number): void => {
          this.dossierMemoryItem(mem, mi)
        }, (mem: WorldCharacterMemoryEntry, mi: number): string => {
          return mem.id;
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
    .margin({ bottom: 8 })
  }

  @Builder
  dossierMemoryItem(mem: WorldCharacterMemoryEntry, mi: number): void {
    Column() {
      Row() {
        Text(this.shortId(mem.id))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
        Text('v' + mem.version.toString())
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('conf=' + mem.confidence.toFixed(2))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('session: ' + this.shortId(mem.sourceSessionId))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
          .margin({ left: 4 })
      }
      .width('100%')

      if (this.expandedMemoryIndex === mi) {
        Text(mem.memoryText)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 4 })
        Row() {
          Text('sourceLocation: ' + this.shortId(mem.sourceLocationId))
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_TERTIARY)
          Text('status: ' + mem.status)
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_TERTIARY)
            .margin({ left: 6 })
        }
        .width('100%')
        .margin({ top: 2 })
      } else {
        Text(mem.memoryText.length > 80 ? mem.memoryText.substring(0, 80) + '...' : mem.memoryText)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_PRIMARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }

      Text(this.expandedMemoryIndex === mi ? 'Collapse' : 'Expand')
        .fontSize(10)
        .fontColor(WorldColors.GOLD)
        .margin({ top: 2 })
        .onClick((): void => {
          this.expandedMemoryIndex = this.expandedMemoryIndex === mi ? -1 : mi;
        })
    }
    .width('100%')
    .padding(8)
    .backgroundColor(WorldColors.SURFACE_2)
    .borderRadius(8)
    .margin({ top: 4 })
  }

  @Builder
  dossierKnownEventSection(): void {
    Column() {
      Row() {
        Text('KnownEvent')
          .fontSize(WorldMetrics.FONT_SECTION)
          .fontColor(WorldColors.GOLD)
          .fontWeight(FontWeight.Medium)
        Text('(' + (this.dossierResult !== null ? this.dossierResult.knownEvents.length.toString() : '0') + ')')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('STORED ONLY')
          .fontSize(10)
          .fontColor(WorldColors.WARNING)
          .margin({ left: 6 })
      }
      .width('100%')

      if (this.dossierResult !== null && this.dossierResult.knownEvents.length === 0) {
        Text('No active known events')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .width('100%')
          .padding({ top: 4 })
      } else if (this.dossierResult !== null) {
        ForEach(this.dossierResult.knownEvents, (ke: WorldKnownEventEntry, ki: number): void => {
          this.dossierKnownEventItem(ke, ki)
        }, (ke: WorldKnownEventEntry, ki: number): string => {
          return ke.id;
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
    .margin({ bottom: 8 })
  }

  @Builder
  dossierKnownEventItem(ke: WorldKnownEventEntry, ki: number): void {
    Column() {
      Row() {
        Text('eventId: ' + this.shortId(ke.eventId))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
        Text('source: ' + ke.knowledgeSourceKind)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 6 })
        Text('session: ' + this.shortId(ke.sourceSessionId))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 6 })
      }
      .width('100%')
    }
    .width('100%')
    .padding(8)
    .backgroundColor(WorldColors.SURFACE_2)
    .borderRadius(8)
    .margin({ top: 4 })
  }

  @Builder
  dossierRelationshipSection(): void {
    Column() {
      Row() {
        Text('Relationship')
          .fontSize(WorldMetrics.FONT_SECTION)
          .fontColor(WorldColors.GOLD)
          .fontWeight(FontWeight.Medium)
        Text('(' + (this.dossierResult !== null ? this.dossierResult.relationships.length.toString() : '0') + ')')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('STORED ONLY')
          .fontSize(10)
          .fontColor(WorldColors.WARNING)
          .margin({ left: 6 })
      }
      .width('100%')

      if (this.dossierResult !== null && this.dossierResult.relationships.length === 0) {
        Text('No active relationships')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .width('100%')
          .padding({ top: 4 })
      } else if (this.dossierResult !== null) {
        ForEach(this.dossierResult.relationships, (rel: WorldDirectionalRelationshipEntry, ri: number): void => {
          this.dossierRelationshipItem(rel, ri)
        }, (rel: WorldDirectionalRelationshipEntry, ri: number): string => {
          return rel.id;
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
    .margin({ bottom: 8 })
  }

  @Builder
  dossierRelationshipItem(rel: WorldDirectionalRelationshipEntry, ri: number): void {
    Column() {
      Row() {
        Text(rel.ownerDisplayNameSnapshot + ' -> ' + rel.targetDisplayNameSnapshot)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_SECONDARY)
        Text('v' + rel.version.toString())
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('conf=' + rel.confidence.toFixed(2))
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
      }
      .width('100%')

      if (this.expandedRelationshipIndex === ri) {
        Text(rel.relationshipText)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_PRIMARY)
          .width('100%')
          .margin({ top: 4 })
        Row() {
          Text('sourceSession: ' + this.shortId(rel.sourceSessionId))
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_TERTIARY)
          Text('sourceLocation: ' + this.shortId(rel.sourceLocationId))
            .fontSize(WorldMetrics.FONT_CAPTION)
            .fontColor(WorldColors.TEXT_TERTIARY)
            .margin({ left: 6 })
        }
        .width('100%')
        .margin({ top: 2 })
      } else {
        Text(rel.relationshipText.length > 80 ? rel.relationshipText.substring(0, 80) + '...' : rel.relationshipText)
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_PRIMARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }

      Text(this.expandedRelationshipIndex === ri ? 'Collapse' : 'Expand')
        .fontSize(10)
        .fontColor(WorldColors.GOLD)
        .margin({ top: 2 })
        .onClick((): void => {
          this.expandedRelationshipIndex = this.expandedRelationshipIndex === ri ? -1 : ri;
        })
    }
    .width('100%')
    .padding(8)
    .backgroundColor(WorldColors.SURFACE_2)
    .borderRadius(8)
    .margin({ top: 4 })
  }

  @Builder
  dossierEventSection(): void {
    Column() {
      Row() {
        Text('WorldEvent')
          .fontSize(WorldMetrics.FONT_SECTION)
          .fontColor(WorldColors.GOLD)
          .fontWeight(FontWeight.Medium)
        Text('(' + this.dossierEventEntries.length.toString() + ')')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .margin({ left: 4 })
        Text('NOT RUNTIME-INJECTED')
          .fontSize(10)
          .fontColor(WorldColors.WARNING)
          .margin({ left: 6 })
      }
      .width('100%')

      if (this.dossierEventEntries.length === 0) {
        Text('No events for current session')
          .fontSize(WorldMetrics.FONT_CAPTION)
          .fontColor(WorldColors.TEXT_TERTIARY)
          .width('100%')
          .padding({ top: 4 })
      } else {
        ForEach(this.dossierEventEntries, (ev: WorldEventEntry, ei: number): void => {
          Row() {
            Text(ev.eventKind)
              .fontSize(WorldMetrics.FONT_CAPTION)
              .fontColor(WorldColors.TEXT_SECONDARY)
            Text('#' + ev.eventOrdinal.toString())
              .fontSize(WorldMetrics.FONT_CAPTION)
              .fontColor(WorldColors.TEXT_TERTIARY)
              .margin({ left: 4 })
            Text(ev.eventText.length > 60 ? ev.eventText.substring(0, 60) + '...' : ev.eventText)
              .fontSize(WorldMetrics.FONT_CAPTION)
              .fontColor(WorldColors.TEXT_PRIMARY)
              .margin({ left: 4 })
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding(6)
          .backgroundColor(WorldColors.SURFACE_2)
          .borderRadius(6)
          .margin({ top: 4 })
        }, (ev: WorldEventEntry, ei: number): string => {
          return ev.id;
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(WorldColors.SURFACE_1)
    .borderRadius(WorldMetrics.RADIUS_CARD)
    .margin({ bottom: 8 })
  }

  private runStatusBadge(status: WorldSessionPostProcessRunStatus): string {
    if (status === WorldSessionPostProcessRunStatus.Pending) {
      return 'Pending';
    }
    if (status === WorldSessionPostProcessRunStatus.Running) {
      return 'Running';
    }
    if (status === WorldSessionPostProcessRunStatus.Completed) {
      return 'Completed';
    }
    if (status === WorldSessionPostProcessRunStatus.CompletedWithErrors) {
      return 'CompletedWithErrors';
    }
    return status;
  }

  private runStatusColor(status: WorldSessionPostProcessRunStatus): string {
    if (status === WorldSessionPostProcessRunStatus.Completed) {
      return WorldColors.SUCCESS;
    }
    if (status === WorldSessionPostProcessRunStatus.CompletedWithErrors) {
      return WorldColors.WARNING;
    }
    if (status === WorldSessionPostProcessRunStatus.Running) {
      return WorldColors.INFO;
    }
    return WorldColors.TEXT_TERTIARY;
  }

  private runStatusBgColor(status: WorldSessionPostProcessRunStatus): string {
    if (status === WorldSessionPostProcessRunStatus.Completed) {
      return '#1A3D1A';
    }
    if (status === WorldSessionPostProcessRunStatus.CompletedWithErrors) {
      return '#3D2E1A';
    }
    if (status === WorldSessionPostProcessRunStatus.Running) {
      return '#1A2A3D';
    }
    return WorldColors.SURFACE_2;
  }

  private stepStatusBadge(status: WorldSessionPostProcessStepStatus): string {
    if (status === WorldSessionPostProcessStepStatus.Succeeded) {
      return 'OK';
    }
    if (status === WorldSessionPostProcessStepStatus.Skipped) {
      return 'Skip';
    }
    if (status === WorldSessionPostProcessStepStatus.Failed) {
      return 'Fail';
    }
    if (status === WorldSessionPostProcessStepStatus.Running) {
      return 'Run';
    }
    return 'Wait';
  }

  private stepStatusColor(status: WorldSessionPostProcessStepStatus): string {
    if (status === WorldSessionPostProcessStepStatus.Succeeded) {
      return WorldColors.SUCCESS;
    }
    if (status === WorldSessionPostProcessStepStatus.Skipped) {
      return WorldColors.TEXT_TERTIARY;
    }
    if (status === WorldSessionPostProcessStepStatus.Failed) {
      return WorldColors.ERROR;
    }
    if (status === WorldSessionPostProcessStepStatus.Running) {
      return WorldColors.INFO;
    }
    return WorldColors.TEXT_TERTIARY;
  }

  private resultCodeBadge(code: WorldSessionPostProcessResultCode): string {
    if (code === WorldSessionPostProcessResultCode.Generated) {
      return 'Generated';
    }
    if (code === WorldSessionPostProcessResultCode.Existing) {
      return 'Existing';
    }
    if (code === WorldSessionPostProcessResultCode.NoPublicContent) {
      return 'NoPublicContent';
    }
    if (code === WorldSessionPostProcessResultCode.NoVisibleEvidence) {
      return 'NoVisibleEvidence';
    }
    if (code === WorldSessionPostProcessResultCode.ZeroEvents) {
      return 'ZeroEvents';
    }
    if (code === WorldSessionPostProcessResultCode.Derived) {
      return 'Derived';
    }
    if (code === WorldSessionPostProcessResultCode.ZeroKnownEvents) {
      return 'ZeroKnownEvents';
    }
    if (code === WorldSessionPostProcessResultCode.NoChange) {
      return 'NoChange';
    }
    if (code === WorldSessionPostProcessResultCode.SkippedDependency) {
      return 'SkippedDependency';
    }
    if (code === WorldSessionPostProcessResultCode.BatchTooLarge) {
      return 'BatchTooLarge';
    }
    return code;
  }

  private shortId(id: string): string {
    if (id.length <= 12) {
      return id;
    }
    return '..' + id.substring(id.length - 10);
  }

  private asContextError(result: InspectorSpeakerContext | InspectorSpeakerContextError): InspectorSpeakerContextError | null {
    const err: InspectorSpeakerContextError = result as InspectorSpeakerContextError;
    if (err.errorCategory !== undefined && err.errorCategory.length > 0) {
      return err;
    }
    return null;
  }
}
