/**
 * Character3DActionManagerPage 3D 动作管理页面
 *
 * T-3D.6C: 三列卡片式动作管理页面。
 *
 * 功能:
 * - 顶部当前模型卡片 + 导入模型/导入动作入口
 * - 动作分类筛选 Chip(全部/内置/已导入/循环/单次/当前模型可用)
 * - 三列卡片网格(LazyForEach 懒加载)
 * - 卡片显示:动作预览占位 + 名称 + 来源标记(内置/导入)
 * - 单击卡片:打开预览弹层(共享 Component3D 播放动作)
 * - 长按卡片:打开管理菜单(重命名/恢复默认/预览/绑定/隐藏/删除)
 * - 内置动作不可删除,只可隐藏/重命名
 * - 导入动作可删除(解除绑定 + 清理文件)
 * - 无当前模型时仍可浏览和预览默认动作
 *
 * 性能:
 * - 使用 Grid 懒加载
 * - 卡片不创建独立 3D Scene
 * - 预览弹层使用共享 Component3D,同一时刻只有一个预览
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { Scene, Animation, Camera, Light, LightType, Position3, SceneNodeParameters, SceneResourceFactory, Node } from '@kit.ArkGraphics3D';
import { AppServices } from '../services/AppServices';
import { Character3DService, Character3DModelConfig } from '../services/Character3DService';
import {
  Character3DActionService,
  ActionImportPreview,
  ActionImportRequest,
  ActionImportConfirm
} from '../services/Character3DActionService';
import {
  Character3DActionManagerViewModel,
  ActionCardItem,
  ModelSummary
} from '../viewmodels/Character3DActionManagerViewModel';
import {
  Character3DActionSlot,
  ActionSlotInfo,
  getAllSlotInfos,
  getSlotInfo
} from '../models/character3d/Character3DActionSlot';
import {
  Character3DActionAsset,
  Character3DActionBinding,
  AnimationClipInfo,
  ActionLoopMode
} from '../models/character3d/Character3DActionAsset';
import {
  ActionSourceFormat,
  CompatibilityLevel
} from '../models/character3d/HumanoidBone';
import {
  ActionCategory,
  ActionFilter
} from '../models/character3d/UnifiedActionItem';
import {
  getCompatibilityLevelDisplayName,
  getSkeletonProfileDisplayName
} from '../models/character3d/HumanoidBoneMapper';
import {
  ModelCapabilityReport,
  CapabilityState,
  HumanoidMappingState,
  getCapabilityStateText,
  getHumanoidMappingStateText,
  getMotionRetargetingText
} from '../models/character3d/ModelCapabilityReport';
import { Logger } from '../utils/Logger';
import { ActionPreviewCanvas } from '../components/ActionPreviewCanvas';
import { ActionAvatarPreview3D } from '../components/ActionAvatarPreview3D';
import { StableActionPreview3DHost } from '../components/StableActionPreview3DHost';
import { ActionCardDataSource } from '../viewmodels/ActionCardDataSource';
import {
  ActionAvatarPreviewViewModel,
  ActionPreview3DState,
  PreviewActionInfo
} from '../viewmodels/ActionAvatarPreviewViewModel';
import { AvatarLibraryService } from '../services/AvatarLibraryService';
import {
  AvatarOrientationCalibration,
  AvatarOrientationMode,
  OrientationConfidence,
  AvatarOrientationAnalysis,
  OrientationCandidateScore
} from '../models/character3d/AvatarOrientationCalibration';
import {
  SkeletonDisplayMode,
  SkeletonDisplayModeInfo,
  getAllSkeletonDisplayModes
} from '../models/character3d/SkeletonDisplayMode';
import { RestPoseType } from '../services/RestPoseClassifier';

const LOG_TAG: string = 'Char3DActionPage';

/**
 * T-3D.6B: 开发构建标识。正式发布前必须改为 false。
 */
const IS_DEV_BUILD: boolean = true;
const DEV_TEST_ACTION_RELATIVE_PATH: string = 'dev_action_test/Fox.glb';
const DEV_TEST_ACTION_DISPLAY_NAME: string = 'Fox.glb';
const DEV_TEST_ACTION_DOWNLOAD_URL: string =
  'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/Fox/glTF-Binary/Fox.glb';

@Entry
@Component
struct Character3DActionManagerPage {
  // ========== 服务引用 ==========
  private actionService: Character3DActionService | null = null;
  private model3DService: Character3DService | null = null;
  private vm: Character3DActionManagerViewModel | null = null;

  // ========== 模型状态 ==========
  @State private modelConfig: Character3DModelConfig = { modelUri: '', displayName: '', fileExists: false };
  @State private modelSummary: ModelSummary | null = null;

  // ========== 动作卡片状态 ==========
  @State private allCards: ActionCardItem[] = [];
  @State private filteredCards: ActionCardItem[] = [];
  private cardDataSource: ActionCardDataSource = new ActionCardDataSource();
  @State private currentFilter: ActionFilter = ActionFilter.All;
  @State private searchKeyword: string = '';
  @State private showSearchInput: boolean = false;
  @State private includeHidden: boolean = false;
  @State private selectedCardId: string = '';

  // ========== 加载状态 ==========
  @State private isLoading: boolean = false;
  @State private isImporting: boolean = false;
  @State private errorMessage: string = '';

  // ========== 导入预览 ==========
  @State private importPreview: ActionImportPreview | null = null;
  @State private selectedClipIndex: number = 0;
  @State private selectedTargetSlot: Character3DActionSlot = Character3DActionSlot.Idle;
  @State private importLoop: boolean = true;
  @State private importDisplayName: string = '';

  // ========== 弹层状态 ==========
  // T-4.2G-A2: 统一动作详情与管理窗口(合并原 previewDialog + detailsSheet)
  @State private actionDialogCard: ActionCardItem | null = null;
  private actionDialogVm: ActionAvatarPreviewViewModel | null = null;
  @State private actionDialogScene: Scene | null = null;
  @State private actionDialogState: ActionPreview3DState = ActionPreview3DState.Idle;
  @State private actionDialogError: string = '';
  @State private actionDialogAvatarName: string = '';
  @State private actionDialogNotice: string = '';
  /** T-4.2G-A3: 模型是否可见(控制 Component3D opacity,避免 Surface 创建过程闪烁)
   *  scene 就绪后 Component3D 挂载,但 opacity=0;
   *  内容完全就绪(Ready/Playing/Paused)后才 opacity=1。
   *  这样 Surface 创建/重新初始化过程对用户不可见。 */
  @State private actionDialogModelVisible: boolean = false;
  /** 异步加载令牌:每次打开/切换动作递增,过期回调直接丢弃 */
  private actionDialogToken: number = 0;
  /** T-4.2G-A3: 诊断计数(每次打开重置)
   *  - sceneAssignmentCount: scene 被赋值次数(应为 1)
   *  - hostCreatedCount: StableActionPreview3DHost 创建次数(应为 1)
   *  - hostDisposedCount: Host dispose 次数(打开期间应为 0)
   *  - surfaceRelatedState: 触发 Surface 重建的状态变化轨迹 */
  private dialogGeneration: number = 0;
  private sceneAssignmentCount: number = 0;
  private hostCreatedCount: number = 0;
  private hostDisposedCount: number = 0;
  private surfaceRelatedState: string = '';

  // 长按轻量菜单 + 重命名/删除/绑定子对话框
  @State private manageCard: ActionCardItem | null = null;
  @State private renameCard: ActionCardItem | null = null;
  @State private renameText: string = '';
  @State private deleteConfirmCard: ActionCardItem | null = null;
  @State private bindSlotCard: ActionCardItem | null = null;

  // ========== T-4.2G-A2: 目标骨架可视化 ==========
  // T-4.2G-A2 统一姿势: 默认改为 ModelOnly,避免普通用户被调试骨架干扰
  @State private skeletonDisplayMode: SkeletonDisplayMode = SkeletonDisplayMode.ModelOnly;
  @State private skeletonJointCount: number = 0;
  @State private skeletonSegmentCount: number = 0;
  @State private skeletonPoseType: RestPoseType = RestPoseType.Unknown;
  @State private skeletonConfidence: number = 0;
  @State private skeletonPoseMessage: string = '';
  /** 骨架详细信息默认折叠,正常用户只看摘要"T Pose · 置信度 95%" */
  @State private showSkeletonDetail: boolean = false;
  /** 管理折叠区(底部) */
  @State private showManagePanel: boolean = false;
  /** T-4.2G-A3: Debug 红绿点可视化开关(仅 IS_DEV_BUILD 时显示) */
  @State private skeletonDebugMode: boolean = false;
  /** T-4.2G-A4: Debug 三栏对比可视化开关(源 Rest/源动画/目标重定向) */
  @State private sourceTargetCompareMode: boolean = false;

  // ========== T-4.2G: 方向校准 ==========
  @State private showOrientationPanel: boolean = false;
  @State private orientationCalibration: AvatarOrientationCalibration | null = null;
  @State private orientationAnalysis: AvatarOrientationAnalysis | null = null;
  @State private customYawInput: number = 0;
  @State private customSwapInput: boolean = false;
  @State private customInvertInput: boolean = false;
  @State private calibrationApplying: boolean = false;

  // ========== 避让高度 ==========
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationIndicatorHeight') navigationIndicatorHeight: number = 0;

  // ========== 槽位信息 ==========
  @State private slotInfos: ActionSlotInfo[] = getAllSlotInfos();

  aboutToAppear(): void {
    this.isLoading = true;
    AppServices.whenReady().then((): void => {
      this.actionService = AppServices.getCharacter3DActionService();
      this.model3DService = AppServices.getCharacter3DService();
      if (this.actionService === null || this.model3DService === null) {
        this.errorMessage = '服务未初始化';
        this.isLoading = false;
        return;
      }
      this.vm = new Character3DActionManagerViewModel(this.actionService, this.model3DService);
      // T-4.2C: 注入 AvatarLibraryService 以按 avatarId 读取/生成能力报告
      const avatarLibraryService: AvatarLibraryService | null = AppServices.getAvatarLibraryService();
      if (avatarLibraryService !== null) {
        this.vm.setAvatarLibraryService(avatarLibraryService);
      }
      this.loadAllData();
    }).catch((e: Error): void => {
      Logger.error(LOG_TAG, 'whenReady failed: ' + e.message);
      this.errorMessage = '初始化失败: ' + e.message;
      this.isLoading = false;
    });
  }

  aboutToDisappear(): void {
    this.cleanupActionDialog();
  }

  onPageHide(): void {
    this.cleanupActionDialog();
  }

