import { WorldSceneLaunchService } from '../../services/world/WorldSceneLaunchService';
import { CharacterService } from '../../services/CharacterService';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { Logger } from '../../utils/Logger';
import {
  WorldSceneLaunchSnapshot,
  WorldSceneLaunchTarget,
  WorldSceneLaunchResult,
  WorldSceneLaunchEligibleParticipant,
  WorldSceneLaunchError
} from '../../models/world/WorldSceneLaunch';
import { WorldConversationSessionStatus } from '../../models/world/WorldConversationSession';
import { WorldSceneStatus } from '../../models/world/WorldScene';
import { Character } from '../../models/Character';

const LOG_TAG: string = 'WorldSceneLauncherViewModel';

export enum LauncherLoadState {
  Loading,
  Ready,
  NotFound,
  Error
}

export interface LauncherParticipantUiModel {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly selected: boolean;
}

export interface LauncherUiModel {
  readonly worldId: string;
  readonly locationId: string;
  readonly locationName: string;
  readonly hasActiveScene: boolean;
  readonly hasActiveSession: boolean;
  readonly activeSessionId: string;
  readonly activeSceneId: string;
  readonly activeSceneStatus: WorldSceneStatus;
  readonly activeSessionStatus: WorldConversationSessionStatus;
  readonly participants: LauncherParticipantUiModel[];
  readonly canLaunchNewSession: boolean;
  readonly canContinueSession: boolean;
  readonly isSceneEnded: boolean;
}

export interface LauncherLaunchResult {
  readonly success: boolean;
  readonly sceneId: string;
  readonly sessionId: string;
  readonly errorMessage: string;
}

export class WorldSceneLauncherViewModel {
  private readonly launchService: WorldSceneLaunchService;
  private readonly characterService: CharacterService;
  private readonly instanceRepo: WorldCharacterInstanceRepository;

  state: LauncherLoadState = LauncherLoadState.Loading;
  errorMessage: string = '';
  detail: LauncherUiModel | null = null;

  private expectedWorldId: string = '';
  private expectedLocationId: string = '';
  private loadOperationId: number = 0;
  private selectedIds: string[] = [];
  private preselectedInstanceId: string = '';
  isLaunching: boolean = false;
  private disposed: boolean = false;
  readonly instanceShortId: string;

  private rawSnapshot: WorldSceneLaunchSnapshot | null = null;

  constructor(
    launchService: WorldSceneLaunchService,
    characterService: CharacterService,
    instanceRepo: WorldCharacterInstanceRepository
  ) {
    this.launchService = launchService;
    this.characterService = characterService;
    this.instanceRepo = instanceRepo;
    this.instanceShortId = WorldSceneLauncherViewModel.generateShortId();
  }

  private static generateShortId(): string {
    const ts: number = Date.now();
    const tail: number = Math.floor(ts % 0xffff);
    return tail.toString(16).padStart(4, '0');
  }

  activate(): void {
    if (this.disposed) {
      this.disposed = false;
      Logger.info(LOG_TAG, 'activate: vmInstance=' + this.instanceShortId);
    }
  }

  dispose(): void {
    this.disposed = true;
    Logger.info(LOG_TAG, 'dispose: vmInstance=' + this.instanceShortId);
  }

  setPreselectedInstanceId(id: string): void {
    this.preselectedInstanceId = id;
  }

