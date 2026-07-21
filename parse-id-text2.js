const fs = require('fs');
const path = process.argv[2] || 'D:/DevEco_studio/ArkTavern/l1.json';
const c = fs.readFileSync(path, 'utf8');
// Find all components with id (any position)
const re = /\{\s*"id"\s*:\s*"([^"]+)"\s*,\s*"type"\s*:\s*"([^"]+)"\s*,\s*"bounds"\s*:\s*"(\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\])"[^}]*?"text"\s*:\s*"([^"]{1,50})"/g;
let m;
const out = [];
while ((m = re.exec(c)) !== null) {
  out.push(`id=${m[1]} type=${m[2]} bounds=${m[3]} text="${m[4]}"`);
}
console.log('with text:');
console.log(out.slice(0, 50).join('\n'));

// Find tabs
console.log('\n--- possible tab areas (bottom 200px) ---');
const re2 = /"bounds":"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/g;
let m2;
const tabs = [];
while ((m2 = re2.exec(c)) !== null) {
  const y1 = parseInt(m2[2]);
  const y2 = parseInt(m2[4]);
  if (y1 > 2400 && y2 < 2800) {
    tabs.push(`[${m2[1]},${y1}][${m2[3]},${y2}]`);
  }
}
console.log(tabs.slice(0, 20).join('\n'));
