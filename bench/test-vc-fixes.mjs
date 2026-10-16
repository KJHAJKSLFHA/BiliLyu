// VC 回归测试入口：锁死两个已修的 bug，防止以后再退化。
//
//   1. 转换完成后原视频文件夹没被删掉（整目录删除 + 写权限）
//   2. 「清空列表」对右边抽屉的转换记录没效果
//
// 跑法（先起静态服务指向仓库根）：
//   python3 -m http.server 8989 --bind 127.0.0.1 &
//   node bench/test-vc-fixes.mjs http://127.0.0.1:8989/app/
//
// 真正的断言在 bench/vc-fixes.expr.js 里，跑在页面上下文，
// 所以拿到的是真实的 state / render / deleteOriginals，而不是正则猜源码。

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const url = process.argv[2] || 'http://127.0.0.1:8989/app/';

const child = spawn(
  process.execPath,
  [join(__dirname, 'cdp.mjs'), url, join(__dirname, 'vc-fixes.expr.js')],
  { stdio: ['ignore', 'pipe', 'inherit'] }
);

let out = '';
child.stdout.on('data', (d) => { out += d; });
child.on('close', (code) => {
  const start = out.indexOf('[');
  const end = out.lastIndexOf(']');
  if (start < 0 || end < 0) {
    console.error('没能拿到测试结果。原始输出：\n' + out);
    process.exit(1);
  }
  let rows;
  try { rows = JSON.parse(out.slice(start, end + 1)); }
  catch (e) {
    console.error('结果不是合法 JSON：\n' + out.slice(start, end + 1));
    process.exit(1);
  }
  let pass = 0, fail = 0;
  for (const r of rows) {
    if (r.pass) { pass++; console.log(`  ✓ ${r.name}`); }
    else { fail++; console.log(`  ✗ ${r.name}${r.detail ? '  → ' + r.detail : ''}`); }
  }
  console.log(`\n${pass}/${pass + fail} 通过` + (fail ? `  ❌ ${fail} 个失败` : '  ✅'));
  process.exit(fail || code ? 1 : 0);
});
