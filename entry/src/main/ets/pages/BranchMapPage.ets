/**
 * BranchMapPage 分支树页面(T-6.4B-1.1)
 *
 * 独立页面,以可点击的分支树形式展示当前 Chat 的所有 Branch。
 * 替代原有平铺式 BranchListPanel 作为 Branch 状态入口的主入口。
 *
 * 功能:
 * - 根据 parentBranchId 构造父子树,Root 位于顶部,Child 向下排列
 * - 父子节点之间使用虚线贝塞尔曲线连接
 * - 当前 Active Branch 使用强调色边框 + 右上角圆点
 * - 节点可点击选中(不立即切换)
 * - 底部"切换到此分支"按钮执行 switchActiveBranch
 * - 支持双向滚动(水平 + 垂直)
 *
 * 数据流:
 * - ChatPage 导航时传入 chatId
 * - BranchMapViewModel 通过 ConversationBranchPersistenceService 加载 Branch 数据
 * - 切换成功后刷新布局
 * - 返回 ChatPage 时由 ChatPage 重新加载消息和 Branch 状态
 *
 * 不依赖:
 * - Repository
 * - ChatService
 * - 页面实例
 */

import { BranchMapViewModel } from '../viewmodels/BranchMapViewModel';
import { AppServices } from '../services/AppServices';
import { BranchMapNode } from '../components/BranchMapNode';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { BranchMapNodeLayout, BranchTreeLayoutResult, BranchTreeEdge } from '../models/BranchMapNodeLayout';
import { Logger } from '../utils/Logger';
import { router } from '@kit.ArkUI';

const LOG_TAG: string = 'BranchMapPage';

// 颜色全部使用 $r('app.color.*') 资源引用,自动适配深色模式。
// 以下常量仅用于字符串资源名拼接(如 $r('app.string.' + RES_BRANCH_MAP_TITLE)),
// 颜色不再使用硬编码字符串。

const RES_BRANCH_MAP_TITLE: string = 'branch_map_title';
const RES_BRANCH_SWITCH: string = 'branch_map_switch_button';
const RES_BRANCH_BACK: string = 'branch_map_back';
const RES_BRANCH_EMPTY: string = 'branch_map_empty';

interface BranchMapRouteParam {
  chatId: string;
}

@Entry
@Component
struct BranchMapPage {
  @State viewModel: BranchMapViewModel = new BranchMapViewModel(
    AppServices.getBranchPersistenceService()
  );
  @State readyHandled: boolean = false;
  @State errorText: string = '';
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  /**
   * 缩放相关状态(T-6.4B-3-R1):
   * - zoomScale: 当前缩放倍率(1.0 = 原始尺寸)
   * - pinchBaseScale: PinchGesture 开始时的 zoomScale 基准
   * - MIN_ZOOM / MAX_ZOOM: 缩放范围限制
   */
  @State zoomScale: number = 1.0;
  @State pinchBaseScale: number = 1.0;
  private readonly MIN_ZOOM: number = 0.5;
  private readonly MAX_ZOOM: number = 2.5;
  private readonly ZOOM_STEP: number = 0.25;

