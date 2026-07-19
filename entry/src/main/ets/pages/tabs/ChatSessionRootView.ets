/**
 * ChatSessionRootView 对话记录 Tab 根视图
 *
 * UI-SESSIONS-01 视觉重构(设计依据:sessions_list.md / SESSIONS_LIST_005.md):
 * - 顶栏:居中标题"聊天"(H2 18fp Medium)
 * - 会话卡:[头像] [名称 时间] / [预览单行截断](两行结构)
 * - 标题显示策略:优先 chat.title → 角色名 → "新对话"
 * - 左滑显示重命名按钮
 * - 重命名:原生 TextInputDialog,空名称拒绝
 * - 角色已删除显示"未知角色",不崩溃
 *
 * 复用:
 * - ChatSessionListViewModel(本 Tab 专用,不创建 ChatService 副作用)
 * - CharacterImageView
 * - PressableCard
 * - AppStorage 跨页面刷新信号(chatListVersion)
 *
 * 不修改:
 * - 数据库 Schema / 迁移
 * - ChatService 生成 / Provider / PromptBuilder
 * - 其他 Tab
 */

import { ChatSessionListViewModel, ChatSessionListItem, formatSessionTimestamp, UNKNOWN_CHARACTER_NAME } from '../../viewmodels/ChatSessionListViewModel';
import { AppServices } from '../../services/AppServices';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';
import { CharacterImageView } from '../../components/CharacterImageView';
import { promptAction } from '@kit.ArkUI';
import { Chat } from '../../models/Chat';

/** AppStorage 中待跳转的 chatId(由本视图写入,ChatPage 读取后清除) */
export const PENDING_CHAT_ID_KEY: string = 'pendingChatId';
/** AppStorage 中待应用的 characterId(配合 pendingChatId 切换到指定角色会话) */
export const PENDING_CHARACTER_ID_KEY: string = 'pendingCharacterId';

