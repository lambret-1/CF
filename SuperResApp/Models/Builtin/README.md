# 内置模型目录

此目录存放编译后的 Core ML 模型（.mlmodelc）。

## 快速编译（推荐）

在项目根目录运行一键编译脚本（需 macOS + Xcode 15.4+）：

```bash
./scripts/compile_builtin_models.sh
```

脚本会自动从 Hugging Face 下载模型并编译到此目录。

## 需要放入的文件

1. **PiperSR_2x.mlmodelc/** — 约 928KB，计算单元 .cpuAndNeuralEngine
2. **RealESRGAN_x4v3.mlmodelc/** — 约 2.3MB，计算单元 .all

## 手动编译方法

```bash
# 下载 PiperSR（HF 上是目录结构，需逐文件下载）
mkdir -p PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights
curl -L -o PiperSR_2x.mlpackage/Manifest.json \
  "https://huggingface.co/ModelPiper/PiperSR-2x/resolve/main/PiperSR_2x.mlpackage/Manifest.json"
curl -L -o PiperSR_2x.mlpackage/Data/com.apple.CoreML/model.mlmodel \
  "https://huggingface.co/ModelPiper/PiperSR-2x/resolve/main/PiperSR_2x.mlpackage/Data/com.apple.CoreML/model.mlmodel"
curl -L -o PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin \
  "https://huggingface.co/ModelPiper/PiperSR-2x/resolve/main/PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin"

# 下载 Real-ESRGAN x4v3（直接 zip）
curl -L -o RealESRGAN_x4v3.mlpackage.zip \
  "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus/resolve/main/RealESRGAN-x4v3.mlpackage.zip"
unzip RealESRGAN_x4v3.mlpackage.zip

# 编译
xcrun coremlcompiler compile PiperSR_2x.mlpackage .
xcrun coremlcompiler compile RealESRGAN-x4v3.mlpackage .
mv RealESRGAN-x4v3.mlmodelc RealESRGAN_x4v3.mlmodelc
```

## 模型来源与校验

| 模型 | 来源 | SHA256 (zip) |
|---|---|---|
| PiperSR 2x | https://huggingface.co/ModelPiper/PiperSR-2x | fed22b55e9d4770f247ca69e5d3ed51beb629e436b71ad3d5c9f4588f199bb42 |
| Real-ESRGAN x4v3 | https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus | 5a59e554794371b95fe61274b8a2040f1b3e274479abf15595dcdad0535afad4 |

## 注意

- .mlmodelc 是目录，不是单文件，需整个目录放入
- 这些模型已被 .gitignore 排除，不会提交到仓库
- 首次运行前必须放入模型，否则 App 加载失败时会回退逻辑可能不可用
- Real-ESRGAN 全系计算单元必须 .all，禁止改为 .cpuOnly 或 .cpuAndGPU
