/**
 * PngCharacterCardParser 单元测试
 *
 * 覆盖:
 * - 正常 V2 PNG(chara tEXt chunk)
 * - 正常 V3 PNG(ccv3 tEXt chunk)
 * - V3 优先于 V2
 * - tEXt chunk 解析(Latin-1 文本)
 * - 无元数据 PNG
 * - PNG 签名错误
 * - chunk 长度异常/越界
 * - Base64 非法
 * - 超大文件
 * - 文件太小
 * - 空 Base64 文本
 * - URL-safe Base64
 */

import { parsePngCharacterCard, PngParseResult, PngTextChunk } from '../main/ets/parser/PngCharacterCardParser';
import { describe, it, expect } from '@ohos/hypium';

// ===== PNG 构建辅助函数 =====

/** PNG 签名 */
const PNG_SIG: number[] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/** 将字符串转为 UTF-8 字节数组 */
function stringToUtf8Bytes(input: string): number[] {
  const result: number[] = [];
  for (let i = 0; i < input.length; i++) {
    const cp: number = input.charCodeAt(i);
    if (cp < 0x80) {
      result.push(cp);
    } else if (cp < 0x800) {
      result.push(0xC0 | (cp >> 6));
      result.push(0x80 | (cp & 0x3F));
    } else {
      result.push(0xE0 | (cp >> 12));
      result.push(0x80 | ((cp >> 6) & 0x3F));
      result.push(0x80 | (cp & 0x3F));
    }
  }
  return result;
}

/** Base64 编码(基于 UTF-8 字节,仅用于测试) */
function base64Encode(input: string): string {
  const utf8Bytes: number[] = stringToUtf8Bytes(input);
  const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let result: string = '';
  let i: number = 0;
  while (i < utf8Bytes.length) {
    const b0: number = utf8Bytes[i];
    const b1: number = i + 1 < utf8Bytes.length ? utf8Bytes[i + 1] : 0;
    const b2: number = i + 2 < utf8Bytes.length ? utf8Bytes[i + 2] : 0;
    const triple: number = (b0 << 16) | (b1 << 8) | b2;
    result += chars.charAt((triple >> 18) & 0x3F);
    result += chars.charAt((triple >> 12) & 0x3F);
    if (i + 1 < utf8Bytes.length) {
      result += chars.charAt((triple >> 6) & 0x3F);
    } else {
      result += '=';
    }
    if (i + 2 < utf8Bytes.length) {
      result += chars.charAt(triple & 0x3F);
    } else {
      result += '=';
    }
    i += 3;
  }
  return result;
}

/** 写入 4 字节 big-endian 整数 */
function writeUint32BE(arr: number[], offset: number, value: number): void {
  arr[offset] = (value >> 24) & 0xFF;
  arr[offset + 1] = (value >> 16) & 0xFF;
  arr[offset + 2] = (value >> 8) & 0xFF;
  arr[offset + 3] = value & 0xFF;
}

/** 写入 ASCII 字符串 */
function writeAscii(arr: number[], offset: number, str: string): void {
  for (let i = 0; i < str.length; i++) {
    arr[offset + i] = str.charCodeAt(i) & 0xFF;
  }
}

/** 写入字节 */
function writeBytes(arr: number[], offset: number, bytes: number[]): void {
  for (let i = 0; i < bytes.length; i++) {
    arr[offset + i] = bytes[i] & 0xFF;
  }
}

/** 构建 PNG chunk: 4B length + 4B type + data + 4B CRC */
function buildChunk(type: string, data: number[]): number[] {
  const chunk: number[] = new Array<number>(12 + data.length);
  writeUint32BE(chunk, 0, data.length);
  writeAscii(chunk, 4, type);
  writeBytes(chunk, 8, data);
  // CRC 用零填充(解析器不校验)
  writeUint32BE(chunk, 8 + data.length, 0);
  return chunk;
}

