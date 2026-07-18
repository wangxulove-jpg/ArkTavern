/**
 * MessageSwipeControls 消息候选切换组件
 *
 * 为 Assistant 消息气泡提供候选回复的切换控制。
 * 支持左右箭头切换、候选计数显示、重新生成/停止操作。
 *
 * T-6.4B-Closeout 显示规则:
 * - candidateCount <= 1(无旧 Swipe Group):不显示计数与箭头,
 *   仅在可操作时显示"重新生成/停止"按钮(避免无意义的 `1 / 1`)。
 * - candidateCount > 1(存在旧 Candidate Group):显示左右箭头与计数,
 *   行为与原实现一致(左右切换、上限禁用)。
 *
 * 状态处理:
 * - 不可操作(非最后一条 Assistant):
 *   * candidateCount > 1:只读显示计数
 *   * candidateCount <= 1:不渲染任何内容
 * - 生成中:箭头禁用,显示"停止"按钮
 * - 常规:箭头根据边界启用/禁用,显示"重新生成"按钮
 * - 已达最大候选数(8):"重新生成"按钮禁用
 */

const COLOR_ARROW_ACTIVE: string = '#333333';
const COLOR_ARROW_DISABLED: string = '#CCCCCC';
const COLOR_TEXT: string = '#666666';
const COLOR_TEXT_HINT: string = '#AAAAAA';
const COLOR_BUTTON_BG: string = '#F0F0F0';
const COLOR_BUTTON_TEXT: string = '#333333';
const COLOR_STOP_BG: string = '#FFE0E0';
const COLOR_STOP_TEXT: string = '#CC3333';
const COLOR_BUTTON_DISABLED_BG: string = '#F5F5F5';
const COLOR_BUTTON_DISABLED_TEXT: string = '#CCCCCC';

@Component
export struct MessageSwipeControls {
  @Prop activeCandidateIndex: number = 0;
  @Prop candidateCount: number = 1;
  @Prop isGenerating: boolean = false;
  @Prop isOperable: boolean = false;
  @Prop isMaxReached: boolean = false;
  onPrevious?: () => void;
  onNext?: () => void;
  onRegenerate?: () => void;
  onStop?: () => void;

  get isLeftDisabled(): boolean {
    if (this.isGenerating) {
      return true;
    }
    return this.activeCandidateIndex <= 0;
  }

  get isRightDisabled(): boolean {
    if (this.isGenerating) {
      return true;
    }
    return this.activeCandidateIndex >= this.candidateCount - 1;
  }

  get displayText(): string {
    const displayIndex: number = this.candidateCount > 0 ? this.activeCandidateIndex + 1 : 0;
    return `${displayIndex} / ${this.candidateCount}`;
  }

  /**
   * T-6.4B-Closeout: 是否存在真实旧 Swipe Candidate Group。
   * candidateCount <= 1 视为无 Candidate Group(新 Branch 默认值)。
   */
  get hasSwipeGroup(): boolean {
    return this.candidateCount > 1;
  }

  build() {
    Row() {
      if (this.isOperable) {
        // T-6.4B-Closeout: 仅在存在旧 Candidate Group 时显示左右切换与计数
        if (this.hasSwipeGroup) {
          this.arrowButton('‹', this.isLeftDisabled, () => {
            this.onPrevious?.();
          })

          Text(this.displayText)
            .fontSize(14)
            .fontColor(COLOR_TEXT)
            .textAlign(TextAlign.Center)
            .width(56)

          this.arrowButton('›', this.isRightDisabled, () => {
            this.onNext?.();
          })
        }

        if (this.isGenerating) {
          this.stopButton();
        } else {
          this.regenerateButton();
        }
      } else if (this.hasSwipeGroup) {
        // T-6.4B-Closeout: 历史只读且存在旧 Candidate Group 时显示计数
        // 无 Candidate Group 时不渲染任何内容(避免无意义的 `1 / 1`)
        Text(this.displayText)
          .fontSize(13)
          .fontColor(COLOR_TEXT_HINT)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height(this.shouldRenderEmpty ? 0 : 40)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Start)
  }

  /**
   * T-6.4B-Closeout: 无 Swipe Group 且不可操作时,组件高度降为 0,
   * 避免在历史 Assistant 下占用空间显示无意义的只读 `1 / 1`。
   */
  get shouldRenderEmpty(): boolean {
    return !this.hasSwipeGroup && !this.isOperable;
  }

  @Builder
  arrowButton(label: string, disabled: boolean, onClick: () => void) {
    Button(label)
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(disabled ? COLOR_ARROW_DISABLED : COLOR_ARROW_ACTIVE)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .borderRadius(18)
      .enabled(!disabled)
      .onClick(() => {
        onClick();
      })
  }

  @Builder
  stopButton() {
    Button('停止')
      .fontSize(13)
      .fontColor(COLOR_STOP_TEXT)
      .backgroundColor(COLOR_STOP_BG)
      .borderRadius(14)
      .height(28)
      .padding({ left: 12, right: 12 })
      .margin({ left: 8 })
      .onClick(() => {
        this.onStop?.();
      })
  }

  @Builder
  regenerateButton() {
    Button('重新生成')
      .fontSize(13)
      .fontColor(this.isMaxReached ? COLOR_BUTTON_DISABLED_TEXT : COLOR_BUTTON_TEXT)
      .backgroundColor(this.isMaxReached ? COLOR_BUTTON_DISABLED_BG : COLOR_BUTTON_BG)
      .borderRadius(14)
      .height(28)
      .padding({ left: 12, right: 12 })
      .margin({ left: 8 })
      .enabled(!this.isMaxReached)
      .onClick(() => {
        this.onRegenerate?.();
      })
  }
}