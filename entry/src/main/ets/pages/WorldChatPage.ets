/**
 * WorldChatPage 多人世界聊天页面
 *
 * 功能:
 * - 顶部:返回 + 世界名称 + 场景 + 回复模式 + 在场头像组
 * - 消息列表:用户 / 角色 / 旁白 三种气泡,独立头像与名称
 * - 流式生成预览
 * - 输入区:输入框 + 发送 / 停止按钮
 * - 回复模式选择器
 * - 指定角色选择器
 * - 场景选择器
 *
 * 复用:
 * - WorldChatViewModel
 * - CharacterImageView
 */

import {
  WorldChatViewModel,
  WorldChatMessageItem,
  PresentMemberAvatar,
  replyModeLabel,
  SendScope
} from '../viewmodels/WorldChatViewModel';
import { AppServices } from '../services/AppServices';
import { ChatRichText, ChatSenderType } from '../components/ChatRichText';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import { CharacterImageView } from '../components/CharacterImageView';
import { WorldScene } from '../models/WorldScene';
import { WorldReplyMode } from '../models/World';
import { router, promptAction } from '@kit.ArkUI';

/** 回复模式选项(含描述) */
interface ReplyModeItem {
  readonly mode: WorldReplyMode;
  readonly label: string;
  readonly desc: string;
}

/** 发送范围选项(含描述) */
interface ScopeItem {
  readonly scope: SendScope;
  readonly label: string;
  readonly desc: string;
}

