import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  WorldCharacterLocationHistory,
  TransitionKind,
  isTransitionKind,
  InitiatorType,
  isInitiatorType
} from '../../models/world/WorldCharacterLocationHistory';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_WORLD_CHARACTER_LOCATION_HISTORY,
  COLUMN_ID,
  COLUMN_WORLD_ID,
  COLUMN_CHARACTER_INSTANCE_ID,
  COLUMN_TRANSITION_KIND,
  COLUMN_FROM_LOCATION_ID,
  COLUMN_TO_LOCATION_ID,
  COLUMN_INITIATOR_TYPE,
  COLUMN_EDGE_ID,
  COLUMN_DIRECTION_LABEL,
  COLUMN_CREATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage
} from '../RepositoryMappers';

export class WorldCharacterLocationHistoryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getById(id: string): Promise<WorldCharacterLocationHistory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterLocationHistory.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<WorldCharacterLocationHistory | null> {
    if (id === '') {
      throw DatabaseError.invalidData('WorldCharacterLocationHistory.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_LOCATION_HISTORY);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return historyFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listByCharacterInstance(
    characterInstanceId: string
  ): Promise<WorldCharacterLocationHistory[]> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData(
        'WorldCharacterLocationHistory.listByCharacterInstance: characterInstanceId empty'
      );
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_LOCATION_HISTORY);
    predicates.equalTo(COLUMN_CHARACTER_INSTANCE_ID, characterInstanceId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterLocationHistory[] = [];
      while (rs.goToNextRow()) {
        list.push(historyFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async listByCharacterInstanceWithStore(
    store: relationalStore.RdbStore,
    characterInstanceId: string
  ): Promise<WorldCharacterLocationHistory[]> {
    if (characterInstanceId === '') {
      throw DatabaseError.invalidData(
        'WorldCharacterLocationHistory.listByCharacterInstanceWithStore: characterInstanceId empty'
      );
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_LOCATION_HISTORY);
    predicates.equalTo(COLUMN_CHARACTER_INSTANCE_ID, characterInstanceId);
    predicates.orderByDesc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: WorldCharacterLocationHistory[] = [];
      while (rs.goToNextRow()) {
        list.push(historyFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async insert(history: WorldCharacterLocationHistory): Promise<void> {
    this.validateHistory(history);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLD_CHARACTER_LOCATION_HISTORY, historyToBucket(history));
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldCharacterLocationHistory.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    history: WorldCharacterLocationHistory
  ): Promise<void> {
    this.validateHistory(history);
    try {
      await store.insert(TABLE_WORLD_CHARACTER_LOCATION_HISTORY, historyToBucket(history));
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldCharacterLocationHistory.insertWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  async deleteByWorldIdWithStore(
    store: relationalStore.RdbStore,
    worldId: string
  ): Promise<void> {
    if (worldId === '') {
      throw DatabaseError.invalidData(
        'WorldCharacterLocationHistory.deleteByWorldIdWithStore: worldId empty'
      );
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLD_CHARACTER_LOCATION_HISTORY);
    predicates.equalTo(COLUMN_WORLD_ID, worldId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `WorldCharacterLocationHistory.deleteByWorldIdWithStore: ${extractCauseMessage(err)}`
      );
    }
  }

  private validateHistory(history: WorldCharacterLocationHistory): void {
    if (history.id === '') {
      throw DatabaseError.invalidData('WorldCharacterLocationHistory.id empty');
    }
    if (history.worldId === '') {
      throw DatabaseError.invalidData('WorldCharacterLocationHistory.worldId empty');
    }
    if (history.characterInstanceId === '') {
      throw DatabaseError.invalidData('WorldCharacterLocationHistory.characterInstanceId empty');
    }
    if (!isTransitionKind(history.transitionKind)) {
      throw DatabaseError.invalidData(
        `WorldCharacterLocationHistory.transitionKind invalid: ${history.transitionKind}`
      );
    }
    if (!isInitiatorType(history.initiatorType)) {
      throw DatabaseError.invalidData(
        `WorldCharacterLocationHistory.initiatorType invalid: ${history.initiatorType}`
      );
    }
    if (!isValidTimestamp(history.createdAt)) {
      throw DatabaseError.invalidData('WorldCharacterLocationHistory.createdAt invalid');
    }
  }
}

function historyToBucket(history: WorldCharacterLocationHistory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = history.id;
  bucket[COLUMN_WORLD_ID] = history.worldId;
  bucket[COLUMN_CHARACTER_INSTANCE_ID] = history.characterInstanceId;
  bucket[COLUMN_TRANSITION_KIND] = history.transitionKind;
  bucket[COLUMN_FROM_LOCATION_ID] = history.fromLocationId;
  bucket[COLUMN_TO_LOCATION_ID] = history.toLocationId;
  bucket[COLUMN_INITIATOR_TYPE] = history.initiatorType;
  bucket[COLUMN_EDGE_ID] = history.edgeId;
  bucket[COLUMN_DIRECTION_LABEL] = history.directionLabel;
  bucket[COLUMN_CREATED_AT] = history.createdAt;
  return bucket;
}

function readOptionalString(rs: relationalStore.ResultSet, columnName: string): string {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return '';
  }
  if (rs.isColumnNull(col)) {
    return '';
  }
  return rs.getString(col);
}

function historyFromRow(rs: relationalStore.ResultSet): WorldCharacterLocationHistory {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id === '') {
    throw DatabaseError.invalidData('WorldCharacterLocationHistory.id empty in row');
  }
  const worldId: string = rs.getString(rs.getColumnIndex(COLUMN_WORLD_ID));
  if (worldId === '') {
    throw DatabaseError.invalidData('WorldCharacterLocationHistory.worldId empty in row');
  }
  const characterInstanceId: string =
    rs.getString(rs.getColumnIndex(COLUMN_CHARACTER_INSTANCE_ID));
  if (characterInstanceId === '') {
    throw DatabaseError.invalidData(
      'WorldCharacterLocationHistory.characterInstanceId empty in row'
    );
  }
  const transitionKindRaw: string = rs.getString(rs.getColumnIndex(COLUMN_TRANSITION_KIND));
  if (!isTransitionKind(transitionKindRaw)) {
    throw DatabaseError.invalidData(
      `WorldCharacterLocationHistory.transitionKind invalid in row: ${transitionKindRaw}`
    );
  }
  const fromLocationId: string = readOptionalString(rs, COLUMN_FROM_LOCATION_ID);
  const toLocationId: string = readOptionalString(rs, COLUMN_TO_LOCATION_ID);
  const initiatorTypeRaw: string = readOptionalString(rs, COLUMN_INITIATOR_TYPE);
  if (!isInitiatorType(initiatorTypeRaw)) {
    throw DatabaseError.invalidData(
      `WorldCharacterLocationHistory.initiatorType invalid in row: ${initiatorTypeRaw}`
    );
  }
  const edgeId: string = readOptionalString(rs, COLUMN_EDGE_ID);
  const directionLabel: string = readOptionalString(rs, COLUMN_DIRECTION_LABEL);
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('WorldCharacterLocationHistory.createdAt invalid in row');
  }
  return {
    id: id,
    worldId: worldId,
    characterInstanceId: characterInstanceId,
    transitionKind: transitionKindRaw as TransitionKind,
    fromLocationId: fromLocationId,
    toLocationId: toLocationId,
    initiatorType: initiatorTypeRaw as InitiatorType,
    edgeId: edgeId,
    directionLabel: directionLabel,
    createdAt: createdAt
  };
}
