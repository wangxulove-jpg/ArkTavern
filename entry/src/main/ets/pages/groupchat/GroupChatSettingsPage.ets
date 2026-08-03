/**
 * GroupChatSettingsPage 群聊设置
 *
 * G-UI-1 预览页面:管理指定群聊的设置项。
 *
 * 功能:
 * - 群聊名称(查看 + 重新命名)
 * - 回复方式(仅"按成员顺序回复")
 * - 失败处理方式(停止整轮 / 跳过并继续)
 * - 管理成员入口
 * - 清空预览记录
 * - 删除预览群聊
 *
 * 数据来源:GroupChatPreviewStore(内存态,非数据库)。
 * 所有操作仅修改页面内预览状态,不调用 Repository / Service。
 *
 * 本阶段不显示:自然发言 / 随机发言 / 角色抢话 / 连续自动聊天 / 私聊 / 频道
 *               / 地图 / 场景 / 记忆 / 事件 等世界模式概念。
 */

import { router, promptAction } from '@kit.ArkUI';
import { GroupChatPreviewStore, PENDING_GROUP_CHAT_ID_KEY } from './preview/GroupChatPreviewStore';
import {
  GroupChatPreviewSession,
  GroupFailurePolicy
} from './preview/GroupChatPreviewModels';

@Entry
@Component
struct GroupChatSettingsPage {
  /** 当前会话 ID */
  @State sessionId: string = '';
  /** 当前会话快照(null 时显示空态) */
  @State session: GroupChatPreviewSession | null = null;
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 清空确认弹窗是否可见 */
  @State clearConfirmVisible: boolean = false;
  /** 删除确认弹窗是否可见 */
  @State deleteConfirmVisible: boolean = false;
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
    AppStorage.set<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    this.syncFromStore();
  }

  /** 从 store 同步快照 */
  private syncFromStore(): void {
    this.session = GroupChatPreviewStore.getSession(this.sessionId);
  }

  build(): void {
    Stack() {
      Column() {
        if (this.session === null) {
          this.emptyView()
        } else {
          this.headerArea()
          this.settingsListArea()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 重命名弹窗
      if (this.renameVisible) {
        this.renameDialog()
      }

      // 清空确认弹窗
      if (this.clearConfirmVisible) {
        this.clearConfirmDialog()
      }

      // 删除确认弹窗
      if (this.deleteConfirmVisible) {
        this.deleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 空会话视图 */
  @Builder
  emptyView(): void {
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

  /** 顶部标题栏 */
  @Builder
  headerArea(): void {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('返回')
      .onClick(() => {
        router.back();
      })

      Text($r('app.string.group_settings_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_8'),
      right: $r('app.float.app_spacing_20'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 设置列表区 */
  @Builder
  settingsListArea(): void {
    Scroll() {
      Column() {
        // 群聊名称
        this.nameSection()
        // 回复方式
        this.replyModeSection()
        // 失败处理方式
        this.failurePolicySection()
        // 管理成员入口
        this.manageMembersEntry()
        // 清空预览记录
        this.clearMessagesEntry()
        // 删除预览群聊
        this.deleteSessionEntry()

        // 末尾空白
        Column().width('100%').height(40)
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 0,
      bottom: 0
    })
  }

  /** 群聊名称区 */
  @Builder
  nameSection(): void {
    Column() {
      Text($r('app.string.group_settings_name'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text(this.session!.title)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button($r('app.string.group_rename'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.renameInput = this.session !== null ? this.session!.title : '';
            this.renameVisible = true;
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_12') })
  }

  /** 回复方式区 */
  @Builder
  replyModeSection(): void {
    Column() {
      Text($r('app.string.group_settings_reply_mode'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text($r('app.string.group_settings_reply_mode_sequential'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)

        Text('●')
          .fontSize(12)
          .fontColor($r('app.color.app_accent'))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
  }

  /** 失败处理方式区 */
  @Builder
  failurePolicySection(): void {
    Column() {
      Text($r('app.string.group_settings_failure_policy'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      // 停止整轮
      Row() {
        Text($r('app.string.group_settings_failure_stop'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)

        Text(this.session !== null && this.session!.failurePolicy === GroupFailurePolicy.StopRound ? '●' : '○')
          .fontSize(14)
          .fontColor(this.session !== null && this.session!.failurePolicy === GroupFailurePolicy.StopRound
            ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.handleSetFailurePolicy(GroupFailurePolicy.StopRound);
      })

      // 跳过并继续
      Row() {
        Text($r('app.string.group_settings_failure_skip'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)

        Text(this.session !== null && this.session!.failurePolicy === GroupFailurePolicy.SkipAndContinue ? '●' : '○')
          .fontSize(14)
          .fontColor(this.session !== null && this.session!.failurePolicy === GroupFailurePolicy.SkipAndContinue
            ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })
      .onClick(() => {
        this.handleSetFailurePolicy(GroupFailurePolicy.SkipAndContinue);
      })
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
  }

  /** 管理成员入口 */
  @Builder
  manageMembersEntry(): void {
    Row() {
      Text($r('app.string.group_settings_manage_members'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.app_text_tertiary')])
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(VerticalAlign.Center)
    .margin({ top: $r('app.float.app_spacing_16') })
    .onClick(() => {
      AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.sessionId);
      router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
    })
  }

  /** 清空预览记录入口 */
  @Builder
  clearMessagesEntry(): void {
    Row() {
      Text($r('app.string.group_settings_clear_messages'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.app_text_tertiary')])
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(VerticalAlign.Center)
    .margin({ top: $r('app.float.app_spacing_16') })
    .onClick(() => {
      this.clearConfirmVisible = true;
    })
  }

  /** 删除预览群聊入口 */
  @Builder
  deleteSessionEntry(): void {
    Row() {
      Text($r('app.string.group_settings_delete'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_12'),
      right: $r('app.float.app_spacing_12'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(VerticalAlign.Center)
    .margin({ top: $r('app.float.app_spacing_16') })
    .onClick(() => {
      this.deleteConfirmVisible = true;
    })
  }

  // ===== 弹窗 =====

  /** 重命名弹窗 */
  @Builder
  renameDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_rename'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })
            .width('100%')

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

  /** 清空确认弹窗 */
  @Builder
  clearConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_settings_clear_messages'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })
            .width('100%')

          Text($r('app.string.group_settings_clear_confirm'))
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')

          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.clearConfirmVisible = false;
              })
            Button($r('app.string.group_confirm'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmClearMessages();
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

  /** 删除确认弹窗 */
  @Builder
  deleteConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_settings_delete'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_danger'))
            .margin({ bottom: 12 })
            .width('100%')

          Text($r('app.string.group_settings_delete_confirm'))
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .width('100%')

          Row() {
            Button($r('app.string.group_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.deleteConfirmVisible = false;
              })
            Button($r('app.string.group_confirm'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmDeleteSession();
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

  // ===== 操作处理 =====

  /** 设置失败处理方式 */
  private handleSetFailurePolicy(policy: GroupFailurePolicy): void {
    GroupChatPreviewStore.setFailurePolicy(this.sessionId, policy);
    this.syncFromStore();
    promptAction.showToast({
      message: policy === GroupFailurePolicy.StopRound ? '已设为停止整轮' : '已设为跳过并继续',
      duration: 1200
    });
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
    promptAction.showToast({ message: '已保存', duration: 1200 });
  }

  /** 确认清空消息 */
  private confirmClearMessages(): void {
    GroupChatPreviewStore.clearMessages(this.sessionId);
    this.clearConfirmVisible = false;
    this.syncFromStore();
    promptAction.showToast({ message: '已清空预览记录', duration: 1500 });
  }

  /** 确认删除群聊 */
  private confirmDeleteSession(): void {
    GroupChatPreviewStore.deleteSession(this.sessionId);
    this.deleteConfirmVisible = false;
    promptAction.showToast({ message: '已删除预览群聊', duration: 1500 });
    // 替换页面栈为多人聊天首页,避免返回到已删除群聊的设置页
    router.replaceUrl({ url: 'pages/groupchat/GroupChatHomePage' });
  }
}
