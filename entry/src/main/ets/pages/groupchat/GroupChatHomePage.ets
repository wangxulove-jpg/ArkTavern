/**
 * GroupChatHomePage 多人聊天首页
 *
 * G-UI-1 预览页面:多人聊天入口与群聊列表。
 *
 * 结构:
 * - 顶部:标题"多人聊天" + 副标题 + 创建按钮
 * - 列表:群聊卡片(头像堆叠 + 标题 + 成员摘要 + 最后消息 + 时间)
 * - 空状态:无群聊时展示 CTA
 *
 * 数据来源:GroupChatPreviewStore(内存态,非数据库)。
 * 标记为"预览",不伪装真实可用。
 */

import { router, promptAction } from '@kit.ArkUI';
import { GroupChatPreviewStore, PENDING_GROUP_CHAT_ID_KEY } from './preview/GroupChatPreviewStore';
import { GroupChatPreviewSession } from './preview/GroupChatPreviewModels';
import { GroupChatCard } from '../../components/groupchat/GroupChatCard';
import { GroupEmptyState } from '../../components/groupchat/GroupEmptyState';

@Entry
@Component
struct GroupChatHomePage {
  @State sessions: GroupChatPreviewSession[] = [];
  /** 长按菜单目标(空时不显示) */
  @State moreTarget: GroupChatPreviewSession | null = null;
  /** 重命名弹窗目标 */
  @State renameTarget: GroupChatPreviewSession | null = null;
  /** 重命名输入值 */
  @State renameInput: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  aboutToAppear(): void {
    this.syncFromStore();
  }

  /** 从 store 同步快照到本地 @State(新数组触发刷新) */
  private syncFromStore(): void {
    this.sessions = GroupChatPreviewStore.listSessions();
  }

  build(): void {
    Stack() {
      Column() {
        this.headerArea()
        this.listArea()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 更多菜单弹窗
      if (this.moreTarget !== null) {
        this.moreMenuDialog()
      }

      // 重命名弹窗
      if (this.renameTarget !== null) {
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

      // 创建按钮
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

  /** 列表区:空状态 or 卡片列表 */
  @Builder
  listArea(): void {
    if (this.sessions.length === 0) {
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
    } else {
      List() {
        ForEach(this.sessions, (session: GroupChatPreviewSession) => {
          ListItem() {
            GroupChatCard({
              session: session,
              onPress: (s: GroupChatPreviewSession): void => {
                this.openSession(s);
              },
              onMore: (s: GroupChatPreviewSession): void => {
                this.moreTarget = s;
              }
            })
          }
          .margin({ bottom: $r('app.float.app_spacing_12') })
        }, (session: GroupChatPreviewSession) => session.id + '|' + String(session.updatedAt))

        // 末尾空白:确保可滚动
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
  }

  /** 打开群聊:写入 pending ID,push 到 GroupChatPage */
  private openSession(session: GroupChatPreviewSession): void {
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, session.id);
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

          if (this.moreTarget !== null) {
            Text(this.moreTarget!.title)
              .fontSize(14)
              .fontColor($r('app.color.app_text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ bottom: 12 })
          }

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
              this.deletePreview();
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
              this.moreTarget = null;
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
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.moreTarget = null;
    })
  }

  /** 打开重命名弹窗 */
  private openRenameDialog(): void {
    if (this.moreTarget !== null) {
      this.renameTarget = this.moreTarget;
      this.renameInput = this.moreTarget!.title;
      this.moreTarget = null;
    }
  }

  /** 跳转成员管理 */
  private goManageMembers(): void {
    if (this.moreTarget !== null) {
      AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, this.moreTarget!.id);
      this.moreTarget = null;
      router.pushUrl({ url: 'pages/groupchat/GroupMemberManagePage' });
    }
  }

  /** 删除预览群聊 */
  private deletePreview(): void {
    if (this.moreTarget !== null) {
      GroupChatPreviewStore.deleteSession(this.moreTarget!.id);
      this.moreTarget = null;
      this.syncFromStore();
      promptAction.showToast({ message: '已删除预览群聊', duration: 1500 });
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
                this.renameTarget = null;
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
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  /** 确认重命名 */
  private confirmRename(): void {
    if (this.renameTarget === null) {
      return;
    }
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    GroupChatPreviewStore.renameSession(this.renameTarget!.id, trimmed);
    this.renameTarget = null;
    this.renameInput = '';
    this.syncFromStore();
  }
}
