/**
 * HumanoidMappingPage 手动人形骨骼映射页面
 *
 * T-3D.6E P3: 实现可保存的手动人形骨骼映射基础功能。
 *
 * 功能:
 * - 顶部模型摘要:模型名 / 总节点数 / 已匹配 / 必需缺失
 * - 操作按钮:保存 / 重置 / 自动匹配 / 验证
 * - Tab 切换:标准关节列表 / 骨骼树
 * - 标准关节列表:显示每个标准关节的匹配状态,可单击选中
 * - 骨骼树:显示模型节点列表,支持搜索,可单击选中源骨骼
 * - 选中后底部显示"匹配"按钮,将选中标准关节映射到选中源骨骼
 * - 支持取消匹配、清空所有匹配
 * - 验证结果列表(错误/警告)
 *
 * 已知限制(本任务不实现):
 * - 3D 模型预览(下一阶段接入)
 * - 骨架可视化(下一阶段接入 BoneDebugOverlay)
 * - 3D 点选骨骼
 *
 * 性能:
 * - 标准关节固定 24 个,直接 ForEach
 * - 骨骼树可能 500+ 节点(Grace 524),使用 LazyForEach 懒加载
 * - 搜索过滤时仅刷新可见列表
 */

import { router, promptAction } from '@kit.ArkUI';
import { Scene } from '@kit.ArkGraphics3D';
import { AppServices } from '../services/AppServices';
import {
  HumanoidMappingViewModel,
  StandardJointItem,
  BoneTreeNode,
  getBoneDisplayName
} from '../viewmodels/HumanoidMappingViewModel';
import { Character3DPocViewModel } from '../viewmodels/Character3DPocViewModel';
import { Character3DLoadStateEnum } from '../models/character3d/Character3DLoadState';
import {
  HumanoidBone
} from '../models/character3d/HumanoidBone';
import {
  HumanoidMappingValidationResult,
  HumanoidMappingIssue,
  HumanoidMappingIssueLevel
} from '../models/character3d/HumanoidMappingValidator';
import {
  HumanoidJointBinding,
  ManualHumanoidMapping
} from '../models/character3d/ManualHumanoidMapping';
import {
  BoneClickCandidate,
  MappingInteractionMode,
  SurfacePickingInput
} from '../models/character3d/SurfaceBoneCandidate';
import {
  CAMERA_FOV,
  CAMERA_HEIGHT,
  CAMERA_NEAR,
  CAMERA_FAR
} from '../models/character3d/Character3DDisplayConfig';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'HumanoidMappingPage';

/** Tab 枚举 */
enum MappingTab {
  StandardJoints = 0,
  BoneTree = 1,
  SurfacePicking = 2,
  Validation = 3
}

