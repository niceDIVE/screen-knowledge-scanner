/* 屏幕扫描机器人 — 前端逻辑（无依赖） */
'use strict';
const $ = (id) => document.getElementById(id);

let currentTab = 'vault';
let statusCache = null;

function toast(msg, ms) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(t._tm);
  t._tm = setTimeout(() => t.classList.add('hidden'), ms || 3200);
}

async function api(path, opts) {
  const r = await fetch(path, opts);
  const j = await r.json().catch(() => ({ error: '响应解析失败' }));
  if (!r.ok) throw new Error(j.error || ('HTTP ' + r.status));
  return j;
}

/* ---------- 状态 ---------- */
function updateRegion(s) {
  const pill = $('region-pill');
  if (s.region) {
    pill.textContent = '区域：' + s.region.width + '×' + s.region.height + ' @(' + s.region.left + ',' + s.region.top + ')';
  } else {
    pill.textContent = '区域：全屏';
  }
  if (s.rhythm) {
    $('rhythm-text').textContent = '节奏：每步 ' + s.rhythm.notch + ' · 停 ' + s.rhythm.pause + ' · 偶尔读 ' + s.rhythm.extraRead;
  }
}

async function refreshStatus() {
  try {
    const s = await api('/api/status');
    statusCache = s;
    $('daemon-dot').className = 'dot ' + (s.daemon.running ? 'on' : 'off');
    $('daemon-text').textContent = '守护进程：' + (s.daemon.running ? '运行中 (pid ' + s.daemon.pid + ')' : '未运行');
    $('btn-daemon').textContent = s.daemon.running ? '停止守护进程' : '启动守护进程';
    const scrollOn = s.scroll.running;
    $('scroll-state').classList.toggle('hidden', !scrollOn);
    $('btn-scroll').textContent = scrollOn ? '中止滚动' : '滚动扫描';
    $('btn-scroll').classList.toggle('primary', scrollOn);
    updateRegion(s);
  } catch (e) {
    $('daemon-text').textContent = '状态获取失败：' + e.message;
  }
}

function setBusy(btn, busy, busyText) {
  if (busy) { btn.dataset.old = btn.textContent; btn.textContent = busyText; btn.disabled = true; }
  else { btn.textContent = btn.dataset.old || btn.textContent; btn.disabled = false; }
}

/* ---------- 动作 ---------- */
$('btn-capture').onclick = async () => {
  const b = $('btn-capture');
  setBusy(b, true, '扫描中…');
  try {
    const r = await api('/api/capture', { method: 'POST' });
    toast('已扫描：' + r.lines + ' 行（' + r.ocr + '）');
    if (currentTab === 'inbox') loadTab('inbox');
  } catch (e) { toast('扫描失败：' + e.message, 5000); }
  setBusy(b, false); refreshStatus();
};

$('btn-scroll').onclick = async () => {
  const b = $('btn-scroll');
  const on = statusCache && statusCache.scroll.running;
  setBusy(b, true, on ? '中止中…' : '启动中…');
  try {
    await api(on ? '/api/scroll-stop' : '/api/scroll-start', { method: 'POST' });
    toast(on ? '已中止滚动扫描' : '滚动扫描已启动（确保 Discord 已聚焦）');
  } catch (e) { toast('操作失败：' + e.message, 5000); }
  setBusy(b, false); refreshStatus();
};

$('btn-daemon').onclick = async () => {
  const b = $('btn-daemon');
  const on = statusCache && statusCache.daemon.running;
  setBusy(b, true, on ? '停止中…' : '启动中…');
  try {
    await api(on ? '/api/daemon-stop' : '/api/daemon-start', { method: 'POST' });
    toast(on ? '守护进程已停止' : '守护进程已启动，热键生效');
  } catch (e) { toast('操作失败：' + e.message, 5000); }
  setBusy(b, false); refreshStatus();
};

$('btn-region').onclick = async () => {
  try {
    await api('/api/region-select', { method: 'POST' });
    toast('在屏幕上按住左键拖拽框选，松开即生效；ESC 取消', 6000);
    setTimeout(refreshStatus, 4000);
  } catch (e) { toast('失败：' + e.message, 5000); }
};

$('btn-region-clear').onclick = async () => {
  try {
    await api('/api/region-clear', { method: 'POST' });
    toast('已恢复全屏采集');
    refreshStatus();
  } catch (e) { toast('失败：' + e.message, 5000); }
};

$('btn-process').onclick = async () => {
  const b = $('btn-process');
  setBusy(b, true, '处理中…');
  try {
    const r = await api('/api/process', { method: 'POST' });
    if (r.busy) { toast('已有入库任务在运行，请稍候'); }
    else {
      toast('入库已开始…');
      for (let i = 0; i < 120; i++) {
        await new Promise((res) => setTimeout(res, 1500));
        const s = await api('/api/process-status');
        if (s.state && s.state.indexOf('done') === 0) {
          toast((s.report || '入库完成').slice(0, 300), 8000);
          break;
        }
        if (i % 4 === 3) refreshStatus();
      }
    }
    loadTab(currentTab);
  } catch (e) { toast('处理失败：' + e.message, 5000); }
  setBusy(b, false); refreshStatus();
};

