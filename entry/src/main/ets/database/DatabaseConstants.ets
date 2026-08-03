/**
 * 数据库常量集中定义
 *
 * 任何 Repository、Schema、Migration 只能从这里读取表名、列名、索引名。
 * 禁止在外部硬编码字符串。
 */

export const DATABASE_NAME: string = 'arktavern.db';
export const DATABASE_VERSION: number = 14;

export const TABLE_CHARACTERS: string = 'characters';
export const TABLE_CHATS: string = 'chats';
export const TABLE_MESSAGES: string = 'messages';

export const INDEX_CHATS_UPDATED_AT: string = 'idx_chats_updated_at';
export const INDEX_CHATS_CHARACTER_ID: string = 'idx_chats_character_id';
export const INDEX_MESSAGES_CHAT_SEQUENCE: string = 'idx_messages_chat_id_sequence';
export const INDEX_MESSAGES_CHAT_CREATED: string = 'idx_messages_chat_id_created_at';

export const COLUMN_ID: string = 'id';
export const COLUMN_NAME: string = 'name';
export const COLUMN_DESCRIPTION: string = 'description';
export const COLUMN_PERSONALITY: string = 'personality';
export const COLUMN_SCENARIO: string = 'scenario';
export const COLUMN_FIRST_MESSAGE: string = 'first_message';
export const COLUMN_SYSTEM_PROMPT: string = 'system_prompt';
export const COLUMN_AVATAR_URI: string = 'avatar_uri';
export const COLUMN_CREATED_AT: string = 'created_at';
export const COLUMN_UPDATED_AT: string = 'updated_at';

// ===== v6: Tavern Card V2 字段(Character 表扩展列) =====
export const COLUMN_MES_EXAMPLE: string = 'mes_example';
export const COLUMN_CREATOR_NOTES: string = 'creator_notes';
export const COLUMN_POST_HISTORY_INSTRUCTIONS: string = 'post_history_instructions';
export const COLUMN_ALTERNATE_GREETINGS_JSON: string = 'alternate_greetings_json';
export const COLUMN_TAGS_JSON: string = 'tags_json';
export const COLUMN_CREATOR: string = 'creator';
export const COLUMN_CHARACTER_VERSION: string = 'character_version';
export const COLUMN_EXTENSIONS_JSON: string = 'extensions_json';
export const COLUMN_CHARACTER_BOOK_ID: string = 'character_book_id';
/** 角色卡 / 会话的自定义排序权重(越小越靠前,v7 引入) */
export const COLUMN_SORT_ORDER: string = 'sort_order';
/** 角色对用户的称呼(v9 引入,仅影响本角色的 {{user}} 替换) */
export const COLUMN_USER_NAME: string = 'user_name';
/** 对话级用户称呼覆盖(v9 引入,优先级高于角色 user_name 与全局设置) */
export const COLUMN_CHAT_USER_NAME_OVERRIDE: string = 'user_name_override';

export const COLUMN_CHARACTER_ID: string = 'character_id';
export const COLUMN_TITLE: string = 'title';
export const COLUMN_LAST_MESSAGE_AT: string = 'last_message_at';
export const COLUMN_IS_ARCHIVED: string = 'is_archived';

export const COLUMN_CHAT_ID: string = 'chat_id';
export const COLUMN_ROLE: string = 'role';
export const COLUMN_CONTENT: string = 'content';
export const COLUMN_STATUS: string = 'status';
export const COLUMN_SEQUENCE_NUMBER: string = 'sequence_number';
export const COLUMN_ERROR_MESSAGE: string = 'error_message';
export const COLUMN_IS_STREAMING: string = 'is_streaming';
export const COLUMN_SOURCE: string = 'source';

export const ROLE_USER: string = 'user';
export const ROLE_ASSISTANT: string = 'assistant';
export const ROLE_SYSTEM: string = 'system';

export const STATUS_PENDING: string = 'pending';
export const STATUS_STREAMING: string = 'streaming';
export const STATUS_COMPLETED: string = 'completed';
export const STATUS_FAILED: string = 'failed';

export const SOURCE_CONVERSATION: string = 'conversation';
export const SOURCE_CHARACTER_PROMPT: string = 'characterPrompt';
export const SOURCE_CHARACTER_FIRST_MESSAGE: string = 'characterFirstMessage';
export const SOURCE_LOREBOOK_BEFORE: string = 'lorebookBefore';
export const SOURCE_LOREBOOK_AFTER: string = 'lorebookAfter';
export const SOURCE_EXTERNAL_SYSTEM: string = 'externalSystem';