@Component
export struct ChatSessionRootView {
  /** AppShell 传入的全局 NavPathStack,用于跳转 ChatPage */
  pathStack: NavPathStack = new NavPathStack();
  @State viewModel: ChatSessionListViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';
  /**
   * 组件本地会话列表(@State 直接装饰数组,赋值新数组即触发 ForEach 重渲染)。
   * 说明:@State 装饰 `ViewModel | null` 联合类型时,对 @Observed 实例属性的观察不可靠,
   * 因此显式维护本地 sessions 数组,在每次 reload / renameSession 后同步。
   */
  @State sessions: ChatSessionListItem[] = [];
  /** 重命名弹窗目标 chatId(空时不显示) */
  @State renameTargetId: string = '';
  /** 重命名弹窗输入值 */
  @State renameInput: string = '';
  /** 重命名进行中(防止重复点击) */
  @State isRenaming: boolean = false;
  /**
   * 跨页面列表刷新信号。
   * 由 ChatPage 在会话变化(发消息/新建会话/删除)后递增,触发本组件 reload。
   * 说明:本组件作为 HdsTabs 的 TabContent 嵌入,onPageShow 不会被调用。
   */
  @StorageProp('chatListVersion') @Watch('onListVersionChange') chatListVersion: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const vm: ChatSessionListViewModel = AppServices.createChatSessionListViewModel();
      this.viewModel = vm;
      await vm.reload();
      this.sessions = vm.sessions;
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      this.initError = (e as Error).message ?? '';
    }
  }

  /** chatListVersion 变化时刷新列表(从 ChatPage 返回后立即重新加载最新摘要/时间) */
  private onListVersionChange(): void {
    if (this.isInitializing) {
      return;
    }
    if (this.viewModel === null || !AppServices.isStarted()) {
      return;
    }
    this.viewModel!.reload()
      .then((): void => {
        this.sessions = this.viewModel!.sessions;
      })
      .catch((): void => {});
  }

  /** 同步 viewModel.sessions 到本地 @State sessions(触发 ForEach 重渲染) */
  private syncSessions(): void {
    if (this.viewModel !== null) {
      this.sessions = this.viewModel!.sessions;
    }
  }

  /** 点击会话项:写入 pendingChatId 和 pendingCharacterId(如有),push 到 ChatPage */
  private openSession(item: ChatSessionListItem): void {
    AppStorage.setOrCreate<string>(PENDING_CHAT_ID_KEY, item.chat.id);
    // 若会话有关联角色,同时写入 characterId,让 ChatPage 在 initialize 时加载正确角色上下文
    const charId: string | undefined = item.chat.characterId;
    if (charId !== undefined && charId.length > 0) {
      AppStorage.setOrCreate<string>(PENDING_CHARACTER_ID_KEY, charId);
    } else {
      AppStorage.set<string>(PENDING_CHARACTER_ID_KEY, '');
    }
    this.pathStack.pushPath({ name: 'ChatPage' });
  }

  /** 打开重命名弹窗 */
  private openRenameDialog(item: ChatSessionListItem): void {
    if (this.isRenaming) {
      return;
    }
    this.renameTargetId = item.chat.id;
    // 回填当前标题(空标题回填为"新对话"以便编辑)
    this.renameInput = item.chat.title.length > 0 ? item.chat.title : '新对话';
  }

  /** 取消重命名 */
  private cancelRename(): void {
    if (this.isRenaming) {
      return;
    }
    this.renameTargetId = '';
    this.renameInput = '';
  }

  /** 确认重命名:校验非空,调 viewModel.renameSession */
  private async confirmRename(): Promise<void> {
    if (this.isRenaming || this.renameTargetId.length === 0) {
      return;
    }
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '会话名称不能为空', duration: 2000 });
      return;
    }
    if (this.viewModel === null) {
      return;
    }
    this.isRenaming = true;
    try {
      await this.viewModel.renameSession(this.renameTargetId, trimmed);
      this.renameTargetId = '';
      this.renameInput = '';
      // 显式同步到本地 @State sessions,触发 ForEach 重渲染
      this.syncSessions();
      // 通知其他可能监听的页面(避免 ChatPage 复用旧 title)
      this.bumpListVersion();
    } catch (e) {
      promptAction.showToast({
        message: (e as Error).message ?? '重命名失败',
        duration: 2000
      });
    } finally {
      this.isRenaming = false;
    }
  }

  /** 递增 chatListVersion,通知其他页面(如已存在的 ChatPage)刷新会话列表 */
  private bumpListVersion(): void {
    const v: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', v + 1);
  }

  build() {
    Stack() {
      Column() {
        // 顶栏:居中标题"聊天"(H2 18fp Medium)
        Row() {
          Text('聊天')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          // 顶部 padding = 状态栏高度 + 间距 8(避开状态栏,与其他 Tab 统一起点)
          top: this.statusBarHeight + 8,
          bottom: $r('app.float.app_spacing_8')
        })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        // 错误提示
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        // 主内容区
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.initError.length > 0) {
          this.errorView()
        } else {
          this.sessionListArea()
        }
      }
      .width('100%')
      .height('100%')
      // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // 重命名弹窗
      if (this.renameTargetId.length > 0) {
        this.renameDialog()
      }
    }
    .width('100%')
    .height('100%')
    // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  /** 会话列表区:加载/空/列表 */
  @Builder
  sessionListArea() {
    if (this.sessions.length === 0) {
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
      List() {
        ForEach(this.sessions, (item: ChatSessionListItem) => {
          ListItem() {
            this.sessionCard(item)
          }
          .margin({ bottom: $r('app.float.app_spacing_12') })
          .swipeAction({
            end: {
              builder: (): void => {
                this.swipeActionButtons(item)
              }
            }
          })
        }, (item: ChatSessionListItem) => item.chat.id + '|' + item.chat.title)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // margin-bottom 让 List 视口在悬浮 HdsTabs 上方结束,
      // 防止顶部滚动位置时最后一项落入 TabBar 覆盖区(80vp=TabBar高度 + 20vp缓冲)
      .margin({ bottom: 100 })
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_8'),
        // 滚动到底部时,最后一项与 List 底部留出视觉间距
        bottom: 80
      })
    }
  }

  /** 左滑操作按钮(重命名) */
  @Builder
  swipeActionButtons(item: ChatSessionListItem) {
    Row() {
      Button($r('app.string.session_action_rename'))
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_accent'))
        .height('100%')
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          this.openRenameDialog(item);
        })
    }
    .height('100%')
  }

  /** 单个会话卡片 */
  @Builder
  sessionCard(item: ChatSessionListItem) {
    PressableCard({
      onPress: () => {
        this.openSession(item);
      },
      surfaceColor: $r('app.color.app_surface_1')
    }) {
      Row() {
        // 左侧角色头像(48x48 圆形缩略图)
        CharacterImageView({
          imageUri: item.character !== null ? item.character.avatarUri : '',
          fallbackName: this.getCharacterFallbackName(item),
          imgWidth: 48,
          imgHeight: 48,
          imgBorderRadius: 24,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })

        // 中间文本区(两行结构:名称+时间 / 预览)
        Column() {
          // 第一行:对话名称 + 时间
          Row() {
            Text(this.getSessionTitle(item))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            Text(formatSessionTimestamp(item.displayTimestamp))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 第二行:最后消息摘要(单行截断,空时不占高度)
          if (item.lastMessagePreview.length > 0) {
            Text(item.lastMessagePreview)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .alignItems(VerticalAlign.Center)
    }
  }

  /**
   * 获取会话标题(规范:名称=角色名;支持重命名优先)。
   * 优先级:chat.title → 角色名 → "未知角色"(已删除) → "新对话"
   */
  private getSessionTitle(item: ChatSessionListItem): string {
    if (item.chat.title.length > 0) {
      return item.chat.title;
    }
    if (item.isCharacterDeleted) {
      return UNKNOWN_CHARACTER_NAME;
    }
    if (item.character !== null && item.character.name.length > 0) {
      return item.character.name;
    }
    return '新对话';
  }

  /** 获取头像占位首字(已删除显示"?",有角色用角色名首字,无角色用"助") */
  private getCharacterFallbackName(item: ChatSessionListItem): string {
    if (item.isCharacterDeleted) {
      return '?';
    }
    if (item.character !== null && item.character.name.length > 0) {
      return item.character.name.charAt(0);
    }
    return '助';
  }

  /** 底部"开始新对话"按钮已移除(规范未要求;新建对话入口统一由角色卡 Tab 提供) */

  /** 重命名弹窗(原生 Stack 遮罩 + 输入框) */
  @Builder
  renameDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.session_rename_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          TextInput({ placeholder: $r('app.string.session_rename_placeholder'), text: this.renameInput })
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
            Button($r('app.string.session_rename_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isRenaming)
              .onClick(() => {
                this.cancelRename();
              })
            Button($r('app.string.session_rename_confirm'))
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
    .backgroundColor('rgba(0,0,0,0.5)')
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
