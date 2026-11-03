@{
    # ============ 路径（相对项目根目录） ============
    InboxShots = 'inbox\shots'      # 截图落盘
    InboxText  = 'inbox\text'       # OCR 原始文本落盘
    Vault      = 'vault'            # 知识库（Markdown）

    # ============ OCR ============
    Ocr = @{
        Mode    = 'auto'                              # auto | windows | umi
        UmiUrl  = 'http://127.0.0.1:1224/api/ocr'     # Umi-OCR 的 HTTP 接口（备用后端）
        PreferLanguages = @('zh-Hans-CN', 'en-US')    # Windows OCR 优先语言
    }

    # ============ 热键（守护进程轮询，不劫持按键） ============
    Hotkeys = @{
        ScanScreen   = 'Ctrl+Alt+S'    # 扫描当前屏幕
        ScanScroll   = 'Ctrl+Alt+W'    # 半自动滚动段扫（人速滚动+稳定即拍）
        StopScroll   = 'Ctrl+Alt+Q'    # 中止滚动扫描
        SelectRegion = 'Ctrl+Alt+R'    # 框选采集区域
    }

    # ============ 滚动扫描节奏（阅读速度采集；参数即安全边界） ============
    # 不缺漏的几何保证：一屏约 1600px，每步只滚 2-4 格（约 250-500px），相邻两张天然重叠 2/3 以上
    Scroll = @{
        NotchRange          = @(2, 4)        # 每步滚动格数在此区间随机
        NotchMs             = @(250, 750)    # 每步之后停顿区间（对数正态取样，右偏似阅读）
        ExtraReadChance     = 10             # 1/N 概率额外停留（模拟读消息）
        ExtraReadMs         = @(1500, 3000)  # 额外停留时长区间
        ScreenCount         = 12             # 单次滚动扫描最多滚多少步
        MaxDurationSec      = 180            # 单次扫描总时长上限
        DiffThresholdPct    = 0.5            # 稳定判定：像素变化率 < 0.5% 视为稳定
        MaxWaitMs           = 4000           # 稳定等待上限，超时照拍并标记 unstable
        GapMaxRetries       = 3              # 缺漏回滚补拍的最大次数，超限停止并告警
        StabilityIntervalMs = 500            # 稳定性采样间隔
    }

    # ============ 视觉 LLM（混合路线第二级，默认关） ============
    VisionLLM = @{
        Enabled  = $false
        BaseUrl  = ''                        # OpenAI 兼容地址，例 https://api.xxx.com/v1
        ApiKeyEnv = 'LB_SCAN_VISION_KEY'     # 密钥从环境变量读，绝不落盘
        Model    = ''                        # 例 gpt-4o-mini / glm-4v-flash 等
        Trigger  = 'complex'                 # complex=只处理代码块/复杂截图 | always | never
    }

    # ============ Web 控制台 ============
    Web = @{
        Port        = 8788       # 固定端口（8787 常被其他程序占用；被占时仍会自动向后尝试 10 个）
        OpenBrowser = $true      # start-web.ps1 启动后自动打开默认浏览器
    }
}
