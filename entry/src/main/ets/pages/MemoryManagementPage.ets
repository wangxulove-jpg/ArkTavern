/**
 * MemoryManagementPage 对话记忆管理页(v8)
 *
 * 功能:
 * - 显示当前 Active Branch 的最新 Memory(摘要文本 / 范围 / 更新时间 / 字符节省估算)
 * - 启用/禁用 Memory
 * - 手动编辑摘要文本
 * - 手动触发重新生成摘要(强制,不检查阈值)
 * - 清除当前 Branch 自产记忆(继承祖先的不删)
 *
 * 路由参数:{ chatId: string }
 *
 * 数据流:
 * - MemoryManagementViewModel 通过 MemoryService + ConversationBranchPersistenceService 操作
 * - 不直接访问 Repository / Provider / 数据库
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { MemoryManagementViewModel } from '../viewmodels/MemoryManagementViewModel';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MemoryMgmtPage';

interface MemoryMgmtRouteParam {
  chatId: string;
}

@Entry
@Component
struct MemoryManagementPage {
  @State viewModel: MemoryManagementViewModel = new MemoryManagementViewModel(
    AppServices.getMemoryService(),
    AppServices.getBranchPersistenceService()
  );
  @State readyHandled: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 是否显示清除确认 */
  @State showClearConfirm: boolean = false;

  aboutToAppear(): void {
    this.handleReady();
  }

  private async handleReady(): Promise<void> {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;
    try {
      const param = router.getParams() as Record<string, Object>;
      if (param === undefined || param === null) {
        this.viewModel.errorMessage = '缺少 chatId 参数';
        return;
      }
      const chatIdVal: Object | undefined = param['chatId'];
      if (chatIdVal === undefined) {
        this.viewModel.errorMessage = '缺少 chatId 参数';
        return;
      }
      const chatId: string = String(chatIdVal);
      await this.viewModel.initialize(chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'handleReady failed: ' + String(e));
    }
  }

  build() {
    Stack() {
      Column() {
        this.titleBar();

        if (this.viewModel.errorMessage.length > 0) {
          this.errorBanner();
        }

        if (this.viewModel.statusMessage.length > 0) {
          this.statusBanner();
        }

        Scroll() {
          Column() {
            if (this.viewModel.isLoading) {
              Text('加载中...')
                .fontSize(14)
                .fontColor($r('app.color.app_text_tertiary'))
                .margin({ top: 40, bottom: 40 })
            } else if (this.viewModel.memory === null) {
              this.emptyState()
            } else {
              this.memoryContent()
            }

            Blank().height(this.navigationBarHeight + 32)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')

      if (this.showClearConfirm) {
        this.clearConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  titleBar() {
    Row() {
      Button($r('app.string.branch_map_back'))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_accent'))
        .onClick(() => {
          router.back();
        })

      Blank()

      Text('对话记忆')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))

      Blank()

      // 占位保持标题居中
      Text('')
        .fontSize(14)
        .width(56)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.statusBarHeight + 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  errorBanner() {
    Row() {
      Text(this.viewModel.errorMessage)
        .fontSize(13)
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_text_tertiary'))
        .onClick(() => {
          this.viewModel.clearErrorMessage();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.app_surface_2'))
  }

  @Builder
  statusBanner() {
    Row() {
      Text(this.viewModel.statusMessage)
        .fontSize(13)
        .fontColor($r('app.color.app_text_secondary'))
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_text_tertiary'))
        .onClick(() => {
          this.viewModel.clearStatusMessage();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.app_surface_2'))
  }

  @Builder
  emptyState() {
    Column() {
      Text('当前分支暂无记忆')
        .fontSize(16)
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 32, bottom: 8 })

      Text('未总结的消息数达到阈值时将自动生成摘要,也可手动生成。')
        .fontSize(13)
        .fontColor($r('app.color.app_text_tertiary'))
        .textAlign(TextAlign.Center)
        .margin({ left: 24, right: 24 })

      // 统计信息
      this.statsCard()

      // 手动生成按钮
      Button('生成摘要')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 24 })
        .enabled(!this.viewModel.isOperating && this.viewModel.totalMessageCount > 0)
        .onClick(() => {
          this.viewModel.regenerateSummary();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  memoryContent() {
    Column() {
      // 启用开关
      this.enableRow()

      Divider().color($r('app.color.app_divider')).margin({ top: 4, bottom: 4 })

      // 摘要展示 / 编辑
      if (this.viewModel.isEditing) {
        this.summaryEditArea()
      } else {
        this.summaryDisplayArea()
      }

      Divider().color($r('app.color.app_divider')).margin({ top: 4, bottom: 4 })

      // 统计信息
      this.statsCard()

      // 操作按钮
      this.actionButtons()
    }
    .width('100%')
  }

  @Builder
  enableRow() {
    Row() {
      Column() {
        Text('启用记忆注入')
          .fontSize(15)
          .fontColor($r('app.color.app_text_primary'))
        Text('禁用后,生成请求不会包含此摘要')
          .fontSize(12)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.viewModel.memory !== null && this.viewModel.memory.enabled })
        .enabled(!this.viewModel.isOperating)
        .onChange((isOn: boolean) => {
          void this.viewModel.toggleEnabled();
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  summaryDisplayArea() {
    Column() {
      Row() {
        Text('摘要')
          .fontSize(15)
          .fontColor($r('app.color.app_text_primary'))
        Blank()
        Text('编辑')
          .fontSize(13)
          .fontColor($r('app.color.app_accent'))
          .onClick(() => {
            this.viewModel.enterEditMode();
          })
      }
      .width('100%')

      Text(this.viewModel.memory !== null ? this.viewModel.memory.summary : '')
        .fontSize(14)
        .fontColor($r('app.color.app_text_secondary'))
        .width('100%')
        .margin({ top: 8 })
        .lineHeight(22)
      }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  summaryEditArea() {
    Column() {
      Row() {
        Text('编辑摘要')
          .fontSize(15)
          .fontColor($r('app.color.app_text_primary'))
        Blank()
        Text('取消')
          .fontSize(13)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ right: 16 })
          .onClick(() => {
            this.viewModel.cancelEdit();
          })
        Text('保存')
          .fontSize(13)
          .fontColor($r('app.color.app_accent'))
          .onClick(() => {
            void this.viewModel.saveEditedSummary();
          })
      }
      .width('100%')

      TextArea({ text: this.viewModel.editingSummary, placeholder: '编辑摘要内容' })
        .fontSize(14)
        .width('100%')
        .height(180)
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.viewModel.editingSummary = value;
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  statsCard() {
    Column() {
      Row() {
        Text('覆盖范围')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        Text(this.formatCoverage())
          .fontSize(13)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width('100%')
      .padding({ top: 8, bottom: 4 })

      Row() {
        Text('最后更新')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        Text(this.formatTime(this.viewModel.memory !== null ? this.viewModel.memory.updatedAt : 0))
          .fontSize(13)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('摘要字符数')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        Text(this.viewModel.summaryChars.toString())
          .fontSize(13)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('未总结消息数')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        Text(this.viewModel.unsummarizedMessageCount.toString()
          + ' / ' + this.viewModel.totalMessageCount.toString())
          .fontSize(13)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('未总结字符数')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
        Blank()
        Text(this.viewModel.unsummarizedChars.toString())
          .fontSize(13)
          .fontColor($r('app.color.app_text_primary'))
      }
      .width('100%')
      .padding({ top: 4, bottom: 8 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .borderRadius(8)
    .backgroundColor($r('app.color.app_surface_2'))
    .margin({ top: 8 })
  }

  @Builder
  actionButtons() {
    Column() {
      // 重新生成
      Button('重新生成摘要')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 16 })
        .backgroundColor($r('app.color.app_accent'))
        .fontColor($r('app.color.app_text_primary'))
        .enabled(!this.viewModel.isOperating && this.viewModel.totalMessageCount > 0)
        .onClick(() => {
          void this.viewModel.regenerateSummary();
        })

      // 清除当前分支记忆
      Button('清除当前分支记忆')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 12 })
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_danger'))
        .enabled(!this.viewModel.isOperating)
        .border({ width: 1, color: $r('app.color.app_danger') })
        .onClick(() => {
          this.showClearConfirm = true;
        })
    }
    .width('100%')
  }

  @Builder
  clearConfirmDialog() {
    Stack() {
      Column() {
        Text('清除当前分支记忆')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ top: 16, bottom: 8 })

        Text('此操作将删除当前分支自产的记忆摘要(继承自祖先的不删)。原始消息不会被修改。')
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 16 })

        Divider().color($r('app.color.app_divider'))

        Row() {
          Button('取消')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_text_secondary'))
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.showClearConfirm = false;
            })

          Divider().vertical(true).height(24).color($r('app.color.app_divider'))

          Button('清除')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.showClearConfirm = false;
              void this.executeClear();
            })
        }
        .width('100%')
      }
      .width('80%')
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showClearConfirm = false;
    })
  }

  private async executeClear(): Promise<void> {
    await this.viewModel.clearOwnedMemory();
    if (this.viewModel.errorMessage.length === 0) {
      promptAction.showToast({ message: '已清除当前分支记忆', duration: 1500 });
    }
  }

  private formatCoverage(): string {
    if (this.viewModel.memory === null) {
      return '0 / ' + this.viewModel.totalMessageCount.toString();
    }
    const start: number = this.viewModel.memory.startPosition;
    const end: number = this.viewModel.memory.endPosition;
    if (end < 0) {
      return '0 / ' + this.viewModel.totalMessageCount.toString();
    }
    return (start + 1).toString() + ' - ' + (end + 1).toString()
      + ' / ' + this.viewModel.totalMessageCount.toString();
  }

  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '从未';
    }
    const date: Date = new Date(ts);
    const y: number = date.getFullYear();
    const m: number = date.getMonth() + 1;
    const d: number = date.getDate();
    const h: number = date.getHours();
    const min: number = date.getMinutes();
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return y.toString() + '-' + pad(m) + '-' + pad(d)
      + ' ' + pad(h) + ':' + pad(min);
  }
}
