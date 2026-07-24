/**
 * VrmMetaExtractor VRM 元信息解析器
 *
 * T-4.0: VRM First Architecture
 *
 * 解析 VRM 1.0 的 VRMC_vrm.meta 和 VRM 0.x 的 VRM.meta。
 * 将两种 schema 映射为统一的 VrmMeta 结构。
 */

import { VrmVersion } from '../models/character3d/vrm/VrmVersion';
import {
  VrmMeta,
  VrmCommercialUsage,
  VrmModification,
  VrmCreditNotation,
  Vrm0AllowedUser,
  createEmptyVrmMeta
} from '../models/character3d/vrm/VrmMeta';
import {
  getObject,
  getString,
  getBoolean,
  getStringArray,
  getNumber,
  getObjectEntries
} from './VrmExtensionParser';

/**
 * 解析 VRM 元信息。
 *
 * @param version VRM 版本
 * @param vrmcVrm VRMC_vrm 扩展对象(VRM 1.0,null 则查 vrm0Extension)
 * @param vrm0Extension VRM 扩展对象(VRM 0.x)
 * @returns VRM 元信息
 */
export function extractVrmMeta(
  version: VrmVersion,
  vrmcVrm: Record<string, Object> | null,
  vrm0Extension: Record<string, Object> | null
): VrmMeta {
  if (version === VrmVersion.Vrm1 && vrmcVrm !== null) {
    return extractVrm1Meta(vrmcVrm);
  }
  if (version === VrmVersion.Vrm0x && vrm0Extension !== null) {
    return extractVrm0Meta(vrm0Extension);
  }
  return createEmptyVrmMeta(version);
}

/**
 * 解析 VRM 1.0 元信息(VRMC_vrm.meta)。
 */
function extractVrm1Meta(vrmcVrm: Record<string, Object>): VrmMeta {
  const metaObj: Record<string, Object> | null = getObject(vrmcVrm, 'meta');
  if (metaObj === null) {
    return createEmptyVrmMeta(VrmVersion.Vrm1);
  }

  const meta: VrmMeta = createEmptyVrmMeta(VrmVersion.Vrm1);
  meta.metaVersion = getString(metaObj, 'version', '1.0');
  meta.name = getString(metaObj, 'name');
  meta.authors = getStringArray(metaObj, 'authors');
  meta.copyrightInformation = getString(metaObj, 'copyrightInformation');
  if (meta.copyrightInformation.length === 0) {
    meta.copyrightInformation = null;
  }
  meta.contactInformation = getString(metaObj, 'contactInformation');
  if (meta.contactInformation.length === 0) {
    meta.contactInformation = null;
  }
  meta.references = getStringArray(metaObj, 'references');
  meta.thumbnailImageIndex = getNumber(metaObj, 'thumbnailImage', -1);
  meta.otherLicenseUrl = getString(metaObj, 'otherLicenseUrl');
  if (meta.otherLicenseUrl.length === 0) {
    meta.otherLicenseUrl = null;
  }

  // 使用许可
  meta.allowExcessivelyViolentUsage = getBoolean(metaObj, 'allowExcessivelyViolentUsage');
  meta.allowExcessivelySexualUsage = getBoolean(metaObj, 'allowExcessivelySexualUsage');
  meta.allowPoliticalOrReligiousUsage = getBoolean(metaObj, 'allowPoliticalOrReligiousUsage');
  meta.allowAntisocialOrHateUsage = getBoolean(metaObj, 'allowAntisocialOrHateUsage');
  meta.allowRedistribution = getBoolean(metaObj, 'allowRedistribution');

  // 商业用途枚举
  const commercialStr: string = getString(metaObj, 'commercialUsage');
  meta.commercialUsage = parseCommercialUsage(commercialStr);

  // 修改许可枚举
  const modStr: string = getString(metaObj, 'modification');
  meta.modification = parseModification(modStr);

  // 署名要求枚举
  const creditStr: string = getString(metaObj, 'creditNotation');
  meta.creditNotation = parseCreditNotation(creditStr);

  return meta;
}

/**
 * 解析 VRM 0.x 元信息(VRM.meta)。
 */
