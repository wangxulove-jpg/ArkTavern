/**
 * 数据库常量集中定义
 *
 * 任何 Repository、Schema、Migration 只能从这里读取表名、列名、索引名。
 * 禁止在外部硬编码字符串。
 */

export const DATABASE_NAME: string = 'arktavern.db';
export const DATABASE_VERSION: number = 12;

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

// ===== v10: Multi-Person World =====
export const TABLE_WORLDS: string = 'worlds';
export const TABLE_WORLD_MEMBERS: string = 'world_members';
export const TABLE_WORLD_SCENES: string = 'world_scenes';
export const TABLE_WORLD_CHAT_LINKS: string = 'world_chat_links';
export const TABLE_CHARACTER_USER_RELATIONSHIPS: string = 'character_user_relationships';
export const TABLE_CHARACTER_RELATIONSHIPS: string = 'character_relationships';
export const TABLE_WORLD_MEMORY_EVENTS: string = 'world_memory_events';
export const TABLE_WORLD_PRIVATE_MEMORIES: string = 'world_private_memories';
export const TABLE_RELATIONSHIP_CHANGE_HISTORY: string = 'relationship_change_history';

// messages 表扩展字段(v10)
export const COLUMN_SENDER_TYPE: string = 'sender_type';
export const COLUMN_SENDER_CHARACTER_ID: string = 'sender_character_id';
export const COLUMN_SCENE_ID: string = 'scene_id';
export const COLUMN_GENERATION_BATCH_ID: string = 'generation_batch_id';

// messages 表扩展字段(v11 私聊引入)
export const COLUMN_VISIBILITY: string = 'visibility';
export const COLUMN_RECIPIENT_CHARACTER_IDS_JSON: string = 'recipient_character_ids_json';
export const COLUMN_PARTICIPANT_IDS_JSON: string = 'participant_ids_json';
export const COLUMN_WITNESS_IDS_JSON: string = 'witness_ids_json';

// worlds 表字段
export const COLUMN_WORLD_ID: string = 'id';
export const COLUMN_WORLD_NAME: string = 'name';
export const COLUMN_WORLD_BACKGROUND: string = 'background';
export const COLUMN_WORLD_INITIAL_SCENE: string = 'initial_scene';
export const COLUMN_WORLD_USER_IDENTITY_JSON: string = 'user_identity_json';
export const COLUMN_WORLD_DEFAULT_REPLY_MODE: string = 'default_reply_mode';

// world_members 表字段
export const COLUMN_MEMBER_ID: string = 'id';
export const COLUMN_MEMBER_WORLD_ID: string = 'world_id';
export const COLUMN_MEMBER_CHARACTER_ID: string = 'character_id';
export const COLUMN_MEMBER_ENABLED: string = 'enabled';
export const COLUMN_MEMBER_PRESENT: string = 'present';
export const COLUMN_MEMBER_MUTED: string = 'muted';
export const COLUMN_MEMBER_TALKATIVENESS: string = 'talkativeness';
export const COLUMN_MEMBER_DISPLAY_ORDER: string = 'display_order';
export const COLUMN_MEMBER_JOINED_AT: string = 'joined_at';
export const COLUMN_MEMBER_INITIAL_RELATIONSHIP_JSON: string = 'initial_relationship_json';

// world_scenes 表字段
export const COLUMN_SCENE_ID_FULL: string = 'id';
export const COLUMN_SCENE_WORLD_ID: string = 'world_id';
export const COLUMN_SCENE_NAME: string = 'name';
export const COLUMN_SCENE_LOCATION: string = 'location';
export const COLUMN_SCENE_TIME_DESCRIPTION: string = 'time_description';
export const COLUMN_SCENE_DESCRIPTION: string = 'description';
export const COLUMN_SCENE_PRESENT_CHARACTER_IDS_JSON: string = 'present_character_ids_json';
export const COLUMN_SCENE_IMPORTANT_OBJECTS_JSON: string = 'important_objects_json';
export const COLUMN_SCENE_STATUS: string = 'status';

// world_chat_links 表字段
export const COLUMN_WCL_CHAT_ID: string = 'chat_id';
export const COLUMN_WCL_WORLD_ID: string = 'world_id';
export const COLUMN_WCL_CURRENT_SCENE_ID: string = 'current_scene_id';
export const COLUMN_WCL_REPLY_MODE: string = 'reply_mode';

