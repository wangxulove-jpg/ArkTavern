/**
 * Index 方舟酒馆入口(UI-1 HDS Immersive Bottom Tabs App Shell)
 *
 * 作为 @Entry 直接持有 Navigation + HdsTabs 外壳:
 * - 顶层 Navigation(pathStack)包裹 HdsTabs
 * - HdsTabs 提供四个一级 Tab:角色卡 / 对话记录 / 市场 / 设置
 * - barFloatingStyle + systemMaterialEffect 启用沉浸光感材质
 * - 二级页面(ChatPage / CharacterListPage 等)通过 NavPathStack 推入,
 *   自动覆盖 HdsTabs,实现"进入二级页面隐藏底部页签"
 *
 * 沉浸式策略:
 * - EntryAbility 设置窗口透明背景 + 状态栏透明 + setWindowLayoutFullScreen(true)
 * - 本 @Entry 根容器不设 backgroundColor,让窗口透明背景透出系统壁纸
 * - Navigation / HdsTabs / TabContent 全部显式 backgroundColor(Color.Transparent)
 *   避免中间层默认背景形成"色块"挡住壁纸
 * - 各页面浮层(顶栏/输入栏)用半透明背景叠加在内容之上
 *
 * 不修改:
 * - 业务 Service / Repository / 数据库
 * - NavPathStack 路由命名(由本文件 pageMap 维护)
 * - 其他二级页面
 */

import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { ChatPage } from './ChatPage';
import { CharacterListPage } from './CharacterListPage';
import { CharacterEditPage } from './CharacterEditPage';
import { AddCharacterPage } from './AddCharacterPage';
import { LorebookPage } from './LorebookPage';
import { ModelSettingsPage } from './ModelSettingsPage';
import { ModelConfigEditPage } from './ModelConfigEditPage';
import { AppSettingsPage } from './AppSettingsPage';
import { PromptPresetListPage } from './PromptPresetListPage';
import { PromptPresetEditPage } from './PromptPresetEditPage';
import { BranchMapPage } from './BranchMapPage';
import { AppServices } from '../services/AppServices';
import { CharacterRootView } from './tabs/CharacterRootView';
import { ChatSessionRootView } from './tabs/ChatSessionRootView';
import { MarketPlaceholderView } from './tabs/MarketPlaceholderView';
import { SettingsRootView } from './tabs/SettingsRootView';

@Entry
@Component
struct Index {
  /** 全局 NavPathStack,用于二级页面跳转(ChatPage / LorebookPage / ModelSettingsPage 等) */
  pathStack: NavPathStack = new NavPathStack();
  /** HdsTabs 控制器,用于编程式切换 Tab */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 当前选中的 Tab 索引(0:角色卡, 1:对话记录, 2:市场, 3:设置) */
  @State selectedTab: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      // 确保全局 Service 已就绪(数据库、Preferences 等)
      await AppServices.whenReady();
    } catch (e) {
      // 各 RootView 会处理自己的初始化错误,此处仅确保 AppServices 启动
    }
  }

  /**
   * NavDestination 页面构建器,根据 name 映射到对应页面组件。
   * 二级页面推入时会自动覆盖 HdsTabs,实现"隐藏底部页签"。
   */
  @Builder
  pageMap(name: string) {
    if (name === 'ChatPage') {
      ChatPage()
    } else if (name === 'CharacterListPage') {
      CharacterListPage()
    } else if (name === 'CharacterEditPage') {
      CharacterEditPage()
    } else if (name === 'AddCharacterPage') {
      AddCharacterPage()
    } else if (name === 'LorebookPage') {
      LorebookPage()
    } else if (name === 'ModelSettingsPage') {
      ModelSettingsPage()
    } else if (name === 'ModelConfigEditPage') {
      ModelConfigEditPage()
    } else if (name === 'AppSettingsPage') {
      AppSettingsPage()
    } else if (name === 'PromptPresetListPage') {
      PromptPresetListPage()
    } else if (name === 'PromptPresetEditPage') {
      PromptPresetEditPage()
    } else if (name === 'BranchMapPage') {
      BranchMapPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      HdsTabs({ controller: this.tabsController }) {
        // ===== Tab 1: 角色卡 =====
        TabContent() {
          CharacterRootView({ pathStack: this.pathStack })
        }
        .backgroundColor(Color.Transparent)
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.person')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.person')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_characters')))

        // ===== Tab 2: 对话记录 =====
        TabContent() {
          ChatSessionRootView({ pathStack: this.pathStack })
        }
        .backgroundColor(Color.Transparent)
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.bell')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.bell')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_sessions')))

        // ===== Tab 3: 市场 =====
        TabContent() {
          MarketPlaceholderView()
        }
        .backgroundColor(Color.Transparent)
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.star')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.star')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_market')))

        // ===== Tab 4: 设置 =====
        TabContent() {
          SettingsRootView({ pathStack: this.pathStack })
        }
        .backgroundColor(Color.Transparent)
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.exposure')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.exposure')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_settings')))
      }
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .vertical(false)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .barFloatingStyle({
        barWidth: {
          smallWidth: 320,
          mediumWidth: 360,
          largeWidth: 420
        },
        barBottomMargin: 24,
        gradientMask: {
          maskColor: '#CCF1F3F5',
          maskHeight: 64
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      })
      .onChange((index: number) => {
        this.selectedTab = index;
      })
    }
    .navDestination(this.pageMap)
    .hideTitleBar(true)
    // 显式透明:Navigation 自身有默认背景,不通过 backgroundColor 属性覆盖会形成
    // "中间层色块"挡住 EntryAbility 窗口透明背景,状态栏区域看起来被浅色背景挡住。
    // Color.Transparent 强制让 Navigation 不绘制自身背景,让窗口透明背景直接透出系统壁纸。
    .backgroundColor(Color.Transparent)
    // expandSafeArea 让 Navigation 范围扩展到状态栏和底部手势区,
    // 配合窗口透明背景实现壁纸从状态栏区域透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