  private verticalScroller: Scroller = new Scroller();
  private horizontalScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.handleReady();
  }

  build() {
    // 外层 Stack alignContent=TopEnd 让缩放控件浮在右上角
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        this.titleBar();

        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        }

        if (this.viewModel.getStatusText().length > 0) {
          Text(this.viewModel.getStatusText())
            .fontSize(12)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
        }

        Divider().color($r('app.color.app_divider')).height(1).width('100%')

        if (this.viewModel.isLoading) {
          this.loadingState();
        } else if (this.viewModel.branches.length === 0) {
          this.emptyState();
        } else {
          this.treeContent();
          this.bottomBar();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 缩放控件浮层(右上角,在树内容加载时显示)
      if (!this.viewModel.isLoading && this.viewModel.branches.length > 0) {
        this.zoomControls()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  titleBar() {
    Row() {
      Button($r('app.string.' + RES_BRANCH_BACK))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_accent'))
        .onClick(() => {
          this.popBack();
        })

      Blank()

      Text($r('app.string.' + RES_BRANCH_MAP_TITLE))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))

      Blank()

      // 占位保持标题居中
      Text('')
        .fontSize(14)
        .width(44)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.statusBarHeight + 4, bottom: 0 })
    .backgroundColor($r('app.color.app_surface_1'))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  loadingState() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyState() {
    Column() {
      Text($r('app.string.' + RES_BRANCH_EMPTY))
        .fontSize(14)
        .fontColor($r('app.color.app_text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  treeContent() {
    if (this.viewModel.layout !== undefined) {
      // 外层垂直滚动,内层水平滚动,实现双向滚动
      Scroll(this.verticalScroller) {
        Scroll(this.horizontalScroller) {
          Stack() {
            // 连接线层(底层):Polyline 折线 + Circle 连接点
            // 与节点同处一个 Stack,会随 Stack scale 一起缩放,实时跟随
            ForEach(this.viewModel.layout.edges,
              (edge: BranchTreeEdge) => {
                this.edgeConnection(edge)
              },
              (edge: BranchTreeEdge) => edge.parentBranchId + '->' + edge.childBranchId
            )

            // 节点(顶层,绝对定位,保持原始坐标)
            ForEach(this.viewModel.layout.nodes,
              (node: BranchMapNodeLayout) => {
                this.nodeWrapper(node)
              },
              (node: BranchMapNodeLayout) => node.branchId
            )
          }
          // 缩放后的画布尺寸(让 Scroll 滚动范围跟随缩放)
          .width(this.viewModel.layout.canvasWidth * this.zoomScale)
          .height(this.viewModel.layout.canvasHeight * this.zoomScale)
          // 整体缩放:从左上角(0,0)为中心,使内容从原点开始放大/缩小
          .scale({
            x: this.zoomScale,
            y: this.zoomScale,
            centerX: '0%',
            centerY: '0%'
          })
          // 双指捏合缩放手势
          .gesture(
            PinchGesture({ fingers: 2, distance: 1 })
              .onActionStart((event: GestureEvent) => {
                this.pinchBaseScale = this.zoomScale;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (event) {
                  const newScale: number = this.pinchBaseScale * event.scale;
                  this.zoomScale = this.clampZoom(newScale);
                }
              })
              .onActionEnd((event: GestureEvent) => {
                this.pinchBaseScale = this.zoomScale;
              })
          )
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
    }
  }

  /**
   * 单条连接线(工作流风格):
   * - 父节点底部连接点(Circle)
   * - 折线 Polyline:父底部中心 → 垂直到中间 Y → 水平到子 X → 垂直到子顶部
   * - 子节点顶部连接点(Circle)
   *
   * 所有元素绝对定位在 Stack 中,与节点同一坐标系,会随 Stack scale 缩放。
   *
   * 注意:ArkUI @Builder 不允许声明局部变量,所有坐标计算通过辅助方法获取。
   */
  @Builder
  edgeConnection(edge: BranchTreeEdge) {
    // 1. 折线(底层)
    Polyline()
      .width(this.getEdgePolyWidth(edge))
      .height(this.getEdgePolyHeight(edge))
      .position({ x: this.getEdgePolyLeft(edge), y: this.getEdgePolyTop(edge) })
      .points(this.getEdgePoints(edge))
      .fillOpacity(0)
      .stroke($r('app.color.app_text_secondary'))
      .strokeWidth(1.5)
      .strokeLineJoin(LineJoinStyle.Round)
      .strokeLineCap(LineCapStyle.Round)

    // 2. 父节点底部连接点(Circle)
    Circle({ width: 6, height: 6 })
      .position({
        x: edge.startX - 3,
        y: edge.startY - 3
      })
      .fill($r('app.color.app_text_secondary'))

    // 3. 子节点顶部连接点(Circle)
    Circle({ width: 6, height: 6 })
      .position({
        x: edge.endX - 3,
        y: edge.endY - 3
      })
      .fill($r('app.color.app_text_secondary'))
  }

  // ===== Edge 坐标计算辅助方法 =====
  // Polyline 折线坐标原点(左上角)= (min(startX, endX), min(startY, endY))

  private getEdgePolyLeft(edge: BranchTreeEdge): number {
    return Math.min(edge.startX, edge.endX);
  }

  private getEdgePolyTop(edge: BranchTreeEdge): number {
    return Math.min(edge.startY, edge.endY);
  }

  private getEdgePolyWidth(edge: BranchTreeEdge): number {
    return Math.abs(edge.endX - edge.startX);
  }

  private getEdgePolyHeight(edge: BranchTreeEdge): number {
    return Math.abs(edge.endY - edge.startY);
  }

  /**
   * 计算折线点坐标(相对于 Polyline 左上角):
   * 起点(startX, startY) → 垂直到 midY → 水平到 endX → 垂直到终点(endX, endY)
   */
  private getEdgePoints(edge: BranchTreeEdge): number[][] {
    const polyLeft: number = this.getEdgePolyLeft(edge);
    const polyTop: number = this.getEdgePolyTop(edge);
    const midY: number = (edge.startY + edge.endY) / 2;
    const startXRel: number = edge.startX - polyLeft;
    const endXRel: number = edge.endX - polyLeft;
    const startYRel: number = edge.startY - polyTop;
    const endYRel: number = edge.endY - polyTop;
    const midYRel: number = midY - polyTop;
    return [[startXRel, startYRel], [startXRel, midYRel], [endXRel, midYRel], [endXRel, endYRel]];
  }

  /** 缩放控件浮层(右上角竖排按钮) */
  @Builder
  zoomControls() {
    Column() {
      // 放大按钮
      Stack() {
        Text('+')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.canZoomIn()
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
      }
      .width(44)
      .height(44)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(22)
      .border({ width: 1, color: $r('app.color.app_divider') })
      .margin({ bottom: 8 })
      .opacity(this.canZoomIn() ? 1.0 : 0.4)
      .onClick(() => {
        this.zoomIn();
      })

      // 缩放比例(点击重置为 1.0)
      Stack() {
        Text(Math.round(this.zoomScale * 100) + '%')
          .fontSize(12)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width(44)
      .height(36)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(8)
      .border({ width: 1, color: $r('app.color.app_divider') })
      .margin({ bottom: 8 })
      .onClick(() => {
        this.resetZoom();
      })

      // 缩小按钮
      Stack() {
        Text('−')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.canZoomOut()
            ? $r('app.color.app_text_primary')
            : $r('app.color.app_text_secondary'))
      }
      .width(44)
      .height(44)
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(22)
      .border({ width: 1, color: $r('app.color.app_divider') })
      .opacity(this.canZoomOut() ? 1.0 : 0.4)
      .onClick(() => {
        this.zoomOut();
      })
    }
    // 外层 Stack alignContent=TopEnd 已对齐到右上角;
    // 这里用 padding 微调位置:top 在状态栏 + 标题栏下方 16vp,right 距屏幕右边 16vp
    .padding({
      top: this.statusBarHeight + 72,
      right: 16
    })
  }

  // ===== 缩放辅助方法 =====

  private clampZoom(scale: number): number {
    if (scale < this.MIN_ZOOM) {
      return this.MIN_ZOOM;
    }
    if (scale > this.MAX_ZOOM) {
      return this.MAX_ZOOM;
    }
    return scale;
  }

  private canZoomIn(): boolean {
    return this.zoomScale < this.MAX_ZOOM - 0.001;
  }

  private canZoomOut(): boolean {
    return this.zoomScale > this.MIN_ZOOM + 0.001;
  }

  private zoomIn(): void {
    let newScale: number = this.zoomScale + this.ZOOM_STEP;
    this.zoomScale = this.clampZoom(newScale);
  }

  private zoomOut(): void {
    let newScale: number = this.zoomScale - this.ZOOM_STEP;
    this.zoomScale = this.clampZoom(newScale);
  }

  private resetZoom(): void {
    this.zoomScale = 1.0;
  }

  @Builder
  nodeWrapper(node: BranchMapNodeLayout) {
    Column() {
      BranchMapNode({
        displayInfo: this.findDisplayInfo(node.branchId),
        isActive: this.viewModel.isActiveBranch(node.branchId),
        isSelected: this.viewModel.isSelected(node.branchId),
        onTap: (branchId: string) => {
          this.viewModel.selectBranch(branchId);
        }
      })
    }
    .width(node.width)
    .height(node.height)
    .position({ x: node.x, y: node.y })
  }

  @Builder
  bottomBar() {
    Column() {
      Divider().color($r('app.color.app_divider')).height(1).width('100%')

      Row() {
        Column() {
          Text(this.viewModel.getSelectedDisplayName())
            .fontSize(14)
            .fontColor($r('app.color.app_text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // T-6.4B-1.2: 显示 fork User 预览
          if (this.viewModel.getSelectedForkUserPreview().length > 0) {
            Text('你:' + this.viewModel.getSelectedForkUserPreview())
              .fontSize(12)
              .fontColor($r('app.color.app_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          // T-6.4B-1.2: 显示分歧 Assistant 预览
          if (this.viewModel.getSelectedAssistantPreview().length > 0) {
            Text('艾伦:' + this.viewModel.getSelectedAssistantPreview())
              .fontSize(12)
              .fontColor($r('app.color.app_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          Text(this.viewModel.getSelectedMessageCount().toString() + ' 条消息')
            .fontSize(12)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button($r('app.string.' + RES_BRANCH_SWITCH))
          .fontSize(14)
          .backgroundColor(this.canSwitch()
            ? $r('app.color.app_accent')
            : $r('app.color.app_surface_2'))
          .fontColor(Color.White)
          .borderRadius(8)
          .height(40)
          .padding({ left: 20, right: 20 })
          .enabled(this.canSwitch())
          .onClick(async () => {
            await this.handleSwitch();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.navigationBarHeight + 12 })
      .backgroundColor($r('app.color.app_surface_1'))
      .alignItems(VerticalAlign.Center)
    }
  }

  private canSwitch(): boolean {
    if (this.viewModel.isBranchOperating) {
      return false;
    }
    if (this.viewModel.selectedBranchId.length === 0) {
      return false;
    }
    // 已是当前分支时禁用切换按钮
    return this.viewModel.selectedBranchId !== this.viewModel.activeBranchId;
  }

  private async handleSwitch(): Promise<void> {
    const previousActive: string = this.viewModel.activeBranchId;
    await this.viewModel.switchToSelected();
    // T-6.4B-1.2: Active Branch 真正变化时,通过 AppStorage 通知 ChatPage reload。
    // 使用 Date.now() 保证每次切换都递增,@Watch 才能检测到变化。
    // 连接线已改为 Polyline + Circle 组件化渲染,会自动响应布局变化,无需手动重绘。
    if (this.viewModel.activeBranchId !== previousActive
      && this.viewModel.activeBranchId.length > 0) {
      AppStorage.set('branchChangeSeq', Date.now());
    }
  }

  private findDisplayInfo(branchId: string): BranchMapDisplayInfo {
    const info: BranchMapDisplayInfo | undefined =
      this.viewModel.getDisplayInfo(branchId);
    if (info !== undefined) {
      return info;
    }
    // 兜底:返回空对象(不应发生)
    return {
      summary: {
        id: '',
        parentBranchId: undefined,
        forkMessageId: undefined,
        name: '',
        isRoot: true,
        messageCount: 0,
        createdAt: 0,
        updatedAt: 0,
        lastMessageAt: 0,
        isActive: false
      },
      branchId: '',
      parentBranchId: undefined,
      forkMessageId: undefined,
      forkTurnNumber: 0,
      currentMaxTurn: 0,
      forkUserPreview: '',
      firstDivergentAssistantPreview: '',
      messageCount: 0,
      isRoot: true,
      isActive: false,
      createdAt: 0
    };
  }

  private handleReady(): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      const param = router.getParams() as Record<string, Object>;
      this.handleParam(param);
    } catch (e) {
      Logger.error(LOG_TAG, 'handleReady failed: ' + String(e));
      this.errorText = '页面参数错误';
    }
  }

  private async handleParam(param: Object | undefined): Promise<void> {
    let chatId: string = '';
    try {
      if (param !== undefined && param !== null) {
        const obj = param as Record<string, Object>;
        if (obj['chatId'] !== undefined) {
          chatId = String(obj['chatId']);
        }
      }
    } catch (_e) {
      chatId = '';
    }

    if (chatId.length === 0) {
      this.errorText = '缺少会话参数';
      Logger.error(LOG_TAG, 'missing chatId param');
      return;
    }

    await this.viewModel.initialize(chatId);

    // 初始化完成后滚动到 Active Branch
    this.scrollToActiveBranch();
  }

  private scrollToActiveBranch(): void {
    if (this.viewModel.layout === undefined) {
      return;
    }
    const activeId: string = this.viewModel.activeBranchId;
    if (activeId.length === 0) {
      return;
    }
    for (let i = 0; i < this.viewModel.layout.nodes.length; i++) {
      const node: BranchMapNodeLayout = this.viewModel.layout.nodes[i];
      if (node.branchId === activeId) {
        // 延迟滚动,确保布局已完成
        setTimeout(() => {
          this.verticalScroller.scrollTo({
            xOffset: 0,
            yOffset: Math.max(0, node.y - 100)
          });
          this.horizontalScroller.scrollTo({
            xOffset: Math.max(0, node.x - 80),
            yOffset: 0
          });
        }, 100);
        break;
      }
    }
  }

  private popBack(): void {
    router.back();
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
    Logger.info(LOG_TAG, 'aboutToDisappear');
  }
}
