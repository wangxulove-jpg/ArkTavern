/**
 * GroupPromptInspectionStore 群聊 Prompt 诊断快照内存存储(G-CONTEXT-INSPECTOR-1)
 *
 * 职责:
 * - 持有最近一次 Prompt 诊断快照(每角色每群聊只保留最近一次)
 * - 纯内存,不持久化,不写日志完整内容
 * - 不记录 API Key / Authorization / 敏感信息
 *
 * 存储键: groupConversationId + speakerCharacterId
 * 生命周期: 应用进程内,页面/ViewModel 读取后不清理,下次同键覆盖
 *
 * 线程安全:
 * - ArkTS 单线程模型,无需同步
 * - Map 操作均为同步
 */

import { GroupPromptInspectionSnapshot } from '../../models/groupchat/GroupPromptInspectionModels';

export class GroupPromptInspectionStore {
  private readonly snapshots: Map<string, GroupPromptInspectionSnapshot> =
    new Map<string, GroupPromptInspectionSnapshot>();

  private buildKey(groupConversationId: string, speakerCharacterId: string): string {
    return groupConversationId + ':' + speakerCharacterId;
  }

  store(snapshot: GroupPromptInspectionSnapshot): void {
    const key: string = this.buildKey(
      snapshot.groupConversationId,
      snapshot.speakerCharacterId
    );
    this.snapshots.set(key, snapshot);
  }

  get(
    groupConversationId: string,
    speakerCharacterId: string
  ): GroupPromptInspectionSnapshot | undefined {
    const key: string = this.buildKey(groupConversationId, speakerCharacterId);
    return this.snapshots.get(key);
  }

  has(groupConversationId: string, speakerCharacterId: string): boolean {
    const key: string = this.buildKey(groupConversationId, speakerCharacterId);
    return this.snapshots.has(key);
  }

  remove(groupConversationId: string, speakerCharacterId: string): void {
    const key: string = this.buildKey(groupConversationId, speakerCharacterId);
    this.snapshots.delete(key);
  }

  clear(): void {
    this.snapshots.clear();
  }
}
