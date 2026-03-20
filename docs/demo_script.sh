#!/bin/bash
# Demo script for asciinema recording

type_cmd() {
    echo ""
    for ((i=0; i<${#1}; i++)); do
        printf '%s' "${1:$i:1}"
        sleep 0.04
    done
    echo ""
    sleep 0.3
    eval "$1"
    sleep 2
}

clear
echo ""
echo "  cc-statistics — Claude Code Session Statistics"
echo ""
sleep 1.5

type_cmd "cc-stats --last 1"
sleep 2

type_cmd "cc-stats --compare --since 1w"
sleep 2

type_cmd "cc-stats --report week | head -30"
sleep 2

echo ""
echo "  pip install cc-statistics"
echo "  github.com/androidZzT/cc-statistics"
echo ""
sleep 3
