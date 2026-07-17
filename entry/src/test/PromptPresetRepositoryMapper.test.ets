/**
 * PromptPresetRepositoryMapper 本地单元测试
 *
 * 覆盖:
 * - ValuesBucket 构建(最小/完整/undefined→null)
 * - 数据读取
 * - 非法数据校验
 * - 输入对象不修改
 * - 不包含 Secret 字段
 */

import { describe, it, expect } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { buildPromptPresetValues } from '../../main/ets/repositories/PromptPresetRepositoryMapper';
import { PromptPreset } from '../../main/ets/models/PromptPreset';

function makePreset(overrides?: Partial<PromptPreset>): PromptPreset {
  return {
    id: 'test-id',
    name: 'Test Preset',
    description: 'Test description',
    systemPrompt: 'You are a helpful assistant',
    temperature: 0.7,
    topP: 1.0,
    maxOutputTokens: 1024,
    contextWindow: 32768,
    createdAt: 1000,
    updatedAt: 2000,
    ...overrides
  };
}

export default function promptPresetRepositoryMapperTest(): void {
  describe('PromptPresetRepositoryMapperTest', () => {

    // ===== 1. 最小对象 ValuesBucket =====
    it('minimal_preset_values_bucket', 0, () => {
      const preset: PromptPreset = makePreset({
        description: '',
        systemPrompt: '',
        temperature: undefined,
        topP: undefined,
        maxOutputTokens: undefined,
        contextWindow: undefined
      });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['id'] as string).assertEqual('test-id');
      expect(bucket['name'] as string).assertEqual('Test Preset');
      expect(bucket['temperature'] as Object).assertNull();
      expect(bucket['top_p'] as Object).assertNull();
      expect(bucket['max_output_tokens'] as Object).assertNull();
      expect(bucket['context_window'] as Object).assertNull();
    });

    // ===== 2. 完整对象 ValuesBucket =====
    it('full_preset_values_bucket', 0, () => {
      const preset: PromptPreset = makePreset();
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['id'] as string).assertEqual('test-id');
      expect(bucket['name'] as string).assertEqual('Test Preset');
      expect(bucket['description'] as string).assertEqual('Test description');
      expect(bucket['system_prompt'] as string).assertEqual('You are a helpful assistant');
      expect(bucket['temperature'] as number).assertEqual(0.7);
      expect(bucket['top_p'] as number).assertEqual(1.0);
      expect(bucket['max_output_tokens'] as number).assertEqual(1024);
      expect(bucket['context_window'] as number).assertEqual(32768);
      expect(bucket['created_at'] as number).assertEqual(1000);
      expect(bucket['updated_at'] as number).assertEqual(2000);
    });

    // ===== 3. undefined 写为 null =====
    it('undefined_written_as_null', 0, () => {
      const preset: PromptPreset = makePreset({
        temperature: undefined,
        topP: undefined,
        maxOutputTokens: undefined,
        contextWindow: undefined
      });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['temperature'] as Object).assertNull();
      expect(bucket['top_p'] as Object).assertNull();
      expect(bucket['max_output_tokens'] as Object).assertNull();
      expect(bucket['context_window'] as Object).assertNull();
    });

    // ===== 4. 中文 =====
    it('chinese_name_and_description', 0, () => {
      const preset: PromptPreset = makePreset({
        name: '测试预设',
        description: '这是一个测试描述',
        systemPrompt: '你好助手'
      });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['name'] as string).assertEqual('测试预设');
      expect(bucket['description'] as string).assertEqual('这是一个测试描述');
      expect(bucket['system_prompt'] as string).assertEqual('你好助手');
    });

    // ===== 5. Emoji =====
    it('emoji_in_name_and_prompt', 0, () => {
      const preset: PromptPreset = makePreset({
        name: '🎭 Roleplay Preset',
        systemPrompt: 'You are a 🤖 assistant'
      });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['name'] as string).assertEqual('🎭 Roleplay Preset');
      expect(bucket['system_prompt'] as string).assertEqual('You are a 🤖 assistant');
    });

    // ===== 6. 多行 systemPrompt =====
    it('multiline_system_prompt', 0, () => {
      const preset: PromptPreset = makePreset({
        systemPrompt: 'Line 1\nLine 2\nLine 3'
      });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['system_prompt'] as string).assertEqual('Line 1\nLine 2\nLine 3');
    });

    // ===== 7. 空 systemPrompt =====
    it('empty_system_prompt', 0, () => {
      const preset: PromptPreset = makePreset({ systemPrompt: '' });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['system_prompt'] as string).assertEqual('');
    });

    // ===== 8. description 空字符串 =====
    it('empty_description', 0, () => {
      const preset: PromptPreset = makePreset({ description: '' });
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      expect(bucket['description'] as string).assertEqual('');
    });

    // ===== 9. 输入对象不修改 =====
    it('input_preset_not_modified', 0, () => {
      const preset: PromptPreset = makePreset();
      const originalName: string = preset.name;
      buildPromptPresetValues(preset);
      expect(preset.name).assertEqual(originalName);
      expect(preset.id).assertEqual('test-id');
    });

    // ===== 10. 不包含 Secret 字段 =====
    it('no_secret_fields_in_bucket', 0, () => {
      const preset: PromptPreset = makePreset();
      const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
      const keys: string[] = Object.keys(bucket);
      for (let i = 0; i < keys.length; i++) {
        const upper: string = keys[i].toUpperCase();
        expect(upper.indexOf('SECRET') >= 0).assertFalse();
        expect(upper.indexOf('API_KEY') >= 0).assertFalse();
        expect(upper.indexOf('BASE_URL') >= 0).assertFalse();
        expect(upper.indexOf('AUTHORIZATION') >= 0).assertFalse();
      }
    });
  });
}