/**
 * CharacterRootView 角色卡 Tab 根视图(UI-3B)
 *
 * 重新设计后的角色卡首页:
 * - 顶部标题栏:标题"角色卡" + 右上角"导入"按钮(导航到 CharacterListPage 用导入流程)
 * - 所有角色以展开式卡片展示
 * - 每张角色卡显示图片、名称、简介
 * - 角色卡支持左滑显示三个操作:新建对话 / 编辑 / 删除
 * - 同一时间只展开一张角色卡(由 List swipeAction 默认行为保证)
 * - 点击角色卡或角色图片 -> 直接进入全屏 CharacterEditPage(UI-3B-2)
 * - 左滑"新建对话" -> 通过 pendingCharacterId 让 ChatPage 用该角色创建新会话
 * - 左滑"编辑" -> 直接进入全屏 CharacterEditPage
 * - 左滑"删除" -> 弹出二次确认(含角色名)
 * - 底部保留现有 HdsTabs 沉浸光感导航栏
 *
 * 复用:
 * - CharacterListViewModel 仅用于加载列表和删除角色
 * - 新建/编辑角色流程已迁移到 CharacterEditPage(不再走底部弹窗)
 */

import { CharacterListViewModel } from '../../viewmodels/CharacterListViewModel';
import { CharacterExportViewModel, CharacterExportFormat, CharacterExportResult } from '../../viewmodels/CharacterExportViewModel';
import { Character } from '../../models/Character';
import { AppServices } from '../../services/AppServices';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';
import { CharacterImageView } from '../../components/CharacterImageView';
import { router, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { ThemePalette } from '../../theme/ThemePalette';

/** 角色编辑页路由参数,携带 characterId */
interface CharacterEditNavParam {
  characterId: string;
}

/** 左滑矩阵单元格参数 */
interface SwipeGridCellParams {
  icon: Resource;
  label: Resource;
  bgColor: ResourceColor;
  fgColor: ResourceColor;
  disabled: boolean;
  action: () => void;
}

@Component
export struct CharacterRootView {
  @State viewModel: CharacterListViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';
  /** 删除二次确认的目标角色(null 时确认弹窗不显示) */
  @State deleteTarget: Character | null = null;
  /** 导出格式选择弹窗的目标角色(null 时不显示弹窗) */
  @State exportTarget: Character | null = null;
  /** 导出进行中(禁用按钮防止重复点击) */
  @State isExporting: boolean = false;
  /** 当前展开左滑菜单的角色 ID(null 表示全部收起) */
  @State expandedCharId: string | null = null;
  /** List 滚动控制器,用于点击操作后收起 swipeAction */
  private listScroller: ListScroller = new ListScroller();
  /**
   * 跨页面列表刷新信号。
   * 由 CharacterEditPage / CharacterListPage 在角色数据变化后递增,
   * 触发本组件 onListVersionChange 回调重新 load。
   *
   * 说明:本组件作为 HdsTabs 的 TabContent 嵌入,非 @Entry 也非 NavDestination,
   * 因此 onPageShow 不会被调用;改用 AppStorage 计数器 + @Watch 监听二级页面变化。
   */
  @StorageProp('characterListVersion') @Watch('onListVersionChange') characterListVersion: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

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

  /** characterListVersion 变化时刷新列表(从编辑页/导入页返回后自动刷新) */
  private onListVersionChange(): void {
    if (this.isInitializing) {
      return;
    }
    if (this.viewModel === null || !AppServices.isStarted()) {
      return;
    }
    this.viewModel!.load().catch((): void => {});
  }

  // ===== 跳转 / 操作 =====

  /** 点击角色卡:直接进入全屏 CharacterEditPage 编辑该角色 */
  private openCharacterDetail(characterId: string): void {
    const navParam: CharacterEditNavParam = { characterId: characterId };
    router.pushUrl({
      url: 'pages/CharacterEditPage',
      params: { param: navParam }
    });
  }

  /** 左滑"新建对话":用该角色创建新会话并跳转 ChatPage(不修改全局当前角色) */
  private startNewChatWithCharacter(characterId: string): void {
    AppStorage.setOrCreate<string>('pendingCharacterId', characterId);
    // 清除 pendingChatId 防止冲突(优先级:pendingChatId > pendingCharacterId)
    AppStorage.setOrCreate<string>('pendingChatId', '');
    router.pushUrl({ url: 'pages/ChatPage' });
  }

  /** 左滑"编辑":与点击角色卡相同,直接进入全屏编辑页 */
  private editCharacter(characterId: string): void {
    this.openCharacterDetail(characterId);
  }

  /** 左滑"删除":弹出二次确认 */
  private promptDelete(char: Character): void {
    this.deleteTarget = char;
  }

  /** 确认删除:复用 CharacterListViewModel.deleteCharacter */
  private async confirmDelete(): Promise<void> {
    if (this.viewModel === null || this.deleteTarget === null) {
      this.deleteTarget = null;
      return;
    }
    const id: string = this.deleteTarget.id;
    this.deleteTarget = null;
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

  // ===== 导出 =====

  /** 左滑"导出":弹出格式选择 */
  private promptExport(char: Character): void {
    if (this.isExporting) {
      return;
    }
    this.exportTarget = char;
  }

  /** 取消导出选择 */
  private cancelExport(): void {
    if (this.isExporting) {
      return;
    }
    this.exportTarget = null;
  }

  /** 选择 PNG 导出 */
  private async chooseExportPng(): Promise<void> {
    if (this.exportTarget === null || this.isExporting) {
      return;
    }
    const char: Character = this.exportTarget;
    this.exportTarget = null;
    await this.runExport(char, CharacterExportFormat.V2Png);
  }

  /** 选择 JSON 导出 */
  private async chooseExportJson(): Promise<void> {
    if (this.exportTarget === null || this.isExporting) {
      return;
    }
    const char: Character = this.exportTarget;
    this.exportTarget = null;
    await this.runExport(char, CharacterExportFormat.V2Json);
  }

  /**
   * 执行导出:调用 ViewModel 生成数据 + 系统文件保存器选择位置 + 写入文件。
   * 用户取消 picker 时不报错。
   */
  private async runExport(char: Character, format: CharacterExportFormat): Promise<void> {
    if (this.isExporting) {
      return;
    }
    this.isExporting = true;
    try {
      const exportVm: CharacterExportViewModel = new CharacterExportViewModel(
        AppServices.getCharacterService()
      );
      const result: CharacterExportResult =
        format === CharacterExportFormat.V2Png
          ? await exportVm.exportToPng(char.id, char.name)
          : await exportVm.exportToJson(char.id, char.name);
      if (!result.success) {
        promptAction.showToast({
          message: $r('app.string.character_export_failed'),
          duration: 2000
        });
        return;
      }
      // 调用系统文件保存器
      let uri: string = '';
      try {
        const documentPicker = new picker.DocumentViewPicker();
        const options = new picker.DocumentSaveOptions();
        options.newFileNames = [result.defaultFileName];
        const uris: string[] = await documentPicker.save(options);
        if (uris.length === 0) {
          // 用户取消,不报错
          return;
        }
        uri = uris[0];
      } catch (e) {
        promptAction.showToast({
          message: $r('app.string.character_export_failed'),
          duration: 2000
        });
        return;
      }
      // 写入文件
      try {
        if (format === CharacterExportFormat.V2Json) {
          await this.writeJsonToFile(uri, result.jsonString);
        } else {
          await this.writePngBytesToFile(uri, result.pngBytes);
        }
        promptAction.showToast({
          message: $r('app.string.character_export_success'),
          duration: 1500
        });
      } catch (e) {
        promptAction.showToast({
          message: $r('app.string.character_export_failed'),
          duration: 2000
        });
      }
    } finally {
      this.isExporting = false;
    }
  }

  /** 写入 JSON 文本到文件(复用 CharacterService.writeFileContent 的 UTF-8 编码能力) */
  private async writeJsonToFile(uri: string, jsonString: string): Promise<void> {
    await AppServices.getCharacterService().writeFileContent(uri, jsonString);
  }

  /** 写入 PNG 字节到文件 */
  private async writePngBytesToFile(uri: string, bytes: Uint8Array): Promise<void> {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  build() {
    Stack() {
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
      }
      .width('100%')
      .height('100%')
      // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // ===== 删除二次确认弹窗(浮层,Stack alignContent 居中)=====
      if (this.deleteTarget !== null) {
        this.deleteConfirmDialog()
      }

      // ===== 导出格式选择弹窗(浮层,Stack alignContent 居中)=====
      if (this.exportTarget !== null) {
        this.exportFormatDialog()
      }
    }
    .width('100%')
    .height('100%')
    // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  // ===== 标题栏 =====

  @Builder
  headerBar() {
    Row() {
      Text($r('app.string.tab_characters'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()

      Button($r('app.string.character_import'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .height(48)
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          // 导航到 AddCharacterPage(新建角色 / 文件导入二选一)
          router.pushUrl({ url: 'pages/AddCharacterPage' });
        })
    }
    .width('100%')
    // 顶部 padding = 状态栏高度 + 间距 8(避开状态栏,与其他 Tab 统一起点)
    // 不设 height,让 padding + 内容自适应撑开
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
    // 背景层分离:顶栏不设 backgroundColor,透出 Index 根背景,避免色块拼接感。
  }

  // ===== 角色列表(支持左滑) =====

  @Builder
  characterList() {
    List({ scroller: this.listScroller }) {
      ForEach(this.viewModel!.characters, (char: Character, index: number) => {
        ListItem() {
          this.characterCard(char)
        }
        .margin({ bottom: $r('app.float.app_spacing_12') })
        .swipeAction({
          end: {
            builder: (): void => {
              this.swipeActionGrid(char, index)
            },
            onStateChange: (state: SwipeActionState): void => {
              if (state === SwipeActionState.EXPANDED) {
                this.expandedCharId = char.id;
              } else if (state === SwipeActionState.COLLAPSED && this.expandedCharId === char.id) {
                this.expandedCharId = null;
              }
            }
          }
        })
      }, (char: Character) => char.id)

      // 末尾空白 ListItem:让内容总高度始终超出视口,确保即使内容少也能上下滚动(spring 回弹)。
      // 高度覆盖 HdsTabs 浮层(barBottomMargin 24 + maskHeight 64 + tabBar ≈ 56 ≈ 144vp),
      // 让最后一项内容下方有足够空白,可滚动到 tab bar 上方查看。
      ListItem() {
        Column().width('100%').height(160)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // padding 0:padding 直接在 List 上会缩小视口,padding 区域不显示内容。
    // 左右 padding 通过每个 ListItem 内部布局控制。
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 0,
      bottom: 0
    })
  }

  // ===== 左滑操作区(2 行 × 3 列矩阵,位于当前角色卡右侧) =====

  /**
   * 左滑矩阵操作区。
   * 第一行:上移 / 新建对话 / 编辑
   * 第二行:下移 / 导出 / 删除
   *
   * @param char 当前角色
   * @param index 当前角色在列表中的位置(用于禁用上移/下移)
   */
  @Builder
  swipeActionGrid(char: Character, index: number) {
    Row() {
      Column() {
        // 第一行:上移 / 新建对话 / 编辑
        Row() {
          this.gridCell({
            icon: $r('sys.symbol.arrow_up'),
            label: $r('app.string.card_action_move_up'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: index === 0,
            action: (): void => { this.viewModel!.moveUp(char.id); }
          })
          this.gridCell({
            icon: $r('sys.symbol.plus'),
            label: $r('app.string.character_action_new_chat'),
            bgColor: ThemePalette.accentColor(this.effectiveTheme),
            fgColor: $r('app.color.app_on_accent'),
            disabled: false,
            action: (): void => { this.startNewChatWithCharacter(char.id); }
          })
          this.gridCell({
            icon: $r('sys.symbol.square_and_pencil'),
            label: $r('app.string.character_action_edit'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: false,
            action: (): void => { this.editCharacter(char.id); }
          })
        }
        .layoutWeight(1)
        .width('100%')

        // 第二行:下移 / 导出 / 删除
        Row() {
          this.gridCell({
            icon: $r('sys.symbol.arrow_down'),
            label: $r('app.string.card_action_move_down'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: index === this.viewModel!.characters.length - 1,
            action: (): void => { this.viewModel!.moveDown(char.id); }
          })
          this.gridCell({
            icon: $r('sys.symbol.share'),
            label: $r('app.string.character_action_export'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: false,
            action: (): void => { this.promptExport(char); }
          })
          this.gridCell({
            icon: $r('sys.symbol.trash'),
            label: $r('app.string.character_action_delete'),
            bgColor: $r('app.color.app_danger'),
            fgColor: $r('app.color.app_on_accent'),
            disabled: false,
            action: (): void => { this.promptDelete(char); }
          })
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width(220)
      .height('100%')
      .padding(2)
    }
    .height('100%')
  }

  /**
   * 单个矩阵单元格(图标在上、文字在下,圆角矩形,非胶囊)。
   * 点击后自动收起 swipeAction。
   */
  @Builder
  gridCell(params: SwipeGridCellParams) {
    Button() {
      Column() {
        SymbolGlyph(params.icon)
          .fontSize(18)
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
    .type(ButtonType.Normal)
    .backgroundColor(params.bgColor)
    .borderRadius(10)
    .height('100%')
    .layoutWeight(1)
    .margin({ left: 2, right: 2, top: 2, bottom: 2 })
    .padding(0)
    .enabled(!params.disabled)
    .opacity(params.disabled ? 0.35 : 1.0)
    .onClick(() => {
      params.action();
      this.listScroller.closeAllSwipeActions();
    })
  }

  // ===== 展开式角色卡 =====

  @Builder
  characterCard(char: Character) {
    PressableCard({
      onPress: () => {
        // 点击角色卡 -> 跳转到该角色详情(编辑弹窗)
        this.openCharacterDetail(char.id);
      },
      surfaceColor: ThemePalette.surface1Color(this.effectiveTheme)
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
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          if (char.description.length > 0) {
            Text(char.description)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          if (char.personality.length > 0) {
            Text(char.personality)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
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
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
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

        // 统一入口:进入"添加角色"页面(新建角色 / 文件导入二选一)
        Button($r('app.string.character_import'))
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(48)
          .width('60%')
          .margin({ top: $r('app.float.app_spacing_24') })
          .onClick(() => {
            router.pushUrl({ url: 'pages/AddCharacterPage' });
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
        .color(ThemePalette.accentColor(this.effectiveTheme))
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
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          // 提示内容(含角色名)
          Text(this.formatDeleteMessage(this.deleteTarget!.name))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })

          // 按钮行
          Row() {
            Button($r('app.string.character_delete_confirm_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
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
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
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

  // ===== 导出格式选择弹窗 =====

  @Builder
  exportFormatDialog() {
    Stack() {
      Column() {
        Column() {
          // 标题
          Text($r('app.string.character_export_choose_format'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 16 })

          // PNG 选项
          Button($r('app.string.character_export_png'))
            .fontSize(15)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .margin({ bottom: 8 })
            .onClick(() => {
              this.chooseExportPng();
            })

          // JSON 选项
          Button($r('app.string.character_export_json'))
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .margin({ bottom: 8 })
            .onClick(() => {
              this.chooseExportJson();
            })

          // 取消
          Button($r('app.string.character_export_cancel'))
            .fontSize(15)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_md'))
            .width('100%')
            .height(44)
            .onClick(() => {
              this.cancelExport();
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
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
      this.cancelExport();
    })
  }
}
