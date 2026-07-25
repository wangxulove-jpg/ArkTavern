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
import { ActionCardDataSource } from '../viewmodels/ActionCardDataSource';
import {
  ActionAvatarPreviewViewModel,
  ActionPreview3DState,
  PreviewActionInfo
} from '../viewmodels/ActionAvatarPreviewViewModel';
import { AvatarLibraryService } from '../services/AvatarLibraryService';

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
  @State private previewCard: ActionCardItem | null = null;
  @State private manageCard: ActionCardItem | null = null;
  @State private renameCard: ActionCardItem | null = null;
  @State private renameText: string = '';
  @State private deleteConfirmCard: ActionCardItem | null = null;
  @State private bindSlotCard: ActionCardItem | null = null;
  // T-3D.6C-C: 动作详情 Sheet(含循环设置)
  @State private detailsCard: ActionCardItem | null = null;

  // ========== T-4.2 阶段5: 动作详情 3D 预览状态 ==========
  /** 动作详情预览 ViewModel(弹窗打开时创建,关闭时 dispose) */
  private detailsPreviewVm: ActionAvatarPreviewViewModel | null = null;
  /** 详情预览 Scene(由 ViewModel 回调写入) */
  @State private detailsPreviewScene: Scene | null = null;
  /** 详情预览状态 */
  @State private detailsPreviewState: ActionPreview3DState = ActionPreview3DState.Idle;
  /** 详情预览错误信息 */
  @State private detailsPreviewError: string = '';
  /** 详情预览当前 Avatar 显示名 */
  @State private detailsPreviewAvatarName: string = '';

  // ========== 预览 3D 状态 ==========
  @State private previewScene: Scene | null = null;
  @State private previewAnimation: Animation | null = null;
  @State private previewPlaying: boolean = false;
  @State private previewLoading: boolean = false;
  @State private previewPackUri: string = '';
  /** T-4.2C: 预览提示信息(如"跨模型动作重定向尚未接通") */
  @State private previewNotice: string = '';
  /** T-4.2C: 预览当前 Avatar 显示名 */
  @State private previewAvatarName: string = '';
  /** T-4.2D: 预览弹窗 ViewModel(复用 ActionAvatarPreviewViewModel 的 bounds 驱动取景) */
  private previewVm: ActionAvatarPreviewViewModel | null = null;
  /** T-4.2E: 预览弹窗 ViewModel 状态(用于按钮文案与启用判断) */
  @State private previewVmState: ActionPreview3DState = ActionPreview3DState.Idle;

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
    this.cleanupPreviewScene();
    this.cleanupDetailsPreview();
  }

  onPageHide(): void {
    this.cleanupPreviewScene();
    this.cleanupDetailsPreview();
  }

  /**
   * 清理预览 Scene 资源。
   */
  private cleanupPreviewScene(): void {
    // T-4.2D: 释放 previewVm(会自动 destroy Scene)
    if (this.previewVm !== null) {
      this.previewVm.dispose();
      this.previewVm = null;
    }
    if (this.previewAnimation !== null) {
      try {
        this.previewAnimation.stop();
      } catch (_e) {
        // ignore
      }
      this.previewAnimation = null;
    }
    if (this.previewScene !== null) {
      try {
        this.previewScene.destroy();
      } catch (_e) {
        // ignore
      }
      this.previewScene = null;
    }
    this.previewPlaying = false;
    this.previewNotice = '';
    this.previewAvatarName = '';
    this.previewVmState = ActionPreview3DState.Idle;
  }

  /**
   * T-4.2 阶段5: 初始化动作详情 3D 预览。
   *
   * 打开详情弹窗时调用:
   * 1. 创建 ViewModel 并注入 AvatarLibraryService
   * 2. 绑定状态/错误/Scene 回调
   * 3. 调用 initialize 加载当前激活 Avatar
   */
  private async initDetailsPreview(card: ActionCardItem): Promise<void> {
    // 先清理上一次残留
    this.cleanupDetailsPreview();

    const avatarLibraryService: AvatarLibraryService | null = AppServices.getAvatarLibraryService();
    if (avatarLibraryService === null) {
      Logger.warn(LOG_TAG, 'initDetailsPreview: AvatarLibraryService null');
      this.detailsPreviewError = 'Avatar 服务未就绪';
      this.detailsPreviewState = ActionPreview3DState.Failed;
      return;
    }

    const vm: ActionAvatarPreviewViewModel = new ActionAvatarPreviewViewModel();
    vm.setAvatarLibraryService(avatarLibraryService);
    // T-4.2D: 注入 Character3DService 用于 bounds 驱动取景
    const char3DService: Character3DService | null = AppServices.getCharacter3DService();
    if (char3DService !== null) {
      vm.setCharacter3DService(char3DService);
    }
    // T-4.2E: 注入 AppContext 用于读取 rawfile 动作包
    vm.setAppContext(getContext(this) as common.Context);
    vm.onStateChanged = (state: ActionPreview3DState): void => {
      this.detailsPreviewState = state;
    };
    vm.onError = (message: string): void => {
      this.detailsPreviewError = message;
    };
    vm.onSceneReady = (scene: Scene | null): void => {
      this.detailsPreviewScene = scene;
    };
    vm.onAvatarInfo = (displayName: string, _hasAnimation: boolean): void => {
      this.detailsPreviewAvatarName = displayName;
    };
    vm.onPrepareProgress = (message: string): void => {
      this.detailsPreviewError = message;
    };

    this.detailsPreviewVm = vm;
    this.detailsPreviewError = '';
    this.detailsPreviewState = ActionPreview3DState.Idle;
    this.detailsPreviewScene = null;
    this.detailsPreviewAvatarName = '';

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
      Logger.error(LOG_TAG, 'initDetailsPreview failed: ' + (e as Error)?.message);
      this.detailsPreviewError = '加载预览失败: ' + (e as Error)?.message;
      this.detailsPreviewState = ActionPreview3DState.Failed;
    }
  }

  /**
   * T-4.2 阶段5: 清理动作详情 3D 预览资源。
   *
   * 关闭弹窗或页面销毁时调用,释放 Scene。
   */
  private cleanupDetailsPreview(): void {
    if (this.detailsPreviewVm !== null) {
      this.detailsPreviewVm.dispose();
      this.detailsPreviewVm = null;
    }
    this.detailsPreviewScene = null;
    this.detailsPreviewState = ActionPreview3DState.Idle;
    this.detailsPreviewError = '';
    this.detailsPreviewAvatarName = '';
  }

  /**
   * T-4.2 阶段5: 重试加载详情预览。
   */
  private async retryDetailsPreview(): Promise<void> {
    if (this.detailsCard === null) {
      return;
    }
    await this.initDetailsPreview(this.detailsCard);
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
        if (this.previewCard !== null) {
          this.buildPreviewDialog();
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
        if (this.detailsCard !== null) {
          this.buildDetailsSheet();
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

  // ==================== 预览弹层 ====================

  @Builder
  buildPreviewDialog(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.6)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.closePreview();
        });

      Column() {
        // 标题
        Row() {
          Text(this.previewCard!.displayName)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .layoutWeight(1);
          Text('✕')
            .fontSize(18)
            .fontColor('#999999')
            .padding(8)
            .onClick(() => {
              this.closePreview();
            });
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 12, bottom: 8 });

        // 3D 预览区域
        Stack() {
          if (this.previewLoading) {
            Column() {
              LoadingProgress()
                .width(40)
                .height(40)
                .color('#007DFF');
              Text('加载当前 Avatar...')
                .fontSize(13)
                .fontColor('#666666')
                .margin({ top: 8 });
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center);
          } else if (this.previewScene !== null) {
            // 正常渲染 3D 场景(当前 Avatar 静态模型)
            Component3D({
              scene: this.previewScene as Scene,
              modelType: ModelType.SURFACE
            })
              .width('100%')
              .height('100%');

            // 底部叠加提示信息
            if (this.previewNotice.length > 0) {
              Column() {
                Text(this.previewNotice)
                  .fontSize(11)
                  .fontColor('#666666')
                  .backgroundColor('rgba(255,255,255,0.8)')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(4)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.End)
              .alignItems(HorizontalAlign.Center)
              .padding({ bottom: 8 });
            }
            // 顶部叠加 Avatar 名称
            if (this.previewAvatarName.length > 0) {
              Column() {
                Text(this.previewAvatarName)
                  .fontSize(11)
                  .fontColor('#333333')
                  .backgroundColor('rgba(255,255,255,0.8)')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(4)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Start)
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 8, top: 8 });
            }
          } else {
            // 无 Scene:显示错误/提示信息
            Column() {
              Text('⚠')
                .fontSize(40)
                .fontColor('#ff9800');
              Text(this.previewNotice.length > 0 ? this.previewNotice : '预览不可用')
                .fontSize(13)
                .fontColor('#666666')
                .margin({ top: 8 })
                .textAlign(TextAlign.Center);
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .padding(16);
          }
        }
        .width('100%')
        .height(300)
        .backgroundColor('#e0e0e0');

        // 动作信息
        Column() {
          this.buildPreviewInfoRow('Clip', this.previewCard!.clipName);
          this.buildPreviewInfoRow('时长', this.formatDuration(this.previewCard!.durationMs));
          this.buildPreviewInfoRow('循环', this.getCardEffectiveLoop(this.previewCard!) ? '是' : '否');
          this.buildPreviewInfoRow('来源', this.previewCard!.isBuiltIn ? '内置' : '导入');
          this.buildPreviewInfoRow('分类', this.getCategoryDisplayName(this.previewCard!.category));
          // T-3D.6E: 不再显示"完全兼容/当前模型不兼容",改为显示动作匹配状态
          this.buildPreviewInfoRow('动作匹配', this.getMotionCompatibilityText());
        }
        .width('100%')
        .padding(16);

        // 控制按钮
        Row() {
          Button(this.previewVm !== null
            ? (this.previewVmState === ActionPreview3DState.Playing ? '暂停' : '播放')
            : (this.previewPlaying ? '暂停' : '播放'))
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor(this.previewVm !== null
              ? (this.previewVmState === ActionPreview3DState.Playing ? '#ff9800' : '#007DFF')
              : (this.previewPlaying ? '#ff9800' : '#007DFF'))
            .fontColor('#ffffff')
            .margin({ right: 4 })
            .enabled(this.previewScene !== null)
            .onClick(() => {
              this.togglePreviewPlay();
            });
          Button('重播')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#28a745')
            .fontColor('#ffffff')
            .margin({ left: 4, right: 4 })
            .enabled(this.previewScene !== null)
            .onClick(() => {
              this.replayPreview();
            });
          Button('停止')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#cccccc')
            .fontColor('#333333')
            .margin({ left: 4, right: 4 })
            .enabled(this.previewScene !== null)
            .onClick(() => {
              this.stopPreview();
            });
          Button('应用')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#9c27b0')
            .fontColor('#ffffff')
            .margin({ left: 4 })
            .enabled(this.canApplyActionToCurrentModel())
            .onClick(() => {
              this.onClickApplyAction();
            });
        }
        .width('100%')
        .padding({ left: 16, right: 16 });

        // T-4.2E-Closeout: 单骨骼测试按钮已删除(SceneNode.rotation 写入已验证有效)
      }
      .width('92%')
      .backgroundColor('#ffffff')
      .borderRadius(16);
    }
    .width('100%')
    .height('100%');
  }

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
          .margin({ bottom: 16 });

        // 重命名
        this.buildManageMenuItem('重命名显示名称', () => {
          this.onClickRenameFromManage();
        });
        // 恢复默认名称(仅内置)
        if (this.manageCard!.isBuiltIn) {
          this.buildManageMenuItem('恢复默认名称', () => {
            this.onClickResetNameFromManage();
          });
        }
        // 预览动作
        this.buildManageMenuItem('预览动作', () => {
          const card: ActionCardItem = this.manageCard!;
          this.manageCard = null;
          this.onClickCard(card);
        });
        // 绑定动作槽位
        this.buildManageMenuItem('绑定动作槽位', () => {
          const card: ActionCardItem = this.manageCard!;
          this.manageCard = null;
          this.bindSlotCard = card;
        });
        // T-3D.6C-C: 设置循环方式
        this.buildManageMenuItem('设置循环方式', () => {
          const card: ActionCardItem = this.manageCard!;
          this.manageCard = null;
          this.openDetailsSheet(card);
        });
        // 查看详情(打开详情 Sheet,含循环设置)
        this.buildManageMenuItem('查看详情', () => {
          const card: ActionCardItem = this.manageCard!;
          this.manageCard = null;
          this.openDetailsSheet(card);
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

  @Builder
  buildDetailsSheet(): void {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.closeDetailsSheet();
        });

      Scroll() {
        Column() {
          // 标题
          Text(this.detailsCard!.displayName)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ bottom: 12 });

          // T-4.2 阶段5: 3D 动作预览区域(显示当前激活 Avatar 执行该动作)
          ActionAvatarPreview3D({
            scene: this.detailsPreviewScene,
            state: this.detailsPreviewState,
            avatarName: this.detailsPreviewAvatarName,
            actionName: this.detailsCard!.displayName,
            errorMessage: this.detailsPreviewError,
            onPlay: () => { this.detailsPreviewVm?.play(); },
            onPause: () => { this.detailsPreviewVm?.pause(); },
            onReplay: () => { this.detailsPreviewVm?.replay(); },
            onStop: () => { this.detailsPreviewVm?.stop(); },
            onRetry: () => { this.retryDetailsPreview(); }
          });

          // 分隔线
          Divider()
            .color('#e0e0e0')
            .margin({ top: 12, bottom: 12 });

          // 基本信息
          this.buildDetailRow('ID', this.detailsCard!.id);
          this.buildDetailRow('Clip', this.detailsCard!.clipName);
          this.buildDetailRow('时长', this.formatDuration(this.detailsCard!.durationMs));
          this.buildDetailRow('来源', this.detailsCard!.isBuiltIn ? '内置' : '导入');
          this.buildDetailRow('骨骼', getSkeletonProfileDisplayName(this.detailsCard!.skeletonProfile));
          this.buildDetailRow('兼容', getCompatibilityLevelDisplayName(this.detailsCard!.compatibilityLevel));
          this.buildDetailRow('默认循环', this.getDefaultLoopLabel(this.detailsCard!));

          // 分隔线
          Divider()
            .color('#e0e0e0')
            .margin({ top: 16, bottom: 16 });

          // 循环方式设置
          Text('循环方式')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333')
            .margin({ bottom: 8 });

          Text('默认: ' + this.getDefaultLoopLabel(this.detailsCard!)
            + '    当前设置: ' + this.getLoopModeLabel(this.detailsCard!.loopMode))
            .fontSize(12)
            .fontColor('#888888')
            .margin({ bottom: 12 });

          // 三个选项
          this.buildLoopModeOption('跟随默认', ActionLoopMode.UseDefault);
          this.buildLoopModeOption('循环播放', ActionLoopMode.Loop);
          this.buildLoopModeOption('播放一次', ActionLoopMode.PlayOnce);

          // 恢复默认设置(loopMode 非 UseDefault 时显示)
          if (this.detailsCard!.loopMode !== ActionLoopMode.UseDefault) {
            Button('恢复默认设置')
              .fontSize(13)
              .height(36)
              .width('100%')
              .backgroundColor('#f0f0f0')
              .fontColor('#666666')
              .margin({ top: 12 })
              .onClick(() => {
                this.onClickResetLoopMode();
              });
          }

          // 关闭按钮
          Button('关闭')
            .fontSize(14)
            .height(40)
            .width('100%')
            .backgroundColor('#007DFF')
            .fontColor('#ffffff')
            .margin({ top: 16 })
            .key('actionDetail.close')
            .onClick(() => {
              this.closeDetailsSheet();
            });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
      .width('88%')
      .height('80%')
      .backgroundColor('#ffffff')
      .borderRadius(16)
      .padding(20)
      .scrollBar(BarState.Auto);
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center);
  }

  /**
   * T-4.2 阶段5: 关闭详情弹窗并释放 3D 预览资源。
   */
  private closeDetailsSheet(): void {
    this.detailsCard = null;
    this.cleanupDetailsPreview();
  }

  /**
   * T-4.2 阶段5: 打开详情弹窗并初始化 3D 预览。
   */
  private openDetailsSheet(card: ActionCardItem): void {
    this.detailsCard = card;
    this.initDetailsPreview(card);
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

  @Builder
  buildLoopModeOption(label: string, mode: ActionLoopMode): void {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#333333')
        .layoutWeight(1);
      // 选中标记
      if (this.detailsCard!.loopMode === mode) {
        Text('✓')
          .fontSize(16)
          .fontColor('#007DFF');
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .borderRadius(8)
    .backgroundColor(this.detailsCard!.loopMode === mode ? '#E6F0FF' : '#f9f9f9')
    .margin({ bottom: 8 })
    .onClick(() => {
      this.onClickSetLoopMode(mode);
    });
  }

  /**
   * T-3D.6C-C: 设置循环模式。
   */
  private async onClickSetLoopMode(mode: ActionLoopMode): Promise<void> {
    if (this.detailsCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.detailsCard;
    const actionId: string = card.id;
    const modelId: string = this.currentModelId();
    const ok: boolean = await this.vm.setLoopMode(modelId, actionId, mode);
    if (ok) {
      // 更新当前详情卡片的 loopMode(避免重新加载整列表)
      card.loopMode = mode;
      this.closeDetailsSheet();
      promptAction.showToast({ message: '已设置为' + this.vm.getLoopModeLabel(mode), duration: 1500 });
      await this.loadActionCards();
    } else {
      promptAction.showToast({ message: '设置失败', duration: 1500 });
    }
  }

  /**
   * T-3D.6C-C: 恢复默认循环模式。
   */
  private async onClickResetLoopMode(): Promise<void> {
    if (this.detailsCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.detailsCard;
    const actionId: string = card.id;
    const modelId: string = this.currentModelId();
    const ok: boolean = await this.vm.resetLoopMode(modelId, actionId);
    if (ok) {
      card.loopMode = ActionLoopMode.UseDefault;
      this.closeDetailsSheet();
      promptAction.showToast({ message: '已恢复默认', duration: 1500 });
      await this.loadActionCards();
    } else {
      promptAction.showToast({ message: '恢复失败', duration: 1500 });
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
   * 单击卡片:打开预览。
   */
  private async onClickCard(card: ActionCardItem): Promise<void> {
    this.selectedCardId = card.id;
    this.previewCard = card;
    this.previewLoading = true;
    this.previewPlaying = false;
    await this.loadPreviewScene(card);
  }

  /**
   * T-4.2D: 加载预览 Scene(复用 ActionAvatarPreviewViewModel 的 bounds 驱动取景)。
   *
   * 修复前(T-4.2C):使用独立的 supplementPreviewScene 硬编码 camera position,
   *                 未设置 camera.enabled/rotation,未应用 modelRootNodes transform → 灰屏。
   * 修复后:复用 ActionAvatarPreviewViewModel,与 detailsSheet 使用同一套 bounds 驱动逻辑。
   */
  private async loadPreviewScene(card: ActionCardItem): Promise<void> {
    this.cleanupPreviewScene();
    this.previewNotice = '';
    this.previewAvatarName = '';

    const avatarLibraryService: AvatarLibraryService | null = AppServices.getAvatarLibraryService();
    if (avatarLibraryService === null) {
      Logger.warn(LOG_TAG, 'loadPreviewScene: AvatarLibraryService null');
      this.previewNotice = 'Avatar 服务未就绪';
      this.previewLoading = false;
      return;
    }

    // T-4.2D: 创建 ActionAvatarPreviewViewModel 复用 bounds 驱动取景
    const vm: ActionAvatarPreviewViewModel = new ActionAvatarPreviewViewModel();
    vm.setAvatarLibraryService(avatarLibraryService);
    const char3DService: Character3DService | null = AppServices.getCharacter3DService();
    if (char3DService !== null) {
      vm.setCharacter3DService(char3DService);
    }
    // T-4.2E: 注入 AppContext 用于读取 rawfile 动作包
    vm.setAppContext(getContext(this) as common.Context);
    vm.onStateChanged = (state: ActionPreview3DState): void => {
      Logger.info(LOG_TAG, 'loadPreviewScene: state=' + state);
      this.previewVmState = state;
      // T-4.2E: 根据状态更新提示文案
      switch (state) {
        case ActionPreview3DState.LoadingAvatar:
        case ActionPreview3DState.LoadingMotion:
        case ActionPreview3DState.PreparingRetarget:
          this.previewNotice = '正在准备动作……';
          break;
        case ActionPreview3DState.Ready:
          this.previewNotice = '就绪：' + card.displayName;
          break;
        case ActionPreview3DState.Playing:
          this.previewNotice = '正在播放：' + card.displayName;
          break;
        case ActionPreview3DState.Paused:
          this.previewNotice = '已暂停：' + card.displayName;
          break;
        case ActionPreview3DState.Failed:
          // 错误信息由 onError 回调设置
          break;
        default:
          break;
      }
    };
    vm.onError = (message: string): void => {
      this.previewNotice = message;
      Logger.error(LOG_TAG, 'loadPreviewScene error: ' + message);
    };
    vm.onSceneReady = (scene: Scene | null): void => {
      this.previewScene = scene;
      Logger.info(LOG_TAG, 'loadPreviewScene: onSceneReady, scene=' + (scene !== null));
    };
    vm.onAvatarInfo = (displayName: string, _hasAnimation: boolean): void => {
      this.previewAvatarName = displayName;
    };
    vm.onPrepareProgress = (message: string): void => {
      this.previewNotice = message;
    };

    this.previewVm = vm;
    this.previewNotice = '正在准备动作……';

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
      Logger.error(LOG_TAG, 'loadPreviewScene failed: ' + (e as Error)?.message);
      this.previewNotice = '加载 Avatar 失败: ' + (e as Error)?.message;
    } finally {
      this.previewLoading = false;
    }
  }

  /**
   * 切换预览播放/暂停。
   */
  private togglePreviewPlay(): void {
    // T-4.2E: 优先通过 ViewModel 调用 Retarget Controller
    if (this.previewVm !== null) {
      if (this.previewVmState === ActionPreview3DState.Playing) {
        this.previewVm.pause();
      } else {
        this.previewVm.play();
      }
      return;
    }
    // 回退:ArkGraphics3D 内置动画
    if (this.previewAnimation === null) {
      return;
    }
    try {
      if (this.previewPlaying) {
        this.previewAnimation.stop();
        this.previewPlaying = false;
      } else {
        this.previewAnimation.start();
        this.previewPlaying = true;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'togglePreviewPlay failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 重新播放预览。
   */
  private replayPreview(): void {
    // T-4.2E: 优先通过 ViewModel 调用 Retarget Controller
    if (this.previewVm !== null) {
      this.previewVm.replay();
      return;
    }
    if (this.previewAnimation === null || this.previewScene === null) {
      return;
    }
    try {
      this.previewAnimation.stop();
      this.previewAnimation.start();
      this.previewPlaying = true;
    } catch (e) {
      Logger.warn(LOG_TAG, 'replayPreview failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 停止预览。
   */
  private stopPreview(): void {
    // T-4.2E: 优先通过 ViewModel 调用 Retarget Controller
    if (this.previewVm !== null) {
      this.previewVm.stop();
      return;
    }
    if (this.previewAnimation === null) {
      return;
    }
    try {
      this.previewAnimation.stop();
      this.previewPlaying = false;
    } catch (e) {
      Logger.warn(LOG_TAG, 'stopPreview failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 关闭预览弹层。
   */
  private closePreview(): void {
    this.cleanupPreviewScene();
    this.previewCard = null;
    this.previewLoading = false;
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
   * 从管理菜单恢复默认名称。
   */
  private async onClickResetNameFromManage(): Promise<void> {
    if (this.manageCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.manageCard;
    this.manageCard = null;
    const ok: boolean = await this.vm.resetBuiltinActionName(card.id);
    if (ok) {
      promptAction.showToast({ message: '已恢复默认名称', duration: 1500 });
      await this.loadActionCards();
    } else {
      promptAction.showToast({ message: '恢复失败', duration: 2000 });
    }
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
   * 查看详情。
   */
  private onClickShowDetails(): void {
    if (this.manageCard === null) {
      return;
    }
    const card: ActionCardItem = this.manageCard;
    this.manageCard = null;
    const details: string = 'ID: ' + card.id + '\n'
      + 'Clip: ' + card.clipName + '\n'
      + '时长: ' + this.formatDuration(card.durationMs) + '\n'
      + '循环: ' + (card.loop ? '是' : '否') + '\n'
      + '来源: ' + (card.isBuiltIn ? '内置' : '导入') + '\n'
      + '骨骼: ' + getSkeletonProfileDisplayName(card.skeletonProfile) + '\n'
      + '兼容: ' + getCompatibilityLevelDisplayName(card.compatibilityLevel);
    promptAction.showDialog({
      title: card.displayName,
      message: details,
      buttons: [{ text: '关闭', color: '#007DFF' }]
    });
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
   * 应用动作到当前模型。
   */
  private async onClickApplyAction(): Promise<void> {
    if (this.previewCard === null || this.vm === null) {
      return;
    }
    const card: ActionCardItem = this.previewCard;
    // 绑定到动作的默认槽位
    const slot: Character3DActionSlot = this.parseSlotFromString(card.asset.slot);
    const ok: boolean = await this.vm.bindActionToSlot(card.id, slot, this.modelConfig.displayName);
    if (ok) {
      promptAction.showToast({
        message: '已应用到当前模型',
        duration: 1500
      });
      await this.loadActionCards();
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
