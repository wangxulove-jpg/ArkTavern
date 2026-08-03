/**
 * GroupChatInputBar 群聊底部输入栏
 *
 * G-UI-1 预览组件:GroupChatPage 底部固定输入区。
 * 多行输入 + 发送(空闲时)/ 停止(生成中)。
 *
 * 纯 UI,不依赖 Service / Repository / 数据库。
 * 适配底部安全区域。
 */

@Component
export struct GroupChatInputBar {
  /** 输入内容(双向同步由父组件管理) */
  @Prop inputText: string = '';
  /** 是否正在生成(生成中显示停止按钮) */
  @Prop isGenerating: boolean = false;
  /** 底部安全区域高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  /** 输入变化回调 */
  onInputChange: (text: string) => void = () => {};
  /** 发送回调 */
  onSend: () => void = () => {};
  /** 停止回调 */
  onStop: () => void = () => {};

  build(): void {
    Column() {
      Row() {
        // 多行输入框
        TextArea({ text: this.inputText, placeholder: '输入消息……' })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .constraintSize({ maxHeight: 120, minHeight: 40 })
          .layoutWeight(1)
          .enabled(!this.isGenerating)
          .onChange((value: string) => {
            this.onInputChange(value);
          })

        // 发送 / 停止按钮
        if (this.isGenerating) {
          Button($r('app.string.group_stop'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor($r('app.color.app_danger'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(40)
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .accessibilityText('停止本轮')
            .onClick(() => {
              this.onStop();
            })
        } else {
          Button($r('app.string.group_send'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(this.inputText.trim().length > 0 ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(40)
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .enabled(this.inputText.trim().length > 0)
            .accessibilityText('发送消息')
            .onClick(() => {
              this.onSend();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    }
    .width('100%')
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
    .padding({ bottom: this.navBarHeight })
  }
}