/** 骨骼树数据源(LazyForEach) */
class BoneTreeDataSource implements IDataSource {
  private items: BoneTreeNode[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): BoneTreeNode {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  setItems(items: BoneTreeNode[]): void {
    this.items = items;
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

@Entry
@Component
struct HumanoidMappingPage {
  @State private vm: HumanoidMappingViewModel | null = null;
  @State private isInitializing: boolean = true;
  @State private errorMessage: string = '';

  // 模型摘要
  @State private modelDisplayName: string = '';
  @State private totalNodeCount: number = 0;
  @State private hasSkins: boolean = false;
  @State private mappedCount: number = 0;
  @State private requiredMissingCount: number = 0;
  @State private autoMappedCount: number = 0;
  @State private manualMappedCount: number = 0;

  // 当前 Tab
  @State private currentTab: MappingTab = MappingTab.StandardJoints;

  // 标准关节列表
  @State private standardJoints: StandardJointItem[] = [];

  // 骨骼树
  private boneTreeDataSource: BoneTreeDataSource = new BoneTreeDataSource();
  @State private searchKeyword: string = '';

  // 选中状态
  @State private selectedBone: HumanoidBone | null = null;
  @State private selectedBoneName: string = '';
  @State private selectedSourceNodeIndex: number = -1;
  @State private selectedSourceNodeName: string = '';

  // 验证结果
  @State private validationResult: HumanoidMappingValidationResult | null = null;
  @State private allIssues: HumanoidMappingIssue[] = [];

  // 操作状态
  @State private isSaving: boolean = false;
  @State private isValidating: boolean = false;

  // T-3D.6F-A: 3D 预览与表面点选
  /** 3D 预览 ViewModel(复用 Character3DPocViewModel 的渲染能力) */
  @State private pocVm: Character3DPocViewModel | null = null;
  /** 当前 Scene(null 时不渲染 Component3D) */
  @State private scene: Scene | null = null;
  /** 3D 预览是否已初始化 */
  @State private pocReady: boolean = false;
  /** 点选交互模式 */
  @State private interactionMode: MappingInteractionMode = MappingInteractionMode.Normal;
  /** 当前候选列表 */
  @State private candidates: BoneClickCandidate[] = [];
  /** 已选中的候选索引(-1 未选) */
  @State private confirmedCandidateIndex: number = -1;
  /** 3D 预览区域宽度(px) */
  private previewWidth: number = 0;
  /** 3D 预览区域高度(px) */
  private previewHeight: number = 0;

  // 避让高度
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  aboutToAppear(): void {
    Logger.info(LOG_TAG, 'aboutToAppear');
    this.initializePage();
  }

  aboutToDisappear(): void {
    // T-3D.6F-A: 释放 3D 预览资源
    if (this.pocVm !== null) {
      this.pocVm.dispose();
      this.pocVm = null;
      this.scene = null;
    }
  }

  private async initializePage(): Promise<void> {
    try {
      await AppServices.whenReady();
      this.vm = AppServices.createHumanoidMappingViewModel();
      const ok: boolean = await this.vm.initialize();
      if (!ok) {
        this.errorMessage = '未导入模型或模型信息不可用,请先在动作管理页导入模型';
        this.isInitializing = false;
        return;
      }
      this.refreshAll();
      // T-3D.6F-A: 如果模型有 Skin,初始化 3D 预览用于表面点选
      if (this.hasSkins) {
        await this.initialize3DPreview();
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize failed: ' + (e as Error)?.message);
      this.errorMessage = '初始化失败: ' + (e as Error)?.message;
    } finally {
      this.isInitializing = false;
    }
  }

  /**
   * T-3D.6F-A: 初始化 3D 预览(复用 Character3DPocViewModel)。
   *
   * 仅在有 Skin 的模型上初始化,用于表面点选。
   */
  private async initialize3DPreview(): Promise<void> {
    try {
      const character3DService = AppServices.getCharacter3DService();
      if (character3DService === null) {
        Logger.warn(LOG_TAG, 'initialize3DPreview: character3DService is null');
        return;
      }
      const pocVm: Character3DPocViewModel = new Character3DPocViewModel();
      pocVm.setService(character3DService);
      // 设置状态回调
      pocVm.onStateChanged = (state: Character3DLoadStateEnum): void => {
        if (state === Character3DLoadStateEnum.Ready) {
          this.scene = pocVm.getScene();
          this.pocReady = true;
          Logger.info(LOG_TAG, 'initialize3DPreview: scene ready');
        } else if (state === Character3DLoadStateEnum.Failed) {
          Logger.warn(LOG_TAG, 'initialize3DPreview: scene failed');
        }
      };
      this.pocVm = pocVm;
      await pocVm.initialize();
    } catch (e) {
      Logger.warn(LOG_TAG, 'initialize3DPreview failed: ' + (e as Error)?.message);
    }
  }

  /**
   * 刷新所有 UI 状态。
   */
  private refreshAll(): void {
    if (this.vm === null) {
      return;
    }
    this.modelDisplayName = this.vm.getModelDisplayName();
    this.totalNodeCount = this.vm.getTotalNodeCount();
    this.hasSkins = this.vm.hasSkins();
    this.standardJoints = this.vm.buildStandardJointItems();
    this.refreshBoneTree();
    this.refreshMappingStats();
    this.validationResult = this.vm.getValidationResult();
    this.allIssues = this.vm.getAllIssues();
  }

  /**
   * 刷新骨骼树(应用搜索过滤)。
   */
  private refreshBoneTree(): void {
    if (this.vm === null) {
      this.boneTreeDataSource.setItems([]);
      return;
    }
    this.vm.setSearchKeyword(this.searchKeyword);
    const nodes: BoneTreeNode[] = this.vm.buildBoneTreeNodes();
    this.boneTreeDataSource.setItems(nodes);
  }

  /**
   * 刷新映射统计。
   */
  private refreshMappingStats(): void {
    if (this.vm === null) {
      return;
    }
    const mapping: ManualHumanoidMapping | null = this.vm.getMapping();
    if (mapping === null) {
      this.mappedCount = 0;
      this.requiredMissingCount = 0;
      this.autoMappedCount = 0;
      this.manualMappedCount = 0;
      return;
    }
    this.mappedCount = mapping.joints.length;
    this.requiredMissingCount = mapping.requiredMissing.length;
    this.autoMappedCount = mapping.autoMappedCount;
    this.manualMappedCount = mapping.manualMappedCount;
  }

  build(): void {
    NavDestination() {
      Column() {
        this.buildHeader();
        if (this.isInitializing) {
          this.buildLoading();
        } else if (this.errorMessage.length > 0) {
          this.buildError();
        } else {
          this.buildModelSummary();
          this.buildTabBar();
          if (this.currentTab === MappingTab.StandardJoints) {
            this.buildStandardJointsTab();
          } else if (this.currentTab === MappingTab.BoneTree) {
            this.buildBoneTreeTab();
          } else if (this.currentTab === MappingTab.SurfacePicking) {
            this.buildSurfacePickingTab();
          } else {
            this.buildValidationTab();
          }
          this.buildBottomActionBar();
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
      Text('骨骼映射')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
        .margin({ left: 8 });
      Blank();
      // 自动匹配按钮
      Button('自动匹配')
        .fontSize(12)
        .height(30)
        .backgroundColor('#17a2b8')
        .fontColor('#ffffff')
        .padding({ left: 10, right: 10 })
        .enabled(!this.isInitializing && this.errorMessage.length === 0)
        .onClick(() => {
          this.onClickAutoMap();
        });
      // 验证按钮
      Button('验证')
        .fontSize(12)
        .height(30)
        .backgroundColor('#ffc107')
        .fontColor('#333333')
        .padding({ left: 10, right: 10 })
        .margin({ left: 8 })
        .enabled(!this.isInitializing && this.errorMessage.length === 0)
        .onClick(() => {
          this.onClickValidate();
        });
      // 保存按钮
      Button('保存')
        .fontSize(12)
        .height(30)
        .backgroundColor('#28a745')
        .fontColor('#ffffff')
        .padding({ left: 10, right: 10 })
        .margin({ left: 8 })
        .enabled(!this.isInitializing && this.errorMessage.length === 0 && !this.isSaving)
        .onClick(() => {
          this.onClickSave();
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
      Text('加载模型信息...')
        .fontSize(14)
        .fontColor('#666666')
        .margin({ top: 12 });
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center);
  }

  // ==================== 错误状态 ====================

  @Builder
  buildError(): void {
    Column() {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(48)
        .fontColor(['#dc3545']);
      Text(this.errorMessage)
        .fontSize(14)
        .fontColor('#666666')
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 });
      Button('返回动作管理')
        .fontSize(13)
        .height(36)
        .backgroundColor('#007DFF')
        .fontColor('#ffffff')
        .margin({ top: 16 })
        .onClick(() => {
          router.back();
        });
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  // ==================== 模型摘要 ====================

  @Builder
  buildModelSummary(): void {
    Column() {
      Row() {
        Text(this.modelDisplayName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        if (this.hasSkins) {
          Text('有 Skin')
            .fontSize(10)
            .fontColor('#28a745')
            .backgroundColor('#e8f5e9')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin({ left: 8 });
        } else {
          Text('无 Skin')
            .fontSize(10)
            .fontColor('#dc3545')
            .backgroundColor('#fbe9e7')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin({ left: 8 });
        }
      }
      .width('100%');

      Row() {
        Column() {
          Text(this.totalNodeCount.toString())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#333333');
          Text('节点')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1);

        Column() {
          Text(this.mappedCount.toString())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#007DFF');
          Text('已匹配')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1);

        Column() {
          Text(this.autoMappedCount.toString())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#28a745');
          Text('自动')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1);

        Column() {
          Text(this.manualMappedCount.toString())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#17a2b8');
          Text('手动')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1);

        Column() {
          Text(this.requiredMissingCount.toString())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.requiredMissingCount === 0 ? '#28a745' : '#dc3545');
          Text('必需缺失')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1);
      }
      .width('100%')
      .margin({ top: 8 });
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#ffffff')
    .borderRadius(0);
  }

  // ==================== Tab 栏 ====================

  @Builder
  buildTabBar(): void {
    Row() {
      this.buildTabItem('标准关节', MappingTab.StandardJoints);
      this.buildTabItem('骨骼树', MappingTab.BoneTree);
      if (this.hasSkins) {
        this.buildTabItem('表面点选', MappingTab.SurfacePicking);
      }
      this.buildTabItem('验证结果', MappingTab.Validation);
    }
    .width('100%')
    .height(40)
    .backgroundColor('#ffffff');
  }

  @Builder
  buildTabItem(label: string, tab: MappingTab): void {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(this.currentTab === tab ? '#007DFF' : '#666666')
        .fontWeight(this.currentTab === tab ? FontWeight.Medium : FontWeight.Normal);
      // 下划线
      Divider()
        .strokeWidth(2)
        .color(this.currentTab === tab ? '#007DFF' : 'transparent')
        .width('60%')
        .margin({ top: 6 });
    }
    .layoutWeight(1)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.currentTab = tab;
    });
  }

  // ==================== 标准关节 Tab ====================

  @Builder
  buildStandardJointsTab(): void {
    Scroll() {
      Column() {
        if (this.standardJoints.length === 0) {
          Text('无标准关节数据')
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 24 });
        } else {
          ForEach(this.standardJoints, (item: StandardJointItem, index: number) => {
            this.buildStandardJointItem(item);
          }, (item: StandardJointItem) => item.bone);
        }
        Blank().height(80);
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 });
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off);
  }

  @Builder
  buildStandardJointItem(item: StandardJointItem): void {
    Row() {
      // 必需标记
      Text(item.required ? '必' : '选')
        .fontSize(10)
        .fontColor('#ffffff')
        .backgroundColor(item.required ? '#dc3545' : '#999999')
        .width(20)
        .height(20)
        .borderRadius(10)
        .textAlign(TextAlign.Center)
        .margin({ right: 8 });

      // 关节名
      Column() {
        Text(item.displayName)
          .fontSize(14)
          .fontColor(this.selectedBone === item.bone ? '#007DFF' : '#333333')
          .fontWeight(this.selectedBone === item.bone ? FontWeight.Medium : FontWeight.Normal);
        if (item.binding !== null) {
          Text('→ ' + item.binding.sourceBoneName)
            .fontSize(11)
            .fontColor('#666666')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      // 状态标签
      Text(item.statusText)
        .fontSize(11)
        .fontColor('#ffffff')
        .backgroundColor(item.statusColor)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .margin({ left: 8 });

      // 取消匹配按钮
      if (item.binding !== null) {
        SymbolGlyph($r('sys.symbol.xmark_circle'))
          .fontSize(18)
          .fontColor(['#dc3545'])
          .margin({ left: 8 })
          .onClick(() => {
            this.onClickUnbind(item.bone);
          });
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .backgroundColor(this.selectedBone === item.bone ? '#e3f2fd' : '#ffffff')
    .borderRadius(8)
    .margin({ bottom: 4 })
    .onClick(() => {
      this.onClickSelectBone(item.bone);
    });
  }

  // ==================== 骨骼树 Tab ====================

  @Builder
  buildBoneTreeTab(): void {
    Column() {
      // 搜索栏
      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor(['#999999'])
          .margin({ right: 8 });
        TextInput({
          text: this.searchKeyword,
          placeholder: '搜索骨骼名称'
        })
          .fontSize(13)
          .backgroundColor('transparent')
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchKeyword = value;
            this.refreshBoneTree();
          });
        if (this.searchKeyword.length > 0) {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(18)
            .fontColor(['#999999'])
            .margin({ left: 8 })
            .onClick(() => {
              this.searchKeyword = '';
              this.refreshBoneTree();
            });
        }
      }
      .width('100%')
      .height(40)
      .padding({ left: 12, right: 12 })
      .backgroundColor('#ffffff');

      // 骨骼树列表
      if (this.boneTreeDataSource.totalCount() === 0) {
        Column() {
          Text(this.searchKeyword.length > 0 ? '无匹配骨骼' : '无骨骼数据')
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 24 });
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center);
      } else {
        List({ space: 2 }) {
          LazyForEach(this.boneTreeDataSource, (item: BoneTreeNode) => {
            ListItem() {
              this.buildBoneTreeItem(item);
            }
          }, (item: BoneTreeNode) => item.nodeIndex.toString());
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .padding({ left: 8, right: 8, top: 4 });
      }
    }
    .width('100%')
    .layoutWeight(1);
  }

  @Builder
  buildBoneTreeItem(item: BoneTreeNode): void {
    Row() {
      // 缩进(扁平结构,简化展示)
      Text('#' + item.nodeIndex)
        .fontSize(11)
        .fontColor('#999999')
        .width(48);

      // 骨骼名
      Text(item.name)
        .fontSize(13)
        .fontColor(this.selectedSourceNodeIndex === item.nodeIndex ? '#007DFF' : '#333333')
        .fontWeight(this.selectedSourceNodeIndex === item.nodeIndex ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      // skin joint 标记
      if (item.isSkinJoint) {
        Text('joint')
          .fontSize(9)
          .fontColor('#28a745')
          .backgroundColor('#e8f5e9')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .margin({ left: 4 });
      }

      // 已映射标记
      if (item.isMapped) {
        Text('→ ' + item.mappedTargetName)
          .fontSize(10)
          .fontColor('#007DFF')
          .backgroundColor('#e3f2fd')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .margin({ left: 4 });
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 12, right: 12 })
    .backgroundColor(this.selectedSourceNodeIndex === item.nodeIndex ? '#e3f2fd' : '#ffffff')
    .borderRadius(6)
    .onClick(() => {
      this.onClickSelectSourceNode(item.nodeIndex, item.name);
    });
  }

  // ==================== T-3D.6F-A: 表面点选 Tab ====================

  @Builder
  buildSurfacePickingTab(): void {
    Column() {
      // 顶部提示栏
      this.buildPickingHintBar();

      // 3D 预览区域
      Stack() {
        if (this.scene !== null) {
          Component3D({
            scene: this.scene as Scene,
            modelType: ModelType.SURFACE
          })
            .width('100%')
            .height('100%')
            .onTouch((event: TouchEvent) => {
              this.handleSurfaceTouch(event);
            })
            .onAreaChange((_oldValue: Area, newValue: Area) => {
              const w: number = typeof newValue.width === 'number' ? newValue.width : 0;
              const h: number = typeof newValue.height === 'number' ? newValue.height : 0;
              if (w > 0 && h > 0) {
                this.previewWidth = w;
                this.previewHeight = h;
              }
            })
        } else {
          Column() {
            LoadingProgress().width(32).height(32).color('#007DFF');
            Text(this.hasSkins ? '正在加载 3D 预览...' : '当前模型无 Skin,无法表面点选')
              .fontSize(12)
              .fontColor('#999999')
              .margin({ top: 8 });
          }
          .justifyContent(FlexAlign.Center);
        }

        // 点选模式浮层提示
        if (this.interactionMode === MappingInteractionMode.SurfacePicking) {
          Column() {
            Text('👆 点击模型表面选择骨骼')
              .fontSize(13)
              .fontColor('#ffffff')
              .backgroundColor('rgba(0,125,255,0.85)')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(16);
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 8 });
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#1a1a1a');

      // 候选列表区域
      if (this.candidates.length > 0) {
        this.buildCandidateList();
      }
    }
    .width('100%')
    .layoutWeight(1);
  }

  @Builder
  buildPickingHintBar(): void {
    Row() {
      // 当前目标关节
      Column() {
        Text('目标关节')
          .fontSize(10)
          .fontColor('#999999');
        Text(this.selectedBoneName.length > 0 ? this.selectedBoneName : '未选择')
          .fontSize(13)
          .fontColor(this.selectedBone !== null ? '#007DFF' : '#666666')
          .fontWeight(FontWeight.Medium);
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      // 操作按钮
      if (this.interactionMode === MappingInteractionMode.Normal) {
        Button('点击模型选择')
          .fontSize(12)
          .height(30)
          .backgroundColor('#17a2b8')
          .fontColor('#ffffff')
          .padding({ left: 10, right: 10 })
          .enabled(this.selectedBone !== null && this.hasSkins && this.pocReady)
          .onClick(() => {
            this.onClickEnterPicking();
          });
        if (this.selectedBone === null) {
          Text('请先在"标准关节"选择目标')
            .fontSize(10)
            .fontColor('#999999')
            .margin({ left: 6 });
        }
      } else if (this.interactionMode === MappingInteractionMode.SurfacePicking) {
        Button('取消')
          .fontSize(12)
          .height(30)
          .backgroundColor('#dc3545')
          .fontColor('#ffffff')
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.onClickCancelPicking();
          });
      } else if (this.interactionMode === MappingInteractionMode.ConfirmCandidate) {
        Button('重新选择')
          .fontSize(12)
          .height(30)
          .backgroundColor('#6c757d')
          .fontColor('#ffffff')
          .padding({ left: 10, right: 10 })
          .onClick(() => {
            this.onClickCancelPicking();
          });
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#ffffff');
  }

  @Builder
  buildCandidateList(): void {
    Column() {
      Text('检测到候选骨骼(点击选中,然后确认)')
        .fontSize(11)
        .fontColor('#666666')
        .padding({ left: 12, top: 6, bottom: 4 });

      Scroll() {
        Column() {
          ForEach(this.candidates, (candidate: BoneClickCandidate, index: number) => {
            this.buildCandidateItem(candidate, index);
          }, (candidate: BoneClickCandidate) => candidate.nodeIndex.toString());
          Blank().height(4);
        }
        .width('100%');
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto);

      // 确认/取消按钮
      Row() {
        Button('取消')
          .fontSize(13)
          .height(36)
          .backgroundColor('#6c757d')
          .fontColor('#ffffff')
          .layoutWeight(1)
          .onClick(() => {
            this.onClickCancelPicking();
          });
        Button('确认匹配')
          .fontSize(13)
          .height(36)
          .backgroundColor('#28a745')
          .fontColor('#ffffff')
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(this.confirmedCandidateIndex >= 0)
          .onClick(() => {
            this.onClickConfirmCandidate();
          });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 8 });
    }
    .width('100%')
    .height('40%')
    .backgroundColor('#f9f9f9')
    .border({ width: { top: 1 }, color: '#e0e0e0' });
  }

  @Builder
  buildCandidateItem(candidate: BoneClickCandidate, index: number): void {
    Row() {
      // 序号
      Text('#' + (index + 1))
        .fontSize(11)
        .fontColor('#999999')
        .width(28);

      // 骨骼名
      Column() {
        Text(candidate.boneName)
          .fontSize(13)
          .fontColor(this.confirmedCandidateIndex === index ? '#007DFF' : '#333333')
          .fontWeight(this.confirmedCandidateIndex === index ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text('node #' + candidate.nodeIndex)
          .fontSize(10)
          .fontColor('#999999')
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      // 评分
      Column() {
        Text((candidate.score * 100).toFixed(1) + '%')
          .fontSize(13)
          .fontColor('#28a745')
          .fontWeight(FontWeight.Medium);
        Text('权重 ' + candidate.averageWeight.toFixed(2))
          .fontSize(10)
          .fontColor('#999999')
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.End)
      .width(80);

      // 选中标记
      if (this.confirmedCandidateIndex === index) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(18)
          .fontColor(['#28a745'])
          .margin({ left: 8 });
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 12, right: 12 })
    .backgroundColor(this.confirmedCandidateIndex === index ? '#e8f5e9' : '#ffffff')
    .borderRadius(6)
    .margin({ left: 8, right: 8, bottom: 2 })
    .onClick(() => {
      this.onClickSelectCandidate(index);
    });
  }

  // ==================== 验证结果 Tab ====================

  @Builder
  buildValidationTab(): void {
    Scroll() {
      Column() {
        if (this.validationResult === null) {
          Text('尚未验证,点击右上角"验证"按钮开始')
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 24 });
        } else {
          // 验证摘要
          Row() {
            Column() {
              Text(this.validationResult.valid ? '通过' : '未通过')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.validationResult.valid ? '#28a745' : '#dc3545');
              Text('验证状态')
                .fontSize(10)
                .fontColor('#999999')
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1);

            Column() {
              Text(this.validationResult.retargetReady ? '就绪' : '未就绪')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.validationResult.retargetReady ? '#28a745' : '#ffc107');
              Text('重定向')
                .fontSize(10)
                .fontColor('#999999')
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1);

            Column() {
              Text(this.validationResult.errors.length.toString())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#dc3545');
              Text('错误')
                .fontSize(10)
                .fontColor('#999999')
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1);

            Column() {
              Text(this.validationResult.warnings.length.toString())
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#ffc107');
              Text('警告')
                .fontSize(10)
                .fontColor('#999999')
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1);
          }
          .width('100%')
          .padding(12)
          .backgroundColor('#ffffff')
          .borderRadius(8);

          // 问题列表
          if (this.allIssues.length === 0) {
            Text('无验证问题')
              .fontSize(13)
              .fontColor('#28a745')
              .margin({ top: 16 });
          } else {
            ForEach(this.allIssues, (issue: HumanoidMappingIssue, index: number) => {
              this.buildIssueItem(issue);
            }, (issue: HumanoidMappingIssue) => issue.type + issue.message);
          }
        }
        Blank().height(80);
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 });
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off);
  }

  @Builder
  buildIssueItem(issue: HumanoidMappingIssue): void {
    Row() {
      // 级别标签
      Text(issue.level === HumanoidMappingIssueLevel.Error ? '错误' : '警告')
        .fontSize(10)
        .fontColor('#ffffff')
        .backgroundColor(issue.level === HumanoidMappingIssueLevel.Error ? '#dc3545' : '#ffc107')
        .width(40)
        .height(20)
        .borderRadius(4)
        .textAlign(TextAlign.Center)
        .margin({ right: 8 });

      // 问题类型
      Text(issue.type)
        .fontSize(11)
        .fontColor('#666666')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(140);

      // 消息
      Text(issue.message)
        .fontSize(12)
        .fontColor('#333333')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 12, right: 12 })
    .backgroundColor('#ffffff')
    .borderRadius(6)
    .margin({ bottom: 4 })
    .alignItems(VerticalAlign.Top);
  }

