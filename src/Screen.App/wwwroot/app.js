"use strict";
const $ = (id) => document.getElementById(id);
const state = {
  run: null,
  detail: null,
  frame: null,
  tab: "document",
  jobs: [],
  status: null,
  dirty: false,
  searching: false,
  listKey: "",
  detailKey: "",
  capturing: false,
};
const labels = {
  pending: "等待识别",
  processing: "识别中",
  succeeded: "已完成",
  failed: "识别失败",
  open: "采集中",
  closed: "已结束",
};
let toastTimer;
function toast(message, error = false) {
  $("toast").textContent = message;
  $("toast").classList.toggle("error", error);
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(
    () => ($("toast").hidden = true),
    error ? 8000 : 4000,
  );
}
async function api(path, method = "GET", body) {
  const options = { method };
  if (body instanceof FormData) options.body = body;
  else if (body !== undefined) {
    options.body = JSON.stringify(body);
    options.headers = { "Content-Type": "application/json" };
  }
  const response = await fetch(path, options);
  const data = await response
    .json()
    .catch(() => ({ error: "服务器响应无法读取" }));
  if (!response.ok)
    throw new Error(data.error || `请求失败 (${response.status})`);
  return data;
}
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function date(value) {
  return new Date(value).toLocaleString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}
function busy(button, action) {
  return async (...args) => {
    button.disabled = true;
    try {
      await action(...args);
    } catch (error) {
      toast(error.message, true);
    } finally {
      button.disabled = false;
    }
  };
}
function openCreate() {
  $("collection-title").value =
    `阅读笔记 ${new Date().toLocaleDateString("zh-CN")}`;
  $("create-dialog").showModal();
  $("collection-title").select();
}
$("new-run").onclick = openCreate;
$("welcome-create").onclick = openCreate;
$("create-cancel").onclick = () => $("create-dialog").close();
$("create-form").onsubmit = async (e) => {
  e.preventDefault();
  const button = e.submitter;
  button.disabled = true;
  try {
    const run = await api("/api/runs", "POST", {
      title: $("collection-title").value.trim(),
    });
    $("create-dialog").close();
    await selectRun(run.id);
    await refresh();
    toast("批次已创建，可以导入图片了。");
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
};
$("menu").onclick = () => $("sidebar").classList.toggle("open");
document.addEventListener("click", (e) => {
  if (
    window.innerWidth <= 760 &&
    !$("sidebar").contains(e.target) &&
    !$("menu").contains(e.target)
  )
    $("sidebar").classList.remove("open");
});
async function selectRun(id, frame = null) {
  if (state.dirty && !confirm("当前校对文字尚未保存，仍然切换吗？")) return;
  state.run = id;
  state.frame = frame;
  state.dirty = false;
  state.searching = false;
  state.detailKey = "";
  $("search-results").hidden = true;
  $("welcome").hidden = true;
  $("run-workspace").hidden = false;
  $("sidebar").classList.remove("open");
  if (frame) state.tab = "evidence";
  await loadDetail();
  renderTabs();
  await loadRuns();
}
async function loadRuns() {
  const runs = await api("/api/runs");
  const key = JSON.stringify([runs, state.run]);
  if (key === state.listKey) return;
  state.listKey = key;
  $("runs").replaceChildren();
  $("run-count").textContent = runs.length;
  if (!runs.length)
    $("runs").append(
      element(
        "p",
        "sidebar-empty",
        "还没有采集记录。\n从你正在阅读的内容开始。",
      ),
    );
  for (const run of runs) {
    const b = element(
      "button",
      "run-item" + (run.id === state.run ? " active" : ""),
    );
    b.append(
      element("strong", "", run.title),
      element(
        "small",
        "",
        `${date(run.createdAt)} · ${run.frameCount} 张 · ${labels[run.state]}`,
      ),
    );
    b.onclick = () => selectRun(run.id).catch((e) => toast(e.message, true));
    $("runs").append(b);
  }
}
async function loadDetail() {
  if (!state.run) return;
  const detail = await api(`/api/runs/${state.run}`);
  state.detail = detail;
  const key = JSON.stringify(detail);
  if (key === state.detailKey || state.dirty) return;
  state.detailKey = key;
  renderDetail();
}
function renderDetail() {
  const { run, frames, document: doc } = state.detail;
  $("run-title").textContent = run.title;
  $("breadcrumb-title").textContent = run.title;
  $("run-meta").textContent =
    `${date(run.createdAt)} 创建 · ${frames.length} 张截图 · ${labels[run.state]}`;
  $("frame-count").textContent = frames.length;
  $("frame-count").ariaLabel = `${frames.length} 张原始截图`;
  $("merge-info").textContent =
    `${frames.length} 张原图 · 已去除 ${doc.removedLines} 行连续重复`;
  $("document-text").textContent =
    doc.text ||
    "识别结果会显示在这里。你也可以到「原始证据」中对照图片校对文字。";
  $("warnings").replaceChildren();
  $("warnings").hidden = !doc.warnings.length;
  if (doc.warnings.length) {
    $("warnings").append(element("strong", "", "需要核对的地方"));
    const list = element("ul");
    for (const warning of doc.warnings) list.append(element("li", "", warning));
    $("warnings").append(list);
  }
  $("close-run").disabled = run.state === "closed";
  $("export").disabled = !frames.length;
  const closed = run.state === "closed";
  for (const id of ["import", "scroll"]) $(id).disabled = closed;
  $("capture").disabled = closed || state.capturing;
  renderFrames();
  renderTabs();
}
function renderTabs() {
  for (const b of document.querySelectorAll("[data-tab]")) {
    b.classList.toggle("active", b.dataset.tab === state.tab);
    b.setAttribute("aria-selected", String(b.dataset.tab === state.tab));
  }
  const hasFrames = !!state.detail?.frames.length;
  $("drop-zone").hidden =
    hasFrames || state.searching || state.detail?.run.state === "closed";
  $("document-panel").hidden =
    !hasFrames || state.tab !== "document" || state.searching;
  $("evidence-panel").hidden =
    !hasFrames || state.tab !== "evidence" || state.searching;
  $("jobs-panel").hidden = state.tab !== "jobs" || state.searching;
  if (state.tab === "jobs") $("drop-zone").hidden = true;
}
for (const b of document.querySelectorAll("[data-tab]"))
  b.onclick = () => {
    if (
      state.dirty &&
      b.dataset.tab !== "evidence" &&
      !confirm("校对文字尚未保存，仍然离开吗？")
    )
      return;
    state.tab = b.dataset.tab;
    renderTabs();
  };
function renderFrames() {
  const frames = state.detail.frames;
  $("frames").replaceChildren();
  if (!frames.length) return;
  if (!frames.some((f) => f.id === state.frame)) state.frame = frames[0].id;
  for (const f of frames) {
    const b = element(
      "button",
      "frame-thumb" + (f.id === state.frame ? " active" : ""),
    );
    const img = element("img");
    img.src = `/api/images/${f.id}`;
    img.alt = `第 ${f.sequence} 帧`;
    img.loading = "lazy";
    b.append(
      img,
      element(
        "span",
        "",
        `${String(f.sequence).padStart(2, "0")} · ${labels[f.ocrState]}`,
      ),
    );
    b.onclick = () => {
      if (state.dirty && !confirm("校对文字尚未保存，仍然切换吗？")) return;
      state.dirty = false;
      state.frame = f.id;
      renderFrames();
    };
    $("frames").append(b);
  }
  renderEditor();
}
function renderEditor() {
  const f = state.detail.frames.find((f) => f.id === state.frame);
  if (!f) return;
  $("frame-image").src = `/api/images/${f.id}`;
  $("image-link").href = `/api/images/${f.id}`;
  $("frame-meta").textContent =
    `第 ${f.sequence} 帧 · ${f.width} × ${f.height} · ${date(f.capturedAt)}\n点击原图查看完整尺寸`;
  $("editor-title").textContent = `第 ${f.sequence} 帧 · 识别原文`;
  $("editor-state").textContent = f.ocrEngine || labels[f.ocrState];
  $("frame-text").value = f.ocrText;
  const running = ["pending", "processing"].includes(f.ocrState);
  $("frame-text").disabled = running;
  $("save-text").disabled = running;
  $("retry").disabled = running;
  $("save-text").textContent = "保存校对";
  $("frame-error").hidden = !f.error;
  $("frame-error").textContent = f.error || "";
  $("revision-details").open = false;
  $("revisions").replaceChildren();
}
$("frame-text").oninput = () => {
  state.dirty = true;
  $("save-text").textContent = "保存校对 · 未保存";
};
$("save-text").onclick = busy($("save-text"), async () => {
  await api(`/api/frames/${state.frame}/text`, "PATCH", {
    text: $("frame-text").value,
  });
  state.dirty = false;
  state.detailKey = "";
  await loadDetail();
  toast("校对已保存，原识别记录仍然保留。");
});
$("retry").onclick = busy($("retry"), async () => {
  if (state.dirty && !confirm("尚有未保存的校对，仍然重新识别吗？")) return;
  await api(`/api/frames/${state.frame}/retry`, "POST");
  state.dirty = false;
  state.detailKey = "";
  await refresh();
  toast("已加入后台识别队列。");
});
$("revision-details").ontoggle = async () => {
  if (!$("revision-details").open || !state.frame) return;
  try {
    const revisions = await api(`/api/frames/${state.frame}/revisions`);
    $("revisions").replaceChildren();
    for (const r of revisions) {
      const article = element("article");
      article.append(
        element("span", "", `${date(r.createdAt)} · ${r.engine}`),
        element("pre", "", r.text),
      );
      $("revisions").append(article);
    }
  } catch (error) {
    toast(error.message, true);
  }
};
function pickImages() {
  $("file-input").click();
}
for (const id of ["import", "drop-import"]) $(id).onclick = pickImages;
$("file-input").onchange = async () => {
  await uploadFiles([...$("file-input").files]);
  $("file-input").value = "";
};
async function uploadFiles(files) {
  if (!state.run) return;
  const target = state.run;
  let count = 0;
  $("import").disabled = true;
  try {
    for (const file of files) {
      const form = new FormData();
      form.append("image", file);
      await api(`/api/runs/${target}/frames`, "POST", form);
      count++;
      toast(`已保存 ${count}/${files.length} 张原图，后台识别中…`);
    }
    state.detailKey = "";
    await refresh();
  } catch (error) {
    toast(`已保存 ${count} 张。${error.message}`, true);
    await refresh();
  } finally {
    $("import").disabled = state.detail?.run.state === "closed";
  }
}
for (const event of ["dragenter", "dragover"])
  $("drop-zone").addEventListener(event, (e) => {
    e.preventDefault();
    $("drop-zone").classList.add("dragging");
  });
for (const event of ["dragleave", "drop"])
  $("drop-zone").addEventListener(event, (e) => {
    e.preventDefault();
    $("drop-zone").classList.remove("dragging");
    if (event === "drop") uploadFiles([...e.dataTransfer.files]);
  });
$("capture").onclick = async () => {
  if (state.capturing) return;
  const button = $("capture");
  const delay = state.status.captureFocusDelayMs;
  const deadline = performance.now() + delay;
  const countdown = () => {
    const seconds = Math.ceil((deadline - performance.now()) / 1000);
    button.textContent = seconds > 0 ? `${seconds} 秒后截图` : "正在截图…";
  };
  state.capturing = true;
  button.disabled = true;
  if (delay > 0) toast("请切换到阅读窗口，将鼠标放在采集区域内。");
  countdown();
  const timer = setInterval(countdown, 100);
  try {
    await api("/api/capture", "POST", { runId: state.run, region: null });
    await refresh();
    toast("原图已保存，正在后台识别。");
  } catch (error) {
    toast(error.message, true);
  } finally {
    clearInterval(timer);
    state.capturing = false;
    button.textContent = "截取屏幕";
    button.disabled = state.detail?.run.state === "closed";
  }
};
$("scroll").onclick = busy($("scroll"), async () => {
  await api("/api/scroll/start", "POST", {
    runId: state.run,
    region: null,
    steps: 12,
    delayMs: 700,
    wheelNotches: 1,
  });
  await refresh();
  toast("4 秒后开始。请切换到阅读窗口，将鼠标放在采集区域内。");
});
$("stop").onclick = busy($("stop"), async () => {
  await api("/api/scroll/stop", "POST");
  await refresh();
});
$("region").onclick = busy($("region"), async () => {
  const r = await api("/api/region/pick", "POST");
  if (!r.cancelled) toast("采集区域已保存。");
  await refresh();
});
$("clear-region").onclick = async () => {
  try {
    await api("/api/region", "PUT", { region: null });
    await refresh();
  } catch (error) {
    toast(error.message, true);
  }
};
$("close-run").onclick = busy($("close-run"), async () => {
  if (
    !confirm("结束这个批次？已保存的内容仍可校对和导出，后续采集请创建新批次。")
  )
    return;
  await api(`/api/runs/${state.run}/close`, "POST");
  await refresh();
});
$("export").onclick = () => {
  if (state.run) window.location.href = `/api/runs/${state.run}/export`;
};
function renderJobs() {
  const frames = new Map((state.detail?.frames || []).map((f) => [f.id, f]));
  const jobs = state.jobs.filter((j) => frames.has(j.frameId));
  $("job-count").textContent = jobs.filter((j) =>
    ["pending", "processing"].includes(j.state),
  ).length;
  $("jobs").replaceChildren();
  if (!jobs.length)
    $("jobs").append(element("p", "sidebar-empty", "这个批次还没有识别任务。"));
  for (const j of jobs) {
    const row = element("div", "job " + j.state);
    row.append(
      element(
        "span",
        "job-icon",
        j.state === "succeeded" ? "✓" : j.state === "failed" ? "!" : "·",
      ),
    );
    const text = element("div", "job-description");
    text.append(
      element("strong", "", `第 ${frames.get(j.frameId).sequence} 帧`),
      element(
        "p",
        "",
        j.error || `${date(j.updatedAt)} · 尝试 ${j.attempts} 次`,
      ),
    );
    row.append(text, element("span", "job-state", labels[j.state]));
    if (j.state === "failed") {
      const retry = element("button", "button", "重试");
      retry.onclick = busy(retry, async () => {
        await api(`/api/frames/${j.frameId}/retry`, "POST");
        await refresh();
      });
      row.append(retry);
    }
    $("jobs").append(row);
  }
}
async function refresh() {
  try {
    const [status, jobs] = await Promise.all([
      api("/api/status"),
      api("/api/jobs"),
    ]);
    state.status = status;
    state.jobs = jobs;
    $("connection").textContent = "已连接 · 内容保存在本机";
    $("stat-frames").textContent = status.counts.frames;
    $("stat-recognized").textContent = status.counts.recognized;
    $("stat-pending").textContent = status.counts.pending;
    $("capture-mode").textContent = status.canCapture
      ? "桌面采集模式"
      : "图片导入模式";
    $("capture-mode").title = status.captureNote;
    $("ocr-label").textContent = status.ocrEngine;
    for (const b of document.querySelectorAll(".desktop"))
      b.hidden = !status.canCapture;
    const active = ["running", "waiting", "cancelling"].includes(
      status.scroll.state,
    );
    $("stop").hidden = !active;
    $("scroll").hidden = !status.canCapture || active;
    $("capture-hint").hidden =
      !status.scroll.note || !state.run || status.scroll.runId !== state.run;
    $("capture-hint").textContent = status.scroll.note || "";
    $("region-line").hidden = !status.region;
    $("region-description").textContent = status.region
      ? `采集区域 ${status.region.width} × ${status.region.height} · (${status.region.x}, ${status.region.y})`
      : "";
    await Promise.all([loadRuns(), loadDetail()]);
    renderJobs();
  } catch (error) {
    $("connection").textContent = "连接中断 · 正在重试";
    console.error(error);
  }
}
$("search-form").onsubmit = async (e) => {
  e.preventDefault();
  const query = $("search").value.trim();
  if (!query) return;
  try {
    const hits = await api(`/api/search?q=${encodeURIComponent(query)}`);
    state.searching = true;
    $("welcome").hidden = true;
    $("run-workspace").hidden = true;
    $("search-results").hidden = false;
    $("search-heading").textContent = `“${query}” · ${hits.length} 条结果`;
    $("search-hits").replaceChildren();
    if (!hits.length)
      $("search-hits").append(
        element("p", "sidebar-empty", "没有找到匹配内容，试试更短的关键词。"),
      );
    for (const hit of hits) {
      const b = element("button", "search-hit");
      b.append(
        element("strong", "", hit.title),
        element("small", "", `第 ${hit.sequence} 帧`),
        element("p", "", hit.text),
      );
      b.onclick = () =>
        selectRun(hit.runId, hit.frameId).catch((error) =>
          toast(error.message, true),
        );
      $("search-hits").append(b);
    }
  } catch (error) {
    toast(error.message, true);
  }
};
$("search-close").onclick = () => {
  state.searching = false;
  $("search-results").hidden = true;
  $("run-workspace").hidden = !state.run;
  $("welcome").hidden = !!state.run;
  renderTabs();
};
document.addEventListener("keydown", (e) => {
  if (
    e.key === "/" &&
    !["INPUT", "TEXTAREA"].includes(document.activeElement.tagName)
  ) {
    e.preventDefault();
    $("search").focus();
  }
});
async function initialize() {
  await refresh();
  const runs = await api("/api/runs");
  if (runs.length) await selectRun(runs[0].id);
  setInterval(refresh, 1600);
}
initialize().catch((error) => {
  toast(error.message, true);
  setInterval(refresh, 3000);
});
