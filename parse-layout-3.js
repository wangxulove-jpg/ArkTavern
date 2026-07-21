const fs = require('fs');
const c = fs.readFileSync('D:/DevEco_studio/ArkTavern/layout-current.json', 'utf8');
// Find all components with type and their bounds
const lines = c.split('\n');
const all = c.match(/"id":"[^"]+"/g) || [];
console.log('all ids:');
all.forEach(x => console.log(' ', x));

console.log('\n--- looking for clickable ---');
const clickable = c.match(/"clickable":true[^}]*?\"bounds\":\"[^\"]+\"/g);
if (clickable) {
  clickable.slice(0, 30).forEach(x => console.log(' ', x));
} else {
  console.log('no clickable matched, try another approach');
  const cb = c.match(/\"bounds\":\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"/g);
  if (cb) {
    console.log('total bounds:', cb.length);
    cb.slice(0, 30).forEach(x => console.log(' ', x));
  }
}