// ===== v2: Lorebooks =====
export const TABLE_LOREBOOKS: string = 'lorebooks';
export const COLUMN_LOREBOOK_ID: string = 'id';
export const COLUMN_LOREBOOK_NAME: string = 'name';
export const COLUMN_LOREBOOK_DESCRIPTION: string = 'description';
export const COLUMN_LOREBOOK_ENABLED: string = 'enabled';
export const COLUMN_LOREBOOK_CREATED_AT: string = 'created_at';
export const COLUMN_LOREBOOK_UPDATED_AT: string = 'updated_at';

// ===== v2: Lorebook Entries =====
export const TABLE_LOREBOOK_ENTRIES: string = 'lorebook_entries';
export const COLUMN_ENTRY_ID: string = 'id';
export const COLUMN_ENTRY_LOREBOOK_ID: string = 'lorebook_id';
export const COLUMN_ENTRY_NAME: string = 'name';
export const COLUMN_ENTRY_KEYS_JSON: string = 'keys_json';
export const COLUMN_ENTRY_SECONDARY_KEYS_JSON: string = 'secondary_keys_json';
export const COLUMN_ENTRY_CONTENT: string = 'content';
export const COLUMN_ENTRY_ENABLED: string = 'enabled';
export const COLUMN_ENTRY_CONSTANT: string = 'constant';
export const COLUMN_ENTRY_SELECTIVE: string = 'selective';
export const COLUMN_ENTRY_POSITION: string = 'position';
export const COLUMN_ENTRY_PRIORITY: string = 'priority';
export const COLUMN_ENTRY_CREATED_AT: string = 'created_at';
export const COLUMN_ENTRY_UPDATED_AT: string = 'updated_at';

// ===== v2: Lorebook Indexes =====
export const INDEX_LOREBOOKS_UPDATED_AT: string = 'idx_lorebooks_updated_at';
export const INDEX_LOREBOOKS_ENABLED: string = 'idx_lorebooks_enabled';
export const INDEX_LOREBOOK_ENTRIES_LOREBOOK_ID: string = 'idx_lorebook_entries_lorebook_id';
export const INDEX_LOREBOOK_ENTRIES_LOREBOOK_PRIORITY: string = 'idx_lorebook_entries_lorebook_priority';

// ===== v3: Prompt Presets =====
export const TABLE_PROMPT_PRESETS: string = 'prompt_presets';
export const COLUMN_PRESET_ID: string = 'id';
export const COLUMN_PRESET_NAME: string = 'name';
export const COLUMN_PRESET_DESCRIPTION: string = 'description';
export const COLUMN_PRESET_SYSTEM_PROMPT: string = 'system_prompt';
export const COLUMN_PRESET_TEMPERATURE: string = 'temperature';
export const COLUMN_PRESET_TOP_P: string = 'top_p';
export const COLUMN_PRESET_MAX_OUTPUT_TOKENS: string = 'max_output_tokens';
export const COLUMN_PRESET_CONTEXT_WINDOW: string = 'context_window';
export const COLUMN_PRESET_CREATED_AT: string = 'created_at';
export const COLUMN_PRESET_UPDATED_AT: string = 'updated_at';

// ===== v3: Prompt Preset Indexes =====
export const INDEX_PROMPT_PRESETS_UPDATED_AT: string = 'idx_prompt_presets_updated_at';

// ===== v4: Swipe =====
export const TABLE_MESSAGE_SWIPE_GROUPS: string = 'message_swipe_groups';
export const TABLE_MESSAGE_SWIPE_CANDIDATES: string = 'message_swipe_candidates';

export const COLUMN_SWIPE_ASSISTANT_MESSAGE_ID: string = 'assistant_message_id';
export const COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX: string = 'active_candidate_index';
export const COLUMN_SWIPE_CANDIDATE_ID: string = 'id';
export const COLUMN_SWIPE_CANDIDATE_INDEX: string = 'candidate_index';

export const INDEX_SWIPE_GROUPS_CHAT_ID: string = 'idx_swipe_groups_chat_id';
export const INDEX_SWIPE_CANDIDATES_MESSAGE_ID: string = 'idx_swipe_candidates_message_id';
export const INDEX_SWIPE_CANDIDATES_MESSAGE_INDEX: string = 'idx_swipe_candidates_message_index';

