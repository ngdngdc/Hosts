#!/usr/bin/env bash
#
# BuildConfig.sh
#
# 作用：参考 MergeConfig.sh，读取 Domains.json 与 Domains_Remote.json 中的全部域名，
#       以 {"mode":"tls-rf","dns_mode":"prefer_ipv6"} 的策略追加到 config_default.json
#       的 domain_policies 末尾，输出 config_ngdngdc.json。
#       Domains.json 的域名在前，Domains_Remote.json 的域名在后。
#
# 用法： ./BuildConfig.sh [Domains.json] [Domains_Remote.json] [基础配置] [输出文件]
#
# 说明：
#   基础配置默认取本地 config_default.json；本地不存在时才从 CONFIG_URL 下载。
#   默认不会覆盖 config_default.json 中已有的同名域名策略（避免冲掉上游精调规则），
#   需要强制覆盖时设置环境变量 OVERRIDE_EXISTING=1。
#   下载基础配置时可用 GH_PROXY（如 https://ghproxy.top/）走加速镜像，失败自动回退直连。
#
set -euo pipefail

LOCAL_DOMAINS_FILE="${1:-Domains.json}"
REMOTE_DOMAINS_FILE="${2:-Domains_Remote.json}"
CONFIG_FILE="${3:-config_default.json}"
OUTPUT_FILE="${4:-config_ngdngdc.json}"

# 输出目录预检：目录不存在时提前给出明确错误，避免重定向失败被静默吞掉
_out_dir="$(dirname "$OUTPUT_FILE")"
if [[ ! -d "$_out_dir" ]]; then
  echo "错误: 输出目录不存在: $_out_dir" >&2
  exit 1
fi
OVERRIDE_EXISTING="${OVERRIDE_EXISTING:-0}"

CONFIG_URL="${CONFIG_URL:-https://raw.githubusercontent.com/SniShaper/lumine-for-android/refs/heads/main/android/app/src/main/assets/config_default.json}"

# ---------------------------------------------------------------- 环境自检
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "错误: 需要 bash 4.0 及以上版本（当前: ${BASH_VERSION:-未知}），请用 bash 而非 sh 执行" >&2
  exit 1
fi

missing=()
for bin in jq awk sed mktemp; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  echo "错误: 缺少依赖: ${missing[*]}" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------- 准备基础配置
BASE_CONFIG="$TMP_DIR/config_base.json"
if [[ -f "$CONFIG_FILE" ]]; then
  cp "$CONFIG_FILE" "$BASE_CONFIG"
  echo "✓ 使用本地基础配置: $CONFIG_FILE" >&2
else
  echo "本地基础配置不存在，尝试下载: $CONFIG_URL" >&2
  if ! command -v curl >/dev/null 2>&1; then
    echo "错误: 缺少依赖 curl，且本地无 $CONFIG_FILE（无法下载基础配置）" >&2
    exit 1
  fi
  # curl 通用选项：--retry-all-errors 需 curl 7.71+，老版本上自动降级为普通重试
  CURL_OPTS=(-fsSL --retry 3 --retry-delay 2 --max-time 30)
  if curl --help all 2>/dev/null | grep -q 'retry-all-errors'; then
    CURL_OPTS+=(--retry-all-errors)
  fi
  # 先尝试 GH_PROXY 镜像（若设置），失败自动回退直连
  urls=()
  if [[ -n "${GH_PROXY:-}" ]]; then
    urls+=("${GH_PROXY%/}/${CONFIG_URL}")
  fi
  urls+=("$CONFIG_URL")
  downloaded=0
  for u in "${urls[@]}"; do
    if curl "${CURL_OPTS[@]}" "$u" -o "$BASE_CONFIG" && [[ -s "$BASE_CONFIG" ]]; then
      echo "✓ 已下载基础配置: $u" >&2
      downloaded=1
      break
    fi
  done
  if (( downloaded == 0 )); then
    echo "错误: 基础配置下载失败: $CONFIG_URL" >&2
    exit 1
  fi
fi

if ! jq empty "$BASE_CONFIG" 2>/dev/null; then
  echo "错误: 基础配置不是有效 JSON: $CONFIG_FILE" >&2
  exit 1
fi
if [[ "$(jq 'has("domain_policies")' "$BASE_CONFIG")" != "true" ]]; then
  echo "错误: 基础配置中缺少 domain_policies 字段" >&2
  exit 1
fi

# ---------------------------------------------------------------- 收集域名
# 从分组文件按文件顺序 → 分组顺序 → 数组顺序展开，并去重保留首次出现位置。
collect_domains() {
  local file="$1" label="$2"
  if [[ ! -f "$file" ]]; then
    echo "警告: 找不到域名分组文件，已跳过: $file" >&2
    return 0
  fi
  if ! jq empty "$file" 2>/dev/null; then
    echo "警告: $file 不是有效 JSON，已跳过" >&2
    return 0
  fi
  # 顶层必须是对象；null / 数组等会让 to_entries 直接报错退出
  if [[ "$(jq -r 'type' "$file" 2>/dev/null)" != "object" ]]; then
    echo "警告: $file 顶层不是 JSON 对象，已跳过" >&2
    return 0
  fi
  jq -r 'to_entries[] | .value[]' "$file"
  echo "✓ 已载入 $label: $file" >&2
}

DOMAINS="$(
  {
    collect_domains "$LOCAL_DOMAINS_FILE" "本地分组"
    collect_domains "$REMOTE_DOMAINS_FILE" "远程分组"
  } | grep -E '^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$' \
    | awk '!seen[$0]++' || true
)"

if [[ -z "$DOMAINS" ]]; then
  echo "警告: 未提取到任何域名，原样输出基础配置" >&2
  cp "$BASE_CONFIG" "$OUTPUT_FILE"
  exit 0
fi

DOMAIN_COUNT=$(printf '%s\n' "$DOMAINS" | grep -c . || true)
echo "共提取到 $DOMAIN_COUNT 个唯一域名" >&2

# ---------------------------------------------------------------- 合并策略
NEW_ENTRIES=$(printf '%s\n' "$DOMAINS" \
  | jq -Rn '[inputs | {key: ., value: {"mode": "tls-rf", "dns_mode": "prefer_ipv6"}}]')

OLD_COUNT=$(jq '.domain_policies | length' "$BASE_CONFIG")

jq --argjson new "$NEW_ENTRIES" --arg override "$OVERRIDE_EXISTING" '
  .domain_policies = (
    reduce ($new[]) as $e (.domain_policies;
      if ($override == "1" or (has($e.key) | not))
      then .[$e.key] = $e.value
      else .
      end
    )
  )
' "$BASE_CONFIG" > "$OUTPUT_FILE"

if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "错误: 生成的配置文件不是有效 JSON" >&2
  exit 1
fi

NEW_COUNT=$(jq '.domain_policies | length' "$OUTPUT_FILE")
ADDED=$((NEW_COUNT - OLD_COUNT))
SKIPPED=$((DOMAIN_COUNT - ADDED))

echo "----------------------------------------" >&2
echo "合并完成: $OUTPUT_FILE" >&2
echo "domain_policies: $OLD_COUNT → $NEW_COUNT (新增 $ADDED, 保留已有策略 $SKIPPED)" >&2
