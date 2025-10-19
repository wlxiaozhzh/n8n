#!/usr/bin/env bash
set -euo pipefail

# === 基本信息 ===
PROJECT_DIR="/Users/renzhiqiang/orb-n8n"
TAG_DATE=$(date +%F)
TAG_NAME="release-${TAG_DATE}"
TAG_MESSAGE="稳定版 ${TAG_DATE} 初始化"

echo "🌀 初始化 orb-n8n Git 仓库..."
cd "$PROJECT_DIR"

# 检查是否已有 .git
if [ -d ".git" ]; then
  echo "✅ 已存在 Git 仓库，跳过初始化。"
else
  git init
  echo "✅ 已创建新的 Git 仓库。"
fi

# 添加常见配置文件
FILES_TO_TRACK=(docker-compose.yml .env .env.example README.md)
for f in "${FILES_TO_TRACK[@]}"; do
  if [ -f "$f" ]; then
    git add "$f"
    echo "📦 已加入版本控制: $f"
  fi
done

# 检查是否已有提交
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "📝 已有提交，准备打标签..."
else
  git commit -m "init: orb-n8n baseline compose & env"
  echo "✅ 完成首次提交。"
fi

# 创建标签
if git tag -l | grep -q "$TAG_NAME"; then
  echo "⚠️ 标签 $TAG_NAME 已存在，跳过。"
else
  git tag -a "$TAG_NAME" -m "$TAG_MESSAGE"
  echo "🏷️ 已打标签：$TAG_NAME"
fi

# 打印仓库状态
echo
echo "🎯 当前仓库状态："
git --no-pager log --oneline -n 3
echo
echo "✨ 初始化完成！"
echo "下次配置修改后可执行以下命令保存版本："
echo "  git add . && git commit -m 'update: 变更描述'"
echo "  git tag -a release-\$(date +%F) -m '稳定版'"
echo
echo "可随时回滚："
echo "  git checkout release-YYYY-MM-DD -- docker-compose.yml .env"

