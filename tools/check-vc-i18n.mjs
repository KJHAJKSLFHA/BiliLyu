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

// 10) 转换页 app/index.html 的主题完整性
//     这个页面与宣传页共用 localStorage 的 vc2_theme，两边令牌也必须成套。
{
  const APP = path.join(ROOT, 'app', 'index.html');
  if (!fs.existsSync(APP)) { bad('转换页存在', '找不到 app/index.html'); }
  else {
    const a = fs.readFileSync(APP, 'utf8');
    const probs = [];

    // a) 内联脚本（预涂脚本 + 主逻辑）语法
    const scripts = [...a.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(x => x[1]);
    if (!scripts.length) probs.push('没有内联脚本');
    scripts.forEach((c, i) => { try { new Function(c); } catch (e) { probs.push('脚本#' + (i + 1) + ' 语法: ' + e.message); } });

    // b) 预涂脚本必须在 <style> 之前，否则会闪一帧错色
    const iPre = a.indexOf("localStorage.getItem('vc2_theme')");
    const iStyle = a.indexOf('<style>');
    if (iPre < 0) probs.push("缺少读 vc2_theme 的预涂脚本");
    else if (iStyle >= 0 && iPre > iStyle) probs.push('预涂脚本在 <style> 之后，会闪一帧');

    // c) 两套令牌 key 必须完全一致（对齐）
    const blk = (sel) => {
      const i = a.indexOf(sel); if (i < 0) return null;
      let depth = 0; const start = a.indexOf('{', i) + 1;
      for (let k = start - 1; k < a.length; k++) {
        if (a[k] === '{') depth++;
        else if (a[k] === '}') { depth--; if (depth === 0) return a.slice(start, k); }
      }
      return null;
    };
    const keysOf = (s) => { const o = new Set(); let x; const re = /^\s*(--[a-z0-9-]+)\s*:/gm; while ((x = re.exec(s))) o.add(x[1]); return o; };
    const D = blk(':root, :root[data-theme="dark"] {') || blk(':root, :root[data-theme="dark"]{');
    const L = blk(':root[data-theme="light"] {') || blk(':root[data-theme="light"]{');
    if (!D || !L) probs.push('找不到深色或浅色令牌块');
    else {
      const dk = keysOf(D), lk = keysOf(L);
      const onlyD = [...dk].filter(k => !lk.has(k)), onlyL = [...lk].filter(k => !dk.has(k));
      if (onlyD.length || onlyL.length) {
        probs.push('令牌不对齐' + (onlyD.length ? ' 只在深色: ' + onlyD.join(',') : '') + (onlyL.length ? ' 只在浅色: ' + onlyL.join(',') : ''));
      }
      // d) 规则体里不许有硬编码色
      const styleBlk = (() => { const i = a.indexOf('<style>'); const j = a.indexOf('</style>', i); return i < 0 ? '' : a.slice(i, j); })();
      const offenders = [];
      styleBlk.split('\n').forEach((line, n) => {
        if (/^\s*--/.test(line)) return;
        if (/data:image\/svg/.test(line)) return;
        const m2 = line.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)/);
        if (m2) offenders.push(m2[0] + ' @第' + (n + 1) + '行');
      });
      if (offenders.length) probs.push('硬编码色: ' + offenders.slice(0, 4).join(' '));

      // e) 深色令牌必须保持原值（保证「旧版外观不变」）
      //    --text3 例外：旧值 4.12:1 达不到 AA，已按无障碍要求调亮。
      const ORIG = { '--bg': '#0e1116', '--bg2': '#141922', '--card': '#181e28', '--card2': '#1e2530',
                     '--line': '#262e3b', '--text': '#e8ecf3', '--text2': '#9aa6b8',
                     '--accent': '#00a1d6', '--accent2': '#fb7299' };
      const dv = {}; let x; const re2 = /(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})/g;
      while ((x = re2.exec(D))) dv[x[1]] = x[2];
      const changed = Object.keys(ORIG).filter(k => dv[k] && dv[k].toLowerCase() !== ORIG[k]);
      if (changed.length) probs.push('深色令牌被改动: ' + changed.map(k => k + '=' + dv[k]).join(' '));

      // f) 对比度 AA：13 组前景/背景 × 深浅两套
      const hexc = (s) => [1, 3, 5].map(i => parseInt(s.slice(i, i + 2), 16));
      const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
      const ratio = (p, q) => { const A = lum(hexc(p)), B = lum(hexc(q)); const hi = Math.max(A, B), lo = Math.min(A, B); return (hi + 0.05) / (lo + 0.05); };
      const d3 = {}; const re3 = /(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})/g; while ((x = re3.exec(D))) d3[x[1]] = x[2];
      const l3 = {}; const re4 = /(--[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{6})/g; while ((x = re4.exec(L))) l3[x[1]] = x[2];
      const PAIRS = [['正文/底色','--text','--bg'], ['次要/底色','--text2','--bg'], ['三级/底色','--text3','--bg'],
                     ['正文/顶栏','--text','--bg2'], ['正文/卡片','--text','--card'], ['次要/卡片','--text2','--card'],
                     ['强调/底色','--accent','--bg'], ['强调/卡片','--accent','--card'], ['次强调/卡片','--accent2','--card'],
                     ['三级/卡片2','--text3','--card2'], ['成功/卡片','--ok','--card'],
                     ['警告/卡片','--warn','--card'], ['错误/卡片','--err','--card']];
      const cfails = []; let cmin = Infinity, cnum = 0;
      for (const [nm, T] of [['深色', d3], ['浅色', l3]]) {
        for (const [lab, f, b] of PAIRS) {
          if (!T[f] || !T[b]) continue;
          cnum++;
          const r = ratio(T[f], T[b]);
          if (r < cmin) cmin = r;
          if (r < 4.5) cfails.push(nm + ' ' + lab + ' ' + r.toFixed(2) + ':1');
        }
      }
      if (cfails.length) probs.push('对比度不达标(AA 需 4.5): ' + cfails.join('  '));
      else probs.push('__con:' + cnum + '/' + cmin.toFixed(2));   // 用前缀回传统计，稍后转成 OK 文案
    }

    const conNote = probs.find(p => p.startsWith('__con:'));
    const real = probs.filter(p => !p.startsWith('__con:'));
    if (real.length) bad('转换页主题', real.join('  |  '));
    else {
      const c = conNote ? conNote.slice(6).split('/') : null;
      ok('转换页主题', '脚本/预涂/令牌对齐/无硬编码色/深色原值 均 OK' +
        (c ? '  对比度 ' + c[0] + ' 项，最低 ' + c[1] + ':1' : ''));
    }
  }
}

console.log('');
if (failed) { console.log('  ✗ ' + failed + ' 项未通过'); process.exit(1); }
console.log('  全部通过 ✅');
