/**
 * GroupChatSettingsPage 群聊设置(G-DATA-1B 正式版)
 *
 * 数据来源:GroupConversationPersistenceService(真实数据库)。
 *
 * 功能:
 * - 显示群聊名称(查看 + 重新命名)
 * - 回复方式(固定说明"按成员顺序回复",不可切换)
 * - 失败处理方式(尚无正式 Schema,显示为"尚未开放")
 * - 管理成员入口
 * - 删除群聊(二次确认 + 调用正式删除事务)
 *
 * 不依赖:GroupChatPreviewStore / GroupFailurePolicy(预览枚举)。
 * 本阶段不持久化的设置不展示为可切换状态。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { GroupChatSettingsViewModel } from '../../viewmodels/groupchat/GroupChatSettingsViewModel';
import {
  GroupChatDetailState,
  PENDING_GROUP_CHAT_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';

@Entry
@Component
struct GroupChatSettingsPage {
  /** 当前群聊 ID */
  @State chatId: string = '';
  /** 当前群聊标题 */
  @State title: string = '';
  /** 详情页状态 */
  @State state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 是否正在重命名 */
  @State isRenaming: boolean = false;
  /** 是否正在删除 */
  @State isDeleting: boolean = false;
  /** 是否正在清空消息 */
  @State isClearing: boolean = false;
  /** G-RUNTIME-1C: 是否正在生成(生成中禁止清空/删除) */
  @State isGenerating: boolean = false;
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 删除确认弹窗是否可见 */
  @State deleteConfirmVisible: boolean = false;
  /** 清空消息确认弹窗是否可见 */
  @State clearConfirmVisible: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  private viewModel: GroupChatSettingsViewModel | null = null;

  async aboutToAppear(): Promise<void> {
    const id: string = AppStorage.get<string>(PENDING_GROUP_CHAT_ID_KEY) ?? '';
    if (id.length === 0) {
      promptAction.showToast({ message: '未找到群聊', duration: 1500 });
      router.back();
      return;
    }
    this.chatId = id;
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupChatSettingsViewModel();
      await this.viewModel.load(id);
      // G-RUNTIME-1C: 刷新生成状态,生成中禁止清空/删除
      this.viewModel.refreshGeneratingState();
      this.syncFromViewModel();
    } catch (e) {
      this.state = GroupChatDetailState.Error;
    }
  }

  /** G-RUNTIME-1C: 页面重新显示时刷新生成状态(从设置返回或从其他页返回) */
  onPageShow(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.refreshGeneratingState();
    this.syncFromViewModel();
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.title = this.viewModel.title;
    this.state = this.viewModel.state;
    this.isRenaming = this.viewModel.isRenaming;
    this.isDeleting = this.viewModel.isDeleting;
    this.isClearing = this.viewModel.isClearing;
    this.isGenerating = this.viewModel.isGenerating;
  }

  build(): void {
    Stack() {
      Column() {
        if (this.state === GroupChatDetailState.Loading) {
          this.loadingView()
        } else if (this.state === GroupChatDetailState.Error) {
          this.errorView()
        } else if (this.state === GroupChatDetailState.NotFound) {
          this.notFoundView()
        } else {
          this.headerArea()
          this.settingsListArea()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.renameVisible) {
        this.renameDialog()
      }
      if (this.deleteConfirmVisible) {
        this.deleteConfirmDialog()
      }
      if (this.clearConfirmVisible) {
        this.clearConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      Text('加载失败')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
      Button('重新加载')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ top: 16 })
        .onClick(() => {
          this.reloadCurrent();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundView(): void {
    Column() {
      Text('多人聊天不存在或已被删除')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .textAlign(TextAlign.Center)
        .width('80%')
      Button('返回多人聊天首页')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ top: 16 })
        .onClick(() => {
          router.replaceUrl({ url: 'pages/groupchat/GroupChatHomePage' });
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private async reloadCurrent(): Promise<void> {
    if (this.viewModel === null || this.chatId.length === 0) {
      return;
    }
    await this.viewModel.load(this.chatId);
    this.syncFromViewModel();
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
        // 回复方式(固定说明)
        this.replyModeSection()
        // 失败处理方式(尚未开放)
        this.failurePolicySection()
        // 管理成员入口
        this.manageMembersEntry()
        // 清空聊天记录
        this.clearMessagesEntry()
        // 删除群聊
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
        Text(this.title)
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
          .enabled(!this.isRenaming)
          .onClick(() => {
            this.renameInput = this.title;
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

  /** 回复方式区(固定说明,不可切换) */
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

  /** 失败处理方式区(尚无正式 Schema,显示为尚未开放) */
  @Builder
  failurePolicySection(): void {
    Column() {
      Text($r('app.string.group_settings_failure_policy'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Text('尚未开放')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_tertiary'))
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
      AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
      router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
    })
  }

  /** 清空聊天记录入口 */
  @Builder
  clearMessagesEntry(): void {
    Row() {
      Text($r('app.string.group_settings_clear_messages'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
      // G-RUNTIME-1C: 生成中显示禁用提示
      if (this.isGenerating) {
        Text('生成中')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
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
    .enabled(!this.isClearing && !this.isDeleting && !this.isGenerating)
    .onClick(() => {
      this.clearConfirmVisible = true;
    })
  }

  /** 删除群聊入口 */
  @Builder
  deleteSessionEntry(): void {
    Row() {
      Text($r('app.string.group_settings_delete'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
      // G-RUNTIME-1C: 生成中显示禁用提示
      if (this.isGenerating) {
        Text('生成中')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
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
    .enabled(!this.isDeleting && !this.isGenerating)
    .onClick(() => {
      this.deleteConfirmVisible = true;
    })
  }

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
              .enabled(!this.isRenaming)
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
              .enabled(!this.isDeleting)
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
              .enabled(!this.isDeleting)
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

  /** 清空消息确认弹窗 */
  @Builder
  clearConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_settings_clear_messages'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_danger'))
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
              .enabled(!this.isClearing)
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
              .enabled(!this.isClearing)
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

  /** 确认重命名 */
  private async confirmRename(): Promise<void> {
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.rename(trimmed);
      this.syncFromViewModel();
      this.renameVisible = false;
      this.renameInput = '';
      promptAction.showToast({ message: '已保存', duration: 1200 });
    } catch (e) {
      promptAction.showToast({ message: '重命名失败', duration: 1500 });
    }
  }

  /** 确认删除群聊 */
  private async confirmDeleteSession(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.delete();
      this.deleteConfirmVisible = false;
      promptAction.showToast({ message: '已删除群聊', duration: 1500 });
      // 替换页面栈为多人聊天首页,避免返回到已删除群聊的设置页
      router.replaceUrl({ url: 'pages/groupchat/GroupChatHomePage' });
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法删除群聊', duration: 1500 });
      } else {
        promptAction.showToast({ message: '删除失败', duration: 1500 });
      }
    }
  }

  /** 确认清空消息 */
  private async confirmClearMessages(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.clearMessages();
      this.syncFromViewModel();
      this.clearConfirmVisible = false;
      promptAction.showToast({ message: '已清空消息', duration: 1500 });
    } catch (e) {
      const msg: string = String(e);
      if (msg.indexOf('生成中') >= 0) {
        promptAction.showToast({ message: '生成中无法清空消息', duration: 1500 });
      } else {
        promptAction.showToast({ message: '清空失败', duration: 1500 });
      }
    }
  }
}
