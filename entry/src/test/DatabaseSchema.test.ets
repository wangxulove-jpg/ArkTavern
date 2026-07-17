/**
 * DatabaseSchema 纯逻辑测试
 *
 * 覆盖:
 * 1. 三个表名唯一
 * 2. SQL 包含 IF NOT EXISTS
 * 3. 不包含 DROP TABLE
 * 4. 不包含 API Key / Authorization / secret
 * 5. messages 包含 chat_id 和 sequence_number
 * 6. 索引名称唯一
 * 7. migration 路径从 0 到 1 有效
 * 8. 不支持降级
 * 9. 不修改输入 migration 数组
 * 10. 相同输入结果确定
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  INDEX_CHATS_UPDATED_AT,
  INDEX_CHATS_CHARACTER_ID,
  INDEX_MESSAGES_CHAT_SEQUENCE,
  INDEX_MESSAGES_CHAT_CREATED
} from '../main/ets/database/DatabaseConstants';
import { VERSION_1_STATEMENTS, getSchemaStatements, getCreateTableStatements, getCreateIndexStatements } from '../main/ets/database/DatabaseSchema';
import {
  buildMigrationPath,
  isMigrationRegistryValid,
  DatabaseMigration
} from '../main/ets/database/DatabaseMigration';

export default function databaseSchemaTest(): void {
  describe('DatabaseSchema_tableNames', () => {
    it('Three_table_names_unique', 0, () => {
      const names: Set<string> = new Set([TABLE_CHARACTERS, TABLE_CHATS, TABLE_MESSAGES]);
      expect(names.size).assertEqual(3);
    });

    it('Table_names_non_empty', 0, () => {
      expect(TABLE_CHARACTERS.length > 0).assertTrue();
      expect(TABLE_CHATS.length > 0).assertTrue();
      expect(TABLE_MESSAGES.length > 0).assertTrue();
    });
  });

  describe('DatabaseSchema_sql_invariants', () => {
    it('Version1_statements_contain_IF_NOT_EXISTS', 0, () => {
      for (let i = 0; i < VERSION_1_STATEMENTS.length; i++) {
        expect(VERSION_1_STATEMENTS[i].indexOf('IF NOT EXISTS') >= 0).assertTrue();
      }
    });

    it('No_DROP_TABLE_in_schema', 0, () => {
      for (let i = 0; i < VERSION_1_STATEMENTS.length; i++) {
        const upper: string = VERSION_1_STATEMENTS[i].toUpperCase();
        expect(upper.indexOf('DROP TABLE') < 0).assertTrue();
        expect(upper.indexOf('DROP INDEX') < 0).assertTrue();
      }
    });

    it('No_sensitive_keywords_in_schema', 0, () => {
      const all: string = VERSION_1_STATEMENTS.join('\n').toLowerCase();
      expect(all.indexOf('apikey') < 0).assertTrue();
      expect(all.indexOf('api_key') < 0).assertTrue();
      expect(all.indexOf('authorization') < 0).assertTrue();
      expect(all.indexOf('secret') < 0).assertTrue();
      expect(all.indexOf('password') < 0).assertTrue();
      expect(all.indexOf('token') < 0).assertTrue();
    });

    it('Messages_table_contains_chat_id_and_sequence', 0, () => {
      const tables: string[] = getCreateTableStatements();
      const messagesSql: string = tables[2];
      expect(messagesSql.indexOf('chat_id') >= 0).assertTrue();
      expect(messagesSql.indexOf('sequence_number') >= 0).assertTrue();
    });

    it('Get_schema_statements_version_1_returns_seven', 0, () => {
      const v1: string[] = getSchemaStatements(1);
      expect(v1.length).assertEqual(7);
    });

    it('Get_schema_statements_unknown_version_returns_empty', 0, () => {
      const v99: string[] = getSchemaStatements(99);
      expect(v99.length).assertEqual(0);
    });

    it('Returned_statements_array_is_new_instance', 0, () => {
      const a: string[] = getSchemaStatements(1);
      const b: string[] = getSchemaStatements(1);
      expect(a === b).assertFalse();
    });
  });

  describe('DatabaseSchema_index_invariants', () => {
    it('Index_names_unique', 0, () => {
      const names: Set<string> = new Set([
        INDEX_CHATS_UPDATED_AT,
        INDEX_CHATS_CHARACTER_ID,
        INDEX_MESSAGES_CHAT_SEQUENCE,
        INDEX_MESSAGES_CHAT_CREATED
      ]);
      expect(names.size).assertEqual(4);
    });

    it('Index_statements_contain_IF_NOT_EXISTS', 0, () => {
      const idx: string[] = getCreateIndexStatements();
      expect(idx.length).assertEqual(4);
      for (let i = 0; i < idx.length; i++) {
        expect(idx[i].indexOf('IF NOT EXISTS') >= 0).assertTrue();
      }
    });
  });

  describe('DatabaseMigration_path', () => {
    it('Empty_migrations_equal_versions_returns_empty_steps', 0, () => {
      const path = buildMigrationPath(1, 1, []);
      expect(path.steps.length).assertEqual(0);
      expect(path.fromVersion).assertEqual(1);
      expect(path.toVersion).assertEqual(1);
    });

    it('Build_path_does_not_modify_input_array', 0, () => {
      const m1: DatabaseMigration = {
        fromVersion: 1,
        toVersion: 2,
        migrate: async (): Promise<void> => { /* empty */ }
      };
      const input: DatabaseMigration[] = [m1];
      const inputLen: number = input.length;
      buildMigrationPath(1, 2, input);
      expect(input.length).assertEqual(inputLen);
      expect(input[0] === m1).assertTrue();
    });

    it('Build_path_same_input_same_output', 0, () => {
      const m1: DatabaseMigration = {
        fromVersion: 1,
        toVersion: 2,
        migrate: async (): Promise<void> => { /* empty */ }
      };
      const m2: DatabaseMigration = {
        fromVersion: 2,
        toVersion: 3,
        migrate: async (): Promise<void> => { /* empty */ }
      };
      const pathA = buildMigrationPath(1, 3, [m1, m2]);
      const pathB = buildMigrationPath(1, 3, [m2, m1]);
      expect(pathA.steps.length).assertEqual(2);
      expect(pathB.steps.length).assertEqual(2);
      expect(pathA.steps[0].fromVersion).assertEqual(1);
      expect(pathA.steps[1].toVersion).assertEqual(3);
    });

    it('Build_path_downgrade_throws', 0, () => {
      try {
        buildMigrationPath(2, 1, []);
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof Error).assertTrue();
      }
    });

    it('Build_path_missing_step_throws', 0, () => {
      try {
        buildMigrationPath(1, 5, []);
        expect(true).assertFalse();
      } catch (e) {
        expect(e instanceof Error).assertTrue();
      }
    });

    it('Registry_validity_empty', 0, () => {
      expect(isMigrationRegistryValid([])).assertTrue();
    });

    it('Registry_validity_rejects_downgrade_step', 0, () => {
      const m: DatabaseMigration = {
        fromVersion: 2,
        toVersion: 1,
        migrate: async (): Promise<void> => { /* empty */ }
      };
      expect(isMigrationRegistryValid([m])).assertFalse();
    });

    it('Registry_validity_rejects_duplicate_steps', 0, () => {
      const m1: DatabaseMigration = {
        fromVersion: 1,
        toVersion: 2,
        migrate: async (): Promise<void> => { /* empty */ }
      };
      const m2: DatabaseMigration = {
        fromVersion: 1,
        toVersion: 2,
        migrate: async (): Promise<void> => { /* empty */ }
      };
      expect(isMigrationRegistryValid([m1, m2])).assertFalse();
    });
  });
}
