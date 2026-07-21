/**
 * WorldCreatePage 创建多人世界页面
 *
 * 多步表单:
 * - 世界基础信息(名称、背景、初始场景、默认回复模式)
 * - 用户在世界中的身份(名称、身份描述、外貌、背景、公开/私人信息、默认称呼)
 * - 选择本地角色(至少 2 个)
 * - 设置每个角色的初始关系(称谓、好感、信任等)
 *
 * 提交成功后跳转到 WorldListPage 或直接进入 WorldChatPage。
 */

import {
  WorldCreateViewModel,
  CandidateCharacter
} from '../viewmodels/WorldCreateViewModel';
import { AppServices } from '../services/AppServices';
import { CharacterImageView } from '../components/CharacterImageView';
import { WorldReplyMode, WorldUserIdentity } from '../models/World';
import { router, promptAction } from '@kit.ArkUI';

/** 回复模式选项 */
interface ReplyModeOption {
  readonly mode: WorldReplyMode;
  readonly label: string;
}

@Entry
@Component
struct WorldCreatePage {
  @State viewModel: WorldCreateViewModel | null = null;
  @State characters: CandidateCharacter[] = [];
  @State currentStep: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const vm: WorldCreateViewModel = AppServices.createWorldCreateViewModel();
      this.viewModel = vm;
      await vm.loadCharacters();
      this.characters = vm.characters;
    } catch (e) {
      promptAction.showToast({ message: '加载失败: ' + (e as Error).message });
    }
  }

  build() {
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

        Text('创建多人世界')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8, right: 8 })

        Text(`步骤 ${this.currentStep + 1}/3`)
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .padding({ right: 12 })
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

      // 步骤内容
      Scroll() {
        Column() {
          if (this.currentStep === 0) {
            this.StepWorldBasic()
          } else if (this.currentStep === 1) {
            this.StepUserIdentity()
          } else {
            this.StepSelectCharacters()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      // 底部按钮
      Row() {
        if (this.currentStep > 0) {
          Button('上一步')
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .borderRadius(20)
            .height(40)
            .padding({ left: 24, right: 24 })
            .margin({ right: 8 })
            .onClick(() => {
              if (this.currentStep > 0) {
                this.currentStep--;
              }
            })
        }

        Button(this.currentStep === 2 ? '创建世界' : '下一步')
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor(Color.White)
          .borderRadius(20)
          .height(40)
          .padding({ left: 24, right: 24 })
          .enabled(this.viewModel !== null && !this.viewModel!.isSubmitting)
          .onClick(() => {
            this.handleNext();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  StepWorldBasic() {
    Column() {
      Text('世界基础信息')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')
        .margin({ bottom: 12 })

      Text('世界名称')
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({
        text: this.viewModel !== null ? this.viewModel!.form.name : '',
        placeholder: '为这个世界取个名字'
      })
        .fontSize(14)
        .backgroundColor($r('sys.color.ohos_id_color_text_field_bg'))
        .borderRadius(8)
        .height(44)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.viewModel!.updateForm({ name: value });
        })

      Text('世界背景')
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })

      TextArea({
        text: this.viewModel !== null ? this.viewModel!.form.background : '',
        placeholder: '描述世界的历史、设定、规则等'
      })
        .fontSize(14)
        .backgroundColor($r('sys.color.ohos_id_color_text_field_bg'))
        .borderRadius(8)
        .height(100)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onChange((value: string) => {
          this.viewModel!.updateForm({ background: value });
        })

      Text('初始场景')
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })

      TextArea({
        text: this.viewModel !== null ? this.viewModel!.form.initialScene : '',
        placeholder: '描述故事开始时的场景'
      })
        .fontSize(14)
        .backgroundColor($r('sys.color.ohos_id_color_text_field_bg'))
        .borderRadius(8)
        .height(80)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onChange((value: string) => {
          this.viewModel!.updateForm({ initialScene: value });
        })

      Text('默认回复模式')
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })

      Row() {
        ForEach([
          { mode: 'auto_director' as WorldReplyMode, label: '自动导演' } as ReplyModeOption,
          { mode: 'designated' as WorldReplyMode, label: '指定角色' } as ReplyModeOption,
          { mode: 'all_respond' as WorldReplyMode, label: '全员回应' } as ReplyModeOption,
          { mode: 'narrator_only' as WorldReplyMode, label: '仅旁白' } as ReplyModeOption
        ] as ReplyModeOption[], (item: ReplyModeOption) => {
          Button(item.label)
            .fontSize(12)
            .backgroundColor(
              this.viewModel !== null && this.viewModel!.form.defaultReplyMode === item.mode
                ? $r('sys.color.ohos_id_color_emphasize')
                : $r('sys.color.ohos_id_color_button_normal')
            )
            .fontColor(
              this.viewModel !== null && this.viewModel!.form.defaultReplyMode === item.mode
                ? Color.White
                : $r('sys.color.ohos_id_color_text_primary')
            )
            .borderRadius(14)
            .height(28)
            .padding({ left: 10, right: 10 })
            .margin({ right: 6 })
            .onClick(() => {
              this.viewModel!.updateForm({ defaultReplyMode: item.mode });
            })
        }, (item: ReplyModeOption) => item.mode)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  StepUserIdentity() {
    Column() {
      Text('用户在世界中的身份')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .width('100%')
        .margin({ bottom: 12 })

      this.IdentityField('用户名称', '在世界中你的名字', 'userName')
      this.IdentityField('身份描述', '职业 / 头衔 / 角色定位', 'identityDescription')
      this.IdentityField('外貌特征', '容貌 / 衣着 / 显著特征', 'appearance')
      this.IdentityField('世界中的背景', '身世 / 经历', 'background')
      this.IdentityField('公开信息', '他人可知的公开信息', 'publicInfo')
      this.IdentityField('私人信息', '只有你知道的秘密', 'privateInfo')
      this.IdentityField('默认称呼', '角色对你的默认称呼', 'defaultAddressTerm')
    }
    .width('100%')
  }

  @Builder
  IdentityField(label: string, placeholder: string, field: string) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ bottom: 4 })

      TextInput({
        text: this.getIdentityField(field),
        placeholder: placeholder
      })
        .fontSize(14)
        .backgroundColor($r('sys.color.ohos_id_color_text_field_bg'))
        .borderRadius(8)
        .height(40)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.updateIdentityField(field, value);
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  private getIdentityField(field: string): string {
    if (this.viewModel === null) {
      return '';
    }
    const identity = this.viewModel!.form.userIdentity;
    switch (field) {
      case 'userName': return identity.userName;
      case 'identityDescription': return identity.identityDescription;
      case 'appearance': return identity.appearance;
      case 'background': return identity.background;
      case 'publicInfo': return identity.publicInfo;
      case 'privateInfo': return identity.privateInfo;
      case 'defaultAddressTerm': return identity.defaultAddressTerm;
      default: return '';
    }
  }

  private updateIdentityField(field: string, value: string): void {
    if (this.viewModel === null) {
      return;
    }
    const identity: WorldUserIdentity = this.viewModel!.form.userIdentity;
    let newIdentity: WorldUserIdentity;
    switch (field) {
      case 'userName':
        newIdentity = {
          userName: value,
          identityDescription: identity.identityDescription,
          appearance: identity.appearance,
          background: identity.background,
          publicInfo: identity.publicInfo,
          privateInfo: identity.privateInfo,
          defaultAddressTerm: identity.defaultAddressTerm
        };
        break;
      case 'identityDescription':
        newIdentity = {
          userName: identity.userName,
          identityDescription: value,
          appearance: identity.appearance,
          background: identity.background,
          publicInfo: identity.publicInfo,
          privateInfo: identity.privateInfo,
          defaultAddressTerm: identity.defaultAddressTerm
        };
        break;
      case 'appearance':
        newIdentity = {
          userName: identity.userName,
          identityDescription: identity.identityDescription,
          appearance: value,
          background: identity.background,
          publicInfo: identity.publicInfo,
          privateInfo: identity.privateInfo,
          defaultAddressTerm: identity.defaultAddressTerm
        };
        break;
      case 'background':
        newIdentity = {
          userName: identity.userName,
          identityDescription: identity.identityDescription,
          appearance: identity.appearance,
          background: value,
          publicInfo: identity.publicInfo,
          privateInfo: identity.privateInfo,
          defaultAddressTerm: identity.defaultAddressTerm
        };
        break;
      case 'publicInfo':
        newIdentity = {
          userName: identity.userName,
          identityDescription: identity.identityDescription,
          appearance: identity.appearance,
          background: identity.background,
          publicInfo: value,
          privateInfo: identity.privateInfo,
          defaultAddressTerm: identity.defaultAddressTerm
        };
        break;
      case 'privateInfo':
        newIdentity = {
          userName: identity.userName,
          identityDescription: identity.identityDescription,
          appearance: identity.appearance,
          background: identity.background,
          publicInfo: identity.publicInfo,
          privateInfo: value,
          defaultAddressTerm: identity.defaultAddressTerm
        };
        break;
      case 'defaultAddressTerm':
        newIdentity = {
          userName: identity.userName,
          identityDescription: identity.identityDescription,
          appearance: identity.appearance,
          background: identity.background,
          publicInfo: identity.publicInfo,
          privateInfo: identity.privateInfo,
          defaultAddressTerm: value
        };
        break;
      default:
        return;
    }
    this.viewModel!.updateForm({ userIdentity: newIdentity });
  }

  @Builder
  StepSelectCharacters() {
    Column() {
      Row() {
        Text('选择角色')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Text(`已选 ${this.viewModel !== null ? this.viewModel!.getSelectedCount() : 0} 个(至少 2 个)`)
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      }
      .width('100%')
      .margin({ bottom: 12 })

      if (this.characters.length === 0) {
        Text('暂无本地角色,请先在角色 Tab 创建或导入角色卡')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(20)
      } else {
        ForEach(this.characters, (c: CandidateCharacter) => {
          this.CharacterCandidateCard(c)
        }, (c: CandidateCharacter) => c.character.id)
      }
    }
    .width('100%')
  }

  @Builder
  CharacterCandidateCard(c: CandidateCharacter) {
    Column() {
      Row() {
        CharacterImageView({
          imageUri: c.character.avatarUri,
          fallbackName: c.character.name,
          imgWidth: 48,
          imgHeight: 48,
          imgBorderRadius: 24,
          displayMode: 'thumbnail'
        })

        Column() {
          Text(c.character.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(c.character.description.length > 0
            ? c.character.description.substring(0, 60)
            : '暂无描述')
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12 })

        Toggle({ type: ToggleType.Checkbox, isOn: c.selected })
          .onChange((on: boolean) => {
            this.viewModel!.toggleSelected(c.character.id);
            this.characters = this.viewModel!.characters;
          })
      }
      .width('100%')

      // 选中时显示初始关系设置
      if (c.selected) {
        Column() {
          this.RelationshipField(c, '关系称谓', 'relationshipLabel')
          this.RelationshipField(c, '对用户称呼', 'addressTerm')
          this.RelationshipField(c, '当前印象', 'currentImpression')
          this.RelationshipField(c, '共同经历', 'sharedExperiences')
          this.RelationshipField(c, '已知秘密', 'knownSecrets')

          Row() {
            Text('初始好感')
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Slider({
              value: c.initialRelationship.affinity,
              min: -100,
              max: 100,
              step: 5
            })
              .layoutWeight(1)
              .onChange((value: number) => {
                this.viewModel!.updateInitialRelationship(c.character.id, {
                  affinity: Math.round(value)
                });
                this.characters = this.viewModel!.characters;
              })
            Text(c.initialRelationship.affinity.toString())
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .width(40)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text('初始信任')
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Slider({
              value: c.initialRelationship.trust,
              min: -100,
              max: 100,
              step: 5
            })
              .layoutWeight(1)
              .onChange((value: number) => {
                this.viewModel!.updateInitialRelationship(c.character.id, {
                  trust: Math.round(value)
                });
                this.characters = this.viewModel!.characters;
              })
            Text(c.initialRelationship.trust.toString())
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .width(40)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text('在场')
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: c.present })
              .onChange((on: boolean) => {
                this.viewModel!.setPresent(c.character.id, on);
                this.characters = this.viewModel!.characters;
              })
          }
          .width('100%')
          .margin({ top: 6 })

          Row() {
            Text('活跃度')
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Slider({
              value: c.talkativeness,
              min: 0,
              max: 1,
              step: 0.1
            })
              .layoutWeight(1)
              .onChange((value: number) => {
                this.viewModel!.setTalkativeness(c.character.id, value);
                this.characters = this.viewModel!.characters;
              })
            Text(c.talkativeness.toFixed(1))
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
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(12)
    .margin({ bottom: 8 })
  }

  @Builder
  RelationshipField(c: CandidateCharacter, label: string, field: string) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width('100%')
        .margin({ bottom: 2 })

      TextInput({
        text: this.getRelationshipField(c, field),
        placeholder: label
      })
        .fontSize(13)
        .backgroundColor($r('sys.color.ohos_id_color_text_field_bg'))
        .borderRadius(6)
        .height(36)
        .padding({ left: 8, right: 8 })
        .onChange((value: string) => {
          this.updateRelationshipField(c.character.id, field, value);
        })
    }
    .width('100%')
    .margin({ top: 4 })
  }

  private getRelationshipField(c: CandidateCharacter, field: string): string {
    const r = c.initialRelationship;
    switch (field) {
      case 'relationshipLabel': return r.relationshipLabel;
      case 'addressTerm': return r.addressTerm;
      case 'currentImpression': return r.currentImpression;
      case 'sharedExperiences': return r.sharedExperiences;
      case 'knownSecrets': return r.knownSecrets;
      default: return '';
    }
  }

  private updateRelationshipField(characterId: string, field: string, value: string): void {
    switch (field) {
      case 'relationshipLabel':
        this.viewModel!.updateInitialRelationship(characterId, { relationshipLabel: value });
        break;
      case 'addressTerm':
        this.viewModel!.updateInitialRelationship(characterId, { addressTerm: value });
        break;
      case 'currentImpression':
        this.viewModel!.updateInitialRelationship(characterId, { currentImpression: value });
        break;
      case 'sharedExperiences':
        this.viewModel!.updateInitialRelationship(characterId, { sharedExperiences: value });
        break;
      case 'knownSecrets':
        this.viewModel!.updateInitialRelationship(characterId, { knownSecrets: value });
        break;
      default:
        break;
    }
    this.characters = this.viewModel!.characters;
  }

  private async handleNext(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    // 步骤校验
    if (this.currentStep === 0) {
      if (this.viewModel!.form.name.length === 0) {
        this.viewModel!.errorMessage = '请填写世界名称';
        return;
      }
      this.currentStep = 1;
    } else if (this.currentStep === 1) {
      if (this.viewModel!.form.userIdentity.userName.length === 0) {
        this.viewModel!.errorMessage = '请填写用户名称';
        return;
      }
      this.currentStep = 2;
    } else {
      // 提交
      const ok: boolean = await this.viewModel!.submit();
      if (ok) {
        promptAction.showToast({ message: '世界创建成功' });
        router.back();
      }
    }
  }
}
