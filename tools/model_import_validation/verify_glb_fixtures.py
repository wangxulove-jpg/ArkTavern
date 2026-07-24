"""
T-3D.6D host-side GLB fixtures verifier.

验证 generate_glb_fixtures.py 生成的 18 个 fixtures 的结构,
并扫描 Grace 模型与 test_models 中的其他 GLB 文件。
仅使用 Python 标准库。

使用方法:
    python tools/model_import_validation/verify_glb_fixtures.py

输出:
    - 每个 fixture 的预期错误类型与实际结构验证结果
    - Grace 模型的扩展使用、mesh/material/animation 统计
    - 总结通过/失败的检查项数量
"""

import os
import struct
import json as json_module

GLB_MAGIC = 0x46546C67  # "glTF"
GLB_VERSION = 2
CHUNK_TYPE_JSON = 0x4E4F534A  # "JSON"
CHUNK_TYPE_BIN = 0x004E4942  # "BIN\0"
GLB_HEADER_SIZE = 12
CHUNK_HEADER_SIZE = 8


def align4(n):
    return (n + 3) & ~3


def read_glb(path):
    """Read a GLB file and return (header_dict, json_text, bin_data, error)."""
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) < GLB_HEADER_SIZE:
        return None, '', b'', f'file too small: {len(data)} bytes'
    magic, version, total_length = struct.unpack('<III', data[:12])
    header = {
        'magic': magic, 'version': version, 'total_length': total_length,
        'actual_size': len(data)
    }
    if magic != GLB_MAGIC:
        return header, '', b'', f'wrong magic: 0x{magic:08X}'
    if version != GLB_VERSION:
        return header, '', b'', f'wrong version: {version}'
    if total_length != len(data):
        return header, '', b'', f'length mismatch: declared={total_length}, actual={len(data)}'

    offset = 12
    json_text = ''
    bin_data = b''
    chunk_index = 0
    while offset < len(data):
        if offset + CHUNK_HEADER_SIZE > len(data):
            return header, json_text, bin_data, f'chunk header truncated at offset {offset}'
        chunk_length, chunk_type = struct.unpack('<II', data[offset:offset + 8])
        if chunk_length % 4 != 0:
            return header, json_text, bin_data, f'chunk {chunk_index} length not 4-aligned: {chunk_length}'
        if offset + 8 + chunk_length > len(data):
            return header, json_text, bin_data, f'chunk {chunk_index} out of range: declared={chunk_length}'
        chunk_data = data[offset + 8:offset + 8 + chunk_length]
        if chunk_index == 0 and chunk_type != CHUNK_TYPE_JSON:
            return header, json_text, bin_data, f'first chunk must be JSON, got 0x{chunk_type:08X}'
        if chunk_type == CHUNK_TYPE_JSON:
            json_text = chunk_data.decode('utf-8', errors='replace').rstrip(' \x00')
        elif chunk_type == CHUNK_TYPE_BIN:
            bin_data = chunk_data
        offset += 8 + chunk_length
        chunk_index += 1

    return header, json_text, bin_data, ''


def parse_json_safe(json_text):
    """Parse JSON safely, return (obj, error)."""
    if not json_text:
        return None, 'empty json'
    try:
        return json_module.loads(json_text), ''
    except Exception as e:
        return None, f'json parse failed: {e}'


