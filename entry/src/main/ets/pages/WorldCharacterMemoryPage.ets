/**
 * WorldCharacterMemoryPage 多人世界角色记忆页面
 *
 * 功能:
 * - 顶部:返回 + 标题 + 刷新按钮
 * - 角色头像横向列表:点击切换当前查看角色
 * - 当前角色记忆分区展示:
 *   * 私人记忆(仅当前角色可见)
 *   * 已知事件(subject=当前角色)
 *   * 与用户的共同经历(visibility=participants 且 subject 或 participant 包含当前角色)
 *   * 角色关系(source=当前角色,展示数值字段,不展示 privateOpinion)
 *   * 公共世界记忆(单独分区,visibility=public,所有角色共享)
 * - 空状态区分:
 *   * 尚未产生记忆
 *   * 加载中
 *   * 加载失败
 * - 脱敏诊断:页面底部显示上次查询的数量摘要
 *
 * 路由参数:{ worldId: string, chatId: string, branchId: string }
 *
 * 数据流:
 * - WorldCharacterMemoryViewModel 通过 WorldMemoryService / WorldRelationshipService 查询
 * - 页面订阅 onDataUpdate 回调触发重渲染
 * - onPageShow 触发刷新(从聊天页返回时同步最新记忆)
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import {
  WorldCharacterMemoryViewModel,
  MemoryDisplayItem,
  MemoryKind,
  CharacterAvatarItem,
  MemoryEmptyState
} from '../viewmodels/WorldCharacterMemoryViewModel';
import { CharacterImageView } from '../components/CharacterImageView';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldCharMemoryPage';

interface WorldCharacterMemoryRouteParam {
  worldId: string;
  chatId: string;
  branchId: string;
}

@Entry
@Component
struct WorldCharacterMemoryPage {
  @State viewModel: WorldCharacterMemoryViewModel | null = null;
  @State readyHandled: boolean = false;
  @State renderTick: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const param = router.getParams() as Record<string, Object>;
      if (param === null || param === undefined) {
        Logger.error(LOG_TAG, 'missing route params');
        return;
      }
      const worldId: string = param['worldId'] !== undefined ? String(param['worldId']) : '';
      const chatId: string = param['chatId'] !== undefined ? String(param['chatId']) : '';
      const branchId: string = param['branchId'] !== undefined ? String(param['branchId']) : '';
      if (worldId.length === 0 || chatId.length === 0 || branchId.length === 0) {
        Logger.error(LOG_TAG, 'invalid route params');
        return;
      }
      const vm: WorldCharacterMemoryViewModel = AppServices.createWorldCharacterMemoryViewModel();
      vm.onDataUpdate = (): void => {
        this.renderTick = !this.renderTick;
      };
      this.viewModel = vm;
      await vm.initialize(worldId, chatId, branchId);
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error).message);
    }
  }

  /** 页面重新显示时刷新(从聊天页返回时同步最新记忆) */
  onPageShow(): void {
    if (this.viewModel === null) return;
    if (this.viewModel!.selectedCharacterId.length === 0) return;
    void this.viewModel!.refresh();
  }

  build() {
    Stack() {
      Column() {
        this.TopBar();

        if (this.viewModel === null) {
          this.LoadingState('正在初始化...')
        } else {
          // 角色头像列表
          this.CharacterList()

          // 错误提示
          if (this.viewModel!.errorMessage.length > 0) {
            this.ErrorBanner()
          }

          // 主内容区
          Scroll() {
            Column() {
              if (this.viewModel!.loadState === 'loading') {
                this.LoadingState('正在加载记忆...')
              } else if (this.viewModel!.loadState === 'query_failed') {
                this.EmptyState('查询失败', this.viewModel!.errorMessage, '重试', (): void => {
                  void this.viewModel!.refresh();
                })
              } else if (this.viewModel!.loadState === 'no_memories') {
                this.EmptyState('尚未产生记忆',
                  '该角色还没有记忆。发送一条消息后会自动生成记忆。',
                  '刷新', (): void => {
                    void this.viewModel!.refresh();
                  })
              } else {
                this.MemoryContent()
              }

              // 诊断信息(底部)
              this.DiagnosticsCard()

              Blank().height(this.navigationBarHeight + 32)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }

  @Builder
  TopBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
        .padding(8)
        .onClick(() => {
          router.back();
        })

      Blank()

      Text('角色记忆')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))

      Blank()

      // 刷新按钮
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(20)
        .fontColor([$r('sys.color.ohos_id_color_text_primary')])
        .padding(8)
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.refresh();
          }
        })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.statusBarHeight + 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  CharacterList() {
    if (this.viewModel !== null && this.viewModel!.members.length > 0) {
      Scroll() {
        Row() {
          ForEach(this.viewModel!.members, (m: CharacterAvatarItem) => {
            Column() {
              Stack() {
                CharacterImageView({
                  imageUri: m.avatarUri,
                  fallbackName: m.displayName,
                  imgWidth: 48,
                  imgHeight: 48,
                  imgBorderRadius: 24,
                  displayMode: 'thumbnail'
                })
                if (m.isCurrent) {
                  // 选中标记:边框
                  Column()
                    .width(48)
                    .height(48)
                    .borderRadius(24)
                    .border({ width: 2, color: $r('sys.color.ohos_id_color_emphasize') })
                }
                if (!m.member.enabled || !m.member.present) {
                  // 禁用/离场标记
                  Text('离')
                    .fontSize(10)
                    .fontColor(Color.White)
                    .backgroundColor('#888888')
                    .borderRadius(8)
                    .padding({ left: 4, right: 4 })
                    .position({ right: 0, top: 0 })
                }
              }
              .width(48)
              .height(48)

              Text(m.displayName)
                .fontSize(11)
                .fontColor(m.isCurrent
                  ? $r('sys.color.ohos_id_color_emphasize')
                  : $r('sys.color.ohos_id_color_text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(56)
                .margin({ top: 2 })
                .textAlign(TextAlign.Center)
            }
            .margin({ right: 8 })
            .onClick(() => {
              void this.viewModel!.selectCharacter(m.characterId);
            })
          }, (m: CharacterAvatarItem) => m.characterId)
        }
        .padding({ left: 12, right: 12 })
      }
      .width('100%')
      .height(80)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)
    }
  }

  @Builder
  ErrorBanner() {
    Row() {
      Text(this.viewModel!.errorMessage)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_warning'))
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        .onClick(() => {
          this.viewModel!.errorMessage = '';
          this.renderTick = !this.renderTick;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor($r('sys.color.ohos_id_color_foreground'))
  }

  @Builder
  LoadingState(message: string) {
    Column() {
      LoadingProgress().width(32).height(32)
      Text(message)
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ top: 12 })
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState(title: string, desc: string, actionLabel: string, action: () => void) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .margin({ top: 40, bottom: 8 })

      Text(desc)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        .textAlign(TextAlign.Center)
        .margin({ left: 24, right: 24, bottom: 24 })

      Button(actionLabel)
        .type(ButtonType.Capsule)
        .width('60%')
        .height(40)
        .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
        .fontColor(Color.White)
        .onClick(() => action())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  MemoryContent() {
    Column() {
      // 1. 私人记忆
      this.MemorySection('私人记忆', '只有该角色可知的内心想法与秘密',
        this.viewModel!.privateMemories, 'private')

      // 2. 已知事件
      this.MemorySection('已知事件', '该角色作为主体参与的事件',
        this.viewModel!.knownEvents, 'known_event')

      // 3. 与用户的共同经历
      this.MemorySection('与用户的共同经历', '该角色与用户共同参与的事件',
        this.viewModel!.sharedExperiences, 'shared_with_user')

      // 4. 角色关系
      this.MemorySection('角色关系', '该角色对其他角色的关系状态',
        this.viewModel!.relationshipMemories, 'relationship')

      // 5. 公共世界记忆(单独分区)
      this.MemorySection('公共世界记忆', '所有在场角色共享的世界事件',
        this.viewModel!.publicMemories, 'public')

      // 6. 与用户的关系数值(单独展示)
      if (this.viewModel!.userRelationship !== null) {
        this.UserRelationshipCard()
      }
    }
    .width('100%')
  }

  @Builder
  MemorySection(title: string, subtitle: string, items: MemoryDisplayItem[], kind: MemoryKind) {
    Column() {
      Row() {
        Column() {
          Text(title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Text(subtitle)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(items.length.toString())
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor($r('sys.color.ohos_id_color_foreground'))
          .borderRadius(8)
      }
      .width('100%')
      .padding({ top: 12, bottom: 8 })

      if (items.length === 0) {
        Text('暂无')
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .padding({ top: 8, bottom: 12, left: 4 })
      } else {
        ForEach(items, (item: MemoryDisplayItem) => {
          this.MemoryCard(item)
        }, (item: MemoryDisplayItem) => item.id)
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  @Builder
  MemoryCard(item: MemoryDisplayItem) {
    Column() {
      // 摘要正文
      Text(item.summary)
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
        .lineHeight(20)
        .width('100%')

      // 元信息
      Row() {
        Text(this.kindLabel(item.kind))
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor($r('sys.color.ohos_id_color_foreground'))
          .borderRadius(4)

        Text('·')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .margin({ left: 6, right: 6 })

        Text(item.visibilityLabel)
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))

        Blank()

        if (!item.enabled) {
          Text('已失效')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_warning'))
        }

        Text(this.formatTime(item.createdAt))
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ top: 8 })

      // 场景与消息范围(只在有值时显示)
      if (item.sceneId.length > 0 || item.startMessageId.length > 0) {
        Row() {
          if (item.sceneId.length > 0) {
            Text(`场景: ${item.sceneId.substring(0, 6)}...`)
              .fontSize(11)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          }
          if (item.startMessageId.length > 0) {
            Text(`消息: ${item.startMessageId.substring(0, 6)}... - ${item.endMessageId.substring(0, 6)}...`)
              .fontSize(11)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
              .margin({ left: 12 })
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(10)
    .margin({ top: 8 })
  }

  @Builder
  UserRelationshipCard() {
    Column() {
      Row() {
        Text('与用户的关系')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Text('用户关系')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor($r('sys.color.ohos_id_color_foreground'))
          .borderRadius(4)
      }
      .width('100%')

      if (this.viewModel!.userRelationship !== null) {
        Column() {
          if (this.viewModel!.userRelationship!.relationshipLabel.length > 0) {
            this.FieldRow('关系', this.viewModel!.userRelationship!.relationshipLabel)
          }
          if (this.viewModel!.userRelationship!.currentEmotion.length > 0) {
            this.FieldRow('当前情绪', this.viewModel!.userRelationship!.currentEmotion)
          }
          this.FieldRow('好感', this.viewModel!.userRelationship!.affinity.toString())
          this.FieldRow('信任', this.viewModel!.userRelationship!.trust.toString())
          this.FieldRow('尊敬', this.viewModel!.userRelationship!.respect.toString())
          this.FieldRow('恐惧', this.viewModel!.userRelationship!.fear.toString())
          this.FieldRow('敌意', this.viewModel!.userRelationship!.hostility.toString())
          this.FieldRow('依赖', this.viewModel!.userRelationship!.dependency.toString())
          this.FieldRow('熟悉度', this.viewModel!.userRelationship!.familiarity.toString())
          if (this.viewModel!.userRelationship!.sharedExperiences.length > 0) {
            this.FieldRow('共同经历', this.viewModel!.userRelationship!.sharedExperiences.length.toString() + ' 条')
          }
          if (this.viewModel!.userRelationship!.promises.length > 0) {
            this.FieldRow('承诺', this.viewModel!.userRelationship!.promises.length.toString() + ' 条')
          }
          if (this.viewModel!.userRelationship!.conflicts.length > 0) {
            this.FieldRow('冲突', this.viewModel!.userRelationship!.conflicts.length.toString() + ' 条')
          }
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
    .borderRadius(10)
    .margin({ top: 12 })
  }

  @Builder
  FieldRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  DiagnosticsCard() {
    if (this.viewModel !== null) {
      Column() {
        Text('诊断信息')
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .margin({ bottom: 4 })

        Row() {
          Text('查询的 worldId:')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          Text(this.viewModel!.worldId.substring(0, 6) + '...')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .margin({ left: 4 })
        }
        .width('100%')

        Row() {
          Text('查询的 branchId:')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          Text(this.viewModel!.branchId.substring(0, 6) + '...')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .margin({ left: 4 })
        }
        .width('100%')
        .margin({ top: 2 })

        Row() {
          Text('查询的 characterId:')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          Text(this.viewModel!.selectedCharacterId.substring(0, 6) + '...')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .margin({ left: 4 })
        }
        .width('100%')
        .margin({ top: 2 })

        Row() {
          Text(`记忆总数: ${this.viewModel!.lastTotalCount}`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          Text(`| 私人=${this.viewModel!.privateMemories.length} 已知=${this.viewModel!.knownEvents.length} 共同=${this.viewModel!.sharedExperiences.length} 公共=${this.viewModel!.publicMemories.length} 关系=${this.viewModel!.relationshipMemories.length}`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .margin({ left: 8 })
        }
        .width('100%')
        .margin({ top: 2 })

        if (this.viewModel!.lastQueryAt > 0) {
          Text(`上次查询: ${this.formatTime(this.viewModel!.lastQueryAt)}`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .margin({ top: 2 })
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('sys.color.ohos_id_color_foreground'))
      .borderRadius(8)
      .margin({ top: 16 })
    }
  }

  private kindLabel(kind: MemoryKind): string {
    switch (kind) {
      case 'private': return '私人';
      case 'known_event': return '已知事件';
      case 'shared_with_user': return '共同经历';
      case 'public': return '公共';
      case 'relationship': return '关系';
      default: return kind;
    }
  }

  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '从未';
    }
    const date: Date = new Date(ts);
    const y: number = date.getFullYear();
    const m: number = date.getMonth() + 1;
    const d: number = date.getDate();
    const h: number = date.getHours();
    const min: number = date.getMinutes();
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return y.toString() + '-' + pad(m) + '-' + pad(d)
      + ' ' + pad(h) + ':' + pad(min);
  }
}