// ===== v5: Conversation Branches =====
export const TABLE_CONVERSATION_BRANCHES: string = 'conversation_branches';
export const TABLE_CHAT_BRANCH_STATE: string = 'chat_branch_state';
export const TABLE_CONVERSATION_BRANCH_MESSAGES: string = 'conversation_branch_messages';
export const TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS: string = 'conversation_branch_swipe_selections';

export const COLUMN_BRANCH_ID: string = 'branch_id';
export const COLUMN_PARENT_BRANCH_ID: string = 'parent_branch_id';
export const COLUMN_FORK_MESSAGE_ID: string = 'fork_message_id';
export const COLUMN_IS_ROOT: string = 'is_root';
export const COLUMN_ACTIVE_BRANCH_ID: string = 'active_branch_id';
export const COLUMN_POSITION: string = 'position';
export const COLUMN_CANDIDATE_INDEX: string = 'candidate_index';

export const INDEX_CONVERSATION_BRANCHES_CHAT_ID: string = 'idx_conversation_branches_chat_id';
export const INDEX_CONVERSATION_BRANCHES_PARENT_ID: string = 'idx_conversation_branches_parent_id';
export const INDEX_BRANCH_MESSAGES_MESSAGE_ID: string = 'idx_branch_messages_message_id';
export const INDEX_BRANCH_SWIPE_SELECTIONS_MESSAGE_ID: string = 'idx_branch_swipe_selections_message_id';

// ===== v8: Chat Memory(分支感知长期记忆) =====
export const TABLE_CHAT_MEMORIES: string = 'chat_memories';

export const COLUMN_MEMORY_ID: string = 'id';
export const COLUMN_MEMORY_CHAT_ID: string = 'chat_id';
export const COLUMN_MEMORY_BRANCH_ID: string = 'branch_id';
export const COLUMN_MEMORY_START_MESSAGE_ID: string = 'start_message_id';
export const COLUMN_MEMORY_END_MESSAGE_ID: string = 'end_message_id';
export const COLUMN_MEMORY_START_POSITION: string = 'start_position';
export const COLUMN_MEMORY_END_POSITION: string = 'end_position';
export const COLUMN_MEMORY_SUMMARY: string = 'summary';
export const COLUMN_MEMORY_ENABLED: string = 'enabled';
export const COLUMN_MEMORY_SUMMARY_VERSION: string = 'summary_version';
export const COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID: string = 'inherited_from_memory_id';

// ===== v12: Chat Memory 多层记忆扩展字段 =====
/** 记忆类型:core / chapter / rolling / legacy */
export const COLUMN_MEMORY_TYPE: string = 'memory_type';
/** 记忆标题(章节标题或核心记忆标签) */
export const COLUMN_MEMORY_TITLE: string = 'title';
/** 详细内容(章节摘要的详细描述,比 summary 更丰富) */
export const COLUMN_MEMORY_DETAIL: string = 'detail';
/** 重要度(0-100,用于注入优先级排序) */
export const COLUMN_MEMORY_IMPORTANCE: string = 'importance';
/** 关键词 JSON 数组(用于相关记忆匹配) */
export const COLUMN_MEMORY_KEYWORDS_JSON: string = 'keywords_json';
/** 源内容哈希(用于检测源消息变化) */
export const COLUMN_MEMORY_SOURCE_HASH: string = 'source_hash';
/** 是否已失效(编辑/删除/Swipe 切换后标记,不再注入 Prompt) */
export const COLUMN_MEMORY_INVALIDATED: string = 'invalidated';

export const INDEX_CHAT_MEMORIES_CHAT_ID: string = 'idx_chat_memories_chat_id';
export const INDEX_CHAT_MEMORIES_BRANCH_ID: string = 'idx_chat_memories_branch_id';
export const INDEX_CHAT_MEMORIES_BRANCH_END_POSITION: string = 'idx_chat_memories_branch_end_position';
/** v12: 按 Branch + Type + Invalidated 查询有效记忆 */
export const INDEX_CHAT_MEMORIES_BRANCH_TYPE: string = 'idx_chat_memories_branch_type';

// ===== messages 表扩展字段(原 v10/v11 引入,已内建到 CREATE 语句) =====
export const COLUMN_SENDER_TYPE: string = 'sender_type';
export const COLUMN_SENDER_CHARACTER_ID: string = 'sender_character_id';
export const COLUMN_SCENE_ID: string = 'scene_id';
export const COLUMN_GENERATION_BATCH_ID: string = 'generation_batch_id';
export const COLUMN_VISIBILITY: string = 'visibility';
export const COLUMN_RECIPIENT_CHARACTER_IDS_JSON: string = 'recipient_character_ids_json';
export const COLUMN_PARTICIPANT_IDS_JSON: string = 'participant_ids_json';
export const COLUMN_WITNESS_IDS_JSON: string = 'witness_ids_json';

