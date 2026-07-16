/**
 * CharacterListPage 角色列表页面
 *
 * 展示角色列表,支持新建/编辑/删除/设为当前角色。
 * 仅通过 CharacterListViewModel 访问业务能力。
 *
 * 要求:
 * - 角色列表(含当前角色标记)
 * - 新建角色
 * - 编辑角色
 * - 删除角色二次确认
 * - 设为当前角色
 * - 无角色空状态
 * - 本次不做头像上传
 */

import { CharacterListViewModel } from '../viewmodels/CharacterListViewModel';
import { Character } from '../models/Character';
import { AppServices } from '../services/AppServices';

@Entry
@Component
export struct CharacterListPage {
  @State viewModel: CharacterListViewModel | null = null;
  /** 表单字段(使用 @State + $$ 双向绑定,兼容 MCP inputText) */
  @State formName: string = '';
  @State formDescription: string = '';
  @State formPersonality: string = '';
  @State formScenario: string = '';
  @State formFirstMessage: string = '';
  @State formSystemPrompt: string = '';

  aboutToAppear(): void {
    const charService = AppServices.getCharacterService();
    const vm: CharacterListViewModel = new CharacterListViewModel(charService);
    this.viewModel = vm;
    vm.load();
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          // 角色列表
          Scroll() {
            Column() {
              if (this.viewModel!.characters.length === 0) {
                this.emptyState();
              } else {
                ForEach(this.viewModel!.characters, (char: Character) => {
                  this.characterCard(char);
                }, (char: Character) => char.id);
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')

        // 新建按钮(FAB)
        Button($r('app.string.character_new'))
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor(Color.White)
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ right: 16, bottom: 16 })
          .onClick(() => {
            this.viewModel!.showNewDialog();
            this.syncFormFromViewModel();
          })

        // 删除确认对话框
        if (this.viewModel!.deleteTarget !== null) {
          this.deleteConfirmDialog();
        }

        // 编辑对话框
        if (this.viewModel!.showEditDialog) {
          this.editDialogOverlay();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
    }
    .title($r('app.string.nav_character_list_title'))
    .hideTitleBar(false)
  }

  // ===== 空状态 =====

  @Builder
  emptyState() {
    Column() {
      Text($r('app.string.character_no_characters'))
        .fontSize(16)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ bottom: 8 })

      Text($r('app.string.character_no_characters_desc'))
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
    .width('100%')
    .height(200)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 角色卡片 =====

  @Builder
  characterCard(char: Character) {
    Column() {
      // 顶部:名称 + 当前标记
      Row() {
        // 文字头像(取名称首字)
        Text(char.name.charAt(0))
          .fontSize(18)
          .fontColor(Color.White)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .borderRadius(20)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .margin({ right: 12 })

        Column() {
          Text(char.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (char.description.length > 0) {
            Text(char.description)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.viewModel!.isCurrent(char)) {
          Text($r('app.string.character_current_badge'))
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
            .border({ width: 1, color: $r('sys.color.ohos_id_color_emphasize') })
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 操作按钮行
      Row() {
        if (!this.viewModel!.isCurrent(char)) {
          Button($r('app.string.character_set_current'))
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
            .height(32)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.viewModel!.setCurrent(char.id);
            })
        }

        Button($r('app.string.character_edit'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .height(32)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.viewModel!.showEditDialogFor(char);
            this.syncFormFromViewModel();
          })

        Button($r('app.string.character_delete'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor('#E74C3C')
          .height(32)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.viewModel!.deleteTarget = char;
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(12)
    .margin({ bottom: 8 })
    .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  // ===== 编辑对话框(新建/编辑共用) =====

  @Builder
  editDialog() {
    Column() {
      // 标题
      Text(this.viewModel!.editingCharacter === null
        ? $r('app.string.character_form_title_new')
        : $r('app.string.character_form_title_edit'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 16 })

      // 名称
      Column() {
        Text($r('app.string.character_form_name'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })
        TextInput({ placeholder: $r('app.string.character_form_name_placeholder'), text: $$this.formName })
          .fontSize(14)
          .width('100%')
          .height(40)
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 描述
      Column() {
        Text($r('app.string.character_form_description'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_description_placeholder'), text: $$this.formDescription })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 性格
      Column() {
        Text($r('app.string.character_form_personality'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_personality_placeholder'), text: $$this.formPersonality })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 场景
      Column() {
        Text($r('app.string.character_form_scenario'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_scenario_placeholder'), text: $$this.formScenario })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 开场白
      Column() {
        Text($r('app.string.character_form_first_message'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_first_message_placeholder'), text: $$this.formFirstMessage })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // System Prompt
      Column() {
        Text($r('app.string.character_form_system_prompt'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_system_prompt_placeholder'), text: $$this.formSystemPrompt })
          .fontSize(14)
          .maxLines(4)
          .width('100%')
          .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 错误提示
      if (this.viewModel!.errorMessage.length > 0) {
        Text(this.viewModel!.errorMessage)
          .fontSize(13)
          .fontColor('#E74C3C')
          .width('100%')
          .margin({ top: 8, bottom: 8 })
      }

      // 按钮行
      Row() {
        Button($r('app.string.character_form_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .height(40)
          .layoutWeight(1)
          .onClick(() => {
            this.viewModel!.closeEditDialog();
          })

        Button($r('app.string.character_form_save'))
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor(Color.White)
          .borderRadius(20)
          .height(40)
          .layoutWeight(1)
          .margin({ left: 12 })
          .onClick(() => {
            this.saveFormToViewModel();
            this.viewModel!.saveEdit();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  /** 将 @State 表单字段同步到 ViewModel */
  private saveFormToViewModel(): void {
    this.viewModel!.editName = this.formName;
    this.viewModel!.editDescription = this.formDescription;
    this.viewModel!.editPersonality = this.formPersonality;
    this.viewModel!.editScenario = this.formScenario;
    this.viewModel!.editFirstMessage = this.formFirstMessage;
    this.viewModel!.editSystemPrompt = this.formSystemPrompt;
  }

  /** 从 ViewModel 同步表单字段到 @State */
  private syncFormFromViewModel(): void {
    this.formName = this.viewModel!.editName;
    this.formDescription = this.viewModel!.editDescription;
    this.formPersonality = this.viewModel!.editPersonality;
    this.formScenario = this.viewModel!.editScenario;
    this.formFirstMessage = this.viewModel!.editFirstMessage;
    this.formSystemPrompt = this.viewModel!.editSystemPrompt;
  }

  // ===== 删除确认对话框 =====

  @Builder
  deleteConfirmDialog() {
    Column() {
      Column() {
        Text('确认删除')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .margin({ bottom: 12 })

        Text('确定删除角色"' + this.viewModel!.deleteTarget!.name + '"吗?此操作不可撤销。')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ bottom: 20 })

        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              this.viewModel!.deleteTarget = null;
            })

          Button('删除')
            .fontSize(14)
            .backgroundColor('#E74C3C')
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .onClick(() => {
              const id: string = this.viewModel!.deleteTarget!.id;
              this.viewModel!.deleteTarget = null;
              this.viewModel!.deleteCharacter(id);
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      // 点击蒙层关闭
      this.viewModel!.deleteTarget = null;
    })
  }

  // ===== 编辑对话框(半屏覆盖) =====

  @Builder
  editDialogOverlay() {
    Column() {
      // 蒙层上半部分
      Blank()
        .backgroundColor('rgba(0,0,0,0.3)')
        .onClick(() => {
          this.viewModel!.closeEditDialog();
        })

      // 编辑表单
      this.editDialog();
    }
    .width('100%')
    .height('100%')
  }
}