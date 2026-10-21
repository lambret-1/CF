iOS 超分 App 开发文档（自签名自用版 · 含现成模型链接与 UI 设计细化）

适用范围：自用 iOS 超分 App，内置轻量模型 + 按需下载大模型。
安装按你现有自签名流程处理，本文不涉及签名、续签、审核。

---

1. 项目目标

· 照片超分：选图 → 选模型 → 推理 → 对比预览 → 保存。
· 实时预览（可选）：相机/视频帧超分。
· 模型管理：轻量模型开箱即用；大模型按需下载、编译、加载、删除。

核心原则：模型与 App 分离；UI 以“功能直达、状态透明、差异显性”为准。

---

2. 模型选型（已核实现成 Core ML 链接）

2.1 选型总表

角色 模型 体积 许可证 分发 计算单元
内置实时 PiperSR 2x 928 KB CC-BY-4.0 内置 .cpuAndNeuralEngine
内置轻量照片 Real-ESRGAN x4v3 2.29 MB BSD-3-Clause 内置 .all
按需通用 Real-ESRGAN x4 59 MB BSD-3-Clause 按需 .all
按需高画质 Real-ESRGAN x4plus / UltraSharp ~31 MB BSD-3-Clause 按需 .all
按需扩散（可选） SinSR（3 件套） ~517 MB CC BY-NC-SA 4.0（非商用） 按需 Encoder/Decoder .all，Denoiser .cpuOnly

关键调整：

· ESPCN 无现成 Core ML 包，用 PiperSR 替代（体积相当、ANE 原生、性能更优）。
· EDSR 无现成 Core ML 包（只有 ExecuTorch .pte），用 Real-ESRGAN x4v3（2.29 MB） 替代作为内置轻量基线。
· AdcSR 不是 Core ML，是 Core AI（.aimodel，面向 iOS 27+），当前 Core ML 无法加载，已移除。扩散效果用 SinSR。

2.2 现成链接

PiperSR 2x（内置实时）
仓库：https://huggingface.co/ModelPiper/PiperSR-2x/tree/main
文件：PiperSR_2x.mlpackage、PiperSR_2x_256.mlpackage、PiperSR_2x_video_720p.mlpackage
参数：928 KB，Set5 PSNR 37.54 dB，Apple Silicon 上 360p→720p 约 44 FPS，算子验证过 ANE 原生执行。

Real-ESRGAN x4（按需通用，59 MB）
独立仓库：https://huggingface.co/mlboydaisuke/Real-ESRGAN-x4-CoreML/tree/main
coreml-zoo zip 直链：
https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/main/realesrgan/RealESRGAN_x4.mlpackage.zip
参数：59 MB，最低 iOS 17.0，峰值内存约 500 MB，512×512 → 2048×2048。验证计算单元 .all，不要改 .cpuOnly / .cpuAndGPU（FP16 attention 溢出）。

Real-ESRGAN 变体（按需）
仓库：https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus

文件 体积 直链后缀
RealESRGAN-x4v3.mlpackage.zip 2.29 MB /resolve/main/RealESRGAN-x4v3.mlpackage.zip
RealESRGAN-x4plus.mlpackage.zip 31 MB /resolve/main/RealESRGAN-x4plus.mlpackage.zip
RealESRGAN-UltraSharp.mlpackage.zip 30.9 MB /resolve/main/RealESRGAN-UltraSharp.mlpackage.zip

SinSR（按需扩散，非商用）
仓库：https://huggingface.co/mlboydaisuke/SinSR-CoreML/tree/main
文件：SinSR_Encoder.mlpackage.zip（39 MB，.all）、SinSR_Denoiser.mlpackage.zip（412 MB，.cpuOnly）、SinSR_Decoder.mlpackage.zip（66 MB，.all）。总包约 517 MB。许可证 CC BY-NC-SA 4.0，仅限非商用自用。

2.3 ⚠️ Hugging Face .mlpackage 目录下载

.mlpackage 是目录，不是单文件。HF 上以目录形式存储时，resolve/main/xxx.mlpackage 不一定返回可下载单文件。

推荐做法（按优先度）：

1. 自打包成 zip 托管：zip -r PiperSR_2x.mlpackage.zip PiperSR_2x.mlpackage，上传 GitHub Releases / Cloudflare R2 / 静态服务，manifest 指向该 zip。最稳。
2. 若仓库已有 .zip（如 coreml-zoo）：直接用 resolve/main/xxx.mlpackage.zip。
3. App 内递归下载 HF 目录：调 https://huggingface.co/api/models/{repo}/tree/main/{path} 拿列表逐文件下载重组。复杂，仅作兜底。

