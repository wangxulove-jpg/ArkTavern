/**
 * MessageSwipeControls 消息候选切换组件
 *
 * 为 Assistant 消息气泡提供候选回复的切换控制。
 * 支持左右箭头切换、候选计数显示、重新生成/停止操作。
 *
 * 状态处理:
 * - 不可操作(非最后一条 Assistant):只读显示计数,无按钮
 * - 生成中:显示计数,箭头禁用,显示"停止"按钮
 * - 常规:显示计数,箭头根据边界启用/禁用,显示"重新生成"按钮
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

  build() {
    Row() {
      if (this.isOperable) {
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

        if (this.isGenerating) {
          this.stopButton();
        } else {
          this.regenerateButton();
        }
      } else {
        Text(this.displayText)
          .fontSize(13)
          .fontColor(COLOR_TEXT_HINT)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Start)
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