/** 构建 tEXt chunk: keyword\0text */
function buildTextChunk(keyword: string, text: string): number[] {
  const kwBytes: number[] = [];
  for (let i = 0; i < keyword.length; i++) {
    kwBytes.push(keyword.charCodeAt(i) & 0xFF);
  }
  kwBytes.push(0x00); // null 分隔符
  for (let i = 0; i < text.length; i++) {
    kwBytes.push(text.charCodeAt(i) & 0xFF);
  }
  return buildChunk('tEXt', kwBytes);
}

/** 最小 IHDR chunk: 13 字节数据 */
function buildIhdrChunk(): number[] {
  const data: number[] = new Array<number>(13);
  writeUint32BE(data, 0, 1);  // width=1
  writeUint32BE(data, 4, 1);  // height=1
  data[8] = 8;   // bit depth=8
  data[9] = 2;   // color type=RGB
  data[10] = 0;  // compression
  data[11] = 0;  // filter
  data[12] = 0;  // interlace
  return buildChunk('IHDR', data);
}

/** 最小 IEND chunk */
function buildIendChunk(): number[] {
  return buildChunk('IEND', []);
}

/** 构建完整 PNG 文件字节数组 */
function buildPngBytes(chunks: number[][]): Uint8Array {
  const totalLen: number = PNG_SIG.length + chunks.reduce((sum, c) => sum + c.length, 0);
  const arr: number[] = new Array<number>(totalLen);
  let offset: number = 0;
  writeBytes(arr, offset, PNG_SIG);
  offset += PNG_SIG.length;
  for (let i = 0; i < chunks.length; i++) {
    writeBytes(arr, offset, chunks[i]);
    offset += chunks[i].length;
  }
  return new Uint8Array(arr);
}

/** 构建含角色卡元数据的 PNG */
function buildCharacterPng(keyword: string, json: string): Uint8Array {
  const textChunk: number[] = buildTextChunk(keyword, base64Encode(json));
  return buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
}

// ===== 测试角色 JSON =====

const V2_CHARACTER_JSON: string = JSON.stringify({
  spec: 'chara_card_v2',
  spec_version: '2.0',
  data: {
    name: 'V2测试角色',
    description: 'V2测试描述',
    personality: 'V2测试性格',
    scenario: 'V2测试场景',
    first_mes: 'V2开场白',
    system_prompt: 'V2系统提示',
    mes_example: ''
  }
});

const V3_CHARACTER_JSON: string = JSON.stringify({
  spec: 'chara_card_v3',
  spec_version: '3.0',
  data: {
    name: 'V3测试角色',
    description: 'V3测试描述',
    personality: 'V3测试性格',
    scenario: 'V3测试场景',
    first_mes: 'V3开场白',
    system_prompt: 'V3系统提示',
    extensions: {}
  }
});

