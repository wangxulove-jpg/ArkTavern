/**
 * SpeakerScheduler 多人世界发言调度器
 *
 * 职责:
 * - 根据回复模式筛选候选角色
 * - 自动导演模式:综合 talkativeness / 最近连续发言次数 / 场景相关性 / 关系紧张度评分
 * - 全员回应模式:返回全部在场且未静音角色
 * - 指定角色模式:仅返回用户指定的角色
 * - 仅旁白模式:返回空候选列表
 *
 * 不负责:
 * - 模型请求(由 MultiPersonChatService 处理)
 * - 关系数值更新(由 WorldRelationshipService 处理)
 *
 * 规则:
 * - 离场角色不发言
 * - 静音角色不发言
 * - 不在世界的角色不发言
 * - 模型只能从候选中选择发言者
 */

import { WorldMember } from '../models/WorldMember';
import { WorldScene } from '../models/WorldScene';
import { CharacterUserRelationship } from '../models/WorldRelationship';
import { ChatMessage } from '../models/ChatMessage';
import { WorldReplyMode } from '../models/World';

/**
 * 单个候选角色的调度结果。
 */
export interface SpeakerCandidate {
  readonly characterId: string;
  readonly talkativeness: number;
  readonly score: number;
  readonly reason: string;
}

/**
 * 调度输入(由 MultiPersonChatService 组装)。
 */
export interface SpeakerScheduleInput {
  readonly replyMode: WorldReplyMode;
  readonly designatedCharacterId: string;
  readonly members: WorldMember[];
  readonly scene: WorldScene | null;
  readonly recentMessages: ChatMessage[];
  readonly userRelationships: Map<string, CharacterUserRelationship>;
  readonly maxSpeakers: number;
}

const MAX_RECENT_SPEAKERS_LOOKBACK: number = 10;
const RECENT_SPEAKER_PENALTY: number = 0.25;

export class SpeakerScheduler {
  /**
   * 根据回复模式筛选候选角色。
   * - designated: 仅返回指定角色(若有效)
   * - auto_director: 按评分取前 maxSpeakers 名
   * - all_respond: 返回全部在场且未静音角色(按 displayOrder)
   * - narrator_only: 返回空数组
   */
  schedule(input: SpeakerScheduleInput): SpeakerCandidate[] {
    if (input.replyMode === 'narrator_only') {
      return [];
    }
    // 候选池:启用 + 在场 + 未静音
    const pool: WorldMember[] = input.members.filter(
      (m: WorldMember) => m.enabled && m.present && !m.muted
    );
    if (pool.length === 0) {
      return [];
    }
    if (input.replyMode === 'designated') {
      if (input.designatedCharacterId.length === 0) {
        return [];
      }
      const target: WorldMember | undefined = pool.find(
        (m: WorldMember) => m.characterId === input.designatedCharacterId
      );
      if (target === undefined) {
        return [];
      }
      const designatedCandidate: SpeakerCandidate = {
        characterId: target.characterId,
        talkativeness: target.talkativeness,
        score: 1.0,
        reason: 'designated'
      };
      return [designatedCandidate];
    }
    if (input.replyMode === 'all_respond') {
      const allCandidates: SpeakerCandidate[] = [];
      for (let i = 0; i < pool.length; i++) {
        const m: WorldMember = pool[i];
        const c: SpeakerCandidate = {
          characterId: m.characterId,
          talkativeness: m.talkativeness,
          score: 1.0,
          reason: 'all_respond'
        };
        allCandidates.push(c);
      }
      return allCandidates;
    }
    // auto_director:评分
    const recent: string[] = this.extractRecentSpeakers(input.recentMessages, MAX_RECENT_SPEAKERS_LOOKBACK);
    const scored: SpeakerCandidate[] = [];
    for (let i = 0; i < pool.length; i++) {
      const m: WorldMember = pool[i];
      const score: number = this.scoreCandidate(m, recent, input.scene, input.userRelationships);
      const c: SpeakerCandidate = {
        characterId: m.characterId,
        talkativeness: m.talkativeness,
        score: score,
        reason: 'auto_director'
      };
      scored.push(c);
    }
    // 按得分降序
    scored.sort((a: SpeakerCandidate, b: SpeakerCandidate) => b.score - a.score);
    const limit: number = input.maxSpeakers > 0 ? input.maxSpeakers : 2;
    return scored.slice(0, Math.min(limit, scored.length));
  }

  /**
   * 从最近消息中提取发言者 characterId 序列(按时间倒序)。
   * 仅统计 senderType === 'character' 的消息。
   */
  private extractRecentSpeakers(messages: ChatMessage[], limit: number): string[] {
    const speakers: string[] = [];
    const start: number = messages.length > limit ? messages.length - limit : 0;
    for (let i = messages.length - 1; i >= start; i--) {
      const msg: ChatMessage = messages[i];
      if (msg.senderType === 'character' && msg.senderCharacterId !== undefined) {
        speakers.push(msg.senderCharacterId);
      }
    }
    return speakers;
  }

  /**
   * 计算候选角色得分。
   * - 基础分:talkativeness(0-1)
   * - 最近发言惩罚:每出现一次扣 RECENT_SPEAKER_PENALTY
   * - 场景相关性:角色在当前场景在场加 0.2
   * - 关系紧张度:affinity < 0 或 hostility > 0 加 0.1(戏剧冲突)
   * 得分下限 0。
   */
  private scoreCandidate(
    member: WorldMember,
    recentSpeakers: string[],
    scene: WorldScene | null,
    userRelationships: Map<string, CharacterUserRelationship>
  ): number {
    let score: number = member.talkativeness;
    // 最近发言惩罚
    for (let i = 0; i < recentSpeakers.length; i++) {
      if (recentSpeakers[i] === member.characterId) {
        score -= RECENT_SPEAKER_PENALTY * (recentSpeakers.length - i);
      }
    }
    // 场景相关性
    if (scene !== null) {
      if (scene.presentCharacterIds.indexOf(member.characterId) >= 0) {
        score += 0.2;
      }
    }
    // 关系紧张度
    const rel: CharacterUserRelationship | undefined = userRelationships.get(member.characterId);
    if (rel !== undefined) {
      if (rel.affinity < 0) {
        score += 0.1;
      }
      if (rel.hostility > 0) {
        score += 0.1;
      }
    }
    return score > 0 ? score : 0;
  }
}