---

3. 工程结构

```text
SuperResApp/
├── App/
│   └── SuperResApp.swift
├── Models/
│   ├── Builtin/               # PiperSR_2x.mlpackage, RealESRGAN-x4v3.mlpackage
│   └── Manifest/
│       └── ModelManifest.swift
├── Services/
│   ├── ModelDownloader.swift
│   ├── ModelCompiler.swift
│   ├── ModelStore.swift
│   └── SuperResolver.swift
├── Features/
│   ├── PhotoSuperRes/
│   ├── LivePreview/
│   └── ModelManager/
├── UI/
│   ├── Components/
│   ├── Theme/
│   └── Screens/
└── Resources/
    └── model_manifest.json
```

---

4. 模型管理

4.1 Manifest（真实可用版本）

```json
[
  {
    "id": "piper-sr-2x",
    "name": "PiperSR 2x (ANE)",
    "size": 950000,
    "url": "https://your-host/models/PiperSR_2x.mlpackage.zip",
    "sha256": "<自打包后计算>",
    "builtin": true,
    "wifiOnly": false,
    "computeUnits": "cpuAndNeuralEngine",
    "license": "CC-BY-4.0",
    "source": "https://huggingface.co/ModelPiper/PiperSR-2x"
  },
  {
    "id": "realesrgan-x4v3",
    "name": "Real-ESRGAN x4v3 (轻量)",
    "size": 2400000,
    "url": "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus/resolve/main/RealESRGAN-x4v3.mlpackage.zip",
    "sha256": "<下载后计算>",
    "builtin": true,
    "wifiOnly": false,
    "computeUnits": "all",
    "license": "BSD-3-Clause",
    "source": "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus"
  },
  {
    "id": "realesrgan-x4",
    "name": "Real-ESRGAN x4",
    "size": 61865984,
    "url": "https://huggingface.co/mlboydaisuke/coreml-zoo/resolve/main/realesrgan/RealESRGAN_x4.mlpackage.zip",
    "sha256": "<下载后计算>",
    "builtin": false,
    "wifiOnly": false,
    "computeUnits": "all",
    "license": "BSD-3-Clause",
    "source": "https://huggingface.co/mlboydaisuke/Real-ESRGAN-x4-CoreML"
  },
  {
    "id": "realesrgan-x4plus",
    "name": "Real-ESRGAN x4plus",
    "size": 31000000,
    "url": "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus/resolve/main/RealESRGAN-x4plus.mlpackage.zip",
    "sha256": "<下载后计算>",
    "builtin": false,
    "wifiOnly": false,
    "computeUnits": "all",
    "license": "BSD-3-Clause",
    "source": "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus"
  },
  {
    "id": "realesrgan-ultrasharp",
    "name": "Real-ESRGAN UltraSharp",
    "size": 30900000,
    "url": "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus/resolve/main/RealESRGAN-UltraSharp.mlpackage.zip",
    "sha256": "<下载后计算>",
    "builtin": false,
    "wifiOnly": false,
    "computeUnits": "all",
    "license": "BSD-3-Clause",
    "source": "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus"
  },
  {
    "id": "sinsr",
    "name": "SinSR (扩散，非商用)",
    "size": 542000000,
    "url": "https://your-host/models/SinSR-bundle.zip",
    "sha256": "<自打包后计算>",
    "builtin": false,
    "wifiOnly": true,
    "computeUnits": "mixed",
    "license": "CC BY-NC-SA 4.0",
    "source": "https://huggingface.co/mlboydaisuke/SinSR-CoreML",
    "note": "Encoder/Decoder 用 .all，Denoiser 必须 .cpuOnly"
  }
]
```

状态以 Application Support/Models/{id}.mlmodelc 是否存在为准。

4.2 下载

```swift
let config = URLSessionConfiguration.background(
    withIdentifier: "com.example.superres.model-download"
)
let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
```

要求：服务端支持 Range、断点续传；wifiOnly 用 NWPathMonitor 检查 isExpensive；下载完校验 SHA256 → 解压 → 编译；进度用 didWriteData 更新 UI。

并发策略：同一时间只允许 1 个模型下载，其余排队。下载队列持久化到本地，App 重启后恢复排队状态。大模型（SinSR）下载时，小的排队项等待，避免带宽争抢。

4.3 解压 + 编译 + 持久化

