/**
 * BranchMapNode 分支树节点组件(T-6.4B-1.1 / T-6.4B-1.2)
 *
 * T-6.4B-1.2: 显示单个 Branch 节点的可识别信息:
 * - Branch 类型(主分支 / 第 N 轮分支)
 * - fork User Message 短预览(非 Root)
 * - 分歧 Assistant Message 短预览
 * - 消息数
 * - Active 标识(强调色边框 + 右上角圆点 + "当前"文字)
 * - 选中态(不同背景色)
 *
 * 不依赖:
 * - Repository / Service
 * - 页面实例
 *
 * 点击通过回调通知父组件,不直接处理切换逻辑。
 */

import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';

// 颜色全部使用 $r('app.color.*') 资源引用,自动适配深色模式。
// 不再使用硬编码颜色常量。

@Component
export struct BranchMapNode {
  /** T-6.4B-1.2: Branch 展示信息(含预览) */
  displayInfo: BranchMapDisplayInfo = createEmptyDisplayInfo();
  /** 是否为当前 Active Branch */
  isActive: boolean = false;
  /** 是否为用户选中 */
  isSelected: boolean = false;
  /** 点击回调 */
  onTap: (branchId: string) => void = (_: string) => {};

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 节点主体
      Column() {
        Text(this.computeBranchLabel())
          .fontSize(13)
          .fontWeight(this.isActive ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.isActive
            ? $r('app.color.app_accent')
            : $r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        // fork User 预览(非 Root 显示)
        if (!this.displayInfo.isRoot && this.displayInfo.forkUserPreview.length > 0) {
          Text('你:' + this.displayInfo.forkUserPreview)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        // 分歧 Assistant 预览
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

        // 底部:消息数 + 当前标识
        Row() {
          Text(this.displayInfo.messageCount.toString() + ' 条消息')
            .fontSize(10)
            .fontColor($r('app.color.app_text_secondary'))

          if (this.isActive) {
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

      // Active 右上角实心圆点
      if (this.isActive) {
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
   * 计算 Branch 标签文本。
   * Root: "主分支"
   * 非 Root: "第 N 轮分支" 或 "分支"
   */
  private computeBranchLabel(): string {
    if (this.displayInfo.isRoot) {
      return '主分支';
    }
    if (this.displayInfo.forkTurnNumber > 0) {
      return '第 ' + this.displayInfo.forkTurnNumber.toString() + ' 轮分支';
    }
    return '分支';
  }

  /**
   * 计算分歧 Assistant 预览文本。
   * 空内容时显示"正在生成…"占位。
   */
  private computeAssistantPreview(): string {
    const preview: string = this.displayInfo.firstDivergentAssistantPreview;
    if (preview.length === 0) {
      // 空内容:可能是新生成中,也可能是空回复
      return '艾伦:正在生成…';
    }
    return '艾伦:' + preview;
  }

  /**
   * 计算节点背景色。
   * Active:app_accent_surface(强调色背景,深浅色模式都明显)
   * Selected:app_accent_surface(浅强调色背景)
   * Normal:app_surface_1(普通表面色)
   */
  private computeBackgroundColor(): ResourceColor {
    if (this.isActive) {
      return $r('app.color.app_accent_surface');
    }
    if (this.isSelected) {
      return $r('app.color.app_accent_surface');
    }
    return $r('app.color.app_surface_1');
  }

  private computeBorderWidth(): number {
    if (this.isActive) {
      return 2.5;
    }
    if (this.isSelected) {
      return 2;
    }
    return 1;
  }

  /**
   * 计算节点边框颜色。
   * Active/Selected:app_accent(强调色边框)
   * Normal:app_divider(分割线色)
   */
  private computeBorderColor(): ResourceColor {
    if (this.isActive) {
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
    createdAt: 0
  };
}
