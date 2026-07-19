/**
 * CharacterRootView 角色卡 Tab 根视图(UI-3B)
 *
 * 重新设计后的角色卡首页:
 * - 顶部标题栏:标题"角色卡" + 右上角"导入"按钮(导航到现有 CharacterListPage)
 * - 所有角色以展开式卡片展示
 * - 每张角色卡显示图片、名称、简介
 * - 角色卡支持左滑显示三个操作:新建对话 / 编辑 / 删除
 * - 同一时间只展开一张角色卡(由 List swipeAction 默认行为保证)
 * - 点击角色卡或角色图片 -> 跳转到 CharacterListPage 并自动打开该角色编辑弹窗(作为详情)
 * - 左滑"新建对话" -> 通过 pendingCharacterId 让 ChatPage 用该角色创建新会话(不修改全局当前角色)
 * - 左滑"编辑" -> 同点击角色卡,跳转到编辑弹窗
 * - 左滑"删除" -> 弹出二次确认(含角色名),确认后复用 CharacterListViewModel.deleteCharacter
 * - 底部保留现有 HdsTabs 沉浸光感导航栏
 *
 * 不复用旧版:
 * - 当前角色摘要卡 / "全部角色"分区 / 英文副标题 / "当前"标签
 *
 * 保留业务:
 * - currentCharacterId 不删除
 * - CharacterService 当前角色逻辑不修改
 * - 删除角色复用 CharacterListViewModel.deleteCharacter(底层走 CharacterService.remove)
 *
 * 分层:
 * - 只通过 CharacterListViewModel 访问业务
 * - 不直接调用 RDB / Repository / 文件解析器
 * - 不复制文件选择器/导入预览/确认弹窗
 */

import { CharacterListViewModel } from '../../viewmodels/CharacterListViewModel';
import { Character } from '../../models/Character';
import { AppServices } from '../../services/AppServices';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';
import { CharacterImageView } from '../../components/CharacterImageView';

