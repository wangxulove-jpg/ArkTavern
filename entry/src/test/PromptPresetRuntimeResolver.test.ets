/**
 * PromptPresetRuntimeResolver 单元测试
 *
 * 覆盖:参数合并优先级、undefined 不覆盖、0 值正确传递、
 * 不修改输入、校验规则、非法组合拒绝。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  resolveEffectiveGenerationSettings,
  validateEffectiveGenerationSettings,
  EffectiveGenerationSettings,
  RuntimeGenerationOverrides
} from '../main/ets/services/PromptPresetRuntimeResolver';
import {
  PromptPreset,
  createPromptPreset,
  CreatePromptPresetOptions
} from '../main/ets/models/PromptPreset';

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

export default function promptPresetRuntimeResolverTest() {
  describe('PromptPresetRuntimeResolver', () => {
    describe('resolveEffectiveGenerationSettings', () => {
      // 1. 无 Preset 使用 base
      it('no_preset_uses_base', () => {
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE);
        expect(result.temperature).assertEqual(0.7);
        expect(result.topP).assertEqual(1.0);
        expect(result.maxOutputTokens).assertEqual(1024);
        expect(result.contextWindow).assertEqual(32768);
      });

      // 2. Preset temperature 覆盖
      it('preset_temperature_overrides_base', () => {
        const preset: PromptPreset = makePreset({ temperature: 0.3 });
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset);
        expect(result.temperature).assertEqual(0.3);
        expect(result.topP).assertEqual(1.0);
        expect(result.maxOutputTokens).assertEqual(1024);
        expect(result.contextWindow).assertEqual(32768);
      });

      // 3. Preset topP 覆盖
      it('preset_topP_overrides_base', () => {
        const preset: PromptPreset = makePreset({ topP: 0.5 });
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset);
        expect(result.temperature).assertEqual(0.7);
        expect(result.topP).assertEqual(0.5);
      });

      // 4. Preset maxOutputTokens 覆盖
      it('preset_maxOutputTokens_overrides_base', () => {
        const preset: PromptPreset = makePreset({ maxOutputTokens: 2048 });
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset);
        expect(result.maxOutputTokens).assertEqual(2048);
      });

      // 5. Preset contextWindow 覆盖
      it('preset_contextWindow_overrides_base', () => {
        const preset: PromptPreset = makePreset({ contextWindow: 16384 });
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset);
        expect(result.contextWindow).assertEqual(16384);
      });

      // 6. Preset undefined 不覆盖
      it('preset_undefined_field_does_not_override', () => {
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

      // 7. temperature=0 正确覆盖
      it('temperature_zero_overrides_correctly', () => {
        const preset: PromptPreset = makePreset({ temperature: 0.0 });
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset);
        expect(result.temperature).assertEqual(0.0);
      });

      // 8. topP=0 正确覆盖
      it('topP_zero_overrides_correctly', () => {
        const preset: PromptPreset = makePreset({ topP: 0.0 });
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset);
        expect(result.topP).assertEqual(0.0);
      });

      // 9. runtime override 高于 Preset
      it('runtime_override_above_preset', () => {
        const preset: PromptPreset = makePreset({ temperature: 0.3 });
        const overrides: RuntimeGenerationOverrides = { temperature: 0.9 };
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset, overrides);
        expect(result.temperature).assertEqual(0.9);
      });

      // 10. runtime undefined 不覆盖 Preset
      it('runtime_undefined_does_not_override_preset', () => {
        const preset: PromptPreset = makePreset({ temperature: 0.3 });
        const overrides: RuntimeGenerationOverrides = {};
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE, preset, overrides);
        expect(result.temperature).assertEqual(0.3);
      });

      // 11. 每个字段独立合并
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

      // 12. base 对象不修改
      it('base_object_not_mutated', () => {
        const originalTemp: number | undefined = BASE.temperature;
        const preset: PromptPreset = makePreset({ temperature: 0.3 });
        resolveEffectiveGenerationSettings(BASE, preset);
        expect(BASE.temperature).assertEqual(originalTemp);
      });

      // 13. preset 对象不修改
      it('preset_object_not_mutated', () => {
        const preset: PromptPreset = makePreset({ temperature: 0.3 });
        const originalTemp: number | undefined = preset.temperature;
        resolveEffectiveGenerationSettings(BASE, preset);
        expect(preset.temperature).assertEqual(originalTemp);
      });

      // 14. runtime 对象不修改
      it('runtime_object_not_mutated', () => {
        const overrides: RuntimeGenerationOverrides = { temperature: 0.9 };
        const originalTemp: number | undefined = overrides.temperature;
        resolveEffectiveGenerationSettings(BASE, undefined, overrides);
        expect(overrides.temperature).assertEqual(originalTemp);
      });

      // 15. 返回新对象
      it('returns_new_object', () => {
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE);
        const result2: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE);
        expect(result === BASE).assertFalse();
        expect(result === result2).assertFalse();
      });

      // 16. maxOutputTokens >= contextWindow 拒绝
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

      // 17. 非法合并结果拒绝(temperature 超出范围)
      it('invalid_temperature_range_rejected', () => {
        const preset: PromptPreset = makePreset({ temperature: 3.0 });
        let threw: boolean = false;
        try {
          resolveEffectiveGenerationSettings(BASE, preset);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      });

      // 18. 不包含 Secret 字段
      it('no_secret_fields_in_result', () => {
        const result: EffectiveGenerationSettings =
          resolveEffectiveGenerationSettings(BASE);
        const resultObj: Record<string, Object> = result as Record<string, Object>;
        expect(resultObj['apiKey'] === undefined).assertTrue();
        expect(resultObj['secret'] === undefined).assertTrue();
        expect(resultObj['baseUrl'] === undefined).assertTrue();
      });
    });

    describe('validateEffectiveGenerationSettings', () => {
      it('valid_settings_pass', () => {
        const settings: EffectiveGenerationSettings = {
          temperature: 0.7,
          topP: 1.0,
          maxOutputTokens: 1024,
          contextWindow: 32768
        };
        // 不应抛异常
        validateEffectiveGenerationSettings(settings);
      });

      it('all_undefined_pass', () => {
        const settings: EffectiveGenerationSettings = {};
        validateEffectiveGenerationSettings(settings);
      });

      it('maxOutputTokens_eq_contextWindow_rejected', () => {
        const settings: EffectiveGenerationSettings = {
          maxOutputTokens: 1000,
          contextWindow: 1000
        };
        let threw: boolean = false;
        try {
          validateEffectiveGenerationSettings(settings);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      });

      it('maxOutputTokens_gt_contextWindow_rejected', () => {
        const settings: EffectiveGenerationSettings = {
          maxOutputTokens: 2000,
          contextWindow: 1000
        };
        let threw: boolean = false;
        try {
          validateEffectiveGenerationSettings(settings);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      });
    });
  });
}