```swift
try FileManager.default.unzipItem(at: zipURL, to: tempDir)
let packageURL = tempDir.appendingPathComponent("\(id).mlpackage")
let compiledURL = try MLModel.compileModel(at: packageURL)
let dest = appSupport
    .appendingPathComponent("Models")
    .appendingPathComponent("\(id).mlmodelc")
try FileManager.default.moveItem(at: compiledURL, to: dest)
try? FileManager.default.removeItem(at: tempDir)
```

后续启动直接 MLModel(contentsOf: dest)。编译阶段单独占用一个后台队列，进度以“编译中”状态展示，不与下载进度混淆。

4.4 删除

删除 .mlmodelc，ModelStore.evict(id)，更新清单状态。删除时同步清理该模型的临时解压残留。

---

5. Core ML 推理

5.1 计算单元

```swift
let config = MLModelConfiguration()
config.computeUnits = model.computeUnits == "cpuAndNeuralEngine"
    ? .cpuAndNeuralEngine
    : .all
```

· PiperSR：.cpuAndNeuralEngine。
· Real-ESRGAN 全系：.all，不要改。
· SinSR：Encoder/Decoder .all，Denoiser 必须 .cpuOnly。
· 怀疑回退时用 Xcode Core ML 性能报告确认。

5.2 模型缓存

```swift
actor ModelStore {
    private var loaded: [String: MLModel] = [:]

    func model(for id: String, url: URL, units: MLComputeUnits) throws -> MLModel {
        if let m = loaded[id] { return m }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        let m = try MLModel(contentsOf: url, configuration: cfg)
        loaded[id] = m
        return m
    }

    func evict(_ id: String) { loaded.removeValue(forKey: id) }
}
```

内存警告或切换大模型前主动 evict。

5.3 大图分块

Real-ESRGAN 全分辨率会爆内存，必须 tile：输入切 256×256 或 512×512，overlap 16px；逐块推理，输出按位置拼接，重叠区羽化融合；每 tile 处理完释放缓冲区。

SinSR：Denoiser 在 CPU 上跑，单块慢，建议 tile 降到 128×128，UI 给出“预计耗时”提示。

5.4 实时预览帧预算

AVCaptureVideoDataOutput 直接取 CVPixelBuffer；目标 30fps，单帧模型耗时 10–15ms；超预算时跳帧超分 + 插帧显示，不降分辨率；实时场景只用 PiperSR。

---

6. UI 设计

6.1 设计原则与全局规范

五条原则：

1. 状态透明：下载、编译、推理、分块进度全部可见，不出现“无响应”观感。任何超过 300ms 的操作必须有反馈。
2. 模型差异显性化：体积、许可证、速度差异直接标在卡片上（“非商用”“仅 Wi-Fi”“CPU 较慢”）。
3. 对比优先：超分结果必须能一键对比原图，滑动分割为默认交互。
4. 单手可达：主操作放在底部，重要按钮距屏幕底边 ≥ 16pt。
5. 暗色优先：图像预览区强制深色背景，减少对图像本身的视觉干扰。

响应时间目标：

操作 目标 超过阈值后的处理
点击反馈 < 100ms 立即高亮/触觉
页面转场 300ms 标准 push/present
小模型加载 < 500ms 无 loading，直接可用
大模型加载 < 3s 超过 300ms 显示“加载模型…”遮罩
模型编译 不定 卡片内转圈 + “编译中”，禁止重复点击
单块推理 不定 超过 1s 追加“预计剩余 Ns”

6.2 导航结构

底部 TabBar，三个主 Tab：

```text
┌─────────────────────────────┐
│                             │
│         内容区域            │
│                             │
├─────────────────────────────┤
│  照片      实时      模型   │
│  🖼️       📷       ⚙️      │
└─────────────────────────────┘
```

· 照片：照片超分主流程。
· 实时：相机实时超分（可选，无相机权限时显示引导）。
· 模型：模型管理。
· TabBar 配置：标准高度 49pt + 安全区；选中项主色，未选中灰色；图标 24pt，标签 10pt。
· 状态保持：切换 Tab 保留各页滚动位置和输入状态（照片页已选图不清空）。
· 转场：Tab 切换无动画；照片页内的模型选择器用 .sheet 半屏；保存成功用 Toast，不弹窗。
· 深层链接：不实现。自用场景无外部唤起需求。
· 返回手势：照片页和模型页的 Sheet 支持下滑关闭；全屏页面左上角“取消/返回”按钮，文案随上下文变化（未选图时“关闭”，推理中“取消”）。

