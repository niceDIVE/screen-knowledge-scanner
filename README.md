# 屏幕 · 个人知识采集工作台

截图留证 → 本地 OCR → 校对与整理 → 中文检索 → Markdown 知识库。

V2 使用 **C# / .NET 10、ASP.NET Core、SQLite FTS5**，配套原生 HTML/CSS/JavaScript 控制台。采集和识别在后台执行，原图先保存，OCR 或去重可以重新运行。默认不调用 Discord API，不读取账号 token，不向客户端注入代码。

## 已实现

- 图片导入：PNG/JPEG，原图按 SHA-256 保存，重复图片共享文件但保留每次观察记录。
- Windows 桌面采集：屏幕截图、区域框选、全局热键、有首帧记录的有限滚动采集。
- 后台 OCR：Windows 系统 OCR、Tesseract 或 Umi-OCR；任务持久化、失败可见、可重试，进程重启恢复中断任务。
- 校对：原图与文字并排展示，每次识别和人工校对保留历史。
- 整理：仅删除能够确认的连续文字重叠；不确定的衔接保留全文并提示核对。
- 检索：中文 bigram、英文词语、单字查询，结果定位到原始帧。
- 导出：ZIP 内含 Markdown、原图与带修订历史的 JSON 清单，可直接解压到 Obsidian。
- 桌面和手机宽度的轻量控制台，无 npm 构建要求。

## 快速运行

开发需要 .NET 10 SDK。项目通过 `global.json` 允许当前 .NET 10 feature band；数据库依赖已锁定。

```bash
dotnet restore Screen.sln --locked-mode
bash scripts/run.sh
```

启动脚本将数据保存在仓库根目录 `data/`。服务启动后，在本机浏览器打开 `http://127.0.0.1:8788`。通用构建支持图片导入、OCR、校对、检索与导出。Linux/macOS 默认使用 Tesseract，需预先安装；中文识别还需要简体中文模型。例如：

```bash
# Debian / Ubuntu
sudo apt-get install tesseract-ocr tesseract-ocr-chi-sim
bash scripts/run.sh --Scanner:TesseractLanguages=chi_sim+eng
```

也可以直接 `dotnet run --project src/Screen.App`。未指定数据目录时，数据保存在应用输出目录下的 `data/`。通过 `Scanner__DataDirectory`、`Scanner__OcrEngine` 等环境变量可以覆盖设置，也可以修改 `src/Screen.App/appsettings.json`。相对数据路径以应用所在目录为基准解析。

## Windows 桌面版本

在 Windows 10 2004 或更新版本、Windows 11 的正常桌面会话运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-windows.ps1
```

该脚本构建 `net10.0-windows10.0.19041.0` 目标，启动后自动打开控制台。默认使用 Windows OCR，中文需要相应系统语言的文字识别组件。

| 操作 | 热键 |
|---|---|
| 框选采集区域 | Ctrl+Alt+R |
| 立即保存当前画面 | Ctrl+Alt+S |
| 开始滚动采集 | Ctrl+Alt+W |
| 停止滚动采集 | Ctrl+Alt+Q |

页面截图按钮默认倒计时 3 秒，滚动按钮等待 4 秒。请在倒计时结束前切换到阅读窗口，并把鼠标放进前台阅读窗口和采集区域。单帧截图以倒计时结束时的前台窗口为目标，截图前后校验窗口和鼠标位置。滚动前先保存首帧；画面重叠不确定、窗口改变或鼠标离开区域时停止并保留已保存的证据。默认最多 12 步或 3 分钟。

生成无需另装 .NET 的 Windows x64 发布包：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\publish-windows.ps1
```

产物为 `artifacts/screen-win-x64.zip`，解压后双击 `start.cmd`。新安装的数据默认保存在 `%LOCALAPPDATA%\Screen\data`。如果程序同目录已存在旧版 `data\knowledge.db`，继续使用该目录。旧版换目录升级时，关闭程序后将整个旧 `data/` 复制到新程序目录，或通过 `Scanner__DataDirectory` 指向旧目录。也可以在其他操作系统交叉发布：

```bash
dotnet publish src/Screen.App -c Release -r win-x64 --self-contained true \
  -p:WindowsDesktop=true -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true -o artifacts/win-x64
```

## 验证

```bash
dotnet test Screen.sln
```

测试覆盖真实 SQLite、并发导入、任务中断恢复、失败重试、校对和索引、重复句不丢新行、位移方向、首帧顺序，以及完整 API 导入—识别—检索—导出流程。测试中 OCR 与桌面驱动使用明确替身。

Windows CI 还会构建桌面目标运行这套测试，并验证实际 Windows 截图驱动的 GDI PNG 解码和灰度缩放。若 Windows 上 testhost 在 `SetParentProcessExitCallback` / `GetProcessHandle` 报 `Win32Exception(5)`，请在普通桌面会话或 CI 运行测试，确认测试进程能够读取父进程句柄。

验证实际 OCR（会创建一个标为功能验证的批次）：

```bash
python3 tools/smoke.py --image /path/to/chinese-screenshot.png --expected 世界书
```

可选浏览器验收需要 Playwright 和 Chromium，见 `tools/browser-smoke.cjs`。

本次云环境已验证 Linux 中文 Tesseract 的真实识别、HTTP 流程、浏览器创建/导入/校对/检索/导出和移动布局；Windows 桌面目标已交叉编译并生成自包含发布包。**Windows 热键、实际截图、WinRT OCR、多屏与 DPI 行为仍需 Windows 实机验收。**

## 结构

```text
src/Screen.App/
  Program.cs             本地 HTTP 接口与启动
  KnowledgeStore.cs      SQLite、原图、任务与修订记录
  Ocr.cs                 OCR 引擎与持久化任务消费者
  Documents.cs           保守连续去重和 Markdown 导出
  MotionEstimator.cs     画面垂直位移估计
  ScrollCoordinator.cs   首帧、滚动、停止与采集说明
  Windows/               GDI 截图、WinRT OCR、框选、热键
  wwwroot/               无构建链控制台
tests/Screen.App.Tests/   单元与 API 回归
scripts/                 启动与发布
tools/                   真实 OCR 和浏览器验收
```

开发脚本的数据目录是仓库根目录的 `data/`。V1 按整理文本哈希跳过重复入库，V2 保留每次采集观察，并按原图哈希共享图片文件。连续阅读同一主题时继续使用同一批次，换主题或结束批次后再新建。V2 依赖 OCR 与人工校对处理复杂排版，视觉 LLM 暂未纳入。详见使用说明中的取舍。

详见[使用说明](docs/使用说明.md)、[后端架构](docs/后端架构.md)。旧版 `bin/` 与 `web/` 保留，历史使用方式见[旧版 PowerShell 使用说明](docs/旧版PowerShell使用说明.md)。MIT 许可证。
