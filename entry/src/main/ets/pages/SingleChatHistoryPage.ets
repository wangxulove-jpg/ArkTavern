/**
 * SingleChatHistoryPage 单人聊天记录列表页(ARK-UI-LAYOUT-OPT-02)
 *
 * 由对话记录 Tab "快速开始 → 单人聊天"入口进入。
 * 展示全部单人聊天记录(不含多人聊天 / 世界),支持左滑操作与进入聊天。
 *
 * 复用:
 * - ChatSessionListViewModel(加载全部单聊会话)
 * - CharacterImageView
 * - PressableCard
 * - ThemePalette(全局主题 token)
 *
 * 不修改:
 * - ChatService / ChatPersistence / Repository / 数据库
 */

import { ChatSessionListViewModel, ChatSessionListItem, formatSessionTimestamp, UNKNOWN_CHARACTER_NAME } from '../viewmodels/ChatSessionListViewModel';
import { AppServices } from '../services/AppServices';
import { PressableCard } from '../components/PressableCard';
import { CharacterImageView } from '../components/CharacterImageView';
import { EmptyStateView } from '../components/EmptyStateView';
import { promptAction, router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'SingleChatHistoryPage';

/** AppStorage 中待跳转的 chatId(由本页写入,ChatPage 读取后清除) */
const PENDING_CHAT_ID_KEY: string = 'pendingChatId';
const PENDING_CHARACTER_ID_KEY: string = 'pendingCharacterId';

/** 左滑图标按钮参数 */
interface SwipeIconButtonParams {
  icon: Resource;
  label: string;
  bgColor: ResourceColor;
  fgColor: ResourceColor;
  action: () => void;
}

@Entry
@Component
struct SingleChatHistoryPage {
  @State viewModel: ChatSessionListViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';
  @State sessions: ChatSessionListItem[] = [];
  @State renameTargetId: string = '';
  @State renameInput: string = '';
  @State isRenaming: boolean = false;
  @State deleteTarget: ChatSessionListItem | null = null;
  @State isDeleting: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

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

  onPageShow(): void {
    if (this.viewModel !== null && AppServices.isStarted()) {
      this.viewModel!.reload()
        .then((): void => {
          this.sessions = this.viewModel!.sessions;
        })
        .catch((): void => {});
    }
  }

  private syncSessions(): void {
    if (this.viewModel !== null) {
      this.sessions = this.viewModel!.sessions;
    }
  }

  private openSession(item: ChatSessionListItem): void {
    AppStorage.setOrCreate<string>(PENDING_CHAT_ID_KEY, item.chat.id);
    const charId: string | undefined = item.chat.characterId;
    if (charId !== undefined && charId.length > 0) {
      AppStorage.setOrCreate<string>(PENDING_CHARACTER_ID_KEY, charId);
    } else {
      AppStorage.set<string>(PENDING_CHARACTER_ID_KEY, '');
    }
    router.pushUrl({ url: 'pages/ChatPage' });
  }

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

  private getCharacterFallbackName(item: ChatSessionListItem): string {
    if (item.isCharacterDeleted) {
      return '?';
    }
    if (item.character !== null && item.character.name.length > 0) {
      return item.character.name.charAt(0);
    }
    return '助';
  }

  private openRenameDialog(item: ChatSessionListItem): void {
    if (this.isRenaming) {
      return;
    }
    this.renameTargetId = item.chat.id;
    this.renameInput = item.chat.title.length > 0 ? item.chat.title : '新对话';
  }

  private cancelRename(): void {
    if (this.isRenaming) {
      return;
    }
    this.renameTargetId = '';
    this.renameInput = '';
  }

  private async confirmRename(): Promise<void> {
    if (this.isRenaming || this.renameTargetId.length === 0 || this.viewModel === null) {
      return;
    }
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '会话名称不能为空', duration: 2000 });
      return;
    }
    this.isRenaming = true;
    try {
      await this.viewModel!.renameSession(this.renameTargetId, trimmed);
      this.renameTargetId = '';
      this.renameInput = '';
      this.syncSessions();
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message ?? '重命名失败', duration: 2000 });
    } finally {
      this.isRenaming = false;
    }
  }

  private promptDelete(item: ChatSessionListItem): void {
    if (this.isDeleting) {
      return;
    }
    this.deleteTarget = item;
  }

  private cancelDelete(): void {
    if (this.isDeleting) {
      return;
    }
    this.deleteTarget = null;
  }

  private async confirmDelete(): Promise<void> {
    if (this.isDeleting || this.deleteTarget === null || this.viewModel === null) {
      this.deleteTarget = null;
      return;
    }
    const chatId: string = this.deleteTarget.chat.id;
    this.isDeleting = true;
    try {
      await this.viewModel!.deleteSession(chatId);
      this.syncSessions();
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message ?? '删除失败', duration: 2000 });
    } finally {
      this.deleteTarget = null;
      this.isDeleting = false;
    }
  }

  private async handleMoveUp(chatId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.moveUp(chatId);
    this.syncSessions();
  }

  private async handleMoveDown(chatId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.moveDown(chatId);
    this.syncSessions();
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text($r('app.string.single_chat_history_title'))
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ right: 40 })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        // 错误提示
        if (this.initError.length > 0) {
          Text(this.initError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_16'),
              right: $r('app.float.app_spacing_16'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        // 主内容区
        if (this.isInitializing) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(ThemePalette.accentColor(this.effectiveTheme))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (this.sessions.length === 0) {
          Column() {
            EmptyStateView({
              title: $r('app.string.tab_sessions_empty'),
              description: $r('app.string.tab_sessions_empty_desc')
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          List() {
            ForEach(this.sessions, (item: ChatSessionListItem) => {
              ListItem() {
                this.sessionCard(item)
              }
              .width('100%')
              .margin({ bottom: 2 })
              .swipeAction({
                end: {
                  builder: (): void => {
                    this.swipeActionButtons(item)
                  }
                }
              })
            }, (item: ChatSessionListItem) => item.chat.id + '|' + item.chat.title)

            // 末尾空白
            ListItem() {
              Column().width('100%').height(160)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({
            left: $r('app.float.app_spacing_8'),
            right: $r('app.float.app_spacing_8'),
            top: 4,
            bottom: 0
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 重命名弹窗
      if (this.renameTargetId.length > 0) {
        this.renameDialog()
      }

      // 删除确认弹窗
      if (this.deleteTarget !== null) {
        this.deleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 单个会话卡片(紧凑布局,复用对话记录页风格) */
  @Builder
  sessionCard(item: ChatSessionListItem) {
    PressableCard({
      onPress: () => {
        this.openSession(item);
      },
      surfaceColor: ThemePalette.surface1Color(this.effectiveTheme)
    }) {
      Row() {
        CharacterImageView({
          imageUri: item.character !== null ? item.character.avatarUri : '',
          fallbackName: this.getCharacterFallbackName(item),
          imgWidth: 52,
          imgHeight: 52,
          imgBorderRadius: 26,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })

        Column() {
          Text(this.getSessionTitle(item))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          if (item.lastMessagePreview.length > 0) {
            Text(item.lastMessagePreview)
              .fontSize(13)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 3 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        Column() {
          Text(formatSessionTimestamp(item.displayTimestamp))
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(14)
            .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.End)
        .margin({ left: 8 })
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: 10,
        bottom: 10
      })
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 左滑操作按钮 */
  @Builder
  swipeActionButtons(item: ChatSessionListItem) {
    Row() {
      this.swipeIconButton({
        icon: $r('sys.symbol.arrow_up'),
        label: '上移',
        bgColor: ThemePalette.surface2Color(this.effectiveTheme),
        fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
        action: (): void => { this.handleMoveUp(item.chat.id); }
      })

      this.swipeIconButton({
        icon: $r('sys.symbol.arrow_down'),
        label: '下移',
        bgColor: ThemePalette.surface2Color(this.effectiveTheme),
        fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
        action: (): void => { this.handleMoveDown(item.chat.id); }
      })

      this.swipeIconButton({
        icon: $r('sys.symbol.square_and_pencil'),
        label: '重命名',
        bgColor: ThemePalette.accentColor(this.effectiveTheme),
        fgColor: $r('app.color.app_on_accent'),
        action: (): void => { this.openRenameDialog(item); }
      })

      this.swipeIconButton({
        icon: $r('sys.symbol.trash'),
        label: '删除',
        bgColor: $r('app.color.app_danger'),
        fgColor: $r('app.color.app_on_accent'),
        action: (): void => { this.promptDelete(item); }
      })
    }
    .height('100%')
  }

  @Builder
  swipeIconButton(params: SwipeIconButtonParams) {
    Button() {
      Column() {
        SymbolGlyph(params.icon)
          .fontSize(20)
          .fontColor([params.fgColor])
        Text(params.label)
          .fontSize(10)
          .fontColor(params.fgColor)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .type(ButtonType.Capsule)
    .backgroundColor(params.bgColor)
    .height('100%')
    .layoutWeight(1)
    .padding({ top: 6, bottom: 6, left: 4, right: 4 })
    .margin({ left: 2, right: 2 })
    .onClick(() => {
      params.action();
    })
  }

  /** 重命名弹窗 */
  @Builder
  renameDialog() {
    Stack() {
      Column() {
        Column() {
          Text('重命名会话')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          TextInput({ placeholder: '输入新名称', text: this.renameInput })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.renameInput = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isRenaming)
              .onClick(() => {
                this.cancelRename();
              })
            Button('确定')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
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
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
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

  /** 删除确认弹窗 */
  @Builder
  deleteConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          Text('删除会话')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text('确定删除该会话吗?此操作不可撤销。')
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })

          Row() {
            Button('取消')
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.cancelDelete();
              })

            Button('删除')
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.confirmDelete();
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
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
}
