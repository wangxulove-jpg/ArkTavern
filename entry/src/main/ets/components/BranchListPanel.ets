/**
 * BranchListPanel 对话分支列表面板(T-6.4B-1)
 *
 * 以全屏覆盖层形式展示当前 Chat 的所有 Branch。
 * 用户可点击非活动 Branch 切换 Active Branch。
 *
 * 设计:
 * - 通过 @ObjectLink 引用 ChatViewModel(@Observed)
 * - 不直接访问 Repository / DbHelper / 网络
 * - 不持有选择状态(由 ViewModel 持有)
 * - 生成中或操作中禁止切换,显示提示
 *
 * 行为:
 * - 点击背景遮罩关闭面板
 * - 点击当前活动 Branch 关闭面板
 * - 点击非活动 Branch 触发 switchBranch
 * - busy 时显示 Toast 拒绝切换
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { ConversationBranchSummary } from '../models/ConversationBranch';
import { promptAction } from '@kit.ArkUI';

const COLOR_BACKDROP: string = 'rgba(0,0,0,0.5)';
const COLOR_PANEL_BG: string = '#FFFFFF';
const COLOR_ITEM_BG: string = '#F7F7F7';
const COLOR_ITEM_BG_ACTIVE: string = '#EEF2FF';
const COLOR_TEXT_PRIMARY: string = '#333333';
const COLOR_TEXT_SECONDARY: string = '#888888';
const COLOR_TEXT_DISABLED: string = '#999999';
const COLOR_CURRENT: string = '#5B7CFA';
const COLOR_DIVIDER: string = '#E0E0E0';

const RES_BRANCH_LIST_TITLE: string = 'chat_branch_list_title';
const RES_BRANCH_ROOT_NAME: string = 'chat_branch_root_name';
const RES_BRANCH_CHILD_NAME: string = 'chat_branch_child_name';
const RES_BRANCH_CURRENT_BADGE: string = 'chat_branch_current_badge';
const RES_BRANCH_SWITCH_BUSY: string = 'chat_branch_switch_busy';

@Component
export struct BranchListPanel {
  @ObjectLink viewModel: ChatViewModel;

  build() {
    Stack() {
      // 背景遮罩(点击关闭)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(COLOR_BACKDROP)
        .onClick(() => {
          this.viewModel.closeBranchList();
        })

      // 面板主体
      Column() {
        this.headerBar();
        this.summaryBar();
        Divider().color(COLOR_DIVIDER).height(1).width('100%')

        if (this.viewModel.branches.length === 0) {
          this.emptyState();
        } else {
          this.branchList();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(COLOR_PANEL_BG)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  headerBar() {
    Row() {
      Text($r('app.string.' + RES_BRANCH_LIST_TITLE))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT_PRIMARY)

      Blank()

      Button('关闭')
        .fontSize(13)
        .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
        .fontColor(COLOR_TEXT_PRIMARY)
        .borderRadius(16)
        .height(32)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.viewModel.closeBranchList();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  summaryBar() {
    if (this.viewModel.getBranchStatusText().length > 0) {
      Text(this.viewModel.getBranchStatusText())
        .fontSize(12)
        .fontColor(COLOR_TEXT_SECONDARY)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
    }
  }

  @Builder
  emptyState() {
    Column() {
      Text('暂无分支')
        .fontSize(14)
        .fontColor(COLOR_TEXT_DISABLED)
    }
    .width('100%')
    .height(200)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  branchList() {
    Scroll() {
      Column() {
        ForEach(this.viewModel.branches, (branch: ConversationBranchSummary) => {
          this.branchListItem(branch)
        }, (branch: ConversationBranchSummary) => branch.id)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  branchListItem(branch: ConversationBranchSummary) {
    Row() {
      Column() {
        Text(branch.isRoot
          ? $r('app.string.' + RES_BRANCH_ROOT_NAME)
          : $r('app.string.' + RES_BRANCH_CHILD_NAME))
          .fontSize(15)
          .fontColor(branch.isActive ? COLOR_CURRENT : COLOR_TEXT_PRIMARY)
          .fontWeight(branch.isActive ? FontWeight.Bold : FontWeight.Normal)

        Text(branch.messageCount.toString() + ' 条消息')
          .fontSize(12)
          .fontColor(COLOR_TEXT_SECONDARY)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (branch.isActive) {
        Text($r('app.string.' + RES_BRANCH_CURRENT_BADGE))
          .fontSize(12)
          .fontColor(COLOR_CURRENT)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .margin({ top: 6 })
    .borderRadius(12)
    .backgroundColor(branch.isActive ? COLOR_ITEM_BG_ACTIVE : COLOR_ITEM_BG)
    .onClick(() => {
      if (branch.isActive) {
        this.viewModel.closeBranchList();
        return;
      }
      if (this.viewModel.busy) {
        promptAction.showToast({
          message: $r('app.string.' + RES_BRANCH_SWITCH_BUSY),
          duration: 1500
        });
        return;
      }
      this.viewModel.switchBranch(branch.id);
    })
  }
}
