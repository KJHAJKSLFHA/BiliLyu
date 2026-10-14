// 校验 index.html 的三语字典与页面结构。
// 用法：node tools/check-vc-i18n.mjs
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.dirname(path.dirname(new URL(import.meta.url).pathname));
const FILE = path.join(ROOT, 'index.html');
const h = fs.readFileSync(FILE, 'utf8');

let failed = 0;
const ok = (label, extra='') => console.log('  ' + label.padEnd(22) + 'OK' + (extra ? '  ' + extra : ''));
const bad = (label, detail) => { failed++; console.log('  ✗ ' + label + '  ' + detail); };

// 1) JS 语法
const m = h.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { bad('JS 语法', '没找到 script 块'); }
else {
  try { new Function(m[1]); ok('JS 语法'); }
  catch (e) { bad('JS 语法', e.message); }
}

// 2) 三语 key 对齐
const KEYS = ['zh', 'en', 'es'];
const sets = {};
for (let i = 0; i < KEYS.length; i++) {
  const name = KEYS[i], next = KEYS[i + 1];
  const a = h.indexOf('\n  ' + name + ': {');
  if (a < 0) { bad('语言块', '找不到 ' + name); continue; }
  const b = next ? h.indexOf('\n  ' + next + ': {') : h.indexOf('\n};', a);
  const blk = h.slice(a, b);
  const s = new Set();
  const re = /^\s{4}'([A-Za-z0-9._]+)':/gm;
  let x; while ((x = re.exec(blk))) s.add(x[1]);
  sets[name] = s;
}
if (sets.zh && sets.en && sets.es) {
  const counts = KEYS.map(k => k + '=' + sets[k].size).join('  ');
  let diff = 0;
  for (let i = 0; i < 3; i++) for (let j = i + 1; j < 3; j++) {
    const A = KEYS[i], B = KEYS[j];
    const onlyA = [...sets[A]].filter(k => !sets[B].has(k));
    const onlyB = [...sets[B]].filter(k => !sets[A].has(k));
    if (onlyA.length || onlyB.length) {
      diff++;
      bad('key 对齐',
        A + ' vs ' + B + (onlyA.length ? '  只在' + A + ': ' + onlyA.join(', ') : '') +
        (onlyB.length ? '  只在' + B + ': ' + onlyB.join(', ') : ''));
    }
  }
  if (!diff) ok('三语 key 一致', counts);
}

// 3) 页面引用的 key 都有译文
const used = new Set();
const r2 = /data-i18n(?:-html|-ph)?="([A-Za-z0-9._]+)"/g;
let y; while ((y = r2.exec(h))) used.add(y[1]);
const missing = [...used].filter(k => !sets.zh.has(k));
if (missing.length) bad('引用 key 有译文', '缺: ' + missing.join(', '));
else ok('引用 key 有译文', used.size + ' 个引用');

// 4) 含 HTML 标签的译文必须用 data-i18n-html 绑定
{
  const zi = h.indexOf('\n  zh: {'), ei = h.indexOf('\n  en: {');
  const zh = h.slice(zi, ei);
  const re = /^\s{4}'([A-Za-z0-9._]+)':\s*'([^']*)'/gm;
  let x; const wrong = [];
  const withHtml = [];
  while ((x = re.exec(zh))) {
    const k = x[1], v = x[2];
    if (!/<[a-z][^>]*>/i.test(v)) continue;
    withHtml.push(k);
    const plain = h.indexOf('data-i18n="' + k + '"') >= 0;
    const html = h.indexOf('data-i18n-html="' + k + '"') >= 0;
    if (plain && !html) wrong.push(k);
  }
  if (wrong.length) bad('HTML key 绑定', '应改用 data-i18n-html: ' + wrong.join(', '));
  else ok('HTML key 绑定', withHtml.length ? withHtml.join(', ') : '（无）');
}

// 5) 宣传页不该残留转换器代码
{
  const traces = ['window.FFmpeg', 'ensureEngine(', 'startConvert(', 'ingestRecords(', 'btnPickFiles', 'dropbig'];
  const hit = traces.filter(w => h.includes(w));
  if (hit.length) bad('无转换器残留', hit.join(', '));
  else ok('无转换器残留');
}

// 6) 页内锚点无死链
{
  const anchors = [...h.matchAll(/href="#([A-Za-z0-9_-]+)"/g)].map(z => z[1]);
  const ids = new Set([...h.matchAll(/\bid="([A-Za-z0-9_-]+)"/g)].map(z => z[1]));
  const dead = anchors.filter(d => !ids.has(d));
  if (dead.length) bad('页内锚点', '死链: ' + dead.join(', '));
  else ok('页内锚点', anchors.length + ' 个，无死链');
}

