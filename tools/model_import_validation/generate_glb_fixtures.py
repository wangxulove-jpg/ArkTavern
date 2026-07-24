"""
T-3D.6D host-side GLB fixture generator.

生成用于 T-3D.6D 负向测试的损坏 GLB 文件,放在 test_models/generated/ 目录。
仅使用 Python 标准库,不引入任何第三方依赖。

使用方法:
    python tools/model_import_validation/generate_glb_fixtures.py

生成的 fixture 列表(18 项):
  01_all_zero_8bytes.glb               - 8 字节全零
  02_wrong_magic.glb                   - 12 字节错误 magic
  03_version_1.glb                     - GLB version = 1
  04_declared_length_ffffffff.glb      - declared total length = 0xFFFFFFFF
  05_json_chunk_length_ffffffff.glb    - JSON chunkLength = 0xFFFFFFFF
  06_json_chunk_not_aligned.glb        - JSON chunkLength 非 4 对齐
  07_json_chunk_out_of_range.glb       - JSON chunk 越界
  08_first_chunk_is_bin.glb            - 第一个 chunk 为 BIN
  09_invalid_json.glb                  - JSON 非法
  10_asset_version_1.glb               - asset.version = 1.0
  11_bufferView_out_of_range.glb       - bufferView 越界
  12_accessor_out_of_range.glb         - accessor 越界
  13_unsupported_required_extension.glb - required extension 不支持
  14_empty_scene.glb                   - 空 scene
  15_no_position.glb                   - primitive 无 POSITION
  16_nan_bounds.glb                    - NaN Bounds
  17_extremely_small_model.glb         - 极小坐标模型
  18_extremely_large_model.glb         - 极大坐标模型
"""

import os
import struct
import json as json_module

# GLB constants
GLB_MAGIC = 0x46546C67  # "glTF"
GLB_VERSION = 2
CHUNK_TYPE_JSON = 0x4E4F534A  # "JSON"
CHUNK_TYPE_BIN = 0x004E4942  # "BIN\0"
GLB_HEADER_SIZE = 12
CHUNK_HEADER_SIZE = 8
JSON_PADDING_BYTE = 0x20  # space


def align4(n):
    """Align n to 4-byte boundary."""
    return (n + 3) & ~3


def encode_utf8(s):
    """Encode string to UTF-8 bytes."""
    return s.encode('utf-8')


def build_glb(json_text, bin_data=None, json_chunk_length_override=None,
              bin_chunk_length_override=None, first_chunk_type_override=None,
              header_length_override=None, header_magic_override=None,
              header_version_override=None, chunk_length_ffffffff=False,
              skip_json_chunk=False, trailing_extra_bytes=0):
    """Build a GLB ArrayBuffer from json text and optional bin data."""
    json_bytes = encode_utf8(json_text)
    json_padded_len = align4(len(json_bytes))
    json_padded = json_bytes + bytes([JSON_PADDING_BYTE] * (json_padded_len - len(json_bytes)))

    bin_padded = b''
    has_bin = bin_data is not None
    if has_bin:
        bin_padded_len = align4(len(bin_data))
        bin_padded = bin_data + bytes([0x00] * (bin_padded_len - len(bin_data)))

    total_length = GLB_HEADER_SIZE
    if not skip_json_chunk:
        total_length += CHUNK_HEADER_SIZE + len(json_padded)
    if has_bin:
        total_length += CHUNK_HEADER_SIZE + len(bin_padded)
    total_length += trailing_extra_bytes

    buf = bytearray()

    # Header
    magic = header_magic_override if header_magic_override is not None else GLB_MAGIC
    version = header_version_override if header_version_override is not None else GLB_VERSION
    header_length = header_length_override if header_length_override is not None else total_length
    buf += struct.pack('<III', magic, version, header_length)

    # JSON chunk
    if not skip_json_chunk:
        first_type = first_chunk_type_override if first_chunk_type_override is not None else CHUNK_TYPE_JSON
        json_len = json_chunk_length_override if json_chunk_length_override is not None else len(json_padded)
        if chunk_length_ffffffff:
            json_len_field = 0xFFFFFFFF
        else:
            json_len_field = json_len
        buf += struct.pack('<II', json_len_field, first_type)
        buf += json_padded[:min(json_len, len(json_padded))]

    # BIN chunk
    if has_bin:
        bin_len = bin_chunk_length_override if bin_chunk_length_override is not None else len(bin_padded)
        if chunk_length_ffffffff:
            bin_len_field = 0xFFFFFFFF
        else:
            bin_len_field = bin_len
        buf += struct.pack('<II', bin_len_field, CHUNK_TYPE_BIN)
        buf += bin_padded[:min(bin_len, len(bin_padded))]

    # Trailing extra bytes
    buf += bytes([0x00] * trailing_extra_bytes)

    return bytes(buf)