  /**
   * T-4.2G-A2: 清理统一动作窗口资源。
   *
   * 关闭弹窗或页面销毁时调用:
   * 1. 递增 token 让所有过期异步回调直接丢弃
   * 2. 清空 ViewModel 回调避免已释放 VM 回写页面状态
   * 3. dispose ViewModel(内部会 destroy Scene、Skeleton、Retarget Controller)
   * 4. 重置所有 UI 状态字段
   */
  /**
   * T-4.2G-A3: 延迟显示模型,等待 Component3D Surface 完全初始化。
   *
   * Scene 加载完成后 Surface 仍需 ~67ms 完成 Vulkan Swapchain 初始化和
   * RSNode 挂载。立即设置 modelVisible=true 会暴露 Surface 创建过程
   * (空白方框闪烁)。
   *
   * 延迟 100~150ms 后再显示模型,且必须携带 token 检查,避免旧窗口
   * 回写新窗口状态。
   *
   * @param token 调用时的 dialogToken
   * @param delayMs 延迟毫秒数
   */
  private scheduleShowModel(token: number, delayMs: number): void {
    setTimeout(() => {
      if (token !== this.actionDialogToken) {
        Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
          + ' scheduleShowModel: token expired, skip');
        return;
      }
      this.actionDialogModelVisible = true;
      Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
        + ' scheduleShowModel: modelVisible=true after ' + delayMs + 'ms');
    }, delayMs);
  }

  private cleanupActionDialog(): void {
    this.actionDialogToken++; // 让所有正在进行的异步回调失效
    // T-4.2G-A3: 诊断日志(关闭时输出本窗口的 Scene/Host 统计)
    Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
      + ' cleanup: sceneAssignments=' + this.sceneAssignmentCount
      + ', hostCreated=' + this.hostCreatedCount
      + ', hostDisposed=' + this.hostDisposedCount
      + ', surfaceStates=[' + this.surfaceRelatedState + ']');
    if (this.actionDialogVm !== null) {
      // 先清空回调,避免 dispose 触发的 onSceneReady(null)/onStateChanged 写入已释放 UI
      this.actionDialogVm.onStateChanged = null;
      this.actionDialogVm.onError = null;
      this.actionDialogVm.onSceneReady = null;
      this.actionDialogVm.onAvatarInfo = null;
      this.actionDialogVm.onPrepareProgress = null;
      this.actionDialogVm.onCalibrationChanged = null;
      this.actionDialogVm.onDisplayModeChanged = null;
      this.actionDialogVm.onSkeletonInfo = null;
      this.actionDialogVm.dispose();
      this.actionDialogVm = null;
    }
    this.actionDialogCard = null;
    this.actionDialogScene = null;
    this.actionDialogState = ActionPreview3DState.Idle;
    this.actionDialogError = '';
    this.actionDialogAvatarName = '';
    this.actionDialogNotice = '';
    this.actionDialogModelVisible = false;
    // 重置诊断计数
    this.sceneAssignmentCount = 0;
    this.hostCreatedCount = 0;
    this.hostDisposedCount = 0;
    this.surfaceRelatedState = '';
    // 重置骨架可视化状态
    this.skeletonDisplayMode = SkeletonDisplayMode.ModelOnly;
    this.skeletonJointCount = 0;
    this.skeletonSegmentCount = 0;
    this.skeletonPoseType = RestPoseType.Unknown;
    this.skeletonConfidence = 0;
    this.skeletonPoseMessage = '';
    this.showSkeletonDetail = false;
    this.showManagePanel = false;
    // T-4.2G-A3: 重置 Debug 模式
    this.skeletonDebugMode = false;
    // T-4.2G-A4: 重置三栏对比模式
    this.sourceTargetCompareMode = false;
    // 重置方向校准状态
    this.orientationCalibration = null;
    this.orientationAnalysis = null;
    this.showOrientationPanel = false;
    this.customYawInput = 0;
    this.customSwapInput = false;
    this.customInvertInput = false;
    this.calibrationApplying = false;
  }

  /**
   * T-4.2G-A2: 打开统一动作详情与管理窗口。
   *
   * 流程:
   * 1. 若已有打开窗口,先 cleanup(递增 token + dispose 旧 VM)
   * 2. 创建新 VM 并注入所有依赖
   * 3. 绑定回调(回调内必须先检查 token 是否仍然有效)
   * 4. 调用 vm.initialize 加载 Avatar + 准备动作
   */
  private async openActionDialog(card: ActionCardItem): Promise<void> {
    // 1. 清理旧窗口(无论是切换动作还是首次打开)
    this.cleanupActionDialog();
    // 2. 设置新卡片 + 新 token + 新 generation
    this.actionDialogCard = card;
    const myToken: number = ++this.actionDialogToken;
    this.dialogGeneration++;
    Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
      + ' openActionDialog: ' + card.id + ', token=' + myToken);
    this.actionDialogState = ActionPreview3DState.Idle;
    this.actionDialogNotice = '正在准备动作……';

    const avatarLibraryService: AvatarLibraryService | null = AppServices.getAvatarLibraryService();
    if (avatarLibraryService === null) {
      Logger.warn(LOG_TAG, 'openActionDialog: AvatarLibraryService null');
      this.actionDialogError = 'Avatar 服务未就绪';
      this.actionDialogState = ActionPreview3DState.Failed;
      return;
    }

    // 3. 创建 VM
    const vm: ActionAvatarPreviewViewModel = new ActionAvatarPreviewViewModel();
    vm.setAvatarLibraryService(avatarLibraryService);
    const char3DService: Character3DService | null = AppServices.getCharacter3DService();
    if (char3DService !== null) {
      vm.setCharacter3DService(char3DService);
    }
    vm.setAppContext(getContext(this) as common.Context);
    vm.setCalibrationStore(AppServices.getAvatarOrientationCalibrationStore());

    // 4. 绑定回调(全部带 token 检查,防止过期回写)
    vm.onStateChanged = (state: ActionPreview3DState): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.actionDialogState = state;
      // T-4.2G-A3: 记录状态变化轨迹(诊断 Surface 重建原因)
      this.surfaceRelatedState += state + '->';
      Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
        + ' onStateChanged: ' + state + ', sceneAssigned=' + this.sceneAssignmentCount);
      switch (state) {
        case ActionPreview3DState.LoadingAvatar:
        case ActionPreview3DState.LoadingMotion:
        case ActionPreview3DState.PreparingRetarget:
          this.actionDialogNotice = '正在准备动作……';
          this.actionDialogModelVisible = false; // 加载中:模型不可见
          break;
        case ActionPreview3DState.Ready:
          this.actionDialogNotice = '就绪';
          // T-4.2G-A3: 延迟 500ms 显示模型,等待 Surface 完全初始化
          // 实测 Surface 创建耗时 67~400ms(Vulkan Swapchain + RSNode 挂载),
          // 120ms 不足以覆盖最坏情况,导致空白方框闪烁。
          // 500ms 覆盖最坏情况,且配合 opacity animation 平滑过渡避免硬切换。
          this.scheduleShowModel(myToken, 500);
          break;
        case ActionPreview3DState.Playing:
          this.actionDialogNotice = '播放中';
          this.actionDialogModelVisible = true; // 播放中:显示模型
          break;
        case ActionPreview3DState.Paused:
          this.actionDialogNotice = '已暂停';
          this.actionDialogModelVisible = true; // 暂停:保持显示
          break;
        case ActionPreview3DState.StaticOnly:
          this.actionDialogNotice = '当前模型无内置动画,仅静态预览';
          this.actionDialogModelVisible = true; // 静态预览:显示模型
          break;
        case ActionPreview3DState.Failed:
          this.actionDialogModelVisible = false; // 失败:隐藏模型,显示错误遮罩
          break;
        default:
          break;
      }
    };
    vm.onError = (message: string): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.actionDialogError = message;
      Logger.error(LOG_TAG, 'openActionDialog error: ' + message);
    };
    vm.onSceneReady = (scene: Scene | null): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      // T-4.2G-A3: Scene 只赋值一次,避免重复赋值导致 Component3D 重建
      // 相同引用不重复赋值;null 不覆盖已赋值的 Scene
      if (scene === null) {
        Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
          + ' onSceneReady(null) ignored, keep existing scene');
        return;
      }
      if (this.actionDialogScene === scene) {
        Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
          + ' onSceneReady same reference ignored');
        return;
      }
      if (this.actionDialogScene !== null) {
        Logger.warn(LOG_TAG, 'dialogGen=' + this.dialogGeneration
          + ' onSceneReady: scene already assigned, refusing re-assignment');
        return;
      }
      this.actionDialogScene = scene;
      this.sceneAssignmentCount++;
      Logger.info(LOG_TAG, 'dialogGen=' + this.dialogGeneration
        + ' onSceneReady: scene assigned, count=' + this.sceneAssignmentCount);
    };
    vm.onAvatarInfo = (displayName: string, _hasAnimation: boolean): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.actionDialogAvatarName = displayName;
    };
    vm.onPrepareProgress = (message: string): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.actionDialogNotice = message;
    };
    vm.onCalibrationChanged = (
      calibration: AvatarOrientationCalibration | null,
      analysis: AvatarOrientationAnalysis | null
    ): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.orientationCalibration = calibration;
      this.orientationAnalysis = analysis;
      if (calibration !== null) {
        this.customYawInput = calibration.yawOffsetDeg;
        this.customSwapInput = calibration.swapLeftRight;
        this.customInvertInput = calibration.invertForward;
      }
    };
    vm.onDisplayModeChanged = (mode: SkeletonDisplayMode): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.skeletonDisplayMode = mode;
    };
    vm.onSkeletonInfo = (
      joints: number,
      segments: number,
      poseType: RestPoseType,
      confidence: number,
      message: string
    ): void => {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      this.skeletonJointCount = joints;
      this.skeletonSegmentCount = segments;
      this.skeletonPoseType = poseType;
      this.skeletonConfidence = confidence;
      this.skeletonPoseMessage = message;
    };

    this.actionDialogVm = vm;

    const actionInfo: PreviewActionInfo = {
      actionId: card.id,
      displayName: card.displayName,
      clipName: card.clipName,
      clipIndex: card.clipIndex,
      loop: card.loop,
      durationMs: card.durationMs
    };
    try {
      await vm.initialize(actionInfo);
    } catch (e) {
      if (myToken !== this.actionDialogToken) {
        return; // 已切换到其他动作或关闭
      }
      Logger.error(LOG_TAG, 'openActionDialog failed: ' + (e as Error)?.message);
      this.actionDialogError = '加载预览失败: ' + (e as Error)?.message;
      this.actionDialogState = ActionPreview3DState.Failed;
    }
  }

  /**
   * T-4.2G-A2: 重试加载当前动作预览(失败后用户点击重试)。
   */
  private async retryActionDialog(): Promise<void> {
    if (this.actionDialogCard === null) {
      return;
    }
    const card: ActionCardItem = this.actionDialogCard;
    await this.openActionDialog(card);
  }

  /**
   * T-4.2G-A2: 关闭统一动作窗口。
   */
  private closeActionDialog(): void {
    this.cleanupActionDialog();
  }

  /**
   * T-4.2G-A2: 在已打开的窗口中切换到另一个动作。
   *
   * 复用当前 VM 与 Avatar Scene,只切换 Clip,避免重新 Scene.load。
   * 若 VM 已 dispose 或 Scene 未就绪,回退到完整 openActionDialog。
   */
  private async switchActionInDialog(card: ActionCardItem): Promise<void> {
    if (this.actionDialogVm === null || this.actionDialogScene === null) {
      await this.openActionDialog(card);
      return;
    }
    // 复用 Scene:更新卡片 + 调用 switchAction
    this.actionDialogCard = card;
    const myToken: number = this.actionDialogToken; // 不递增,Scene 未变
    const actionInfo: PreviewActionInfo = {
      actionId: card.id,
      displayName: card.displayName,
      clipName: card.clipName,
      clipIndex: card.clipIndex,
      loop: card.loop,
      durationMs: card.durationMs
    };
    try {
      await this.actionDialogVm.switchAction(actionInfo);
    } catch (e) {
      if (myToken !== this.actionDialogToken) {
        return;
      }
      Logger.error(LOG_TAG, 'switchActionInDialog failed: ' + (e as Error)?.message);
      this.actionDialogError = '切换动作失败: ' + (e as Error)?.message;
    }
  }

  /**
   * 加载所有数据:模型 + 动作卡片。
   */
  private async loadAllData(): Promise<void> {
    try {
      // 1. 读取当前模型配置
      this.modelConfig = await this.model3DService!.getConfig();
      // 2. 加载模型摘要
      if (this.vm !== null) {
        this.modelSummary = await this.vm.loadModelSummary();
      }
      // 3. 加载所有动作卡片
      await this.loadActionCards();
    } catch (e) {
      this.errorMessage = '加载数据失败: ' + (e as Error)?.message;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 加载所有动作卡片并应用筛选。
   */
  private async loadActionCards(): Promise<void> {
    if (this.vm === null) {
      return;
    }
    const modelId: string = this.modelConfig.displayName;
    this.allCards = await this.vm.loadAllActionCards(modelId, this.includeHidden);
    this.applyFilter();
  }

  /**
   * 应用筛选和搜索。
   */
  private applyFilter(): void {
    if (this.vm === null) {
      this.filteredCards = [];
      this.cardDataSource.setCards(this.filteredCards);
      return;
    }
    this.filteredCards = this.vm.filterActionCards(this.allCards, this.currentFilter, this.searchKeyword);
    this.cardDataSource.setCards(this.filteredCards);
  }

  build(): void {
    NavDestination() {
      Column() {
        this.buildHeader();
        if (this.isLoading) {
          this.buildLoading();
        } else {
          Scroll() {
            Column() {
              this.buildModelCard();
              this.buildFilterChips();
              this.buildActionGrid();
              Blank().height(100);
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8 });
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off);
        }
        // 弹层
        if (this.actionDialogCard !== null) {
          this.buildActionDialog();
        }
        if (this.manageCard !== null) {
          this.buildManageSheet();
        }
        if (this.renameCard !== null) {
          this.buildRenameDialog();
        }
        if (this.deleteConfirmCard !== null) {
          this.buildDeleteConfirmDialog();
        }
        if (this.bindSlotCard !== null) {
          this.buildBindSlotDialog();
        }
        if (this.importPreview !== null) {
          this.buildImportPreviewDialog();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#f5f5f5');
    }
    .hideTitleBar(true);
  }

  // ==================== 顶部标题栏 ====================

  @Builder
  buildHeader(): void {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .fontColor(['#333333'])
        .key('actionManager.back')
        .onClick(() => {
          router.back();
        });
      Text('动作管理')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
        .margin({ left: 8 });
      Blank();
      // 搜索按钮
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(20)
        .fontColor(['#333333'])
        .margin({ right: 12 })
        .key('actionManager.search')
        .onClick(() => {
          this.showSearchInput = !this.showSearchInput;
          if (!this.showSearchInput) {
            this.searchKeyword = '';
            this.applyFilter();
          }
        });
      // 导入动作按钮
      Button('导入动作')
        .fontSize(13)
        .height(32)
        .backgroundColor('#007DFF')
        .fontColor('#ffffff')
        .padding({ left: 12, right: 12 })
        .key('actionManager.importAction')
        .onClick(() => {
          this.onClickImportAction();
        });
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#ffffff')
    .margin({ top: this.statusBarHeight });
  }

  // ==================== 加载中 ====================

  @Builder
  buildLoading(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color('#007DFF');
      Text('加载中...')
        .fontSize(14)
        .fontColor('#666666')
        .margin({ top: 12 });
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center);
  }

  // ==================== 当前模型卡片 ====================

  /**
   * T-3D.6E: 构建模型多维度能力摘要文案。
   *
   * 替代原"兼容: 完全/不兼容"单一显示。
   * 输出示例:
   * - 显示: 可正常显示 | 骨架: 已检测到 | 映射: 需要手动匹配
   * - 显示: 可正常显示 | 骨架: 未检测到 | 动作: 仅静态显示
   */
  private buildModelCapabilitySummary(): string {
    if (this.modelSummary === null || this.modelSummary.capabilityReport === null) {
      // 未导入或无 capabilityReport 时,回退到原 compatibilityLevel 显示
      return '兼容: ' + getCompatibilityLevelDisplayName(this.modelSummary?.compatibilityLevel
        ?? CompatibilityLevel.Unsupported);
    }
    const report: ModelCapabilityReport = this.modelSummary.capabilityReport;
    // 显示状态
    let displayText: string;
    if (report.sceneLoadable === CapabilityState.Supported
      && report.geometryRenderable === CapabilityState.Supported) {
      displayText = '可正常显示';
    } else if (report.sceneLoadable === CapabilityState.PartiallySupported) {
      displayText = '已加载但未定位';
    } else if (report.geometryRenderable === CapabilityState.Unsupported) {
      displayText = '无可渲染几何';
    } else {
      displayText = '引擎无法加载';
    }
    // 骨架状态
    let skeletonText: string;
    if (report.skeletonPresent === CapabilityState.Supported) {
      const jointCount: number = report.skinReport.jointCount > 0
        ? report.skinReport.jointCount : this.modelSummary.nodeCount;
      skeletonText = '骨架: 检测到 ' + jointCount + ' 关节';
    } else if (report.skeletonPresent === CapabilityState.NotPresent) {
      skeletonText = '骨架: 未检测到';
    } else {
      skeletonText = '骨架: 未知';
    }
    // 映射/动作状态
    let mappingText: string;
    if (report.skeletonPresent === CapabilityState.NotPresent) {
      mappingText = '动作: 仅静态显示';
    } else if (report.humanoidManualMapping === HumanoidMappingState.ManualMapped) {
      mappingText = '映射: 已完成手动';
    } else if (report.humanoidAutoMapping === HumanoidMappingState.AutoMapped) {
      mappingText = '映射: 已自动匹配';
    } else if (report.humanoidAutoMapping === HumanoidMappingState.PartiallyMapped) {
      mappingText = '映射: 自动部分成功';
    } else if (report.humanoidAutoMapping === HumanoidMappingState.NeedsManualMapping) {
      mappingText = '映射: 需手动匹配';
    } else {
      mappingText = '映射: ' + getHumanoidMappingStateText(report.humanoidAutoMapping);
    }
    return '显示: ' + displayText + ' | ' + skeletonText + ' | ' + mappingText;
  }

  /**
   * T-3D.6E: 模型能力摘要颜色。
   *
   * - 几何不可用: 红色(模型确实不可用)
   * - 可显示但需配置骨骼: 中性蓝灰(不使用红色"不兼容")
   * - 完全就绪: 绿色
   */
  private getModelCapabilityColor(): string {
    if (this.modelSummary === null || this.modelSummary.capabilityReport === null) {
      return '#666666';
    }
    const report: ModelCapabilityReport = this.modelSummary.capabilityReport;
    if (report.geometryRenderable === CapabilityState.Unsupported
      || report.sceneLoadable === CapabilityState.Unsupported) {
      return '#d9534f'; // 红色:模型确实不可用
    }
    if (report.motionRetargeting === CapabilityState.Supported) {
      return '#28a745'; // 绿色:完全就绪
    }
    return '#6c757d'; // 中性灰:可显示但需配置
  }

  /**
   * T-3D.6E: 预览弹层中的动作匹配状态文案。
   *
   * 替代原"完全兼容/当前模型不兼容"二元显示。
   */
  private getMotionCompatibilityText(): string {
    if (this.modelSummary === null || !this.modelSummary.hasModel) {
      return '未导入模型';
    }
    const report: ModelCapabilityReport | null = this.modelSummary.capabilityReport;
    if (report === null) {
      return '能力报告未生成';
    }
    // 模型不可显示时,动作无法应用
    if (report.geometryRenderable === CapabilityState.Unsupported
      || report.sceneLoadable === CapabilityState.Unsupported) {
      return '模型不可用';
    }
    // 骨架不存在:静态模型,无法应用外部动作
    if (report.skeletonPresent === CapabilityState.NotPresent) {
      return '当前只支持静态显示';
    }
    // 骨架存在,基于映射状态
    return getMotionRetargetingText(report.motionRetargeting);
  }

  /**
   * T-3D.6E: 判断当前模型是否可以应用动作。
   *
   * 仅当 motionRetargeting=Supported 时允许应用。
   * - 自动映射完整 或 手动映射完成 且 几何/Scene 可用
   */
  private canApplyActionToCurrentModel(): boolean {
    if (this.modelSummary === null || !this.modelSummary.hasModel) {
      return false;
    }
    const report: ModelCapabilityReport | null = this.modelSummary.capabilityReport;
    if (report === null) {
      return false;
    }
    return report.sceneLoadable === CapabilityState.Supported
      && report.geometryRenderable === CapabilityState.Supported
      && report.motionRetargeting === CapabilityState.Supported;
  }

  @Builder
  buildModelCard(): void {
    Column() {
      Row() {
        // 模型缩略图占位
        Column() {
          Text('3D')
            .fontSize(20)
            .fontColor('#ffffff')
            .fontWeight(FontWeight.Bold);
        }
        .width(56)
        .height(56)
        .backgroundColor('#007DFF')
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);

        // 模型信息
        Column() {
          if (this.modelSummary !== null && this.modelSummary.hasModel) {
            Text(this.modelSummary.displayName)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Row() {
              Text('骨骼: ' + getSkeletonProfileDisplayName(this.modelSummary.skeletonProfile))
                .fontSize(11)
                .fontColor('#666666');
              Text(' | ')
                .fontSize(11)
                .fontColor('#cccccc');
              Text('动画: ' + this.modelSummary.animationCount)
                .fontSize(11)
                .fontColor('#666666');
            }
            .margin({ top: 4 });
            // T-3D.6E: 多维度能力分层显示(替代原单一"兼容: 完全/不兼容")
            Text(this.buildModelCapabilitySummary())
              .fontSize(11)
              .fontColor(this.getModelCapabilityColor())
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 });
          } else {
            Text('尚未导入 3D 模型')
              .fontSize(14)
              .fontColor('#999999');
            Text('默认动作仍可浏览和预览')
              .fontSize(11)
              .fontColor('#aaaaaa')
              .margin({ top: 4 });
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 });

        // 操作按钮
        Column() {
          Button('导入模型')
            .fontSize(11)
            .height(28)
            .backgroundColor('#28a745')
            .fontColor('#ffffff')
            .padding({ left: 8, right: 8 })
            .key('actionManager.importModel')
            .onClick(() => {
              this.onClickImportModel();
            });
          // T-3D.6E: 配置骨骼入口(仅当模型已导入时显示)
          // T-4.2B: 传入当前激活 avatarId
          if (this.modelSummary !== null && this.modelSummary.hasModel) {
            Button('配置骨骼')
              .fontSize(11)
              .height(28)
              .backgroundColor('#17a2b8')
              .fontColor('#ffffff')
              .padding({ left: 8, right: 8 })
              .margin({ top: 6 })
              .key('actionManager.openHumanoidMapping')
              .onClick(() => {
                this.onClickOpenHumanoidMapping();
              });
          }
        }
        .alignItems(HorizontalAlign.End);
      }
      .width('100%');

      // 提示文案
      Text('默认动作可用于兼容 ArkTavern Humanoid 骨骼的模型。其他人形模型可能需要进行动作适配。')
        .fontSize(10)
        .fontColor('#8a6d3b')
        .margin({ top: 8 })
        .lineHeight(14);
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#ffffff')
    .borderRadius(12);
  }

  // ==================== 筛选 Chip ====================

  @Builder
  buildFilterChips(): void {
    Column() {
      // 搜索输入框
      if (this.showSearchInput) {
        Row() {
          TextInput({ text: this.searchKeyword, placeholder: '搜索动作名称...' })
            .fontSize(13)
            .height(32)
            .backgroundColor('#f0f0f0')
            .borderRadius(16)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.searchKeyword = value;
              this.applyFilter();
            });
          Text('取消')
            .fontSize(13)
            .fontColor('#007DFF')
            .margin({ left: 8 })
            .onClick(() => {
              this.showSearchInput = false;
              this.searchKeyword = '';
              this.applyFilter();
            });
        }
        .width('100%')
        .margin({ bottom: 8 });
      }

      // 筛选 Chip 横向滚动
      Scroll() {
        Row() {
          this.buildFilterChip('全部', ActionFilter.All);
          this.buildFilterChip('内置', ActionFilter.BuiltIn);
          this.buildFilterChip('已导入', ActionFilter.Imported);
          this.buildFilterChip('循环', ActionFilter.Loop);
          this.buildFilterChip('单次', ActionFilter.Once);
          // 隐藏动作切换
          Row() {
            Checkbox()
              .select(this.includeHidden)
              .onChange((checked: boolean) => {
                this.includeHidden = checked;
                this.loadActionCards();
              });
            Text('显示隐藏')
              .fontSize(12)
              .fontColor('#666666');
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor('#f0f0f0')
          .borderRadius(16)
          .margin({ right: 8 });
        }
        .padding({ left: 0, right: 8 });
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(40);
    }
    .width('100%')
    .margin({ top: 12 });
  }

  @Builder
  buildFilterChip(label: string, filter: ActionFilter): void {
    Text(label)
      .fontSize(12)
      .fontColor(this.currentFilter === filter ? '#ffffff' : '#333333')
      .backgroundColor(this.currentFilter === filter ? '#007DFF' : '#f0f0f0')
      .borderRadius(16)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ right: 8 })
      .onClick(() => {
        this.currentFilter = filter;
        this.applyFilter();
      });
  }

  // ==================== 三列动作卡片网格 ====================

  @Builder
  buildActionGrid(): void {
    Column() {
      // 统计信息
      Row() {
        Text('动作(' + this.filteredCards.length + ')')
          .fontSize(13)
          .fontColor('#666666');
        Blank();
        Text(this.includeHidden ? '含隐藏' : '')
          .fontSize(11)
          .fontColor('#999999');
      }
      .width('100%')
      .margin({ top: 12, bottom: 8 });

      if (this.filteredCards.length === 0) {
        Column() {
          Text('暂无动作')
            .fontSize(14)
            .fontColor('#999999');
          Text('内置动作随 App 安装,无需导入')
            .fontSize(11)
            .fontColor('#aaaaaa')
            .margin({ top: 4 });
        }
        .width('100%')
        .padding(40)
        .alignItems(HorizontalAlign.Center);
      } else {
        Grid() {
          LazyForEach(this.cardDataSource, (card: ActionCardItem) => {
            GridItem() {
              this.buildActionCard(card);
            }
          }, (card: ActionCardItem) => card.id + '_' + card.displayName);
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(12)
        .width('100%')
        .layoutWeight(1);
      }
    }
    .width('100%');
  }

  @Builder
  buildActionCard(card: ActionCardItem): void {
    Column() {
      // 预览区域(1:1)
      Stack() {
        // 骨架动画预览 Canvas(T-3D.6C-B: 自管理背景色,高对比度)
        // T-3D.6C-C: 使用 loopMode 解析后的 effectiveLoop
        ActionPreviewCanvas({
          actionId: card.id,
          durationMs: card.durationMs,
          loop: this.getCardEffectiveLoop(card)
        })
        .zIndex(0);

        // 分类色条(顶部细条)
        Column()
          .width('100%')
          .height(3)
          .backgroundColor(this.getCategoryColor(card.category))
          .position({ x: 0, y: 0 })
          .zIndex(1);

        // 时长标记(底部居中)
        Text(this.formatDuration(card.durationMs))
          .fontSize(9)
          .fontColor('rgba(255,255,255,0.85)')
          .backgroundColor('rgba(0,0,0,0.45)')
          .borderRadius(3)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .position({ x: '50%', y: '82%' })
          .translate({ x: '-50%' })
          .zIndex(1);

        // 来源标记(左上角)
        Text(card.isBuiltIn ? '内置' : '导入')
          .fontSize(9)
          .fontColor('#ffffff')
          .backgroundColor(card.isBuiltIn ? 'rgba(0,125,255,0.7)' : 'rgba(40,167,69,0.7)')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          .position({ x: 4, y: 6 })
          .zIndex(1);

        // T-4.2G-A1: 源动作示意标记(左下角,说明此为源动作示意,非目标 Avatar 真实结果)
        Text('源动作示意')
          .fontSize(8)
          .fontColor('rgba(255,255,255,0.85)')
          .backgroundColor('rgba(0,0,0,0.45)')
          .borderRadius(3)
          .padding({ left: 3, right: 3, top: 1, bottom: 1 })
          .position({ x: 4, y: '78%' })
          .zIndex(1);

        // 循环标记(右上角)— T-3D.6C-C: 使用 effectiveLoop
        if (this.getCardEffectiveLoop(card)) {
          Text('循环')
            .fontSize(9)
            .fontColor('#ffffff')
            .backgroundColor('rgba(255,152,0,0.7)')
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .position({ x: '68%', y: 6 })
            .zIndex(1);
        }

        // 选中边框
        if (this.selectedCardId === card.id) {
          Column()
            .width('100%')
            .height('100%')
            .border({ width: 2, color: '#007DFF' })
            .borderRadius({ topLeft: 12, topRight: 12 })
            .zIndex(1);
        }

        // 绑定标记(左下角)
        if (card.boundSlot !== null) {
          Text('已绑定')
            .fontSize(9)
            .fontColor('#ffffff')
            .backgroundColor('rgba(156,39,176,0.7)')
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .position({ x: 4, y: '70%' })
            .zIndex(1);
        }
      }
      .width('100%')
      .aspectRatio(1);

      // 名称区域
      Column() {
        Text(card.displayName)
          .fontSize(12)
          .fontColor('#333333')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontWeight(this.selectedCardId === card.id ? FontWeight.Medium : FontWeight.Normal);
        if (card.hidden) {
          Text('(已隐藏)')
            .fontSize(9)
            .fontColor('#999999');
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 6, bottom: 6 })
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#ffffff')
      .borderRadius({ bottomLeft: 12, bottomRight: 12 });
    }
    .width('100%')
    .borderRadius(12)
    .clip(true)
    .key('actionManager.card.' + card.id)
    .onClick(() => {
      this.onClickCard(card);
    })
    .gesture(
      LongPressGesture({ duration: 300 })
        .onAction(() => {
          this.onLongPressCard(card);
        })
    );
  }

  /**
   * 获取分类颜色。
   */
  private getCategoryColor(category: ActionCategory): string {
    switch (category) {
      case ActionCategory.Base: return '#5c6bc0';
      case ActionCategory.Social: return '#26a69a';
      case ActionCategory.Emotion: return '#ec407a';
      case ActionCategory.Reaction: return '#ff7043';
      default: return '#78909c';
    }
  }

  /**
   * 获取分类图标(emoji 简单表示)。
   */
  private getCategoryIcon(category: ActionCategory): string {
    switch (category) {
      case ActionCategory.Base: return '🧍';
      case ActionCategory.Social: return '👋';
      case ActionCategory.Emotion: return '😊';
      case ActionCategory.Reaction: return '🎉';
      default: return '📦';
    }
  }

  /**
   * 格式化时长。
   */
  private formatDuration(ms: number): string {
    const seconds: number = ms / 1000;
    return seconds.toFixed(1) + 's';
  }

  // ==================== 信息行 Builder(供导入预览对话框使用) ====================

  @Builder
  buildPreviewInfoRow(label: string, value: string): void {
    Row() {
      Text(label + ':')
        .fontSize(12)
        .fontColor('#666666')
        .width(60);
      Text(value)
        .fontSize(12)
        .fontColor('#333333')
        .layoutWeight(1);
    }
    .width('100%')
    .margin({ bottom: 4 });
  }

  private getCategoryDisplayName(category: ActionCategory): string {
    switch (category) {
      case ActionCategory.Base: return '基础';
      case ActionCategory.Social: return '社交';
      case ActionCategory.Emotion: return '情绪';
      case ActionCategory.Reaction: return '反应';
      default: return '其他';
    }
  }

  // ==================== 管理菜单(长按) ====================

  @Builder
  buildManageSheet(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.manageCard = null;
        });

      Column() {
        Text(this.manageCard!.displayName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 4 });
        Text('长按菜单 · 仅快速操作(预览/详情/循环请单击卡片)')
          .fontSize(11)
          .fontColor('#999999')
          .margin({ bottom: 12 });

        // 重命名(打开重命名窗口,内置"恢复默认名称"按钮)
        this.buildManageMenuItem('重命名显示名称', () => {
          this.onClickRenameFromManage();
        });
        // 绑定动作槽位
        this.buildManageMenuItem('绑定动作槽位', () => {
          const card: ActionCardItem = this.manageCard!;
          this.manageCard = null;
          this.bindSlotCard = card;
        });
        // 隐藏此动作(仅内置)
        if (this.manageCard!.isBuiltIn) {
          if (this.manageCard!.hidden) {
            this.buildManageMenuItem('取消隐藏', () => {
              this.onClickToggleHide(false);
            });
          } else {
            this.buildManageMenuItem('隐藏此动作', () => {
              this.onClickToggleHide(true);
            });
          }
        }
        // 删除动作(仅导入)
        if (!this.manageCard!.isBuiltIn) {
          this.buildManageMenuItem('删除动作', () => {
            const card: ActionCardItem = this.manageCard!;
            this.manageCard = null;
            this.deleteConfirmCard = card;
          }, '#cc0000');
        }

        // 取消
        Button('取消')
          .fontSize(14)
          .height(40)
          .width('100%')
          .backgroundColor('#f0f0f0')
          .fontColor('#333333')
          .margin({ top: 12 })
          .onClick(() => {
            this.manageCard = null;
          });
      }
      .width('85%')
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .padding(20);
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center);
  }

  @Builder
  buildManageMenuItem(label: string, action: () => void, color: string = '#333333'): void {
    Text(label)
      .fontSize(14)
      .fontColor(color)
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .textAlign(TextAlign.Center)
      .onClick(() => {
        action();
      });
  }

  // ==================== T-3D.6C-C: 动作详情 Sheet(含循环设置) ====================

  /**
   * 当前详情卡片的默认循环标签。
   */
  private getDefaultLoopLabel(card: ActionCardItem): string {
    return card.loop ? '循环播放' : '播放一次';
  }

  /**
   * 当前详情卡片的循环模式标签。
   */
  private getLoopModeLabel(mode: ActionLoopMode): string {
    if (this.vm === null) {
      return '跟随默认';
    }
    return this.vm.getLoopModeLabel(mode);
  }

  /**
   * T-4.2G-A2: 统一动作详情与管理窗口(合并原 previewDialog + detailsSheet)。
   *
   * 布局结构:
   * - 标题栏(固定):动作名 + 关闭按钮 + 模型名 + 来源/槽位状态
   * - 滚动内容区:
   *   A. 3D 预览区域(状态标签 + ActionAvatarPreview3D)
   *   B. 常用设置(循环方式 / 动作槽位 / 显示模式)
   *   C. 基础信息(紧凑)
   *   D. 骨架信息(折叠,默认摘要一行)
   *   E. 方向校准(折叠)
   *   F. 动作管理(折叠,底部)
   * - 底部关闭按钮(固定)
   */
  @Builder
  buildActionDialog(): void {
    Stack() {
      // 背景遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.closeActionDialog();
        });

      // ===== 弹窗主体: 上(预览固定) + 下(信息滚动) =====
      Column() {
        // ----- A. 标题栏(固定) -----
        Row() {
          Column() {
            Text(this.actionDialogCard!.displayName)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#333333')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Row() {
              Text('模型: ')
                .fontSize(11)
                .fontColor('#999999');
              Text(this.actionDialogAvatarName.length > 0
                ? this.actionDialogAvatarName : '未选择')
                .fontSize(11)
                .fontColor('#666666')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
              Text(' | ' + this.getActionDialogStatusText())
                .fontSize(11)
                .fontColor('#888888');
            }
            .width('100%')
            .margin({ top: 2 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          Text('✕')
            .fontSize(18)
            .fontColor('#999999')
            .padding(8)
            .key('actionDetail.close')
            .onClick(() => {
              this.closeActionDialog();
            });
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 12, bottom: 8 });

        // ----- B. 3D 预览区域(固定高度,固定结构,绝不在运行时改变) -----
        // T-4.2G-A3: 直接渲染 Component3D,用 if 包裹确保 scene 非 null 时才创建
        // 父组件其他状态变化不会触发 Component3D 重建(ArkUI diff 算法保证)
        // T-4.2G-A3: opacity 使用 animation 平滑过渡(200ms EaseOut),
        // 避免延迟显示时硬切换造成的视觉突兀。
        // T-4.2G-A2 统一姿势:
        // - ModelOnly/ModelWithSkeleton/SkeletonOnly: 显示 Component3D
        // - SourceActionPreview: 隐藏 Component3D,显示 2D 源动作卡片
        Stack() {
          // 底层: Component3D(scene 非 null 时创建,之后不重建)
          // SourceActionPreview 模式下 opacity=0,但 scene 引用不变,不重建 Surface
          if (this.actionDialogScene !== null) {
            Component3D({
              scene: this.actionDialogScene as Scene,
              modelType: ModelType.SURFACE
            })
              .width('100%')
              .height('100%')
              .opacity((this.actionDialogModelVisible
                && this.skeletonDisplayMode !== SkeletonDisplayMode.SourceActionPreview) ? 1 : 0)
              .animation({ duration: 200, curve: Curve.EaseOut, delay: 0 });
          }

          // T-4.2G-A2: "源动作示意"模式 - 渲染 2D ActionPreviewCanvas 卡片
          // 明确标注为"源动作示意",不得称为当前模型骨架
          if (this.skeletonDisplayMode === SkeletonDisplayMode.SourceActionPreview
            && this.actionDialogCard !== null) {
            Column() {
              Text('源动作示意')
                .fontSize(11)
                .fontColor('#ffcc00')
                .backgroundColor('rgba(0,0,0,0.7)')
                .borderRadius(8)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .margin({ top: 8 });
              Stack() {
                ActionPreviewCanvas({
                  actionId: this.actionDialogCard.id,
                  durationMs: this.actionDialogCard.durationMs,
                  loop: this.getCardEffectiveLoop(this.actionDialogCard)
                });
              }
              .width('80%')
              .layoutWeight(1)
              .margin({ top: 8, bottom: 8 })
              .backgroundColor('#2a2a2a')
              .borderRadius(8);

              Text('此骨架展示动作源语义,不代表当前模型的默认姿势。')
                .fontSize(10)
                .fontColor('#aaaaaa')
                .textAlign(TextAlign.Center)
                .padding({ left: 12, right: 12, bottom: 8 });
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#1a1a1a');
          }

          // 加载遮罩(兄弟节点,不替换 Component3D)
          if (!this.actionDialogModelVisible && this.actionDialogState !== ActionPreview3DState.Failed
            && this.skeletonDisplayMode !== SkeletonDisplayMode.SourceActionPreview) {
            Column() {
              LoadingProgress()
                .width(40)
                .height(40)
                .color('#007DFF');
              Text(this.actionDialogNotice.length > 0 ? this.actionDialogNotice : '加载中...')
                .fontSize(13)
                .fontColor('#ffffff')
                .margin({ top: 8 });
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#1a1a1a');
          }

          // 错误遮罩
          if (this.actionDialogState === ActionPreview3DState.Failed) {
            Column() {
              Text('⚠')
                .fontSize(40)
                .fontColor('#ff9800');
              Text(this.actionDialogError.length > 0 ? this.actionDialogError : '预览加载失败')
                .fontSize(12)
                .fontColor('#ffffff')
                .margin({ top: 6, bottom: 10 })
                .textAlign(TextAlign.Center);
              Button('重试')
                .fontSize(12)
                .height(30)
                .backgroundColor('#007DFF')
                .fontColor('#ffffff')
                .onClick(() => { this.retryActionDialog(); });
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#1a1a1a');
          }

          // 状态标签(右上角悬浮)
          Text(this.actionDialogNotice.length > 0 ? this.actionDialogNotice : '就绪')
            .fontSize(10)
            .fontColor('#ffffff')
            .backgroundColor('rgba(0,0,0,0.6)')
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .position({ x: '70%', y: 8 });

          // 简短辅助说明(左下角悬浮,根据显示模式切换文案)
          Text(this.getSkeletonModeHint())
            .fontSize(10)
            .fontColor('#cccccc')
            .backgroundColor('rgba(0,0,0,0.5)')
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .position({ x: 8, y: '85%' });
        }
        .width('100%')
        .height('45%')
        .backgroundColor('#1a1a1a')
        .borderRadius({ topLeft: 12, topRight: 12 });

        // ----- C. 播放控制(固定) -----
        Row() {
          Button(this.actionDialogState === ActionPreview3DState.Playing ? '暂停' : '播放')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor(this.actionDialogState === ActionPreview3DState.Playing ? '#ff9800' : '#007DFF')
            .fontColor('#ffffff')
            .margin({ right: 4 })
            .key('actionDetail.play')
            .onClick(() => {
              if (this.actionDialogState === ActionPreview3DState.Playing) {
                this.actionDialogVm?.pause();
              } else {
                this.actionDialogVm?.play();
              }
            });
          Button('重播')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#28a745')
            .fontColor('#ffffff')
            .margin({ left: 4, right: 4 })
            .key('actionDetail.replay')
            .onClick(() => { this.actionDialogVm?.replay(); });
          Button('停止')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#6c757d')
            .fontColor('#ffffff')
            .margin({ left: 4, right: 4 })
            .key('actionDetail.stop')
            .onClick(() => { this.actionDialogVm?.stop(); });
          if (this.canApplyActionToCurrentModel()) {
            Button('应用')
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .backgroundColor('#17a2b8')
              .fontColor('#ffffff')
              .margin({ left: 4 })
              .key('actionDetail.apply')
              .onClick(() => { this.onClickApplyAction(); });
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 });

        // ----- D. 滚动信息区(常用设置/基础信息/骨架/方向/管理) -----
        Scroll() {
          Column() {
            // D.1 常用设置(循环方式/动作槽位/显示模式)
            this.buildCommonSettingsSection();
            // D.2 基础信息(ID/Clip/时长/来源/分类/骨骼/兼容性/默认循环/当前槽位)
            this.buildBasicInfoSection();
            // D.3 骨架信息(折叠:摘要一行;展开:关节数/骨段数/姿态分类/置信度/诊断信息)
            this.buildSkeletonInfoSection();
            // D.4 方向校准(折叠:当前模式+置信度;展开:6种模式+Custom参数+候选评分)
            this.buildOrientationSection();
            // D.5 动作管理(折叠:重命名/恢复名称/绑定槽位/隐藏/删除)
            this.buildManagePanelSection();
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 8, right: 8, bottom: 8 });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Start);

        // ----- E. 底部固定关闭按钮 -----
        Button('关闭')
          .fontSize(14)
          .height(40)
          .width('100%')
          .backgroundColor('#007DFF')
          .fontColor('#ffffff')
          .key('actionDetail.bottomClose')
          .onClick(() => {
            this.closeActionDialog();
          });
      }
      .width('92%')
      .height('88%')
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .clip(true);
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center);
  }

  /**
   * 统一窗口"状态"列文案。
   * 优先显示当前槽位与来源。
   */
  private getActionDialogStatusText(): string {
    if (this.actionDialogCard === null) {
      return '';
    }
    const card: ActionCardItem = this.actionDialogCard!;
    const sourceText: string = card.isBuiltIn ? '内置' : '导入';
    if (card.boundSlot !== null) {
      const slotInfo: ActionSlotInfo | null = this.findSlotInfo(card.boundSlot);
      if (slotInfo !== null) {
        return sourceText + ' · 槽位 ' + slotInfo.displayName;
      }
    }
    return sourceText;
  }

  /**
   * 统一窗口状态文案颜色。
   */
  private getActionDialogNoticeColor(): string {
    if (this.actionDialogState === ActionPreview3DState.Failed) {
      return '#d9534f';
    }
    if (this.actionDialogState === ActionPreview3DState.Playing) {
      return '#28a745';
    }
    if (this.actionDialogState === ActionPreview3DState.Paused) {
      return '#ff9800';
    }
    return '#666666';
  }

  /**
   * 查找槽位信息(用于状态文案与槽位选择器)。
   */
  private findSlotInfo(slot: string): ActionSlotInfo | null {
    for (let i: number = 0; i < this.slotInfos.length; i++) {
      if (String(this.slotInfos[i].slot) === slot) {
        return this.slotInfos[i];
      }
    }
    return null;
  }

  // ==================== 统一窗口:常用设置区 ====================

  /**
   * T-4.2G-A2: 常用设置区(直接显示不折叠)。
   *
   * 包含:
   * - 循环方式(跟随默认/循环播放/播放一次,显示默认值与当前设置)
   * - 动作槽位(显示当前槽位,点击打开槽位选择器)
   * - 显示模式(仅模型/模型+骨架/仅骨架/源动作示意)
   */
  @Builder
  buildCommonSettingsSection(): void {
    Column() {
      Text('常用设置')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
        .margin({ top: 12, bottom: 8 });

      // ----- 循环方式 -----
      Row() {
        Text('默认: ' + this.getDefaultLoopLabel(this.actionDialogCard!)
          + '    当前: ' + this.getLoopModeLabel(this.actionDialogCard!.loopMode))
          .fontSize(11)
          .fontColor('#888888')
          .layoutWeight(1);
      }
      .width('100%')
      .margin({ bottom: 6 });

      Row() {
        this.buildLoopModeChip('跟随默认', ActionLoopMode.UseDefault);
        this.buildLoopModeChip('循环播放', ActionLoopMode.Loop);
        this.buildLoopModeChip('播放一次', ActionLoopMode.PlayOnce);
      }
      .width('100%');

      // ----- 动作槽位 -----
      Divider().color('#f0f0f0').margin({ top: 10, bottom: 8 });

      Row() {
        Text('动作槽位')
          .fontSize(13)
          .fontColor('#333333')
          .layoutWeight(1);
        Text(this.getSlotDisplayText(this.actionDialogCard!.boundSlot))
          .fontSize(12)
          .fontColor('#007DFF')
          .onClick(() => {
            if (this.actionDialogCard !== null) {
              this.bindSlotCard = this.actionDialogCard;
            }
          });
      }
      .width('100%');

      // ----- 显示模式 -----
      Divider().color('#f0f0f0').margin({ top: 10, bottom: 8 });

      Text('显示模式')
        .fontSize(13)
        .fontColor('#333333')
        .margin({ bottom: 6 });

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(getAllSkeletonDisplayModes(), (info: SkeletonDisplayModeInfo) => {
          Button(info.label)
            .fontSize(11)
            .height(30)
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.skeletonDisplayMode === info.mode ? '#007DFF' : '#f0f0f0')
            .fontColor(this.skeletonDisplayMode === info.mode ? '#ffffff' : '#333333')
            .key('actionDetail.displayMode.' + info.mode)
            .onClick(() => {
              this.actionDialogVm?.setDisplayMode(info.mode);
            });
        })
      }
      .width('100%');
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#fafafa')
    .borderRadius(8)
    .margin({ top: 8 });
  }

  /**
   * 循环方式单选项(紧凑 chip)。
   */
  @Builder
  buildLoopModeChip(label: string, mode: ActionLoopMode): void {
    Text(label)
      .fontSize(11)
      .fontColor(this.actionDialogCard!.loopMode === mode ? '#ffffff' : '#333333')
      .backgroundColor(this.actionDialogCard!.loopMode === mode ? '#007DFF' : '#e8e8e8')
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .margin({ right: 6 })
      .key('actionDetail.loopMode.' + mode)
      .onClick(() => {
        this.onClickSetLoopMode(mode);
      });
  }

  /**
   * 获取槽位显示文本。
   */
  private getSlotDisplayText(slot: string | null): string {
    if (slot === null || slot.length === 0) {
      return '未绑定(点击选择)';
    }
    const slotInfo: ActionSlotInfo | null = this.findSlotInfo(slot);
    return slotInfo !== null ? slotInfo.displayName : slot;
  }

  // ==================== 统一窗口:基础信息区 ====================

  /**
   * T-4.2G-A2: 基础信息区(紧凑展示)。
   */
  @Builder
  buildBasicInfoSection(): void {
    Column() {
      Text('基础信息')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
        .margin({ top: 12, bottom: 6 });

      this.buildCompactInfoRow('ID', this.actionDialogCard!.id);
      this.buildCompactInfoRow('Clip', this.actionDialogCard!.clipName);
      this.buildCompactInfoRow('时长', this.formatDuration(this.actionDialogCard!.durationMs));
      this.buildCompactInfoRow('来源', this.actionDialogCard!.isBuiltIn ? '内置' : '导入');
      this.buildCompactInfoRow('分类', this.getCategoryDisplayName(this.actionDialogCard!.category));
      this.buildCompactInfoRow('骨骼', getSkeletonProfileDisplayName(this.actionDialogCard!.skeletonProfile));
      this.buildCompactInfoRow('兼容性', getCompatibilityLevelDisplayName(this.actionDialogCard!.compatibilityLevel));
      this.buildCompactInfoRow('默认循环', this.getDefaultLoopLabel(this.actionDialogCard!));
      this.buildCompactInfoRow('当前槽位', this.getSlotDisplayText(this.actionDialogCard!.boundSlot));
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#fafafa')
    .borderRadius(8)
    .margin({ top: 8 });
  }

  /**
   * 紧凑信息行(避免行间距过大)。
   */
  @Builder
  buildCompactInfoRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#999999')
        .width(72);
      Text(value)
        .fontSize(12)
        .fontColor('#333333')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .margin({ bottom: 3 });
  }

  // ==================== 统一窗口:骨架信息区(折叠) ====================

  /**
   * T-4.2G-A2: 骨架信息区(默认折叠,正常用户只看摘要)。
   *
   * 折叠时:T Pose · 置信度 95%
   * 展开后:关节数/骨段数/Rest Pose 分类/置信度/详细角度
   */
  @Builder
  buildSkeletonInfoSection(): void {
    Column() {
      Row() {
        Text('骨架信息')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .layoutWeight(1);
        Text(this.showSkeletonDetail ? '收起' : '展开')
          .fontSize(12)
          .fontColor('#007DFF')
          .onClick(() => {
            this.showSkeletonDetail = !this.showSkeletonDetail;
          });
      }
      .width('100%');

      // 摘要(始终显示一行)
      Text(this.getSkeletonSummaryText())
        .fontSize(12)
        .fontColor('#666666')
        .margin({ top: 4 });

      // 详情(展开时显示)
      if (this.showSkeletonDetail) {
        Divider().color('#f0f0f0').margin({ top: 8, bottom: 6 });
        this.buildCompactInfoRow('关节数', this.skeletonJointCount.toString());
        this.buildCompactInfoRow('骨段数', this.skeletonSegmentCount.toString());
        this.buildCompactInfoRow('姿态分类', this.getPoseTypeLabel(this.skeletonPoseType));
        this.buildCompactInfoRow('置信度', (this.skeletonConfidence * 100).toFixed(0) + '%');
        if (this.skeletonPoseMessage.length > 0) {
          Text(this.skeletonPoseMessage)
            .fontSize(11)
            .fontColor('#888888')
            .margin({ top: 4 });
        }

        // T-4.2G-A3: Debug 红绿点可视化(仅 IS_DEV_BUILD 显示)
        // 红色球(较大)= avatarBoneWorld
        // 绿色球(较小) = jointNode 实际渲染位置
        // 黄色线 = 误差连线
        if (IS_DEV_BUILD) {
          Divider().color('#f0f0f0').margin({ top: 8, bottom: 6 });
          Row() {
            Text('Debug 红绿点')
              .fontSize(12)
              .fontColor('#cc3366')
              .layoutWeight(1);
            Toggle({ type: ToggleType.Switch, isOn: this.skeletonDebugMode })
              .selectedColor('#cc3366')
              .key('actionDetail.debugToggle')
              .onChange((on: boolean) => {
                this.skeletonDebugMode = on;
                this.actionDialogVm?.setSkeletonDebugMode(on);
              });
          }
          .width('100%');

          // 手动触发一次三组坐标对齐诊断输出
          Button('触发坐标诊断')
            .fontSize(11)
            .fontColor('#ffffff')
            .backgroundColor('#cc3366')
            .height(28)
            .key('actionDetail.triggerDiagBtn')
            .margin({ top: 6 })
            .onClick(() => {
              this.actionDialogVm?.triggerSkeletonDiagnostic();
            });

          Text('红=avatarWorld  绿=jointWorld  黄=误差线')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 4 });

          // T-4.2G-A4: 三栏对比可视化(源 Rest 灰 / 源动画 蓝 / 目标重定向 绿)
          Divider().color('#f0f0f0').margin({ top: 10, bottom: 6 });
          Row() {
            Text('Debug 三栏对比')
              .fontSize(12)
              .fontColor('#cc3366')
              .layoutWeight(1);
            Toggle({ type: ToggleType.Switch, isOn: this.sourceTargetCompareMode })
              .selectedColor('#cc3366')
              .key('actionDetail.compareToggle')
              .onChange((on: boolean) => {
                this.sourceTargetCompareMode = on;
                this.actionDialogVm?.setSourceTargetCompareMode(on);
              });
          }
          .width('100%');

          // 手动触发 Source/Target 重定向基准诊断
          Button('触发基准诊断')
            .fontSize(11)
            .fontColor('#ffffff')
            .backgroundColor('#cc3366')
            .height(28)
            .key('actionDetail.triggerBaselineBtn')
            .margin({ top: 6 })
            .onClick(() => {
              this.actionDialogVm?.triggerSourceTargetDiagnostic();
            });

          Text('灰=源Rest  蓝=源动画  绿=目标重定向')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 4 });
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#fafafa')
    .borderRadius(8)
    .margin({ top: 8 });
  }

  /**
   * 骨架摘要文案(正常用户只看此行)。
   */
  private getSkeletonSummaryText(): string {
    if (this.skeletonJointCount === 0 && this.skeletonSegmentCount === 0) {
      return '未加载骨架信息';
    }
    return this.getPoseTypeLabel(this.skeletonPoseType)
      + ' · 置信度 ' + (this.skeletonConfidence * 100).toFixed(0) + '%';
  }

  // ==================== 统一窗口:方向校准区(折叠) ====================

  /**
   * T-4.2G-A2: 方向校准区(默认折叠)。
   *
   * 折叠状态:方向校准 | 当前:正常(自动) | 置信度:高
   * 展开后:模式选择 + (Custom 模式下)Yaw/Swap/Invert 调整
   */
  @Builder
  buildOrientationSection(): void {
    Column() {
      Row() {
        Text('方向校准')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .layoutWeight(1);
        Text(this.showOrientationPanel ? '收起' : '展开')
          .fontSize(12)
          .fontColor('#007DFF')
          .onClick(() => {
            this.showOrientationPanel = !this.showOrientationPanel;
          });
      }
      .width('100%')
      .key('actionDetail.orientationToggle');

      // 摘要(始终显示)
      this.buildCalibrationSummary();

      // 展开:模式选择 + Custom 模式参数
      if (this.showOrientationPanel) {
        Divider().color('#f0f0f0').margin({ top: 8, bottom: 8 });
        this.buildOrientationCalibrationPanel();
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#fafafa')
    .borderRadius(8)
    .margin({ top: 8 });
  }

  // ==================== 统一窗口:动作管理区(底部折叠) ====================

  /**
   * T-4.2G-A2: 动作管理区(底部折叠)。
   *
   * 内容:
   * - 重命名显示名称(打开重命名窗口)
   * - 恢复默认名称(仅已重命名的内置动作显示)
   * - 绑定或更改动作槽位(打开槽位选择器)
   * - 隐藏此动作(内置动作可隐藏)
   * - 删除自定义动作(仅导入动作显示)
   */
  @Builder
  buildManagePanelSection(): void {
    Column() {
      Row() {
        Text('动作管理')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .layoutWeight(1);
        Text(this.showManagePanel ? '收起' : '展开')
          .fontSize(12)
          .fontColor('#007DFF')
          .onClick(() => {
            this.showManagePanel = !this.showManagePanel;
          });
      }
      .width('100%');

      if (this.showManagePanel) {
        Divider().color('#f0f0f0').margin({ top: 8, bottom: 8 });

        // 重命名显示名称
        this.buildManagePanelItem('重命名显示名称', () => {
          if (this.actionDialogCard !== null) {
            this.renameText = this.actionDialogCard!.displayName;
            this.renameCard = this.actionDialogCard;
          }
        });

        // 恢复默认名称(仅当 displayName 与 defaultDisplayName 不同时显示)
        if (this.actionDialogCard !== null
          && this.actionDialogCard!.isBuiltIn
          && this.actionDialogCard!.defaultDisplayName.length > 0
          && this.actionDialogCard!.displayName !== this.actionDialogCard!.defaultDisplayName) {
          this.buildManagePanelItem('恢复默认名称', () => {
            this.onClickResetNameFromDialog();
          });
        }

        // 绑定或更改动作槽位
        this.buildManagePanelItem('绑定或更改动作槽位', () => {
          if (this.actionDialogCard !== null) {
            this.bindSlotCard = this.actionDialogCard;
          }
        });

        // 隐藏此动作(仅内置动作)
        if (this.actionDialogCard !== null && this.actionDialogCard!.isBuiltIn) {
          if (this.actionDialogCard!.hidden) {
            this.buildManagePanelItem('取消隐藏', () => {
              this.onClickToggleHideFromDialog(false);
            });
          } else {
            this.buildManagePanelItem('隐藏此动作', () => {
              this.onClickToggleHideFromDialog(true);
            });
          }
        }

        // 删除自定义动作(仅导入动作)
        if (this.actionDialogCard !== null && !this.actionDialogCard!.isBuiltIn) {
          this.buildManagePanelItem('删除自定义动作', () => {
            if (this.actionDialogCard !== null) {
              this.deleteConfirmCard = this.actionDialogCard;
            }
          }, '#cc0000');
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#fafafa')
    .borderRadius(8)
    .margin({ top: 8, bottom: 8 });
  }

  /**
   * 管理面板单行项。
   */
  @Builder
  buildManagePanelItem(label: string, action: () => void, color: string = '#333333'): void {
    Text(label)
      .fontSize(13)
      .fontColor(color)
      .width('100%')
      .padding({ top: 10, bottom: 10, left: 12, right: 12 })
      .borderRadius(6)
      .backgroundColor('#ffffff')
      .margin({ bottom: 4 })
      .onClick(() => {
        action();
      });
  }

  /**
   * T-4.2G-A2: 从统一窗口触发"恢复默认名称"。
   */
  private async onClickResetNameFromDialog(): Promise<void> {
    if (this.actionDialogCard === null || this.vm === null) {
      return;
    }
    const actionId: string = this.actionDialogCard!.id;
    const ok: boolean = await this.vm.resetBuiltinActionName(actionId);
    if (ok) {
      promptAction.showToast({ message: '已恢复默认名称', duration: 1500 });
      await this.loadActionCards();
      // 同步更新当前窗口的卡片引用
      const updated: ActionCardItem | null = this.findUpdatedCard(actionId);
      if (updated !== null) {
        this.actionDialogCard = updated;
      }
    } else {
      promptAction.showToast({ message: '恢复失败', duration: 2000 });
    }
  }

  /**
   * T-4.2G-A2: 从统一窗口触发"隐藏/取消隐藏"。
   */
  private async onClickToggleHideFromDialog(hidden: boolean): Promise<void> {
    if (this.actionDialogCard === null || this.vm === null) {
      return;
    }
    const actionId: string = this.actionDialogCard!.id;
    // 二次确认
    promptAction.showDialog({
      message: hidden ? '确认隐藏此动作?' : '确认取消隐藏此动作?',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '确认', color: '#007DFF' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.doToggleHideFromDialog(actionId, hidden);
      }
    });
  }

  private async doToggleHideFromDialog(actionId: string, hidden: boolean): Promise<void> {
    if (this.vm === null) {
      return;
    }
    const ok: boolean = await this.vm.setBuiltinActionHidden(actionId, hidden);
    if (ok) {
      promptAction.showToast({
        message: hidden ? '已隐藏' : '已取消隐藏',
        duration: 1500
      });
      await this.loadActionCards();
      const updated: ActionCardItem | null = this.findUpdatedCard(actionId);
      if (updated !== null) {
        this.actionDialogCard = updated;
      }
    } else {
      promptAction.showToast({ message: '操作失败', duration: 2000 });
    }
  }

  /**
   * 根据动作 ID 在最新加载的卡片列表中查找对应项。
   * 用于窗口内操作后同步 actionDialogCard 引用。
   */
  private findUpdatedCard(actionId: string): ActionCardItem | null {
    for (let i: number = 0; i < this.allCards.length; i++) {
      if (this.allCards[i].id === actionId) {
        return this.allCards[i];
      }
    }
    return null;
  }

  // ==================== T-4.2G: 方向校准 UI ====================

  /**
   * T-4.2G: 校准摘要(始终显示,简短一行)。
   *
   * 显示:当前模式 + 置信度 + 简短理由。
   */
  @Builder
  buildCalibrationSummary(): void {
    if (this.orientationCalibration === null) {
      Text('方向校准:未加载')
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 4, bottom: 4 });
    } else {
      Column() {
        Row() {
          Text('当前: ' + this.getOrientationModeDisplayName(this.orientationCalibration!.mode)
            + (this.orientationCalibration!.mode === AvatarOrientationMode.Auto ? '(自动)' : '(手动)'))
            .fontSize(12)
            .fontColor('#333333')
            .layoutWeight(1);
          Text('置信度: ' + this.getConfidenceDisplayName(this.orientationCalibration!.autoConfidence))
            .fontSize(11)
            .fontColor(this.getConfidenceColor(this.orientationCalibration!.autoConfidence));
        }
        .width('100%')
        .margin({ top: 4, bottom: 4 });

        if (this.orientationAnalysis !== null) {
          Text('理由: ' + this.orientationAnalysis!.reasonCode)
            .fontSize(11)
            .fontColor('#888888')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 4 });
        }
      }
      .width('100%');
    }
  }

  /**
   * T-4.2G: 方向校准面板(展开时显示)。
   *
   * 包含:
   * - 模式选择(Auto / Normal / RotateY180 / MirrorLeftRight / MirrorLeftRightAndRotateY180 / Custom)
   * - 模型朝向 Yaw 调整(仅 Custom 模式)
   * - 高级选项:交换左右骨骼 / 反转 Forward(仅 Custom 模式)
   * - 恢复自动检测 / 恢复默认按钮
   */
  @Builder
  buildOrientationCalibrationPanel(): void {
    Column() {
      // 模式选择标题
      Text('方向模式')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
        .margin({ top: 8, bottom: 6 });

      // 模式选项(单选)
      this.buildOrientationModeOption('自动检测', AvatarOrientationMode.Auto);
      this.buildOrientationModeOption('正常', AvatarOrientationMode.Normal);
      this.buildOrientationModeOption('前后旋转 180°', AvatarOrientationMode.RotateY180);
      this.buildOrientationModeOption('左右镜像', AvatarOrientationMode.MirrorLeftRight);
      this.buildOrientationModeOption('左右镜像并前后旋转', AvatarOrientationMode.MirrorLeftRightAndRotateY180);
      this.buildOrientationModeOption('自定义', AvatarOrientationMode.Custom);

      // Custom 模式:Yaw 调整
      if (this.orientationCalibration !== null
        && this.orientationCalibration!.mode === AvatarOrientationMode.Custom) {
        Divider().color('#e0e0e0').margin({ top: 12, bottom: 8 });

        Text('模型朝向(Yaw)')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 4 });

        Row() {
          Text(this.customYawInput.toFixed(0) + '°')
            .fontSize(12)
            .fontColor('#007DFF')
            .width(50);
          Slider({
            value: this.customYawInput,
            min: -180,
            max: 180,
            step: 1
          })
            .layoutWeight(1)
            .onChange((value: number) => {
              this.customYawInput = Math.round(value);
            });
        }
        .width('100%');

        // 90° 步进 + 重置
        Row() {
          Button('-90°')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#f0f0f0')
            .fontColor('#333333')
            .onClick(() => {
              this.customYawInput = this.clampYaw(this.customYawInput - 90);
            });
          Button('+90°')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#f0f0f0')
            .fontColor('#333333')
            .margin({ left: 4 })
            .onClick(() => {
              this.customYawInput = this.clampYaw(this.customYawInput + 90);
            });
          Button('重置')
            .fontSize(11)
            .height(28)
            .layoutWeight(1)
            .backgroundColor('#f0f0f0')
            .fontColor('#333333')
            .margin({ left: 4 })
            .onClick(() => {
              this.customYawInput = 0;
            });
        }
        .width('100%')
        .margin({ top: 6 });

        // 高级选项
        Text('高级选项')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ top: 12, bottom: 4 });

        Row() {
          Text('交换左右骨骼')
            .fontSize(12)
            .fontColor('#333333')
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.customSwapInput })
            .onChange((on: boolean) => {
              this.customSwapInput = on;
            });
        }
        .width('100%')
        .margin({ bottom: 4 });

        Row() {
          Text('反转 Forward')
            .fontSize(12)
            .fontColor('#333333')
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.customInvertInput })
            .onChange((on: boolean) => {
              this.customInvertInput = on;
            });
        }
        .width('100%');

        // 应用按钮
        Button('应用自定义校准')
          .fontSize(13)
          .height(36)
          .width('100%')
          .backgroundColor('#007DFF')
          .fontColor('#ffffff')
          .margin({ top: 12 })
          .enabled(!this.calibrationApplying)
          .key('actionDetail.orientationApplyCustom')
          .onClick(() => {
            this.applyCustomCalibration();
          });
      }

      // 恢复按钮(非 Auto 模式时显示)
      if (this.orientationCalibration !== null
        && this.orientationCalibration!.mode !== AvatarOrientationMode.Auto) {
        Button('恢复自动检测')
          .fontSize(12)
          .height(32)
          .width('100%')
          .backgroundColor('#f5f5f5')
          .fontColor('#666666')
          .margin({ top: 8 })
          .enabled(!this.calibrationApplying)
          .key('actionDetail.orientationRestoreAuto')
          .onClick(() => {
            this.restoreAutoCalibration();
          });
      }

      // 恢复默认按钮(任何非 Normal 模式时显示)
      if (this.orientationCalibration !== null
        && this.orientationCalibration!.mode !== AvatarOrientationMode.Normal) {
        Button('恢复默认(无校正)')
          .fontSize(12)
          .height(32)
          .width('100%')
          .backgroundColor('#f5f5f5')
          .fontColor('#666666')
          .margin({ top: 4 })
          .enabled(!this.calibrationApplying)
          .key('actionDetail.orientationRestoreDefault')
          .onClick(() => {
            this.restoreDefaultCalibration();
          });
      }

      // 候选评分(诊断信息)
      if (this.orientationAnalysis !== null) {
        Divider().color('#e0e0e0').margin({ top: 12, bottom: 8 });
        Text('候选评分(诊断)')
          .fontSize(11)
          .fontColor('#888888')
          .margin({ bottom: 4 });
        ForEach(this.orientationAnalysis!.candidateScores, (cs: OrientationCandidateScore) => {
          Row() {
            Text(cs.mode)
              .fontSize(11)
              .fontColor('#666666')
              .layoutWeight(1);
            Text(cs.score.toFixed(2))
              .fontSize(11)
              .fontColor(this.isSelectedCandidate(cs.mode) ? '#007DFF' : '#999999');
          }
          .width('100%')
          .margin({ bottom: 2 });
        });
      }
    }
    .width('100%');
  }

  /**
   * T-4.2G: 单个模式选项(可点击的 Row)。
   */
  @Builder
  buildOrientationModeOption(label: string, mode: AvatarOrientationMode): void {
    Row() {
      Row()
        .width(14)
        .height(14)
        .borderRadius(7)
        .backgroundColor(this.isOrientationModeSelected(mode) ? '#007DFF' : '#ffffff')
        .border({ width: 1, color: this.isOrientationModeSelected(mode) ? '#007DFF' : '#cccccc' })
        .margin({ right: 8 });
      Text(label)
        .fontSize(12)
        .fontColor(this.isOrientationModeSelected(mode) ? '#007DFF' : '#333333')
        .layoutWeight(1);
    }
    .width('100%')
    .height(36)
    .padding({ left: 8, right: 8 })
    .borderRadius(8)
    .backgroundColor(this.isOrientationModeSelected(mode) ? '#e6f4ff' : '#ffffff')
    .margin({ bottom: 4 })
    .key('actionDetail.orientationMode.' + mode)
    .onClick(() => {
      this.onSelectOrientationMode(mode);
    });
  }

  /**
   * T-4.2G: 判断指定模式是否为当前选中模式。
   */
  private isOrientationModeSelected(mode: AvatarOrientationMode): boolean {
    return this.orientationCalibration !== null
      && this.orientationCalibration!.mode === mode;
  }

  /**
   * T-4.2G-A2: 用户选择模式时触发(统一窗口内)。
   *
   * - Auto:立即应用(使用自动分析结果)
   * - Normal / RotateY180 / MirrorLeftRight / MirrorLeftRightAndRotateY180:立即应用
   * - Custom:不立即应用,等用户点击"应用自定义校准"按钮
   */
  private async onSelectOrientationMode(mode: AvatarOrientationMode): Promise<void> {
    if (this.actionDialogVm === null) {
      return;
    }
    if (mode === AvatarOrientationMode.Custom) {
      // 仅切换 UI 状态,等用户点击应用按钮
      if (this.orientationCalibration !== null) {
        // 临时改 mode 字段,让 UI 显示 Custom 配置
        // 实际生效需要点击"应用自定义校准"
        this.orientationCalibration = {
          avatarId: this.orientationCalibration!.avatarId,
          sourceSha256: this.orientationCalibration!.sourceSha256,
          mode: AvatarOrientationMode.Custom,
          autoDetectedMode: this.orientationCalibration!.autoDetectedMode,
          autoConfidence: this.orientationCalibration!.autoConfidence,
          yawOffsetDeg: this.customYawInput,
          swapLeftRight: this.customSwapInput,
          invertForward: this.customInvertInput,
          autoReasonCode: this.orientationCalibration!.autoReasonCode,
          isManualOverride: true,
          updatedAt: Date.now()
        };
      }
      return;
    }
    // 非 Custom:立即应用
    this.calibrationApplying = true;
    try {
      await this.actionDialogVm.applyManualCalibration(mode, 0, false, false);
    } catch (e) {
      Logger.warn(LOG_TAG, 'onSelectOrientationMode failed: ' + (e as Error)?.message);
    } finally {
      this.calibrationApplying = false;
    }
  }

  /**
   * T-4.2G-A2: 应用 Custom 模式校准。
   */
  private async applyCustomCalibration(): Promise<void> {
    if (this.actionDialogVm === null) {
      return;
    }
    this.calibrationApplying = true;
    try {
      await this.actionDialogVm.applyManualCalibration(
        AvatarOrientationMode.Custom,
        this.customYawInput,
        this.customSwapInput,
        this.customInvertInput
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'applyCustomCalibration failed: ' + (e as Error)?.message);
    } finally {
      this.calibrationApplying = false;
    }
  }

  /**
   * T-4.2G-A2: 恢复自动检测。
   */
  private async restoreAutoCalibration(): Promise<void> {
    if (this.actionDialogVm === null) {
      return;
    }
    this.calibrationApplying = true;
    try {
      await this.actionDialogVm.restoreAutoCalibration();
    } catch (e) {
      Logger.warn(LOG_TAG, 'restoreAutoCalibration failed: ' + (e as Error)?.message);
    } finally {
      this.calibrationApplying = false;
    }
  }

  /**
   * T-4.2G-A2: 恢复默认(Normal 无校正)。
   */
  private async restoreDefaultCalibration(): Promise<void> {
    if (this.actionDialogVm === null) {
      return;
    }
    this.calibrationApplying = true;
    try {
      await this.actionDialogVm.restoreDefaultCalibration();
    } catch (e) {
      Logger.warn(LOG_TAG, 'restoreDefaultCalibration failed: ' + (e as Error)?.message);
    } finally {
      this.calibrationApplying = false;
    }
  }

  /**
   * T-4.2G: 获取模式显示名。
   */
  private getOrientationModeDisplayName(mode: AvatarOrientationMode): string {
    switch (mode) {
      case AvatarOrientationMode.Auto:
        return '自动';
      case AvatarOrientationMode.Normal:
        return '正常';
      case AvatarOrientationMode.RotateY180:
        return '前后旋转 180°';
      case AvatarOrientationMode.MirrorLeftRight:
        return '左右镜像';
      case AvatarOrientationMode.MirrorLeftRightAndRotateY180:
        return '左右镜像并旋转';
      case AvatarOrientationMode.Custom:
        return '自定义';
      default:
        return '未知';
    }
  }

  /**
   * T-4.2G: 获取置信度显示名。
   */
  private getConfidenceDisplayName(confidence: OrientationConfidence): string {
    switch (confidence) {
      case OrientationConfidence.High:
        return '高';
      case OrientationConfidence.Medium:
        return '中';
      case OrientationConfidence.Low:
        return '低';
      case OrientationConfidence.Unknown:
        return '未知';
      default:
        return '未知';
    }
  }

  /**
   * T-4.2G: 获取置信度对应的颜色。
   */
  private getConfidenceColor(confidence: OrientationConfidence): string {
    switch (confidence) {
      case OrientationConfidence.High:
        return '#34c759'; // 绿
      case OrientationConfidence.Medium:
        return '#007DFF'; // 蓝
      case OrientationConfidence.Low:
        return '#ff9500'; // 橙
      case OrientationConfidence.Unknown:
        return '#999999'; // 灰
      default:
        return '#999999';
    }
  }

  /**
   * T-4.2G: 判断候选模式是否为当前选中模式(用于评分列表高亮)。
   */
  private isSelectedCandidate(mode: AvatarOrientationMode): boolean {
    if (this.orientationCalibration === null) {
      return false;
    }
    const cal: AvatarOrientationCalibration = this.orientationCalibration!;
    const effectiveMode: AvatarOrientationMode = cal.mode === AvatarOrientationMode.Auto
      ? cal.autoDetectedMode
      : cal.mode;
    return effectiveMode === mode;
  }

  /**
   * T-4.2G: 将 Yaw 角度限制到 [-180, 180]。
   */
  private clampYaw(yawDeg: number): number {
    let v: number = yawDeg % 360.0;
    if (v > 180.0) {
      v -= 360.0;
    } else if (v < -180.0) {
      v += 360.0;
    }
    return v;
  }

  @Builder
  buildDetailRow(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#888888')
        .width(70);
      Text(value)
        .fontSize(13)
        .fontColor('#333333')
        .layoutWeight(1);
    }
    .width('100%')
    .margin({ bottom: 6 });
  }

  /**
   * T-4.2G-A2: 获取姿态分类显示标签。
   */
  private getPoseTypeLabel(type: RestPoseType): string {
    switch (type) {
      case RestPoseType.TPose: return 'T Pose (双臂水平)';
      case RestPoseType.APose: return 'A Pose (双臂斜下)';
      case RestPoseType.ArmsDown: return 'Arms Down (双臂下垂)';
      case RestPoseType.Custom: return 'Custom (自定义姿态)';
      default: return 'Unknown (未知)';
    }
  }

  /**
   * T-4.2G-A2: 在统一窗口内设置循环模式。
   *
   * 设置后保留窗口打开,只刷新卡片列表并同步 actionDialogCard 引用,
   * 不调用 closeActionDialog(用户要求"切换其他设置不应停止或重新加载模型")。
   */
  private async onClickSetLoopMode(mode: ActionLoopMode): Promise<void> {
    if (this.actionDialogCard === null || this.vm === null) {
      return;
    }
    const actionId: string = this.actionDialogCard!.id;
    const modelId: string = this.currentModelId();
    const ok: boolean = await this.vm.setLoopMode(modelId, actionId, mode);
    if (ok) {
      promptAction.showToast({ message: '已设置为' + this.vm.getLoopModeLabel(mode), duration: 1500 });
      await this.loadActionCards();
      // 同步当前窗口的卡片引用,让 loopMode chip 立即刷新
      const updated: ActionCardItem | null = this.findUpdatedCard(actionId);
      if (updated !== null) {
        this.actionDialogCard = updated;
      }
    } else {
      promptAction.showToast({ message: '设置失败', duration: 1500 });
    }
  }

  /**
   * 获取当前模型 ID(用于 per-model 循环偏好)。
   * 无当前模型时返回空字符串(使用全局偏好)。
   *
   * 注意:必须与 loadActionCards() 中传给 ViewModel 的 modelId 保持一致,
   * 否则写入和读取的 Preferences key 不匹配,导致设置"丢失"。
   */
  private currentModelId(): string {
    return this.modelConfig.displayName;
  }

  /**
   * T-3D.6C-C: 获取卡片的实际循环值(loopMode 解析后)。
   */
  private getCardEffectiveLoop(card: ActionCardItem): boolean {
    if (this.vm === null) {
      return card.loop;
    }
    return this.vm.getEffectiveLoop(card);
  }

  /**
   * T-4.2G-A2: 获取当前骨架显示模式的简短辅助说明文案。
   *
   * 用于 3D 预览区域左下角悬浮提示。
   * - ModelOnly: 默认模型预览
   * - ModelWithSkeleton: 骨架来自当前模型的实际重定向结果
   * - SkeletonOnly: 仅显示目标骨架
   * - SourceActionPreview: 源动作示意,不代表当前模型姿势
   */
  private getSkeletonModeHint(): string {
    switch (this.skeletonDisplayMode) {
      case SkeletonDisplayMode.ModelOnly:
        return '当前模型实际重定向结果';
      case SkeletonDisplayMode.ModelWithSkeleton:
        return '骨架来自当前模型的实际重定向结果';
      case SkeletonDisplayMode.SkeletonOnly:
        return '仅目标骨架(无模型)';
      case SkeletonDisplayMode.SourceActionPreview:
        return '源动作示意,不代表当前模型姿势';
      default:
        return '';
    }
  }

  // ==================== 重命名对话框 ====================

  @Builder
  buildRenameDialog(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.renameCard = null;
        });

      Column() {
        Text('重命名动作')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 12 });

        Text('原名: ' + this.renameCard!.defaultDisplayName)
          .fontSize(12)
          .fontColor('#666666')
          .margin({ bottom: 12 });

        TextInput({ text: this.renameText, placeholder: '输入新名称(最多30字符)' })
          .fontSize(14)
          .height(40)
          .backgroundColor('#f5f5f5')
          .borderRadius(8)
          .maxLength(30)
          .onChange((value: string) => {
            this.renameText = value;
          });

        Row() {
          Button('取消')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#cccccc')
            .fontColor('#333333')
            .margin({ right: 8 })
            .onClick(() => {
              this.renameCard = null;
            });
          Button('保存')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#007DFF')
            .fontColor('#ffffff')
            .onClick(() => {
              this.confirmRename();
            });
        }
        .width('100%')
        .margin({ top: 16 });
      }
      .width('85%')
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .padding(20);
    }
    .width('100%')
    .height('100%');
  }

  // ==================== 删除确认对话框 ====================

  @Builder
  buildDeleteConfirmDialog(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.deleteConfirmCard = null;
        });

      Column() {
        Text('确认删除')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#cc0000')
          .margin({ bottom: 12 });

        Text('确定删除动作"' + this.deleteConfirmCard!.displayName + '"吗?该操作会同时解除使用此动作的绑定,且无法撤销。')
          .fontSize(13)
          .fontColor('#333333')
          .lineHeight(20)
          .margin({ bottom: 16 });

        Row() {
          Button('取消')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#cccccc')
            .fontColor('#333333')
            .margin({ right: 8 })
            .onClick(() => {
              this.deleteConfirmCard = null;
            });
          Button('删除')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#cc0000')
            .fontColor('#ffffff')
            .onClick(() => {
              this.confirmDelete();
            });
        }
        .width('100%');
      }
      .width('85%')
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .padding(20);
    }
    .width('100%')
    .height('100%');
  }

  // ==================== 绑定槽位对话框 ====================

  @Builder
  buildBindSlotDialog(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.bindSlotCard = null;
        });

      Column() {
        Text('绑定到槽位')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 12 });

        Text('动作: ' + this.bindSlotCard!.displayName)
          .fontSize(13)
          .fontColor('#666666')
          .margin({ bottom: 12 });

        Scroll() {
          Column() {
            ForEach(this.slotInfos, (slotInfo: ActionSlotInfo) => {
              Row() {
                Text(slotInfo.displayName)
                  .fontSize(13)
                  .fontColor('#333333')
                  .layoutWeight(1);
                if (this.bindSlotCard!.boundSlot === slotInfo.slot) {
                  Text('当前')
                    .fontSize(11)
                    .fontColor('#007DFF');
                }
                Button('绑定')
                  .fontSize(11)
                  .height(28)
                  .backgroundColor('#007DFF')
                  .fontColor('#ffffff')
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.confirmBindSlot(slotInfo.slot);
                  });
              }
              .width('100%')
              .padding({ top: 8, bottom: 8, left: 12, right: 12 })
              .backgroundColor('#f9f9f9')
              .borderRadius(8)
              .margin({ bottom: 4 });
            }, (slotInfo: ActionSlotInfo) => String(slotInfo.slot));
          }
          .width('100%');
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off);

        Button('关闭')
          .fontSize(14)
          .height(36)
          .width('100%')
          .backgroundColor('#cccccc')
          .fontColor('#333333')
          .margin({ top: 12 })
          .onClick(() => {
            this.bindSlotCard = null;
          });
      }
      .width('85%')
      .height('60%')
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .padding(20);
    }
    .width('100%')
    .height('100%');
  }

  // ==================== 导入预览对话框(保留原逻辑) ====================

  @Builder
  buildImportPreviewDialog(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.onClickCancelImport();
        });

      Column() {
        Text('导入动作预览')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 12 });

        Scroll() {
          Column() {
            this.buildPreviewInfoRow('文件名', this.importPreview!.sourceFileName);
            this.buildPreviewInfoRow('格式', this.getSourceFormatDisplayName(this.importPreview!.sourceFormat));
            this.buildPreviewInfoRow('Clip 数', String(this.importPreview!.clips.length));
            this.buildPreviewInfoRow('骨骼节点', String(this.importPreview!.nodeNames.length));
            this.buildPreviewInfoRow('骨骼 Profile', getSkeletonProfileDisplayName(this.importPreview!.skeletonProfile));
            this.buildPreviewInfoRow('兼容等级', getCompatibilityLevelDisplayName(this.importPreview!.compatibilityLevel));

            Text('选择 Clip:')
              .fontSize(13)
              .fontColor('#333333')
              .margin({ top: 12, bottom: 4 })
              .alignSelf(ItemAlign.Start);
            ForEach(this.importPreview!.clips, (clip: AnimationClipInfo, index: number) => {
              Row() {
                Radio({ value: String(index), group: 'clipGroup' })
                  .checked(this.selectedClipIndex === index)
                  .onChange((checked: boolean) => {
                    if (checked) {
                      this.selectedClipIndex = index;
                      this.importDisplayName = clip.name;
                    }
                  });
                Text(clip.name + ' (' + (clip.durationMs / 1000).toFixed(2) + 's)')
                  .fontSize(13)
                  .fontColor('#333333')
                  .margin({ left: 8 });
              }
              .margin({ bottom: 4 });
            }, (clip: AnimationClipInfo) => clip.name + '_' + clip.index);

            Text('目标槽位:')
              .fontSize(13)
              .fontColor('#333333')
              .margin({ top: 12, bottom: 4 })
              .alignSelf(ItemAlign.Start);
            ForEach(this.slotInfos, (slotInfo: ActionSlotInfo) => {
              Row() {
                Radio({ value: String(slotInfo.slot), group: 'slotGroup' })
                  .checked(this.selectedTargetSlot === slotInfo.slot)
                  .onChange((checked: boolean) => {
                    if (checked) {
                      this.selectedTargetSlot = slotInfo.slot;
                      this.importLoop = slotInfo.defaultLoop;
                    }
                  });
                Text(slotInfo.displayName)
                  .fontSize(13)
                  .fontColor('#333333')
                  .margin({ left: 8 });
              }
              .margin({ bottom: 2 });
            }, (slotInfo: ActionSlotInfo) => String(slotInfo.slot));

            Row() {
              Checkbox()
                .select(this.importLoop)
                .onChange((checked: boolean) => {
                  this.importLoop = checked;
                });
              Text('循环播放')
                .fontSize(13)
                .fontColor('#333333')
                .margin({ left: 8 });
            }
            .margin({ top: 12 });

            Row() {
              Text('显示名:')
                .fontSize(13)
                .fontColor('#333333')
                .width(70);
              TextInput({ text: this.importDisplayName })
                .fontSize(13)
                .layoutWeight(1)
                .onChange((value: string) => {
                  this.importDisplayName = value;
                });
            }
            .margin({ top: 12 });

            Text('导入的动作文件需要包含骨骼动画。动作是否能用于其他模型,取决于模型与动作的骨骼兼容性。')
              .fontSize(11)
              .fontColor('#8a6d3b')
              .margin({ top: 12 })
              .lineHeight(16);
          }
          .width('100%')
          .padding(16);
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off);

        Row() {
          Button('取消')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#cccccc')
            .fontColor('#333333')
            .margin({ right: 8 })
            .onClick(() => {
              this.onClickCancelImport();
            });
          Button('确认导入')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#007DFF')
            .fontColor('#ffffff')
            .onClick(() => {
              this.onClickConfirmImport();
            });
        }
        .width('100%')
        .padding({ top: 12, bottom: 12, left: 16, right: 16 });
      }
      .width('92%')
      .height('82%')
      .backgroundColor('#ffffff')
      .borderRadius(12);
    }
    .width('100%')
    .height('100%');
  }

  // ==================== 事件处理 ====================

  /**
   * T-4.2G-A2: 单击卡片 → 打开统一动作详情与管理窗口。
   *
   * - 若统一窗口已打开且 Avatar Scene 已就绪,优先复用 Scene 切换 Clip(switchActionInDialog)
   * - 否则完整 openActionDialog(创建新 VM + Scene.load)
   */
  private async onClickCard(card: ActionCardItem): Promise<void> {
    this.selectedCardId = card.id;
    if (this.actionDialogCard !== null && this.actionDialogVm !== null && this.actionDialogScene !== null) {
      await this.switchActionInDialog(card);
    } else {
      await this.openActionDialog(card);
    }
  }

  /**
   * 长按卡片:打开管理菜单。
   */
  private onLongPressCard(card: ActionCardItem): void {
    this.selectedCardId = card.id;
    this.manageCard = card;
  }

  /**
   * 从管理菜单点击重命名。
   */
  private onClickRenameFromManage(): void {
    if (this.manageCard === null) {
      return;
    }
    const card: ActionCardItem = this.manageCard;
    this.manageCard = null;
    this.renameText = card.displayName;
    this.renameCard = card;
  }

  /**
   * 切换隐藏状态。
   */
  private async onClickToggleHide(hidden: boolean): Promise<void> {
    if (this.manageCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.manageCard;
    this.manageCard = null;
    const ok: boolean = await this.vm.setBuiltinActionHidden(card.id, hidden);
    if (ok) {
      promptAction.showToast({
        message: hidden ? '已隐藏' : '已取消隐藏',
        duration: 1500
      });
      await this.loadActionCards();
    } else {
      promptAction.showToast({ message: '操作失败', duration: 2000 });
    }
  }

  /**
   * 确认重命名。
   */
  private async confirmRename(): Promise<void> {
    if (this.renameCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.renameCard;
    const newName: string = this.renameText;
    this.renameCard = null;
    const ok: boolean = await this.vm.renameAction(card.id, newName);
    if (ok) {
      promptAction.showToast({ message: '已保存', duration: 1500 });
      await this.loadActionCards();
    } else {
      promptAction.showToast({
        message: '重命名失败(名称不能为空,最多30字符)',
        duration: 3000
      });
    }
  }

  /**
   * 确认删除。
   */
  private async confirmDelete(): Promise<void> {
    if (this.deleteConfirmCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.deleteConfirmCard;
    this.deleteConfirmCard = null;
    const ok: boolean = await this.vm.deleteImportedAction(card.id, this.modelConfig.displayName);
    if (ok) {
      promptAction.showToast({ message: '已删除', duration: 1500 });
      await this.loadActionCards();
    } else {
      promptAction.showToast({ message: '删除失败', duration: 2000 });
    }
  }

  /**
   * 确认绑定槽位。
   */
  private async confirmBindSlot(slot: Character3DActionSlot): Promise<void> {
    if (this.bindSlotCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.bindSlotCard;
    this.bindSlotCard = null;
    const ok: boolean = await this.vm.bindActionToSlot(card.id, slot, this.modelConfig.displayName);
    if (ok) {
      promptAction.showToast({ message: '已绑定', duration: 1500 });
      await this.loadActionCards();
    } else {
      promptAction.showToast({ message: '绑定失败', duration: 2000 });
    }
  }

  /**
   * T-4.2G-A2: 应用动作到当前模型(从统一窗口触发)。
   *
   * 绑定到动作的默认槽位;成功后刷新卡片列表并同步 actionDialogCard 引用,
   * 不关闭统一窗口。
   */
  private async onClickApplyAction(): Promise<void> {
    if (this.actionDialogCard === null || this.vm === null) {
      return;
    }
    const actionId: string = this.actionDialogCard!.id;
    const slot: Character3DActionSlot = this.parseSlotFromString(this.actionDialogCard!.asset.slot);
    const ok: boolean = await this.vm.bindActionToSlot(actionId, slot, this.modelConfig.displayName);
    if (ok) {
      promptAction.showToast({
        message: '已应用到当前模型',
        duration: 1500
      });
      await this.loadActionCards();
      const updated: ActionCardItem | null = this.findUpdatedCard(actionId);
      if (updated !== null) {
        this.actionDialogCard = updated;
      }
    } else {
      promptAction.showToast({ message: '应用失败', duration: 2000 });
    }
  }

  /**
   * 从字符串解析槽位。
   */
  private parseSlotFromString(value: string): Character3DActionSlot {
    for (let i: number = 0; i < this.slotInfos.length; i++) {
      if (String(this.slotInfos[i].slot) === value) {
        return this.slotInfos[i].slot;
      }
    }
    return Character3DActionSlot.Idle;
  }

  /**
   * 点击导入模型(跳转到 3D 设置页或 PoC 页)。
   */
  private onClickImportModel(): void {
    // 跳转到 3D PoC 页面(用户可在那里导入模型)
    router.pushUrl({ url: 'pages/Character3DPocPage' });
  }

  /**
   * T-4.2B: 点击"配置骨骼"按钮,跳转到 HumanoidMappingPage 并传入当前激活 avatarId。
   *
   * 流程:
   * 1. 通过 AvatarLibraryService.getActiveAvatarId() 获取当前激活 avatarId
   * 2. 通过 router.pushUrl 传参跳转
   * 3. 无激活 Avatar 时提示用户先导入模型
   */
  private async onClickOpenHumanoidMapping(): Promise<void> {
    const avatarLibraryService: AvatarLibraryService | null = AppServices.getAvatarLibraryService();
    if (avatarLibraryService === null) {
      Logger.warn(LOG_TAG, 'onClickOpenHumanoidMapping: AvatarLibraryService null');
      return;
    }
    const activeAvatarId: string = await avatarLibraryService.getActiveAvatarId();
    if (activeAvatarId.length === 0) {
      promptAction.showToast({
        message: '请先在模型库中导入并激活一个 Avatar',
        duration: 2000
      });
      return;
    }
    router.pushUrl({
      url: 'pages/HumanoidMappingPage',
      params: { avatarId: activeAvatarId }
    });
  }

  /**
   * 点击导入动作。
   */
  private async onClickImportAction(): Promise<void> {
    if (this.isImporting || this.actionService === null) {
      return;
    }
    this.isImporting = true;
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.glb', '.gltf', '.vrma'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        this.isImporting = false;
        return;
      }
      const sourceUri: string = uris[0];
      const sourceFileName: string = this.extractFileName(sourceUri);
      const request: ActionImportRequest = {
        sourceUri: sourceUri,
        sourceFileName: sourceFileName
      };
      const preview: ActionImportPreview =
        await this.actionService.importActionPreview(request);
      if (!preview.canImport) {
        promptAction.showToast({
          message: preview.errorMessage,
          duration: 4000
        });
        this.isImporting = false;
        return;
      }
      this.importPreview = preview;
      this.selectedClipIndex = 0;
      this.selectedTargetSlot = Character3DActionSlot.Idle;
      this.importLoop = preview.clips.length > 0 ? this.getDefaultLoopBySlot(Character3DActionSlot.Idle) : false;
      this.importDisplayName = preview.clips.length > 0 ? preview.clips[0].name : sourceFileName;
    } catch (e) {
      Logger.error(LOG_TAG, 'onClickImportAction failed: ' + (e as Error)?.message);
      promptAction.showToast({
        message: '导入失败: ' + (e as Error)?.message,
        duration: 3000
      });
    } finally {
      this.isImporting = false;
    }
  }

  /**
   * 从 URI 提取文件名。
   */
  private extractFileName(uri: string): string {
    let path: string = uri;
    const queryIdx: number = path.indexOf('?');
    if (queryIdx >= 0) {
      path = path.substring(0, queryIdx);
    }
    const lastSlash: number = path.lastIndexOf('/');
    return lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
  }

  /**
   * 根据槽位获取默认循环设置。
   */
  private getDefaultLoopBySlot(slot: Character3DActionSlot): boolean {
    const info: ActionSlotInfo = getSlotInfo(slot);
    return info.defaultLoop;
  }

  /**
   * 获取来源格式显示名。
   */
  private getSourceFormatDisplayName(format: ActionSourceFormat): string {
    switch (format) {
      case ActionSourceFormat.ExternalGlb: return '外部 GLB';
      case ActionSourceFormat.Gltf: return 'GLTF';
      case ActionSourceFormat.Vrma: return 'VRMA';
      case ActionSourceFormat.EmbeddedGlb: return '内置 GLB';
      default: return '未知';
    }
  }

  /**
   * 确认导入动作。
   */
  private async onClickConfirmImport(): Promise<void> {
    if (this.importPreview === null || this.actionService === null) {
      return;
    }
    try {
      const confirm: ActionImportConfirm = {
        preview: this.importPreview!,
        selectedClipIndex: this.selectedClipIndex,
        targetSlot: this.selectedTargetSlot,
        loop: this.importLoop,
        speed: 1.0,
        displayName: this.importDisplayName
      };
      const asset: Character3DActionAsset = await this.actionService.confirmImportAction(confirm);
      // 自动绑定到目标槽位
      const binding: Character3DActionBinding = {
        modelId: this.modelConfig.displayName,
        slot: this.selectedTargetSlot,
        actionAssetId: asset.id,
        clipName: asset.clipName,
        clipIndex: -1,
        loop: this.importLoop,
        speed: 1.0,
        updatedAt: Date.now()
      };
      await this.actionService.saveBinding(binding);
      // 刷新数据
      await this.loadActionCards();
      this.importPreview = null;
      promptAction.showToast({ message: '导入成功', duration: 1500 });
    } catch (e) {
      promptAction.showToast({
        message: '导入失败: ' + (e as Error)?.message,
        duration: 3000
      });
    }
  }

  /**
   * 取消导入。
   */
  private async onClickCancelImport(): Promise<void> {
    if (this.importPreview !== null && this.actionService !== null) {
      await this.actionService.cancelImport(this.importPreview);
    }
    this.importPreview = null;
  }
}
