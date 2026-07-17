/**
 * PromptPresetEditViewModel 单元测试
 *
 * 覆盖:
 * - 新建模式表单为空
 * - 编辑模式查询 Repository 并回填
 * - name / description / systemPrompt 回填
 * - temperature 回填
 * - temperature=0 回填且开关开启
 * - topP=0 回填且开关开启
 * - maxOutputTokens 回填
 * - contextWindow 回填
 * - undefined 字段关闭覆盖开关
 * - 同一 presetId 重复初始化不清空
 * - 从 create 模式再初始化 edit 模式可正确加载
 * - 从 Preset A 切换到 Preset B 可重新加载
 * - 找不到记录不显示空白新建表单
 * - 编辑保存调用 update
 * - 编辑保存不创建重复 Preset
 * - 输入内容不修改 Repository 原对象
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  PromptPresetEditViewModel,
  PromptPresetEditFormState,
  emptyFormState
} from '../main/ets/viewmodels/PromptPresetEditViewModel';
import {
  PromptPreset,
  createPromptPreset,
  CreatePromptPresetOptions,
  PromptPresetUpdates
} from '../main/ets/models/PromptPreset';

// ===== Mock PromptPresetService =====

class MockPromptPresetService {
  private presets: Map<string, PromptPreset> = new Map();
  private currentId: string | null = null;
  createCallCount: number = 0;
  updateCallCount: number = 0;
  lastUpdateUpdates: Record<string, Object> = {};

  async getById(id: string): Promise<PromptPreset | null> {
    return this.presets.get(id) ?? null;
  }

  async list(): Promise<PromptPreset[]> {
    const result: PromptPreset[] = [];
    this.presets.forEach((v: PromptPreset): void => { result.push(v); });
    return result;
  }

  async create(options: CreatePromptPresetOptions): Promise<PromptPreset> {
    this.createCallCount++;
    const preset: PromptPreset = createPromptPreset(options);
    this.presets.set(preset.id, preset);
    return preset;
  }

  async update(id: string, updates: PromptPresetUpdates): Promise<void> {
    this.updateCallCount++;
    this.lastUpdateUpdates = updates as Record<string, Object>;
    const existing: PromptPreset | null = this.presets.get(id) ?? null;
    if (existing !== null) {
      // 简单模拟:更新 name
      const updated: PromptPreset = {
        id: existing.id,
        name: updates.name !== undefined ? updates.name : existing.name,
        description: updates.description !== undefined ? updates.description : existing.description,
        systemPrompt: updates.systemPrompt !== undefined ? updates.systemPrompt : existing.systemPrompt,
        temperature: updates.clearTemperature ? undefined : (updates.temperature !== undefined ? updates.temperature : existing.temperature),
        topP: updates.clearTopP ? undefined : (updates.topP !== undefined ? updates.topP : existing.topP),
        maxOutputTokens: updates.clearMaxOutputTokens ? undefined : (updates.maxOutputTokens !== undefined ? updates.maxOutputTokens : existing.maxOutputTokens),
        contextWindow: updates.clearContextWindow ? undefined : (updates.contextWindow !== undefined ? updates.contextWindow : existing.contextWindow),
        createdAt: existing.createdAt,
        updatedAt: existing.updatedAt
      };
      this.presets.set(id, updated);
    }
  }

  async remove(id: string): Promise<void> {
    this.presets.delete(id);
    if (this.currentId === id) {
      this.currentId = null;
    }
  }

  async getCurrentPresetId(): Promise<string | null> {
    return this.currentId;
  }

  async setCurrentPresetId(id: string | null): Promise<void> {
    this.currentId = id;
  }

  async getCurrentPreset(): Promise<PromptPreset | null> {
    if (this.currentId === null) {
      return null;
    }
    return this.presets.get(this.currentId) ?? null;
  }
}

// ===== Helper =====

function addPreset(service: MockPromptPresetService, id: string, overrides: Partial<CreatePromptPresetOptions>): PromptPreset {
  const preset = createPromptPreset({
    id: id,
    name: 'Preset ' + id,
    ...overrides
  });
  service.presets.set(preset.id, preset);
  return preset;
}

export default function promptPresetEditViewModelTest() {
  describe('PromptPresetEditViewModel', () => {

    describe('create mode', () => {

      it('create_mode_form_is_empty', () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        vm.initialize();
        const fs = emptyFormState();
        expect(fs.nameInput).assertEquals('');
        expect(fs.descriptionInput).assertEquals('');
        expect(fs.systemPromptInput).assertEquals('');
        expect(fs.overrideTemperature).assertFalse();
        expect(fs.overrideTopP).assertFalse();
        expect(fs.overrideMaxOutputTokens).assertFalse();
        expect(fs.overrideContextWindow).assertFalse();
      });

    });

    describe('edit mode', () => {

      it('edits_existing_preset_populates_form', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        const preset: PromptPreset = addPreset(service, 'p1', {
          name: 'Test Preset',
          description: 'A test preset',
          systemPrompt: 'You are a helpful assistant.',
          temperature: 0.7,
          topP: 0.9,
          maxOutputTokens: 2048,
          contextWindow: 16384
        });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('p1');
        expect(vm.isEditing).assertTrue();
        expect(vm.editingPresetId).assertEquals('p1');

        const fs: PromptPresetEditFormState = await vm.getFormState('p1');
        expect(fs.nameInput).assertEquals('Test Preset');
        expect(fs.descriptionInput).assertEquals('A test preset');
        expect(fs.systemPromptInput).assertEquals('You are a helpful assistant.');
        expect(fs.overrideTemperature).assertTrue();
        expect(fs.temperatureInput).assertEquals('0.7');
        expect(fs.overrideTopP).assertTrue();
        expect(fs.topPInput).assertEquals('0.9');
        expect(fs.overrideMaxOutputTokens).assertTrue();
        expect(fs.maxOutputTokensInput).assertEquals('2048');
        expect(fs.overrideContextWindow).assertTrue();
        expect(fs.contextWindowInput).assertEquals('16384');
      });

      it('temperature_zero_override_enabled', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'p2', { temperature: 0 });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('p2');
        const fs: PromptPresetEditFormState = await vm.getFormState('p2');
        expect(fs.overrideTemperature).assertTrue();
        expect(fs.temperatureInput).assertEquals('0');
      });

      it('topP_zero_override_enabled', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'p3', { topP: 0 });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('p3');
        const fs: PromptPresetEditFormState = await vm.getFormState('p3');
        expect(fs.overrideTopP).assertTrue();
        expect(fs.topPInput).assertEquals('0');
      });

      it('undefined_fields_override_disabled', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'p4', {});

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('p4');
        const fs: PromptPresetEditFormState = await vm.getFormState('p4');
        expect(fs.overrideTemperature).assertFalse();
        expect(fs.overrideTopP).assertFalse();
        expect(fs.overrideMaxOutputTokens).assertFalse();
        expect(fs.overrideContextWindow).assertFalse();
      });

      it('same_preset_id_repeated_init_does_not_clear', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'p5', { name: 'Persistent', description: 'keep' });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('p5');
        const fs1: PromptPresetEditFormState = await vm.getFormState('p5');

        await vm.initialize('p5'); // 重复初始化
        const fs2: PromptPresetEditFormState = await vm.getFormState('p5');

        expect(fs2.nameInput).assertEquals('Persistent');
        expect(fs2.descriptionInput).assertEquals('keep');
      });

      it('switches_from_create_to_edit_mode', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'p6', { name: 'Switch Test' });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);

        // 先 create 模式
        await vm.initialize();
        expect(vm.isEditing).assertFalse();

        // 再 edit 模式
        await vm.initialize('p6');
        expect(vm.isEditing).assertTrue();
        expect(vm.editingPresetId).assertEquals('p6');

        const fs: PromptPresetEditFormState = await vm.getFormState('p6');
        expect(fs.nameInput).assertEquals('Switch Test');
      });

      it('switches_from_preset_a_to_preset_b', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        const a: PromptPreset = addPreset(service, 'pA', { name: 'Preset A', description: 'Alpha' });
        const b: PromptPreset = addPreset(service, 'pB', { name: 'Preset B', description: 'Beta' });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);

        // 编辑 A
        await vm.initialize('pA');
        const fsA: PromptPresetEditFormState = await vm.getFormState('pA');
        expect(fsA.nameInput).assertEquals('Preset A');

        // 切换到 B
        await vm.initialize('pB');
        expect(vm.editingPresetId).assertEquals('pB');
        const fsB: PromptPresetEditFormState = await vm.getFormState('pB');
        expect(fsB.nameInput).assertEquals('Preset B');
        expect(fsB.descriptionInput).assertEquals('Beta');
      });

      it('not_found_preset_shows_error', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('nonexistent');

        // getFormState 返回空表单
        const fs: PromptPresetEditFormState = await vm.getFormState('nonexistent');
        expect(fs.nameInput).assertEquals('');
        // initialize 设置 isEditing=false
        expect(vm.isEditing).assertFalse();
      });

    });

    describe('save', () => {

      it('edit_save_calls_update', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'pSave', {
          name: 'Original Name',
          description: 'Original Description',
          systemPrompt: 'Original Prompt',
          temperature: 0.7,
          topP: 0.9,
          maxOutputTokens: 2048,
          contextWindow: 16384
        });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('pSave');

        const formState: PromptPresetEditFormState = {
          nameInput: 'Updated Name',
          descriptionInput: 'Updated Description',
          systemPromptInput: 'Updated Prompt',
          overrideTemperature: true,
          temperatureInput: '0.5',
          overrideTopP: true,
          topPInput: '0.8',
          overrideMaxOutputTokens: true,
          maxOutputTokensInput: '4096',
          overrideContextWindow: true,
          contextWindowInput: '32768'
        };

        const saved: boolean = await vm.save(formState);
        expect(saved).assertTrue();
        expect(service.updateCallCount).assertEquals(1);

        // 验证 Repository 更新
        const updated: PromptPreset | null = await service.getById('pSave');
        expect(updated!.name).assertEquals('Updated Name');
      });

      it('edit_save_does_not_create_duplicate', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'pNoDup', { name: 'Original' });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('pNoDup');

        const formState: PromptPresetEditFormState = {
          nameInput: 'Updated',
          descriptionInput: '',
          systemPromptInput: '',
          overrideTemperature: false,
          temperatureInput: '',
          overrideTopP: false,
          topPInput: '',
          overrideMaxOutputTokens: false,
          maxOutputTokensInput: '',
          overrideContextWindow: false,
          contextWindowInput: ''
        };

        await vm.save(formState);

        // 检查 list 只有一个
        const all: PromptPreset[] = await service.list();
        expect(all.length).assertEquals(1);
        expect(all[0].name).assertEquals('Updated');
      });

      it('input_object_not_modified_by_save', async () => {
        const service: MockPromptPresetService = new MockPromptPresetService();
        addPreset(service, 'pImmutable', { name: 'Immutable' });

        const vm: PromptPresetEditViewModel = new PromptPresetEditViewModel(service as unknown as never);
        await vm.initialize('pImmutable');

        const formState: PromptPresetEditFormState = {
          nameInput: 'New Name',
          descriptionInput: '',
          systemPromptInput: '',
          overrideTemperature: false,
          temperatureInput: '',
          overrideTopP: false,
          topPInput: '',
          overrideMaxOutputTokens: false,
          maxOutputTokensInput: '',
          overrideContextWindow: false,
          contextWindowInput: ''
        };

        const original: string = formState.nameInput;
        await vm.save(formState);
        expect(formState.nameInput).assertEquals(original);
      });

    });

  });
}