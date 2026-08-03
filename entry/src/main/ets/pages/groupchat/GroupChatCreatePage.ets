/**
 * GroupChatCreatePage 创建多人聊天
 *
 * G-UI-1 预览页面:两步式创建流程。
 *
 * 步骤 1 / 2:选择角色
 * - 搜索框 + 角色列表(头像 / 名称 / 描述 / 选择状态)
 * - 最少 2 位,最多 8 位
 * - 按选择顺序确定默认发言顺序
 *
 * 步骤 2 / 2:群聊配置
 * - 群聊名称(默认由角色名组合)
 * - 已选成员(上移 / 下移调整顺序)
 * - 回复方式(仅"按成员顺序回复")
 * - 创建并进入聊天
 *
 * 数据来源:GroupChatPreviewStore(内存态,非数据库)。
 */

import { router, promptAction } from '@kit.ArkUI';
import { CharacterImageView } from '../../components/CharacterImageView';
import { GroupChatPreviewStore, PENDING_GROUP_CHAT_ID_KEY } from './preview/GroupChatPreviewStore';
import { GroupChatPreviewCharacter } from './preview/GroupChatPreviewModels';
import {
  PREVIEW_CHARACTERS,
  PREVIEW_MEMBER_MIN,
  PREVIEW_MEMBER_MAX,
  composeDefaultTitle
} from './preview/GroupChatPreviewData';

/** 选中角色项(带选择顺序) */
interface SelectedCharacterItem {
  readonly character: GroupChatPreviewCharacter;
  readonly selectedOrder: number;
}

@Entry
@Component
struct GroupChatCreatePage {
  /** 当前步骤:1=选择角色,2=群聊配置 */
  @State step: number = 1;
  /** 搜索关键词 */
  @State searchKeyword: string = '';
  /** 已选角色 ID 列表(按选择顺序) */
  @State selectedIds: string[] = [];
  /** 步骤二:群聊名称输入值 */
  @State chatNameInput: string = '';
  /** 步骤二:是否已用自定义名称(为 true 时不自动覆盖) */
  @State nameCustomized: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  /** 获取过滤后的角色列表(按搜索关键词) */
  private getFilteredCharacters(): GroupChatPreviewCharacter[] {
    const keyword: string = this.searchKeyword.trim();
    if (keyword.length === 0) {
      return PREVIEW_CHARACTERS.slice();
    }
    const result: GroupChatPreviewCharacter[] = [];
    for (let i = 0; i < PREVIEW_CHARACTERS.length; i++) {
      const c: GroupChatPreviewCharacter = PREVIEW_CHARACTERS[i];
      if (c.name.indexOf(keyword) >= 0 || c.description.indexOf(keyword) >= 0) {
        result.push(c);
      }
    }
    return result;
  }

  /** 获取已选角色项(按选择顺序) */
  private getSelectedItems(): SelectedCharacterItem[] {
    const items: SelectedCharacterItem[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      const char = this.findCharacterById(this.selectedIds[i]);
      if (char !== null) {
        items.push({ character: char, selectedOrder: i + 1 });
      }
    }
    return items;
  }

  /** 按 ID 查找预览角色 */
  private findCharacterById(id: string): GroupChatPreviewCharacter | null {
    for (let i = 0; i < PREVIEW_CHARACTERS.length; i++) {
      if (PREVIEW_CHARACTERS[i].id === id) {
        return PREVIEW_CHARACTERS[i];
      }
    }
    return null;
  }

  /** 切换角色选择状态 */
  private toggleSelect(characterId: string): void {
    const idx: number = this.selectedIds.indexOf(characterId);
    if (idx >= 0) {
      // 取消选择
      const next: string[] = this.selectedIds.filter((id: string): boolean => id !== characterId);
      this.selectedIds = next;
    } else {
      // 选择(检查上限)
      if (this.selectedIds.length >= PREVIEW_MEMBER_MAX) {
        promptAction.showToast({ message: '最多选择 ' + String(PREVIEW_MEMBER_MAX) + ' 位角色', duration: 1500 });
        return;
      }
      this.selectedIds = this.selectedIds.concat([characterId]);
    }
  }

