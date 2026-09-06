#!/usr/bin/env bash
set -euo pipefail

# 输出文件路径
OUTPUT_FILE="hosts_520_Clov"

# 本仓库 hosts 文件路径
LOCAL_HOSTS="hosts"

# 远程 hosts 文件 URL（按合并顺序排列）
GITHUB520_URL="https://raw.githubusercontent.com/521xueweihan/GitHub520/refs/heads/main/hosts"
STEAM_HOSTS_URL="https://raw.githubusercontent.com/Clov614/SteamHostSync/refs/heads/main/Hosts"

# 检查本地 hosts 文件是否存在
if [[ ! -f "$LOCAL_HOSTS" ]]; then
  echo "错误: 找不到本仓库 hosts 文件: $LOCAL_HOSTS" >&2
  exit 1
fi

# 创建临时目录用于安全下载
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "开始合并 hosts 文件..." >&2

# 1. 首先写入本仓库 hosts 内容
cp "$LOCAL_HOSTS" "$OUTPUT_FILE"
echo "✓ 已添加本仓库 hosts 文件内容" >&2

# 2. 追加 GitHub520 hosts
echo "" >> "$OUTPUT_FILE"
echo "# ========================================" >> "$OUTPUT_FILE"
echo "# Merged from: GitHub520" >> "$OUTPUT_FILE"
echo "# Source: $GITHUB520_URL" >> "$OUTPUT_FILE"
echo "# ========================================" >> "$OUTPUT_FILE"
if curl -fsSL --retry 3 --retry-delay 2 "$GITHUB520_URL" -o "$TMP_DIR/github520_hosts"; then
  cat "$TMP_DIR/github520_hosts" >> "$OUTPUT_FILE"
  echo "✓ 已追加 GitHub520 hosts 内容" >&2
else
  echo "警告: 无法下载 GitHub520 hosts，跳过该部分" >&2
fi

# 3. 追加 SteamHostSync Hosts
echo "" >> "$OUTPUT_FILE"
echo "# ========================================" >> "$OUTPUT_FILE"
echo "# Merged from: SteamHostSync" >> "$OUTPUT_FILE"
echo "# Source: $STEAM_HOSTS_URL" >> "$OUTPUT_FILE"
echo "# ========================================" >> "$OUTPUT_FILE"
if curl -fsSL --retry 3 --retry-delay 2 "$STEAM_HOSTS_URL" -o "$TMP_DIR/steam_hosts"; then
  cat "$TMP_DIR/steam_hosts" >> "$OUTPUT_FILE"
  echo "✓ 已追加 SteamHostSync Hosts 内容" >&2
else
  echo "警告: 无法下载 SteamHostSync Hosts，跳过该部分" >&2
fi

echo "合并完成，输出文件: $OUTPUT_FILE" >&2
echo "文件大小: $(wc -c < "$OUTPUT_FILE") bytes, 行数: $(wc -l < "$OUTPUT_FILE")" >&2