/**
 * BranchMapNode 分支树节点组件(T-6.4B-1.1 / T-6.4B-1.2 / T-6.4B-4)
 *
 * T-6.4B-1.2: 显示单个 Branch 节点的可识别信息:
 * - Branch 类型(主分支 / 第 N 轮分支 / 第 N 轮)
 * - fork User Message 短预览(非 Root)
 * - 分歧 Assistant Message 短预览
 * - 消息数
 * - Active 标识(强调色边框 + 右上角圆点 + "当前"文字)
 * - 选中态(不同背景色)
 *
 * T-6.4B-4: 新增末端节点样式:
 * - isTerminal: 显示"第 N 轮"标签
 * - isCurrent: 显示"当前位置"标记 + 强调色边框
 *
 * 不依赖:
 * - Repository / Service
 * - 页面实例
 *
 * 点击通过回调通知父组件,不直接处理切换逻辑。
 */

import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';

@Component
export struct BranchMapNode {
  /** T-6.4B-1.2: Branch 展示信息(含预览) */
  displayInfo: BranchMapDisplayInfo = createEmptyDisplayInfo();
  /** 是否为当前 Active Branch */
  isActive: boolean = false;
  /** 是否为用户选中 */
  isSelected: boolean = false;
  /** 是否为末端显示节点(T-6.4B-4) */
  isTerminal: boolean = false;
  /** 是否为用户当前所在位置(T-6.4B-4) */
  isCurrent: boolean = false;
  /** 点击回调 */
  onTap: (branchId: string) => void = (_: string) => {};

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 节点主体
      Column() {
        // 标题行
        Text(this.computeBranchLabel())
          .fontSize(13)
          .fontWeight(this.isCurrent ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.computeTitleColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        // 当前位置标记(末端节点专属)
        if (this.isCurrent) {
          Text('当前位置')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 2 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        // fork User 预览(非 Root 显示,末端节点不重复显示)
        if (!this.isTerminal && !this.displayInfo.isRoot && this.displayInfo.forkUserPreview.length > 0) {
          Text('你:' + this.displayInfo.forkUserPreview)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        // 分歧 Assistant 预览(末端节点不重复显示)
        if (!this.isTerminal) {
          Text(this.computeAssistantPreview())
            .fontSize(11)
            .fontColor(this.displayInfo.firstDivergentAssistantPreview.length === 0
              ? $r('app.color.app_text_tertiary')
              : $r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        // 底部:消息数 + 当前标识
        Row() {
          Text(this.displayInfo.messageCount.toString() + ' 条消息')
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))

          if (this.isActive && !this.isCurrent) {
            Text('· 当前')
              .fontSize(10)
              .fontColor($r('app.color.app_accent'))
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .margin({ top: 4 })
        .justifyContent(FlexAlign.Start)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 10, right: 10, top: 10, bottom: 10 })
      .borderRadius(12)
      .backgroundColor(this.computeBackgroundColor())
      .borderWidth(this.computeBorderWidth())
      .borderColor(this.computeBorderColor())
      .borderStyle(BorderStyle.Solid)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.onTap(this.displayInfo.branchId);
      })

      // Active 右上角实心圆点(末端节点不显示,用"当前位置"文字替代)
      if (this.isActive && !this.isCurrent) {
        Circle({ width: 10, height: 10 })
          .fill($r('app.color.app_accent'))
          .markAnchor({ x: 5, y: 5 })
          .position({ x: '100%', y: 0 })
          .translate({ x: -8, y: 8 })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 计算节点标题文本:
   * - isCurrent + isTerminal: "第 N 轮"
   * - isRoot: "对话开始"
   * - 非 Root: "第 N 轮分支"
   */
  private computeBranchLabel(): string {
    if (this.isTerminal && this.displayInfo.currentMaxTurn > 0) {
      return '第 ' + this.displayInfo.currentMaxTurn.toString() + ' 轮';
    }
    if (this.displayInfo.isRoot) {
      return '对话开始';
    }
    if (this.displayInfo.forkTurnNumber > 0) {
      return '第 ' + this.displayInfo.forkTurnNumber.toString() + ' 轮分支';
    }
    return '分支';
  }

  /**
   * 计算标题颜色:
   * - isCurrent: 强调色
   * - 默认: app_text_primary
   */
  private computeTitleColor(): ResourceColor {
    if (this.isCurrent) {
      return $r('app.color.app_accent');
    }
    return $r('app.color.app_text_primary');
  }

  /**
   * 计算分歧 Assistant 预览文本。
   * 空内容时显示"正在生成…"占位。
   */
  private computeAssistantPreview(): string {
    const preview: string = this.displayInfo.firstDivergentAssistantPreview;
    if (preview.length === 0) {
      return '艾伦:正在生成…';
    }
    return '艾伦:' + preview;
  }

  /**
   * 计算节点背景色:
   * - isCurrent: 强调色背景
   * - isSelected: 浅强调色背景
   * - Normal: 普通表面色
   */
  private computeBackgroundColor(): ResourceColor {
    if (this.isCurrent) {
      return $r('app.color.app_accent_surface');
    }
    if (this.isSelected) {
      return $r('app.color.app_accent_surface');
    }
    return $r('app.color.app_surface_1');
  }

  /**
   * 计算边框宽度:
   * - isCurrent: 2.5
   * - isSelected: 2
   * - Normal: 1
   */
  private computeBorderWidth(): number {
    if (this.isCurrent) {
      return 2.5;
    }
    if (this.isSelected) {
      return 2;
    }
    return 1;
  }

  /**
   * 计算边框颜色:
   * - isCurrent: 强调色
   * - isSelected: 强调色
   * - Normal: 分割线色
   */
  private computeBorderColor(): ResourceColor {
    if (this.isCurrent) {
      return $r('app.color.app_accent');
    }
    if (this.isSelected) {
      return $r('app.color.app_accent');
    }
    return $r('app.color.app_divider');
  }
}

/**
 * 创建空 BranchMapDisplayInfo(组件 @Prop 初始值占位)。
 */
function createEmptyDisplayInfo(): BranchMapDisplayInfo {
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
    createdAt: 0,
    nodeId: '',
    isTerminal: false,
    isCurrent: false
  };
}