  /** 进入步骤二 */
  private goStepTwo(): void {
    if (this.selectedIds.length < PREVIEW_MEMBER_MIN) {
      promptAction.showToast({ message: '最少选择 ' + String(PREVIEW_MEMBER_MIN) + ' 位角色', duration: 1500 });
      return;
    }
    // 首次进入步骤二时,若未自定义名称,生成默认名称
    if (!this.nameCustomized && this.chatNameInput.trim().length === 0) {
      const names: string[] = this.getSelectedItems().map((item: SelectedCharacterItem): string => item.character.name);
      this.chatNameInput = composeDefaultTitle(names);
    }
    this.step = 2;
  }

  /** 返回步骤一 */
  private goStepOne(): void {
    this.step = 1;
  }

  /** 上移成员(步骤二) */
  private moveUp(characterId: string): void {
    const idx: number = this.selectedIds.indexOf(characterId);
    if (idx <= 0) {
      return;
    }
    const next: string[] = this.selectedIds.slice();
    next[idx] = next[idx - 1];
    next[idx - 1] = characterId;
    this.selectedIds = next;
    this.refreshDefaultName();
  }

  /** 下移成员(步骤二) */
  private moveDown(characterId: string): void {
    const idx: number = this.selectedIds.indexOf(characterId);
    if (idx < 0 || idx >= this.selectedIds.length - 1) {
      return;
    }
    const next: string[] = this.selectedIds.slice();
    next[idx] = next[idx + 1];
    next[idx + 1] = characterId;
    this.selectedIds = next;
    this.refreshDefaultName();
  }

  /** 名称输入变化 */
  private onNameInput(value: string): void {
    this.chatNameInput = value;
    this.nameCustomized = value.trim().length > 0;
  }

  /** 当未自定义名称时,根据当前选择重新生成默认名称 */
  private refreshDefaultName(): void {
    if (this.nameCustomized) {
      return;
    }
    const names: string[] = this.getSelectedItems().map((item: SelectedCharacterItem): string => item.character.name);
    this.chatNameInput = composeDefaultTitle(names);
  }

  /** 确认创建并进入聊天 */
  private confirmCreate(): void {
    if (this.selectedIds.length < PREVIEW_MEMBER_MIN) {
      promptAction.showToast({ message: '最少选择 ' + String(PREVIEW_MEMBER_MIN) + ' 位角色', duration: 1500 });
      return;
    }
    const title: string = this.chatNameInput.trim();
    const id: string = GroupChatPreviewStore.createSession(title, this.selectedIds);
    AppStorage.setOrCreate<string>(PENDING_GROUP_CHAT_ID_KEY, id);
    // 替换当前页面栈为 GroupChatPage,避免返回时回到创建页
    router.replaceUrl({ url: 'pages/groupchat/GroupChatPage' });
  }

