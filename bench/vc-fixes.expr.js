// 页面内跑的测试体。由 bench/test-vc-fixes.mjs 通过 bench/cdp.mjs 注入执行。
// 这里直接拿真实的 state / render / deleteOriginals，不是正则猜源码。
// 最后一行表达式的值就是返回值（数组 JSON 字符串）。
const R = [];
const ok = (name, cond, detail) => R.push({ name, pass: !!cond, detail });
const oc = window.confirm;
const autoYes = (box) => { window.confirm = (m) => { box.msg = m; return true; }; };

const mk = (id) => ({
  id, kind:'single', title:id, uname:'', bvid:'', duration:0, quality:'',
  coverUrl:'', vrec:null, arec:null, size:0, sizeText:'', status:'pending',
  progress:0, message:'', outName:'', originals:[], deletable:false, hash:id,
});

try {
  // ── bug 2：抽屉「清除记录」────────────────────────────
  const btnJobs = document.getElementById('btnClearJobs');
  ok('抽屉上有「清除记录」按钮', !!btnJobs);

  state.items.length = 0; state.sel.clear();
  state.items.push(mk('v1'), mk('v2'));
  state.jobs = [
    { videoId:'v1', title:'v1', status:'done',  progress:1,   message:'', outName:'v1.mp4', duration:60 },
    { videoId:'v2', title:'v2', status:'error', progress:0.4, message:'x', outName:'',       duration:60 },
  ];
  render(); paintDrawer();
  ok('清除前抽屉有 2 行', document.querySelectorAll('#jobList .job').length === 2);
  ok('清除前悬浮角标是 2', document.getElementById('fabCnt').textContent === '2');

  const box = {}; autoYes(box);
  if (btnJobs) btnJobs.click();
  window.confirm = oc;

  ok('清除后 state.jobs 清空', state.jobs.length === 0);
  ok('清除后抽屉 0 行', document.querySelectorAll('#jobList .job').length === 0,
     '实际 ' + document.querySelectorAll('#jobList .job').length);
  ok('清除后悬浮角标归零', document.getElementById('fabCnt').textContent === '0',
     '实际 ' + document.getElementById('fabCnt').textContent);
  ok('清除记录不碰主列表', state.items.length === 2, '实际 ' + state.items.length);
  ok('清除记录有二次确认', !!box.msg);

  // ── 「清空列表」仍然只清主列表 ────────────────────────
  state.jobs = [{ videoId:'v1', title:'v1', status:'done', progress:1, message:'', outName:'', duration:60 }];
  render(); paintDrawer();
  const box2 = {}; autoYes(box2);
  document.getElementById('btnClearAll').click();
  window.confirm = oc;
  ok('清空列表会清掉主列表', state.items.length === 0);
  ok('清空列表不动抽屉记录（两者独立）', state.jobs.length === 1 && !!box2.msg);

  // ── bug 1a：deleteOriginals 删的是整个文件夹 ─────────
  const calls = [];
  const fakeDir = { removeEntry: async (name, o) => { calls.push([name, o]); } };
  const twoFiles = {
    originals: [
      { handle: fakeDir, name: '视频.m4s', parent: fakeDir, parentName: '【标题】' },
      { handle: fakeDir, name: '音频.m4s', parent: fakeDir, parentName: '【标题】' },
    ],
  };
  const r1 = await deleteOriginals(twoFiles);
  ok('同一文件夹只删一次（不重复调 removeEntry）', calls.length === 1,
     '调了 ' + calls.length + ' 次: ' + JSON.stringify(calls.map(c => c[0])));
  ok('删的是文件夹本身', calls[0] && calls[0][0] === '【标题】', '实际 ' + (calls[0] && calls[0][0]));
  ok('删除带 recursive', !!(calls[0] && calls[0][1] && calls[0][1].recursive));
  ok('删目录成功不报 failed', r1.failed.length === 0 && r1.dirs === 1, JSON.stringify(r1));

  // ── bug 1b：目录删不掉时退回逐个删文件，并如实报错 ───
  const calls2 = [];
  const denyDir = {
    removeEntry: async (name) => { calls2.push('dir:' + name); const e = new Error('no'); e.name = 'NotAllowedError'; throw e; },
  };
  const fileDir = { removeEntry: async (name) => { calls2.push('file:' + name); } };
  const denied = { originals: [{ handle: fileDir, name: '视频.m4s', parent: denyDir, parentName: '【标题】' }] };
  const r2 = await deleteOriginals(denied);
  ok('目录删不掉时退回删文件', r2.files === 1, JSON.stringify(r2));
  ok('删除失败会报出来（不再静默吞掉）', r2.failed.length === 1, JSON.stringify(r2.failed));

  // ── bug 1c：目录已经不在了不算错误 ──────────────────
  const goneDir = { removeEntry: async () => { const e = new Error('gone'); e.name = 'NotFoundError'; throw e; } };
  const gone = { originals: [{ handle: fakeDir, name: 'x.m4s', parent: goneDir, parentName: '【标题】' }] };
  const r3 = await deleteOriginals(gone);
  ok('目录已不存在视为成功', r3.dirs === 1 && r3.failed.length === 0, JSON.stringify(r3));

  // ── bug 1d：根目录下的文件不整层删 ───────────────────
  const rootCalls = [];
  const rootDir = { removeEntry: async (n) => { rootCalls.push(n); } };
  const atRoot = { originals: [{ handle: rootDir, name: 'a.mp4', parent: rootDir, parentName: null }] };
  const r4 = await deleteOriginals(atRoot);
  ok('顶层文件只删自己，不动整个根目录',
     rootCalls.length === 1 && rootCalls[0] === 'a.mp4' && r4.dirs === 0, JSON.stringify(rootCalls));

  // ── parentOf 解析 ───────────────────────────────────
  ok('parentOf 取最后一段', parentOf('a/b/') === 'b' && parentOf('【标题】/') === '【标题】');
  ok('parentOf 对顶层返回 null', parentOf('') === null);

  // ── 开关后补权限：ensureWriteAccess 请求的是父目录 ──
  {
    const asked = [];
    const parentH = {
      queryPermission: async () => 'prompt',
      requestPermission: async (o) => { asked.push(o && o.mode); return 'granted'; },
      removeEntry: async () => {},
    };
    const rec = { del: { handle: parentH, name: '视频.m4s', parent: parentH, parentName: '【标题】' } };
    const n = await ensureWriteAccess([rec]);
    ok('ensureWriteAccess 会请求父目录读写权', n === 1 && asked[0] === 'readwrite',
       'n=' + n + ' mode=' + asked[0]);
  }
  {
    // 顶层文件（无 parentName）不该去要权限：不整目录删
    const asked2 = [];
    const h = {
      queryPermission: async () => 'prompt',
      requestPermission: async () => { asked2.push(1); return 'granted'; },
    };
    const rec = { del: { handle: h, name: 'a.mp4', parent: h, parentName: null } };
    const n = await ensureWriteAccess([rec]);
    ok('顶层文件不请求写权限（不整层删）', n === 0 && asked2.length === 0, 'n=' + n);
  }

  // ── 卡死自愈：running 卡住时仍能清空 ────────────────
  state.items.length = 0; state.jobs.length = 0;
  state.items.push(mk('r1'));
  state.running = state.items[0];
  state.ff = null;
  await cancelAll();
  ok('cancelAll 同步复位 running', state.running === null, '实际 ' + String(state.running));
  const box3 = {}; autoYes(box3);
  document.getElementById('btnClearAll').click();
  window.confirm = oc;
  ok('running 复位后清空列表不再被挡', state.items.length === 0 && !!box3.msg);

} catch (e) {
  R.push({ name: '测试自身异常', pass: false, detail: (e && e.stack) || String(e) });
}
return JSON.stringify(R);
