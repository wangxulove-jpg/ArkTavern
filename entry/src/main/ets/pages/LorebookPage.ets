/**
 * LorebookPage 世界书页面
 *
 * 支持世界书列表、新建/编辑/删除、设为当前、启用/禁用,
 * 以及条目的新建/编辑/删除。
 * 页面只通过 LorebookViewModel 操作,不直接调用 LorebookService。
 *
 * 要求:
 * - 页面只通过 ViewModel 访问业务能力
 * - 不直接调用 LorebookService/LorebookStore
 * - 所有 @Builder 方法不传参数,直接访问 this.viewModel
 * - 深色模式可读
 */

import { LorebookViewModel } from '../viewmodels/LorebookViewModel';
import { LorebookService } from '../services/LorebookService';
import { Lorebook, LorebookEntry } from '../models/Lorebook';
import { AppServices } from '../services/AppServices';
import { router } from '@kit.ArkUI';

/**
 * 颜色资源引用(全部通过 $r('app.color.worldbook_*') 主题资源访问,
 * 不在组件中散落十六进制颜色,确保浅色/深色模式自动切换)。
 *
 * 主题资源清单:
 * - worldbook_page_background:页面背景
 * - worldbook_card_background:世界书卡片背景
 * - worldbook_card_border:卡片边框
 * - worldbook_text_primary:主文字(标题/正文)
 * - worldbook_text_secondary:次级文字(摘要/数量)
 * - worldbook_text_muted:静音文字(禁用状态)
 * - worldbook_action_primary:主操作色(编辑/新建条目)
 * - worldbook_action_warning:警告色(Selective 标签)
 * - worldbook_action_danger:危险色(删除)
 * - worldbook_selected_background:选中态背景(设为当前)
 * - worldbook_entry_background:条目行背景
 * - worldbook_disabled_badge:禁用徽章颜色
 */

@Entry
@Component
struct LorebookPage {
  @State viewModel: LorebookViewModel | null = null;
  @State lorebooks: Lorebook[] = [];
  @State currentLorebookId: string | null = null;
  /** 本地 @State 镜像 ViewModel 的 UI 状态,确保属性变化触发重渲染 */
  @State showLorebookDialog: boolean = false;
  @State showEntryDialog: boolean = false;
  @State expandedLorebookId: string | null = null;
  @State deleteTargetLorebook: Lorebook | null = null;
  @State deleteTargetEntry: LorebookEntry | null = null;
  @State deleteTargetEntryLorebookId: string = '';
  @State vmErrorMessage: string = '';
  /** 本地 @State 镜像,用于条目编辑对话框表单字段 */
  @State editEntryName: string = '';
  @State editEntryKeys: string = '';
  @State editEntrySecondaryKeys: string = '';
  @State editEntryContent: string = '';
  @State editEntryConstant: boolean = false;
  @State editEntrySelective: boolean = false;
  @State editEntryEnabled: boolean = true;
  @State editEntryPosition: number = 0;
  @State editEntryPriority: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  aboutToAppear(): void {
    const service: LorebookService = AppServices.getLorebookService();
    const vm: LorebookViewModel = new LorebookViewModel(service);
    this.viewModel = vm;
    vm.onDataUpdate = () => {
      this.syncFromViewModel();
    };
    vm.load();
  }

