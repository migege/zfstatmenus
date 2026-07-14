#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_FILE="ZFStatMenus.xcodeproj"
readonly SCHEME="ZFStatMenus"
readonly PRODUCT_NAME="ZFStatMenus"

configuration="Release"
architecture="native"
output_dir="build/packages"
clean_build=false

usage() {
    cat <<'EOF'
用法：./scripts/package.sh [选项]

编译 ZFStatMenus，并生成未签名的 macOS ZIP 包。

选项：
  --configuration <Release|Debug>  构建配置，默认 Release
  --arch <native|arm64|x86_64|universal>
                                   目标架构，默认 native
  --output-dir <路径>              输出目录，默认 build/packages
  --clean                          打包前执行 clean
  -h, --help                       显示帮助

示例：
  ./scripts/package.sh
  ./scripts/package.sh --arch universal
  ./scripts/package.sh --configuration Debug --arch arm64
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || fail "--configuration 缺少参数"
            configuration="$2"
            shift 2
            ;;
        --arch)
            [[ $# -ge 2 ]] || fail "--arch 缺少参数"
            architecture="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir 缺少参数"
            output_dir="$2"
            shift 2
            ;;
        --clean)
            clean_build=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1"
            ;;
    esac
done

case "$configuration" in
    Release|Debug) ;;
    *) fail "--configuration 只支持 Release 或 Debug" ;;
esac

case "$architecture" in
    native)
        build_archs="$(uname -m)"
        arch_label="$build_archs"
        only_active_arch="YES"
        ;;
    arm64|x86_64)
        build_archs="$architecture"
        arch_label="$architecture"
        only_active_arch="YES"
        ;;
    universal)
        build_archs="arm64 x86_64"
        arch_label="universal"
        only_active_arch="NO"
        ;;
    *)
        fail "--arch 只支持 native、arm64、x86_64 或 universal"
        ;;
esac

for command_name in xcodebuild ditto plutil unzip shasum awk; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令：$command_name"
done

if [[ "$output_dir" != /* ]]; then
    output_dir="${PROJECT_ROOT}/${output_dir}"
fi

readonly derived_data_path="${PROJECT_ROOT}/build/PackageDerivedData"
readonly app_path="${derived_data_path}/Build/Products/${configuration}/${PRODUCT_NAME}.app"

mkdir -p "$output_dir"

build_actions=(build)
if [[ "$clean_build" == true ]]; then
    build_actions=(clean build)
fi

echo "开始构建：configuration=${configuration}, arch=${arch_label}"

cd "$PROJECT_ROOT"
xcodebuild \
    -quiet \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$configuration" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data_path" \
    "ARCHS=${build_archs}" \
    "ONLY_ACTIVE_ARCH=${only_active_arch}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "${build_actions[@]}"

[[ -d "$app_path" ]] || fail "未找到构建产物：$app_path"

version="$(plutil -extract CFBundleShortVersionString raw -o - "${app_path}/Contents/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw -o - "${app_path}/Contents/Info.plist")"
[[ -n "$version" ]] || fail "无法读取应用版本"
[[ -n "$build_number" ]] || fail "无法读取构建号"

configuration_suffix=""
if [[ "$configuration" != "Release" ]]; then
    configuration_suffix="-${configuration}"
fi

package_name="${PRODUCT_NAME}-${version}-macos-${arch_label}${configuration_suffix}-unsigned.zip"
package_path="${output_dir}/${package_name}"

rm -f "$package_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$package_path"
unzip -tq "$package_path"

checksum="$(shasum -a 256 "$package_path" | awk '{print $1}')"

echo
echo "打包完成"
echo "  版本：${version} (${build_number})"
echo "  应用：${app_path}"
echo "  安装包：${package_path}"
echo "  SHA-256：${checksum}"
echo
echo "注意：该产物未使用 Developer ID 签名和 Apple 公证，仅适合本机开发测试。"