// 7) 外链存在
{
  const ext = [...new Set([...h.matchAll(/href="(https?:\/\/[^"]+)"/g)].map(z => z[1]))];
  if (ext.length) ok('外链', ext.length + ' 个');
  else bad('外链', '一个都没有');
}

// 8) 两套主题的令牌 key 必须完全一致，且颜色不得写死在 CSS 规则里
{
  const grab = (sel) => {
    const i = h.indexOf(sel);
    if (i < 0) return null;
    let depth = 0, j = h.indexOf('{', i);
    const start = j + 1;
    for (let k = j; k < h.length; k++) {
      if (h[k] === '{') depth++;
      else if (h[k] === '}') { depth--; if (depth === 0) return h.slice(start, k); }
    }
    return null;
  };
  const darkBlk  = grab(':root, :root[data-theme="dark"] {');
  const lightBlk = grab(':root[data-theme="light"] {');
  if (!darkBlk || !lightBlk) bad('主题令牌', '找不到 dark 或 light 块');
  else {
    const decls = (blk) => {
      const s = new Set();
      const re = /(--[a-z0-9-]+)\s*:/gm;
      let x; while ((x = re.exec(blk))) s.add(x[1]);
      return s;
    };
    const D = decls(darkBlk), L = decls(lightBlk);
    const onlyD = [...D].filter(k => !L.has(k));
    const onlyL = [...L].filter(k => !D.has(k));
    if (onlyD.length || onlyL.length) {
      bad('主题令牌对齐',
        (onlyD.length ? '只在 dark: ' + onlyD.join(', ') : '') +
        (onlyL.length ? '  只在 light: ' + onlyL.join(', ') : ''));
    } else ok('主题令牌对齐', D.size + ' 个令牌 × 2 套');
  }

  // 规则体里不该再出现硬编码颜色（令牌定义行与 SVG 除外）
  const styleBlk = h.slice(h.indexOf('<style>'), h.indexOf('</style>'));
  const offenders = [];
  styleBlk.split('\n').forEach((line, n) => {
    if (/^\s*--/.test(line)) return;                 // 令牌定义
    if (/data:image\/svg/.test(line)) return;        // 内联图标
    const m2 = line.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)/);
    if (m2) offenders.push(m2[0] + ' @样式第' + (n + 1) + '行');
  });
  if (offenders.length) bad('无硬编码颜色', offenders.slice(0, 6).join('  ') + (offenders.length > 6 ? ' …共' + offenders.length : ''));
  else ok('无硬编码颜色', '全部走 CSS 变量');
}

// 9) 对比度（WCAG AA 正文 >= 4.5:1）
{
  const grab = (sel) => {
    const i = h.indexOf(sel); if (i < 0) return null;
    let depth = 0; const start = h.indexOf('{', i) + 1;
    for (let k = start - 1; k < h.length; k++) {
      if (h[k] === '{') depth++;
      else if (h[k] === '}') { depth--; if (depth === 0) return h.slice(start, k); }
    }
    return null;
  };
  const tokensOf = (blk) => {
    const o = {};
    const re = /(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})/g;
    let x; while ((x = re.exec(blk))) o[x[1]] = x[2];
    return o;
  };
  const D = tokensOf(grab(':root, :root[data-theme="dark"] {') || '');
  const L = tokensOf(grab(':root[data-theme="light"] {') || '');
  const hex = (s) => [1, 3, 5].map(i => parseInt(s.slice(i, i + 2), 16));
  const lum = (c) => {
    const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
  };
  const ratio = (a, b) => { const la = lum(hex(a)), lb = lum(hex(b)); const hi = Math.max(la, lb), lo = Math.min(la, lb); return (hi + 0.05) / (lo + 0.05); };

  const checks = [];
  for (const [name, T] of [['dark', D], ['light', L]]) {
    if (T['--text'] && T['--bg'])     checks.push([name + ' 正文/底色', T['--text'], T['--bg']]);
    if (T['--text-2'] && T['--bg'])   checks.push([name + ' 次要/底色', T['--text-2'], T['--bg']]);
    if (T['--text-3'] && T['--bg'])   checks.push([name + ' 三级/底色', T['--text-3'], T['--bg']]);
    if (T['--brand'] && T['--bg'])    checks.push([name + ' 链接/底色', T['--brand'], T['--bg']]);
    if (T['--text'] && T['--panel'])  checks.push([name + ' 正文/卡片', T['--text'], T['--panel']]);
  }
  const fails = checks.filter(([, fg, bg]) => ratio(fg, bg) < 4.5);
  if (fails.length) bad('对比度 AA', fails.map(([n, fg, bg]) => n + ' ' + ratio(fg, bg).toFixed(2) + ':1').join('  '));
  else {
    const min = Math.min(...checks.map(([, fg, bg]) => ratio(fg, bg)));
    ok('对比度 AA', checks.length + ' 项，最低 ' + min.toFixed(2) + ':1');
  }
}

console.log('');
if (failed) { console.log('  ✗ ' + failed + ' 项未通过'); process.exit(1); }
console.log('  全部通过 ✅');