6.3 照片超分页（核心）

布局

```text
┌─────────────────────────────┐
│  [取消]      照片超分    [保存] │
├─────────────────────────────┤
│                             │
│      ┌───────────────┐      │
│      │               │      │
│      │   图片预览区   │      │
│      │  (原图/超分)   │      │
│      │               │      │
│      └───────────────┘      │
│                             │
│   [◀ 滑动对比 ▶]  [并排] [原图]│
├─────────────────────────────┤
│  模型：Real-ESRGAN x4  ▾    │
│  尺寸：512×512 → 2048×2048  │
├─────────────────────────────┤
│  [    开始超分    ]          │
└─────────────────────────────┘
```

尺寸与间距：

· 顶部导航栏：标准 44pt + 安全区；左“取消”右“保存”，标题居中 17pt Semibold。
· 预览区：占满剩余高度，左右 16pt 边距，上下 8pt；黑色背景，图片 aspectFit。
· 对比控件：浮动在预览区底部，距底 12pt，胶囊背景，高度 36pt。
· 模型行：高 44pt，左右 16pt，显示模型名 + 下拉箭头。
· 尺寸行：高 20pt，13pt 灰色文字，显示 512×512 → 2048×2048。
· 主按钮：高 50pt，左右 16pt，距底安全区 16pt，圆角 10pt。

状态机

状态 预览区 模型行 底部按钮 右上“保存”
空态 虚线框 + 图标 + “从相册选择图片” 隐藏 隐藏 隐藏
已选图 原图 可用 “开始超分” 隐藏
推理中 原图 + 40% 黑色遮罩 + 进度环 禁用 “取消” 隐藏
完成 超分结果，默认滑动对比 可用 “重新超分” 可用
失败 原图 + 错误卡片 可用 “重试” 隐藏

空态：虚线框 2pt 描边，圆角 12pt，图标 48pt 灰色，文案 15pt 灰色。点击整个虚线框唤起相册。

选图过渡：选中图片后，缩略图从相册选择器位置以 250ms easeOut 放大进入预览区，同时模型行和按钮从底部 200ms 淡入。

预览区手势

· 双指缩放：UIPinchGestureRecognizer，缩放范围 1×–8×，超出回弹（UIScrollView 的 bouncesZoom）。
· 双击：在 1× 和 2.5× 之间切换，以双击点为锚点，250ms easeInOut 动画。
· 单指拖动：缩放 > 1× 时平移，边界回弹；缩放 = 1× 时禁用拖动，避免与对比滑块冲突。
· 长按：按住 200ms 后显示原图，松手恢复；长按期间震动一次（UIImpactFeedbackGenerator.light）。
· 对比滑块仅在 1× 缩放下可用；缩放 > 1× 时自动隐藏对比控件，退出缩放后恢复。

对比滑块细节

· 初始位置：屏幕中线 50%。
· 拖动：竖线宽 2pt 白色 + 阴影，顶部和底部各有一个 8pt 圆点手柄，可拖动范围限制在预览区左右各 5% 内。
· 惯性：松手后无惯性，立即停在当前位置（图像对比场景不需要惯性，反而干扰）。
· 双击分割线：重置回 50%。
· 并排模式：左右各半，中间 1pt 分割线；两张图独立 aspectFit，高度对齐。
· 原图模式：完整显示原图，超分结果隐藏；再次点击“超分”切回对比。
· 切换动画：三种模式间用 200ms 交叉淡入。

模型选择器（半屏 Sheet）

· 高度：内容自适应，最多 70% 屏幕高，超出可滚动。
· 分组：内置模型 / 已下载 / 可下载，组标题 13pt 灰色。
· 排序：组内按体积升序；已下载的排在可下载之前。
· 列表项：左侧模型名 15pt + 体积 13pt 灰色；右侧状态徽章或“下载”按钮。
· 当前选中项：左侧主色竖条 3pt + 背景主色 10% 透明度。
· 点击未下载项：关闭 Sheet，跳转模型页并高亮该卡片，自动开始下载（蜂窝下先弹确认）。
· 不支持搜索（模型数量 ≤ 10，搜索是过度设计）。

推理进度

· 进度环：预览区中央，直径 64pt，白色描边 4pt，中央显示百分比。
· 分块文案：预览区底部，“处理中 3/16 块”15pt 白色。
· 预计剩余：单块耗时超过 1s 后显示“预计剩余 12s”，每秒更新一次。
· 取消：底部按钮变红色“取消”，点击后立即中断，已处理块丢弃，不写盘，回到“已选图”状态。
· 取消确认：不弹确认框，直接取消（进度可能已达 80%，但重来成本低，弹窗打断更烦）。

