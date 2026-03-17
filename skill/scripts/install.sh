#!/usr/bin/env bash
set -e

if command -v cc-stats &>/dev/null; then
    echo "cc-stats 已安装: $(cc-stats --version 2>/dev/null || echo 'ok')"
    exit 0
fi

echo "正在安装 cc-statistics..."
pip install cc-statistics 2>/dev/null || pip3 install cc-statistics
echo "安装完成"