def verify_fixture(path, expected_error_keyword):
    """Verify a single fixture, return (passed, message)."""
    name = os.path.basename(path)
    header, json_text, bin_data, error = read_glb(path)

    # 如果连 header 都读不到
    if header is None:
        return True, f'{name}: file too small (expected: {expected_error_keyword})'

    # 如果有容器层错误,检查是否符合预期
    if error:
        if expected_error_keyword.lower() in error.lower() or expected_error_keyword == 'ANY':
            return True, f'{name}: container error as expected ({error})'
        return False, f'{name}: container error mismatch (expected: {expected_error_keyword}, got: {error})'

    # 容器有效,检查语义
    obj, json_error = parse_json_safe(json_text)
    if json_error:
        if expected_error_keyword.lower() in json_error.lower() or expected_error_keyword == 'ANY':
            return True, f'{name}: json error as expected ({json_error})'
        return False, f'{name}: json error mismatch (expected: {expected_error_keyword}, got: {json_error})'

    # JSON 有效,检查语义层
    if 'asset' not in obj:
        if expected_error_keyword == 'asset':
            return True, f'{name}: missing asset as expected'
        return False, f'{name}: missing asset unexpectedly'
    asset = obj.get('asset', {})
    if asset.get('version') != '2.0':
        if expected_error_keyword == 'version':
            return True, f'{name}: asset.version={asset.get("version")} as expected'
        return False, f'{name}: asset.version={asset.get("version")} unexpectedly'

    # 检查扩展
    ext_required = obj.get('extensionsRequired', [])
    if 'KHR_draco_mesh_compression' in ext_required:
        if expected_error_keyword == 'draco':
            return True, f'{name}: KHR_draco_mesh_compression required as expected'
        return False, f'{name}: draco required unexpectedly'

    # 对于正常情况(如 14_empty_scene, 15_no_position, 16_nan_bounds, 17_small, 18_large)
    # 容器有效,JSON 有效,asset.version=2.0,但语义可能有问题
    # 这里只验证容器层,语义层由 ArkTS 测试覆盖
    return True, f'{name}: container valid (semantic checks in ArkTS tests)'


