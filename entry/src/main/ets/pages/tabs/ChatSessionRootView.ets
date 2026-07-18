/**
 * ChatSessionRootView 对话记录 Tab 根视图(UI-1)
 *
 * 作为 HdsTabs 的第二个 Tab 内容,展示会话列表入口。
 *
 * 设计:
 * - 标题区:应用名 + 简短描述
 * - 会话列表(点击会话进入 ChatPage 二级页面,通过 AppStorage 传递 chatId)
 * - 空状态:无会话时引导用户开始聊天
 * - 加载 / 错误状态
 * - 底部"开始新对话"按钮
 *
 * 复用:
 * - ChatViewModel(只读接线,会话列表加载)
 * - AppServices.createChatService() 创建 ChatService 实例
 *
 * 不修改:
 * - ChatService 业务逻辑
 * - 会话持久化 / Swipe / Branch 逻辑
 *
 * 限制:
 * - 当前实现显示 character_id IS NULL 的会话(普通助手上下文)
 *   原因:ChatService.listSessions() 依赖 character 上下文,
 *   而 ChatSessionRootView 不调用 vm.initialize()(避免修改数据库)。
 *   后续 Phase 可在 AppServices 中添加 listAllSessionsForUi() 改进。
 */

import { ChatViewModel } from '../../viewmodels/ChatViewModel';
import { Chat } from '../../models/Chat';
import { AppServices } from '../../services/AppServices';
import { AppPageHeader } from '../../components/AppPageHeader';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';

/** AppStorage 中待跳转的 chatId(由 ChatSessionRootView 写入,ChatPage 读取后清除) */
export const PENDING_CHAT_ID_KEY: string = 'pendingChatId';

@Component
export struct ChatSessionRootView {
  /** AppShell 传入的全局 NavPathStack,用于跳转 ChatPage */
  pathStack: NavPathStack = new NavPathStack();
  @State viewModel: ChatViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const modelService = AppServices.getModelService();
      const characterService = AppServices.getCharacterService();
      const promptPresetService = AppServices.getPromptPresetService();
      const chatService = AppServices.createChatService();
      const vm: ChatViewModel =
        new ChatViewModel(chatService, modelService, characterService, promptPresetService);
      this.viewModel = vm;
      // 只加载会话列表,不调用 initialize(避免创建新会话副作用)
      await vm.refreshSessions();
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      this.initError = (e as Error).message ?? '';
    }
  }

  /** 页面恢复时刷新会话列表(从 ChatPage 返回时) */
  onPageShow(): void {
    if (this.viewModel !== null && AppServices.isStarted()) {
      this.viewModel!.refreshSessions().catch((): void => {});
    }
  }

  /** 点击会话项:写入 pendingChatId,push 到 ChatPage */
  private openSession(chatId: string): void {
    AppStorage.setOrCreate<string>(PENDING_CHAT_ID_KEY, chatId);
    this.pathStack.pushPath({ name: 'ChatPage' });
  }

  /** 开始新对话:清除 pendingChatId,push 到 ChatPage(让 ChatPage 创建新会话) */
  private startNewChat(): void {
    AppStorage.setOrCreate<string>(PENDING_CHAT_ID_KEY, '');
    this.pathStack.pushPath({ name: 'ChatPage' });
  }

  build() {
    Stack() {
      Column() {
        AppPageHeader({
          title: $r('app.string.tab_sessions'),
          subtitle: $r('app.string.tab_sessions_subtitle')
        })

        Text($r('app.string.tab_sessions_desc'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({
            left: $r('app.float.app_spacing_20'),
            right: $r('app.float.app_spacing_20'),
            bottom: $r('app.float.app_spacing_12')
          })

        // ===== 错误提示 =====
        if (this.viewModel !== null && this.viewModel!.sessionError.length > 0) {
          Text(this.viewModel!.sessionError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              top: $r('app.float.app_spacing_4'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        // ===== 主内容区 =====
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.initError.length > 0) {
          this.errorView()
        } else {
          this.sessionListArea()
        }

        // ===== 底部"开始新对话"按钮 =====
        this.bottomNewChatButton()
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
  }

  /** 会话列表区:加载/空/列表 */
  @Builder
  sessionListArea() {
    if (this.viewModel === null || this.viewModel!.sessions.length === 0) {
      Column() {
        EmptyStateView({
          title: $r('app.string.tab_sessions_empty'),
          description: $r('app.string.tab_sessions_empty_desc')
        })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column() {
          ForEach(this.viewModel!.sessions, (chat: Chat) => {
            this.sessionCard(chat)
          }, (chat: Chat) => chat.id)
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_16'),
          right: $r('app.float.app_spacing_16'),
          top: $r('app.float.app_spacing_8'),
          bottom: $r('app.float.app_spacing_24')
        })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .width('100%')
    }
  }

  /** 单个会话卡片 */
  @Builder
  sessionCard(chat: Chat) {
    PressableCard({
      onPress: () => {
        this.openSession(chat.id);
      }
    }) {
      Row() {
        Column() {
          Text(this.getSessionTitle(chat))
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          Text(this.getSessionSubtitle(chat))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.viewModel !== null && this.viewModel!.isCurrentSession(chat.id)) {
          Text($r('app.string.tab_sessions_current_badge'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_accent'))
            .border({ width: 1, color: $r('app.color.app_accent') })
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }

        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 底部"开始新对话"按钮 */
  @Builder
  bottomNewChatButton() {
    Row() {
      Button($r('app.string.tab_sessions_new_chat'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor($r('app.color.app_accent'))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('100%')
        .onClick(() => {
          this.startNewChat();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_24')
    })
  }

  private getSessionTitle(chat: Chat): string {
    if (this.viewModel === null) {
      return chat.title;
    }
    return this.viewModel!.getSessionTitle(chat);
  }

  private getSessionSubtitle(chat: Chat): string {
    if (this.viewModel === null) {
      return '';
    }
    return this.viewModel!.getSessionSubtitle(chat);
  }

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.app_accent'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView() {
    Column() {
      EmptyStateView({
        title: $r('app.string.tab_sessions_load_failed'),
        description: this.initError
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}
