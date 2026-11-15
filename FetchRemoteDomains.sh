#!/usr/bin/env bash
#
# FetchRemoteDomains.sh
#
# 作用：按源配置文件声明的远程 hosts 源逐个抓取、提取域名，生成 Domains_Remote.json。
#       输出格式与 Domains.json 保持一致：{ "分组名": ["域名", ...], ... }
#       分组顺序 = 源配置文件 sources 数组的顺序，分组数量不限。
#
# 用法： ./FetchRemoteDomains.sh [输出文件] [源配置文件]
#        输出文件默认 Domains_Remote.json
#        源配置文件默认 RemoteSources.json（也可用 REMOTE_SOURCES_CONFIG 环境变量指定）
#
# 源配置文件结构（RemoteSources.json）：
#   {
#     "proxy": "https://gh-proxy.org/",
#     "sources": [
#       {
#         "group":   "Group1_GitHub520",
#         "name":    "GitHub520 hosts",
#         "url":     "https://raw.githubusercontent.com/521xueweihan/GitHub520/refs/heads/main/hosts",
#         "enabled": true
#       }
#     ]
#   }
#
# 字段说明：
#   proxy     可选。GitHub 加速镜像前缀（如 https://gh-proxy.org/），留空或缺省为直连。
#             镜像失败会自动回退直连；环境变量 GH_PROXY 优先级更高。
#   sources   必填。数组，顺序即输出分组顺序，可任意增减条目。
#   group     必填。输出 JSON 的分组名，启用项之间不可重复。
#   name      可选。日志显示名，缺省取 group。
#   url       必填。hosts 文件地址；可写字符串，也可写字符串数组提供多个备用地址
#             （字段名写成 urls 亦可）。
#   enabled   可选。默认 true；设为 false 时跳过该源（不产生对应分组）。
#
# 扩展方式：新增一个远程源，只需在 sources 数组里追加一项，脚本无需任何改动。
#
# 环境变量（可选覆盖）：
#   GH_PROXY               GitHub 加速镜像前缀，覆盖配置文件中的 proxy；
#                          显式置为空字符串可强制直连。GitHub Actions 官方 runner
#                          直连通常没问题，自托管 runner 或网络受限环境可临时设此项。
#   REMOTE_SOURCES_CONFIG  指定源配置文件（等价于第二个命令行参数）
#
# 下载策略：候选地址按「每个 url 的镜像版 → 原始版」依次尝试；
#           下载成功但内容中没有合法域名同样视为失败并继续尝试下一个候选。
#           全部源都失败时终止且不会覆盖已有输出文件。
#
set -euo pipefail

die() { echo "错误: $*" >&2; exit 1; }

OUTPUT_FILE="${1:-Domains_Remote.json}"
CONFIG_FILE="${2:-${REMOTE_SOURCES_CONFIG:-RemoteSources.json}}"

# 输出目录预检：目录不存在时提前给出明确错误，避免重定向失败被静默吞掉
_out_dir="$(dirname "$OUTPUT_FILE")"
[[ -d "$_out_dir" ]] || die "输出目录不存在: $_out_dir"
[[ -f "$CONFIG_FILE" ]] || die "找不到源配置文件: $CONFIG_FILE"
[[ "$OUTPUT_FILE" != "$CONFIG_FILE" ]] || die "输出文件不能与源配置文件相同: $CONFIG_FILE"

# ---------------------------------------------------------------- 环境自检
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  die "需要 bash 4.0 及以上版本（当前: ${BASH_VERSION:-未知}），请用 bash 而非 sh 执行"
fi

missing=()
for bin in jq curl awk sed tr grep mktemp cat; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  die "缺少依赖: ${missing[*]}"
fi

# ---------------------------------------------------------------- 校验源配置
# 所有 jq 读文件统一走标准输入重定向：文件名由 shell 解析，避免 Git Bash + MSYS2
# 这类混合环境下 jq 自身对 /tmp、盘符路径的解析差异。
jq empty < "$CONFIG_FILE" 2>/dev/null || die "源配置文件不是有效 JSON: $CONFIG_FILE"

