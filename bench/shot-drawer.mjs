// 截图：VC 抽屉里的「清除记录」按钮，浅色 + 深色。
//   node bench/shot-drawer.mjs [baseUrl]
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const BASE = process.argv[2] || 'http://127.0.0.1:8989/app/';
const CDP_PORT = Number(process.argv[3] || 9399);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const profile = join(tmpdir(), 'vc-shot-drawer');
mkdirSync(profile, { recursive: true });

const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu-sandbox',
  '--disable-crash-reporter', '--disable-breakpad',
  `--remote-debugging-port=${CDP_PORT}`, `--user-data-dir=${profile}`,
  '--no-first-run', '--no-default-browser-check', '--disable-extensions',
  '--mute-audio', '--window-size=1440,900', 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore'] });

async function cdp(ws, method, params = {}, id = Math.floor(Math.random() * 1e6)) {
  return new Promise((res, rej) => {
    const on = (evt) => {
      const raw = (evt && evt.data !== undefined) ? evt.data : evt;
      const m = JSON.parse(typeof raw === 'string' ? raw : String(raw));
      if (m.id === id) { ws.removeEventListener('message', on); m.error ? rej(new Error(m.error.message)) : res(m.result); }
    };
    ws.addEventListener('message', on);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function evalJs(ws, expression) {
  const r = await cdp(ws, 'Runtime.evaluate', { expression: `(async () => { ${expression} })()`, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
  return r.result.value;
}

const FILL = `
const mk = (id) => ({ id, kind:'single', title:id, uname:'', bvid:'', duration:0, quality:'',
  coverUrl:'', vrec:null, arec:null, size:0, sizeText:'', status:'pending', progress:0,
  message:'', outName:'', originals:[], deletable:false, hash:id });
state.items.length = 0; state.sel.clear();
state.items.push(mk('v1'), mk('v2'), mk('v3'));
state.jobs = [
  { videoId:'v1', title:'【4K】Python 入门教程 P1', status:'done', progress:1, message:'', outName:'a.mp4', duration:754 },
  { videoId:'v2', title:'线性代数 第 3 讲', status:'running', progress:0.42, message:'正在合并音视频…', outName:'', duration:1320 },
  { videoId:'v3', title:'英语听力练习 01', status:'error', progress:0.1, message:'内核崩溃', outName:'', duration:300 },
];
render(); paintDrawer();
document.getElementById('drawer').classList.add('open');
`;

const main = async () => {
  await sleep(1600);
  const list = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`)).json();
  const page = list.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl, { maxPayload: 256 * 1024 * 1024 });
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  await cdp(ws, 'Page.enable');
  await cdp(ws, 'Runtime.enable');
  await cdp(ws, 'Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 2, mobile: false });

  for (const theme of ['light', 'dark']) {
    await cdp(ws, 'Page.navigate', { url: BASE });
    await sleep(2200);
    await evalJs(ws, `localStorage.setItem('vc-theme', '${theme}'); document.documentElement.dataset.theme='${theme}';`);
    await evalJs(ws, FILL);
    await sleep(600);
    const r = await cdp(ws, 'Page.captureScreenshot', { format: 'png' });
    writeFileSync(`/tmp/vc-repro/drawer-${theme}.png`, Buffer.from(r.data, 'base64'));
    console.log(`  ✓ drawer-${theme}.png`);
  }
  chrome.kill('SIGKILL');
  process.exit(0);
};
main().catch((e) => { console.error('FAIL', e); chrome.kill('SIGKILL'); process.exit(1); });
