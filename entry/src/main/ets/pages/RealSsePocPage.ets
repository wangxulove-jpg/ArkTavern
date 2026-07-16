/**
 * RealSsePocPage 真实 SSE PoC 页面
 *
 * 临时开发测试页面,用于验证真实 OpenAI-compatible SSE 流式响应。
 * 不是正式聊天页面,不是正式设置页面。
 *
 * 安全声明:
 * - 配置仅保存在内存中,不写入持久化存储
 * - API Key 输入框使用密码模式
 * - 页面退出时主动 abort 并清空 API Key
 *
 * 完成正式设置页后删除该入口。
 *
 * 导航说明:Phase 1A 统一为 NavDestination,通过首页 NavPathStack 访问。
 * PoC 网络逻辑(ViewModel)未修改,仅页面外壳从 @Entry/router 改为 NavDestination。
 */

import { RealSsePocViewModel, PocState, PocCallbackImpl, PocStats } from '../viewmodels/RealSsePocViewModel';

@Component
export struct RealSsePocPage {
  @State baseUrl: string = '';
  @State model: string = '';
  @State apiKey: string = '';
  @State message: string = 'Hello, please reply with a short greeting.';
  @State displayState: PocState = PocState.Idle;
  @State chunkCount: number = 0;
  @State sseEventCount: number = 0;
  @State deltaCount: number = 0;
  @State replyText: string = '';
  @State errorText: string = '';
  @State doneReceived: boolean = false;

  private viewModel: RealSsePocViewModel = new RealSsePocViewModel();

  aboutToAppear(): void {
    const cb: PocCallbackImpl = new PocCallbackImpl(
      (state: PocState): void => {
        this.displayState = state;
        if (state === PocState.Completed || state === PocState.Cancelled || state === PocState.Failed) {
          const stats: PocStats = this.viewModel.getStats();
          this.doneReceived = stats.doneReceived;
        }
      },
      (count: number): void => {
        this.chunkCount = count;
      },
      (count: number): void => {
        this.sseEventCount = count;
      },
      (text: string, count: number): void => {
        this.replyText = text;
        this.deltaCount = count;
      },
      (msg: string): void => {
        this.errorText = msg;
      }
    );
    this.viewModel.setCallback(cb);
  }

  aboutToDisappear(): void {
    this.viewModel.cleanup();
    this.apiKey = '';
  }

  onStart(): void {
    this.errorText = '';
    this.replyText = '';
    this.chunkCount = 0;
    this.sseEventCount = 0;
    this.deltaCount = 0;
    this.doneReceived = false;
    this.viewModel.setApiKey(this.apiKey);
    this.viewModel.start(this.baseUrl, this.model, this.message);
  }

  onStop(): void {
    this.viewModel.stop();
  }

  onClearSensitive(): void {
    this.viewModel.clearSensitiveData();
    this.apiKey = '';
    this.replyText = '';
    this.errorText = '';
  }

  canStart(): boolean {
    return this.displayState !== PocState.Streaming && this.displayState !== PocState.Connecting;
  }

  canStop(): boolean {
    return this.displayState === PocState.Streaming || this.displayState === PocState.Connecting;
  }