# 一次性校验结构：顶层对象、proxy 为字符串、sources 非空数组、
# 每项为对象且 group 非空、url/urls 为非空字符串或非空字符串数组、
# enabled / name 类型正确。校验失败统一给出提示，字段含义见文件头。
if ! jq -e '
  (type == "object")
  and (((.proxy // "") | type) == "string")
  and ((.sources | type) == "array")
  and ((.sources | length) > 0)
  and (all(.sources[];
        (type == "object")
        and (((.group // null) | type) == "string")
        and (((.group // "") | length) > 0)
        and (((.enabled // true) | type) == "boolean")
        and (((.name // "") | type) == "string")
        and ((.url // .urls // null) as $u
          | ($u != null)
          and (((($u | type) == "string") and (($u | length) > 0))
            or ((($u | type) == "array") and (($u | length) > 0)
                and (all($u[]; (type == "string") and (length > 0))))))
      ))
' < "$CONFIG_FILE" >/dev/null 2>&1; then
  die "源配置文件结构不合法：$CONFIG_FILE（需含 sources 数组，每项需有非空 group 与 url/urls）"
fi

# 同一个分组名出现两次会让输出 JSON 的键互相覆盖，只检查实际启用的源
if ! jq -e '
  [.sources[] | select(.enabled != false) | .group] | length == (unique | length)
' < "$CONFIG_FILE" >/dev/null 2>&1; then
  die "源配置文件中存在重复的 group 分组名: $CONFIG_FILE"
fi

PROXY="$(jq -r '.proxy // ""' < "$CONFIG_FILE")"
# 环境变量优先；用 ${VAR-DEFAULT} 而非 ${VAR:-DEFAULT}，允许以空字符串显式禁用代理
PROXY="${GH_PROXY-$PROXY}"
if [[ -n "$PROXY" ]]; then
  echo "GitHub 加速镜像: ${PROXY%/}/（失败自动回退直连）" >&2
fi

SOURCE_COUNT=$(jq '.sources | length' < "$CONFIG_FILE")
echo "已载入源配置: $CONFIG_FILE ($SOURCE_COUNT 个源)" >&2

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR" 2>/dev/null || true' EXIT
HOSTS_DIR="$TMP_DIR/hosts"
GROUP_DIR="$TMP_DIR/groups"
mkdir -p "$HOSTS_DIR" "$GROUP_DIR"

# ---------------------------------------------------------------- 下载远程 hosts
# curl 通用选项：--retry-all-errors 需 curl 7.71+，老版本上自动降级为普通重试
CURL_OPTS=(-fsSL --retry 3 --retry-delay 2 --max-time 30)
if curl --help all 2>/dev/null | grep -q 'retry-all-errors'; then
  CURL_OPTS+=(--retry-all-errors)
fi

# ---------------------------------------------------------------- 提取域名
# 规则（与 BuildHosts.sh / BuildConfig.sh 一致并加固）：
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

ok_sources=0
fail_sources=0

for (( i = 0; i < SOURCE_COUNT; i++ )); do
  enabled="$(jq -r --argjson i "$i" '(.sources[$i].enabled != false)' < "$CONFIG_FILE")"
  if [[ "$enabled" != "true" ]]; then
    echo "⊘ 跳过未启用源 #$((i + 1)): $(jq -r --argjson i "$i" '.sources[$i].group' < "$CONFIG_FILE")" >&2
    continue
  fi

  group="$(jq -r --argjson i "$i" '.sources[$i].group' < "$CONFIG_FILE")"
  name="$(jq -r --argjson i "$i" '(.sources[$i].name // .sources[$i].group)' < "$CONFIG_FILE")"

  # url 既可以是单个字符串，也可以是备用地址数组；统一展开成候选地址
  mapfile -t urls < <(jq -r --argjson i "$i" '
    .sources[$i] as $s
    | ($s.url // $s.urls) as $u
    | if ($u | type) == "array" then $u[] else $u end
  ' < "$CONFIG_FILE")

  # 每个地址先试镜像、再试直连；地址之间保持配置中的先后顺序
  candidates=()
  for url in "${urls[@]}"; do
    if [[ -n "$PROXY" ]]; then
      candidates+=("${PROXY%/}/${url}")
    fi
    candidates+=("$url")
  done

  dest="$HOSTS_DIR/$i.hosts"
  : > "$dest"
  domains=""
  for u in "${candidates[@]}"; do
    if curl "${CURL_OPTS[@]}" "$u" -o "$dest" 2>/dev/null && [[ -s "$dest" ]]; then
      domains="$(extract_domains "$dest")"
      if [[ -n "$domains" ]]; then
        echo "✓ 已下载 $name: $u" >&2
        break
      fi
      echo "警告: $name 的内容中未提取到合法域名，尝试下一个地址: $u" >&2
    fi
    domains=""
  done

  count=$(printf '%s' "$domains" | grep -c . || true)
  if [[ -n "$domains" ]]; then
    ok_sources=$((ok_sources + 1))
  else
    fail_sources=$((fail_sources + 1))
    echo "警告: 无法获取 $group 的有效域名，该分组将为空" >&2
  fi
  echo "  $group: $count 个域名" >&2

  # 每个源单独产出一个 JSON 片段，文件名带序号保证合并顺序 = 配置顺序
  jq -n --arg g "$group" --arg d "$domains" '
    def to_array: split("\n") | map(select(length > 0));
    { ($g): ($d | to_array) }
  ' > "$GROUP_DIR/$(printf '%04d' "$i").json"
done

if (( ok_sources == 0 && fail_sources == 0 )); then
  die "源配置文件中没有启用的源: $CONFIG_FILE"
fi
if (( ok_sources == 0 )); then
  die "所有启用的远程 hosts 均下载失败，终止（未覆盖 $OUTPUT_FILE）"
fi

# ---------------------------------------------------------------- 生成 JSON
shopt -s nullglob
group_files=("$GROUP_DIR"/*.json)
shopt -u nullglob
if (( ${#group_files[@]} == 0 )); then
  echo '{}' > "$OUTPUT_FILE"
else
  # 通过管道把所有片段喂给 jq，jq 只读 stdin、不解析文件路径
  cat "${group_files[@]}" | jq -s 'add' > "$OUTPUT_FILE"
fi

if ! jq empty < "$OUTPUT_FILE" 2>/dev/null; then
  die "生成的 $OUTPUT_FILE 不是有效 JSON"
fi

echo "已生成 $OUTPUT_FILE (源成功 $ok_sources / 失败 $fail_sources, 分组 $(jq 'length' < "$OUTPUT_FILE") 个, 域名合计 $(jq '[.[] | length] | add // 0' < "$OUTPUT_FILE") 个)" >&2