  // ==================== 底部操作栏 ====================

  @Builder
  buildBottomActionBar(): void {
    Column() {
      // 选中状态显示
      Row() {
        Column() {
          Text('标准关节:')
            .fontSize(10)
            .fontColor('#999999');
          Text(this.selectedBoneName.length > 0 ? this.selectedBoneName : '未选择')
            .fontSize(13)
            .fontColor(this.selectedBone !== null ? '#007DFF' : '#666666')
            .fontWeight(FontWeight.Medium);
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Text('→')
          .fontSize(16)
          .fontColor('#999999')
          .margin({ left: 8, right: 8 });

        Column() {
          Text('源骨骼:')
            .fontSize(10)
            .fontColor('#999999');
          Text(this.selectedSourceNodeName.length > 0 ? this.selectedSourceNodeName : '未选择')
            .fontSize(13)
            .fontColor(this.selectedSourceNodeIndex >= 0 ? '#007DFF' : '#666666')
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 });

      // 操作按钮
      Row() {
        Button('匹配')
          .fontSize(13)
          .height(36)
          .backgroundColor('#007DFF')
          .fontColor('#ffffff')
          .layoutWeight(1)
          .enabled(this.selectedBone !== null && this.selectedSourceNodeIndex >= 0)
          .onClick(() => {
            this.onClickBind();
          });
        Button('清空全部')
          .fontSize(13)
          .height(36)
          .backgroundColor('#dc3545')
          .fontColor('#ffffff')
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(this.mappedCount > 0)
          .onClick(() => {
            this.onClickClearAll();
          });
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 });
    }
    .width('100%')
    .backgroundColor('#ffffff')
    .border({ width: { top: 1 }, color: '#e0e0e0' });
  }

