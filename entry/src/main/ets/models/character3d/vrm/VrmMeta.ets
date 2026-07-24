/**
 * VrmMeta VRM 元信息
 *
 * T-4.0: VRM First Architecture
 *
 * 统一承载 VRM 0.x 和 VRM 1.0 的元信息。
 * VRM 0.x 与 1.0 字段名不同,这里映射为统一结构,缺失字段为 null。
 *
 * 参考:
 * - VRM 1.0: https://vrm.dev/vrm1/spec/core/#meta
 * - VRM 0.x: https://vrm.dev/vrm0/unihumanoid.html#vrm-meta
 */

import { VrmVersion } from './VrmVersion';

/**
 * 商业用途许可(VRM 1.0)。
 */
export enum VrmCommercialUsage {
  /** 个人非盈利 */
  PersonalNonProfit = 'personalNonProfit',
  /** 个人盈利 */
  PersonalProfit = 'personalProfit',
  /** 企业使用 */
  Corporation = 'corporation'
}

/**
 * 修改许可(VRM 1.0 modification 字段)。
 */
export enum VrmModification {
  /** 禁止修改 */
  Prohibited = 'prohibited',
  /** 允许修改 */
  AllowModification = 'allowModification',
  /** 允许修改并允许再分发 */
  AllowModificationRedistribution = 'allowModificationRedistribution'
}

/**
 * 署名要求(VRM 1.0 creditNotation 字段)。
 */
export enum VrmCreditNotation {
  /** 必须署名 */
  Required = 'required',
  /** 不需要署名 */
  Unnecessary = 'unnecessary'
}

/**
 * VRM 0.x 允许用户类型。
 */
export enum Vrm0AllowedUser {
  OnlyAuthor = 'OnlyAuthor',
  ExplicitlyLicensedPerson = 'ExplicitlyLicensedPerson',
  Everyone = 'Everyone'
}

/**
 * VRM 0.x 三态许可(暴力/性/商业)。
 */
export enum Vrm0UsageFlag {
  Allow = 'Allow',
  Disallow = 'Disallow'
}

/**
 * VRM 元信息(统一结构)。
 *
 * 必填字段在 VRM 1.0 规范中为 name/authors/version。
 * VRM 0.x 必填字段为 title/author/version。
 */
export interface VrmMeta {
  /** VRM 版本 */
  version: VrmVersion;
  /** 元信息版本字符串(如 "1.0" / "0.51") */
  metaVersion: string;
  /** 模型名称(VRM1: name, VRM0: title) */
  name: string;
  /** 作者列表(VRM1: authors[], VRM0: author 字符串) */
  authors: string[];
  /** 版权信息(VRM1: copyrightInformation) */
  copyrightInformation: string | null;
  /** 联系方式 */
  contactInformation: string | null;
  /** 参考资料 URL 列表(VRM1: references[]) */
  references: string[];
  /** 缩略图在 gltf.images 中的索引(无则为 -1) */
  thumbnailImageIndex: number;
  /** 其他许可 URL */
  otherLicenseUrl: string | null;
  /** 其他权限 URL(VRM0 专有) */
  otherPermissionUrl: string | null;
  /** 许可证名称(VRM0 专有,如 "Redistribution_Prohibited") */
  licenseName: string | null;

  // === 使用许可(统一三态) ===
  /** 商业用途许可(VRM1: commercialUsage 枚举;VRM0: commercialUssageName) */
  commercialUsage: VrmCommercialUsage | null;
  /** 允许暴力内容 */
  allowExcessivelyViolentUsage: boolean;
  /** 允许性相关内容 */
  allowExcessivelySexualUsage: boolean;
  /** 允许政治/宗教用途(VRM1 专有) */
  allowPoliticalOrReligiousUsage: boolean;
  /** 允许反社会/仇恨用途(VRM1 专有) */
  allowAntisocialOrHateUsage: boolean;

  // === 署名与分发(VRM1 专有) ===
  /** 署名要求 */
  creditNotation: VrmCreditNotation | null;
  /** 允许再分发 */
  allowRedistribution: boolean;
  /** 修改许可 */
  modification: VrmModification | null;

  // === VRM 0.x 兼容字段 ===
  /** 允许用户类型(VRM0 专有) */
  allowedUser: Vrm0AllowedUser | null;

  /** 原始 meta 哈希(用于校验,来自完整 meta JSON) */
  metaHash: string;
}

/**
 * 创建空 VRM 元信息(用于非 VRM 或解析失败时)。
 */
export function createEmptyVrmMeta(version: VrmVersion): VrmMeta {
  return {
    version: version,
    metaVersion: '',
    name: '',
    authors: [],
    copyrightInformation: null,
    contactInformation: null,
    references: [],
    thumbnailImageIndex: -1,
    otherLicenseUrl: null,
    otherPermissionUrl: null,
    licenseName: null,
    commercialUsage: null,
    allowExcessivelyViolentUsage: false,
    allowExcessivelySexualUsage: false,
    allowPoliticalOrReligiousUsage: false,
    allowAntisocialOrHateUsage: false,
    creditNotation: null,
    allowRedistribution: false,
    modification: null,
    allowedUser: null,
    metaHash: ''
  };
}