@Component
export struct CharacterRootView {
  /** AppShell 传入的全局 NavPathStack,用于跳转二级页面 */
  pathStack: NavPathStack = new NavPathStack();
  @State viewModel: CharacterListViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';
  /** 删除二次确认的目标角色(null 时确认弹窗不显示) */
  @State deleteTarget: Character | null = null;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const charService = AppServices.getCharacterService();
      const vm: CharacterListViewModel = new CharacterListViewModel(charService);
      this.viewModel = vm;
      await vm.load();
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      this.initError = (e as Error).message ?? '';
    }
  }

  /** 页面恢复时刷新列表(从二级页面返回,如编辑保存后) */
  onPageShow(): void {
    if (this.viewModel !== null && AppServices.isStarted()) {
      this.viewModel!.load().catch((): void => {});
    }
  }

  // ===== 跳转 / 操作 =====

  /** 点击角色卡:跳转到 CharacterListPage 并自动打开该角色的编辑弹窗(作为详情) */
  private openCharacterDetail(characterId: string): void {
    AppStorage.setOrCreate<string>('pendingCharacterDetailId', characterId);
    this.pathStack.pushPath({ name: 'CharacterListPage' });
  }

  /** 左滑"新建对话":用该角色创建新会话并跳转 ChatPage(不修改全局当前角色) */
  private startNewChatWithCharacter(characterId: string): void {
    AppStorage.setOrCreate<string>('pendingCharacterId', characterId);
    // 清除 pendingChatId 防止冲突(优先级:pendingChatId > pendingCharacterId)
    AppStorage.setOrCreate<string>('pendingChatId', '');
    this.pathStack.pushPath({ name: 'ChatPage' });
  }

  /** 左滑"编辑":与点击角色卡相同,跳转到编辑弹窗 */
  private editCharacter(characterId: string): void {
    this.openCharacterDetail(characterId);
  }

  /** 左滑"删除":弹出二次确认 */
  private promptDelete(char: Character): void {
    this.deleteTarget = char;
  }

  /** 确认删除:复用 ViewModel 的删除逻辑(底层走 CharacterService.remove) */
  private async confirmDelete(): Promise<void> {
    if (this.viewModel === null || this.deleteTarget === null) {
      this.deleteTarget = null;
      return;
    }
    const id: string = this.deleteTarget.id;
    this.deleteTarget = null;
    // ViewModel 内部已记录 errorMessage,这里不重复处理
    await this.viewModel!.deleteCharacter(id);
  }

  /** 取消删除 */
  private cancelDelete(): void {
    this.deleteTarget = null;
  }

  /** 删除确认消息(显示角色名) */
  private formatDeleteMessage(name: string): string {
    return '确定删除角色"' + name + '"吗?此操作不可撤销。';
  }

  build() {
    Column() {
      // ===== 顶部标题栏 =====
      this.headerBar()

      // ===== 错误提示 =====
      if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
        Text(this.viewModel!.errorMessage)
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
      } else if (this.viewModel === null || this.viewModel!.characters.length === 0) {
        this.emptyStateView()
      } else {
        this.characterList()
      }

      // ===== 删除二次确认弹窗 =====
      if (this.deleteTarget !== null) {
        this.deleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
  }

  // ===== 标题栏 =====

  @Builder
  headerBar() {
    Row() {
      Text($r('app.string.tab_characters'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()

      Button($r('app.string.character_import'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_accent'))
        .backgroundColor(Color.Transparent)
        .height(48)
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          // 导航到现有 CharacterListPage,在那里使用完整的导入流程
          this.pathStack.pushPath({ name: 'CharacterListPage' });
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 20, right: 20 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 角色列表(支持左滑) =====

  @Builder
  characterList() {
    List() {
      ForEach(this.viewModel!.characters, (char: Character) => {
        ListItem() {
          this.characterCard(char)
        }
        .margin({ bottom: $r('app.float.app_spacing_12') })
        .swipeAction({
          end: {
            builder: (): void => {
              this.swipeActionButtons(char)
            }
          }
        })
      }, (char: Character) => char.id)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: 100
    })
  }

  // ===== 左滑操作按钮(新建对话 / 编辑 / 删除) =====

  @Builder
  swipeActionButtons(char: Character) {
    Row() {
      // 新建对话 - 主操作
      Button($r('app.string.character_action_new_chat'))
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_accent'))
        .height('100%')
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          this.startNewChatWithCharacter(char.id);
        })

      // 编辑
      Button($r('app.string.character_action_edit'))
        .fontSize(14)
        .fontColor($r('app.color.app_text_primary'))
        .backgroundColor($r('app.color.app_surface_2'))
        .height('100%')
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          this.editCharacter(char.id);
        })

      // 删除 - 危险操作
      Button($r('app.string.character_action_delete'))
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.app_danger'))
        .height('100%')
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          this.promptDelete(char);
        })
    }
    .height('100%')
  }

  // ===== 展开式角色卡 =====

  @Builder
  characterCard(char: Character) {
    PressableCard({
      onPress: () => {
        // 点击角色卡 -> 跳转到该角色详情(编辑弹窗)
        this.openCharacterDetail(char.id);
      },
      surfaceColor: $r('app.color.app_surface_1')
    }) {
      Row() {
        // 左侧角色图片
        CharacterImageView({
          imageUri: char.avatarUri,
          fallbackName: char.name,
          imgWidth: 100,
          imgHeight: 130,
          imgBorderRadius: 12,
          displayMode: 'portrait',
          objectFit: ImageFit.Cover
        })

        // 右侧角色信息
        Column() {
          Text(char.name)
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          if (char.description.length > 0) {
            Text(char.description)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_secondary'))
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          if (char.personality.length > 0) {
            Text(char.personality)
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
        .padding({ left: $r('app.float.app_spacing_16') })

        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding($r('app.float.app_spacing_16'))
      .alignItems(VerticalAlign.Center)
    }
  }

  // ===== 空状态 =====

  @Builder
  emptyStateView() {
    Scroll() {
      Column() {
        EmptyStateView({
          title: $r('app.string.character_home_empty_title'),
          description: $r('app.string.character_home_empty_desc')
        })

        // 主要操作:导入角色卡(导航到现有导入流程)
        Button($r('app.string.tab_characters_import'))
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor($r('app.color.app_accent'))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(48)
          .width('60%')
          .margin({ top: $r('app.float.app_spacing_24') })
          .onClick(() => {
            this.pathStack.pushPath({ name: 'CharacterListPage' });
          })

        // 次要操作:新建角色(导航到现有角色管理页面)
        Button($r('app.string.character_new'))
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_text_secondary'))
          .height(48)
          .margin({ top: $r('app.float.app_spacing_8') })
          .onClick(() => {
            this.pathStack.pushPath({ name: 'CharacterListPage' });
          })
      }
      .width('100%')
      .padding({
        top: $r('app.float.app_spacing_48'),
        bottom: 100,
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20')
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  // ===== 加载 / 错误视图 =====

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
        title: $r('app.string.tab_characters_load_failed'),
        description: this.initError
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 删除二次确认弹窗 =====

  @Builder
  deleteConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          // 标题
          Text($r('app.string.character_delete_confirm_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 12 })

          // 提示内容(含角色名)
          Text(this.formatDeleteMessage(this.deleteTarget!.name))
            .fontSize(14)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ bottom: 20 })

          // 按钮行
          Row() {
            Button($r('app.string.character_delete_confirm_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.app_text_secondary'))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.cancelDelete();
              })

            Button($r('app.string.character_delete_confirm_ok'))
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius(20)
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmDelete();
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(20)
        .backgroundColor($r('app.color.app_surface_1'))
        .borderRadius(16)
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
      // 点击外部取消
      this.cancelDelete();
    })
  }
}