  // ==================== 事件处理 ====================

  private onClickSelectBone(bone: HumanoidBone): void {
    if (this.vm === null) {
      return;
    }
    this.vm.selectBone(bone);
    this.selectedBone = bone;
    this.selectedBoneName = getBoneDisplayName(bone);
    // 如果该关节已绑定,显示已绑定的源骨骼
    const items: StandardJointItem[] = this.standardJoints;
    for (let i: number = 0; i < items.length; i++) {
      if (items[i].bone === bone && items[i].binding !== null) {
        const binding: HumanoidJointBinding = items[i].binding as HumanoidJointBinding;
        this.selectedSourceNodeIndex = binding.sourceNodeIndex;
        this.selectedSourceNodeName = binding.sourceBoneName;
        return;
      }
    }
    // 未绑定,清空源骨骼选中(让用户选新的)
    this.selectedSourceNodeIndex = -1;
    this.selectedSourceNodeName = '';
  }

  private onClickSelectSourceNode(nodeIndex: number, name: string): void {
    if (this.vm === null) {
      return;
    }
    this.vm.selectSourceNode(nodeIndex);
    this.selectedSourceNodeIndex = nodeIndex;
    this.selectedSourceNodeName = name;
    // 自动切换到标准关节 Tab(如果尚未选标准关节)
    if (this.selectedBone === null) {
      this.currentTab = MappingTab.StandardJoints;
      promptAction.showToast({
        message: '请选择要映射的标准关节',
        duration: 1500
      });
    }
  }

