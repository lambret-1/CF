# 内置模型目录

此目录存放编译后的 Core ML 模型（.mlmodelc）。

## 需要放入的文件

1. **PiperSR_2x.mlmodelc/** — 约 928KB，从 PiperSR_2x.mlpackage 编译得到
2. **RealESRGAN_x4v3.mlmodelc/** — 约 2.29MB，从 RealESRGAN-x4v3.mlpackage 编译得到

## 编译方法

```bash
# 方法一：Xcode 自动编译
# 将 .mlpackage 拖入 Xcode 工程，Xcode 会在构建时自动编译为 .mlmodelc

# 方法二：命令行手动编译
xcrun coremlcompiler compile PiperSR_2x.mlpackage .
xcrun coremlcompiler compile RealESRGAN-x4v3.mlpackage .
```

## 模型来源

- PiperSR 2x: https://huggingface.co/ModelPiper/PiperSR-2x
- Real-ESRGAN x4v3: https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus

## 注意

- .mlmodelc 是目录，不是单文件，需整个目录放入
- 这些模型已被 .gitignore 排除，不会提交到仓库
- 首次运行前必须放入模型，否则 App 会提示"内置模型缺失"并引导下载
