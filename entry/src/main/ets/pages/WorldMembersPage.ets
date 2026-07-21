/**
 * WorldMembersPage 多人世界成员管理页面
 *
 * 功能:
 * - 加载指定世界的成员列表
 * - 切换在场/离场、静音/恢复、启用/禁用
 * - 调整活跃度
 * - 移出成员(不删除原角色卡)
 * - 添加新角色(对话框)
 */

import {
  WorldMembersViewModel,
  AddableCharacter
} from '../viewmodels/WorldMembersViewModel';
import { AppServices } from '../services/AppServices';
import { CharacterImageView } from '../components/CharacterImageView';
import { EmptyStateView } from '../components/EmptyStateView';
import { WorldMemberView } from '../services/WorldService';
import { router, promptAction } from '@kit.ArkUI';

@Entry
@Component
struct WorldMembersPage {
  @State viewModel: WorldMembersViewModel | null = null;
  @State members: WorldMemberView[] = [];
  @State addableCharacters: AddableCharacter[] = [];
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const param = router.getParams() as Record<string, Object>;
      const worldId: string = param !== null && param !== undefined
        ? String(param['worldId'])
        : '';
      if (worldId.length === 0) {
        promptAction.showToast({ message: '缺少 worldId' });
        router.back();
        return;
      }
      const vm: WorldMembersViewModel = AppServices.createWorldMembersViewModel();
      this.viewModel = vm;
      await vm.initialize(worldId);
      this.members = vm.members;
    } catch (e) {
      promptAction.showToast({ message: '加载失败: ' + (e as Error).message });
    }
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([$r('sys.color.ohos_id_color_text_primary')])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text(this.viewModel !== null ? this.viewModel!.worldName : '成员管理')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 8 })

          Button('添加')
            .fontSize(13)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .fontColor(Color.White)
            .borderRadius(16)
            .height(32)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.viewModel!.openAddDialog();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: this.statusBarHeight + 12, bottom: 4 })
        .alignItems(VerticalAlign.Center)

        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize(13)
            .fontColor('#E74C3C')
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }

        // 成员列表
        if (this.members.length === 0 && this.viewModel !== null && !this.viewModel!.isLoading) {
          EmptyStateView({
            title: '暂无成员',
            description: '点击右上角"添加"加入角色'
          })
        } else {
          Scroll() {
            Column() {
              ForEach(this.members, (view: WorldMemberView) => {
                this.MemberCard(view)
              }, (view: WorldMemberView) => view.member.id)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 12 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')

      // 添加成员对话框(条件渲染在 Stack 内)
      if (this.viewModel !== null && this.viewModel!.showAddDialog) {
        this.AddMemberDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MemberCard(view: WorldMemberView) {
    Column() {
      Row() {
        CharacterImageView({
          imageUri: view.character !== null ? view.character.avatarUri : '',
          fallbackName: view.character !== null ? view.character.name : '?',
          imgWidth: 48,
          imgHeight: 48,
          imgBorderRadius: 24,
          displayMode: 'thumbnail'
        })

        Column() {
          Text(view.character !== null ? view.character.name : '未知角色')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.getStatusText(view))
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12 })

        Button('移出')
          .fontSize(12)
          .backgroundColor('#E74C3C')
          .fontColor(Color.White)
          .borderRadius(12)
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.confirmRemove(view.member.characterId);
          })
      }
      .width('100%')

      // 控制开关
      Column() {
        Row() {
          Text('在场')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: view.member.present })
            .onChange((on: boolean) => {
              this.viewModel!.setPresent(view.member.characterId, on).then(() => {
                this.members = this.viewModel!.members;
              });
            })
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          Text('启用')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: view.member.enabled })
            .onChange((on: boolean) => {
              this.viewModel!.setEnabled(view.member.characterId, on).then(() => {
                this.members = this.viewModel!.members;
              });
            })
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          Text('静音')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: view.member.muted })
            .onChange((on: boolean) => {
              this.viewModel!.setMuted(view.member.characterId, on).then(() => {
                this.members = this.viewModel!.members;
              });
            })
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          Text('活跃度')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          Slider({
            value: view.member.talkativeness,
            min: 0,
            max: 1,
            step: 0.1
          })
            .layoutWeight(1)
          Text(view.member.talkativeness.toFixed(1))
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .width(40)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .width('100%')
      .padding({ left: 60, top: 8 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(12)
    .margin({ bottom: 8 })
  }

  private getStatusText(view: WorldMemberView): string {
    const parts: string[] = [];
    parts.push(view.member.enabled ? '启用' : '禁用');
    parts.push(view.member.present ? '在场' : '离场');
    if (view.member.muted) {
      parts.push('静音');
    }
    parts.push('活跃度 ' + view.member.talkativeness.toFixed(1));
    return parts.join(' · ');
  }

  private confirmRemove(characterId: string): void {
    AlertDialog.show({
      title: '移出成员',
      message: '将该角色从世界中移出。原角色卡不会被删除,历史消息保留。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '移出',
        fontColor: '#E74C3C',
        action: async () => {
          await this.viewModel!.removeMember(characterId);
          this.members = this.viewModel!.members;
        }
      }
    });
  }

  @Builder
  AddMemberDialog() {
    Column() {
      Column() {
        Text('添加角色到世界')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .margin({ bottom: 12 })

        if (this.viewModel!.addableCharacters.length === 0) {
          Text('所有本地角色均已加入此世界')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(20)
        } else {
          Scroll() {
            Column() {
              ForEach(this.viewModel!.addableCharacters, (c: AddableCharacter) => {
                this.AddableCard(c)
              }, (c: AddableCharacter) => c.character.id)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
        }

        Row() {
          Button('关闭')
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .borderRadius(20)
            .height(40)
            .padding({ left: 24, right: 24 })
            .onClick(() => {
              this.viewModel!.closeAddDialog();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 12 })
      }
      .width('92%')
      .padding(16)
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  AddableCard(c: AddableCharacter) {
    Column() {
      Row() {
        CharacterImageView({
          imageUri: c.character.avatarUri,
          fallbackName: c.character.name,
          imgWidth: 40,
          imgHeight: 40,
          imgBorderRadius: 20,
          displayMode: 'thumbnail'
        })

        Column() {
          Text(c.character.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Text(c.character.description.length > 0
            ? c.character.description.substring(0, 50)
            : '暂无描述')
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10 })

        Button('加入')
          .fontSize(12)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor(Color.White)
          .borderRadius(12)
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(async () => {
            const ok = await this.viewModel!.addMember(c.character.id);
            if (ok) {
              this.members = this.viewModel!.members;
              this.addableCharacters = this.viewModel!.addableCharacters;
            }
          })
      }
      .width('100%')

      // 在场开关
      Row() {
        Text('在场')
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: c.present })
          .onChange((on: boolean) => {
            this.viewModel!.updateAddablePresent(c.character.id, on);
            this.addableCharacters = this.viewModel!.addableCharacters;
          })
      }
      .width('100%')
      .margin({ top: 6, left: 50 })
    }
    .width('100%')
    .padding(10)
    .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(10)
    .margin({ bottom: 6 })
  }
}
