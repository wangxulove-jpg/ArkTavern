/**
 * VrmVersion VRM 版本标识
 *
 * T-4.0: VRM First Architecture
 *
 * VRM 有两个主版本系列:
 * - VRM 0.x: 早期版本,使用顶层 `VRM` 扩展(已弃用但需兼容)
 * - VRM 1.0: 当前版本,使用 `VRMC_vrm` / `VRMC_springBone` / `VRMC_materials_mtoon` 等扩展
 *
 * 参考:
 * - VRM 0.x: https://vrm.dev/vrm0/
 * - VRM 1.0: https://vrm.dev/vrm1/
 */

/**
 * VRM 版本枚举。
 */
export enum VrmVersion {
  /** 非 VRM 文件 */
  NonVrm = 'NonVrm',
  /** VRM 0.x(顶层 VRM 扩展) */
  Vrm0x = 'Vrm0x',
  /** VRM 1.0(VRMC_vrm 扩展) */
  Vrm1 = 'Vrm1'
}

/**
 * 判断版本是否为 VRM(0.x 或 1.0)。
 */
export function isVrm(version: VrmVersion): boolean {
  return version === VrmVersion.Vrm0x || version === VrmVersion.Vrm1;
}
