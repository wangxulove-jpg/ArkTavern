/**
 * 临时脚本:解析 default_ai_action_pack.glb,输出动画结构。
 * 仅用于开发分析,不属于正式代码。
 */
const fs = require('fs');
const path = require('path');

const glbPath = path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'rawfile', 'actions', 'default_ai', 'default_ai_action_pack.glb');
const buffer = fs.readFileSync(glbPath);

// GLB Header
const magic = buffer.readUInt32LE(0);
const version = buffer.readUInt32LE(4);
const totalLength = buffer.readUInt32LE(8);
console.log('=== GLB Header ===');
console.log('magic:', magic.toString(16), '(glTF=46546c67)');
console.log('version:', version);
console.log('totalLength:', totalLength);
console.log('fileSize:', buffer.length);

// Parse chunks
let offset = 12;
let jsonText = '';
let binChunk = null;
let chunkIndex = 0;
while (offset + 8 <= buffer.length) {
  const chunkLength = buffer.readUInt32LE(offset);
  const chunkType = buffer.readUInt32LE(offset + 4);
  const chunkDataStart = offset + 8;
  const chunkTypeStr = chunkType === 0x4E4F534A ? 'JSON' : (chunkType === 0x004E4942 ? 'BIN' : 'UNKNOWN');
  console.log(`\n=== Chunk ${chunkIndex}: ${chunkTypeStr} ===`);
  console.log('  length:', chunkLength, 'type:', chunkType.toString(16));
  if (chunkType === 0x4E4F534A) {
    jsonText = buffer.slice(chunkDataStart, chunkDataStart + chunkLength).toString('utf-8');
  } else if (chunkType === 0x004E4942) {
    binChunk = buffer.slice(chunkDataStart, chunkDataStart + chunkLength);
  }
  offset = chunkDataStart + chunkLength;
  // 4-byte alignment
  while (offset < buffer.length && (offset % 4) !== 0) offset++;
  chunkIndex++;
}

const gltf = JSON.parse(jsonText);
console.log('\n=== glTF JSON Summary ===');
console.log('asset:', JSON.stringify(gltf.asset));
console.log('nodes count:', (gltf.nodes || []).length);
console.log('meshes count:', (gltf.meshes || []).length);
console.log('skins count:', (gltf.skins || []).length);
console.log('animations count:', (gltf.animations || []).length);
console.log('accessors count:', (gltf.accessors || []).length);
console.log('bufferViews count:', (gltf.bufferViews || []).length);
console.log('buffers count:', (gltf.buffers || []).length);
console.log('materials count:', (gltf.materials || []).length);
console.log('images count:', (gltf.images || []).length);
console.log('textures count:', (gltf.textures || []).length);

// Extensions
if (gltf.extensionsUsed) console.log('extensionsUsed:', gltf.extensionsUsed);
if (gltf.extensionsRequired) console.log('extensionsRequired:', gltf.extensionsRequired);

// List all animations
console.log('\n=== Animations ===');
(gltf.animations || []).forEach((anim, i) => {
  console.log(`\n--- Animation[${i}]: name="${anim.name}" ---`);
  console.log('  channels:', (anim.channels || []).length);
  console.log('  samplers:', (anim.samplers || []).length);
  // Sampler details
  (anim.samplers || []).forEach((s, j) => {
    console.log(`  sampler[${j}]: input=accessor[${s.input}], output=accessor[${s.output}], interpolation=${s.interpolation}`);
  });
  // Channel details
  (anim.channels || []).forEach((c, j) => {
    console.log(`  channel[${j}]: sampler=${c.sampler}, target.node=${c.target.node}, target.path=${c.target.path}`);
  });
});

// Find AT_Wave specifically
const waveIndex = (gltf.animations || []).findIndex(a => a.name === 'AT_Wave');
console.log('\n=== AT_Wave Analysis ===');
if (waveIndex >= 0) {
  const wave = gltf.animations[waveIndex];
  console.log('animation index:', waveIndex);
  console.log('name:', wave.name);
  console.log('channel count:', wave.channels.length);
  console.log('sampler count:', wave.samplers.length);
  // Count by path
  const pathCounts = {};
  wave.channels.forEach(c => {
    pathCounts[c.target.path] = (pathCounts[c.target.path] || 0) + 1;
  });
  console.log('path counts:', JSON.stringify(pathCounts));
  // Interpolation types
  const interpTypes = new Set();
  wave.samplers.forEach(s => interpTypes.add(s.interpolation));
  console.log('interpolation types:', Array.from(interpTypes));
  // Source nodes
  console.log('\n  Source nodes targeted:');
  wave.channels.forEach((c, j) => {
    const nodeIdx = c.target.node;
    const node = gltf.nodes[nodeIdx];
    const nodeName = node && node.name ? node.name : '<unnamed>';
    console.log(`    channel[${j}]: node[${nodeIdx}]="${nodeName}", path=${c.target.path}, sampler=${c.sampler}`);
  });
  // Sampler input/output accessor details
  console.log('\n  Sampler accessor details:');
  wave.samplers.forEach((s, j) => {
    const inputAcc = gltf.accessors[s.input];
    const outputAcc = gltf.accessors[s.output];
    console.log(`    sampler[${j}]: interp=${s.interpolation}`);
    console.log(`      input  accessor[${s.input}]: count=${inputAcc.count}, type=${inputAcc.type}, componentType=${inputAcc.componentType}, min=${JSON.stringify(inputAcc.min)}, max=${JSON.stringify(inputAcc.max)}`);
    console.log(`      output accessor[${s.output}]: count=${outputAcc.count}, type=${outputAcc.type}, componentType=${outputAcc.componentType}, min=${JSON.stringify(outputAcc.min)}, max=${JSON.stringify(outputAcc.max)}`);
  });
  // Duration
  let maxTime = 0;
  wave.samplers.forEach(s => {
    const inputAcc = gltf.accessors[s.input];
    if (inputAcc.max && inputAcc.max[0] > maxTime) maxTime = inputAcc.max[0];
  });
  console.log('\n  Duration (seconds):', maxTime);
  console.log('  Duration (ms):', Math.round(maxTime * 1000));
} else {
  console.log('AT_Wave NOT FOUND!');
  console.log('Available animations:', (gltf.animations || []).map(a => a.name));
}

// List all node names (first 30)
console.log('\n=== Node Names (first 30) ===');
(gltf.nodes || []).slice(0, 30).forEach((n, i) => {
  console.log(`  node[${i}]: name="${n.name || '<unnamed>'}", children=${(n.children || []).length}`);
});

// Check VRM extension
console.log('\n=== VRM Extension Check ===');
let hasVrm = false;
if (gltf.extensionsUsed) {
  hasVrm = gltf.extensionsUsed.some(e => e.indexOf('VRM') >= 0);
}
console.log('Has VRM extension:', hasVrm);
if (gltf.extensions) {
  const extKeys = Object.keys(gltf.extensions);
  console.log('Top-level extensions:', extKeys);
}

// Check if nodes have VRM_humanoid extension
const vrmBones = [];
(gltf.nodes || []).forEach((n, i) => {
  if (n.extensions && n.extensions.VRMC_vrm_humanoid) {
    vrmBones.push({ index: i, name: n.name, bone: n.extensions.VRMC_vrm_humanoid.humanBone });
  }
});
if (vrmBones.length > 0) {
  console.log('VRM humanoid bones found:', vrmBones.length);
  vrmBones.slice(0, 10).forEach(b => console.log(`  node[${b.index}]="${b.name}" bone=${b.bone}`));
}

console.log('\nDone.');
