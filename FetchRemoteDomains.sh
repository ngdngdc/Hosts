#!/usr/bin/env bash
#
# FetchRemoteDomains.sh
#
# 作用：抓取 MergeHosts.sh 中用到的两个远程 hosts 源（GITHUB520_URL / STEAM_HOSTS_URL），
#       提取其中的域名，生成 Domains_Remote.json。
#       文件格式与 Domains.json 保持一致：{ "分组名": ["域名", ...], ... }
#       GitHub520 的域名排在前面，SteamHostSync 的域名排在后面。
#
# 用法： ./FetchRemoteDomains.sh [输出文件]
#        输出文件默认 Domains_Remote.json
#
# 环境变量（可选覆盖）：
#   GITHUB520_URL      GitHub520 hosts 地址
#   STEAM_HOSTS_URL    SteamHostSync hosts 地址
#   GITHUB520_GROUP    第一个分组名（默认 Group1_GitHub520）
#   STEAM_GROUP        第二个分组名（默认 Group2_SteamHostSync）
#   GH_PROXY           GitHub 加速镜像前缀，如 https://ghproxy.top/。
#                      设置后先走镜像，镜像失败自动回退直连；不设置则直接连接。
#                      GitHub Actions 官方 runner 直连通常没问题，自托管 runner
#                      或网络受限环境下可设此项提速。
#
set -euo pipefail

OUTPUT_FILE="${1:-Domains_Remote.json}"

# 输出目录预检：目录不存在时提前给出明确错误，避免重定向失败被静默吞掉
_out_dir="$(dirname "$OUTPUT_FILE")"
if [[ ! -d "$_out_dir" ]]; then
  echo "错误: 输出目录不存在: $_out_dir" >&2
  exit 1
fi

GITHUB520_URL="${GITHUB520_URL:-https://raw.githubusercontent.com/521xueweihan/GitHub520/refs/heads/main/hosts}"
STEAM_HOSTS_URL="${STEAM_HOSTS_URL:-https://raw.githubusercontent.com/Clov614/SteamHostSync/refs/heads/main/Hosts}"
GITHUB520_GROUP="${GITHUB520_GROUP:-Group1_GitHub520}"
STEAM_GROUP="${STEAM_GROUP:-Group2_SteamHostSync}"

# ---------------------------------------------------------------- 环境自检
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "错误: 需要 bash 4.0 及以上版本（当前: ${BASH_VERSION:-未知}），请用 bash 而非 sh 执行" >&2
  exit 1
fi

missing=()
for bin in jq curl awk sed tr grep mktemp; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  echo "错误: 缺少依赖: ${missing[*]}" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

GH_HOSTS="$TMP_DIR/github520.hosts"
ST_HOSTS="$TMP_DIR/steam.hosts"
: > "$GH_HOSTS"
: > "$ST_HOSTS"

# ---------------------------------------------------------------- 下载远程 hosts
# curl 通用选项：--retry-all-errors 需 curl 7.71+，老版本上自动降级为普通重试
CURL_OPTS=(-fsSL --retry 3 --retry-delay 2 --max-time 30)
if curl --help all 2>/dev/null | grep -q 'retry-all-errors'; then
  CURL_OPTS+=(--retry-all-errors)
fi

# 先尝试 GH_PROXY 镜像（若设置），失败自动回退直连；结果为空也视为失败
fetch_url() {
  local url="$1" dest="$2" name="$3"
  local -a candidates=()
  if [[ -n "${GH_PROXY:-}" ]]; then
    candidates+=("${GH_PROXY%/}/${url}")
  fi
  candidates+=("$url")
  local u
  for u in "${candidates[@]}"; do
    if curl "${CURL_OPTS[@]}" "$u" -o "$dest" && [[ -s "$dest" ]]; then
      echo "✓ 已下载 $name: $u" >&2
      return 0
    fi
  done
  echo "警告: 无法下载 $name，该分组将为空: $url" >&2
  : > "$dest"
  return 1
}

gh_ok=0
st_ok=0
if fetch_url "$GITHUB520_URL" "$GH_HOSTS" "GitHub520 hosts"; then gh_ok=1; fi
if fetch_url "$STEAM_HOSTS_URL" "$ST_HOSTS" "SteamHostSync hosts"; then st_ok=1; fi

if (( gh_ok == 0 && st_ok == 0 )); then
  echo "错误: 两个远程 hosts 均下载失败，终止" >&2
  exit 1
fi

# ---------------------------------------------------------------- 提取域名
# 规则（与 MergeConfig.sh 一致并加固）：
#   1. 丢弃注释行与空行；
#   2. 取该行最后一个字段作为域名（兼容单空格 / 多空格 / 制表符混排）；
#   3. 用域名正则过滤掉 localhost、IP、通配符等非法项；
#   4. 去重，并保留在 hosts 中首次出现的顺序。
extract_domains() {
  # 处理顺序（每一步都对应一个真实存在的畸形输入场景）：
  #   1. tr -d '\r'          —— Windows 风格的 CRLF 行尾，否则域名会带上 \r 被正则剔除
  #   2. sed 去掉 UTF-8 BOM  —— 某些编辑器保存的 hosts 文件头带 EF BB BF
  #   3. awk 剥掉 # 之后的注释 —— 兼容 "IP 域名 # 备注" 这种行内注释格式
  #   4. 取该行最后一个字段作域名（兼容单空格 / 多空格 / 制表符混排）
  #   5. 域名正则过滤 + 去重，保留在 hosts 中首次出现的顺序
  # 末尾 || true：空 hosts / 无合法域名时 grep 返回 1，避免 pipefail 下中断脚本
  tr -d '\r' < "$1" \
    | sed '1s/^\xef\xbb\xbf//' \
    | awk '{ sub(/[[:space:]]*#.*/, "") } !/^[[:space:]]*$/ && NF >= 2 { print $NF }' \
    | grep -E '^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$' \
    | awk '!seen[$0]++' || true
}

GH_DOMAINS="$(extract_domains "$GH_HOSTS")"
ST_DOMAINS="$(extract_domains "$ST_HOSTS")"

gh_count=$(printf '%s' "$GH_DOMAINS" | grep -c . || true)
st_count=$(printf '%s' "$ST_DOMAINS" | grep -c . || true)
echo "提取域名: $GITHUB520_GROUP = $gh_count 个, $STEAM_GROUP = $st_count 个" >&2

# ---------------------------------------------------------------- 生成 JSON
jq -n \
  --arg g1 "$GITHUB520_GROUP" --arg d1 "$GH_DOMAINS" \
  --arg g2 "$STEAM_GROUP" --arg d2 "$ST_DOMAINS" '
  def to_array: split("\n") | map(select(length > 0));
  {
    ($g1): ($d1 | to_array),
    ($g2): ($d2 | to_array)
  }
' > "$OUTPUT_FILE"

if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "错误: 生成的 $OUTPUT_FILE 不是有效 JSON" >&2
  exit 1
fi

echo "已生成 $OUTPUT_FILE (分组 $(jq 'length' "$OUTPUT_FILE") 个, 域名合计 $(jq '[.[] | length] | add' "$OUTPUT_FILE") 个)" >&2
