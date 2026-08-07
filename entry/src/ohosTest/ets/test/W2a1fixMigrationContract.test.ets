import { describe, it, expect } from '@ohos/hypium';
import {
  DATABASE_VERSION
} from '../../../main/ets/database/DatabaseConstants';
import {
  V19_TO_V20_DDL_STATEMENTS,
  V22_TO_V23_DDL_STATEMENTS,
  V23_SCHEMA_STATEMENTS
} from '../../../main/ets/database/DatabaseSchema';

export default function w2a1fixMigrationContractTest(): void {
  describe('W2A1FIX Migration 契约', () => {
    it('W2A1FIX-10 DATABASE_VERSION 仍为 23', 0, () => {
      expect(DATABASE_VERSION).assertEqual(23);
    });

    it('W2A1FIX-11 V22→V23 不重复 ALTER PlayerProfile 的 persona', 0, () => {
      const profileAltters: string[] = V22_TO_V23_DDL_STATEMENTS.filter(
        (s: string) => s.indexOf('world_player_profiles') >= 0 && s.indexOf('persona') >= 0
      );
      expect(profileAltters.length).assertEqual(1);
    });

    it('W2A1FIX-12 V22→V23 不重复 ALTER PlayerProfile 的 public_identity', 0, () => {
      const profileAltters: string[] = V22_TO_V23_DDL_STATEMENTS.filter(
        (s: string) => s.indexOf('world_player_profiles') >= 0 && s.indexOf('public_identity') >= 0
      );
      expect(profileAltters.length).assertEqual(1);
    });

    it('W2A1FIX-13 V22→V23 不重复 ALTER PlayerProfile 的 private_identity', 0, () => {
      const profileAltters: string[] = V22_TO_V23_DDL_STATEMENTS.filter(
        (s: string) => s.indexOf('world_player_profiles') >= 0 && s.indexOf('private_identity') >= 0
      );
      expect(profileAltters.length).assertEqual(1);
    });

    it('W2A1FIX-14 V22→V23 不重复 ALTER PlayerProfile 的 current_location_id', 0, () => {
      const profileAltters: string[] = V22_TO_V23_DDL_STATEMENTS.filter(
        (s: string) => s.indexOf('world_player_profiles') >= 0 && s.indexOf('current_location_id') >= 0
      );
      expect(profileAltters.length).assertEqual(1);
    });

    it('W2A1FIX-15 V19→V20 CREATE TABLE 不包含 persona 列', 0, () => {
      const createTableStmt: string | undefined = V19_TO_V20_DDL_STATEMENTS.find(
        (s: string) => s.indexOf('CREATE TABLE') >= 0 && s.indexOf('world_player_profiles') >= 0
      );
      expect(createTableStmt !== undefined).assertTrue();
      expect(createTableStmt!.indexOf('persona') < 0).assertTrue();
    });

    it('W2A1FIX-16 V19→V20 CREATE TABLE 不包含 public_identity 列', 0, () => {
      const createTableStmt: string | undefined = V19_TO_V20_DDL_STATEMENTS.find(
        (s: string) => s.indexOf('CREATE TABLE') >= 0 && s.indexOf('world_player_profiles') >= 0
      );
      expect(createTableStmt!.indexOf('public_identity') < 0).assertTrue();
    });

    it('W2A1FIX-17 V19→V20 CREATE TABLE 不包含 private_identity 列', 0, () => {
      const createTableStmt: string | undefined = V19_TO_V20_DDL_STATEMENTS.find(
        (s: string) => s.indexOf('CREATE TABLE') >= 0 && s.indexOf('world_player_profiles') >= 0
      );
      expect(createTableStmt!.indexOf('private_identity') < 0).assertTrue();
    });

    it('W2A1FIX-18 V19→V20 CREATE TABLE 不包含 profile current_location_id 列', 0, () => {
      const createTableStmt: string | undefined = V19_TO_V20_DDL_STATEMENTS.find(
        (s: string) => s.indexOf('CREATE TABLE') >= 0 && s.indexOf('world_player_profiles') >= 0
      );
      expect(createTableStmt!.indexOf('current_location_id') < 0).assertTrue();
    });

    it('W2A1FIX-19 V23 fresh schema 包含 ALTER 语句(先 CREATE 再 ALTER)', 0, () => {
      const hasAlter: boolean = V23_SCHEMA_STATEMENTS.some(
        (s: string) => s.indexOf('ALTER TABLE') >= 0
      );
      expect(hasAlter).assertTrue();
    });

    it('W2A1FIX-20 V23 fresh schema 不包含 duplicate ALTER', 0, () => {
      const personaAlters: string[] = V23_SCHEMA_STATEMENTS.filter(
        (s: string) => s.indexOf('ADD COLUMN persona') >= 0
      );
      expect(personaAlters.length).assertEqual(1);
    });

    it('W2A1FIX-21 isActive 是唯一 active authority(无 status 列)', 0, () => {
      const instanceAltters: string[] = V22_TO_V23_DDL_STATEMENTS.filter(
        (s: string) => s.indexOf('world_character_instances') >= 0 && s.indexOf('status') >= 0
      );
      expect(instanceAltters.length).assertEqual(0);
    });

    it('W2A1FIX-22 历史迁移完整(V22_TO_V23_DDL_STATEMENTS 有 6 条)', 0, () => {
      expect(V22_TO_V23_DDL_STATEMENTS.length).assertEqual(6);
    });
  });
}