保存流程

1. 点击“保存” → 检查相册写入权限。
2. 无权限：弹系统权限请求；被拒后显示引导卡片“请在设置中允许访问相册”，附“打开设置”按钮。
3. 有权限：显示保存进度（大图可能 1–2s），完成后 Toast“已保存到相册”。
4. 保存格式：默认 HEIF（体积小），设置中可切换 PNG。不保留原图 EXIF 中的位置信息，仅保留拍摄时间和设备型号。
5. HDR：若原图是 HDR，超分结果转 SDR 保存，避免色彩异常；UI 不额外提示（自用场景可接受）。
6. 保存后不自动关闭页面，用户可以继续对比或重新超分。

分享

· 长按预览图 → 上下文菜单：“分享”“存储到文件”“复制”。
· 分享用 UIActivityViewController，传入超分后的全分辨率图。

6.4 实时预览页

布局

```text
┌─────────────────────────────┐
│  实时超分            [切换] │
├─────────────────────────────┤
│                             │
│        相机预览画面          │
│      （超分后实时画面）       │
│                             │
│   ┌─────────┐               │
│   │ 28 FPS  │               │
│   └─────────┘               │
├─────────────────────────────┤
│  模型：PiperSR 2x (ANE) ▾   │
│  分辨率：540p → 1080p       │
└─────────────────────────────┘
```

细节：

· 预览区：全屏，aspectFill 裁切，黑色背景。
· FPS 胶囊：左上角，距安全区 16pt，半透明黑色背景，白色 13pt 等宽数字。
· 模型行：底部安全区上方 16pt，高 44pt。
· 分辨率行：模型行下方，13pt 灰色。
· “切换”按钮：右上角，arrow.triangle.2.circlepath.camera 图标，仅前后摄像头切换。

权限与生命周期

· 首次进入：未授权时显示引导卡片“需要相机权限才能实时超分”，附“授权”按钮；点击后弹系统权限。
· 被拒：卡片改为“相机权限被拒绝”，附“打开设置”。
· 进入后台：自动停止相机会话，释放资源；回前台后恢复。
· 来电/中断：监听 AVCaptureSessionWasInterrupted，显示“相机被占用”，中断结束后自动恢复。

FPS 显示

· 计算方式：滑动窗口 30 帧的平均值，每 1s 更新一次 UI。
· 颜色：≥ 25 FPS 白色；20–24 黄色；< 20 红色。
· 低于 15 FPS 持续 3s：底部显示一行提示“当前设备性能不足，可尝试降低分辨率”，不弹窗。

方向

· 锁定竖屏（自用场景简化）；横屏时预览画面旋转但 UI 不旋转，避免布局复杂化。

6.5 模型管理页

布局

```text
┌─────────────────────────────┐
│  模型管理            [清理缓存]│
├─────────────────────────────┤
│  内置模型                    │
│  ┌─────────────────────────┐│
│  │ PiperSR 2x      928 KB  ││
│  │ ANE 实时 · CC-BY-4.0    ││
│  │ [内置]                  ││
│  └─────────────────────────┘│
│  ┌─────────────────────────┐│
│  │ Real-ESRGAN x4v3 2.3 MB ││
│  │ 轻量照片 · BSD-3-Clause ││
│  │ [内置]                  ││
│  └─────────────────────────┘│
│                             │
│  可下载模型                  │
│  ┌─────────────────────────┐│
│  │ Real-ESRGAN x4   59 MB  ││
│  │ 通用照片 · BSD-3-Clause ││
│  │ [下载]                  ││
│  └─────────────────────────┘│
└─────────────────────────────┘
```

尺寸与间距：

· 卡片：左右 16pt，高度自适应（约 88pt），圆角 12pt，背景 secondarySystemGroupedBackground，间距 12pt。
· 卡片内边距 12pt；模型名 15pt Semibold；描述 13pt 灰色；许可证 11pt。
· 组标题：13pt 灰色，左右 16pt，上间距 24pt，下间距 8pt。
· 右侧控件：宽 72pt，垂直居中。

列表项状态

状态 右侧控件 卡片视觉
内置 灰色 内置 徽章 无变化
未下载 下载 按钮（主色填充） 无变化
排队中 排队中 文字 + 灰色 无变化
下载中 圆形进度环 32pt + 百分比 进度环填充
已暂停 继续 按钮（描边） 无变化
编译中 转圈 20pt + 编译中 无变化
已下载 删除 文字按钮（红色） 无变化
失败 重试 按钮（描边）+ 错误简述 左侧 3pt 红色竖条