/* ---------- 搜索 / 问答 ---------- */
$('btn-search').onclick = doSearch;
$('q').addEventListener('keydown', (e) => { if (e.key === 'Enter') doSearch(); });
async function doSearch() {
  const q = $('q').value.trim();
  if (!q) return;
  const v = $('viewer');
  v.innerHTML = '<p class="hint">搜索中…</p>';
  try {
    const r = await api('/api/search?q=' + encodeURIComponent(q));
    if (!r.results.length) { v.innerHTML = '<p class="hint">没有命中：' + q + '</p>'; return; }
    v.innerHTML = '<p class="hint">命中 ' + r.total + ' 处 / ' + r.results.length + ' 个文件（点击打开）</p>';
    for (const res of r.results) {
      const div = document.createElement('div');
      div.className = 'search-hit';
      const f = document.createElement('div'); f.className = 'f';
      f.textContent = res.path + '（' + res.count + ' 处）';
      div.appendChild(f);
      for (const h of res.hits) {
        const l = document.createElement('div'); l.className = 'l';
        l.textContent = 'L' + h.line + ': ' + h.text;
        div.appendChild(l);
      }
      div.onclick = () => openFile(res.path);
      v.appendChild(div);
    }
  } catch (e) { v.innerHTML = '<p class="hint">搜索失败：' + e.message + '</p>'; }
}

$('btn-ask').onclick = doAsk;
$('aq').addEventListener('keydown', (e) => { if (e.key === 'Enter') doAsk(); });
async function doAsk() {
  const q = $('aq').value.trim();
  if (!q) return;
  const v = $('viewer');
  v.innerHTML = '<p class="hint">检索中…</p>';
  try {
    const r = await api('/api/ask?q=' + encodeURIComponent(q));
    v.innerHTML = '';
    const t = document.createElement('div'); t.className = 'viewer-title';
    t.textContent = '问一问：' + r.q;
    v.appendChild(t);
    const pre = document.createElement('pre'); pre.className = 'ans';
    pre.textContent = r.text;
    v.appendChild(pre);
  } catch (e) { v.innerHTML = '<p class="hint">失败：' + e.message + '</p>'; }
}

/* ---------- 文件列表 / 查看 ---------- */
document.querySelectorAll('.tabs button').forEach((b) => {
  b.onclick = () => {
    document.querySelectorAll('.tabs button').forEach((x) => x.classList.remove('on'));
    b.classList.add('on');
    loadTab(b.dataset.tab);
  };
});

function loadTab(tab) {
  currentTab = tab;
  const ul = $('filelist');
  ul.innerHTML = '';
  if (tab === 'checklist' || tab === 'log') { renderSpecial(tab); return; }
  const dir = tab === 'inbox' ? 'inbox-text' : 'vault';
  api('/api/list?dir=' + dir).then((r) => {
    if (!r.items.length) {
      const li = document.createElement('li');
      li.textContent = tab === 'inbox' ? '（空：先扫描屏幕）' : '（空：先处理 inbox）';
      ul.appendChild(li);
      return;
    }
    for (const it of r.items) {
      const li = document.createElement('li');
      const name = document.createElement('span'); name.textContent = it.name;
      const meta = document.createElement('span'); meta.className = 'meta';
      meta.textContent = it.mtime + ' · ' + Math.max(1, Math.round(it.size / 1024)) + 'KB';
      li.appendChild(name); li.appendChild(meta);
      const full = tab === 'inbox'
        ? 'inbox\\text\\' + it.name
        : 'vault\\scans\\' + it.name;
      li.onclick = () => openFile(full);
      ul.appendChild(li);
    }
  }).catch((e) => { const li = document.createElement('li'); li.textContent = '加载失败：' + e.message; ul.appendChild(li); });
}

function renderSpecial(tab) {
  const ul = $('filelist');
  const li = document.createElement('li');
  if (tab === 'checklist') {
    li.textContent = '打开手动复制清单 →';
    li.onclick = () => openFile('vault\\_meta\\手动复制清单.md');
  } else {
    li.textContent = '打开运行日志 →';
    li.onclick = () => openLog();
  }
  ul.appendChild(li);
}

function mdBlock() {
  const v = $('viewer');
  v.innerHTML = '';
  const box = document.createElement('div');
  box.className = 'md';
  v.appendChild(box);
  return box;
}

async function openFile(relPath) {
  const v = $('viewer');
  v.innerHTML = '<p class="hint">加载中…</p>';
  try {
    const r = await api('/api/file?p=' + encodeURIComponent(relPath));
    const box = mdBlock();
    const title = document.createElement('div');
    title.className = 'viewer-title';
    title.textContent = relPath;
    v.insertBefore(title, box);
    if (r.png) {
      const wrap = document.createElement('div'); wrap.className = 'imglink';
      const img = document.createElement('img');
      img.src = '/media?p=' + encodeURIComponent(r.png);
      img.alt = '截图';
      img.loading = 'lazy';
      wrap.appendChild(img);
      box.appendChild(wrap);
    }
    const pre = document.createElement('span');
    pre.textContent = r.content;
    box.appendChild(pre);
  } catch (e) {
    v.innerHTML = '<p class="hint">打开失败：' + e.message + '</p>';
  }
}

async function openLog() {
  const v = $('viewer');
  v.innerHTML = '<p class="hint">加载中…</p>';
  try {
    const r = await api('/api/log?n=120');
    v.innerHTML = '';
    const t = document.createElement('div'); t.className = 'viewer-title';
    t.textContent = '运行日志';
    v.appendChild(t);
    const pre = document.createElement('pre'); pre.className = 'logview';
    pre.textContent = r.lines.join('\n');
    v.appendChild(pre);
  } catch (e) { v.innerHTML = '<p class="hint">加载失败：' + e.message + '</p>'; }
}

/* ---------- 启动 ---------- */
refreshStatus();
loadTab('vault');
setInterval(refreshStatus, 5000);
