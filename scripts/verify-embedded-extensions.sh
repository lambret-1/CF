#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: verify-embedded-extensions.sh <SuperResApp.app>}"
EXPECTED_APP_BUNDLE_ID="com.superres.app"
PLUGINS_DIR="$APP_PATH/PlugIns"

fail() {
  echo "::error::$1"
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

[[ -d "$APP_PATH" ]] || fail "主程序 .app 不存在：$APP_PATH"
APP_INFO="$APP_PATH/Info.plist"
[[ -f "$APP_INFO" ]] || fail "主程序 Info.plist 缺失"
APP_BUNDLE_ID="$(plist_value "$APP_INFO" CFBundleIdentifier || true)"
[[ "$APP_BUNDLE_ID" == "$EXPECTED_APP_BUNDLE_ID" ]] || fail "主程序 Bundle ID 不匹配：$APP_BUNDLE_ID"
[[ -d "$PLUGINS_DIR" ]] || fail "主程序中缺少 PlugIns 目录，扩展没有被嵌入"

verify_extension() {
  local bundle_name="$1"
  local expected_bundle_id="$2"
  local expected_extension_point="$3"
  local extension_path="$PLUGINS_DIR/$bundle_name"
  local info="$extension_path/Info.plist"

  [[ -d "$extension_path" ]] || fail "缺少嵌入扩展：$extension_path"
  [[ -f "$info" ]] || fail "$bundle_name 缺少 Info.plist"

  local bundle_id package_type executable extension_point principal_class
  bundle_id="$(plist_value "$info" CFBundleIdentifier || true)"
  package_type="$(plist_value "$info" CFBundlePackageType || true)"
  executable="$(plist_value "$info" CFBundleExecutable || true)"
  extension_point="$(plist_value "$info" NSExtension:NSExtensionPointIdentifier || true)"
  principal_class="$(plist_value "$info" NSExtension:NSExtensionPrincipalClass || true)"

  [[ "$bundle_id" == "$expected_bundle_id" ]] || fail "$bundle_name Bundle ID 错误：$bundle_id"
  [[ "$package_type" == "XPC!" ]] || fail "$bundle_name CFBundlePackageType 应为 XPC!，实际为：$package_type"
  [[ -n "$executable" && -f "$extension_path/$executable" ]] || fail "$bundle_name 扩展可执行文件缺失：$executable"
  [[ "$extension_point" == "$expected_extension_point" ]] || fail "$bundle_name 扩展入口错误：$extension_point"
  if [[ "$expected_extension_point" == "com.apple.photo-editing" ]]; then
    [[ "$principal_class" == *.PhotoEditingViewController ]] || fail "照片编辑扩展 Principal Class 错误：$principal_class"
    [[ "$principal_class" != *'$('* ]] || fail "照片编辑扩展 Principal Class 未完成构建变量替换：$principal_class"
    /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:PHSupportedMediaTypes:0" "$info" 2>/dev/null | grep -qx "Image" || fail "照片编辑扩展未声明支持 Image 媒体类型"
  fi

  echo "✓ $bundle_name"
  echo "  Bundle ID: $bundle_id"
  echo "  Extension Point: $extension_point"
  echo "  Executable: $executable"
}

verify_extension \
  "PhotoEditingExtension.appex" \
  "com.superres.app.PhotoEditingExtension" \
  "com.apple.photo-editing"

verify_extension \
  "PhotoEditorLiveActivity.appex" \
  "com.superres.app.PhotoEditorLiveActivity" \
  "com.apple.widgetkit-extension"

echo "✓ 主程序及两个嵌入扩展的结构检查通过"
