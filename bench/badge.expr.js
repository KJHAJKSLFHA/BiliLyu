// 模拟 Netlify 的 HUD：按官方脚本同样的方式插一个 nl-badge-frame，
// 带同样的行内样式和 z-index，看我们的 CSS 能不能压住。
const R = [];
const ok = (n,c,d)=>R.push({name:n,pass:!!c,detail:d});

// 官方脚本用的 base 样式（hud.js:483）
const base = 'position:fixed;bottom:0;right:0;border:0;margin:0;padding:0;background:transparent;color-scheme:dark;z-index:2147483645;';
const f = document.createElement('iframe');
f.id = 'nl-badge-frame';
f.setAttribute('title','Powered by Netlify');
f.style.cssText = base + "width:216px;height:92px;clip-path:path('M0 0Z')";
document.documentElement.appendChild(f);

const cs = getComputedStyle(f);
ok('插入成功', !!document.getElementById('nl-badge-frame'));
ok('visibility 被盖成 hidden', cs.visibility === 'hidden', '实际 ' + cs.visibility);
ok('opacity 被盖成 0', cs.opacity === '0', '实际 ' + cs.opacity);
ok('pointer-events 被盖成 none', cs.pointerEvents === 'none', '实际 ' + cs.pointerEvents);
ok('宽度被压成 0', cs.width === '0px', '实际 ' + cs.width);
ok('高度被压成 0', cs.height === '0px', '实际 ' + cs.height);
ok('z-index 仍然很高但看不见（不靠 z-index 压制）', cs.zIndex === '2147483645', '实际 ' + cs.zIndex);
ok('clip-path 被覆盖', cs.clipPath.includes('inset'), '实际 ' + cs.clipPath);

// 视觉上不占位
const r = f.getBoundingClientRect();
ok('不占布局空间', r.width === 0 && r.height === 0, r.width + 'x' + r.height);

// owner-private 变体也一起盖
const g = document.createElement('iframe');
g.id = 'nl-hud-frame';
g.style.cssText = base + "width:652px;height:94px";
document.documentElement.appendChild(g);
ok('owner 工具条也被盖住', getComputedStyle(g).visibility === 'hidden');

// 页面底部按钮仍然可点（徽章不再拦截点击）
const hit = document.elementFromPoint(innerWidth - 40, innerHeight - 40);
ok('右下角不再被徽章拦截',
   !hit || (hit.tagName !== 'IFRAME'),
   '命中 ' + (hit ? hit.tagName + (hit.id?('#'+hit.id):'') : 'null'));

return JSON.stringify(R);