// ===== v14: G-CONTROL-2A 公开消息回复目标字段(独立于私聊 recipient) =====
/** 公开消息回复目标角色 ID 列表(JSON 数组,空表示全员回复) */
export const COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON: string = 'reply_target_character_ids_json';

// messages 索引扩展
export const INDEX_MESSAGES_CHAT_BATCH: string = 'idx_messages_chat_batch';
export const INDEX_MESSAGES_SENDER_CHARACTER: string = 'idx_messages_sender_character';

// ===== ALTER TABLE 语句(仅迁移时使用) =====
export const ALTER_MESSAGES_ADD_SENDER_TYPE: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_SENDER_TYPE} TEXT NOT NULL DEFAULT 'user'`;
export const ALTER_MESSAGES_ADD_SENDER_CHARACTER_ID: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_SENDER_CHARACTER_ID} TEXT`;
export const ALTER_MESSAGES_ADD_SCENE_ID: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_SCENE_ID} TEXT`;
export const ALTER_MESSAGES_ADD_GENERATION_BATCH_ID: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_GENERATION_BATCH_ID} TEXT`;
export const ALTER_MESSAGES_ADD_VISIBILITY: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_VISIBILITY} TEXT NOT NULL DEFAULT 'public'`;
export const ALTER_MESSAGES_ADD_RECIPIENT_CHARACTER_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_RECIPIENT_CHARACTER_IDS_JSON} TEXT`;
export const ALTER_MESSAGES_ADD_PARTICIPANT_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_PARTICIPANT_IDS_JSON} TEXT`;
export const ALTER_MESSAGES_ADD_WITNESS_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_WITNESS_IDS_JSON} TEXT`;

// ===== v14: G-CONTROL-2A 公开消息回复目标字段迁移 =====
export const ALTER_MESSAGES_ADD_REPLY_TARGET_CHARACTER_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON} TEXT`;

// ===== CREATE INDEX 语句(新安装和迁移都用) =====
export const CREATE_INDEX_MESSAGES_CHAT_BATCH: string =
  `CREATE INDEX IF NOT EXISTS ${INDEX_MESSAGES_CHAT_BATCH} ON ${TABLE_MESSAGES}(${COLUMN_CHAT_ID}, ${COLUMN_GENERATION_BATCH_ID})`;
export const CREATE_INDEX_MESSAGES_SENDER_CHARACTER: string =
  `CREATE INDEX IF NOT EXISTS ${INDEX_MESSAGES_SENDER_CHARACTER} ON ${TABLE_MESSAGES}(${COLUMN_SENDER_CHARACTER_ID})`;

// ===== v13: 多人聊天参与者表(G-DATA-1A) =====
export const TABLE_CHAT_PARTICIPANTS: string = 'chat_participants';
/** chats 表新增字段:对话模式('single' / 'group') */
export const COLUMN_CONVERSATION_MODE: string = 'conversation_mode';
/** chat_participants.speaker_order:发言顺序(从 0 开始,同 Chat 内唯一) */
export const COLUMN_SPEAKER_ORDER: string = 'speaker_order';
/** chat_participants.is_enabled:是否启用(参与 AI 生成轮次) */
export const COLUMN_IS_ENABLED: string = 'is_enabled';

/** ConversationMode 字符串值集中定义 */
export const CONVERSATION_MODE_SINGLE: string = 'single';
export const CONVERSATION_MODE_GROUP: string = 'group';

/** chat_participants(chat_id, speaker_order) 索引 */
export const INDEX_CHAT_PARTICIPANTS_CHAT_ORDER: string = 'idx_chat_participants_chat_order';

export const ALTER_CHATS_ADD_CONVERSATION_MODE: string =
  `ALTER TABLE ${TABLE_CHATS} ADD COLUMN ${COLUMN_CONVERSATION_MODE} TEXT NOT NULL DEFAULT '${CONVERSATION_MODE_SINGLE}'`;

export const CREATE_INDEX_CHAT_PARTICIPANTS_CHAT_ORDER: string =
  `CREATE INDEX IF NOT EXISTS ${INDEX_CHAT_PARTICIPANTS_CHAT_ORDER} ` +
  `ON ${TABLE_CHAT_PARTICIPANTS}(${COLUMN_CHAT_ID}, ${COLUMN_SPEAKER_ORDER})`;
