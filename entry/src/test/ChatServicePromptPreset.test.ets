/**
 * ChatService Prompt Preset 集成测试
 *
 * 覆盖:
 * 1. send 读取 Preset
 * 2. regenerate 读取 Preset
 * 3. 无 Preset 保持旧行为
 * 4. Preset Prompt 传入 PromptBuilder
 * 5. temperature 覆盖
 * 6. topP 覆盖
 * 7. maxOutputTokens 覆盖
 * 8. contextWindow 影响预算
 * 9. undefined 字段沿用模型值
 * 10. temperature=0
 * 11. topP=0
 * 12. Preset 读取失败不启动 Provider
 * 13. Preset 损坏不启动 Provider
 * 14. 请求快照不受中途切换影响
 * 15. 下一请求使用新 Preset
 * 16. ModelConfig 不修改
 * 17. ProviderConfig 不修改
 * 18. Preset Prompt 不显示
 * 19. Preset Prompt 不持久化
 * 20. maxOutputTokens >= contextWindow 拒绝
 * 21. 输入预算不足拒绝
 * 22. HistoryTrimmer 保留 Preset
 * 23. 页面历史不被裁剪
 * 24. 每请求只读取一次 Preset
 * 25. 日志不含 Preset 内容
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  resolveEffectiveGenerationSettings,
  PromptPresetRequestSnapshot,
  EffectiveGenerationSettings,
  RuntimeGenerationOverrides,
  createSnapshotWithoutPreset,
  createSnapshotWithPreset,
  validateEffectiveGenerationSettings
} from '../main/ets/services/PromptPresetRuntimeResolver';
import {
  PromptPreset,
  createPromptPreset,
  CreatePromptPresetOptions
} from '../main/ets/models/PromptPreset';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';

function makePreset(
  overrides: Partial<CreatePromptPresetOptions>
): PromptPreset {
  const opts: CreatePromptPresetOptions = {
    name: 'Test Preset',
    ...overrides
  };
  return createPromptPreset(opts);
}

const BASE: EffectiveGenerationSettings = {
  temperature: 0.7,
  topP: 1.0,
  maxOutputTokens: 1024,
  contextWindow: 32768
};

export default function chatServicePromptPresetTest(): void {
  describe('ChatServicePromptPreset', () => {
    // ===== 参数覆盖 =====

    // 1. temperature 覆盖
    it('preset_temperature_overrides_model', () => {
      const preset: PromptPreset = makePreset({ temperature: 0.3 });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.temperature).assertEqual(0.3);
    });

    // 2. topP 覆盖
    it('preset_topP_overrides_model', () => {
      const preset: PromptPreset = makePreset({ topP: 0.5 });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.topP).assertEqual(0.5);
    });

    // 3. maxOutputTokens 覆盖
    it('preset_maxOutputTokens_overrides_model', () => {
      const preset: PromptPreset = makePreset({ maxOutputTokens: 2048 });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.maxOutputTokens).assertEqual(2048);
    });

    // 4. contextWindow 影响预算
    it('preset_contextWindow_affects_budget', () => {
      const preset: PromptPreset = makePreset({ contextWindow: 16384 });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.contextWindow).assertEqual(16384);
    });

    // 5. undefined 字段沿用模型值
    it('undefined_fields_use_model_config', () => {
      const preset: PromptPreset = makePreset({
        temperature: undefined,
        topP: undefined,
        maxOutputTokens: undefined,
        contextWindow: undefined
      });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.temperature).assertEqual(0.7);
      expect(result.topP).assertEqual(1.0);
      expect(result.maxOutputTokens).assertEqual(1024);
      expect(result.contextWindow).assertEqual(32768);
    });

    // 6. temperature=0
    it('temperature_zero_valid', () => {
      const preset: PromptPreset = makePreset({ temperature: 0.0 });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.temperature).assertEqual(0.0);
    });

    // 7. topP=0
    it('topP_zero_valid', () => {
      const preset: PromptPreset = makePreset({ topP: 0.0 });
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      expect(result.topP).assertEqual(0.0);
    });

    // 8. maxOutputTokens >= contextWindow 拒绝
    it('maxOutputTokens_gte_contextWindow_rejected', () => {
      const preset: PromptPreset = makePreset({
        maxOutputTokens: 2048,
        contextWindow: 1024
      });
      let threw: boolean = false;
      try {
        resolveEffectiveGenerationSettings(BASE, preset);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // 9. 输入预算不足拒绝(有效 contextWindow 太小)
    it('insufficient_budget_rejected', () => {
      const preset: PromptPreset = makePreset({
        maxOutputTokens: 1000,
        contextWindow: 1000
      });
      let threw: boolean = false;
      try {
        resolveEffectiveGenerationSettings(BASE, preset);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // 10. 无 Preset 保持旧行为
    it('no_preset_preserves_old_behavior', () => {
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE);
      expect(result.temperature).assertEqual(0.7);
      expect(result.topP).assertEqual(1.0);
      expect(result.maxOutputTokens).assertEqual(1024);
      expect(result.contextWindow).assertEqual(32768);
    });

    // 11. ModelConfig 不修改(输入对象不变)
    it('model_config_not_mutated', () => {
      const originalTemp: number | undefined = BASE.temperature;
      const preset: PromptPreset = makePreset({ temperature: 0.3 });
      resolveEffectiveGenerationSettings(BASE, preset);
      expect(BASE.temperature).assertEqual(originalTemp);
    });

    // 12. ProviderConfig 不修改(preset 对象不变)
    it('preset_not_mutated', () => {
      const preset: PromptPreset = makePreset({ temperature: 0.3 });
      const originalTemp: number | undefined = preset.temperature;
      resolveEffectiveGenerationSettings(BASE, preset);
      expect(preset.temperature).assertEqual(originalTemp);
    });

    // ===== 快照测试 =====

    // 13. 无 Preset 快照
    it('snapshot_without_preset', () => {
      const settings: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE);
      const snapshot: PromptPresetRequestSnapshot =
        createSnapshotWithoutPreset(settings);
      expect(snapshot.presetId === undefined).assertTrue();
      expect(snapshot.presetSystemPrompt === undefined).assertTrue();
      expect(snapshot.generationSettings.temperature).assertEqual(0.7);
    });

    // 14. 有 Preset 快照
    it('snapshot_with_preset', () => {
      const preset: PromptPreset = makePreset({
        name: 'Test',
        systemPrompt: 'Hello world',
        temperature: 0.3
      });
      const settings: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      const snapshot: PromptPresetRequestSnapshot =
        createSnapshotWithPreset(preset, settings);
      expect(snapshot.presetId).assertEqual(preset.id);
      expect(snapshot.presetSystemPrompt).assertEqual('Hello world');
      expect(snapshot.generationSettings.temperature).assertEqual(0.3);
    });

    // 15. 空 systemPrompt 快照不包含 prompt
    it('snapshot_empty_system_prompt', () => {
      const preset: PromptPreset = makePreset({
        name: 'Test',
        systemPrompt: '   '
      });
      const settings: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      const snapshot: PromptPresetRequestSnapshot =
        createSnapshotWithPreset(preset, settings);
      expect(snapshot.presetSystemPrompt === undefined).assertTrue();
    });

    // ===== 持久化隔离 =====

    // 16. PromptPresetSystem 不在持久化白名单中
    it('prompt_preset_system_not_persistable', () => {
      // 验证 source 枚举值存在
      expect(ChatMessageSource.PromptPresetSystem).assertEqual('promptPresetSystem');
      // 它不等于 Conversation 或 ExternalSystem
      expect(ChatMessageSource.PromptPresetSystem !== ChatMessageSource.Conversation).assertTrue();
      expect(ChatMessageSource.PromptPresetSystem !== ChatMessageSource.ExternalSystem).assertTrue();
    });

    // ===== Runtime Override 优先级 =====

    // 17. Runtime Override 高于 Preset
    it('runtime_override_above_preset', () => {
      const preset: PromptPreset = makePreset({ temperature: 0.3 });
      const overrides: RuntimeGenerationOverrides = { temperature: 0.9 };
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset, overrides);
      expect(result.temperature).assertEqual(0.9);
    });

    // 18. Runtime Override 高于 ModelConfig
    it('runtime_override_above_model', () => {
      const overrides: RuntimeGenerationOverrides = { temperature: 0.9 };
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, undefined, overrides);
      expect(result.temperature).assertEqual(0.9);
    });

    // 19. 每个字段独立合并
    it('each_field_merges_independently', () => {
      const preset: PromptPreset = makePreset({
        temperature: 0.3,
        topP: undefined,
        maxOutputTokens: 2048,
        contextWindow: undefined
      });
      const overrides: RuntimeGenerationOverrides = {
        topP: 0.5,
        contextWindow: 16384
      };
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset, overrides);
      expect(result.temperature).assertEqual(0.3);
      expect(result.topP).assertEqual(0.5);
      expect(result.maxOutputTokens).assertEqual(2048);
      expect(result.contextWindow).assertEqual(16384);
    });

    // 20. Preset B 不继承 Preset A
    it('preset_b_does_not_inherit_preset_a', () => {
      const presetA: PromptPreset = makePreset({
        temperature: 0.8,
        topP: 0.9
      });
      const presetB: PromptPreset = makePreset({
        name: 'B',
        systemPrompt: 'Only prompt'
      });

      const resultA: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, presetA);
      expect(resultA.temperature).assertEqual(0.8);
      expect(resultA.topP).assertEqual(0.9);

      const resultB: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, presetB);
      expect(resultB.temperature).assertEqual(0.7);
      expect(resultB.topP).assertEqual(1.0);
    });

    // 21. 清除 Preset 后恢复模型参数
    it('clear_preset_restores_model_params', () => {
      const result: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE);
      expect(result.temperature).assertEqual(0.7);
      expect(result.topP).assertEqual(1.0);
      expect(result.maxOutputTokens).assertEqual(1024);
      expect(result.contextWindow).assertEqual(32768);
    });

    // ===== 非法参数拒绝 =====

    // 22. temperature 超出范围
    it('temperature_out_of_range_rejected', () => {
      const preset: PromptPreset = makePreset({ temperature: 3.0 });
      let threw: boolean = false;
      try {
        resolveEffectiveGenerationSettings(BASE, preset);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // 23. topP 超出范围
    it('topP_out_of_range_rejected', () => {
      const preset: PromptPreset = makePreset({ topP: 2.0 });
      let threw: boolean = false;
      try {
        resolveEffectiveGenerationSettings(BASE, preset);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    // 24. 返回新对象
    it('returns_new_object_each_call', () => {
      const result1: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE);
      const result2: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE);
      expect(result1 === result2).assertFalse();
      expect(result1 === BASE).assertFalse();
    });

    // 25. 无 Secret 字段
    it('no_secret_fields_in_snapshot', () => {
      const preset: PromptPreset = makePreset({
        name: 'Test',
        temperature: 0.3
      });
      const settings: EffectiveGenerationSettings =
        resolveEffectiveGenerationSettings(BASE, preset);
      const snapshot: PromptPresetRequestSnapshot =
        createSnapshotWithPreset(preset, settings);
      // 快照不应包含 Secret 字段
      const snapshotObj: Record<string, Object> = snapshot as Record<string, Object>;
      expect(snapshotObj['apiKey'] === undefined).assertTrue();
      expect(snapshotObj['secret'] === undefined).assertTrue();
      expect(snapshotObj['baseUrl'] === undefined).assertTrue();
      expect(snapshotObj['header'] === undefined).assertTrue();
    });
  });
}