@Entry
@Component
struct WorldChatPage {
  @State viewModel: WorldChatViewModel | null = null;
  @State messages: WorldChatMessageItem[] = [];
  /** v11 富文本样式设置 */
  @State chatTextStyle: ChatTextStyle | null = null;
  @State presentMembers: PresentMemberAvatar[] = [];
  @State scenes: WorldScene[] = [];
  @State streamingPreview: string = '';
  /** 触发状态重渲染的开关(避免直接读 viewModel 属性不触发更新) */
  @State streamFlushTrigger: boolean = false;
  /** 是否显示更多菜单 */
  @State showMoreMenu: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  private scroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const param = router.getParams() as Record<string, Object>;
      const chatId: string = param !== null && param !== undefined
        ? String(param['chatId'])
        : '';
      if (chatId.length === 0) {
        promptAction.showToast({ message: '缺少 chatId' });
        router.back();
        return;
      }
      const vm: WorldChatViewModel = AppServices.createWorldChatViewModel();
      this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
      // 订阅 ViewModel 状态更新(参照 ChatPage.onMessagesUpdate 模式)
      vm.onMessagesUpdate = (msgs: WorldChatMessageItem[]): void => {
        const prevCount: number = this.messages.length;
        this.messages = msgs;
        // v11 修复:消息数量增加时(新消息到达),延迟滚动到底部
        // 避免 onMessageReady 回调生成新消息后用户看不到回复
        if (msgs.length > prevCount) {
          setTimeout(() => {
            this.scrollToBottom();
          }, 50);
        }
      };
      vm.onStreamingUpdate = (preview: string): void => {
        this.streamingPreview = preview;
        // 流式预览更新时也滚动到底部,确保用户看到最新流式内容
        if (preview.length > 0) {
          setTimeout(() => {
            this.scrollToBottom();
          }, 50);
        }
      };
      vm.onStateUpdate = (): void => {
        if (this.viewModel !== null) {
          // 触发 @State 重新读取 viewModel 的属性
          this.presentMembers = this.viewModel!.presentMembers;
          this.scenes = this.viewModel!.scenes;
          // isGenerating / errorMessage / statusMessage 等通过 viewModel 直接读取
          // 这里用一个空赋值触发重渲染
          this.streamFlushTrigger = !this.streamFlushTrigger;
        }
      };
      this.viewModel = vm;
      await vm.initialize(chatId);
      this.syncState();
      // v11 修复:进入聊天页时滚动到底部,显示最新消息
      setTimeout(() => {
        this.scrollToBottom();
      }, 100);
    } catch (e) {
      promptAction.showToast({ message: '初始化失败: ' + (e as Error).message });
    }
  }

  private syncState(): void {
    if (this.viewModel === null) {
      return;
    }
    this.messages = this.viewModel!.messages;
    this.presentMembers = this.viewModel!.presentMembers;
    this.scenes = this.viewModel!.scenes;
    this.streamingPreview = this.viewModel!.streamingPreview;
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏
        this.TopBar()

        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize(13)
            .fontColor('#E74C3C')
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
            .onClick(() => {
              this.viewModel!.clearError();
            })
        }

        // 消息列表
        if (this.messages.length === 0
          && this.viewModel !== null
          && !this.viewModel!.isInitializing) {
          Column() {
            Text('开始你的多人世界对话')
              .fontSize(14)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .textAlign(TextAlign.Center)
              .padding(40)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.scroller) {
            Column() {
              ForEach(this.messages, (item: WorldChatMessageItem) => {
                this.MessageBubble(item)
              }, (item: WorldChatMessageItem) => item.message.id)

              // 流式预览
              if (this.viewModel !== null
                && this.viewModel!.isGenerating
                && this.streamingPreview.length > 0) {
                this.StreamingPreview()
              }

              // 生成中提示
              if (this.viewModel !== null
                && this.viewModel!.isGenerating
                && this.streamingPreview.length === 0) {
                Row() {
                  LoadingProgress().width(20).height(20)
                  Text(this.viewModel!.statusMessage.length > 0
                    ? this.viewModel!.statusMessage
                    : '生成中...')
                    .fontSize(13)
                    .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .padding(12)
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 12 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
        }

        // 输入区
        this.InputArea()
      }
      .width('100%')
      .height('100%')

      // 选择器对话框(条件渲染在 Stack 内,避免 build 多根节点)
      if (this.viewModel !== null && this.viewModel!.showReplyModePicker) {
        this.ReplyModePicker()
      }
      if (this.viewModel !== null && this.viewModel!.showDesignatedPicker) {
        this.DesignatedPicker()
      }
      if (this.viewModel !== null && this.viewModel!.showScenePicker) {
        this.ScenePicker()
      }
      if (this.viewModel !== null && this.viewModel!.showScopePicker) {
        this.ScopePicker()
      }
      if (this.viewModel !== null && this.viewModel!.showPrivateRecipientPicker) {
        this.PrivateRecipientPicker()
      }
      if (this.showMoreMenu) {
        this.MoreMenu()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MoreMenu() {
    Column() {
      Column() {
        Text('更多')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .margin({ bottom: 12 })

        // 角色记忆入口
        Row() {
          Text('🧠')
            .fontSize(20)
          Text('角色记忆')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .margin({ left: 12 })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
        }
        .width('100%')
        .padding(12)
        .onClick(() => {
          this.showMoreMenu = false;
          this.navigateToCharacterMemory();
        })
      }
      .width('88%')
      .padding(16)
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      // 点击遮罩关闭菜单
      this.showMoreMenu = false;
    })
  }

  /** 跳转到多人世界角色记忆页面 */
  private navigateToCharacterMemory(): void {
    if (this.viewModel === null) {
      promptAction.showToast({ message: '页面未就绪' });
      return;
    }
    const wid: string = this.viewModel!.worldId;
    const cid: string = this.viewModel!.chatId;
    const bid: string = this.viewModel!.branchId;
    if (wid.length === 0 || cid.length === 0 || bid.length === 0) {
      promptAction.showToast({ message: '会话信息缺失' });
      return;
    }
    router.pushUrl({
      url: 'pages/WorldCharacterMemoryPage',
      params: { worldId: wid, chatId: cid, branchId: bid }
    });
  }

  @Builder
  TopBar() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Column() {
          Text(this.viewModel !== null && this.viewModel!.world !== null
            ? this.viewModel!.world!.name
            : '多人世界')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row() {
            Text(this.viewModel !== null && this.viewModel!.currentScene !== null
              ? this.viewModel!.currentScene!.name
              : '无场景')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Text(' · ')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Text(this.viewModel !== null
              ? replyModeLabel(this.viewModel!.replyMode)
              : '')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          }
          .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 4 })

        // 更多按钮
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(22)
          .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          .padding(8)
          .onClick(() => {
            this.showMoreMenu = true;
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: this.statusBarHeight + 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // 在场头像组 + 切换按钮
      Row() {
        Scroll() {
          Row() {
            ForEach(this.presentMembers, (m: PresentMemberAvatar) => {
              Column() {
                Stack() {
                  CharacterImageView({
                    imageUri: m.avatarUri,
                    fallbackName: m.displayName,
                    imgWidth: 36,
                    imgHeight: 36,
                    imgBorderRadius: 18,
                    displayMode: 'thumbnail'
                  })
                  if (m.muted) {
                    Text('禁')
                      .fontSize(10)
                      .fontColor(Color.White)
                      .backgroundColor('#888888')
                      .borderRadius(8)
                      .padding({ left: 4, right: 4 })
                      .position({ right: 0, top: 0 })
                  }
                }
                .width(36)
                .height(36)

                Text(m.displayName)
                  .fontSize(10)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(48)
                  .margin({ top: 2 })
              }
              .margin({ right: 8 })
              .onClick(() => {
                if (this.viewModel !== null && this.viewModel!.replyMode === 'designated') {
                  this.viewModel!.setDesignatedCharacter(m.characterId);
                }
              })
            }, (m: PresentMemberAvatar) => m.characterId)
          }
          .padding({ left: 12, right: 12 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Button('模式')
          .fontSize(11)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .borderRadius(12)
          .height(28)
          .padding({ left: 8, right: 8 })
          .margin({ right: 4 })
          .onClick(() => {
            this.viewModel!.toggleReplyModePicker();
          })

        Button('场景')
          .fontSize(11)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .borderRadius(12)
          .height(28)
          .padding({ left: 8, right: 8 })
          .margin({ right: 4 })
          .onClick(() => {
            this.viewModel!.toggleScenePicker();
          })
      }
      .width('100%')
      .padding({ left: 4, right: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  MessageBubble(item: WorldChatMessageItem) {
    // 旁白消息(AI 生成, senderType='narrator'):居中显示
    if (item.senderType === 'narrator') {
      Column() {
        Text('旁白')
          .fontSize(11)
          .fontColor($r('app.color.chat_text_narrator'))
          .margin({ bottom: 4 })
        Column() {
          ChatRichText({
            content: item.message.content,
            senderType: 'narrator' as ChatSenderType,
            senderCharacterId: '',
            isStreaming: false,
            settings: this.chatTextStyle,
            selectable: true
          })
        }
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius(10)
        .padding(10)
        .width('100%')
      }
      .width('100%')
      .margin({ bottom: 12 })
    } else if (item.senderType === 'user') {
      // 用户消息:右对齐
      Row() {
        Blank()
        Column() {
          // v11 私聊/旁白标识(用户消息)
          if (item.message.visibility === 'private') {
            Text('私聊给: ' + this.getRecipientNames(item.message.recipientCharacterIds))
              .fontSize(10)
              .fontColor($r('app.color.chat_text_dialogue'))
              .backgroundColor($r('app.color.app_accent_surface'))
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ bottom: 4 })
              .textAlign(TextAlign.End)
          } else if (item.message.visibility === 'narrator') {
            Text('旁白动作')
              .fontSize(10)
              .fontColor($r('app.color.chat_text_narrator'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ bottom: 4 })
              .textAlign(TextAlign.End)
          }
          Text(item.displayName)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .margin({ bottom: 4 })
            .textAlign(TextAlign.End)
            .width('100%')
          Column() {
            ChatRichText({
              content: item.message.content,
              senderType: 'user' as ChatSenderType,
              senderCharacterId: '',
              isStreaming: false,
              settings: this.chatTextStyle,
              selectable: true
            })
          }
          .backgroundColor(item.message.visibility === 'private'
            ? $r('app.color.chat_text_dialogue')
            : item.message.visibility === 'narrator'
              ? $r('app.color.chat_text_narrator')
              : $r('app.color.app_accent'))
          .borderRadius(12)
          .padding(10)
        }
        .constraintSize({ maxWidth: '80%' })
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .margin({ bottom: 12 })
    } else {
      // 角色消息:左对齐 + 头像 + 名称
      Row() {
        Column() {
          CharacterImageView({
            imageUri: item.avatarUri,
            fallbackName: item.displayName,
            imgWidth: 36,
            imgHeight: 36,
            imgBorderRadius: 18,
            displayMode: 'thumbnail'
          })

          Text(item.displayName)
            .fontSize(11)
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(48)
            .margin({ top: 4 })
            .textAlign(TextAlign.Center)
        }
        .width(48)
        .alignItems(HorizontalAlign.Center)

        Column() {
          // v11 私聊标识(角色消息:私聊回复)
          if (item.message.visibility === 'private') {
            Text('私聊回复')
              .fontSize(10)
              .fontColor($r('app.color.chat_text_dialogue'))
              .backgroundColor($r('app.color.app_accent_surface'))
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ bottom: 4 })
          }
          Column() {
            ChatRichText({
              content: item.message.content,
              senderType: 'character' as ChatSenderType,
              senderCharacterId: item.senderCharacterId,
              isStreaming: false,
              settings: this.chatTextStyle,
              selectable: true
            })
          }
          .backgroundColor($r('app.color.app_surface_1'))
          .borderRadius(12)
          .padding(10)
        }
        .constraintSize({ maxWidth: '70%' })
        .margin({ left: 8, top: 16 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ bottom: 12 })
    }
  }

  /** 获取私聊目标角色名称列表(委托给 ViewModel) */
  private getRecipientNames(recipientCharacterIds: string[] | undefined): string {
    if (this.viewModel === null) {
      return '';
    }
    return this.viewModel!.getRecipientNames(recipientCharacterIds);
  }

  @Builder
  StreamingPreview() {
    Column() {
      Text('生成中...')
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 4 })
      Column() {
        ChatRichText({
          content: this.streamingPreview,
          senderType: 'assistant' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: true,
          settings: this.chatTextStyle,
          selectable: false
        })
      }
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius(10)
      .padding(10)
      .width('100%')
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  @Builder
  InputArea() {
    Column() {
      // v11 私聊:输入框上方显示当前发送范围状态
      if (this.viewModel !== null) {
        Row() {
          // 范围按钮(点击打开范围选择面板)
          Text(this.viewModel!.getScopeStatusText())
            .fontSize(12)
            .fontColor(this.viewModel!.sendScope === 'private' ? '#9B59B6'
              : this.viewModel!.sendScope === 'narrator' ? '#7F8C8D'
              : $r('sys.color.ohos_id_color_text_secondary'))
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 240 })
            .onClick(() => {
              this.viewModel!.toggleScopePicker();
            })

          // 私聊范围下:额外的目标角色管理按钮
          if (this.viewModel!.sendScope === 'private') {
            Text('选择角色')
              .fontSize(12)
              .fontColor('#9B59B6')
              .backgroundColor('rgba(155, 89, 182, 0.1)')
              .borderRadius(10)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .margin({ left: 6 })
              .onClick(() => {
                this.viewModel!.togglePrivateRecipientPicker();
              })
          }

          Blank()

          // 隐私边界提示(仅私聊范围显示)
          if (this.viewModel!.sendScope === 'private') {
            Text('🔒 私聊内容仅注入所选角色')
              .fontSize(10)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        TextArea({
          text: this.viewModel !== null ? this.viewModel!.inputText : '',
          placeholder: '输入消息...'
        })
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_text_field_bg'))
          .borderRadius(20)
          .layoutWeight(1)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .enabled(this.viewModel !== null && !this.viewModel!.isGenerating)
          .onChange((value: string) => {
            this.viewModel!.updateInput(value);
          })

        if (this.viewModel !== null && this.viewModel!.isGenerating) {
          Button('停止')
            .fontSize(13)
            .backgroundColor('#E74C3C')
            .fontColor(Color.White)
            .borderRadius(20)
            .height(40)
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .onClick(() => {
              this.viewModel!.stopGeneration();
            })
        } else {
          Button('发送')
            .fontSize(13)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .fontColor(Color.White)
            .borderRadius(20)
            .height(40)
            .padding({ left: 16, right: 16 })
            .margin({ left: 8 })
            .enabled(this.viewModel !== null && this.viewModel!.inputText.trim().length > 0)
            .onClick(() => {
              this.viewModel!.sendMessage();
              // 立即同步状态(isGenerating 等)
              this.syncState();
              // 延迟刷新(回调可能异步更新)
              setTimeout(() => {
                this.syncState();
                this.scrollToBottom();
              }, 100);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: 12,
      right: 12,
      top: 8,
      bottom: this.navigationBarHeight + 8
    })
  }

  @Builder
  ScopePicker() {
    Column() {
      Column() {
        Text('发送范围')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .margin({ bottom: 12 })

        ForEach([
          { scope: 'public' as SendScope, label: '公开发言', desc: '所有在场角色可见' } as ScopeItem,
          { scope: 'private' as SendScope, label: '私下交谈', desc: '仅所选目标角色可见' } as ScopeItem,
          { scope: 'narrator' as SendScope, label: '旁白动作', desc: '作为场景描述处理' } as ScopeItem
        ] as ScopeItem[], (item: ScopeItem) => {
          Row() {
            Column() {
              Text(item.label)
                .fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
              Text(item.desc)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Blank()
            if (this.viewModel!.sendScope === item.scope) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([$r('sys.color.ohos_id_color_emphasize')])
            }
          }
          .width('100%')
          .padding(12)
          .onClick(() => {
            this.viewModel!.setSendScope(item.scope);
            this.syncState();
          })
        }, (item: ScopeItem) => item.scope)

        Button('关闭')
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .borderRadius(20)
          .height(40)
          .padding({ left: 24, right: 24 })
          .margin({ top: 12 })
          .onClick(() => {
            this.viewModel!.toggleScopePicker();
          })
      }
      .width('88%')
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
  PrivateRecipientPicker() {
    Column() {
      Column() {
        Row() {
          Text('选择私聊目标角色')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .layoutWeight(1)
          Text(`已选 ${this.viewModel!.privateRecipientIds.length} 人`)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
        .width('100%')
        .margin({ bottom: 8 })

        Text('未被选择的角色不会知道私聊内容,也不能在后续回复、记忆或关系更新中使用该信息。')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .width('100%')
          .margin({ bottom: 12 })

        Scroll() {
          Column() {
            ForEach(this.presentMembers, (m: PresentMemberAvatar) => {
              // 静音角色不允许作为私聊目标
              if (!m.muted) {
                Row() {
                  CharacterImageView({
                    imageUri: m.avatarUri,
                    fallbackName: m.displayName,
                    imgWidth: 40,
                    imgHeight: 40,
                    imgBorderRadius: 20,
                    displayMode: 'thumbnail'
                  })
                  Text(m.displayName)
                    .fontSize(14)
                    .fontColor($r('sys.color.ohos_id_color_text_primary'))
                    .layoutWeight(1)
                    .margin({ left: 10 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.viewModel!.privateRecipientIds.indexOf(m.characterId) >= 0) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(18)
                      .fontColor([$r('sys.color.ohos_id_color_emphasize')])
                  }
                }
                .width('100%')
                .padding(10)
                .onClick(() => {
                  this.viewModel!.togglePrivateRecipient(m.characterId);
                  this.syncState();
                })
              }
            }, (m: PresentMemberAvatar) => m.characterId + (this.viewModel!.privateRecipientIds.indexOf(m.characterId) >= 0 ? '_on' : '_off'))
          }
          .width('100%')
        }
        .layoutWeight(1)
        .constraintSize({ maxHeight: 400 })

        Row() {
          Button('清空')
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .borderRadius(20)
            .height(40)
            .padding({ left: 20, right: 20 })
            .layoutWeight(1)
            .onClick(() => {
              this.viewModel!.clearPrivateRecipients();
              this.syncState();
            })

          Button('确认')
            .fontSize(14)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .fontColor(Color.White)
            .borderRadius(20)
            .height(40)
            .padding({ left: 20, right: 20 })
            .margin({ left: 12 })
            .layoutWeight(1)
            .enabled(this.viewModel!.privateRecipientIds.length > 0)
            .onClick(() => {
              this.viewModel!.confirmPrivateRecipients();
              this.syncState();
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('88%')
      .constraintSize({ maxHeight: '75%' })
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
  ReplyModePicker() {
    Column() {
      Column() {
        Text('回复模式')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .margin({ bottom: 12 })

        ForEach([
          { mode: 'auto_director' as WorldReplyMode, label: '自动导演', desc: '系统选择 1-2 位合适角色' } as ReplyModeItem,
          { mode: 'designated' as WorldReplyMode, label: '指定角色', desc: '用户选择下一位回复者' } as ReplyModeItem,
          { mode: 'all_respond' as WorldReplyMode, label: '全员回应', desc: '所有在场未静音角色依次回应' } as ReplyModeItem,
          { mode: 'narrator_only' as WorldReplyMode, label: '仅旁白', desc: '只生成场景描述' } as ReplyModeItem
        ] as ReplyModeItem[], (item: ReplyModeItem) => {
          Row() {
            Column() {
              Text(item.label)
                .fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
              Text(item.desc)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Blank()
            if (this.viewModel!.replyMode === item.mode) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([$r('sys.color.ohos_id_color_emphasize')])
            }
          }
          .width('100%')
          .padding(12)
          .onClick(() => {
            this.viewModel!.setReplyMode(item.mode).then(() => {
              this.syncState();
            });
          })
        }, (item: ReplyModeItem) => item.mode)

        Button('关闭')
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .borderRadius(20)
          .height(40)
          .padding({ left: 24, right: 24 })
          .margin({ top: 12 })
          .onClick(() => {
            this.viewModel!.toggleReplyModePicker();
          })
      }
      .width('88%')
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
  DesignatedPicker() {
    Column() {
      Column() {
        Text('选择回复角色')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .margin({ bottom: 12 })

        Scroll() {
          Column() {
            ForEach(this.presentMembers, (m: PresentMemberAvatar) => {
              Row() {
                CharacterImageView({
                  imageUri: m.avatarUri,
                  fallbackName: m.displayName,
                  imgWidth: 40,
                  imgHeight: 40,
                  imgBorderRadius: 20,
                  displayMode: 'thumbnail'
                })
                Text(m.displayName)
                  .fontSize(14)
                  .fontColor($r('sys.color.ohos_id_color_text_primary'))
                  .layoutWeight(1)
                  .margin({ left: 10 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.viewModel!.designatedCharacterId === m.characterId) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(18)
                    .fontColor([$r('sys.color.ohos_id_color_emphasize')])
                }
              }
              .width('100%')
              .padding(10)
              .onClick(() => {
                this.viewModel!.setDesignatedCharacter(m.characterId);
              })
            }, (m: PresentMemberAvatar) => m.characterId)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .constraintSize({ maxHeight: 400 })

        Button('关闭')
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .borderRadius(20)
          .height(40)
          .padding({ left: 24, right: 24 })
          .margin({ top: 12 })
          .onClick(() => {
            this.viewModel!.toggleDesignatedPicker();
          })
      }
      .width('88%')
      .constraintSize({ maxHeight: '70%' })
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
  ScenePicker() {
    Column() {
      Column() {
        Text('切换场景')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
          .margin({ bottom: 12 })

        Scroll() {
          Column() {
            ForEach(this.scenes, (s: WorldScene) => {
              Row() {
                Column() {
                  Text(s.name)
                    .fontSize(14)
                    .fontColor($r('sys.color.ohos_id_color_text_primary'))
                  Text(s.description.length > 0
                    ? s.description.substring(0, 60)
                    : '暂无描述')
                    .fontSize(12)
                    .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Blank()
                if (this.viewModel!.currentSceneId === s.id) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(18)
                    .fontColor([$r('sys.color.ohos_id_color_emphasize')])
                }
              }
              .width('100%')
              .padding(10)
              .onClick(() => {
                this.viewModel!.setCurrentScene(s.id).then(() => {
                  this.syncState();
                });
              })
            }, (s: WorldScene) => s.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .constraintSize({ maxHeight: 400 })

        Button('关闭')
          .fontSize(14)
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .borderRadius(20)
          .height(40)
          .padding({ left: 24, right: 24 })
          .margin({ top: 12 })
          .onClick(() => {
            this.viewModel!.toggleScenePicker();
          })
      }
      .width('88%')
      .constraintSize({ maxHeight: '70%' })
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

  private scrollToBottom(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  onPageHide(): void {
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
    }
  }
}
