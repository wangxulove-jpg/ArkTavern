/**
 * CharacterRootView 角色卡 Tab 根视图(UI-1)
 *
 * 作为 HdsTabs 的第一个 Tab 内容,展示角色卡入口。
 *
 * 设计:
 * - 标题区:应用名 + 简短描述
 * - 当前角色状态(已选/未选)
 * - 操作行:新建角色 + 导入角色卡
 * - 角色列表(点击进入 CharacterListPage 二级页面)
 * - 无角色空状态
 * - 加载 / 错误状态
 *
 * 复用:
 * - CharacterListViewModel(只读接线,角色列表加载与当前角色查询)
 * - AppServices.getCharacterService()
 * - AppPageHeader / EmptyStateView / PressableCard(UI 组件)
 *
 * 不重写:
 * - 角色编辑对话框(CharacterListPage 二级页面保留完整功能)
 * - 角色导入预览(CharacterListPage 二级页面处理)
 * - CharacterService 业务逻辑
 */

import { CharacterListViewModel } from '../../viewmodels/CharacterListViewModel';
import { Character } from '../../models/Character';
import { AppServices } from '../../services/AppServices';
import { AppPageHeader } from '../../components/AppPageHeader';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';

@Component
export struct CharacterRootView {
  /** AppShell 传入的全局 NavPathStack,用于跳转二级页面 */
  pathStack: NavPathStack = new NavPathStack();
  @State viewModel: CharacterListViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';

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

  /** 页面恢复时刷新列表(从二级页面返回) */
  onPageShow(): void {
    if (this.viewModel !== null && AppServices.isStarted()) {
      this.viewModel!.load().catch((): void => {});
    }
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题区 =====
        AppPageHeader({
          title: $r('app.string.tab_characters'),
          subtitle: $r('app.string.tab_characters_subtitle')
        })

        Text($r('app.string.tab_characters_desc'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({
            left: $r('app.float.app_spacing_20'),
            right: $r('app.float.app_spacing_20'),
            bottom: $r('app.float.app_spacing_12')
          })

        // ===== 当前角色状态 =====
        this.currentCharacterRow()

        // ===== 操作行:新建 + 导入 =====
        this.actionRow()

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
        } else {
          this.characterListArea()
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
  }

  /**
   * 当前角色状态行。
   * 已选时显示当前角色名称,点击进入 CharacterListPage 二级页面。
   */
  @Builder
  currentCharacterRow() {
    Column() {
      PressableCard({
        onPress: () => {
          this.pathStack.pushPath({ name: 'CharacterListPage' });
        }
      }) {
        Row() {
          Column() {
            if (this.viewModel !== null && this.viewModel!.currentCharacterId !== null) {
              Text($r('app.string.tab_characters_current_label'))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.app_text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Start)
              Text(this.getCurrentCharacterName())
                .fontSize($r('app.float.app_font_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ top: 2 })
            } else {
              Text($r('app.string.tab_characters_no_current'))
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Start)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(20)
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          top: $r('app.float.app_spacing_16'),
          bottom: $r('app.float.app_spacing_16')
        })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16')
    })
    .margin({ top: $r('app.float.app_spacing_12') })
  }

  /** 获取当前角色名称(用于显示) */
  private getCurrentCharacterName(): string {
    if (this.viewModel === null || this.viewModel!.currentCharacterId === null) {
      return '';
    }
    const currentId: string = this.viewModel!.currentCharacterId!;
    const found: Character | undefined =
      this.viewModel!.characters.find((c: Character) => c.id === currentId);
    return found !== undefined ? found.name : '';
  }

  /** 操作行:新建角色 + 导入角色卡 */
  @Builder
  actionRow() {
    Row({ space: 8 }) {
      Button($r('app.string.tab_characters_new'))
        .fontSize($r('app.float.app_font_caption'))
        .backgroundColor($r('app.color.app_accent'))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .layoutWeight(1)
        .onClick(() => {
          this.pathStack.pushPath({ name: 'CharacterListPage' });
        })

      Button($r('app.string.tab_characters_import'))
        .fontSize($r('app.float.app_font_caption'))
        .backgroundColor($r('app.color.app_surface_2'))
        .fontColor($r('app.color.app_text_primary'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 14, right: 14 })
        .layoutWeight(1)
        .onClick(() => {
          this.pathStack.pushPath({ name: 'CharacterListPage' });
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12')
    })
  }

  /** 角色列表区:加载/空/列表 */
  @Builder
  characterListArea() {
    if (this.viewModel === null) {
      EmptyStateView({
        title: $r('app.string.tab_characters_empty'),
        description: $r('app.string.tab_characters_empty_desc')
      })
    } else if (this.viewModel!.characters.length === 0) {
      EmptyStateView({
        title: $r('app.string.tab_characters_empty'),
        description: $r('app.string.tab_characters_empty_desc')
      })
    } else {
      Scroll() {
        Column() {
          ForEach(this.viewModel!.characters, (char: Character) => {
            this.characterCard(char)
          }, (char: Character) => char.id)
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

  /** 单个角色卡片 */
  @Builder
  characterCard(char: Character) {
    PressableCard({
      onPress: () => {
        this.pathStack.pushPath({ name: 'CharacterListPage' });
      }
    }) {
      Row() {
        Text(char.name.charAt(0))
          .fontSize(18)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius(20)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .margin({ right: 12 })

        Column() {
          Text(char.name)
            .fontSize($r('app.float.app_font_body'))
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
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.viewModel !== null && this.viewModel!.isCurrent(char)) {
          Text($r('app.string.character_current_badge'))
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
  }
}
