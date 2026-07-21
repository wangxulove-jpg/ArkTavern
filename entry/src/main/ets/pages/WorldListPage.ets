/**
 * WorldListPage 多人世界列表页面
 *
 * 展示全部多人世界,支持:
 * - 创建新世界(跳转 WorldCreatePage)
 * - 进入世界聊天(创建/进入 Chat,跳转 WorldChatPage)
 * - 管理成员(跳转 WorldMembersPage)
 * - 删除世界(确认对话框)
 *
 * 复用:
 * - WorldListViewModel
 * - CharacterImageView
 * - EmptyStateView
 */

import { WorldListViewModel, WorldListItem } from '../viewmodels/WorldListViewModel';
import { AppServices } from '../services/AppServices';
import { CharacterImageView } from '../components/CharacterImageView';
import { EmptyStateView } from '../components/EmptyStateView';
import { WorldMemberView } from '../services/WorldService';
import { router, promptAction } from '@kit.ArkUI';

@Entry
@Component
struct WorldListPage {
  @State viewModel: WorldListViewModel | null = null;
  @State worlds: WorldListItem[] = [];
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const vm: WorldListViewModel = AppServices.createWorldListViewModel();
      this.viewModel = vm;
      await vm.reload();
      this.worlds = vm.worlds;
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

          Text('多人世界')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 8 })

          Button('新建')
            .fontSize(13)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .fontColor(Color.White)
            .borderRadius(16)
            .height(32)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/WorldCreatePage' });
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

        // 世界列表
        if (this.worlds.length === 0 && this.viewModel !== null && !this.viewModel!.isLoading) {
          EmptyStateView({
            title: '暂无多人世界',
            description: '点击右上角"新建"创建第一个世界'
          })
        } else {
          Scroll() {
            Column() {
              ForEach(this.worlds, (item: WorldListItem) => {
                this.WorldCard(item)
              }, (item: WorldListItem) => item.world.id)
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

      // 删除确认对话框(条件渲染,避免 build 多根节点)
      if (this.viewModel !== null && this.viewModel!.showDeleteConfirm) {
        this.DeleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DeleteConfirmDialog() {
    // 半透明遮罩
    Column() {
      // 占位填充顶部
      Blank()
      // 居中对话框
      Column() {
        Text('删除世界')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 8 })

        Text('确定删除这个世界吗?所有成员关系、场景、记忆都会被清除,关联的聊天记录会保留。')
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .borderRadius(20)
            .height(40)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => {
              this.viewModel!.cancelDelete();
            })

          Button('删除')
            .fontSize(14)
            .backgroundColor('#E74C3C')
            .fontColor(Color.White)
            .borderRadius(20)
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.viewModel!.confirmDelete();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  WorldCard(item: WorldListItem) {
    Column() {
      Row() {
        // 成员头像组
        Row() {
          ForEach(item.memberPreview, (view: WorldMemberView) => {
            CharacterImageView({
              imageUri: view.character !== null ? view.character.avatarUri : '',
              fallbackName: view.character !== null ? view.character.name : '?',
              imgWidth: 36,
              imgHeight: 36,
              imgBorderRadius: 18,
              displayMode: 'thumbnail'
            })
            .margin({ right: -8 })
          }, (view: WorldMemberView, idx: number) => idx.toString())
        }
        .width('40%')
        .alignItems(VerticalAlign.Center)

        // 世界信息
        Column() {
          Text(item.world.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(`成员 ${item.memberCount} · 在场 ${item.presentCount}`)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12 })

        // 更多菜单
        Row() {
          Button('进入')
            .fontSize(12)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .fontColor(Color.White)
            .borderRadius(12)
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ right: 4 })
            .onClick(() => {
              this.enterWorld(item.world.id);
            })

          Button('成员')
            .fontSize(12)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .borderRadius(12)
            .height(28)
            .padding({ left: 8, right: 8 })
            .margin({ right: 4 })
            .onClick(() => {
              router.pushUrl({
                url: 'pages/WorldMembersPage',
                params: { worldId: item.world.id }
              });
            })

          Button('删除')
            .fontSize(12)
            .backgroundColor('#E74C3C')
            .fontColor(Color.White)
            .borderRadius(12)
            .height(28)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.viewModel!.requestDelete(item.world.id);
            })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
      .borderRadius(12)
      .margin({ bottom: 8 })
    }
  }

  private async enterWorld(worldId: string): Promise<void> {
    try {
      // 查找该世界的现有 Chat,没有则创建
      const worldService = AppServices.getInstance().worldService;
      const links = await worldService.listChatsByWorld(worldId);
      let chatId: string = '';
      if (links.length > 0) {
        chatId = links[0].chatId;
      } else {
        // 创建初始场景对应的 Chat
        const scenes = await worldService.listScenes(worldId);
        if (scenes.length === 0) {
          promptAction.showToast({ message: '世界没有场景' });
          return;
        }
        const result = await worldService.createChatForWorld(worldId, '', scenes[0].id);
        chatId = result.chat.id;
      }
      router.pushUrl({
        url: 'pages/WorldChatPage',
        params: { chatId: chatId, worldId: worldId }
      });
    } catch (e) {
      promptAction.showToast({ message: '进入失败: ' + (e as Error).message });
    }
  }
}
