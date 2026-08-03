/**
 * GroupMemberManagePage 群聊成员管理
 *
 * G-UI-1 预览页面:管理指定群聊的成员列表。
 *
 * 功能:
 * - 显示成员列表(顺序号 + 头像 + 名称 + 启用/停用状态)
 * - 上移 / 下移调整顺序
 * - 启用 / 停用切换
 * - 移除成员(至少保留 2 个)
 * - 添加预览角色(从预览角色池选择,非真实角色 Service)
 *
 * 数据来源:GroupChatPreviewStore(内存态,非数据库)。
 * 所有操作仅修改页面内预览状态,不调用 Repository / Service。
 */

import { router, promptAction } from '@kit.ArkUI';
import { CharacterImageView } from '../../components/CharacterImageView';
import { GroupChatPreviewStore, PENDING_GROUP_CHAT_ID_KEY } from './preview/GroupChatPreviewStore';
import {
  GroupChatPreviewCharacter,
  GroupChatPreviewMember,
  GroupChatPreviewSession
} from './preview/GroupChatPreviewModels';
import {
  PREVIEW_CHARACTERS,
  PREVIEW_MEMBER_MIN,
  PREVIEW_MEMBER_MAX
} from './preview/GroupChatPreviewData';

@Entry
@Component
struct GroupMemberManagePage {
  /** 当前会话 ID */
  @State sessionId: string = '';
  /** 当前会话快照(null 时显示空态) */
  @State session: GroupChatPreviewSession | null = null;
  /** 添加角色弹窗是否可见 */
  @State addDialogVisible: boolean = false;
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
          this.hintArea()
          this.memberListArea()
          this.bottomAddButton()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 添加角色弹窗
      if (this.addDialogVisible) {
        this.addDialog()
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

      Text($r('app.string.group_manage_title'))
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

  /** 规则提示 */
  @Builder
  hintArea(): void {
    Text($r('app.string.group_member_min_hint'))
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_tertiary'))
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
  }

  /** 成员列表 */
  @Builder
  memberListArea(): void {
    List() {
      ForEach(this.session!.members, (member: GroupChatPreviewMember) => {
        ListItem() {
          this.memberRow(member)
        }
        .margin({ bottom: $r('app.float.app_spacing_8') })
      }, (member: GroupChatPreviewMember) => member.id + '|' + String(member.order) + '|' + String(member.enabled) + '|' + member.status)

      // 末尾空白
      ListItem() {
        Column().width('100%').height(100)
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

  /** 单个成员行 */
  @Builder
  memberRow(member: GroupChatPreviewMember): void {
    Column() {
      // 第一行:顺序号 + 头像 + 名称 + 状态
      Row() {
        // 顺序号
        Text(String(member.order + 1))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_secondary'))
          .width(24)
          .textAlign(TextAlign.Center)

        // 头像
        CharacterImageView({
          imageUri: member.avatarUri,
          fallbackName: member.name,
          imgWidth: 40,
          imgHeight: 40,
          imgBorderRadius: 20,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
          .margin({ left: 8 })
          .opacity(member.enabled ? 1 : 0.5)

        // 名称 + 状态
        Column() {
          Text(member.name)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(member.enabled ? $r('app.color.app_text_primary') : $r('app.color.app_text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(member.enabled ? $r('app.string.group_manage_enabled') : $r('app.string.group_manage_disabled'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(member.enabled ? $r('app.color.app_accent') : $r('app.color.app_text_tertiary'))
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第二行:操作按钮
      Row() {
        Button($r('app.string.group_create_move_up'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .accessibilityText('上移角色')
          .enabled(member.order > 0)
          .onClick(() => {
            this.handleMoveUp(member.id);
          })

        Button($r('app.string.group_create_move_down'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText('下移角色')
          .enabled(member.order < this.session!.members.length - 1)
          .onClick(() => {
            this.handleMoveDown(member.id);
          })

        Button(member.enabled ? $r('app.string.group_manage_disable') : $r('app.string.group_manage_enable'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(member.enabled ? $r('app.color.app_danger') : $r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .accessibilityText(member.enabled ? '停用角色' : '启用角色')
          .onClick(() => {
            this.handleToggleEnabled(member.id, member.enabled);
          })

        Button($r('app.string.group_manage_remove'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .enabled(this.session!.members.length > PREVIEW_MEMBER_MIN)
          .onClick(() => {
            this.handleRemove(member.id);
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Start)
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
  }

  /** 底部添加按钮 */
  @Builder
  bottomAddButton(): void {
    Row() {
      Button($r('app.string.group_manage_add'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .layoutWeight(1)
        .enabled(this.session !== null && this.session!.members.length < PREVIEW_MEMBER_MAX)
        .onClick(() => {
          this.addDialogVisible = true;
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_16')
    })
  }

  /** 添加角色弹窗 */
  @Builder
  addDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.group_manage_add_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })
            .width('100%')

          // 可添加角色列表(尚未在群聊中的)
          List() {
            ForEach(this.getAddableCharacters(), (char: GroupChatPreviewCharacter) => {
              ListItem() {
                Row() {
                  CharacterImageView({
                    imageUri: char.avatarUri,
                    fallbackName: char.name,
                    imgWidth: 36,
                    imgHeight: 36,
                    imgBorderRadius: 18,
                    displayMode: 'thumbnail',
                    objectFit: ImageFit.Cover
                  })

                  Column() {
                    Text(char.name)
                      .fontSize($r('app.float.app_font_body'))
                      .fontColor($r('app.color.app_text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(char.description)
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

                  Button($r('app.string.group_manage_add'))
                    .fontSize($r('app.float.app_font_caption'))
                    .fontColor($r('app.color.app_on_accent'))
                    .backgroundColor($r('app.color.app_accent'))
                    .borderRadius($r('app.float.app_radius_sm'))
                    .height(32)
                    .padding({ left: 12, right: 12 })
                    .onClick(() => {
                      this.handleAddMember(char.id);
                    })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .alignItems(VerticalAlign.Center)
              }
            }, (char: GroupChatPreviewCharacter) => char.id)
          }
          .width('100%')
          .height(280)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)

          Button($r('app.string.group_cancel'))
            .fontSize(15)
            .fontColor($r('app.color.app_text_secondary'))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 8 })
            .onClick(() => {
              this.addDialogVisible = false;
            })
        }
        .width('85%')
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
      this.addDialogVisible = false;
    })
  }

  /** 获取可添加的角色(不在当前群聊中的) */
  private getAddableCharacters(): GroupChatPreviewCharacter[] {
    if (this.session === null) {
      return [];
    }
    const existIds: Set<string> = new Set<string>();
    for (let i = 0; i < this.session!.members.length; i++) {
      existIds.add(this.session!.members[i].characterId);
    }
    const result: GroupChatPreviewCharacter[] = [];
    for (let i = 0; i < PREVIEW_CHARACTERS.length; i++) {
      if (!existIds.has(PREVIEW_CHARACTERS[i].id)) {
        result.push(PREVIEW_CHARACTERS[i]);
      }
    }
    return result;
  }

  // ===== 操作处理 =====

  /** 上移成员 */
  private handleMoveUp(memberId: string): void {
    GroupChatPreviewStore.moveMemberUp(this.sessionId, memberId);
    this.syncFromStore();
  }

  /** 下移成员 */
  private handleMoveDown(memberId: string): void {
    GroupChatPreviewStore.moveMemberDown(this.sessionId, memberId);
    this.syncFromStore();
  }

  /** 切换启用/停用 */
  private handleToggleEnabled(memberId: string, currentEnabled: boolean): void {
    if (currentEnabled) {
      // 停用前检查至少保留 2 个启用
      if (this.session === null) {
        return;
      }
      const enabledCount: number = this.session!.members.filter(
        (m: GroupChatPreviewMember): boolean => m.enabled
      ).length;
      if (enabledCount <= PREVIEW_MEMBER_MIN) {
        promptAction.showToast({ message: '至少保留 ' + String(PREVIEW_MEMBER_MIN) + ' 个启用角色', duration: 1500 });
        return;
      }
    }
    GroupChatPreviewStore.setMemberEnabled(this.sessionId, memberId, !currentEnabled);
    this.syncFromStore();
  }

  /** 移除成员 */
  private handleRemove(memberId: string): void {
    if (this.session === null) {
      return;
    }
    if (this.session!.members.length <= PREVIEW_MEMBER_MIN) {
      promptAction.showToast({ message: '最少保留 ' + String(PREVIEW_MEMBER_MIN) + ' 个成员', duration: 1500 });
      return;
    }
    GroupChatPreviewStore.removeMember(this.sessionId, memberId);
    this.syncFromStore();
    promptAction.showToast({ message: '已移除成员(预览)', duration: 1200 });
  }

  /** 添加成员 */
  private handleAddMember(characterId: string): void {
    if (this.session !== null && this.session!.members.length >= PREVIEW_MEMBER_MAX) {
      promptAction.showToast({ message: '最多 ' + String(PREVIEW_MEMBER_MAX) + ' 位角色', duration: 1500 });
      return;
    }
    GroupChatPreviewStore.addMember(this.sessionId, characterId);
    this.syncFromStore();
    this.addDialogVisible = false;
    promptAction.showToast({ message: '已添加成员(预览)', duration: 1200 });
  }
}
