import { router } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';

  build() {
    RelativeContainer() {
      Text(this.message)
        .id('HelloWorld')
        .fontSize($r('app.float.page_text_font_size'))
        .fontWeight(FontWeight.Bold)
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
        .onClick(() => {
          this.message = 'Welcome';
        })

      // 开发测试入口(完成正式设置页后删除)
      Button('真实 SSE 测试 [开发测试]')
        .id('DevSseTestEntry')
        .fontSize(14)
        .fontColor('#cc6600')
        .height(48)
        .padding({ left: 16, right: 16 })
        .margin({ top: 20 })
        .alignRules({
          top: { anchor: 'HelloWorld', align: VerticalAlign.Bottom },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
        .onClick(() => {
          router.pushUrl({ url: 'pages/RealSsePocPage' });
        })
    }
    .height('100%')
    .width('100%')
  }
}