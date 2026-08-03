/**
 * GroupChatPage 多人聊天主页面
 *
 * G-UI-1 预览页面:多人聊天核心交互界面。
 *
 * 布局:
 * - 顶部标题栏(GroupChatHeader)
 * - 成员横向栏(GroupMemberStrip)
 * - 消息列表(GroupMessageBubble)
 * - 本轮状态栏(GroupRoundStatusBar)
 * - 底部输入区(GroupChatInputBar)
 *
 * 交互:
 * - 发送用户消息 → 模拟生成状态
 * - 开发菜单:下一位 / 完成当前 / 模拟失败 / 停止本轮 / 完成整轮
 * - 更多菜单:管理成员 / 群聊设置 / 重新命名 / 清空当前预览 / 预览状态
 * - 成员点击:查看角色 / 只让此角色回复 / 停用
 *
 * 数据来源:GroupChatPreviewStore(内存态,非数据库)。
 * 所有按钮只修改本地预览状态,不调用 Provider / Service。
 */

import { router, promptAction } from '@kit.ArkUI';
import { GroupChatHeader } from '../../components/groupchat/GroupChatHeader';
import { GroupMemberStrip } from '../../components/groupchat/GroupMemberStrip';
import { GroupMessageBubble } from '../../components/groupchat/GroupMessageBubble';
import { GroupRoundStatusBar } from '../../components/groupchat/GroupRoundStatusBar';
import { GroupChatInputBar } from '../../components/groupchat/GroupChatInputBar';
import { GroupChatPreviewStore, PENDING_GROUP_CHAT_ID_KEY } from './preview/GroupChatPreviewStore';
import {
  GroupChatPreviewSession,
  GroupChatPreviewMessage,
  GroupChatPreviewMember,
  GroupRoundPreviewStatus,
  GroupMemberPreviewStatus
} from './preview/GroupChatPreviewModels';

/**
 * 预览状态控制总开关(G-UI-2 收口)。
 *
 * - true:GroupChatPage 更多菜单中显示"预览状态"入口与"开发操作(模拟生成)"区。
 * - false:正式用户菜单不散落调试按钮,只保留管理成员 / 群聊设置 / 重命名 / 清空。
 *
 * 接入真实数据时将此常量改为 false 即可整体隐藏调试入口,便于删除,
 * 不需要在多处分散查找预览调试代码。
 */
const ENABLE_GROUP_CHAT_PREVIEW_CONTROLS: boolean = true;

@Entry
@Component
struct GroupChatPage {
  /** 当前会话 ID(由首页 / 创建页写入 AppStorage) */
  @State sessionId: string = '';
  /** 当前会话快照(null 时显示空态) */
  @State session: GroupChatPreviewSession | null = null;
  /** 输入框文本 */
  @State inputText: string = '';
  /** 更多菜单是否可见 */
  @State moreMenuVisible: boolean = false;
  /** 成员菜单目标(空时不显示) */
  @State memberMenuTarget: GroupChatPreviewMember | null = null;
  /** 预览状态菜单是否可见 */
  @State previewMenuVisible: boolean = false;
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 列表滚动控制器 */
  private scroller: ListScroller = new ListScroller();
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  aboutToAppear(): void {
    const id: string = AppStorage.get<string>(PENDING_GROUP_CHAT_ID_KEY) ?? '';
    if (id.length === 0) {
      promptAction.showToast({ message: '未找到群聊', duration: 1500 });
      router.back();
      return;
    }
    this.sessionId = id;
    // 清除 pending,避免返回后误用
    AppStorage.set<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    this.syncFromStore();
  }

  /** 从 store 同步快照 */
  private syncFromStore(): void {
    const s: GroupChatPreviewSession | null = GroupChatPreviewStore.getSession(this.sessionId);
    this.session = s;
    if (s !== null) {
      // 滚动到底部(下一帧执行,确保列表已更新)
      setTimeout((): void => {
        if (s.messages.length > 0) {
          this.scroller.scrollToIndex(s.messages.length - 1);
        }
      }, 50);
    }
  }