  /** 将 ViewModel 的所有 UI 状态同步到本地 @State,确保属性变化触发重渲染 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.lorebooks = [...this.viewModel.lorebooks];
    this.currentLorebookId = this.viewModel.currentLorebookId;
    this.showLorebookDialog = this.viewModel.showLorebookDialog;
    this.showEntryDialog = this.viewModel.showEntryDialog;
    this.expandedLorebookId = this.viewModel.expandedLorebookId;
    this.deleteTargetLorebook = this.viewModel.deleteTargetLorebook;
    this.deleteTargetEntry = this.viewModel.deleteTargetEntry;
    this.deleteTargetEntryLorebookId = this.viewModel.deleteTargetEntryLorebookId;
    this.vmErrorMessage = this.viewModel.errorMessage;
    // 同步条目编辑表单字段
    this.editEntryName = this.viewModel.editEntryName;
    this.editEntryKeys = this.viewModel.editEntryKeys;
    this.editEntrySecondaryKeys = this.viewModel.editEntrySecondaryKeys;
    this.editEntryContent = this.viewModel.editEntryContent;
    this.editEntryConstant = this.viewModel.editEntryConstant;
    this.editEntrySelective = this.viewModel.editEntrySelective;
    this.editEntryEnabled = this.viewModel.editEntryEnabled;
    this.editEntryPosition = this.viewModel.editEntryPosition;
    this.editEntryPriority = this.viewModel.editEntryPriority;
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏:返回 + 标题
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('sys.color.ohos_id_color_text_primary')])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text($r('app.string.nav_lorebook_title'))
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 40 })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        // 错误提示
        if (this.vmErrorMessage.length > 0) {
          Text(this.vmErrorMessage)
            .fontSize(13)
            .fontColor($r('app.color.worldbook_action_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        }

        // 内容区
        if (this.lorebooks.length === 0) {
          this.emptyState();
        } else {
          Scroll() {
            Column() {
              ForEach(this.lorebooks, (lb: Lorebook) => {
                this.lorebookCard(lb);
              }, (lb: Lorebook) => lb.id + '_' + lb.updatedAt);
              Blank().height(80);
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')

      // FAB
      if (this.viewModel !== null) {
        Button($r('app.string.lorebook_new'))
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ x: '80%', y: '90%' })
          .onClick(() => {
            this.viewModel!.showNewLorebookDialog();
            this.syncFromViewModel();
          })
      }

      // 世界书编辑对话框
      if (this.showLorebookDialog) {
        this.lorebookDialog();
      }

      // 条目编辑对话框
      if (this.showEntryDialog) {
        this.entryDialog();
      }

      // 删除确认(世界书)
      if (this.deleteTargetLorebook !== null) {
        this.deleteLorebookConfirm();
      }

      // 删除确认(条目)
      if (this.deleteTargetEntry !== null) {
        this.deleteEntryConfirm();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.worldbook_page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== 空状态 =====

  @Builder
  emptyState() {
    Column() {
      Text($r('app.string.lorebook_no_lorebooks'))
        .fontSize(16)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ bottom: 8 })
      Text($r('app.string.lorebook_no_lorebooks_desc'))
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 世界书卡片 =====

  @Builder
  lorebookCard(lb: Lorebook) {
    Column() {
      // 主卡片
      Row() {
        Column() {
          Row() {
            if (this.currentLorebookId === lb.id) {
              Text($r('app.string.lorebook_current_badge'))
                .fontSize(11)
                .fontColor($r('app.color.app_on_accent'))
                .backgroundColor($r('app.color.worldbook_action_primary'))
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 6 })
            }
            if (!lb.enabled) {
              Text($r('app.string.lorebook_disabled'))
                .fontSize(11)
                .fontColor($r('app.color.worldbook_disabled_badge'))
                .border({ width: 1, color: $r('app.color.worldbook_disabled_badge'), style: BorderStyle.Solid })
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 6 })
            }
            Text(lb.name)
              .fontSize(15)
              .fontColor(lb.enabled
                ? $r('app.color.worldbook_text_primary')
                : $r('app.color.worldbook_text_muted'))
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          if (lb.description.length > 0) {
            Text(lb.description)
              .fontSize(12)
              .fontColor($r('app.color.worldbook_text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
              .width('100%')
          }

          Row() {
            Text(this.viewModel !== null
              ? this.viewModel.getEntryCountText(lb) : '')
              .fontSize(11)
              .fontColor($r('app.color.worldbook_text_secondary'))
              .margin({ top: 4 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 展开/折叠按钮
        Image($r('sys.media.ohos_ic_public_arrow_down'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.worldbook_text_secondary'))
          .margin({ left: 8 })
          .rotate({
            angle: this.expandedLorebookId === lb.id ? 180 : 0
          })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.toggleExpand(lb.id);
              this.syncFromViewModel();
            }
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 10 })
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.toggleExpand(lb.id);
          this.syncFromViewModel();
        }
      })

      // 操作按钮行
      Row() {
        Button($r('app.string.lorebook_set_current'))
          .fontSize(12)
          .backgroundColor(this.currentLorebookId === lb.id
            ? $r('app.color.worldbook_selected_background')
            : Color.Transparent)
          .fontColor(this.currentLorebookId === lb.id
            ? $r('app.color.worldbook_action_primary')
            : $r('app.color.worldbook_text_secondary'))
          .height(28)
          .padding({ left: 8, right: 8 })
          .borderRadius(6)
          .onClick(() => {
            if (this.viewModel !== null) {
              void this.viewModel.setCurrentLorebook(
                this.currentLorebookId === lb.id ? null : lb.id
              ).then(() => {
                this.syncFromViewModel();
              });
            }
          })

        Button($r('app.string.lorebook_edit'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.worldbook_action_primary'))
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showEditLorebookDialog(lb);
              this.syncFromViewModel();
            }
          })

        Button(lb.enabled
          ? $r('app.string.lorebook_disable')
          : $r('app.string.lorebook_enable'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(lb.enabled
            ? $r('app.color.worldbook_action_warning')
            : $r('app.color.worldbook_action_primary'))
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              void this.viewModel.toggleLorebookEnabled(lb).then(() => {
                this.syncFromViewModel();
              });
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.worldbook_action_danger'))
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetLorebook = lb;
              this.syncFromViewModel();
            }
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 8 })
      .justifyContent(FlexAlign.SpaceEvenly)

      // 条目列表(展开时显示)
      if (this.expandedLorebookId === lb.id) {
        Divider()
          .color($r('app.color.worldbook_card_border'))
          .width('100%')
          .height(1)

        if (lb.entries.length === 0) {
          Text($r('app.string.lorebook_no_entries'))
            .fontSize(13)
            .fontColor($r('app.color.worldbook_text_secondary'))
            .padding(16)
            .width('100%')
            .textAlign(TextAlign.Center)
        } else {
          ForEach(lb.entries, (entry: LorebookEntry) => {
            this.entryRow(lb.id, entry);
          }, (entry: LorebookEntry) => entry.id + '_' + entry.updatedAt);
        }

        Button($r('app.string.lorebook_new_entry'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.worldbook_action_primary'))
          .height(32)
          .width('100%')
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showNewEntryDialog(lb.id);
              this.syncFromViewModel();
            }
          })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.worldbook_card_background'))
    .border({ width: 1, color: $r('app.color.worldbook_card_border') })
    .borderRadius(10)
    .margin({ left: 12, right: 12, top: 8 })
  }

  // ===== 条目行 =====

  @Builder
  entryRow(lorebookId: string, entry: LorebookEntry) {
    Column() {
      Row() {
        Column() {
          Row() {
            if (!entry.enabled) {
              Text($r('app.string.lorebook_disabled'))
                .fontSize(10)
                .fontColor($r('app.color.worldbook_disabled_badge'))
                .border({ width: 1, color: $r('app.color.worldbook_disabled_badge'), style: BorderStyle.Solid })
                .borderRadius(6)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ right: 4 })
            }
            Text(entry.name)
              .fontSize(13)
              .fontColor(entry.enabled
                ? $r('app.color.worldbook_text_primary')
                : $r('app.color.worldbook_text_muted'))
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          Row() {
            if (entry.constant) {
              Text('恒定')
                .fontSize(10)
                .fontColor($r('app.color.worldbook_action_primary'))
                .margin({ right: 4 })
            }
            if (entry.selective) {
              Text('Selective')
                .fontSize(10)
                .fontColor($r('app.color.worldbook_action_warning'))
                .margin({ right: 4 })
            }
            if (entry.keys.length > 0) {
              Text(entry.keys.join(', '))
                .fontSize(10)
                .fontColor($r('app.color.worldbook_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ right: 4 })
            }
            if (this.viewModel !== null) {
              Text('P' + entry.priority.toString())
                .fontSize(10)
                .fontColor($r('app.color.worldbook_text_secondary'))
                .margin({ right: 4 })
              Text(this.viewModel.getPositionText(entry.position))
                .fontSize(10)
                .fontColor($r('app.color.worldbook_text_secondary'))
            }
          }
          .width('100%')
          .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button($r('app.string.lorebook_edit'))
          .fontSize(11)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.worldbook_action_primary'))
          .height(24)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showEditEntryDialog(lorebookId, entry);
              this.syncFromViewModel();
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(11)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.worldbook_action_danger'))
          .height(24)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetEntry = entry;
              this.viewModel.deleteTargetEntryLorebookId = lorebookId;
              this.syncFromViewModel();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    }
    .width('100%')
    .backgroundColor($r('app.color.worldbook_entry_background'))
    .border({ width: 1, color: $r('app.color.worldbook_card_border') })
    .margin({ left: 12, right: 12, bottom: 6 })
    .borderRadius(8)
  }

  // ===== 世界书编辑对话框 =====

  @Builder
  lorebookDialog() {
    Stack() {
      Column() {
        // 遮罩
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.closeLorebookDialog();
        }
      })

      Column() {
        Text(this.viewModel !== null && this.viewModel.editingLorebook !== null
          ? $r('app.string.lorebook_form_title_edit')
          : $r('app.string.lorebook_form_title_new'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        Text($r('app.string.lorebook_form_name'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })

        TextInput({
          placeholder: $r('app.string.lorebook_form_name_placeholder'),
          text: this.viewModel !== null ? this.viewModel.editLorebookName : ''
        })
          .fontSize(14)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange((value: string) => {
            if (this.viewModel !== null) {
              this.viewModel.editLorebookName = value;
            }
          })

        Text($r('app.string.lorebook_form_description'))
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .margin({ bottom: 4 })

        TextInput({
          placeholder: $r('app.string.lorebook_form_description_placeholder'),
          text: this.viewModel !== null ? this.viewModel.editLorebookDescription : ''
        })
          .fontSize(14)
          .width('100%')
          .margin({ bottom: 16 })
          .onChange((value: string) => {
            if (this.viewModel !== null) {
              this.viewModel.editLorebookDescription = value;
            }
          })

        Row() {
          Button($r('app.string.lorebook_form_cancel'))
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.closeLorebookDialog();
                this.syncFromViewModel();
              }
            })

          Button($r('app.string.lorebook_form_save'))
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                void this.viewModel.saveLorebook().then(() => {
                  this.syncFromViewModel();
                });
              }
            })
        }
        .width('100%')
      }
      .width('85%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))
      .borderRadius(12)
      .padding(20)
      .position({ x: '7.5%', y: '25%' })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 条目编辑对话框 =====

  @Builder
  entryDialog() {
    Stack() {
      Column() {
        // 遮罩
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.closeEntryDialog();
        }
      })

      Scroll() {
      Column() {
        Text(this.viewModel !== null && this.viewModel.editingEntry !== null
          ? $r('app.string.lorebook_entry_form_title_edit')
          : $r('app.string.lorebook_entry_form_title_new'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        this.entryFormField(
          $r('app.string.lorebook_entry_name'),
          $r('app.string.lorebook_entry_name_placeholder'),
          this.editEntryName,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryName = value;
            }
            this.editEntryName = value;
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_keys'),
          $r('app.string.lorebook_entry_keys_placeholder'),
          this.editEntryKeys,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryKeys = value;
            }
            this.editEntryKeys = value;
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_secondary_keys'),
          $r('app.string.lorebook_entry_secondary_keys_placeholder'),
          this.editEntrySecondaryKeys,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntrySecondaryKeys = value;
            }
            this.editEntrySecondaryKeys = value;
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_content'),
          $r('app.string.lorebook_entry_content_placeholder'),
          this.editEntryContent,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryContent = value;
            }
            this.editEntryContent = value;
          },
          true
        )

        // 开关行
        Row() {
          Text($r('app.string.lorebook_entry_enabled'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editEntryEnabled })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntryEnabled = isOn;
              }
              this.editEntryEnabled = isOn;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Text($r('app.string.lorebook_entry_constant'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editEntryConstant })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntryConstant = isOn;
              }
              this.editEntryConstant = isOn;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Text($r('app.string.lorebook_entry_selective'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editEntrySelective })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntrySelective = isOn;
              }
              this.editEntrySelective = isOn;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 优先级
        Row() {
          Text($r('app.string.lorebook_entry_priority'))
            .fontSize(13)
            .width(60)
          TextInput({
            text: this.editEntryPriority.toString()
          })
            .fontSize(14)
            .type(InputType.Number)
            .layoutWeight(1)
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                const parsed: number = parseInt(value);
                this.viewModel.editEntryPriority = isNaN(parsed) ? 0 : parsed;
              }
              const parsed: number = parseInt(value);
              this.editEntryPriority = isNaN(parsed) ? 0 : parsed;
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 位置选择
        Row() {
          Text($r('app.string.lorebook_entry_position'))
            .fontSize(13)
            .width(60)
          Row() {
            Button($r('app.string.lorebook_entry_position_before'))
              .fontSize(12)
              .backgroundColor(this.editEntryPosition === 0
                ? $r('sys.color.ohos_id_color_emphasize')
                : $r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(16)
              .height(32)
              .padding({ left: 12, right: 12 })
              .margin({ right: 8 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel.editEntryPosition = 0;
                }
                this.editEntryPosition = 0;
              })

            Button($r('app.string.lorebook_entry_position_after'))
              .fontSize(12)
              .backgroundColor(this.editEntryPosition === 1
                ? $r('sys.color.ohos_id_color_emphasize')
                : $r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(16)
              .height(32)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel.editEntryPosition = 1;
                }
                this.editEntryPosition = 1;
              })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: 16 })

        Row() {
          Button($r('app.string.lorebook_form_cancel'))
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.closeEntryDialog();
                this.syncFromViewModel();
              }
            })

          Button($r('app.string.lorebook_form_save'))
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                void this.viewModel.saveEntry().then(() => {
                  this.syncFromViewModel();
                });
              }
            })
        }
        .width('100%')
      }
      .width('100%')
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .width('85%')
    .height('70%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .borderRadius(12)
    .padding(20)
    .position({ x: '7.5%', y: '15%' })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  entryFormField(
    label: ResourceStr,
    placeholder: ResourceStr,
    text: string,
    onChange: (value: string) => void,
    multiLine: boolean = false
  ) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ bottom: 4 })

      if (multiLine) {
        TextArea({
          placeholder: placeholder,
          text: text
        })
          .fontSize(14)
          .barState(BarState.Auto)
          .constraintSize({ minHeight: 80, maxHeight: 400 })
          .width('100%')
          .margin({ bottom: 12 })
          .onChange(onChange)
      } else {
        TextInput({
          placeholder: placeholder,
          text: text
        })
          .fontSize(14)
          .barState(BarState.Auto)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange(onChange)
      }
    }
    .width('100%')
  }

  // ===== 删除确认(世界书) =====

  @Builder
  deleteLorebookConfirm() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.deleteTargetLorebook = null;
          this.syncFromViewModel();
        }
      })

      Column() {
      Text('删除世界书')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })

      Text(this.deleteTargetLorebook !== null
        ? '确定删除世界书"' + this.deleteTargetLorebook.name + '"吗?所有条目也将一并删除。'
        : '')
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)

      Row() {
        Button($r('app.string.lorebook_form_cancel'))
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetLorebook = null;
              this.syncFromViewModel();
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(14)
          .backgroundColor($r('app.color.worldbook_action_danger'))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            if (this.viewModel !== null && this.deleteTargetLorebook !== null) {
              void this.viewModel.deleteLorebook(this.deleteTargetLorebook.id).then(() => {
                this.syncFromViewModel();
              });
            }
          })
      }
      .width('100%')
    }
    .width('80%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .borderRadius(12)
    .padding(20)
    }
    .width('100%')
    .height('100%')
  }

  // ===== 删除确认(条目) =====

  @Builder
  deleteEntryConfirm() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.deleteTargetEntry = null;
          this.syncFromViewModel();
        }
      })

      Column() {
      Text('删除条目')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })

      Text(this.deleteTargetEntry !== null
        ? '确定删除条目"' + this.deleteTargetEntry.name + '"吗?'
        : '')
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)

      Row() {
        Button($r('app.string.lorebook_form_cancel'))
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetEntry = null;
              this.syncFromViewModel();
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(14)
          .backgroundColor($r('app.color.worldbook_action_danger'))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            if (this.viewModel !== null && this.deleteTargetEntry !== null) {
              void this.viewModel.deleteEntry(
                this.deleteTargetEntryLorebookId,
                this.deleteTargetEntry.id
              ).then(() => {
                this.syncFromViewModel();
              });
            }
          })
      }
      .width('100%')
    }
    .width('80%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .borderRadius(12)
    .padding(20)
    }
    .width('100%')
    .height('100%')
  }
}