export default function pngParserTest() {
  describe('PngCharacterCardParser', () => {

    // ===== 正常 V2 PNG =====

    it('V2_PNG_chara_keyword', () => {
      const bytes: Uint8Array = buildCharacterPng('chara', V2_CHARACTER_JSON);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.sourceFormat).assertEqual('chara_card_v2');
      // 解码后的 JSON 应包含原始数据
      expect(result.jsonString.includes('V2测试角色')).assertTrue();
      expect(result.error).assertEqual('');
    });

    it('V2_PNG_decoded_json_contains_original_fields', () => {
      const bytes: Uint8Array = buildCharacterPng('chara', V2_CHARACTER_JSON);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      const parsed: Object = JSON.parse(result.jsonString) as Object;
      // 类型安全访问
      const parsedObj = parsed as Record<string, Object>;
      expect(parsedObj['spec'] as string).assertEqual('chara_card_v2');
    });

    // ===== 正常 V3 PNG =====

    it('V3_PNG_ccv3_keyword', () => {
      const bytes: Uint8Array = buildCharacterPng('ccv3', V3_CHARACTER_JSON);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.sourceFormat).assertEqual('chara_card_v3');
      expect(result.jsonString.includes('V3测试角色')).assertTrue();
    });

    // ===== V3 优先于 V2 =====

    it('V3_prioritized_over_V2', () => {
      // 同时包含 chara 和 ccv3 chunk
      const charaChunk: number[] = buildTextChunk('chara', base64Encode(V2_CHARACTER_JSON));
      const ccv3Chunk: number[] = buildTextChunk('ccv3', base64Encode(V3_CHARACTER_JSON));
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), charaChunk, ccv3Chunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      // 应优先返回 V3 数据
      expect(result.sourceFormat).assertEqual('chara_card_v3');
      expect(result.jsonString.includes('V3测试角色')).assertTrue();
    });

    // ===== 无元数据 PNG =====

    it('no_metadata_PNG', () => {
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('未找到角色卡元数据')).assertTrue();
    });

    it('only_non_chara_text_chunks', () => {
      // 只有非角色卡 tEXt chunk(如 "Title", "Author")
      const titleChunk: number[] = buildTextChunk('Title', 'test');
      const authorChunk: number[] = buildTextChunk('Author', 'test');
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), titleChunk, authorChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('未找到角色卡元数据')).assertTrue();
    });

    // ===== PNG 签名错误 =====

    it('invalid_PNG_signature', () => {
      const bytes: Uint8Array = new Uint8Array(20);
      // 全部填充 0xFF
      for (let i = 0; i < bytes.length; i++) {
        bytes[i] = 0xFF;
      }
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('无效的 PNG 签名')).assertTrue();
    });

    it('truncated_signature', () => {
      const bytes: Uint8Array = new Uint8Array([0x89, 0x50, 0x4E]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('文件太小')).assertTrue();
    });

    // ===== chunk 数据越界 =====

    it('chunk_data_overflow', () => {
      // 构建一个声称数据很大但实际不够的 chunk
      const badChunk: number[] = new Array<number>(12);
      writeUint32BE(badChunk, 0, 1000); // 声称 1000 字节数据
      writeAscii(badChunk, 4, 'tEXt');  // 类型 tEXt
      writeUint32BE(badChunk, 8, 0);     // CRC
      const bytes: Uint8Array = buildPngBytes([badChunk]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('PNG 解析失败')).assertTrue();
    });

    // ===== Base64 非法 =====

    it('invalid_Base64_in_text_chunk', () => {
      const textChunk: number[] = buildTextChunk('chara', '!!!not-valid-base64!!!');
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('Base64 解码失败')).assertTrue();
    });

    it('empty_Base64_text', () => {
      const textChunk: number[] = buildTextChunk('chara', '');
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('Base64 解码结果为空')).assertTrue();
    });

    // ===== 超大文件 =====

    it('file_too_large', () => {
      // 构造一个超过 50MB 的数组(不实际填充,只设置长度)
      const bytes: Uint8Array = new Uint8Array(51 * 1024 * 1024);
      // 设置正确的 PNG 签名,避免小文件错误
      for (let i = 0; i < PNG_SIG.length; i++) {
        bytes[i] = PNG_SIG[i];
      }
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('文件过大')).assertTrue();
    });

    // ===== URL-safe Base64 =====

    it('URL_safe_Base64', () => {
      // URL-safe Base64 使用 - 和 _ 代替 + 和 /
      const json: string = '{"name":"test"}';
      const standard: string = base64Encode(json);
      // 转换为 URL-safe 格式
      let urlSafe: string = '';
      for (let i = 0; i < standard.length; i++) {
        const ch: string = standard.charAt(i);
        if (ch === '+') {
          urlSafe += '-';
        } else if (ch === '/') {
          urlSafe += '_';
        } else {
          urlSafe += ch;
        }
      }
      const textChunk: number[] = buildTextChunk('chara', urlSafe);
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.jsonString.includes('test')).assertTrue();
    });

    // ===== 中文角色名(UTF-8 编码) =====

    it('Chinese_character_name_in_JSON', () => {
      const json: string = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: '星野爱',
          description: '偶像',
          personality: '温柔',
          scenario: '',
          first_mes: '你好!',
          system_prompt: '',
          mes_example: ''
        }
      });
      const bytes: Uint8Array = buildCharacterPng('chara', json);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.jsonString.includes('星野爱')).assertTrue();
    });

    // ===== 空 keyword(无 null 分隔符) =====

    it('text_chunk_without_null_separator', () => {
      // 构造一个没有 null 分隔符的 tEXt chunk
      const data: number[] = [];
      for (let i = 0; i < 'chara'.length; i++) {
        data.push('chara'.charCodeAt(i) & 0xFF);
      }
      // 没有 0x00 分隔符,直接跟数据
      data.push(0x41); // 'A'
      const textChunk: number[] = buildChunk('tEXt', data);
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      // 没有 null 分隔符 → parseTextChunk 返回 null → 视为无元数据
      expect(result.success).assertFalse();
      expect(result.error.includes('未找到角色卡元数据')).assertTrue();
    });

    // ===== chunk 长度异常(超大) =====

    it('chunk_data_length_too_large', () => {
      const badChunk: number[] = new Array<number>(16);
      writeUint32BE(badChunk, 0, 101 * 1024 * 1024); // 101MB chunk 数据
      writeAscii(badChunk, 4, 'tEXt');
      writeUint32BE(badChunk, 8, 0);
      // 需要填充足够的数据以通过越界检查,但长度超过 MAX_CHUNK_DATA_LENGTH 应直接报错
      // 填充 101MB 数据不现实,使用小数组但声称大长度来测试越界
      const bytes: Uint8Array = buildPngBytes([badChunk]);
      // chunk 数据长度 101MB > MAX_CHUNK_DATA_LENGTH(100MB),应报错
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('chunk 数据长度异常')).assertTrue();
    });

    // ===== 纯 ASCII 文本 =====

    it('ASCII_text_in_tEXt_chunk', () => {
      const json: string = '{"name":"AsciiChar","desc":"simple"}';
      const bytes: Uint8Array = buildCharacterPng('chara', json);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.jsonString.includes('AsciiChar')).assertTrue();
    });

    // ===== 错误信息不包含角色数据 =====

    it('error_message_does_not_contain_raw_binary', () => {
      // 构造一个带有非法 Base64 的 PNG,确保错误信息中不含原始字节
      const textChunk: number[] = buildTextChunk('chara', '@@@bad@@@');
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      // 错误信息应是可读的,不含原始二进制
      expect(result.error.length).assertLess(200);
    });

    // ===== 大文本(但不超过限制) =====

    it('large_but_valid_character_card', () => {
      // 构建一个约 1KB 的角色卡
      let longDesc: string = '';
      for (let i = 0; i < 50; i++) {
        longDesc += '这是一个很长的描述文本,用于测试解析器对较大角色卡的处理能力。';
      }
      const json: string = JSON.stringify({
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
          name: '长文本角色',
          description: longDesc,
          personality: longDesc,
          scenario: '',
          first_mes: longDesc,
          system_prompt: '',
          mes_example: ''
        }
      });
      const bytes: Uint8Array = buildCharacterPng('chara', json);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.jsonString.includes('长文本角色')).assertTrue();
    });

    // ===== 文本过长(超过 10MB) =====

    it('text_too_large', () => {
      // 生成超过 10MB 的 Base64 文本(但文件大小不超 50MB)
      // 实际创建一个 11MB 的 Base64 字符串不现实,使用小文件但触发限制
      // 测试逻辑:直接构造一个 text 长度超过 MAX_TEXT_LENGTH 的 chunk
      const largeText: string = 'A'.repeat(11 * 1024 * 1024); // 11MB
      const textChunk: number[] = buildTextChunk('chara', largeText);
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      // 文件大小可能超 50MB,但至少会触发 text 长度检查
      const result: PngParseResult = parsePngCharacterCard(bytes);
      // 要么文件过大,要么文本过大,两者之一
      const isSizeOrTextError: boolean = result.error.includes('文件过大') || result.error.includes('元数据过大');
      expect(isSizeOrTextError).assertTrue();
    });

  });
}