  /** 获取当前正在生成的成员名称 */
  private getGeneratingMemberName(): string {
    if (this.session === null) {
      return '';
    }
    const s: GroupChatPreviewSession = this.session!;
    if (s.roundStatus !== GroupRoundPreviewStatus.Generating) {
      return '';
    }
    const order: number = s.currentGeneratingOrder;
    for (let i = 0; i < s.members.length; i++) {
      if (s.members[i].order === order) {
        return s.members[i].name;
      }
    }
    return '';
  }

  /** 获取失败成员名称(失败状态时) */
  private getFailedMemberName(): string {
    if (this.session === null) {
      return '';
    }
    const s: GroupChatPreviewSession = this.session!;
    if (s.roundStatus !== GroupRoundPreviewStatus.Failed) {
      return '';
    }
    for (let i = 0; i < s.members.length; i++) {
      if (s.members[i].status === GroupMemberPreviewStatus.Failed) {
        return s.members[i].name;
      }
    }
    return '';
  }

  build(): void {
    Column() {
      if (this.session === null) {
        this.emptySessionView()
      } else {
        this.chatLayout()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 空会话视图 */
  @Builder
  emptySessionView(): void {
    Column() {
      Text('未找到群聊')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 主聊天布局 */
  @Builder
  chatLayout(): void {
    Stack() {
      Column() {
        // 顶部标题栏
        GroupChatHeader({
          title: this.session!.title,
          memberCount: this.session!.members.length,
          roundStatus: this.session!.roundStatus,
          generatingMemberName: this.getGeneratingMemberName(),
          onBack: (): void => {
            router.back();
          },
          onMore: (): void => {
            this.moreMenuVisible = true;
          }
        })

        // 成员横向栏
        GroupMemberStrip({
          members: this.session!.members,
          onMemberClick: (member: GroupChatPreviewMember): void => {
            this.memberMenuTarget = member;
          }
        })

        // 消息列表
        this.messageListArea()

        // 本轮状态栏
        GroupRoundStatusBar({
          roundStatus: this.session!.roundStatus,
          completedCount: this.session!.completedCount,
          totalCount: this.session!.totalCount,
          generatingMemberName: this.session!.roundStatus === GroupRoundPreviewStatus.Failed
            ? this.getFailedMemberName() : this.getGeneratingMemberName(),
          onStop: (): void => {
            this.handleStopRound();
          },
          onRetry: (): void => {
            this.handleRetry();
          },
          onEndRound: (): void => {
            this.handleEndRound();
          }
        })

        // 底部输入区
        GroupChatInputBar({
          inputText: this.inputText,
          isGenerating: this.session!.roundStatus === GroupRoundPreviewStatus.Generating,
          onInputChange: (text: string): void => {
            this.inputText = text;
          },
          onSend: (): void => {
            this.handleSend();
          },
          onStop: (): void => {
            this.handleStopRound();
          }
        })
      }
      .width('100%')
      .height('100%')

      // 更多菜单弹窗
      if (this.moreMenuVisible) {
        this.moreMenuDialog()
      }

      // 成员菜单弹窗
      if (this.memberMenuTarget !== null) {
        this.memberMenuDialog()
      }

      // 预览状态菜单弹窗
      if (this.previewMenuVisible) {
        this.previewMenuDialog()
      }

      // 重命名弹窗
      if (this.renameVisible) {
        this.renameDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 消息列表区 */
  @Builder
  messageListArea(): void {
    if (this.session!.messages.length === 0) {
      Column() {
        Text('还没有消息,在下方输入开始聊天')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_tertiary'))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ scroller: this.scroller }) {
        ForEach(this.session!.messages, (msg: GroupChatPreviewMessage) => {
          ListItem() {
            GroupMessageBubble({
              message: msg,
              onRetry: (): void => {
                this.handleRetry();
              },
              onEndRound: (): void => {
                this.handleEndRound();
              }
            })
          }
        }, (msg: GroupChatPreviewMessage) => msg.id + '|' + String(msg.updatedAt) + '|' + msg.status + '|' + String(msg.content.length))

        // 末尾空白
        ListItem() {
          Column().width('100%').height(16)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_8'),
        bottom: 0
      })
    }
  }

  // ===== 交互处理 =====

  /** 发送消息 */
  private handleSend(): void {
    const text: string = this.inputText.trim();
    if (text.length === 0) {
      return;
    }
    GroupChatPreviewStore.appendUserMessage(this.sessionId, text);
    this.inputText = '';
    this.syncFromStore();
  }

  /** 停止本轮 */
  private handleStopRound(): void {
    GroupChatPreviewStore.stopRound(this.sessionId);
    this.syncFromStore();
  }

  /** 重试当前失败成员 */
  private handleRetry(): void {
    GroupChatPreviewStore.retryCurrentMember(this.sessionId);
    this.syncFromStore();
  }

  /** 结束本轮 */
  private handleEndRound(): void {
    GroupChatPreviewStore.endRound(this.sessionId);
    this.syncFromStore();
  }

  /** 开发菜单:完成当前角色(推进到下一位) */
  private handleAdvanceCurrent(): void {
    GroupChatPreviewStore.advanceCurrentMember(this.sessionId);
    this.syncFromStore();
  }

  /** 开发菜单:模拟失败 */
  private handleFailCurrent(): void {
    GroupChatPreviewStore.failCurrentMember(this.sessionId);
    this.syncFromStore();
  }

  // ===== 更多菜单 =====

  @Builder
  moreMenuDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_more_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          Button($r('app.string.group_chat_menu_manage'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .onClick(() => {
              this.moreMenuVisible = false;
              AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.sessionId);
              router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
            })

          Button($r('app.string.group_chat_menu_settings'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.moreMenuVisible = false;
              AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.sessionId);
              router.pushUrl({ url: 'pages/groupchat/GroupChatSettingsPage' });
            })

          Button($r('app.string.group_chat_menu_rename'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.moreMenuVisible = false;
              this.renameInput = this.session !== null ? this.session!.title : '';
              this.renameVisible = true;
            })

          Button($r('app.string.group_chat_menu_clear'))
            .fontSize(15)
            .fontColor($r('app.color.app_danger'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.moreMenuVisible = false;
              GroupChatPreviewStore.clearMessages(this.sessionId);
              this.syncFromStore();
              promptAction.showToast({ message: '已清空当前预览消息', duration: 1500 });
            })

          // 预览状态切换(开发菜单,受总开关控制)
          if (ENABLE_GROUP_CHAT_PREVIEW_CONTROLS) {
            Button($r('app.string.group_chat_menu_preview'))
              .fontSize(15)
              .fontColor($r('app.color.app_accent'))
              .backgroundColor($r('app.color.app_accent_surface'))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%')
              .height(44)
              .margin({ top: 8 })
              .onClick(() => {
                this.moreMenuVisible = false;
                this.previewMenuVisible = true;
              })

            // 开发操作区(模拟生成流程,受总开关控制)
            Divider().color($r('app.color.app_divider')).margin({ top: 12, bottom: 8 })

            Text($r('app.string.group_chat_dev_section'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .width('100%')
              .margin({ bottom: 8 })

            Button($r('app.string.group_chat_dev_complete'))
              .fontSize(15)
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor($r('app.color.app_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%')
              .height(44)
              .enabled(this.session !== null && this.session!.roundStatus === GroupRoundPreviewStatus.Generating)
              .onClick(() => {
                this.moreMenuVisible = false;
                this.handleAdvanceCurrent();
              })

            Button($r('app.string.group_chat_dev_fail'))
              .fontSize(15)
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor($r('app.color.app_danger'))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%')
              .height(44)
              .margin({ top: 8 })
              .enabled(this.session !== null && this.session!.roundStatus === GroupRoundPreviewStatus.Generating)
              .onClick(() => {
                this.moreMenuVisible = false;
                this.handleFailCurrent();
              })

            Button($r('app.string.group_chat_dev_finish'))
              .fontSize(15)
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%')
              .height(44)
              .margin({ top: 8 })
              .enabled(this.session !== null && this.session!.roundStatus !== GroupRoundPreviewStatus.Idle)
              .onClick(() => {
                this.moreMenuVisible = false;
                GroupChatPreviewStore.resetRound(this.sessionId);
                this.syncFromStore();
              })
          }

          Button($r('app.string.group_cancel'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 12 })
            .onClick(() => {
              this.moreMenuVisible = false;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_scrim'))
    .onClick(() => {
      this.moreMenuVisible = false;
    })
  }

  // ===== 成员菜单 =====

  @Builder
  memberMenuDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text(this.memberMenuTarget !== null ? this.memberMenuTarget!.name : '')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          Button($r('app.string.group_chat_member_view'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .onClick(() => {
              const name: string = this.memberMenuTarget !== null ? this.memberMenuTarget!.name : '';
              this.memberMenuTarget = null;
              promptAction.showToast({ message: '查看角色:' + name + '(预览,暂未实现)', duration: 1500 });
            })

          Button($r('app.string.group_chat_member_only'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .enabled(this.memberMenuTarget !== null && this.memberMenuTarget!.enabled)
            .onClick(() => {
              this.handleOnlyThisMember();
            })

          Button($r('app.string.group_chat_member_disable'))
            .fontSize(15)
            .fontColor($r('app.color.app_danger'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .enabled(this.memberMenuTarget !== null && this.memberMenuTarget!.enabled)
            .onClick(() => {
              this.handleDisableMember();
            })

          Button($r('app.string.group_cancel'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 12 })
            .onClick(() => {
              this.memberMenuTarget = null;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_scrim'))
    .onClick(() => {
      this.memberMenuTarget = null;
    })
  }

  /** 只让此角色回复:停用其他成员 */
  private handleOnlyThisMember(): void {
    if (this.memberMenuTarget === null) {
      return;
    }
    const targetId: string = this.memberMenuTarget!.id;
    this.memberMenuTarget = null;
    if (this.session === null) {
      return;
    }
    const s: GroupChatPreviewSession = this.session!;
    for (let i = 0; i < s.members.length; i++) {
      const m: GroupChatPreviewMember = s.members[i];
      if (m.id !== targetId && m.enabled) {
        GroupChatPreviewStore.setMemberEnabled(this.sessionId, m.id, false);
      }
    }
    this.syncFromStore();
    promptAction.showToast({ message: '已仅保留该角色(预览)', duration: 1500 });
  }

  /** 停用成员 */
  private handleDisableMember(): void {
    if (this.memberMenuTarget === null) {
      return;
    }
    const targetId: string = this.memberMenuTarget!.id;
    this.memberMenuTarget = null;
    GroupChatPreviewStore.setMemberEnabled(this.sessionId, targetId, false);
    this.syncFromStore();
    promptAction.showToast({ message: '已停用(预览)', duration: 1500 });
  }

  // ===== 预览状态菜单 =====

  @Builder
  previewMenuDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_chat_menu_preview'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          this.previewModeButton($r('app.string.group_chat_preview_empty'), 'empty')
          this.previewModeButton($r('app.string.group_chat_preview_normal'), 'normal')
          this.previewModeButton($r('app.string.group_chat_preview_generating'), 'generating')
          this.previewModeButton($r('app.string.group_chat_preview_cancelled'), 'cancelled')
          this.previewModeButton($r('app.string.group_chat_preview_failed'), 'failed')
          this.previewModeButton($r('app.string.group_chat_preview_long'), 'long')
          this.previewModeButton($r('app.string.group_chat_preview_members8'), 'members8')

          Button($r('app.string.group_cancel'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 12 })
            .onClick(() => {
              this.previewMenuVisible = false;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_scrim'))
    .onClick(() => {
      this.previewMenuVisible = false;
    })
  }

  /** 预览模式按钮 */
  @Builder
  previewModeButton(label: ResourceStr, mode: string): void {
    Button(label)
      .fontSize(15)
      .fontColor($r('app.color.app_text_primary'))
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .width('100%')
      .height(44)
      .margin({ top: 8 })
      .onClick(() => {
        this.previewMenuVisible = false;
        GroupChatPreviewStore.setPreviewMode(this.sessionId, mode);
        this.syncFromStore();
      })
  }

  // ===== 重命名弹窗 =====

  @Builder
  renameDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_chat_menu_rename'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          TextInput({ placeholder: $r('app.string.group_rename_placeholder'), text: this.renameInput })
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.renameInput = value;
            })

          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.renameVisible = false;
                this.renameInput = '';
              })
            Button($r('app.string.group_save'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmRename();
              })
          }
          .width('100%')
          .margin({ top: 20 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_scrim'))
  }

  /** 确认重命名 */
  private confirmRename(): void {
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    GroupChatPreviewStore.renameSession(this.sessionId, trimmed);
    this.renameVisible = false;
    this.renameInput = '';
    this.syncFromStore();
  }
}
