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
import { V1_TO_V2_STATEMENTS, V2_TO_V3_STATEMENTS, V3_TO_V4_STATEMENTS } from './DatabaseSchema';

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

/**
 * 创建 v1→v2 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 lorebooks 表
 * 2. 创建 lorebook_entries 表
 * 3. 创建新索引
 * 4. 任一失败全部回滚,不影响旧数据
 */
export function createV1ToV2Migration(): DatabaseMigration {
  return new V1ToV2Migration();
}

class V1ToV2Migration implements DatabaseMigration {
  readonly fromVersion: number = 1;
  readonly toVersion: number = 2;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V1_TO_V2_STATEMENTS.length; i++) {
      await store.executeSql(V1_TO_V2_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v2→v3 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 prompt_presets 表
 * 2. 创建相关索引
 * 3. 任一失败全部回滚,不影响旧数据
 */
export function createV2ToV3Migration(): DatabaseMigration {
  return new V2ToV3Migration();
}

class V2ToV3Migration implements DatabaseMigration {
  readonly fromVersion: number = 2;
  readonly toVersion: number = 3;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V2_TO_V3_STATEMENTS.length; i++) {
      await store.executeSql(V2_TO_V3_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v3→v4 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 message_swipe_groups 表
 * 2. 创建 message_swipe_candidates 表
 * 3. 创建 Swipe 索引
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有表结构
 * 6. 不为旧消息批量创建 Swipe 数据
 */
export function createV3ToV4Migration(): DatabaseMigration {
  return new V3ToV4Migration();
}

class V3ToV4Migration implements DatabaseMigration {
  readonly fromVersion: number = 3;
  readonly toVersion: number = 4;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V3_TO_V4_STATEMENTS.length; i++) {
      await store.executeSql(V3_TO_V4_STATEMENTS[i]);
    }
  }
}
