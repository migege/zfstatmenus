#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_FILE="ZFStatMenus.xcodeproj"
readonly SCHEME="ZFStatMenus"
readonly PRODUCT_NAME="ZFStatMenus"

configuration="Debug"
clean_build=false

usage() {
    cat <<'EOF'
用法：./scripts/build-and-run.sh [选项]

构建 ZFStatMenus，关闭当前运行的旧实例，然后打开刚生成的应用。
只有构建成功后才会关闭旧实例。

选项：
  --configuration <Debug|Release>  构建配置，默认 Debug
  --clean                          构建前执行 clean
  -h, --help                       显示帮助

示例：
  ./scripts/build-and-run.sh
  ./scripts/build-and-run.sh --clean
  ./scripts/build-and-run.sh --configuration Release
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
    Debug|Release) ;;
    *) fail "--configuration 只支持 Debug 或 Release" ;;
esac

for command_name in xcodebuild open pgrep pkill; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令：$command_name"
done

readonly derived_data_path="${PROJECT_ROOT}/build/RunDerivedData"
readonly app_path="${derived_data_path}/Build/Products/${configuration}/${PRODUCT_NAME}.app"

build_actions=(build)
if [[ "$clean_build" == true ]]; then
    build_actions=(clean build)
fi

echo "开始构建：configuration=${configuration}"

cd "$PROJECT_ROOT"
xcodebuild \
    -quiet \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$configuration" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "${build_actions[@]}"

[[ -d "$app_path" ]] || fail "未找到构建产物：$app_path"

if pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
    echo "关闭旧的 ${PRODUCT_NAME} 实例..."
    pkill -TERM -x "$PRODUCT_NAME" || true

    for _ in {1..20}; do
        if ! pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done

    if pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
        echo "旧实例未及时退出，强制结束..."
        pkill -KILL -x "$PRODUCT_NAME" || true

        for _ in {1..20}; do
            if ! pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done

        if pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; then
            fail "无法结束旧的 ${PRODUCT_NAME} 实例"
        fi
    fi
fi

echo "打开新构建：${app_path}"
launched=false
for attempt in {1..3}; do
    if open -n "$app_path"; then
        launched=true
        break
    fi

    if [[ "$attempt" -lt 3 ]]; then
        echo "启动请求失败，等待 LaunchServices 后重试（${attempt}/3）..."
        sleep 0.3
    fi
done

[[ "$launched" == true ]] || fail "无法启动新构建：${app_path}"

echo "完成：已构建并启动新的 ${PRODUCT_NAME}。"
