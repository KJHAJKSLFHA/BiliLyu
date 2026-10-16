// 回归测试：Netlify 徽章必须被盖住，且不能挡住右下角的按钮。
//
// 背景：Netlify 免费套餐改规则后，HUD 里 HIDEABLE 恒为 false，
// 我们写 localStorage 的那招被官方主动作废（脚本读到 "hidden" 会抹掉再渲染）。
// 现在靠 <style> 里按 id 盖 #nl-badge-frame / #nl-hud-frame。
// 这个测试用官方脚本同样的方式插 iframe，验证 CSS 压得住。
//
//   python3 -m http.server 8989 --bind 127.0.0.1 &
//   node bench/test-vc-badge.mjs http://127.0.0.1:8989/app/

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const url = process.argv[2] || 'http://127.0.0.1:8989/app/';

const child = spawn(process.execPath,
  [join(__dirname, 'cdp.mjs'), url, join(__dirname, 'badge.expr.js')],
  { stdio: ['ignore', 'pipe', 'inherit'] });

let out = '';
child.stdout.on('data', (d) => { out += d; });
child.on('close', (code) => {
  const s = out.indexOf('['), e = out.lastIndexOf(']');
  if (s < 0 || e < 0) { console.error('没拿到结果：\n' + out); process.exit(1); }
  const rows = JSON.parse(out.slice(s, e + 1));
  let pass = 0, fail = 0;
  for (const r of rows) {
    if (r.pass) { pass++; console.log(`  ✓ ${r.name}`); }
    else { fail++; console.log(`  ✗ ${r.name}${r.detail ? '  → ' + r.detail : ''}`); }
  }
  console.log(`\n${pass}/${pass + fail} 通过` + (fail ? `  ❌ ${fail} 个失败` : '  ✅'));
  process.exit(fail || code ? 1 : 0);
});