下载交互细节

· 蜂窝确认：wifiOnly 模型在蜂窝下点击“下载”，弹 UIAlertController：“SinSR 约 517 MB，建议在 Wi-Fi 下下载。”按钮“使用蜂窝下载” / “取消”。
· 队列：同时只下载 1 个；点击第二个模型的“下载”时，状态变为“排队中”，队列顺序按点击时间。
· 暂停/继续：进度环旁有一个 32pt 的暂停按钮；暂停后右侧变“继续”，进度环变灰色。
· 删除确认：“删除后需重新下载（约 59 MB）。”内置模型不显示删除按钮。
· 清理缓存：右上角，点击后弹确认“将清除临时文件，不影响已下载模型。”清理内容：tmp/ 下的解压残留、失败的编译产物。
· 存储空间：页面底部显示一行 13pt 灰色“已用 61 MB · 可用 12.3 GB”，随下载/删除实时更新。

排序

· 组内顺序：内置模型 → 已下载 → 下载中/排队 → 未下载。
· 同状态内按体积升序。
· 不提供手动排序（模型数量少，排序价值低）。

6.6 通用状态与交互

空态

· 照片页未选图：虚线框 + 图标 + “从相册选择图片”。
· 模型页：内置模型始终存在，不显示空态；若所有可下载模型都已下载，组标题“可下载模型”隐藏。

加载态

· 模型编译：卡片内转圈 + “编译中”，禁止重复点击；编译失败转为“失败”状态。
· 首次加载大模型：全屏轻量遮罩（黑色 30%），中央白色转圈 + “加载模型…”，超过 3s 显示“首次加载可能需要几秒钟”。
· 图片解码：预览区显示低分辨率缩略图占位，全图解码完成后 200ms 淡入。

骨架屏

· 模型管理页首次加载 manifest 时，显示 3 个灰色占位卡片，骨架动画用 opacity 0.3–0.6 循环，周期 1.2s。
· 照片页不走骨架屏（空态已足够）。

Toast 规范

· 位置：底部安全区上方 24pt，居中。
· 样式：深色背景（#1C1C1E 90%），白色 14pt 文字，圆角 10pt，内边距 12×8pt。
· 时长：2s 后淡出，可叠加但最多 2 条。
· 场景：保存成功、下载完成、删除完成、复制成功。

错误态

· 统一样式：卡片内，图标 32pt + 标题 15pt Semibold + 简述 13pt 灰色 + 主按钮。
· 下载失败：“下载中断，已保留进度。”按钮“重试”。
· 编译失败：“模型文件可能损坏。”按钮“重新下载”。
· 推理失败：“内存不足。”按钮“降低分块大小重试”；点击后将 tile 从 512 降到 256 重试。
· 加载失败：“模型加载失败。”按钮“回退到内置模型”；点击后切到 PiperSR 并关闭错误卡片。

权限引导

· 相册：卡片样式，图标 photo，标题“需要相册权限”，按钮“打开设置”。
· 相机：卡片样式，图标 camera，标题“需要相机权限”，按钮“授权”（首次）/“打开设置”（被拒后）。
· 权限引导卡片不阻塞其他页面，仅出现在对应 Tab 内。

首次启动引导

· 自用场景不做多页引导。首次启动显示一个 1 屏说明卡片：“内置 PiperSR 和 Real-ESRGAN x4v3，可直接使用。更多模型可在‘模型’页下载。”按钮“知道了”。
· 只显示一次，记录在 UserDefaults。

崩溃恢复

· 照片页推理中崩溃：重启后回到空态，不恢复推理（中间状态无价值）。
· 下载中崩溃：重启后从本地队列恢复，断点续传继续。
· 编译中崩溃：重启后检查临时目录，若有未完成的 .mlpackage 残留，标记为“失败”，提示重新下载。

6.7 视觉规范

