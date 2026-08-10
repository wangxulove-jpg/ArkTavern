import { GroupCharacterOverrideRepository } from '../../repositories/groupchat/GroupCharacterOverrideRepository';
import { GroupCharacterOverride } from '../../models/groupchat/GroupCharacterOverride';
import { Character } from '../../models/Character';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'GroupCharacterOverrideSvc';

export class GroupCharacterOverrideService {
  private readonly repository: GroupCharacterOverrideRepository;

  constructor(repository: GroupCharacterOverrideRepository) {
    this.repository = repository;
  }

  async getOverrides(
    groupConversationId: string,
    characterId: string
  ): Promise<GroupCharacterOverride | null> {
    if (groupConversationId === '' || characterId === '') {
      return null;
    }
    try {
      return await this.repository.getByGroupAndCharacter(
        groupConversationId, characterId
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'getOverrides failed: ' + String(e));
      return null;
    }
  }

  async upsert(override: GroupCharacterOverride): Promise<void> {
    await this.repository.upsert(override);
  }

  async deleteByGroupAndCharacter(
    groupConversationId: string,
    characterId: string
  ): Promise<void> {
    const existing: GroupCharacterOverride | null =
      await this.repository.getByGroupAndCharacter(
        groupConversationId, characterId
      );
    if (existing !== null) {
      await this.repository.deleteById(existing.id);
    }
  }

  applyOverrides(
    character: Character,
    overrides: GroupCharacterOverride
  ): Character {
    return {
      id: character.id,
      name: overrides.name !== null ? overrides.name : character.name,
      description: overrides.description !== null
        ? overrides.description : character.description,
      personality: overrides.personality !== null
        ? overrides.personality : character.personality,
      scenario: overrides.scenario !== null
        ? overrides.scenario : character.scenario,
      firstMessage: overrides.firstMessage !== null
        ? overrides.firstMessage : character.firstMessage,
      systemPrompt: overrides.systemPrompt !== null
        ? overrides.systemPrompt : character.systemPrompt,
      avatarUri: character.avatarUri,
      mesExample: overrides.mesExample !== null
        ? overrides.mesExample : character.mesExample,
      creatorNotes: character.creatorNotes,
      postHistoryInstructions: overrides.postHistoryInstructions !== null
        ? overrides.postHistoryInstructions : character.postHistoryInstructions,
      alternateGreetings: character.alternateGreetings,
      tags: character.tags,
      creator: character.creator,
      characterVersion: character.characterVersion,
      extensions: character.extensions,
      characterBookId: character.characterBookId,
      userName: character.userName,
      sortOrder: character.sortOrder,
      createdAt: character.createdAt,
      updatedAt: character.updatedAt
    };
  }
}