  build(): void {
    Column() {
      this.headerArea()
      if (this.step === 1) {
        this.stepOneArea()
      } else {
        this.stepTwoArea()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
        if (this.step === 2) {
          this.goStepOne();
        } else {
          router.back();
        }
      })

      Column() {
        Text($r('app.string.group_create_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.step === 1 ? $r('app.string.group_create_step_1') : $r('app.string.group_create_step_2'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
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

  /** 步骤一:选择角色 */
  @Builder
  stepOneArea(): void {
    Column() {
      // 搜索框
      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(18)
          .fontColor([$r('app.color.app_text_tertiary')])
          .margin({ right: 8 })

        TextInput({ placeholder: $r('app.string.group_create_search_placeholder'), text: this.searchKeyword })
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.searchKeyword = value;
          })
      }
      .width('100%')
      .height(44)
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 12, right: 12 })
      .margin({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
      .alignItems(VerticalAlign.Center)

      // 提示信息
      Row() {
        Text($r('app.string.group_create_min_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        Text('  ·  ')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
        Text($r('app.string.group_create_max_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })

      // 角色列表
      List() {
        ForEach(this.getFilteredCharacters(), (character: GroupChatPreviewCharacter) => {
          ListItem() {
            this.characterRow(character)
          }
          .margin({ bottom: $r('app.float.app_spacing_8') })
        }, (character: GroupChatPreviewCharacter) => character.id)

        // 末尾空白
        ListItem() {
          Column().width('100%').height(120)
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

      // 底部固定栏
      this.bottomBarStepOne()
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 单个角色行 */
  @Builder
  characterRow(character: GroupChatPreviewCharacter): void {
    Row() {
      // 头像
      CharacterImageView({
        imageUri: character.avatarUri,
        fallbackName: character.name,
        imgWidth: 44,
        imgHeight: 44,
        imgBorderRadius: 22,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })

      // 名称 + 描述
      Column() {
        Text(character.name)
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(character.description)
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

      // 选择状态(内联表达式避免 @Builder 内声明局部变量)
      if (this.selectedIds.indexOf(character.id) >= 0) {
        // 显示选择顺序
        Text(String(this.selectedIds.indexOf(character.id) + 1))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius(10)
          .width(20)
          .height(20)
          .textAlign(TextAlign.Center)
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize(22)
          .fontColor([$r('app.color.app_text_tertiary')])
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
    .onClick(() => {
      this.toggleSelect(character.id);
    })
  }

  /** 步骤一底部固定栏 */
  @Builder
  bottomBarStepOne(): void {
    Row() {
      Text('已选择 ' + String(this.selectedIds.length) + ' 位角色')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .layoutWeight(1)

      Button($r('app.string.group_create_next'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(this.selectedIds.length >= PREVIEW_MEMBER_MIN ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .enabled(this.selectedIds.length >= PREVIEW_MEMBER_MIN)
        .onClick(() => {
          this.goStepTwo();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navBarHeight + 12
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
    .alignItems(VerticalAlign.Center)
  }

  /** 步骤二:群聊配置 */
  @Builder
  stepTwoArea(): void {
    Column() {
      Scroll() {
        Column() {
          // 群聊名称
          Column() {
            Text($r('app.string.group_create_chat_name'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .width('100%')

            TextInput({ placeholder: $r('app.string.group_create_chat_name_placeholder'), text: this.chatNameInput })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_text_primary'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(44)
              .padding({ left: 12, right: 12 })
              .margin({ top: 8 })
              .onChange((value: string) => {
                this.onNameInput(value);
              })
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })
          .backgroundColor($r('app.color.app_surface_1'))

          // 已选成员 + 发言顺序
          Column() {
            Text($r('app.string.group_create_speak_order'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .width('100%')
              .margin({ bottom: 8 })

            ForEach(this.getSelectedItems(), (item: SelectedCharacterItem) => {
              this.memberOrderRow(item)
            }, (item: SelectedCharacterItem) => item.character.id + '_' + String(item.selectedOrder))
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })
          .backgroundColor($r('app.color.app_surface_1'))
          .margin({ top: 8 })

          // 回复方式
          Column() {
            Text($r('app.string.group_create_reply_mode'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .width('100%')
              .margin({ bottom: 8 })

            Row() {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(20)
                .fontColor([$r('app.color.app_accent')])
              Text($r('app.string.group_create_reply_mode_sequential'))
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_text_primary'))
                .margin({ left: 8 })
                .layoutWeight(1)
            }
            .width('100%')
            .height(44)
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })
          .backgroundColor($r('app.color.app_surface_1'))
          .margin({ top: 8 })

          // 末尾空白
          Column().width('100%').height(120)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // 底部固定栏
      this.bottomBarStepTwo()
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 成员顺序行(步骤二) */
  @Builder
  memberOrderRow(item: SelectedCharacterItem): void {
    Row() {
      // 顺序号
      Text(String(item.selectedOrder))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius(12)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)

      // 头像
      CharacterImageView({
        imageUri: item.character.avatarUri,
        fallbackName: item.character.name,
        imgWidth: 36,
        imgHeight: 36,
        imgBorderRadius: 18,
        displayMode: 'thumbnail',
        objectFit: ImageFit.Cover
      })
        .margin({ left: 8 })

      // 名称
      Text(item.character.name)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
        .margin({ left: 8 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 上移按钮
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(18)
          .fontColor([$r('app.color.app_text_secondary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('上移角色')
      .onClick(() => {
        this.moveUp(item.character.id);
      })

      // 下移按钮
      Button() {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(18)
          .fontColor([$r('app.color.app_text_secondary')])
      }
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .accessibilityText('下移角色')
      .onClick(() => {
        this.moveDown(item.character.id);
      })
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
  }

  /** 步骤二底部固定栏 */
  @Builder
  bottomBarStepTwo(): void {
    Row() {
      Button($r('app.string.group_create_prev'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          this.goStepOne();
        })

      Button($r('app.string.group_create_confirm'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .padding({ left: 20, right: 20 })
        .margin({ left: 12 })
        .layoutWeight(1)
        .onClick(() => {
          this.confirmCreate();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navBarHeight + 12
    })
    .backgroundColor($r('app.color.app_surface_1'))
    .border({ width: { top: 0.5 }, color: $r('app.color.app_divider') })
    .alignItems(VerticalAlign.Center)
  }
}
