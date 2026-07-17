/**
 * 数据库迁移框架
 *
 * 职责:
 * - 定义单步迁移接口
 * - 维护已注册的迁移列表
 * - 计算从 currentVersion 到 targetVersion 的迁移路径
 * - 不实现 destructive migration(禁止 DROP TABLE)
 *
 * 限制:
 * - 不支持降级(currentVersion > targetVersion 抛错)
 * - 不支持跳版本(必须逐版本)
 * - 不修改入参 migrations 数组
 */

import { relationalStore } from '@kit.ArkData';

export interface DatabaseMigration {
  readonly fromVersion: number;
  readonly toVersion: number;
  migrate(store: relationalStore.RdbStore): Promise<void>;
}

export interface MigrationPath {
  readonly fromVersion: number;
  readonly toVersion: number;
  readonly steps: DatabaseMigration[];
}

export function buildMigrationPath(
  currentVersion: number,
  targetVersion: number,
  migrations: ReadonlyArray<DatabaseMigration>
): MigrationPath {
  if (currentVersion === targetVersion) {
    return { fromVersion: currentVersion, toVersion: targetVersion, steps: [] };
  }
  if (currentVersion > targetVersion) {
    throw new Error('downgrade not supported');
  }

  const sorted: DatabaseMigration[] = [...migrations].sort(
    (a, b) => a.fromVersion - b.fromVersion
  );

  const steps: DatabaseMigration[] = [];
  let expected: number = currentVersion;
  for (let i = 0; i < sorted.length; i++) {
    const m: DatabaseMigration = sorted[i];
    if (m.fromVersion !== expected) {
      continue;
    }
    if (m.toVersion > targetVersion) {
      continue;
    }
    steps.push(m);
    expected = m.toVersion;
    if (expected === targetVersion) {
      break;
    }
  }

  if (expected !== targetVersion) {
    throw new Error(`no migration path from ${currentVersion} to ${targetVersion}`);
  }

  return { fromVersion: currentVersion, toVersion: targetVersion, steps };
}

export function isMigrationRegistryValid(
  migrations: ReadonlyArray<DatabaseMigration>
): boolean {
  if (migrations.length === 0) {
    return true;
  }
  const seen: Set<string> = new Set();
  for (let i = 0; i < migrations.length; i++) {
    const m: DatabaseMigration = migrations[i];
    if (m.fromVersion >= m.toVersion) {
      return false;
    }
    const key: string = `${m.fromVersion}->${m.toVersion}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
  }
  return true;
}