项 值
模式 默认跟随系统，支持暗色/亮色；图像预览区强制深色背景
主色 系统蓝 #0A84FF（暗色）/ #007AFF（亮色）
强调/警告 橙色 #FF9F0A（非商用、Wi-Fi 提示）
错误 红色 #FF453A
背景 暗色 #000000 / #1C1C1E；亮色 #F2F2F7 / #FFFFFF
卡片背景 暗色 #1C1C1E；亮色 #FFFFFF
分割线 暗色 #38383A；亮色 #C6C6C8，0.5pt
卡片圆角 12pt
按钮圆角 10pt；主按钮高度 50pt
徽章圆角 4pt，高度 18pt，内边距 4×2pt
间距 8pt 网格；页面边距 16pt；卡片内边距 12pt；卡片间距 12pt
字体 SF Pro；标题 17pt Semibold；正文 15pt Regular；辅助 13pt；徽章 11pt Medium
图标 SF Symbols 24pt（Tab）、20pt（按钮内）、16pt（行内）
阴影 卡片无阴影，用背景色区分；FPS 胶囊和 Toast 用 0 2pt 8pt 黑色 20%
安全区 所有固定元素距安全区 ≥ 16pt；底部按钮距安全区 16pt

动效参数：

场景 时长 曲线
页面 push/present 300ms easeInOut
Sheet 弹出 300ms 系统默认
选图过渡 250ms easeOut
对比模式切换 200ms easeInOut
双击缩放 250ms easeInOut
Toast 淡入/淡出 200ms easeInOut
进度环更新 200ms linear
骨架屏循环 1200ms easeInOut 循环
长按原图切换 150ms easeOut

动效原则：不做弹跳（spring）动画，图像处理工具应保持克制；所有动效可被“减弱动态效果”系统设置关闭。

6.8 组件清单与状态映射

组件 用途 状态
ModelCard 模型列表项 内置/未下载/排队中/下载中/已暂停/编译中/已下载/失败
Badge 状态与许可证 内置、已下载、非商用、仅 Wi-Fi、CPU 较慢
DownloadProgress 下载进度 进度环 + 百分比 + 暂停/继续
CompareSlider 对比预览 滑动、并排、长按原图
InferenceProgress 分块进度 块计数 + 环形进度 + 预计剩余
PrimaryButton 主操作 默认/禁用/加载中/取消（红色）
SecondaryButton 次要操作 默认/禁用
EmptyState 空态 图标 + 文案 + 可选按钮
ErrorCard 错误 标题 + 简述 + 重试
PermissionCard 权限引导 相册/相机，授权/打开设置
FPSBadge 实时帧率 正常/警告/危险三色
StorageFooter 存储用量 已用/可用
Toast 轻提示 成功/信息

6.9 无障碍与性能

无障碍：

· 所有按钮有 accessibilityLabel，图标按钮必须有标签（如“切换摄像头”）。
· 进度条使用 accessibilityValue 播报“已下载 45%”“处理中 3/16 块”。
· 对比滑块支持 accessibilityAdjustableAction，上下滑动微调分割线位置，每次 5%。
· 支持 Dynamic Type：正文和标题随系统字号缩放，卡片高度自适应；徽章和 FPS 胶囊不缩放（空间受限）。
· 对比度：所有文字对比度 ≥ 4.5:1；橙色徽章在暗色下用 #FFB340 提高对比度。
· 减弱动态效果：关闭所有非必要动画，仅保留透明度变化。

性能：

· 预览区使用降采样缩略图（最长边 ≤ 2048px），保存时才输出全分辨率。
· 实时页 FPS 更新节流到 1s 一次，不每帧刷新 UI。
· 模型列表滚动使用 LazyVStack，卡片内不加载模型，仅读 manifest。
· 推理中避免高频 UI 刷新：进度环每 200ms 更新一次，块计数每块更新一次。
· 图片解码在后台队列，主线程只做 UI 更新。

6.10 屏幕适配

设备 适配策略
iPhone SE（小屏） 预览区高度自适应，模型行和按钮压缩到 40pt；对比控件改到预览区右上角竖排
iPhone 标准/Plus 按上述布局
iPhone Pro Max 预览区更大，其余不变
iPad 照片页改为左右分栏：左侧预览，右侧模型/操作面板；模型页卡片改为两列网格
横屏 照片页锁定竖屏；实时页预览旋转但 UI 不旋转；模型页支持横屏

安全区：所有固定元素避让刘海和 Home Indicator；预览区延伸到安全区外（全屏黑底），但控件保持在安全区内。

6.11 文案规范

