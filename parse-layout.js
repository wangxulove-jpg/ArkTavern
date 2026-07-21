const fs = require('fs');
const c = fs.readFileSync('D:/DevEco_studio/ArkTavern/layout-current.json', 'utf8');
const m = c.match(/"text":"[^"]*"/g);
console.log('text matches:', m ? m.length : 0);
if (m) console.log(m.slice(0, 80).join('\n'));

const ed = c.match(/"id":"[^"]*EditText[^"]*"/g);
console.log('\nEditText ids:', ed ? ed.length : 0);
if (ed) console.log(ed.slice(0, 20).join('\n'));

const btn = c.match(/"id":"[^"]*Button[^"]*"/g);
console.log('\nButton ids:', btn ? btn.length : 0);
if (btn) console.log(btn.slice(0, 20).join('\n'));

const all = c.match(/"id":"[^"]+"/g);
console.log('\nAll ids (first 60):', all ? all.slice(0, 60).join('\n') : 'none');
