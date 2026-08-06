/**
 * WorldDesignTokens 世界模式 UI 设计令牌(W-UI-1A)
 *
 * 集中定义世界模式纯 UI 常量,供 Canvas 绘制、渐变、阴影等
 * 不便使用 $r() 资源引用的场景使用。
 *
 * 颜色值与 resources/base/element/color.json 和 resources/dark/element/color.json
 * 中的 world_* 条目保持一致(世界模式始终深色酒馆质感,不随系统主题切换)。
 *
 * 不依赖 Repository / Service / AppServices / 数据库。
 */

/** 世界模式纯色常量(用于 Canvas / 渐变 / 阴影,与 color.json world_* 对应) */
export class WorldColors {
  static readonly BG: string = '#1A1510';
  static readonly SURFACE_1: string = '#2A2118';
  static readonly SURFACE_2: string = '#3A2F22';
  static readonly SURFACE_ELEVATED: string = '#332A1E';
  static readonly BORDER: string = '#4A3D2E';
  static readonly TEXT_PRIMARY: string = '#F5E6CA';
  static readonly TEXT_SECONDARY: string = '#B8A88A';
  static readonly TEXT_TERTIARY: string = '#8A7B62';
  static readonly GOLD: string = '#D4A843';
  static readonly ON_GOLD: string = '#1A1510';
  static readonly GOLD_SURFACE: string = '#3D3220';
  static readonly SUCCESS: string = '#6B9E47';
  static readonly WARNING: string = '#D49B43';
  static readonly ERROR: string = '#C45A4A';
  static readonly INFO: string = '#5B8AB5';
  static readonly GRID_LINE: string = '#2E2519';
  static readonly MAP_BG: string = '#15110C';
  static readonly EDGE: string = '#6B5B42';
  static readonly EDGE_DISABLED: string = '#4A3D2E';
  static readonly SCRIM: string = '#99000000';
}

/** 世界模式布局常量(vp/fp,与 float.json world_* 对应) */
export class WorldMetrics {
  static readonly RADIUS_CARD: number = 16;
  static readonly RADIUS_CHIP: number = 8;
  static readonly RADIUS_BUTTON: number = 12;
  static readonly PAGE_PADDING: number = 16;
  static readonly CARD_SPACING: number = 12;
  static readonly TOP_NAV_HEIGHT: number = 52;
  static readonly BOTTOM_BAR_HEIGHT: number = 64;
  static readonly FONT_DISPLAY: number = 28;
  static readonly FONT_TITLE: number = 22;
  static readonly FONT_SECTION: number = 14;
  static readonly FONT_BODY: number = 15;
  static readonly FONT_CAPTION: number = 12;
  static readonly FONT_MICRO: number = 10;
  static readonly FAB_SIZE: number = 56;
  static readonly TOOLBAR_ICON: number = 20;
  static readonly NODE_WIDTH: number = 140;
  static readonly NODE_HEIGHT: number = 80;
}

/** 世界模式等距网格绘制常量(Canvas 用) */
export class WorldGrid {
  static readonly CELL_SIZE: number = 40;
  static readonly LINE_WIDTH: number = 1;
  static readonly ANGLE: number = 30;
}
