#!/usr/bin/env bash
set -euo pipefail

HOSTS_FILE="${1:-hosts_520_Clov}"
CONFIG_URL="https://raw.githubusercontent.com/SniShaper/lumine-for-android/refs/heads/main/android/app/src/main/assets/config_default.json"
OUTPUT_FILE="config_ngdngdc.json"

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "错误: 找不到 hosts 文件: $HOSTS_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "错误: 需要安装 jq" >&2
  exit 1
fi

# 下载原始配置文件
TMP_CONFIG=$(mktemp)
trap 'rm -f "$TMP_CONFIG"' EXIT

echo "下载原始配置文件..." >&2
curl -fsSL --retry 3 "$CONFIG_URL" -o "$TMP_CONFIG"

# 验证 JSON 合法性
if ! jq empty "$TMP_CONFIG" 2>/dev/null; then
  echo "错误: 下载的配置文件不是有效 JSON" >&2
  exit 1
fi

# 从 hosts 文件中提取所有域名（兼容单空格、多空格、制表符等混合格式）
# 排除注释行、空行、纯 IP 行；取每行最后一个字段作为域名
DOMAINS=$(awk '!/^[[:space:]]*#/ && NF>=2 {print $NF}' "$HOSTS_FILE" | sort -u)

if [[ -z "$DOMAINS" ]]; then
  echo "警告: 未从 hosts 文件中提取到任何域名" >&2
  cp "$TMP_CONFIG" "$OUTPUT_FILE"
  echo "已保存原始配置至 $OUTPUT_FILE" >&2
  exit 0
fi

DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l | tr -d ' ')
echo "共提取到 $DOMAIN_COUNT 个唯一域名" >&2

# 构建待追加的 domain_policies 条目（JSON 对象数组）
NEW_ENTRIES=$(echo "$DOMAINS" | jq -Rn '[inputs | {key: ., value: {"mode": "tls-rf", "dns_mode": "prefer_ipv6"}}]')

# 将新条目合并到 domain_policies 末尾，保持原有顺序
jq --argjson new "$NEW_ENTRIES" '
  .domain_policies = (.domain_policies + ($new | from_entries))
' "$TMP_CONFIG" > "$OUTPUT_FILE"

# 验证输出 JSON 合法性
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
  echo "错误: 生成的配置文件不是有效 JSON" >&2
  exit 1
fi

FINAL_COUNT=$(jq '.domain_policies | length' "$OUTPUT_FILE")
echo "合并完成: $OUTPUT_FILE (domain_policies 共 $FINAL_COUNT 条)" >&2