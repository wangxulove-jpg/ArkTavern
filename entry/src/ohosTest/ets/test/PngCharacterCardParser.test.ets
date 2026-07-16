/**
 * PngCharacterCardParser 设备测试(ohosTest)
 *
 * 覆盖:
 * - 正常 V2 PNG(chara)
 * - 正常 V3 PNG(ccv3)
 * - V3 优先于 V2
 * - 无元数据 PNG
 * - PNG 签名错误
 * - Base64 非法
 * - chunk 越界
 * - 超大文件
 */

import { parsePngCharacterCard, PngParseResult } from '../../../main/ets/parser/PngCharacterCardParser';
import { describe, it, expect } from '@ohos/hypium';

// ===== PNG 构建辅助(与本地测试一致) =====

const PNG_SIG: number[] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

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

function writeUint32BE(arr: number[], offset: number, value: number): void {
  arr[offset] = (value >> 24) & 0xFF;
  arr[offset + 1] = (value >> 16) & 0xFF;
  arr[offset + 2] = (value >> 8) & 0xFF;
  arr[offset + 3] = value & 0xFF;
}

function writeAscii(arr: number[], offset: number, str: string): void {
  for (let i = 0; i < str.length; i++) {
    arr[offset + i] = str.charCodeAt(i) & 0xFF;
  }
}

function writeBytes(arr: number[], offset: number, bytes: number[]): void {
  for (let i = 0; i < bytes.length; i++) {
    arr[offset + i] = bytes[i] & 0xFF;
  }
}

function buildChunk(type: string, data: number[]): number[] {
  const chunk: number[] = new Array<number>(12 + data.length);
  writeUint32BE(chunk, 0, data.length);
  writeAscii(chunk, 4, type);
  writeBytes(chunk, 8, data);
  writeUint32BE(chunk, 8 + data.length, 0);
  return chunk;
}

function buildTextChunk(keyword: string, text: string): number[] {
  const kwBytes: number[] = [];
  for (let i = 0; i < keyword.length; i++) {
    kwBytes.push(keyword.charCodeAt(i) & 0xFF);
  }
  kwBytes.push(0x00);
  for (let i = 0; i < text.length; i++) {
    kwBytes.push(text.charCodeAt(i) & 0xFF);
  }
  return buildChunk('tEXt', kwBytes);
}

function buildIhdrChunk(): number[] {
  const data: number[] = new Array<number>(13);
  writeUint32BE(data, 0, 1);
  writeUint32BE(data, 4, 1);
  data[8] = 8;
  data[9] = 2;
  data[10] = 0;
  data[11] = 0;
  data[12] = 0;
  return buildChunk('IHDR', data);
}

function buildIendChunk(): number[] {
  return buildChunk('IEND', []);
}

function buildPngBytes(chunks: number[][]): Uint8Array {
  const totalLen: number = PNG_SIG.length + chunks.reduce((sum: number, c: number[]) => sum + c.length, 0);
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

function buildCharacterPng(keyword: string, json: string): Uint8Array {
  const textChunk: number[] = buildTextChunk(keyword, base64Encode(json));
  return buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
}

function buildV2Json(): string {
  const data: Record<string, Object> = {
    'name': 'V2Test',
    'description': 'V2Desc',
    'personality': 'V2Pers',
    'scenario': '',
    'first_mes': 'Hello',
    'system_prompt': '',
    'mes_example': ''
  };
  const root: Record<string, Object> = {
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': data
  };
  return JSON.stringify(root);
}

function buildV3Json(): string {
  const extensions: Record<string, Object> = {};
  const data: Record<string, Object> = {
    'name': 'V3Test',
    'description': 'V3Desc',
    'personality': 'V3Pers',
    'scenario': '',
    'first_mes': 'Hello',
    'system_prompt': '',
    'extensions': extensions
  };
  const root: Record<string, Object> = {
    'spec': 'chara_card_v3',
    'spec_version': '3.0',
    'data': data
  };
  return JSON.stringify(root);
}

const V2_JSON: string = buildV2Json();
const V3_JSON: string = buildV3Json();

export default function pngParserDeviceTest() {
  describe('PngCharacterCardParser', () => {

    it('V2_PNG_chara_keyword', 0, () => {
      const bytes: Uint8Array = buildCharacterPng('chara', V2_JSON);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.sourceFormat).assertEqual('chara_card_v2');
      expect(result.jsonString.includes('V2Test')).assertTrue();
    });

    it('V3_PNG_ccv3_keyword', 0, () => {
      const bytes: Uint8Array = buildCharacterPng('ccv3', V3_JSON);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.sourceFormat).assertEqual('chara_card_v3');
      expect(result.jsonString.includes('V3Test')).assertTrue();
    });

    it('V3_prioritized_over_V2', 0, () => {
      const charaChunk: number[] = buildTextChunk('chara', base64Encode(V2_JSON));
      const ccv3Chunk: number[] = buildTextChunk('ccv3', base64Encode(V3_JSON));
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), charaChunk, ccv3Chunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.sourceFormat).assertEqual('chara_card_v3');
      expect(result.jsonString.includes('V3Test')).assertTrue();
    });

    it('no_metadata_PNG', 0, () => {
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('未找到角色卡元数据')).assertTrue();
    });

    it('invalid_PNG_signature', 0, () => {
      const bytes: Uint8Array = new Uint8Array(20);
      for (let i = 0; i < bytes.length; i++) {
        bytes[i] = 0xFF;
      }
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('无效的 PNG 签名')).assertTrue();
    });

    it('invalid_Base64', 0, () => {
      const textChunk: number[] = buildTextChunk('chara', '!!!not-valid!!!');
      const bytes: Uint8Array = buildPngBytes([buildIhdrChunk(), textChunk, buildIendChunk()]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('Base64 解码失败')).assertTrue();
    });

    it('file_too_large', 0, () => {
      const bytes: Uint8Array = new Uint8Array(51 * 1024 * 1024);
      for (let i = 0; i < PNG_SIG.length; i++) {
        bytes[i] = PNG_SIG[i];
      }
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('文件过大')).assertTrue();
    });

    it('chunk_data_overflow', 0, () => {
      const badChunk: number[] = new Array<number>(12);
      writeUint32BE(badChunk, 0, 1000);
      writeAscii(badChunk, 4, 'tEXt');
      writeUint32BE(badChunk, 8, 0);
      const bytes: Uint8Array = buildPngBytes([badChunk]);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertFalse();
      expect(result.error.includes('PNG 解析失败')).assertTrue();
    });

    it('Chinese_character_in_json', 0, () => {
      const data: Record<string, Object> = {
        'name': '星野爱',
        'description': '偶像',
        'personality': '',
        'scenario': '',
        'first_mes': '',
        'system_prompt': '',
        'mes_example': ''
      };
      const root: Record<string, Object> = {
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': data
      };
      const json: string = JSON.stringify(root);
      const bytes: Uint8Array = buildCharacterPng('chara', json);
      const result: PngParseResult = parsePngCharacterCard(bytes);
      expect(result.success).assertTrue();
      expect(result.jsonString.includes('星野爱')).assertTrue();
    });

  });
}