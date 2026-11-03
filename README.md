# 屏幕扫描机器人

把"人肉刷 Discord 学知识"变成"顺手一键入库 + 本地可检索"。
采集端**零注入、零 API、零 token**——只用屏幕截图和本地 OCR，Discord 看到的就是你在正常阅读。

```
你正常刷 Discord
  │ 热键① 扫描当前屏幕   热键② 半自动滚动段扫（人速+随机抖动+稳定即拍）
  ▼
inbox\shots\*.png + inbox\text\*.md     ← 原始证据，OCR 全程本地
  ▼ process-inbox.ps1
  ├─ 相邻截图行重叠去重拼接
  ├─ 疑似代码/JSON → vault\_meta\手动复制清单.md（OCR 对代码不可靠，人工兜底）
  └─ （可选）视觉 LLM 二级结构化 → vault\_shots\<id>.llm.md
  ▼
vault\scans\scan-<批次>.md               ← 知识库（含截图索引）
  ▼
search.ps1 / ask.ps1                     ← 全文检索 / 关键词问答
```

## 快速开始（Web 控制台，推荐）

**桌面双击「屏幕扫描机器人」快捷方式**即可（已创建，指向 `bin\launch-console.vbs` 隐藏启动）。

```powershell
powershell -ExecutionPolicy Bypass -File bin\start-web.ps1
```

会启动本地服务（只绑 127.0.0.1，默认端口 8787，被占自动后移）并打开浏览器。
页面上可以：扫描屏幕 / 启停滚动扫描 / 处理 inbox / 启停守护进程 / 搜索 / 问一问 / 浏览知识库与截图 / 看日志。
停止：`powershell -File start-web.ps1 -Stop`。

## 快速开始（命令行）

```powershell
# 1. 启动热键守护进程（隐藏后台）
powershell -ExecutionPolicy Bypass -File bin\start-scanner.ps1

# 2. 聚焦 Discord 窗口，按 Ctrl+Alt+S 扫描当前屏幕
#    或按 Ctrl+Alt+W 做一段滚动扫描（人速滚动，随时 Ctrl+Alt+Q 中止）

# 3. 收工后入库
powershell -ExecutionPolicy Bypass -File bin\process-inbox.ps1

# 4. 检索
powershell -ExecutionPolicy Bypass -File bin\search.ps1 -Query 世界书
powershell -ExecutionPolicy Bypass -File bin\ask.ps1 -Question "预设 排版"

# 停止守护进程
powershell -ExecutionPolicy Bypass -File bin\start-scanner.ps1 -Stop
```

单发测试（不装守护进程）：

```powershell
powershell -File bin\capture-ocr.ps1                 # 截全屏 → OCR → inbox
powershell -File bin\capture-ocr.ps1 -Probe          # 检查 OCR 引擎
powershell -File bin\capture-ocr.ps1 -ImageFile x.png # 对已有图片 OCR
```

## 热键（config.psd1 可改）

| 热键 | 作用 |
|---|---|
| `Ctrl+Alt+R` | 框选采集区域：全屏变暗出现十字光标，拖出矩形松开即生效，ESC 取消 |
| `Ctrl+Alt+S` | 截当前采集区域 → OCR → inbox |
| `Ctrl+Alt+W` | 半自动滚动段扫：每步随机滚 2-4 格 + 随机停顿 0.25~0.75s（约 1/10 概率"读消息"停 1.5~3s，偶尔回滚一格再看），画面连续 3 次采样一致才拍照，滚到帖子底部自动停，单次上限 12 步 |
| `Ctrl+Alt+Q` | 中止滚动扫描 |

守护进程只是轮询按键状态（GetAsyncKeyState），**不劫持、不注入、不影响正常打字**。

## 详细使用流程（你找帖子，程序滚动）

