/**
 * DbHelper
 *
 * 职责:
 * - 初始化 RDB(幂等,允许并发,失败可重试)
 * - 创建 V1 Schema
 * - 执行版本迁移(逐版本,事务包裹)
 * - 提供事务执行入口
 * - 关闭数据库(幂等)
 * - 关闭后允许重新初始化
 *
 * 不负责:
 * - Repository 层 SQL 拼接
 * - 业务模型转换
 * - 缓存
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../utils/Logger';
import {
  DATABASE_NAME,
  DATABASE_VERSION
} from './DatabaseConstants';
import { getSchemaStatements } from './DatabaseSchema';
import {
  buildMigrationPath,
  DatabaseMigration,
  MigrationPath
} from './DatabaseMigration';
import { DatabaseError, DatabaseErrorType } from '../models/DatabaseError';

const LOG_TAG: string = 'DbHelper';

export class DbHelper {
  private readonly databaseName: string;
  private readonly migrations: ReadonlyArray<DatabaseMigration>;

  private store: relationalStore.RdbStore | null = null;
  private initializing: Promise<relationalStore.RdbStore> | null = null;
  private closed: boolean = false;

  constructor(
    databaseName: string = DATABASE_NAME,
    migrations: ReadonlyArray<DatabaseMigration> = []
  ) {
    this.databaseName = databaseName;
    this.migrations = migrations;
  }

  isInitialized(): boolean {
    return this.store !== null && !this.closed;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.store !== null && !this.closed) {
      return;
    }
    if (this.initializing !== null) {
      await this.initializing;
      return;
    }
    if (this.closed) {
      this.closed = false;
    }

    Logger.info(LOG_TAG, 'initialize start');
    const initPromise: Promise<relationalStore.RdbStore> = this.openAndMigrate(context);
    this.initializing = initPromise;

    try {
      const opened: relationalStore.RdbStore = await initPromise;
      this.store = opened;
      const version: number = await this.readUserVersion(opened);
      Logger.info(
        LOG_TAG,
        `initialize success version=${version}`
      );
    } catch (err) {
      this.initializing = null;
      const cause: string = this.extractCauseMessage(err);
      Logger.error(LOG_TAG, `initialize failed cause=${cause}`);
      throw DatabaseError.openFailed(cause);
    } finally {
      this.initializing = null;
    }
  }

  getStore(): relationalStore.RdbStore {
    if (this.closed) {
      throw DatabaseError.closed('getStore after close');
    }
    if (this.store === null) {
      throw DatabaseError.notInitialized('getStore before initialize');
    }
    return this.store;
  }

  async getVersion(): Promise<number> {
    const store: relationalStore.RdbStore = this.getStore();
    return await this.readUserVersion(store);
  }

  async runInTransaction(
    action: (store: relationalStore.RdbStore) => Promise<void>
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.getStore();
    try {
      store.beginTransaction();
      await action(store);
      store.commit();
    } catch (err) {
      try {
        store.rollBack();
      } catch (rollbackErr) {
        const rollbackCause: string = this.extractCauseMessage(rollbackErr);
        Logger.error(LOG_TAG, `rollback failed cause=${rollbackCause}`);
        throw DatabaseError.transactionFailed(
          `rollback failed: ${this.extractCauseMessage(err)}`
        );
      }
      throw DatabaseError.transactionFailed(this.extractCauseMessage(err));
    }
  }

  async close(): Promise<void> {
    if (this.store === null && this.initializing === null) {
      return;
    }
    if (this.initializing !== null) {
      try {
        await this.initializing;
      } catch (err) {
        Logger.warn(LOG_TAG, 'close: pending init failed, ignoring');
      }
    }
    if (this.store !== null) {
      try {
        await this.store.close();
      } catch (err) {
        const cause: string = this.extractCauseMessage(err);
        Logger.warn(LOG_TAG, `close store failed cause=${cause}`);
      }
    }
    this.store = null;
    this.initializing = null;
    this.closed = true;
    Logger.info(LOG_TAG, 'close success');
  }

  private async openAndMigrate(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: this.databaseName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(context, config);
    const currentVersion: number = await this.readUserVersion(store);
    if (currentVersion > DATABASE_VERSION) {
      throw DatabaseError.unsupportedVersion(
        `current=${currentVersion} > supported=${DATABASE_VERSION}`
      );
    }
    if (currentVersion === 0) {
      await this.createFreshSchema(store);
      await this.writeUserVersion(store, DATABASE_VERSION);
      return store;
    }
    if (currentVersion < DATABASE_VERSION) {
      await this.runMigrations(store, currentVersion, DATABASE_VERSION);
      return store;
    }
    await this.ensureSchemaExists(store);
    return store;
  }

  private async createFreshSchema(store: relationalStore.RdbStore): Promise<void> {
    const statements: string[] = getSchemaStatements(1);
    try {
      for (let i = 0; i < statements.length; i++) {
        await store.executeSql(statements[i]);
      }
    } catch (err) {
      throw DatabaseError.schemaFailed(this.extractCauseMessage(err));
    }
  }

  private async ensureSchemaExists(store: relationalStore.RdbStore): Promise<void> {
    const statements: string[] = getSchemaStatements(1);
    try {
      for (let i = 0; i < statements.length; i++) {
        await store.executeSql(statements[i]);
      }
    } catch (err) {
      throw DatabaseError.schemaFailed(this.extractCauseMessage(err));
    }
  }

  private async runMigrations(
    store: relationalStore.RdbStore,
    fromVersion: number,
    toVersion: number
  ): Promise<void> {
    if (fromVersion === toVersion) {
      return;
    }
    const path: MigrationPath =
      buildMigrationPath(fromVersion, toVersion, this.migrations);
    for (let i = 0; i < path.steps.length; i++) {
      const step: DatabaseMigration = path.steps[i];
      try {
        store.beginTransaction();
        await step.migrate(store);
        store.commit();
        Logger.info(
          LOG_TAG,
          `migration ${step.fromVersion}->${step.toVersion} success`
        );
      } catch (err) {
        try {
          store.rollBack();
        } catch (rollbackErr) {
          Logger.error(
            LOG_TAG,
            `migration rollback failed cause=${this.extractCauseMessage(rollbackErr)}`
          );
        }
        throw DatabaseError.migrationFailed(
          `step ${step.fromVersion}->${step.toVersion}: ${this.extractCauseMessage(err)}`
        );
      }
    }
  }

  private async readUserVersion(store: relationalStore.RdbStore): Promise<number> {
    try {
      const result: relationalStore.ResultSet = await store.querySql('PRAGMA user_version');
      let version: number = 0;
      if (result.goToFirstRow()) {
        const columnIndex: number = result.getColumnIndex('user_version');
        if (columnIndex >= 0) {
          version = result.getLong(columnIndex);
        }
      }
      result.close();
      return version;
    } catch (err) {
      throw DatabaseError.queryFailed(this.extractCauseMessage(err));
    }
  }

  private async writeUserVersion(
    store: relationalStore.RdbStore,
    version: number
  ): Promise<void> {
    try {
      await store.executeSql(`PRAGMA user_version = ${version}`);
    } catch (err) {
      throw DatabaseError.schemaFailed(this.extractCauseMessage(err));
    }
  }

  private extractCauseMessage(err: Error | BusinessError | Object): string {
    if (err === null || err === undefined) {
      return '';
    }
    if (typeof err === 'object') {
      const obj: Object = err as Object;
      const code: Object | undefined = Reflect.has(obj, 'code')
        ? (obj as Record<string, Object>).code
        : undefined;
      const msg: Object | undefined = Reflect.has(obj, 'message')
        ? (obj as Record<string, Object>).message
        : undefined;
      if (typeof code === 'number' && typeof msg === 'string') {
        return `code=${code} message=${msg}`;
      }
      if (typeof msg === 'string') {
        return msg;
      }
    }
    return 'unknown error';
  }
}

interface BusinessError {
  code: number;
  message: string;
}