// 关系表字段
export const COLUMN_RELATIONSHIP_LABEL: string = 'relationship_label';
export const COLUMN_AFFINITY: string = 'affinity';
export const COLUMN_TRUST: string = 'trust';
export const COLUMN_RESPECT: string = 'respect';
export const COLUMN_FEAR: string = 'fear';
export const COLUMN_HOSTILITY: string = 'hostility';
export const COLUMN_DEPENDENCY: string = 'dependency';
export const COLUMN_FAMILIARITY: string = 'familiarity';
export const COLUMN_CURRENT_EMOTION: string = 'current_emotion';
export const COLUMN_PRIVATE_OPINION: string = 'private_opinion';
export const COLUMN_SHARED_EXPERIENCES_JSON: string = 'shared_experiences_json';
export const COLUMN_PROMISES_JSON: string = 'promises_json';
export const COLUMN_CONFLICTS_JSON: string = 'conflicts_json';
export const COLUMN_SECRETS_FROM_USER_JSON: string = 'secrets_from_user_json';
export const COLUMN_SECRETS_SHARED_BY_USER_JSON: string = 'secrets_shared_by_user_json';
export const COLUMN_USER_NAME_OVERRIDE: string = 'user_name_override';
export const COLUMN_LAST_UPDATED_MESSAGE_ID: string = 'last_updated_message_id';
export const COLUMN_SOURCE_CHARACTER_ID: string = 'source_character_id';
export const COLUMN_TARGET_CHARACTER_ID: string = 'target_character_id';
export const COLUMN_KNOWN_SECRETS_JSON: string = 'known_secrets_json';

// 记忆表字段
export const COLUMN_EVENT_PARTICIPANT_IDS_JSON: string = 'participant_ids_json';
export const COLUMN_EVENT_WITNESS_IDS_JSON: string = 'witness_ids_json';
export const COLUMN_EVENT_INFORMED_IDS_JSON: string = 'informed_character_ids_json';
export const COLUMN_EVENT_SUBJECT_CHARACTER_ID: string = 'subject_character_id';
export const COLUMN_EVENT_RELATED_CHARACTER_IDS_JSON: string = 'related_character_ids_json';
export const COLUMN_EVENT_VISIBILITY: string = 'visibility';
export const COLUMN_EVENT_SUMMARY: string = 'summary';
export const COLUMN_EVENT_START_MESSAGE_ID: string = 'start_message_id';
export const COLUMN_EVENT_END_MESSAGE_ID: string = 'end_message_id';

// 私人记忆表字段
export const COLUMN_PRIVATE_MEMORY_CHARACTER_ID: string = 'character_id';

// 关系变化历史字段
export const COLUMN_CHANGE_TARGET_CHARACTER_ID: string = 'target_character_id';
export const COLUMN_CHANGE_FIELD_NAME: string = 'field_name';
export const COLUMN_CHANGE_OLD_VALUE: string = 'old_value';
export const COLUMN_CHANGE_NEW_VALUE: string = 'new_value';
export const COLUMN_CHANGE_REASON: string = 'reason';
export const COLUMN_CHANGE_SOURCE_MESSAGE_ID: string = 'source_message_id';

// v10 索引
export const INDEX_MESSAGES_CHAT_BATCH: string = 'idx_messages_chat_batch';
export const INDEX_MESSAGES_SENDER_CHARACTER: string = 'idx_messages_sender_character';
export const INDEX_WORLD_MEMBERS_WORLD_ID: string = 'idx_world_members_world_id';
export const INDEX_WORLD_MEMBERS_CHARACTER_ID: string = 'idx_world_members_character_id';
export const INDEX_WORLD_SCENES_WORLD_ID: string = 'idx_world_scenes_world_id';
export const INDEX_WORLD_CHAT_LINKS_CHAT_ID: string = 'idx_world_chat_links_chat_id';
export const INDEX_WORLD_CHAT_LINKS_WORLD_ID: string = 'idx_world_chat_links_world_id';
export const INDEX_CHAR_USER_REL_WORLD: string = 'idx_char_user_rel_world';
export const INDEX_CHAR_USER_REL_CHARACTER: string = 'idx_char_user_rel_character';
export const INDEX_CHAR_REL_WORLD: string = 'idx_char_rel_world';
export const INDEX_CHAR_REL_SOURCE: string = 'idx_char_rel_source';
export const INDEX_CHAR_REL_TARGET: string = 'idx_char_rel_target';
export const INDEX_WORLD_MEMORY_EVENTS_WORLD: string = 'idx_world_memory_events_world';
export const INDEX_WORLD_MEMORY_EVENTS_BRANCH: string = 'idx_world_memory_events_branch';
export const INDEX_WORLD_MEMORY_EVENTS_SCENE: string = 'idx_world_memory_events_scene';
export const INDEX_WORLD_PRIVATE_MEMORIES_WORLD: string = 'idx_world_private_memories_world';
export const INDEX_WORLD_PRIVATE_MEMORIES_CHARACTER: string = 'idx_world_private_memories_character';
export const INDEX_RELATIONSHIP_CHANGE_HISTORY_WORLD: string = 'idx_relationship_change_history_world';
export const INDEX_RELATIONSHIP_CHANGE_HISTORY_MESSAGE: string = 'idx_relationship_change_history_message';
