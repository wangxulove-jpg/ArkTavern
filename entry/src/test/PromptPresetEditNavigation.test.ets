/**
 * PromptPresetEditNavigation 路由参数解析单元测试
 *
 * 覆盖 parsePresetEditRouteParam 全部边界:
 * - undefined 参数进入 create 模式
 * - 空字符串 presetId 进入 create 模式
 * - 有效 ID 进入 edit 模式
 * - 缺少 presetId 返回参数错误
 * - 非字符串 presetId 返回参数错误
 * - 不修改参数对象
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  parsePresetEditRouteParam,
  ParsedPresetEditRoute
} from '../main/ets/viewmodels/PromptPresetEditViewModel';

export default function promptPresetEditNavigationTest() {
  describe('PromptPresetEditNavigation', () => {
    describe('parsePresetEditRouteParam', () => {

      it('undefined_param_enters_create_mode', () => {
        const result: ParsedPresetEditRoute = parsePresetEditRouteParam(undefined);
        expect(result.presetId).assertUndefined();
        expect(result.error).assertUndefined();
      });

      it('empty_presetId_enters_create_mode', () => {
        const result: ParsedPresetEditRoute = parsePresetEditRouteParam({ presetId: '' });
        expect(result.presetId).assertUndefined();
        expect(result.error).assertUndefined();
      });

      it('valid_presetId_enters_edit_mode', () => {
        const result: ParsedPresetEditRoute = parsePresetEditRouteParam({ presetId: 'valid-id-123' });
        expect(result.presetId).assertEquals('valid-id-123');
        expect(result.error).assertUndefined();
      });

      it('missing_presetId_returns_error', () => {
        const result: ParsedPresetEditRoute = parsePresetEditRouteParam({});
        expect(result.presetId).assertUndefined();
        expect(result.error).assertEquals('页面参数错误:缺少 presetId');
      });

      it('non_string_presetId_returns_error', () => {
        const result: ParsedPresetEditRoute = parsePresetEditRouteParam({ presetId: 123 });
        expect(result.presetId).assertUndefined();
        expect(result.error).assertEquals('页面参数错误:presetId 类型无效');
      });

      it('does_not_mutate_input_object', () => {
        const input: Object = { presetId: 'test-id' };
        parsePresetEditRouteParam(input);
        const record = input as Record<string, Object>;
        expect(record['presetId']).assertEquals('test-id');
      });

    });
  });
}