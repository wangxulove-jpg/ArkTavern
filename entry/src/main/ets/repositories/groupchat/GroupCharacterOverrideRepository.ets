import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import {
  GroupCharacterOverride,
  createOverride
} from '../../models/groupchat/GroupCharacterOverride';
import { generateUuid } from '../../utils/Uuid';
import { DatabaseError } from '../../models/DatabaseError';
import {
  TABLE_GROUP_CHARACTER_OVERRIDES,
  COLUMN_ID,
  COLUMN_GROUP_CONVERSATION_ID,
  COLUMN_CHARACTER_ID,
  COLUMN_OVERRIDE_NAME,
  COLUMN_OVERRIDE_DESCRIPTION,
  COLUMN_OVERRIDE_PERSONALITY,
  COLUMN_OVERRIDE_SCENARIO,
  COLUMN_OVERRIDE_SYSTEM_PROMPT,
  COLUMN_OVERRIDE_MES_EXAMPLE,
  COLUMN_OVERRIDE_POST_HISTORY_INSTRUCTIONS,
  COLUMN_OVERRIDE_FIRST_MESSAGE,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage
} from '../RepositoryMappers';

const OVERRIDE_ID_PREFIX: string = 'gco_';

export class GroupCharacterOverrideRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async getByGroupAndCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterOverride | null> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.getByGroupAndCharacter: groupConversationId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.getByGroupAndCharacter: characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_OVERRIDES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return overrideFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listByGroup(groupConversationId: string): Promise<GroupCharacterOverride[]> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.listByGroup: groupConversationId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_OVERRIDES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    predicates.orderByAsc(COLUMN_CHARACTER_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: GroupCharacterOverride[] = [];
      while (rs.goToNextRow()) {
        list.push(overrideFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  async upsert(override: GroupCharacterOverride): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.upsertWithStore(store, override);
  }

  async upsertWithStore(
    store: relationalStore.RdbStore,
    override: GroupCharacterOverride
  ): Promise<void> {
    if (override.id === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.upsert: id empty');
    }
    if (override.groupConversationId === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.upsert: groupConversationId empty');
    }
    if (override.characterId === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.upsert: characterId empty');
    }

    const pred: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_OVERRIDES);
    pred.equalTo(COLUMN_GROUP_CONVERSATION_ID, override.groupConversationId);
    pred.equalTo(COLUMN_CHARACTER_ID, override.characterId);

    const rs: relationalStore.ResultSet = await store.query(pred);
    let existingId: string = '';
    try {
      if (rs.goToFirstRow()) {
        existingId = rs.getString(rs.getColumnIndex(COLUMN_ID));
      }
    } finally {
      rs.close();
    }

    if (existingId !== '') {
      const bucket: relationalStore.ValuesBucket = overrideToBucket(override);
      bucket[COLUMN_ID] = existingId;
      bucket[COLUMN_CREATED_AT] = override.createdAt;
      const updatePred: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_OVERRIDES);
      updatePred.equalTo(COLUMN_ID, existingId);
      await store.update(bucket, updatePred);
    } else {
      const newId: string = OVERRIDE_ID_PREFIX + generateUuid();
      const bucket: relationalStore.ValuesBucket = overrideToBucket(override);
      bucket[COLUMN_ID] = newId;
      const now: number = Date.now();
      bucket[COLUMN_CREATED_AT] = now;
      bucket[COLUMN_UPDATED_AT] = now;
      await store.insert(TABLE_GROUP_CHARACTER_OVERRIDES, bucket);
    }
  }

  async deleteById(id: string): Promise<void> {
    if (id === '') {
      throw DatabaseError.invalidData('GroupCharacterOverride.deleteById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_OVERRIDES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `GroupCharacterOverride.deleteById: ${extractCauseMessage(err)}`
      );
    }
  }

  async deleteByGroupWithStore(
    store: relationalStore.RdbStore,
    groupConversationId: string
  ): Promise<void> {
    if (groupConversationId === '') {
      throw DatabaseError.invalidData(
        'GroupCharacterOverride.deleteByGroupWithStore: groupConversationId empty'
      );
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_GROUP_CHARACTER_OVERRIDES);
    predicates.equalTo(COLUMN_GROUP_CONVERSATION_ID, groupConversationId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `GroupCharacterOverride.deleteByGroupWithStore: ${extractCauseMessage(err)}`
      );
    }
  }
}

function readOptionalString(
  rs: relationalStore.ResultSet,
  columnName: string
): string | null {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return null;
  }
  if (rs.isColumnNull(col)) {
    return null;
  }
  const value: string = rs.getString(col);
  return value !== '' ? value : null;
}

function overrideToBucket(
  override: GroupCharacterOverride
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_GROUP_CONVERSATION_ID] = override.groupConversationId;
  bucket[COLUMN_CHARACTER_ID] = override.characterId;
  bucket[COLUMN_OVERRIDE_NAME] = override.name;
  bucket[COLUMN_OVERRIDE_DESCRIPTION] = override.description;
  bucket[COLUMN_OVERRIDE_PERSONALITY] = override.personality;
  bucket[COLUMN_OVERRIDE_SCENARIO] = override.scenario;
  bucket[COLUMN_OVERRIDE_SYSTEM_PROMPT] = override.systemPrompt;
  bucket[COLUMN_OVERRIDE_MES_EXAMPLE] = override.mesExample;
  bucket[COLUMN_OVERRIDE_POST_HISTORY_INSTRUCTIONS] = override.postHistoryInstructions;
  bucket[COLUMN_OVERRIDE_FIRST_MESSAGE] = override.firstMessage;
  bucket[COLUMN_UPDATED_AT] = override.updatedAt;
  return bucket;
}

function overrideFromRow(
  rs: relationalStore.ResultSet
): GroupCharacterOverride {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const groupConversationId: string = rs.getString(
    rs.getColumnIndex(COLUMN_GROUP_CONVERSATION_ID)
  );
  const characterId: string = rs.getString(
    rs.getColumnIndex(COLUMN_CHARACTER_ID)
  );
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));

  return {
    id: id,
    groupConversationId: groupConversationId,
    characterId: characterId,
    name: readOptionalString(rs, COLUMN_OVERRIDE_NAME),
    description: readOptionalString(rs, COLUMN_OVERRIDE_DESCRIPTION),
    personality: readOptionalString(rs, COLUMN_OVERRIDE_PERSONALITY),
    scenario: readOptionalString(rs, COLUMN_OVERRIDE_SCENARIO),
    systemPrompt: readOptionalString(rs, COLUMN_OVERRIDE_SYSTEM_PROMPT),
    mesExample: readOptionalString(rs, COLUMN_OVERRIDE_MES_EXAMPLE),
    postHistoryInstructions: readOptionalString(
      rs, COLUMN_OVERRIDE_POST_HISTORY_INSTRUCTIONS
    ),
    firstMessage: readOptionalString(rs, COLUMN_OVERRIDE_FIRST_MESSAGE),
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}
