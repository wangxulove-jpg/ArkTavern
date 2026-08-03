/**
 * GroupChatPage 多人聊天主页面(G-DATA-1B / G-RUNTIME-1A 正式版)
 *
 * 数据来源:
 * - GroupConversationPersistenceService(真实数据库)
 * - GroupConversationMessageService(真实消息)
 *
 * 状态:
 * - Loading:加载中
 * - Ready:展示群聊标题、成员、真实消息列表、启用输入区
 * - NotFound:群聊不存在或已删除
 * - Error:加载失败
 *
 * 消息区域:
 * - 有消息:显示真实消息列表(用户右对齐,角色左对齐)
 * - 无消息:显示"还没有消息"
 * - 底部说明:"AI 角色回复将在下一阶段接入"
 *
 * 输入区:
 * - 启用真实发送
 * - 发送期间禁用按钮(isSending)
 * - 失败时保留输入内容
 *
 * 本阶段不实现:
 * - 多人 AI 生成(不显示"正在回复")
 * - 流式输出
 * - 停止 / 重试
 *
 * 不依赖:GroupChatPreviewStore / 预览种子数据。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { GroupChatViewModel } from '../../viewmodels/groupchat/GroupChatViewModel';
import {
  GroupConversationDetailUiModel,
  GroupMemberUiModel,
  GroupMessageUiModel,
  GroupChatDetailState,
  GroupMessageListState,
  PENDING_GROUP_CHAT_ID_KEY
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { CharacterImageView } from '../../components/CharacterImageView';
import { ChatRole } from '../../models/ChatRole';
import { ChatMessageStatus } from '../../models/ChatMessage';

@Entry
@Component
struct GroupChatPage {
  /** 当前群聊 ID */
  @State chatId: string = '';
  /** 群聊详情(Ready 状态下非 null) */
  @State detail: GroupConversationDetailUiModel | null = null;
  /** 页面状态 */
  @State state: GroupChatDetailState = GroupChatDetailState.Loading;
  /** 消息列表 */
  @State messages: GroupMessageUiModel[] = [];
  /** 消息列表状态 */
  @State messageState: GroupMessageListState = GroupMessageListState.Loading;
  /** 输入框文本 */
  @State inputText: string = '';
  /** 是否正在发送 */
  @State isSending: boolean = false;
  /** 错误提示 */
  @State errorMessage: string = '';
  /** 更多菜单是否可见 */
  @State moreMenuVisible: boolean = false;
  /** 重命名弹窗是否可见 */
  @State renameVisible: boolean = false;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  private viewModel: GroupChatViewModel | null = null;
  private messageScroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    const id: string = AppStorage.get<string>(PENDING_GROUP_CHAT_ID_KEY) ?? '';
    if (id.length === 0) {
      promptAction.showToast({ message: '未找到群聊', duration: 1500 });
      router.back();
      return;
    }
    this.chatId = id;
    // 清除 pending,避免返回后误用
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, '');
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupChatViewModel();
      await this.viewModel.load(id);
      this.syncFromViewModel();
    } catch (e) {
      this.state = GroupChatDetailState.Error;
    }
  }

  /** 页面重新显示时刷新(从设置/成员管理返回) */
  async onPageShow(): Promise<void> {
    if (this.viewModel !== null && this.chatId.length > 0) {
      await this.viewModel.load(this.chatId);
      this.syncFromViewModel();
    }
  }

  /** 从 ViewModel 同步状态 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.detail = this.viewModel.detail;
    this.state = this.viewModel.state;
    this.messages = this.viewModel.messages;
    this.messageState = this.viewModel.messageState;
    this.inputText = this.viewModel.inputText;
    this.isSending = this.viewModel.isSending;
    this.errorMessage = this.viewModel.errorMessage;
  }

  build(): void {
    Column() {
      if (this.state === GroupChatDetailState.Loading) {
        this.loadingView()
      } else if (this.state === GroupChatDetailState.Error) {
        this.errorView()
      } else if (this.state === GroupChatDetailState.NotFound || this.detail === null) {
        this.notFoundView()
      } else {
        this.chatLayout()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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

  /** 主聊天布局 */
  @Builder
  chatLayout(): void {
    Stack() {
      Column() {
        this.headerArea()
        this.memberStripArea()
        this.messageArea()
        this.inputBarArea()
      }
      .width('100%')
      .height('100%')

      if (this.moreMenuVisible) {
        this.moreMenuDialog()
      }
      if (this.renameVisible) {
        this.renameDialog()
      }
    }
    .width('100%')
    .height('100%')
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

      Column() {
        Text(this.detail!.title)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.composeMemberSubtitle())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4, right: 8 })

      Button() {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.app_text_primary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('更多操作')
      .onClick(() => {
        this.moreMenuVisible = true;
      })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_8'),
      right: $r('app.float.app_spacing_12'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 构建成员副标题 */
  private composeMemberSubtitle(): string {
    const members: GroupMemberUiModel[] = this.detail !== null ? this.detail.members : [];
    const enabled: number = members.filter((m: GroupMemberUiModel): boolean => m.isEnabled).length;
    return String(members.length) + ' 位成员 · ' + String(enabled) + ' 位启用';
  }

  /** 成员横向栏 */
  @Builder
  memberStripArea(): void {
    Scroll() {
      Row() {
        ForEach(this.detail!.members, (member: GroupMemberUiModel) => {
          Column() {
            Stack() {
              CharacterImageView({
                imageUri: member.avatarUri,
                fallbackName: member.name,
                imgWidth: 44,
                imgHeight: 44,
                imgBorderRadius: 22,
                displayMode: 'thumbnail',
                objectFit: ImageFit.Cover
              })
              if (!member.characterExists) {
                // 缺失角色标记
                Text('!')
                  .fontSize(12)
                  .fontColor($r('app.color.app_on_accent'))
                  .backgroundColor($r('app.color.app_danger'))
                  .borderRadius(8)
                  .width(16)
                  .height(16)
                  .textAlign(TextAlign.Center)
                  .position({ x: 30, y: -2 })
              }
            }
            .width(44)
            .height(44)

            Text(member.name)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(member.isEnabled ? $r('app.color.app_text_primary') : $r('app.color.app_text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(56)
              .textAlign(TextAlign.Center)
              .margin({ top: 4 })
              .opacity(member.isEnabled ? 1 : 0.5)
          }
          .margin({ left: 8, right: 8 })
        }, (member: GroupMemberUiModel) => member.characterId + '|' + String(member.speakerOrder) + '|' + String(member.isEnabled))
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    }
    .width('100%')
    .height(78)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 消息列表区 */
  @Builder
  messageArea(): void {
    if (this.messageState === GroupMessageListState.Loading) {
      Column() {
        Text('加载消息…')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else if (this.messages.length === 0) {
      Column() {
        Text('还没有消息')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')

        Text('AI 角色回复将在下一阶段接入。')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 6 })
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ scroller: this.messageScroller }) {
        ForEach(this.messages, (msg: GroupMessageUiModel) => {
          ListItem() {
            this.messageBubble(msg)
          }
          .margin({ left: 12, right: 12, top: 6, bottom: 6 })
        }, (msg: GroupMessageUiModel) => msg.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange(() => {
        // 消息列表变化后滚动到底部
        if (this.messages.length > 0) {
          this.messageScroller.scrollEdge(Edge.Bottom);
        }
      })
    }
  }

  /** 单条消息气泡 */
  @Builder
  messageBubble(msg: GroupMessageUiModel): void {
    if (msg.role === ChatRole.User) {
      // 用户消息:右对齐
      Row() {
        Column() {
          Text(msg.content)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.chat_user_text'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.chat_user_bubble'))
        .borderRadius($r('app.float.app_radius_md'))
        .constraintSize({ maxWidth: '75%' })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    } else {
      // AI 角色消息:左对齐
      Row() {
        Column() {
          CharacterImageView({
            imageUri: msg.senderAvatarUri ?? '',
            fallbackName: msg.senderName,
            imgWidth: 32,
            imgHeight: 32,
            imgBorderRadius: 16,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })
            .margin({ right: 8 })
        }
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text(msg.senderName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(msg.characterExists ? $r('app.color.app_text_secondary') : $r('app.color.app_danger'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(msg.content)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.chat_text_primary'))
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 2 })

          if (msg.status === ChatMessageStatus.Cancelled) {
            Text('已停止')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .margin({ top: 2 })
          } else if (msg.status === ChatMessageStatus.Failed) {
            Text('生成失败')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .margin({ top: 2 })
          }
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.chat_assistant_bubble'))
        .borderRadius($r('app.float.app_radius_md'))
        .constraintSize({ maxWidth: '75%' })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Top)
    }
  }

  /** 输入区(启用真实发送) */
  @Builder
  inputBarArea(): void {
    Column() {
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
      }

      Row() {
        TextInput({ placeholder: '发送消息', text: this.inputText })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(40)
          .padding({ left: 12, right: 12 })
          .layoutWeight(1)
          .enabled(!this.isSending)
          .onChange((value: string) => {
            this.inputText = value;
            if (this.viewModel !== null) {
              this.viewModel.inputText = value;
            }
          })
          .onSubmit(() => {
            this.handleSend();
          })

        Button() {
          SymbolGlyph($r('sys.symbol.paperplane_fill'))
            .fontSize(20)
            .fontColor([$r('app.color.app_on_accent')])
        }
        .type(ButtonType.Circle)
        .backgroundColor(this.isSending ? $r('app.color.app_text_tertiary') : $r('app.color.app_accent'))
        .width(40)
        .height(40)
        .margin({ left: 8 })
        .enabled(!this.isSending && this.inputText.trim().length > 0)
        .onClick(() => {
          this.handleSend();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('AI 角色回复将在下一阶段接入')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: this.navBarHeight + 4
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
  }

  /** 处理发送 */
  private async handleSend(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const content: string = this.inputText.trim();
    if (content.length === 0 || this.isSending) {
      return;
    }
    await this.viewModel.sendUserMessage(content);
    this.syncFromViewModel();
    if (this.viewModel.errorMessage.length === 0 && this.viewModel.inputText.length === 0) {
      // 发送成功,清空本地输入框
      this.inputText = '';
    }
  }

  /** 更多菜单弹窗 */
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
              this.goManageMembers();
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
              this.goSettings();
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
              this.renameInput = this.detail !== null ? this.detail.title : '';
              this.renameVisible = true;
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

  private goManageMembers(): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
  }

  private goSettings(): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupChatSettingsPage' });
  }

  /** 重命名弹窗 */
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
}
