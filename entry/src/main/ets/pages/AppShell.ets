/**
 * AppShell 应用外壳(UI-1 HDS Immersive Bottom Tabs App Shell)
 *
 * 作为 ArkTavern 的根应用外壳,使用 HDS 沉浸光感悬浮底部页签提供四个一级 Tab:
 * 1. 角色卡 - CharacterRootView
 * 2. 对话记录 - ChatSessionRootView
 * 3. 市场 - MarketPlaceholderView
 * 4. 设置 - SettingsRootView
 *
 * 设计:
 * - 顶层 Navigation(pathStack)包裹 HdsTabs,二级页面通过 NavPathStack 推入
 * - 二级页面(ChatPage 等)作为 NavDestination 自动覆盖 HdsTabs,实现"进入二级页面隐藏底部页签"
 * - 底部页签使用 @kit.UIDesignKit 的 HdsTabs + barFloatingStyle + systemMaterialEffect
 * - 启用系统自适应沉浸光感材质(materialType: IMMERSIVE, materialLevel: EXQUISITE)
 *
 * 不修改:
 * - 业务 Service / Repository / 数据库
 * - ChatPage / CharacterListPage 等已有页面
 * - NavPathStack 路由命名
 */

import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { ChatPage } from './ChatPage';
import { CharacterListPage } from './CharacterListPage';
import { CharacterEditPage } from './CharacterEditPage';
import { LorebookPage } from './LorebookPage';
import { ModelSettingsPage } from './ModelSettingsPage';
import { ModelConfigEditPage } from './ModelConfigEditPage';
import { AppSettingsPage } from './AppSettingsPage';
import { PromptPresetListPage } from './PromptPresetListPage';
import { PromptPresetEditPage } from './PromptPresetEditPage';
import { BranchMapPage } from './BranchMapPage';
import { RealSsePocPage } from './RealSsePocPage';
import { AppServices } from '../services/AppServices';
import { CharacterRootView } from './tabs/CharacterRootView';
import { ChatSessionRootView } from './tabs/ChatSessionRootView';
import { MarketPlaceholderView } from './tabs/MarketPlaceholderView';
import { SettingsRootView } from './tabs/SettingsRootView';

const TAG: string = 'AppShell';

/**
 * 应用外壳组件。
 *
 * 由 Index.ets 作为 @Entry 持有,内部:
 * 1. 顶层 Navigation(pathStack),承载二级页面路由
 * 2. Navigation 根内容为 HdsTabs,提供四个一级 Tab
 * 3. HdsTabs 使用 barFloatingStyle + systemMaterialEffect 实现沉浸光感悬浮底部页签
 */
@Component
export struct AppShell {
  /** 全局 NavPathStack,用于二级页面跳转(ChatPage / LorebookPage / ModelSettingsPage 等) */
  pathStack: NavPathStack = new NavPathStack();
  /** HdsTabs 控制器,用于编程式切换 Tab */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 当前选中的 Tab 索引(0:角色卡, 1:对话记录, 2:市场, 3:设置) */
  @State selectedTab: number = 0;

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
    } else if (name === 'RealSsePocPage') {
      RealSsePocPage()
    }
  }

  build() {
    Navigation(this.pathStack) {
      HdsTabs({ controller: this.tabsController }) {
        // ===== Tab 1: 角色卡 =====
        TabContent() {
          CharacterRootView({ pathStack: this.pathStack })
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.person')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.person')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_characters')))

        // ===== Tab 2: 对话记录 =====
        TabContent() {
          ChatSessionRootView({ pathStack: this.pathStack })
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.bell')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.bell')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_sessions')))

        // ===== Tab 3: 市场 =====
        TabContent() {
          MarketPlaceholderView()
        }
        .tabBar(new BottomTabBarStyle({
          normal: new SymbolGlyphModifier($r('sys.symbol.star')).fontColor(['#667085']),
          selected: new SymbolGlyphModifier($r('sys.symbol.star')).fontColor(['#2F73FF'])
        }, $r('app.string.tab_market')))

        // ===== Tab 4: 设置 =====
        TabContent() {
          SettingsRootView({ pathStack: this.pathStack })
        }
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
    .backgroundColor($r('app.color.app_bg'))
  }
}
