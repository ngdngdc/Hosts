#!/usr/bin/env bash
#
# BuildHosts.sh
#
# 作用：读取 Domains.json 与 Domains_Remote.json 两个分组域名文件，
#       参考 GetIP.sh 的实现逐个解析 AAAA / A 记录，直接生成 hosts_520_Clov。
#       Domains.json 的分组在前，Domains_Remote.json 的分组在后；不再生成 hosts 文件。
#
# 用法： ./BuildHosts.sh [Domains.json] [Domains_Remote.json] [输出文件]
#
# 环境变量（可选）：
#   JOBS=8             并发解析进程数（设为 1 即串行，行为与原 GetIP.sh 一致）
#   SKIP_DUPLICATE=1   重复域名只保留首次出现位置（默认开启，设为 0 关闭）
#
set -euo pipefail

LOCAL_DOMAINS_FILE="${1:-Domains.json}"
REMOTE_DOMAINS_FILE="${2:-Domains_Remote.json}"
OUTPUT_FILE="${3:-hosts_520_Clov}"

# 输出目录预检：目录不存在时提前给出明确错误，避免重定向失败被静默吞掉
_out_dir="$(dirname "$OUTPUT_FILE")"
if [[ ! -d "$_out_dir" ]]; then
  echo "错误: 输出目录不存在: $_out_dir" >&2
  exit 1
fi
JOBS="${JOBS:-8}"
SKIP_DUPLICATE="${SKIP_DUPLICATE:-1}"

# JOBS 必须是正整数：非法值（含 abc 这类会让 set -u 报 unbound variable 的字符串）
# 一律回退为默认并发度，避免脚本在 CI 里因环境变量写错而崩掉。
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "警告: JOBS='$JOBS' 不是正整数，回退为 8" >&2
  JOBS=8
fi
if ! [[ "$SKIP_DUPLICATE" =~ ^[01]$ ]]; then
  echo "警告: SKIP_DUPLICATE='$SKIP_DUPLICATE' 只能是 0 或 1，回退为 1" >&2
  SKIP_DUPLICATE=1
fi

# ---------------------------------------------------------------- 环境自检
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  echo "错误: 需要 bash 4.0 及以上版本（当前: ${BASH_VERSION:-未知}），请用 bash 而非 sh 执行" >&2
  exit 1
fi

missing=()
for bin in jq awk grep sed mktemp xargs; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  echo "错误: 缺少依赖: ${missing[*]}" >&2
  exit 1
fi

# ---------------------------------------------------------------- DNS 解析器
# 优先使用 dig（与 GetIP.sh 一致）；若系统无 dig（如精简版 Linux 容器）则回退 python3。
if command -v dig >/dev/null 2>&1; then
  RESOLVER="dig"
elif command -v python3 >/dev/null 2>&1; then
  RESOLVER="python3"
  echo "警告: 系统无 dig，回退使用 python3 解析（建议安装 dnsutils）" >&2
else
  echo "错误: 缺少 DNS 解析工具，需要 dig 或 python3" >&2
  exit 1
fi
echo "DNS 解析器: $RESOLVER" >&2

# ---------------------------------------------------------------- 读入分组清单
# plan.tsv 每行： "#\t组名" 或 "D\t域名"，顺序即最终 hosts 的顺序。
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PLAN="$TMP_DIR/plan.tsv"
: > "$PLAN"

append_plan() {
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
  jq -r 'to_entries[] | ("#\t" + .key), (.value[] | "D\t" + .)' "$file" >> "$PLAN"
  echo "✓ 已载入 $label: $file ($(jq '[.[] | length] | add' "$file") 个域名, $(jq 'length' "$file") 个分组)" >&2
}

append_plan "$LOCAL_DOMAINS_FILE" "本地分组"
append_plan "$REMOTE_DOMAINS_FILE" "远程分组"

if [[ ! -s "$PLAN" ]]; then
  echo "错误: 未从任何域名分组文件中读到内容" >&2
  exit 1
fi

# ---------------------------------------------------------------- 并发解析
# 先对域名去重，避免同一域名重复发起解析。
# 结果文件以「序号」而非「域名」命名：域名最长可达 253 字符，加上后缀会突破
# ext4/overlayfs 的 255 字节文件名上限，导致长域名静默解析失败。
mkdir -p "$TMP_DIR/res"
# 过滤掉空域名与非域名格式的条目（JSON 里的 "" / null / 非法值），
# 再去重。空域名若进入队列会浪费一次解析，还会让统计数字偏离真实值。
awk -F'\t' '$1 == "D" && $2 != "" { print $2 }' "$PLAN" \
  | grep -E '^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$' \
  | awk '!seen[$0]++' > "$TMP_DIR/domains.txt"
awk '{ print NR "\t" $0 }' "$TMP_DIR/domains.txt" > "$TMP_DIR/tasks.tsv"
TOTAL_DOMAIN=$(grep -c . "$TMP_DIR/domains.txt" || true)
echo "待解析唯一域名: $TOTAL_DOMAIN 个 (并发度 $JOBS)" >&2