  async loadSnapshot(worldId: string, locationId: string): Promise<void> {
    if (this.disposed) {
      Logger.warn(LOG_TAG, 'loadSnapshot skipped: disposed');
      return;
    }
    this.expectedWorldId = worldId;
    this.expectedLocationId = locationId;
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = LauncherLoadState.Loading;
    this.errorMessage = '';

    try {
      const snapshot: WorldSceneLaunchSnapshot = await this.launchService.loadLaunchSnapshot(worldId, locationId);
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.rawSnapshot = snapshot;

      const participantUiModels: LauncherParticipantUiModel[] = [];
      const selectedIds: string[] = [];
      for (let i = 0; i < snapshot.eligibleParticipants.length; i++) {
        const p: WorldSceneLaunchEligibleParticipant = snapshot.eligibleParticipants[i];
        const avatarUri: string = await this.resolveAvatarUri(p.characterInstanceId);
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        const isSelected: boolean = this.preselectedInstanceId === p.characterInstanceId;
        participantUiModels.push({
          instanceId: p.characterInstanceId,
          displayName: p.displayNameSnapshot,
          avatarUri: avatarUri,
          selected: isSelected
        });
        if (isSelected) {
          selectedIds.push(p.characterInstanceId);
        }
      }
      this.selectedIds = selectedIds;

      const hasActiveScene: boolean = snapshot.existingActiveScene !== null;
      const hasActiveSession: boolean = snapshot.existingActiveSession !== null;
      const isSceneEnded: boolean = hasActiveScene
        && snapshot.existingActiveScene !== null
        && snapshot.existingActiveScene.status === WorldSceneStatus.Ended;
      const canContinueSession: boolean = hasActiveSession
        && snapshot.existingActiveSession !== null
        && snapshot.existingActiveSession.status === WorldConversationSessionStatus.Active;
      // 多场景并行:只要地点有可参与角色即可新建独立场景,即使已有进行中会话。
      const canLaunchNewSession: boolean =
        snapshot.eligibleParticipants.length > 0;

      const uiModel: LauncherUiModel = {
        worldId: snapshot.worldId,
        locationId: snapshot.locationId,
        locationName: snapshot.locationName,
        hasActiveScene: hasActiveScene,
        hasActiveSession: hasActiveSession,
        activeSessionId: hasActiveSession && snapshot.existingActiveSession !== null
          ? snapshot.existingActiveSession.id : '',
        activeSceneId: hasActiveScene && snapshot.existingActiveScene !== null
          ? snapshot.existingActiveScene.id : '',
        activeSceneStatus: hasActiveScene && snapshot.existingActiveScene !== null
          ? snapshot.existingActiveScene.status as WorldSceneStatus : WorldSceneStatus.Ended,
        activeSessionStatus: hasActiveSession && snapshot.existingActiveSession !== null
          ? snapshot.existingActiveSession.status as WorldConversationSessionStatus
          : WorldConversationSessionStatus.Ended,
        participants: participantUiModels,
        canLaunchNewSession: canLaunchNewSession,
        canContinueSession: canContinueSession,
        isSceneEnded: isSceneEnded
      };

      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.detail = uiModel;
      this.state = LauncherLoadState.Ready;
      Logger.info(LOG_TAG, 'loadSnapshot done: vmInstance=' + this.instanceShortId
        + ', operation=' + operationId.toString()
        + ', hasActiveScene=' + (hasActiveScene ? '1' : '0')
        + ', hasActiveSession=' + (hasActiveSession ? '1' : '0')
        + ', canLaunch=' + (canLaunchNewSession ? '1' : '0')
        + ', canContinue=' + (canContinueSession ? '1' : '0')
        + ', locShortId=' + this.shortId(locationId));
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'loadSnapshot failed: vmInstance=' + this.instanceShortId
        + ', ' + this.safeErrorCategory(e));
      this.errorMessage = '地点数据加载失败,请重试';
      this.state = LauncherLoadState.Error;
    }
  }

  toggleParticipant(instanceId: string): void {
    if (this.detail === null) {
      return;
    }
    const idx: number = this.selectedIds.indexOf(instanceId);
    if (idx >= 0) {
      const newIds: string[] = this.selectedIds.slice();
      newIds.splice(idx, 1);
      this.selectedIds = newIds;
    } else {
      const newIds: string[] = this.selectedIds.slice();
      newIds.push(instanceId);
      this.selectedIds = newIds;
    }
    const updatedParticipants: LauncherParticipantUiModel[] = [];
    for (let i = 0; i < this.detail.participants.length; i++) {
      const p: LauncherParticipantUiModel = this.detail.participants[i];
      updatedParticipants.push({
        instanceId: p.instanceId,
        displayName: p.displayName,
        avatarUri: p.avatarUri,
        selected: this.selectedIds.indexOf(p.instanceId) >= 0
      });
    }
    const canLaunch: boolean = this.selectedIds.length > 0;
    this.detail = {
      worldId: this.detail.worldId,
      locationId: this.detail.locationId,
      locationName: this.detail.locationName,
      hasActiveScene: this.detail.hasActiveScene,
      hasActiveSession: this.detail.hasActiveSession,
      activeSessionId: this.detail.activeSessionId,
      activeSceneId: this.detail.activeSceneId,
      activeSceneStatus: this.detail.activeSceneStatus,
      activeSessionStatus: this.detail.activeSessionStatus,
      participants: updatedParticipants,
      canLaunchNewSession: canLaunch,
      canContinueSession: this.detail.canContinueSession,
      isSceneEnded: this.detail.isSceneEnded
    };
  }

  async continueActiveSession(): Promise<LauncherLaunchResult> {
    if (this.detail === null || !this.detail.canContinueSession) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '无进行中的会话' } as LauncherLaunchResult;
    }
    if (this.rawSnapshot === null) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '数据未加载' } as LauncherLaunchResult;
    }
    if (this.rawSnapshot.existingActiveScene === null || this.rawSnapshot.existingActiveSession === null) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '数据异常' } as LauncherLaunchResult;
    }
    Logger.info(LOG_TAG, 'continueActiveSession: sceneShortId='
      + this.shortId(this.rawSnapshot.existingActiveScene.id)
      + ', sessionShortId=' + this.shortId(this.rawSnapshot.existingActiveSession.id));
    return {
      success: true,
      sceneId: this.rawSnapshot.existingActiveScene.id,
      sessionId: this.rawSnapshot.existingActiveSession.id,
      errorMessage: ''
    } as LauncherLaunchResult;
  }

  async launchNewSession(): Promise<LauncherLaunchResult> {
    if (this.isLaunching) {
      Logger.warn(LOG_TAG, 'launchNewSession skipped: isLaunching');
      return { success: false, sceneId: '', sessionId: '', errorMessage: '正在处理,请稍候' } as LauncherLaunchResult;
    }
    if (this.detail === null) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '数据未加载' } as LauncherLaunchResult;
    }
    if (this.selectedIds.length === 0) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '请选择至少一个参与角色' } as LauncherLaunchResult;
    }
    if (this.rawSnapshot === null) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '数据未加载' } as LauncherLaunchResult;
    }

    this.isLaunching = true;
    try {
      const target: WorldSceneLaunchTarget = {
        worldId: this.detail.worldId,
        locationId: this.detail.locationId,
        participantCharacterInstanceIds: this.selectedIds.slice()
      };
      const result: WorldSceneLaunchResult = await this.launchService.launchSceneSession(target);
      Logger.info(LOG_TAG, 'launchNewSession ok: sceneShortId=' + this.shortId(result.scene.id)
        + ', sessionShortId=' + this.shortId(result.session.id)
        + ', isNewScene=' + (result.isNewScene ? '1' : '0')
        + ', isNewSession=' + (result.isNewSession ? '1' : '0'));
      return {
        success: true,
        sceneId: result.scene.id,
        sessionId: result.session.id,
        errorMessage: ''
      } as LauncherLaunchResult;
    } catch (e) {
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'launchNewSession failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(this.detail.worldId)
        + ', locShortId=' + this.shortId(this.detail.locationId));
      return { success: false, sceneId: '', sessionId: '', errorMessage: msg } as LauncherLaunchResult;
    } finally {
      this.isLaunching = false;
    }
  }

  selectedCount(): number {
    return this.selectedIds.length;
  }

  /** 直接以指定角色开启 1:1 单人会话(地点已有 Active 会话时走 continue 逻辑由调用方控制)。 */
  async launchSoloSession(instanceId: string): Promise<LauncherLaunchResult> {
    if (this.isLaunching) {
      Logger.warn(LOG_TAG, 'launchSoloSession skipped: isLaunching');
      return { success: false, sceneId: '', sessionId: '', errorMessage: '正在处理,请稍候' } as LauncherLaunchResult;
    }
    if (this.detail === null) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '数据未加载' } as LauncherLaunchResult;
    }
    if (instanceId.length === 0) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '请选择角色' } as LauncherLaunchResult;
    }
    if (this.rawSnapshot === null) {
      return { success: false, sceneId: '', sessionId: '', errorMessage: '数据未加载' } as LauncherLaunchResult;
    }

    this.isLaunching = true;
    try {
      const target: WorldSceneLaunchTarget = {
        worldId: this.detail.worldId,
        locationId: this.detail.locationId,
        participantCharacterInstanceIds: [instanceId]
      };
      const result: WorldSceneLaunchResult = await this.launchService.launchSceneSession(target);
      Logger.info(LOG_TAG, 'launchSoloSession ok: sceneShortId=' + this.shortId(result.scene.id)
        + ', sessionShortId=' + this.shortId(result.session.id));
      return {
        success: true,
        sceneId: result.scene.id,
        sessionId: result.session.id,
        errorMessage: ''
      } as LauncherLaunchResult;
    } catch (e) {
      const msg: string = this.resolveErrorMessage(e);
      Logger.warn(LOG_TAG, 'launchSoloSession failed: ' + this.safeErrorCategory(e)
        + ', worldShortId=' + this.shortId(this.detail.worldId));
      return { success: false, sceneId: '', sessionId: '', errorMessage: msg } as LauncherLaunchResult;
    } finally {
      this.isLaunching = false;
    }
  }

  private async resolveAvatarUri(characterInstanceId: string): Promise<string> {
    try {
      const inst = await this.instanceRepo.getById(characterInstanceId);
      if (inst === null || inst.characterId.length === 0) {
        return '';
      }
      const c: Character | null = await this.characterService.getById(inst.characterId);
      if (c !== null) {
        return c.avatarUri;
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  private resolveErrorMessage(e: Object): string {
    if (e instanceof WorldSceneLaunchError) {
      return e.message;
    }
    const msg: string = (e as Error).message ?? '';
    if (msg.length > 0) {
      return msg.length > 60 ? msg.substring(0, 60) : msg;
    }
    return '操作失败,请重试';
  }

  private safeErrorCategory(e: Object): string {
    if (e instanceof WorldSceneLaunchError) {
      return 'LaunchError:' + e.kind.toString();
    }
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }

  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}
