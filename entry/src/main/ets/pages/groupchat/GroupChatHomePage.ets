/**
 * GroupChatHomePage 多人聊天首页(G-DATA-1B 正式版)
 *
 * 数据来源:GroupConversationPersistenceService(正式数据库)。
 *
 * 状态:
 * - Loading:轻量加载
 * - Empty:无群聊,显示创建 CTA
 * - Ready:群聊卡片列表
 * - Error:加载失败,提供重新加载
 *
 * 不依赖:GroupChatPreviewStore / 预览种子数据。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../../services/AppServices';
import { GroupChatHomeViewModel } from '../../viewmodels/groupchat/GroupChatHomeViewModel';
import {
  GroupConversationListItemUiModel,
  GroupMemberUiModel,
  GroupChatListState,
  PENDING_GROUP_CHAT_ID_KEY,
  formatGroupTimestamp
} from '../../viewmodels/groupchat/GroupChatUiModels';
import { CharacterImageView } from '../../components/CharacterImageView';
import { GroupEmptyState } from '../../components/groupchat/GroupEmptyState';

@Entry
@Component
struct GroupChatHomePage {
  @State items: GroupConversationListItemUiModel[] = [];
  @State state: GroupChatListState = GroupChatListState.Loading;
  /** 更多菜单目标 chatId */
  @State moreTargetId: string = '';
  @State moreTargetTitle: string = '';
  /** 重命名弹窗 */
  @State renameTargetId: string = '';
  @State renameInput: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  private viewModel: GroupChatHomeViewModel | null = null;

  async aboutToAppear(): Promise<void> {
    await this.ensureAndLoad();
  }

  /** 页面重新显示时刷新(从创建/设置/成员管理返回) */
  async onPageShow(): Promise<void> {
    if (this.viewModel !== null) {
      await this.reload();
    }
  }

  private async ensureAndLoad(): Promise<void> {
    try {
      await AppServices.whenReady();
      this.viewModel = new GroupChatHomeViewModel();
      await this.reload();
    } catch (e) {
      this.state = GroupChatListState.Error;
    }
  }

  private async reload(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel.load();
    this.items = this.viewModel.items;
    this.state = this.viewModel.state;
  }

  build(): void {
    Stack() {
      Column() {
        this.headerArea()
        this.contentArea()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.moreTargetId.length > 0) {
        this.moreMenuDialog()
      }
      if (this.renameTargetId.length > 0) {
        this.renameDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 顶部标题区 */
  @Builder
  headerArea(): void {
    Row() {
      Column() {
        Text($r('app.string.group_home_title'))
          .fontSize($r('app.float.app_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text($r('app.string.group_home_subtitle'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button($r('app.string.group_create'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 16, right: 16 })
        .accessibilityText('创建多人聊天')
        .onClick(() => {
          router.pushUrl({ url: 'pages/groupchat/GroupChatCreatePage' });
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_12')
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 内容区:根据状态切换 */
  @Builder
  contentArea(): void {
    if (this.state === GroupChatListState.Loading) {
      this.loadingView()
    } else if (this.state === GroupChatListState.Error) {
      this.errorView()
    } else if (this.state === GroupChatListState.Empty || this.items.length === 0) {
      this.emptyView()
    } else {
      this.listView()
    }
  }

  @Builder
  loadingView(): void {
    Column() {
      Text('加载中…')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_tertiary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(): void {
    Column() {
      Text('多人聊天加载失败')
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
          this.reload();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyView(): void {
    Column() {
      GroupEmptyState({
        title: $r('app.string.group_home_empty_title'),
        description: $r('app.string.group_home_empty_desc'),
        actionText: $r('app.string.group_create'),
        onAction: (): void => {
          router.pushUrl({ url: 'pages/groupchat/GroupChatCreatePage' });
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  listView(): void {
    List() {
      ForEach(this.items, (item: GroupConversationListItemUiModel) => {
        ListItem() {
          this.groupCard(item)
        }
        .margin({ bottom: $r('app.float.app_spacing_12') })
      }, (item: GroupConversationListItemUiModel) => item.chatId + '|' + String(item.updatedAt))

      ListItem() {
        Column().width('100%').height(40)
      }
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

  /** 群聊卡片 */
  @Builder
  groupCard(item: GroupConversationListItemUiModel): void {
    Column() {
      Row() {
        // 头像堆叠(最多显示前 3 个)
        this.avatarStack(item.members)

        Column() {
          Text(item.title)
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.composeMemberSummary(item.members))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        // 更多按钮
        Button() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(18)
            .fontColor([$r('app.color.app_text_tertiary')])
        }
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .width(36)
        .height(36)
        .accessibilityText('更多操作')
        .onClick(() => {
          this.moreTargetId = item.chatId;
          this.moreTargetTitle = item.title;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 最后消息 + 时间
      Row() {
        Text(item.lastMessagePreview)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(formatGroupTimestamp(item.updatedAt))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
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
    .onClick(() => {
      this.openGroupChat(item.chatId);
    })
  }

  /** 头像堆叠(最多 3 个) */
  @Builder
  avatarStack(members: GroupMemberUiModel[]): void {
    Stack() {
      ForEach(this.sliceMembers(members, 3), (m: GroupMemberUiModel, index: number) => {
        CharacterImageView({
          imageUri: m.avatarUri,
          fallbackName: m.name,
          imgWidth: 36,
          imgHeight: 36,
          imgBorderRadius: 18,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
          .offset({ x: (this.computeStackOffset(members.length, index)) })
          .zIndex(10 - index)
      }, (m: GroupMemberUiModel, index: number) => m.characterId + '_' + String(index))
    }
    .width(this.computeStackWidth(members.length))
    .height(36)
    .alignContent(Alignment.Start)
  }

  /** 截取前 N 个成员(用于头像堆叠) */
  private sliceMembers(members: GroupMemberUiModel[], maxCount: number): GroupMemberUiModel[] {
    const maxShow: number = members.length > maxCount ? maxCount : members.length;
    return members.slice(0, maxShow);
  }

  /** 计算头像堆叠中单个头像的 X 偏移(从右往左堆叠) */
  private computeStackOffset(totalCount: number, index: number): number {
    const maxShow: number = totalCount > 3 ? 3 : totalCount;
    return (maxShow - 1 - index) * 12;
  }

  /** 计算头像堆叠区域总宽度 */
  private computeStackWidth(totalCount: number): number {
    if (totalCount === 0) {
      return 36;
    }
    const maxShow: number = totalCount > 3 ? 3 : totalCount;
    return 36 + (maxShow - 1) * 12;
  }

  /** 组合成员名称摘要 */
  private composeMemberSummary(members: GroupMemberUiModel[]): string {
    if (members.length === 0) {
      return '';
    }
    const names: string[] = [];
    const max: number = members.length > 3 ? 3 : members.length;
    for (let i = 0; i < max; i++) {
      names.push(members[i].name);
    }
    let summary: string = names.join('、');
    if (members.length > 3) {
      summary = summary + ' 等 ' + String(members.length) + ' 人';
    }
    return summary;
  }

  /** 打开群聊 */
  private openGroupChat(chatId: string): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, chatId);
    router.pushUrl({ url: 'pages/groupchat/GroupChatPage' });
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

          Text(this.moreTargetTitle)
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 12 })

          Button($r('app.string.group_rename'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .onClick(() => {
              this.openRenameDialog();
            })

          Button($r('app.string.group_manage_members'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_primary'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.goManageMembers();
            })

          Button($r('app.string.group_delete_preview'))
            .fontSize(15)
            .fontColor($r('app.color.app_danger'))
            .backgroundColor($r('app.color.app_surface_2'))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.deleteGroupChat();
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
              this.moreTargetId = '';
              this.moreTargetTitle = '';
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
      this.moreTargetId = '';
      this.moreTargetTitle = '';
    })
  }

  private openRenameDialog(): void {
    if (this.moreTargetId.length === 0) {
      return;
    }
    this.renameTargetId = this.moreTargetId;
    this.renameInput = this.moreTargetTitle;
    this.moreTargetId = '';
    this.moreTargetTitle = '';
  }

  private goManageMembers(): void {
    if (this.moreTargetId.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.moreTargetId);
    const targetId: string = this.moreTargetId;
    this.moreTargetId = '';
    this.moreTargetTitle = '';
    router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
  }

  private deleteGroupChat(): void {
    if (this.moreTargetId.length === 0) {
      return;
    }
    const targetId: string = this.moreTargetId;
    this.moreTargetId = '';
    this.moreTargetTitle = '';
    this.deleteGroupChatAsync(targetId);
  }

  private async deleteGroupChatAsync(chatId: string): Promise<void> {
    try {
      const service = AppServices.getGroupConversationPersistenceService();
      await service.deleteGroupConversation(chatId);
      promptAction.showToast({ message: '已删除群聊', duration: 1500 });
      await this.reload();
    } catch (e) {
      promptAction.showToast({ message: '删除失败', duration: 1500 });
    }
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
                this.renameTargetId = '';
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
    const targetId: string = this.renameTargetId;
    try {
      const service = AppServices.getGroupConversationPersistenceService();
      await service.renameGroupConversation(targetId, trimmed);
      this.renameTargetId = '';
      this.renameInput = '';
      await this.reload();
      promptAction.showToast({ message: '已保存', duration: 1200 });
    } catch (e) {
      promptAction.showToast({ message: '重命名失败', duration: 1500 });
    }
  }
}
