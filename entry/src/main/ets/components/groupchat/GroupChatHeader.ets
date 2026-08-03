/**
 * GroupChatHeader 群聊顶部标题栏
 *
 * G-UI-1 预览组件:GroupChatPage 顶部固定栏。
 * 返回按钮 + 群聊名称 + 副标题(成员数/回复状态) + 更多菜单。
 *
 * 纯 UI,不依赖 Service / Repository / 数据库。
 */

import { GroupRoundPreviewStatus } from '../../pages/groupchat/preview/GroupChatPreviewModels';

@Component
export struct GroupChatHeader {
  /** 群聊名称 */
  title: string = '';
  /** 成员总数 */
  memberCount: number = 0;
  /** 当前轮次状态 */
  roundStatus: GroupRoundPreviewStatus = GroupRoundPreviewStatus.Idle;
  /** 当前正在生成的成员名称(无生成时为空) */
  generatingMemberName: string = '';
  /** 返回回调 */
  onBack: () => void = () => {};
  /** 更多菜单回调 */
  onMore: () => void = () => {};
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  build(): void {
    Row() {
      // 返回按钮
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
        this.onBack();
      })

      // 标题区
      Column() {
        Text(this.title)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.buildSubtitle())
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

      // 更多按钮
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
        this.onMore();
      })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_8'),
      right: $r('app.float.app_spacing_8'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.app_bg'))
  }

  /** 构建副标题 */
  private buildSubtitle(): string {
    const countText: string = String(this.memberCount) + ' 位角色';
    if (this.roundStatus === GroupRoundPreviewStatus.Generating && this.generatingMemberName.length > 0) {
      return countText + ' · ' + this.generatingMemberName + '正在回复';
    }
    return countText + ' · 按顺序回复';
  }
}