### 一次性准备（30 秒）
1. 双击桌面「屏幕扫描机器人」→ 浏览器打开控制台。
2. 点「**框选区域**」→ 屏幕变暗出现十字光标 → 按住左键拖出**帖子阅读区**（盖住 Discord 消息栏即可，别把侧边栏/输入框框进去），松开生效，ESC 取消。
   - 选区保存在 `logs\region.json`，之后**所有截图（单拍和滚动扫）都只拍这块**；状态栏显示当前区域尺寸，点「清除选区」恢复全屏。
3. 点「启动守护进程」启用水银热键；不装守护进程也可以全程用页面按钮操作。

### 每次扫一篇帖子（约 10 秒人工 + 后面全自动）
1. 在 Discord 点开目标帖子，**把鼠标移到消息区上**（滚轮焦点所在的窗口）。
2. 点「滚动扫描」（或 `Ctrl+Alt+W`）→ 程序自动：随机滚 2-4 格 → 随机停 0.25~0.75s → 画面稳定才拍 → 循环；滚到帖子底部**自动停**（`Ctrl+Alt+Q` 或页面按钮随时中止）。
3. 点「处理 inbox」→ 行级去重拼接、疑似代码自动进手动复制清单。
4. 搜索框查任何关键词，点结果直达原文 + 截图。

### 为什么不会缺漏（可以重叠，不许缺漏）
- **几何保证**：一屏约 1600px 高，每步只滚 2-4 格（约 250-500px），相邻两张天然重叠 2/3 以上——盖不到中间的情况在物理上不存在。
- **程序校验兜底**：每拍一张立刻比对"新帧顶部 6 行"与上一帧：一旦零重叠（异常跳变，如手滑滚轮、窗口跳动）→ **自动回滚补拍**一帧（入库时带 ⚠ 提示供核对），下一步继续正常覆盖间隙。
- **重叠无害**：入库管线按行精确匹配自动去重拼接，重叠部分只保留一份。
- 到底判定是"新帧没有一行新内容"，不会提前收工漏掉尾页。

### 关于随机的幅度（担心"随机过大"恰好反了一半）
反爬检测抓的特征是**恒定节奏**，不是随机幅度。程序叠加四层变化：滚动格数随机（2-4 格）、步间停顿随机（0.25-0.75s）、约 1/10 步出现 1.5-3s 的"读消息"停顿、偶尔回滚一格再看一眼（净位移 0）。这些与手刷不可区分；反过来，**匀速滚动 + 固定间隔**才是真正的机器特征。默认值不需要调大调小；想更保守只动 config.psd1 的 Scroll 段，别动"每步不超过视口一半"这条底线。

## 安全纪律（为什么这样做不封号）

封号检测打的是：token 自动化、API 频率/指纹异常、客户端注入、异常在线时长。
本工具**不产生任何发往 Discord 的额外流量**——截图、OCR、落盘全在本机；
唯一的网络行为是 Discord 客户端响应你的滚动，和真人手刷一模一样。

剩下唯一的间接信号是"滚动节奏"，所以三条硬规矩：

1. **只在你在电脑前时用**，不要无人值守挂机跑滚动扫描；
2. 保持默认人速节奏，别把停顿改成毫秒级；
3. 限量：每天扫的量别超过你真会读的量。

批量补历史请走别的路线（公告频道关注 + 自有服务器 bot / 低频只读导出工具），不要用视觉方案硬扫整个服务器——它是安全上限最高、吞吐下限最低的方案。

## 配置（config.psd1）

- **Web**：`Port`（默认 8787，被占用自动 +1 重试 10 个）、`OpenBrowser`（启动后自动开浏览器）。
  服务端为 TcpListener 手写 HTTP 子集（本机环境裁掉了 HttpListener），只监听 127.0.0.1，
  带 Host 头校验、路径穿越防护与静态文件白名单——**不要手动暴露到局域网**。
- **Ocr.Mode**：`auto`（默认，Windows 内置 OCR 优先，失败回退 Umi-OCR）/ `windows` / `umi`。
  Umi-OCR 备用后端：启动 Umi-OCR 的 HTTP 服务即可（默认 `http://127.0.0.1:1224/api/ocr`）。
