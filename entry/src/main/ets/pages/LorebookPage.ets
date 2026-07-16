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

const COLOR_CURRENT: string = '#5B7CFA';
const COLOR_DISABLED: string = '#999999';
const COLOR_DIVIDER: string = '#E0E0E0';
const COLOR_ERROR: string = '#E74C3C';
const COLOR_ENTRY_BG: string = '#F5F5F5';

@Entry
@Component
export struct LorebookPage {
  @State viewModel: LorebookViewModel | null = null;
  pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    const service: LorebookService = AppServices.getLorebookService();
    const vm: LorebookViewModel = new LorebookViewModel(service);
    this.viewModel = vm;
    vm.load();
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          // 错误提示
          if (this.viewModel !== null && this.viewModel.errorMessage.length > 0) {
            Text(this.viewModel.errorMessage)
              .fontSize(13)
              .fontColor(COLOR_ERROR)
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 4 })
          }

          // 内容区
          if (this.viewModel !== null && this.viewModel.lorebooks.length === 0) {
            this.emptyState();
          } else {
            Scroll() {
              Column() {
                if (this.viewModel !== null) {
                  ForEach(this.viewModel.lorebooks, (lb: Lorebook) => {
                    this.lorebookCard(lb);
                  }, (lb: Lorebook) => lb.id + '_' + lb.updatedAt);
                }
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
            })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_sub_background'))

      // 世界书编辑对话框
      if (this.viewModel !== null && this.viewModel.showLorebookDialog) {
        this.lorebookDialog();
      }

      // 条目编辑对话框
      if (this.viewModel !== null && this.viewModel.showEntryDialog) {
        this.entryDialog();
      }

      // 删除确认(世界书)
      if (this.viewModel !== null && this.viewModel.deleteTargetLorebook !== null) {
        this.deleteLorebookConfirm();
      }

      // 删除确认(条目)
      if (this.viewModel !== null && this.viewModel.deleteTargetEntry !== null) {
        this.deleteEntryConfirm();
      }
    }
    .title($r('app.string.nav_lorebook_title'))
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
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
            if (this.viewModel !== null && this.viewModel.isCurrent(lb)) {
              Text($r('app.string.lorebook_current_badge'))
                .fontSize(11)
                .fontColor(Color.White)
                .backgroundColor(COLOR_CURRENT)
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 6 })
            }
            if (!lb.enabled) {
              Text($r('app.string.lorebook_disabled'))
                .fontSize(11)
                .fontColor(COLOR_DISABLED)
                .border({ width: 1, color: COLOR_DISABLED, style: BorderStyle.Solid })
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 6 })
            }
            Text(lb.name)
              .fontSize(15)
              .fontColor(lb.enabled
                ? $r('sys.color.ohos_id_color_text_primary')
                : COLOR_DISABLED)
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          if (lb.description.length > 0) {
            Text(lb.description)
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
              .width('100%')
          }

          Row() {
            Text(this.viewModel !== null
              ? this.viewModel.getEntryCountText(lb) : '')
              .fontSize(11)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
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
          .fillColor($r('sys.color.ohos_id_color_text_secondary'))
          .margin({ left: 8 })
          .rotate({
            angle: this.viewModel !== null
              && this.viewModel.expandedLorebookId === lb.id ? 180 : 0
          })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.toggleExpand(lb.id);
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.toggleExpand(lb.id);
        }
      })

      // 操作按钮行
      Row() {
        Button($r('app.string.lorebook_set_current'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .height(28)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.setCurrentLorebook(
                this.viewModel.isCurrent(lb) ? null : lb.id
              );
            }
          })

        Button($r('app.string.lorebook_edit'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .height(28)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showEditLorebookDialog(lb);
            }
          })

        Button(lb.enabled
          ? $r('app.string.lorebook_disable')
          : $r('app.string.lorebook_enable'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .height(28)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.toggleLorebookEnabled(lb);
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(COLOR_ERROR)
          .height(28)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetLorebook = lb;
            }
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 6 })
      .justifyContent(FlexAlign.SpaceEvenly)

      // 条目列表(展开时显示)
      if (this.viewModel !== null
        && this.viewModel.expandedLorebookId === lb.id) {
        Divider()
          .color(COLOR_DIVIDER)
          .width('100%')
          .height(1)

        if (lb.entries.length === 0) {
          Text($r('app.string.lorebook_no_entries'))
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
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
          .fontColor(COLOR_CURRENT)
          .height(32)
          .width('100%')
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showNewEntryDialog(lb.id);
            }
          })
      }
    }
    .width('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .borderRadius(8)
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
                .fontColor(COLOR_DISABLED)
                .border({ width: 1, color: COLOR_DISABLED, style: BorderStyle.Solid })
                .borderRadius(6)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ right: 4 })
            }
            Text(entry.name)
              .fontSize(13)
              .fontColor(entry.enabled
                ? $r('sys.color.ohos_id_color_text_primary')
                : COLOR_DISABLED)
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
                .fontColor(COLOR_CURRENT)
                .margin({ right: 4 })
            }
            if (entry.selective) {
              Text('Selective')
                .fontSize(10)
                .fontColor('#E67E22')
                .margin({ right: 4 })
            }
            if (entry.keys.length > 0) {
              Text(entry.keys.join(', '))
                .fontSize(10)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ right: 4 })
            }
            if (this.viewModel !== null) {
              Text('P' + entry.priority.toString())
                .fontSize(10)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ right: 4 })
              Text(this.viewModel.getPositionText(entry.position))
                .fontSize(10)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
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
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .height(24)
          .padding({ left: 4, right: 4 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showEditEntryDialog(lorebookId, entry);
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(11)
          .backgroundColor(Color.Transparent)
          .fontColor(COLOR_ERROR)
          .height(24)
          .padding({ left: 4, right: 4 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetEntry = entry;
              this.viewModel.deleteTargetEntryLorebookId = lorebookId;
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    }
    .width('100%')
    .backgroundColor(COLOR_ENTRY_BG)
    .margin({ left: 12, right: 12, bottom: 4 })
    .borderRadius(6)
  }

  // ===== 世界书编辑对话框 =====

  @Builder
  lorebookDialog() {
    Column() {
      // 遮罩
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
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
              this.viewModel.saveLorebook();
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

  // ===== 条目编辑对话框 =====

  @Builder
  entryDialog() {
    Column() {
      // 遮罩
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
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
          this.viewModel !== null ? this.viewModel.editEntryName : '',
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryName = value;
            }
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_keys'),
          $r('app.string.lorebook_entry_keys_placeholder'),
          this.viewModel !== null ? this.viewModel.editEntryKeys : '',
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryKeys = value;
            }
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_secondary_keys'),
          $r('app.string.lorebook_entry_secondary_keys_placeholder'),
          this.viewModel !== null ? this.viewModel.editEntrySecondaryKeys : '',
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntrySecondaryKeys = value;
            }
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_content'),
          $r('app.string.lorebook_entry_content_placeholder'),
          this.viewModel !== null ? this.viewModel.editEntryContent : '',
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryContent = value;
            }
          },
          true
        )

        // 开关行
        Row() {
          Text($r('app.string.lorebook_entry_constant'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.viewModel !== null
            ? this.viewModel.editEntryConstant : false })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntryConstant = isOn;
              }
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Text($r('app.string.lorebook_entry_selective'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.viewModel !== null
            ? this.viewModel.editEntrySelective : false })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntrySelective = isOn;
              }
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
            text: this.viewModel !== null
              ? this.viewModel.editEntryPriority.toString() : '0'
          })
            .fontSize(14)
            .type(InputType.Number)
            .layoutWeight(1)
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                const parsed: number = parseInt(value);
                this.viewModel.editEntryPriority = isNaN(parsed) ? 0 : parsed;
              }
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
              .backgroundColor(this.viewModel !== null
                && this.viewModel.editEntryPosition === 0
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
              })

            Button($r('app.string.lorebook_entry_position_after'))
              .fontSize(12)
              .backgroundColor(this.viewModel !== null
                && this.viewModel.editEntryPosition === 1
                ? $r('sys.color.ohos_id_color_emphasize')
                : $r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(16)
              .height(32)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel.editEntryPosition = 1;
                }
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
                this.viewModel.saveEntry();
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
          .maxLines(4)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange(onChange)
      } else {
        TextInput({
          placeholder: placeholder,
          text: text
        })
          .fontSize(14)
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
    Column() {
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)

    Column() {
      Text('删除世界书')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })

      Text(this.viewModel !== null && this.viewModel.deleteTargetLorebook !== null
        ? '确定删除世界书"' + this.viewModel.deleteTargetLorebook.name + '"吗?所有条目也将一并删除。'
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
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(14)
          .backgroundColor(COLOR_ERROR)
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            if (this.viewModel !== null && this.viewModel.deleteTargetLorebook !== null) {
              this.viewModel.deleteLorebook(this.viewModel.deleteTargetLorebook.id);
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

  // ===== 删除确认(条目) =====

  @Builder
  deleteEntryConfirm() {
    Column() {
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)

    Column() {
      Text('删除条目')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })

      Text(this.viewModel !== null && this.viewModel.deleteTargetEntry !== null
        ? '确定删除条目"' + this.viewModel.deleteTargetEntry.name + '"吗?'
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
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(14)
          .backgroundColor(COLOR_ERROR)
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            if (this.viewModel !== null && this.viewModel.deleteTargetEntry !== null) {
              this.viewModel.deleteEntry(
                this.viewModel.deleteTargetEntryLorebookId,
                this.viewModel.deleteTargetEntry.id
              );
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
}