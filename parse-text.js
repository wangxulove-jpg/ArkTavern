const fs = require('fs');
const path = process.argv[2] || 'D:/DevEco_studio/ArkTavern/l1.json';
const c = fs.readFileSync(path, 'utf8');
// Find text + bounds + id
const re = /"id":"([^"]+)"[^}]*"bounds":"(\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\])"[^}]*"text":"([^"]*)"/g;
let m;
const out = [];
while ((m = re.exec(c)) !== null) {
  if (m[3].length > 0 || /chat|session|tab|input|send|对话|发送|消息|记录|市场|设置|角色卡/.test(m[1])) {
    out.push(`${m[1]} | ${m[2]} | ${m[3].slice(0,40)}`);
  }
}
console.log(out.join('\n'));
console.log('\n--- text-only ---');
const re2 = /"text":"([^"]{1,80})"/g;
let m2;
const out2 = [];
while ((m2 = re2.exec(c)) !== null) {
  out2.push(m2[1]);
}
console.log(out2.join(' | '));