- **VisionLLM**：混合路线第二级。`Enabled = $true` + OpenAI 兼容 `BaseUrl` + `Model`，
  密钥放环境变量 `LB_SCAN_VISION_KEY`（**绝不落盘**）。
  `Trigger = complex` 时只对疑似代码/复杂截图调用，提示词要求逐字符转写并输出结构化 Markdown。
- **Scroll**：滚动节奏参数即安全边界，默认值就是"像人"的设置。

## 已知限制

- **OCR 精度**：Windows 内置 OCR 对小字号深底文字有错字（实测），结论是"可检索、可留证"，但引用原文前对照截图或走视觉 LLM 二级处理。真实 Discord 界面字号更大，效果会好于极端测试。
- **代码块/JSON 必须手动复制**：管线会把疑似截图列进 `vault\_meta\手动复制清单.md`，照着截图把原文 Ctrl+C 进收集箱即可——复制是正常行为，零风险。
- 卡 PNG 附件等文件类资源：手动另存，不进 OCR 管线。
- 截图是**全部显示器**（虚拟屏），扫描前把 Discord 聚焦。

## 故障排查

- `OCR_ENGINE: NULL` → 系统缺中文 OCR 语言包：设置 → 时间和语言 → 语言和区域 → 中文（简体）→ 语言选项 → 勾选文字识别；或改用 Umi-OCR 后端（`Ocr.Mode = 'umi'`）。
- 截图黑屏 → 一般发生在无桌面的会话里；守护进程请在你正常登录的桌面会话中启动。
- 脚本中文乱码 → 所有 `.ps1/.psd1` 必须带 UTF-8 BOM（PowerShell 5.1 的要求），已内置；若用其他编辑器改动后出现乱码，重新另存为"带 BOM 的 UTF-8"。

## 路线图

- [ ] RAG 问答：vault 向量化 + 本地 LLM，把 ask.ps1 从关键词升级成自然语言问答
- [ ] 每日 digest：把当天新增 scan 汇总成一页
- [ ] T1 官方管道：关注屏幕公告频道到自有服务器 + 自有 bot 自动归档（全官方功能）
- [ ] T0 批量：镜像 [屏幕新版宝宝教程](https://down-3ud.pages.dev/)（CC BY-NC-SA，个人学习合规）
- [ ] Obsidian vault 化：加 front-matter 分类标签（预设/世界书/写卡/讨论）

## 项目结构

| 路径 | 说明 |
|---|---|
| `bin\capture-ocr.ps1` | 截图 → 本地 OCR → inbox（DPI 感知、选区优先、喂图 2x 放大） |
| `bin\scan-daemon.ps1` | 热键守护进程（RegisterHotKey 消息循环）：框选、单拍、滚动段扫（缺漏校验/回滚补拍/节奏控制） |
| `bin\select-region.ps1` | 全屏半透明覆盖层框选采集区域 |
| `bin\process-inbox.ps1` | 去重拼接（锚点对齐）、代码兜底清单、批次幂等、入库 |
| `bin\web-server.ps1` | 本地 Web 控制台后端（TcpListener 手写 HTTP/1.1，Host/Origin 校验） |
| `bin\start-web.ps1` / `start-scanner.ps1` | Web 控制台 / 热键守护进程的启停脚本 |
| `bin\search.ps1` / `ask.ps1` | 全文检索 / 关键词问答 |
| `web\` | 控制台前端（vanilla HTML/JS/CSS 单页，无构建链） |
| `docs\技术路线概况.md` | 架构与关键算法的技术说明（供外部评审） |
| `tests\make-test-image.ps1` | 生成模拟界面截图用于验证 OCR 链路 |

运行时目录（`logs\` `inbox\` `vault\` `tests\output*\`）不入库——见 `.gitignore`。

## 许可证

MIT（见 [LICENSE](LICENSE)）。请遵守目标站点的使用条款；本项目仅做本地采集与个人知识整理。