  build() {
    NavDestination() {
      Column() {
        // 开发测试警告
        Text('⚠ 开发测试页面,配置仅保存在内存中')
          .fontSize(12)
          .fontColor('#cc6600')
          .width('100%')
          .padding(8)
          .backgroundColor('#fff3e0')

        Scroll() {
          Column() {
            // 输入区域
            Column() {
              Text('Base URL').fontSize(14).margin({ bottom: 4 })
              TextInput({ text: this.baseUrl, placeholder: 'https://api.example.com/v1' })
                .fontSize(14)
                .onChange((v: string) => { this.baseUrl = v })
                .width('100%')

              Text('Model').fontSize(14).margin({ top: 8, bottom: 4 })
              TextInput({ text: this.model, placeholder: 'gpt-4o / deepseek-chat' })
                .fontSize(14)
                .onChange((v: string) => { this.model = v })
                .width('100%')

              Text('API Key').fontSize(14).margin({ top: 8, bottom: 4 })
              TextInput({ text: this.apiKey, placeholder: 'sk-...' })
                .type(InputType.Password)
                .fontSize(14)
                .onChange((v: string) => { this.apiKey = v })
                .width('100%')

              Text('测试消息').fontSize(14).margin({ top: 8, bottom: 4 })
              TextInput({ text: this.message, placeholder: '输入测试消息' })
                .fontSize(14)
                .onChange((v: string) => { this.message = v })
                .width('100%')

              // 临时:一键填充 DeepSeek 示例(仅 Base URL + Model,API Key 仍需手动输入)
              // 完成正式设置页后删除
              Button('填充 DeepSeek 示例 [仅 Base URL + Model]')
                .id('FillDeepSeekExample')
                .fontSize(12)
                .fontColor('#cc6600')
                .height(40)
                .margin({ top: 8 })
                .width('100%')
                .onClick(() => {
                  this.baseUrl = 'https://api.deepseek.com';
                  this.model = 'deepseek-v4-flash';
                })
            }
            .width('100%')
            .padding(12)

            // 按钮区域
            Row() {
              Button('开始')
                .enabled(this.canStart())
                .layoutWeight(1)
                .fontSize(14)
                .onClick(() => this.onStart())

              Button('停止')
                .enabled(this.canStop())
                .layoutWeight(1)
                .fontSize(14)
                .margin({ left: 8 })
                .onClick(() => this.onStop())

              Button('清除敏感信息')
                .layoutWeight(1)
                .fontSize(14)
                .margin({ left: 8 })
                .onClick(() => this.onClearSensitive())
            }
            .width('100%')
            .padding({ left: 12, right: 12 })

            // 状态信息
            Column() {
              Row() {
                Text('状态:').fontSize(13).fontColor('#666')
                Text(this.displayState.toString())
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.stateColor(this.displayState))
              }
              .width('100%')

              Row() {
                Text('Chunk 数量:').fontSize(13).fontColor('#666')
                Text(this.chunkCount.toString()).fontSize(13)
                Blank()
                Text('SSE 事件:').fontSize(13).fontColor('#666')
                Text(this.sseEventCount.toString()).fontSize(13)
                Blank()
                Text('Delta:').fontSize(13).fontColor('#666')
                Text(this.deltaCount.toString()).fontSize(13)
              }
              .width('100%')
              .margin({ top: 4 })

              Row() {
                Text('[DONE]:').fontSize(13).fontColor('#666')
                Text(this.doneReceived ? '是' : '否')
                  .fontSize(13)
                  .fontColor(this.doneReceived ? '#4caf50' : '#999')
              }
              .width('100%')
              .margin({ top: 4 })
            }
            .width('100%')
            .padding(12)

            // 错误提示
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(13)
                .fontColor('#f44336')
                .width('100%')
                .padding(8)
                .backgroundColor('#ffebee')
                .margin({ left: 12, right: 12 })
            }

            // 回复文本
            Column() {
              Text('增量回复').fontSize(14).fontWeight(FontWeight.Bold).margin({ bottom: 4 })
              if (this.replyText.length > 0) {
                Text(this.replyText)
                  .fontSize(14)
                  .width('100%')
                  .padding(8)
                  .backgroundColor('#f5f5f5')
                  .borderRadius(4)
              } else {
                Text('(等待回复...)')
                  .fontSize(13)
                  .fontColor('#999')
                  .width('100%')
                  .padding(8)
              }
            }
            .width('100%')
            .padding(12)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('100%')
    }
    .title('真实 SSE 测试')
    .backgroundColor('#f5f5f5')
  }

  private stateColor(state: PocState): string {
    switch (state) {
      case PocState.Idle:
        return '#999999';
      case PocState.Validating:
      case PocState.Connecting:
        return '#2196f3';
      case PocState.Streaming:
        return '#4caf50';
      case PocState.Completed:
        return '#4caf50';
      case PocState.Cancelled:
        return '#ff9800';
      case PocState.Failed:
        return '#f44336';
      default:
        return '#999999';
    }
  }
}
