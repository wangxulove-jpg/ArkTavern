export interface GroupCharacterOverride {
  readonly id: string;
  readonly groupConversationId: string;
  readonly characterId: string;
  readonly name: string | null;
  readonly description: string | null;
  readonly personality: string | null;
  readonly scenario: string | null;
  readonly systemPrompt: string | null;
  readonly mesExample: string | null;
  readonly postHistoryInstructions: string | null;
  readonly firstMessage: string | null;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export function createOverride(
  id: string,
  groupConversationId: string,
  characterId: string
): GroupCharacterOverride {
  const now: number = Date.now();
  return {
    id: id,
    groupConversationId: groupConversationId,
    characterId: characterId,
    name: null,
    description: null,
    personality: null,
    scenario: null,
    systemPrompt: null,
    mesExample: null,
    postHistoryInstructions: null,
    firstMessage: null,
    createdAt: now,
    updatedAt: now
  };
}
