#!/bin/bash
# 编译内置模型脚本（需在 macOS 上运行，Xcode 15.4+）
# 用法：./scripts/compile_builtin_models.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILTIN_DIR="$PROJECT_DIR/SuperResApp/Models/Builtin"
TMP_DIR="$PROJECT_DIR/tmp_models"

echo "=== 超分工坊 - 内置模型编译脚本 ==="
echo "项目目录: $PROJECT_DIR"
echo "输出目录: $BUILTIN_DIR"
echo ""

# 清理临时目录
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# 检查 coremlcompiler
if ! command -v xcrun &> /dev/null; then
    echo "错误: 未找到 xcrun，请安装 Xcode"
    exit 1
fi

echo "[1/4] 下载 PiperSR 2x..."
mkdir -p "$TMP_DIR/PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights"
curl -sL -o "$TMP_DIR/PiperSR_2x.mlpackage/Manifest.json" \
    "https://huggingface.co/ModelPiper/PiperSR-2x/resolve/main/PiperSR_2x.mlpackage/Manifest.json"
curl -sL -o "$TMP_DIR/PiperSR_2x.mlpackage/Data/com.apple.CoreML/model.mlmodel" \
    "https://huggingface.co/ModelPiper/PiperSR-2x/resolve/main/PiperSR_2x.mlpackage/Data/com.apple.CoreML/model.mlmodel"
curl -sL -o "$TMP_DIR/PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin" \
    "https://huggingface.co/ModelPiper/PiperSR-2x/resolve/main/PiperSR_2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
echo "  完成"

echo "[2/4] 下载 Real-ESRGAN x4v3..."
curl -sL -o "$TMP_DIR/RealESRGAN_x4v3.mlpackage.zip" \
    "https://huggingface.co/LocalMuseAI/coreml-realesrgan-x4plus/resolve/main/RealESRGAN-x4v3.mlpackage.zip"
unzip -q "$TMP_DIR/RealESRGAN_x4v3.mlpackage.zip" -d "$TMP_DIR"
echo "  完成"

echo "[3/4] 编译 PiperSR 2x..."
rm -rf "$BUILTIN_DIR/PiperSR_2x.mlmodelc"
xcrun coremlcompiler compile "$TMP_DIR/PiperSR_2x.mlpackage" "$BUILTIN_DIR"
echo "  完成 -> $BUILTIN_DIR/PiperSR_2x.mlmodelc"

echo "[4/4] 编译 Real-ESRGAN x4v3..."
rm -rf "$BUILTIN_DIR/RealESRGAN_x4v3.mlmodelc" "$BUILTIN_DIR/RealESRGAN-x4v3.mlmodelc"
xcrun coremlcompiler compile "$TMP_DIR/RealESRGAN-x4v3.mlpackage" "$BUILTIN_DIR"
# 重命名为统一格式
if [ -d "$BUILTIN_DIR/RealESRGAN-x4v3.mlmodelc" ]; then
    mv "$BUILTIN_DIR/RealESRGAN-x4v3.mlmodelc" "$BUILTIN_DIR/RealESRGAN_x4v3.mlmodelc"
fi
echo "  完成 -> $BUILTIN_DIR/RealESRGAN_x4v3.mlmodelc"

# 清理
rm -rf "$TMP_DIR"

echo ""
echo "=== 编译完成 ==="
echo "内置模型已放入: $BUILTIN_DIR"
ls -lh "$BUILTIN_DIR"/*.mlmodelc 2>/dev/null || echo "（未找到 .mlmodelc，请检查错误）"
