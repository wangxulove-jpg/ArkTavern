const fs = require('fs');
const path = process.argv[2];
const c = fs.readFileSync(path, 'utf8');
// Find any text by character
const re2 = /"text":"([^"]{1,60})"/g;
let m2;
const out2 = [];
while ((m2 = re2.exec(c)) !== null) {
  out2.push(m2[1]);
}
console.log(out2.join(' | '));

// also find any item with text + bounds
const re3 = /"bounds":"(\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\])"[^}]*?"text":"([^"]{1,60})"/g;
let m3;
const out3 = [];
while ((m3 = re3.exec(c)) !== null) {
  if (m3[2].length > 0) out3.push(`${m3[1]} | ${m3[2]}`);
}
console.log('\n--- text+bounds ---');
console.log(out3.slice(0, 30).join('\n'));