场景 文案
空态 从相册选择图片
开始超分 开始超分
推理中 处理中 {n}/{total} 块
预计剩余 预计剩余 {n}s
取消 取消
重新超分 重新超分
保存成功 已保存到相册
下载 下载
排队中 排队中
暂停 暂停
继续 继续
编译中 编译中
删除 删除
删除确认 删除后需重新下载（约 {size}）。
蜂窝确认 {name} 约 {size}，建议在 Wi-Fi 下下载。
下载失败 下载中断，已保留进度。
编译失败 模型文件可能损坏，请重新下载。
推理失败 内存不足，请尝试更小分块。
加载失败 模型加载失败。
回退内置 回退到内置模型
清理缓存 将清除临时文件，不影响已下载模型。
存储用量 已用 {used} · 可用 {free}
权限-相册 需要相册权限才能保存图片。
权限-相机 需要相机权限才能实时超分。
打开设置 打开设置
首次引导 内置 PiperSR 和 Real-ESRGAN x4v3，可直接使用。更多模型可在“模型”页下载。
性能不足 当前设备性能不足，可尝试降低分辨率。

文案原则：动词开头、不用感叹号、错误文案必须给出下一步动作；体积统一用 MB/GB，保留一位小数。

6.12 触觉反馈

场景 反馈类型
开始超分 UIImpactFeedbackGenerator.medium
推理完成 UINotificationFeedbackGenerator.success
保存成功 .success
下载完成 .success
删除完成 .light
长按显示原图 .light
对比滑块跨过 50% .selection（仅一次，不重复触发）
错误 .error
蜂窝确认弹窗 .warning

触觉可被系统“触觉反馈”设置关闭，代码中不强制。

---

7. 内存与错误处理

· 推理前后 autoreleasepool，及时释放缓冲区。
· 大模型推理前检查 os_proc_available_memory()，不足则拒绝并提示。
· 下载失败保留断点，提供重试。
· 编译失败给出明确错误（损坏/不兼容/磁盘不足）。
· 加载失败回退到内置 PiperSR，保证 App 可用。
· SinSR 额外提示：CPU 推理耗时可能是 ANE 模型数倍，UI 显式标注预计时间。

---

8. 构建与安装

· Xcode 工程按你现有自签名配置。
· 开发期 Run 到设备调试；稳定后打包 IPA 走自签名流程。
· 模型托管：GitHub Releases / Cloudflare R2 / 自建 HTTP。建议所有 .mlpackage 自打包成 zip，避免 HF 目录结构兼容问题。
· .sha256 首次上传后计算并写回 manifest。

---

9. 开发里程碑

1. 最小闭环：内置 PiperSR，选图 → 推理 → 保存。
2. 模型管理骨架：manifest、沙盒扫描、内置模型加载。
3. 下载链路：用 Real-ESRGAN x4v3（2.29 MB）跑通下载 → SHA256 → 解压 → 编译 → 持久化 → 加载。
4. 通用模型：接入 Real-ESRGAN x4（59 MB），验证 .all 下推理与内存。
5. 分块推理：x4plus / UltraSharp 大图 tile + 羽化融合 + 分块进度 UI。
6. UI 打磨：对比滑块、模型卡片状态、错误态、空态、Toast、触觉。
7. 扩散模型（可选）：SinSR 三件套，Denoiser cpuOnly，Wi-Fi 限制，进度与耗时提示。
8. 实时预览（可选）：PiperSR 相机流 + FPS 显示 + 权限引导。

---

10. 已知限制

· AdcSR 不可用：Core AI 格式，需 iOS 27+，当前 Core ML 无法加载。扩散效果用 SinSR。
· ESPCN / EDSR 无现成 Core ML 包：已用 PiperSR 和 Real-ESRGAN x4v3 替代。
· SinSR 非商用：CC BY-NC-SA 4.0，自用可以，商用需换方案。
· HF .mlpackage 目录下载：优先自打包 zip 托管。
· ANE 算子回退：以 Xcode 性能报告为准。
· Denoiser 必须 CPU：SinSR 的 Denoiser 强行放 ANE 会数值异常/崩溃。
· 实时仅 PiperSR：Real-ESRGAN 系列不适合实时，UI 中不提供实时选项。
· 横屏支持有限：照片页锁定竖屏，实时页和模型页支持横屏但不做深度适配。

---

本次 UI 细化补充了：全局响应时间目标、导航与转场、预览区手势（缩放/双击/长按/平移）、对比滑块的精确行为、模型选择器分组与排序、保存与分享流程、权限生命周期、下载队列与蜂窝确认、Toast/骨架屏/错误态/权限引导/首次启动/崩溃恢复、动效参数表、组件状态映射、无障碍、屏幕适配、文案表、触觉反馈映射。所有 UI 状态都与模型清单和推理流程一一对应，可直接作为开发与验收依据。# CF