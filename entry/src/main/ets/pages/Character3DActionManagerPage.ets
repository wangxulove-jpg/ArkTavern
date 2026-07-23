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
import { picker } from '@kit.CoreFileKit';
import { Scene, Animation } from '@kit.ArkGraphics3D';
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
  ActionSourceFormat
} from '../models/character3d/HumanoidBone';
import {
  ActionCategory,
  ActionFilter
} from '../models/character3d/UnifiedActionItem';
import {
  getCompatibilityLevelDisplayName,
  getSkeletonProfileDisplayName
} from '../models/character3d/HumanoidBoneMapper';
import { Logger } from '../utils/Logger';
import { ActionPreviewCanvas } from '../components/ActionPreviewCanvas';
import { ActionCardDataSource } from '../viewmodels/ActionCardDataSource';

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

  // ========== 预览 3D 状态 ==========
  @State private previewScene: Scene | null = null;
  @State private previewAnimation: Animation | null = null;
  @State private previewPlaying: boolean = false;
  @State private previewLoading: boolean = false;
  @State private previewPackUri: string = '';

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
      this.loadAllData();
    }).catch((e: Error): void => {
      Logger.error(LOG_TAG, 'whenReady failed: ' + e.message);
      this.errorMessage = '初始化失败: ' + e.message;
      this.isLoading = false;
    });
  }

  aboutToDisappear(): void {
    this.cleanupPreviewScene();
  }

  onPageHide(): void {
    this.cleanupPreviewScene();
  }

  /**
   * 清理预览 Scene 资源。
   */
  private cleanupPreviewScene(): void {
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
            Text('兼容: ' + getCompatibilityLevelDisplayName(this.modelSummary.compatibilityLevel))
              .fontSize(11)
              .fontColor('#666666')
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
            .onClick(() => {
              this.onClickImportModel();
            });
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
        Column() {
          if (this.previewLoading) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#007DFF');
            Text('加载预览...')
              .fontSize(13)
              .fontColor('#666666')
              .margin({ top: 8 });
          } else if (this.previewScene !== null) {
            Component3D({
              scene: this.previewScene as Scene,
              modelType: ModelType.SURFACE
            })
              .width('100%')
              .height('100%');
          } else {
            Column() {
              Text(this.getCategoryIcon(this.previewCard!.category))
                .fontSize(64);
              Text('预览不可用')
                .fontSize(13)
                .fontColor('#999999')
                .margin({ top: 8 });
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center);
          }
        }
        .width('100%')
        .height(300)
        .backgroundColor('#e0e0e0')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);

        // 动作信息
        Column() {
          this.buildPreviewInfoRow('Clip', this.previewCard!.clipName);
          this.buildPreviewInfoRow('时长', this.formatDuration(this.previewCard!.durationMs));
          this.buildPreviewInfoRow('循环', this.getCardEffectiveLoop(this.previewCard!) ? '是' : '否');
          this.buildPreviewInfoRow('来源', this.previewCard!.isBuiltIn ? '内置' : '导入');
          this.buildPreviewInfoRow('分类', this.getCategoryDisplayName(this.previewCard!.category));
          this.buildPreviewInfoRow(
            '兼容',
            this.modelSummary !== null && this.modelSummary.builtinActionCompatible
              ? '完全兼容' : '当前模型不兼容'
          );
        }
        .width('100%')
        .padding(16);

        // 控制按钮
        Row() {
          Button(this.previewPlaying ? '暂停' : '播放')
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor(this.previewPlaying ? '#ff9800' : '#007DFF')
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
            .enabled(this.modelSummary !== null && this.modelSummary.builtinActionCompatible)
            .onClick(() => {
              this.onClickApplyAction();
            });
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 });
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
          this.detailsCard = card;
        });
        // 查看详情(打开详情 Sheet,含循环设置)
        this.buildManageMenuItem('查看详情', () => {
          const card: ActionCardItem = this.manageCard!;
          this.manageCard = null;
          this.detailsCard = card;
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
          this.detailsCard = null;
        });

      Column() {
        // 标题
        Text(this.detailsCard!.displayName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 16 });

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
          .onClick(() => {
            this.detailsCard = null;
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
      this.detailsCard = null;
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
      this.detailsCard = null;
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
   * 加载预览 Scene。
   */
  private async loadPreviewScene(card: ActionCardItem): Promise<void> {
    this.cleanupPreviewScene();
    if (this.vm === null) {
      this.previewLoading = false;
      return;
    }
    try {
      // 确保内置动作包已缓存
      const packUri: string = await this.vm.ensureBuiltinPackReady();
      this.previewPackUri = packUri;
      // 加载 Scene
      const scene: Scene = await Scene.load(packUri);
      this.previewScene = scene;
      // 播放指定动画
      const animations: Animation[] = scene.animations;
      if (animations.length > card.clipIndex && card.clipIndex >= 0) {
        const anim: Animation = animations[card.clipIndex];
        anim.enabled = true;
        anim.start();
        this.previewAnimation = anim;
        this.previewPlaying = true;
      } else if (animations.length > 0) {
        // 回退到第一个动画
        const anim: Animation = animations[0];
        anim.enabled = true;
        anim.start();
        this.previewAnimation = anim;
        this.previewPlaying = true;
      }
      Logger.info(LOG_TAG, 'loadPreviewScene ok: clipIndex=' + card.clipIndex
        + ', anims=' + animations.length);
    } catch (e) {
      Logger.error(LOG_TAG, 'loadPreviewScene failed: ' + (e as Error)?.message);
    } finally {
      this.previewLoading = false;
    }
  }

  /**
   * 切换预览播放/暂停。
   */
  private togglePreviewPlay(): void {
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