def write_fixture(out_dir, name, data):
    """Write a fixture file."""
    path = os.path.join(out_dir, name)
    with open(path, 'wb') as f:
        f.write(data)
    print(f'  generated: {name} ({len(data)} bytes)')


def generate_all_fixtures(out_dir):
    """Generate all 18 GLB fixtures."""
    if not os.path.exists(out_dir):
        os.makedirs(out_dir)

    print(f'Generating GLB fixtures in: {out_dir}')

    # 01. 8 字节全零
    write_fixture(out_dir, '01_all_zero_8bytes.glb', bytes(8))

    # 02. 12 字节错误 magic
    wrong_magic = struct.pack('<III', 0x12345678, GLB_VERSION, 12)
    write_fixture(out_dir, '02_wrong_magic.glb', wrong_magic)

    # 03. GLB version = 1
    json_text = '{"asset":{"version":"2.0"}}'
    data = build_glb(json_text, header_version_override=1)
    write_fixture(out_dir, '03_version_1.glb', data)

    # 04. declared total length = 0xFFFFFFFF
    data = build_glb(json_text, header_length_override=0xFFFFFFFF)
    write_fixture(out_dir, '04_declared_length_ffffffff.glb', data)

    # 05. JSON chunkLength = 0xFFFFFFFF
    data = build_glb(json_text, chunk_length_ffffffff=True)
    write_fixture(out_dir, '05_json_chunk_length_ffffffff.glb', data)

    # 06. JSON chunkLength 非 4 对齐(声明 13 字节,实际 padded 为 16)
    data = build_glb(json_text, json_chunk_length_override=13)
    write_fixture(out_dir, '06_json_chunk_not_aligned.glb', data)

    # 07. JSON chunk 越界(声明 1024 字节)
    data = build_glb(json_text, json_chunk_length_override=1024)
    write_fixture(out_dir, '07_json_chunk_out_of_range.glb', data)

    # 08. 第一个 chunk 为 BIN
    data = build_glb(json_text, first_chunk_type_override=CHUNK_TYPE_BIN)
    write_fixture(out_dir, '08_first_chunk_is_bin.glb', data)

    # 09. JSON 非法
    data = build_glb('{invalid json!!!', )
    write_fixture(out_dir, '09_invalid_json.glb', data)

    # 10. asset.version = 1.0
    data = build_glb('{"asset":{"version":"1.0"}}')
    write_fixture(out_dir, '10_asset_version_1.glb', data)

    # 11. bufferView 越界(buffer 索引 = 5)
    json_11 = json_module.dumps({
        'asset': {'version': '2.0'},
        'buffers': [{'byteLength': 100}],
        'bufferViews': [{'buffer': 5, 'byteOffset': 0, 'byteLength': 10}]
    })
    data = build_glb(json_11)
    write_fixture(out_dir, '11_bufferView_out_of_range.glb', data)

    # 12. accessor 越界(bufferView 索引 = 99)
    json_12 = json_module.dumps({
        'asset': {'version': '2.0'},
        'buffers': [{'byteLength': 100}],
        'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': 48}],
        'accessors': [{'bufferView': 99, 'componentType': 5126, 'count': 3, 'type': 'VEC3'}]
    })
    data = build_glb(json_12)
    write_fixture(out_dir, '12_accessor_out_of_range.glb', data)

    # 13. required extension 不支持(KHR_draco_mesh_compression)
    json_13 = json_module.dumps({
        'asset': {'version': '2.0'},
        'extensionsRequired': ['KHR_draco_mesh_compression']
    })
    data = build_glb(json_13)
    write_fixture(out_dir, '13_unsupported_required_extension.glb', data)

    # 14. 空 scene(有 scene 但无 nodes)
    json_14 = json_module.dumps({
        'asset': {'version': '2.0'},
        'scenes': [{'nodes': []}]
    })
    data = build_glb(json_14)
    write_fixture(out_dir, '14_empty_scene.glb', data)

    # 15. primitive 无 POSITION
    json_15 = json_module.dumps({
        'asset': {'version': '2.0'},
        'buffers': [{'byteLength': 48}],
        'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': 48}],
        'accessors': [{'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'}],
        'meshes': [{'primitives': [{'attributes': {'NORMAL': 0}}]}]
    })
    data = build_glb(json_15)
    write_fixture(out_dir, '15_no_position.glb', data)

    # 16. NaN Bounds(POSITION accessor 的 min/max 包含 NaN)
    json_16 = json_module.dumps({
        'asset': {'version': '2.0'},
        'buffers': [{'byteLength': 48}],
        'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': 48}],
        'accessors': [{
            'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3',
            'min': [float('nan'), float('nan'), float('nan')],
            'max': [float('nan'), float('nan'), float('nan')]
        }],
        'meshes': [{'primitives': [{'attributes': {'POSITION': 0}}]}],
        'nodes': [{'mesh': 0}],
        'scenes': [{'nodes': [0]}]
    })
    # NaN 在 JSON 中会被序列化为 NaN,Python json 默认支持
    # 手动构造以确保 NaN 出现
    json_16_text = '{"asset":{"version":"2.0"},"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[NaN,NaN,NaN],"max":[NaN,NaN,NaN]}],"buffers":[{"byteLength":48}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}'
    # Python json_module.dumps 默认会输出 NaN,但保险起见用字符串替换
    data = build_glb(json_16_text)
    write_fixture(out_dir, '16_nan_bounds.glb', data)

    # 17. 极小坐标模型(POSITION min/max 为 1e-10 级别)
    json_17 = json_module.dumps({
        'asset': {'version': '2.0'},
        'buffers': [{'byteLength': 48}],
        'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': 48}],
        'accessors': [{
            'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3',
            'min': [0.0, 0.0, 0.0],
            'max': [1e-10, 1e-10, 1e-10]
        }],
        'meshes': [{'primitives': [{'attributes': {'POSITION': 0}}]}],
        'nodes': [{'mesh': 0}],
        'scenes': [{'nodes': [0]}]
    })
    # 提供实际的 BIN 数据(48 字节,12 个 float32)
    bin_17 = struct.pack('<12f', 0.0, 0.0, 0.0, 1e-10, 0.0, 0.0,
                         0.0, 1e-10, 0.0, 0.0, 0.0, 1e-10)
    data = build_glb(json_17, bin_data=bin_17)
    write_fixture(out_dir, '17_extremely_small_model.glb', data)

    # 18. 极大坐标模型(POSITION min/max 为 1e8 级别)
    json_18 = json_module.dumps({
        'asset': {'version': '2.0'},
        'buffers': [{'byteLength': 48}],
        'bufferViews': [{'buffer': 0, 'byteOffset': 0, 'byteLength': 48}],
        'accessors': [{
            'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3',
            'min': [0.0, 0.0, 0.0],
            'max': [1e8, 1e8, 1e8]
        }],
        'meshes': [{'primitives': [{'attributes': {'POSITION': 0}}]}],
        'nodes': [{'mesh': 0}],
        'scenes': [{'nodes': [0]}]
    })
    bin_18 = struct.pack('<12f', 0.0, 0.0, 0.0, 1e8, 0.0, 0.0,
                         0.0, 1e8, 0.0, 0.0, 0.0, 1e8)
    data = build_glb(json_18, bin_data=bin_18)
    write_fixture(out_dir, '18_extremely_large_model.glb', data)

    print(f'\nGenerated 18 fixtures in {out_dir}')


def main():
    """Entry point."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    out_dir = os.path.join(project_root, 'test_models', 'generated')
    generate_all_fixtures(out_dir)


if __name__ == '__main__':
    main()
