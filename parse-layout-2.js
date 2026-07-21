const fs = require('fs');
const c = fs.readFileSync('D:/DevEco_studio/ArkTavern/layout-current.json', 'utf8');
const all = c.match(/"id":"[^"]+"/g);
if (all) {
  console.log('Total ids:', all.length);
  // Find send button / TextArea / EditText / btn / input
  const send = all.filter(s => /send|发送|Submit|TextArea|EditText/i.test(s));
  console.log('send/input ids:');
  if (send.length > 0) console.log(send.join('\n'));
  else console.log('(none)');
}
