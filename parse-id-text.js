const fs = require('fs');
const path = process.argv[2] || 'D:/DevEco_studio/ArkTavern/l1.json';
const c = fs.readFileSync(path, 'utf8');
// Find all components with id+text+bounds
const re = /"id":"([^"]+)"[^}]*?"text":"([^"]{1,40})"[^}]*?"bounds":"(\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\])"/g;
let m;
const out = [];
while ((m = re.exec(c)) !== null) {
  out.push(`id=${m[1]} bounds=${m[3]} text="${m[2]}"`);
}
console.log(out.slice(0, 60).join('\n'));
