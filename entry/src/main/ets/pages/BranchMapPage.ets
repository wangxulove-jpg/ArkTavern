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

const LOG_TAG: string = 'BranchMapPage';

const COLOR_PAGE_BG: string = '#FAFAFA';
const COLOR_TITLE_BAR_BG: string = '#FFFFFF';
const COLOR_TEXT_PRIMARY: string = '#333333';
const COLOR_TEXT_SECONDARY: string = '#888888';
const COLOR_DIVIDER: string = '#E0E0E0';
const COLOR_BUTTON_PRIMARY: string = '#5B7CFA';
const COLOR_BUTTON_DISABLED: string = '#CCCCCC';
const COLOR_EDGE: string = '#B0B0B0';
const COLOR_ERROR: string = '#FF3B30';

const RES_BRANCH_MAP_TITLE: string = 'branch_map_title';
const RES_BRANCH_SWITCH: string = 'branch_map_switch_button';
const RES_BRANCH_BACK: string = 'branch_map_back';
const RES_BRANCH_EMPTY: string = 'branch_map_empty';

interface BranchMapRouteParam {
  chatId: string;
}

@Entry
@Component
export struct BranchMapPage {
  @State viewModel: BranchMapViewModel = new BranchMapViewModel(
    AppServices.getBranchPersistenceService()
  );
  @State readyHandled: boolean = false;
  @State errorText: string = '';

  private verticalScroller: Scroller = new Scroller();
  private horizontalScroller: Scroller = new Scroller();
  private canvasContext: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));

  build() {
    NavDestination() {
      Column() {
        this.titleBar();

        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(13)
            .fontColor(COLOR_ERROR)
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        }

        if (this.viewModel.getStatusText().length > 0) {
          Text(this.viewModel.getStatusText())
            .fontSize(12)
            .fontColor(COLOR_TEXT_SECONDARY)
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
        }

        Divider().color(COLOR_DIVIDER).height(1).width('100%')

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
      .backgroundColor(COLOR_PAGE_BG)
    }
    .title('')
    .hideTitleBar(true)
    .onReady((context: Object) => {
      this.handleReady(context);
    })
  }

  @Builder
  titleBar() {
    Row() {
      Button($r('app.string.' + RES_BRANCH_BACK))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(COLOR_BUTTON_PRIMARY)
        .onClick(() => {
          this.popBack();
        })

      Blank()

      Text($r('app.string.' + RES_BRANCH_MAP_TITLE))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TEXT_PRIMARY)

      Blank()

      // 占位保持标题居中
      Text('')
        .fontSize(14)
        .width(44)
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .backgroundColor(COLOR_TITLE_BAR_BG)
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
        .fontColor(COLOR_TEXT_SECONDARY)
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
            // 连接线 Canvas(底层)
            Canvas(this.canvasContext)
              .width(this.viewModel.layout.canvasWidth)
              .height(this.viewModel.layout.canvasHeight)
              .onReady(() => {
                this.drawConnections(this.viewModel.layout!);
              })

            // 节点(顶层,绝对定位)
            ForEach(this.viewModel.layout.nodes,
              (node: BranchMapNodeLayout) => {
                this.nodeWrapper(node)
              },
              (node: BranchMapNodeLayout) => node.branchId
            )
          }
          .width(this.viewModel.layout.canvasWidth)
          .height(this.viewModel.layout.canvasHeight)
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
      Divider().color(COLOR_DIVIDER).height(1).width('100%')

      Row() {
        Column() {
          Text(this.viewModel.getSelectedDisplayName())
            .fontSize(14)
            .fontColor(COLOR_TEXT_PRIMARY)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // T-6.4B-1.2: 显示 fork User 预览
          if (this.viewModel.getSelectedForkUserPreview().length > 0) {
            Text('你:' + this.viewModel.getSelectedForkUserPreview())
              .fontSize(12)
              .fontColor(COLOR_TEXT_SECONDARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          // T-6.4B-1.2: 显示分歧 Assistant 预览
          if (this.viewModel.getSelectedAssistantPreview().length > 0) {
            Text('艾伦:' + this.viewModel.getSelectedAssistantPreview())
              .fontSize(12)
              .fontColor(COLOR_TEXT_SECONDARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          Text(this.viewModel.getSelectedMessageCount().toString() + ' 条消息')
            .fontSize(12)
            .fontColor(COLOR_TEXT_SECONDARY)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button($r('app.string.' + RES_BRANCH_SWITCH))
          .fontSize(14)
          .backgroundColor(this.canSwitch() ? COLOR_BUTTON_PRIMARY : COLOR_BUTTON_DISABLED)
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
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(COLOR_TITLE_BAR_BG)
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
    // 切换成功后重绘连接线(Active 高亮可能变化)
    if (this.viewModel.layout !== undefined) {
      this.drawConnections(this.viewModel.layout);
    }
    // T-6.4B-1.2: Active Branch 真正变化时,通过 AppStorage 通知 ChatPage reload。
    // 使用 Date.now() 保证每次切换都递增,@Watch 才能检测到变化。
    if (this.viewModel.activeBranchId !== previousActive
      && this.viewModel.activeBranchId.length > 0) {
      AppStorage.set('branchChangeSeq', Date.now());
    }
  }

  private drawConnections(layout: BranchTreeLayoutResult): void {
    const ctx: CanvasRenderingContext2D = this.canvasContext;
    const scale: number = vp2px(1);
    ctx.scale(scale, scale);
    ctx.strokeStyle = COLOR_EDGE;
    ctx.lineWidth = 1.5;
    ctx.setLineDash([6, 4]);

    for (let i = 0; i < layout.edges.length; i++) {
      const edge: BranchTreeEdge = layout.edges[i];
      ctx.beginPath();
      ctx.moveTo(edge.startX, edge.startY);
      const midY: number = (edge.startY + edge.endY) / 2;
      ctx.bezierCurveTo(
        edge.startX, midY,
        edge.endX, midY,
        edge.endX, edge.endY
      );
      ctx.stroke();
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
      forkUserPreview: '',
      firstDivergentAssistantPreview: '',
      messageCount: 0,
      isRoot: true,
      isActive: false,
      createdAt: 0
    };
  }

  private handleReady(context: Object): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      const ctx = context as Record<string, Object>;
      const pathInfo = ctx['pathInfo'] as Record<string, Object>;
      const param = pathInfo['param'];
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
    const navInfo = this.queryNavigationInfo();
    if (navInfo !== undefined) {
      // HarmonyOS 5:pop() 必须传回返回值才会触发 pushPathByName 的 onPop 回调
      navInfo.pathStack.pop(true);
    }
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
    Logger.info(LOG_TAG, 'aboutToDisappear');
  }
}