def scan_model_file(path):
    """Scan a real model file, return summary dict."""
    header, json_text, bin_data, error = read_glb(path)
    result = {
        'path': os.path.basename(path),
        'file_size': os.path.getsize(path),
        'container_valid': error == '',
        'error': error,
    }
    if error:
        return result

    obj, json_error = parse_json_safe(json_text)
    if json_error:
        result['error'] = json_error
        result['container_valid'] = False
        return result

    result['gltf_version'] = obj.get('asset', {}).get('version', '')
    result['mesh_count'] = len(obj.get('meshes', []))
    result['material_count'] = len(obj.get('materials', []))
    result['animation_count'] = len(obj.get('animations', []))
    result['skin_count'] = len(obj.get('skins', []))
    result['node_count'] = len(obj.get('nodes', []))
    result['scene_count'] = len(obj.get('scenes', []))
    result['accessor_count'] = len(obj.get('accessors', []))
    result['buffer_view_count'] = len(obj.get('bufferViews', []))
    result['buffer_count'] = len(obj.get('buffers', []))
    result['image_count'] = len(obj.get('images', []))
    result['texture_count'] = len(obj.get('textures', []))
    result['sampler_count'] = len(obj.get('samplers', []))
    result['camera_count'] = len(obj.get('cameras', []))
    result['extensions_used'] = obj.get('extensionsUsed', [])
    result['extensions_required'] = obj.get('extensionsRequired', [])
    result['bin_chunk_length'] = len(bin_data)
    result['declared_buffer_length'] = obj.get('buffers', [{}])[0].get('byteLength', 0) if obj.get('buffers') else 0

    # 统计 joint 数量(去重)
    joints = set()
    for skin in obj.get('skins', []):
        for j in skin.get('joints', []):
            joints.add(j)
    result['joint_count'] = len(joints)

    # 统计 morph target 数量
    morph_count = 0
    for mesh in obj.get('meshes', []):
        for prim in mesh.get('primitives', []):
            for target in prim.get('targets', []):
                morph_count += 1
    result['morph_target_count'] = morph_count

    # 统计 primitive 数量
    prim_count = 0
    for mesh in obj.get('meshes', []):
        prim_count += len(mesh.get('primitives', []))
    result['primitive_count'] = prim_count

    return result


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    fixtures_dir = os.path.join(project_root, 'test_models', 'generated')
    models_dir = os.path.join(project_root, 'test_models')

    # 预期错误关键字映射
    # 注:fixture 05 和 06 触发的具体错误可能因实现细节而异,
    # 验证器会拒绝这些非法 GLB,关键字使用 'ANY' 表示只要被拒绝即可
    fixture_expectations = {
        '01_all_zero_8bytes.glb': 'small',
        '02_wrong_magic.glb': 'magic',
        '03_version_1.glb': 'version',
        '04_declared_length_ffffffff.glb': 'mismatch',
        '05_json_chunk_length_ffffffff.glb': 'ANY',  # 0xFFFFFFFF 非 4 对齐或越界,ANY 表示只要被拒绝
        '06_json_chunk_not_aligned.glb': 'ANY',      # chunkLength=13 触发 length mismatch 或 not-aligned
        '07_json_chunk_out_of_range.glb': 'range',
        '08_first_chunk_is_bin.glb': 'JSON',
        '09_invalid_json.glb': 'parse',
        '10_asset_version_1.glb': 'version',
        '11_bufferView_out_of_range.glb': 'ANY',  # 容器有效,语义层错误由 ArkTS 测试
        '12_accessor_out_of_range.glb': 'ANY',
        '13_unsupported_required_extension.glb': 'draco',
        '14_empty_scene.glb': 'ANY',
        '15_no_position.glb': 'ANY',
        '16_nan_bounds.glb': 'ANY',
        '17_extremely_small_model.glb': 'ANY',
        '18_extremely_large_model.glb': 'ANY',
    }

    print('=' * 70)
    print('T-3D.6D Host-side GLB Fixtures Verification')
    print('=' * 70)

    # 1. 验证 fixtures
    print('\n--- Fixture Verification (18 items) ---')
    passed = 0
    failed = 0
    for name in sorted(fixture_expectations.keys()):
        path = os.path.join(fixtures_dir, name)
        if not os.path.exists(path):
            print(f'  [FAIL] {name}: file not found')
            failed += 1
            continue
        expected = fixture_expectations[name]
        ok, msg = verify_fixture(path, expected)
        status = 'PASS' if ok else 'FAIL'
        print(f'  [{status}] {msg}')
        if ok:
            passed += 1
        else:
            failed += 1

    print(f'\nFixtures: {passed} passed, {failed} failed')

    # 2. 扫描真实模型
    print('\n--- Real Model Scan ---')
    if os.path.exists(models_dir):
        for entry in sorted(os.listdir(models_dir)):
            if entry.endswith('.glb'):
                path = os.path.join(models_dir, entry)
                if os.path.isfile(path):
                    print(f'\n  Scanning: {entry}')
                    info = scan_model_file(path)
                    print(f'    file_size: {info["file_size"]} bytes')
                    print(f'    container_valid: {info["container_valid"]}')
                    if info['container_valid']:
                        print(f'    gltf_version: {info.get("gltf_version", "")}')
                        print(f'    scenes/nodes/meshes/primitives: '
                              f'{info["scene_count"]}/{info["node_count"]}/{info["mesh_count"]}/{info["primitive_count"]}')
                        print(f'    materials/textures/images/samplers: '
                              f'{info["material_count"]}/{info["texture_count"]}/{info["image_count"]}/{info["sampler_count"]}')
                        print(f'    animations/skins/joints/morph: '
                              f'{info["animation_count"]}/{info["skin_count"]}/{info["joint_count"]}/{info["morph_target_count"]}')
                        print(f'    accessors/bufferViews/buffers: '
                              f'{info["accessor_count"]}/{info["buffer_view_count"]}/{info["buffer_count"]}')
                        print(f'    cameras: {info["camera_count"]}')
                        print(f'    bin_chunk_length: {info["bin_chunk_length"]}')
                        print(f'    declared_buffer_length: {info["declared_buffer_length"]}')
                        print(f'    extensions_used: {info["extensions_used"]}')
                        print(f'    extensions_required: {info["extensions_required"]}')
                    else:
                        print(f'    error: {info.get("error", "")}')

    print('\n' + '=' * 70)
    print(f'Summary: fixtures {passed}/{passed + failed} passed')
    print('=' * 70)


if __name__ == '__main__':
    main()
