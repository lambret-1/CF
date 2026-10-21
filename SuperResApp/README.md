# SuperResApp 源码目录

## 目录说明

| 目录 | 职责 |
|---|---|
| `App/` | 应用入口、依赖注入容器 |
| `Models/Builtin/` | 内置编译后模型（.mlmodelc） |
| `Models/Manifest/` | 模型清单 Codable 结构、加载器 |
| `Models/` | 模型描述符、推理进度/结果/错误类型 |
| `Services/` | 核心服务层 |
| `Features/PhotoSuperRes/` | 照片超分功能 |
| `Features/LivePreview/` | 实时预览功能 |
| `Features/ModelManager/` | 模型管理功能 |
| `UI/Components/` | 通用 UI 组件 |
| `UI/Theme/` | 主题（颜色/字体/设计令牌） |
| `UI/Screens/` | 根导航屏幕 |
| `Resources/` | 资源文件 |

## 服务层说明

| 文件 | 职责 |
|---|---|
| `NetworkMonitor.swift` | NWPathMonitor，蜂窝/Wi-Fi 判断 |
| `MemoryPressureMonitor.swift` | 内存警告监听、可用内存查询 |
| `ModelDownloader.swift` | 后台 URLSession 下载、断点续传、队列、SHA256 |
| `ModelCompiler.swift` | ZIPFoundation 解压、MLModel 编译、持久化 |
| `ModelStore.swift` | actor 模型缓存、加载/驱逐、内存警告自动驱逐 |
| `SuperResolver.swift` | 分块推理、羽化融合、进度回调、SinSR 三件套 |
| `PhotoLibraryService.swift` | 相册权限、HEIF/PNG 保存 |
| `CameraSession.swift` | AVCaptureSession、CVPixelBuffer 输出 |

## 构建依赖

- iOS 17.0+
- Xcode 15.4+
- XcodeGen
- ZIPFoundation（SPM 自动引入）