  private onClickBind(): void {
    if (this.vm === null || this.selectedBone === null || this.selectedSourceNodeIndex < 0) {
      return;
    }
    const ok: boolean = this.vm.bindSelected();
    if (ok) {
      promptAction.showToast({
        message: '匹配成功',
        duration: 1000
      });
      this.refreshAll();
      // 自动跳到下一个未匹配的必需关节
      this.autoSelectNextRequiredUnmapped();
    } else {
      promptAction.showToast({
        message: '匹配失败',
        duration: 1500
      });
    }
  }

  private onClickUnbind(bone: HumanoidBone): void {
    if (this.vm === null) {
      return;
    }
    const ok: boolean = this.vm.unbindBone(bone);
    if (ok) {
      promptAction.showToast({
        message: '已取消匹配',
        duration: 1000
      });
      this.refreshAll();
    }
  }

  private onClickClearAll(): void {
    if (this.vm === null) {
      return;
    }
    promptAction.showDialog({
      title: '清空全部匹配',
      message: '将清除所有已匹配的关节,确定继续?',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '确定', color: '#dc3545' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        const ok: boolean = this.vm!.clearAll();
        if (ok) {
          this.selectedBone = null;
          this.selectedBoneName = '';
          this.selectedSourceNodeIndex = -1;
          this.selectedSourceNodeName = '';
          this.refreshAll();
          promptAction.showToast({
            message: '已清空全部匹配',
            duration: 1000
          });
        }
      }
    });
  }

  private onClickAutoMap(): void {
    if (this.vm === null) {
      return;
    }
    const count: number = this.vm.applyAutoMapping();
    this.refreshAll();
    promptAction.showToast({
      message: '自动匹配 ' + count + ' 个关节(置信度 ≥ 85%)',
      duration: 2000
    });
  }

  private onClickValidate(): void {
    if (this.vm === null) {
      return;
    }
    this.isValidating = true;
    try {
      const result: HumanoidMappingValidationResult = this.vm.validate();
      this.validationResult = result;
      this.allIssues = this.vm.getAllIssues();
      this.refreshMappingStats();
      // 自动切换到验证 Tab
      this.currentTab = MappingTab.Validation;
      promptAction.showToast({
        message: result.valid ? '验证通过' : '验证未通过,请查看错误',
        duration: 1500
      });
    } finally {
      this.isValidating = false;
    }
  }

  private async onClickSave(): Promise<void> {
    if (this.vm === null) {
      return;
    }
    this.isSaving = true;
    try {
      const ok: boolean = await this.vm.save();
      promptAction.showToast({
        message: ok ? '保存成功' : '保存失败',
        duration: 1500
      });
    } catch (e) {
      Logger.error(LOG_TAG, 'save failed: ' + (e as Error)?.message);
      promptAction.showToast({
        message: '保存异常: ' + (e as Error)?.message,
        duration: 2000
      });
    } finally {
      this.isSaving = false;
    }
  }

  /**
   * 自动选择下一个未匹配的必需关节。
   */
  private autoSelectNextRequiredUnmapped(): void {
    for (let i: number = 0; i < this.standardJoints.length; i++) {
      const item: StandardJointItem = this.standardJoints[i];
      if (item.required && item.binding === null) {
        this.onClickSelectBone(item.bone);
        return;
      }
    }
    // 所有必需关节已匹配,清空选中
    this.selectedBone = null;
    this.selectedBoneName = '';
    this.selectedSourceNodeIndex = -1;
    this.selectedSourceNodeName = '';
  }

  // ==================== T-3D.6F-A: 表面点选事件处理 ====================

  /**
   * 进入表面点选模式。
   */
  private onClickEnterPicking(): void {
    if (this.vm === null) {
      return;
    }
    // 准备表面点选(解析 GLB,构建世界空间三角形)
    const prepared: boolean = this.vm.prepareSurfacePicking();
    if (!prepared) {
      promptAction.showToast({
        message: '准备点选失败,请检查模型是否有 Skin',
        duration: 2000
      });
      return;
    }
    const ok: boolean = this.vm.enterSurfacePickingMode();
    if (ok) {
      this.interactionMode = MappingInteractionMode.SurfacePicking;
      this.candidates = [];
      this.confirmedCandidateIndex = -1;
    } else {
      promptAction.showToast({
        message: '进入点选模式失败',
        duration: 1500
      });
    }
  }

  /**
   * 取消表面点选,回到 Normal。
   */
  private onClickCancelPicking(): void {
    if (this.vm === null) {
      return;
    }
    this.vm.cancelSurfacePicking();
    this.interactionMode = MappingInteractionMode.Normal;
    this.candidates = [];
    this.confirmedCandidateIndex = -1;
  }

  /**
   * 选择候选(高亮对应骨骼)。
   */
  private onClickSelectCandidate(index: number): void {
    if (this.vm === null) {
      return;
    }
    this.vm.selectCandidate(index);
    this.confirmedCandidateIndex = index;
  }

  /**
   * 确认当前选中的候选,保存为表面映射。
   */
  private onClickConfirmCandidate(): void {
    if (this.vm === null) {
      return;
    }
    // 检查是否已有映射,询问是否替换
    if (this.vm.hasExistingBindingForSelectedBone()) {
      promptAction.showDialog({
        title: '替换已有映射',
        message: '该关节已有映射,是否替换?',
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '替换', color: '#28a745' }
        ]
      }).then((result) => {
        if (result.index === 1) {
          this.doConfirmCandidate(true);
        }
      });
    } else {
      this.doConfirmCandidate(false);
    }
  }

  private doConfirmCandidate(replace: boolean): void {
    if (this.vm === null) {
      return;
    }
    const ok: boolean = this.vm.confirmCandidate(replace);
    if (ok) {
      promptAction.showToast({
        message: '表面点选匹配成功',
        duration: 1200
      });
      this.interactionMode = MappingInteractionMode.Normal;
      this.candidates = [];
      this.confirmedCandidateIndex = -1;
      this.refreshAll();
    } else {
      promptAction.showToast({
        message: '确认失败,候选无效',
        duration: 1500
      });
    }
  }

  /**
   * 处理 3D 预览区域的触摸事件(仅 SurfacePicking 模式响应)。
   *
   * 仅响应 TouchType.Up(点击抬起),获取屏幕坐标并执行点选。
   */
  private handleSurfaceTouch(event: TouchEvent): void {
    if (this.vm === null || this.interactionMode !== MappingInteractionMode.SurfacePicking) {
      return;
    }
    if (this.previewWidth <= 0 || this.previewHeight <= 0) {
      Logger.warn(LOG_TAG, 'handleSurfaceTouch: preview size not ready');
      return;
    }
    // 仅处理 Up 事件(点击抬起)
    if (event.type !== TouchType.Up) {
      return;
    }
    const touches: TouchObject[] = event.touches;
    if (touches.length === 0) {
      return;
    }
    const touch: TouchObject = touches[0];
    // 获取相对于预览区域的坐标
    // touch.x/touch.y 是相对于组件的坐标(px)
    const screenX: number = touch.x;
    const screenY: number = touch.y;
    Logger.info(LOG_TAG, 'handleSurfaceTouch: x=' + screenX + ', y=' + screenY
      + ', w=' + this.previewWidth + ', h=' + this.previewHeight);

    // 构造点选输入
    const displayConfig = this.vm.getDisplayConfig();
    // 相机位置:(0, CAMERA_HEIGHT, cameraDistance) - 与 Character3DPocViewModel 一致
    // 外部模型 camY=0,但 CAMERA_HEIGHT 在程序化几何体时使用
    // 对于外部 GLB 模型,相机位置为 (0, 0, cameraDistance),朝向原点
    const isExternal: boolean = this.modelDisplayName.length > 0;
    const camY: number = isExternal ? 0 : CAMERA_HEIGHT;
    const input: SurfacePickingInput = {
      screenX: screenX,
      screenY: screenY,
      viewportWidth: this.previewWidth,
      viewportHeight: this.previewHeight,
      cameraPosX: 0,
      cameraPosY: camY,
      cameraPosZ: displayConfig.cameraDistance,
      cameraTargetX: 0,
      cameraTargetY: 0,
      cameraTargetZ: 0,
      cameraFovDeg: CAMERA_FOV,
      cameraNear: CAMERA_NEAR,
      cameraFar: CAMERA_FAR
    };
    // 执行点选
    const candidates: BoneClickCandidate[] = this.vm.pickSurfaceBone(input);
    this.candidates = candidates;
    if (candidates.length === 0) {
      promptAction.showToast({
        message: '未命中模型表面,请重试',
        duration: 1200
      });
    } else {
      // 自动选中第一个候选
      this.vm.selectCandidate(0);
      this.confirmedCandidateIndex = 0;
      this.interactionMode = MappingInteractionMode.ConfirmCandidate;
    }
  }
}
