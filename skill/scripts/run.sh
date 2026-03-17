#!/usr/bin/env bash
set -e

# 检查 cc-stats 是否可用
if ! command -v cc-stats &>/dev/null; then
    echo "cc-stats 未安装，正在安装..."
    pip install cc-statistics 2>/dev/null || pip3 install cc-statistics
fi

# 透传所有参数给 cc-stats
cc-stats "$@"
