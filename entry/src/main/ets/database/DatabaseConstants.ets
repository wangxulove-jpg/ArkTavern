/**
 * 数据库常量集中定义
 *
 * 任何 Repository、Schema、Migration 只能从这里读取表名、列名、索引名。
 * 禁止在外部硬编码字符串。
 */

export const DATABASE_NAME: string = 'arktavern.db';
export const DATABASE_VERSION: number = 1;

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