cat > "$TMP_DIR/resolve_one.sh" <<'EOS'
#!/usr/bin/env bash
# $1 = "序号\t域名"，$2 = 结果目录；产出 <序号>.v6 与 <序号>.v4
set -uo pipefail
IFS=$'\t' read -r idx domain <<< "$1"
outdir="$2"
# 注意 dig 的记录类型用 -t 显式指定：写成 "dig AAAA name" 时，若域名本身
# 与类型关键字相似会被误判，-t 形式在 BIND 9.16/9.18/9.20 上均无歧义。
if command -v dig >/dev/null 2>&1; then
  dig +short +time=3 +tries=2 -t AAAA "$domain" 2>/dev/null \
    | grep -E '^([0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:.]+$' | head -n 1 > "$outdir/$idx.v6" || true
  dig +short +time=3 +tries=2 -t A "$domain" 2>/dev/null \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1 > "$outdir/$idx.v4" || true
else
  python3 - "$domain" "$outdir" "$idx" <<'PY' || true
import socket, sys
domain, outdir, idx = sys.argv[1], sys.argv[2], sys.argv[3]
for family, suffix in ((socket.AF_INET6, "v6"), (socket.AF_INET, "v4")):
    value = ""
    try:
        for info in socket.getaddrinfo(domain, None, family):
            value = info[4][0]
            break
    except Exception:
        value = ""
    with open(f"{outdir}/{idx}.{suffix}", "w") as fh:
        fh.write(value + ("\n" if value else ""))
PY
fi
EOS
chmod +x "$TMP_DIR/resolve_one.sh"

# 域名 -> 序号 映射，供生成阶段回查
declare -A idx_of=()
while IFS=$'\t' read -r idx domain; do
  if [[ -n "${idx:-}" && -n "${domain:-}" ]]; then
    idx_of["$domain"]="$idx"
  fi
done < "$TMP_DIR/tasks.tsv"

if (( JOBS > 1 )); then
  xargs -P "$JOBS" -I{} bash "$TMP_DIR/resolve_one.sh" {} "$TMP_DIR/res" < "$TMP_DIR/tasks.tsv" >/dev/null 2>&1 || true
else
  while IFS= read -r line; do
    bash "$TMP_DIR/resolve_one.sh" "$line" "$TMP_DIR/res" >/dev/null 2>&1 || true
  done < "$TMP_DIR/tasks.tsv"
fi

# ---------------------------------------------------------------- 生成 hosts
{
  echo "# Auto-generated hosts file"
  echo "# Generated by BuildHosts.sh on $(date)"
  echo "# Source(local): $LOCAL_DOMAINS_FILE"
  echo "# Source(remote): $REMOTE_DOMAINS_FILE"
  echo "# IPv6 addresses are listed first, IPv4 as additional entries"
  echo ""
} > "$OUTPUT_FILE"

declare -A seen_domain=()
stat_v6=0
stat_v4=0
stat_fail=0
stat_dup=0
first_group=1

while IFS=$'\t' read -r kind value; do
  [[ -z "${kind:-}" ]] && continue
  if [[ "$kind" == "#" ]]; then
    if (( first_group == 0 )); then
      echo "" >> "$OUTPUT_FILE"
    fi
    first_group=0
    echo "# ===== $value =====" >> "$OUTPUT_FILE"
    echo "分组: $value" >&2
    continue
  fi

  domain="$value"
  # 空域名不能作关联数组下标（bash 会报 bad array subscript 并中断），直接跳过
  if [[ -z "$domain" ]]; then
    stat_dup=$((stat_dup + 1))
    echo "  · 跳过空域名条目" >&2
    continue
  fi
  if (( SKIP_DUPLICATE == 1 )) && [[ -n "${seen_domain[$domain]+x}" ]]; then
    stat_dup=$((stat_dup + 1))
    echo "  · 跳过重复域名: $domain" >&2
    continue
  fi
  seen_domain["$domain"]=1

  # 用 bash 内建读取，避免每条记录额外 fork 一次 cat
  idx="${idx_of[$domain]:-}"
  ipv6=""
  ipv4=""
  if [[ -n "$idx" && -f "$TMP_DIR/res/$idx.v6" ]]; then ipv6="$(<"$TMP_DIR/res/$idx.v6")"; fi
  if [[ -n "$idx" && -f "$TMP_DIR/res/$idx.v4" ]]; then ipv4="$(<"$TMP_DIR/res/$idx.v4")"; fi

  if [[ -n "$ipv6" ]]; then
    echo "$ipv6 $domain" >> "$OUTPUT_FILE"
    stat_v6=$((stat_v6 + 1))
  fi
  if [[ -n "$ipv4" ]]; then
    echo "$ipv4 $domain" >> "$OUTPUT_FILE"
    stat_v4=$((stat_v4 + 1))
  fi
  if [[ -z "$ipv6" && -z "$ipv4" ]]; then
    stat_fail=$((stat_fail + 1))
    echo "  警告: 解析失败 $domain (IPv6 与 IPv4 均无结果)" >&2
  fi
done < "$PLAN"

echo "" >> "$OUTPUT_FILE"

echo "----------------------------------------" >&2
echo "生成完成: $OUTPUT_FILE" >&2
echo "域名: 唯一 $TOTAL_DOMAIN 个 | IPv6 命中 $stat_v6 | IPv4 命中 $stat_v4 | 解析失败 $stat_fail | 重复跳过 $stat_dup" >&2
echo "行数: $(wc -l < "$OUTPUT_FILE" | tr -d ' ') | 大小: $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes" >&2