function extractVrm0Meta(vrm0Ext: Record<string, Object>): VrmMeta {
  const metaObj: Record<string, Object> | null = getObject(vrm0Ext, 'meta');
  if (metaObj === null) {
    return createEmptyVrmMeta(VrmVersion.Vrm0x);
  }

  const meta: VrmMeta = createEmptyVrmMeta(VrmVersion.Vrm0x);
  meta.metaVersion = getString(metaObj, 'version', '0.51');
  meta.name = getString(metaObj, 'title');
  // VRM0 author 是单个字符串,转为数组
  const authorStr: string = getString(metaObj, 'author');
  if (authorStr.length > 0) {
    meta.authors = [authorStr];
  }
  meta.contactInformation = getString(metaObj, 'contactInformation');
  if (meta.contactInformation.length === 0) {
    meta.contactInformation = null;
  }
  // VRM0 reference 是单个字符串
  const refStr: string = getString(metaObj, 'reference');
  if (refStr.length > 0) {
    meta.references = [refStr];
  }
  meta.thumbnailImageIndex = getNumber(metaObj, 'thumbnail', -1);
  meta.otherLicenseUrl = getString(metaObj, 'otherLicenseUrl');
  if (meta.otherLicenseUrl.length === 0) {
    meta.otherLicenseUrl = null;
  }
  meta.otherPermissionUrl = getString(metaObj, 'otherPermissionUrl');
  if (meta.otherPermissionUrl.length === 0) {
    meta.otherPermissionUrl = null;
  }
  meta.licenseName = getString(metaObj, 'licenseName');
  if (meta.licenseName.length === 0) {
    meta.licenseName = null;
  }

  // VRM0 使用许可(字符串枚举,值如 "Allow"/"Disallow")
  meta.allowExcessivelyViolentUsage = getString(metaObj, 'violentUssageName') === 'Allow';
  meta.allowExcessivelySexualUsage = getString(metaObj, 'sexualUssageName') === 'Allow';

  // VRM0 商业用途(commercialUssageName: "Allow"/"Disallow")
  // 映射:Allow → PersonalNonProfit(0.x 不区分盈利,保守映射),Disallow → null
  const commercialStr: string = getString(metaObj, 'commercialUssageName');
  if (commercialStr === 'Allow') {
    meta.commercialUsage = VrmCommercialUsage.PersonalNonProfit;
  }

  // VRM0 允许用户类型
  const allowedUserStr: string = getString(metaObj, 'allowedUserName');
  meta.allowedUser = parseVrm0AllowedUser(allowedUserStr);

  // VRM0 无 creditNotation / modification / redistribution 字段
  // 根据 licenseName 推断 modification
  if (meta.licenseName !== null) {
    if (meta.licenseName.indexOf('Redistribution_Prohibited') >= 0) {
      meta.modification = VrmModification.Prohibited;
      meta.allowRedistribution = false;
    } else if (meta.licenseName.indexOf('CC0') >= 0) {
      meta.modification = VrmModification.AllowModificationRedistribution;
      meta.allowRedistribution = true;
    }
  }

  return meta;
}

/**
 * 解析商业用途枚举。
 */
function parseCommercialUsage(value: string): VrmCommercialUsage | null {
  if (value === VrmCommercialUsage.PersonalNonProfit) {
    return VrmCommercialUsage.PersonalNonProfit;
  }
  if (value === VrmCommercialUsage.PersonalProfit) {
    return VrmCommercialUsage.PersonalProfit;
  }
  if (value === VrmCommercialUsage.Corporation) {
    return VrmCommercialUsage.Corporation;
  }
  return null;
}

/**
 * 解析修改许可枚举。
 */
function parseModification(value: string): VrmModification | null {
  if (value === VrmModification.Prohibited) {
    return VrmModification.Prohibited;
  }
  if (value === VrmModification.AllowModification) {
    return VrmModification.AllowModification;
  }
  if (value === VrmModification.AllowModificationRedistribution) {
    return VrmModification.AllowModificationRedistribution;
  }
  return null;
}

/**
 * 解析署名要求枚举。
 */
function parseCreditNotation(value: string): VrmCreditNotation | null {
  if (value === VrmCreditNotation.Required) {
    return VrmCreditNotation.Required;
  }
  if (value === VrmCreditNotation.Unnecessary) {
    return VrmCreditNotation.Unnecessary;
  }
  return null;
}

/**
 * 解析 VRM 0.x 允许用户类型。
 */
function parseVrm0AllowedUser(value: string): Vrm0AllowedUser | null {
  if (value === Vrm0AllowedUser.OnlyAuthor) {
    return Vrm0AllowedUser.OnlyAuthor;
  }
  if (value === Vrm0AllowedUser.ExplicitlyLicensedPerson) {
    return Vrm0AllowedUser.ExplicitlyLicensedPerson;
  }
  if (value === Vrm0AllowedUser.Everyone) {
    return Vrm0AllowedUser.Everyone;
  }
  return null;
}
