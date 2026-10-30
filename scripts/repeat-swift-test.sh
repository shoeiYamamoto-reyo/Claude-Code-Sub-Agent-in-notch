#!/bin/sh
# `swift test` を続けて流し、落ちた回のログを残す（ROADMAP 5-11）。
#
#   scripts/repeat-swift-test.sh [回数]   # 既定は 20 回
#
# 1 回目の前に notch-hook とテストを作り直し、「ビルド直後の初回」も含める。
# ログは .build/repeat-test/<回>.log に置き、最後に落ちた回と落ちたテストの名前を出す。
set -u
count=${1:-20}
logs=.build/repeat-test
mkdir -p "$logs"
rm -f "$logs"/*.log

# 実行ファイルを作り直す（初回の起動時の検査も毎回の 1 回目に含める）。
touch Sources/notch-hook/*.swift
swift build --build-tests >/dev/null || exit 1

failed=0
i=1
while [ "$i" -le "$count" ]; do
    if swift test >"$logs/$i.log" 2>&1; then
        printf '%2d: ok\n' "$i"
    else
        failed=$((failed + 1))
        printf '%2d: 失敗（%s）\n' "$i" "$logs/$i.log"
        grep -E "error: |failed \(" "$logs/$i.log" | sed 's/^/      /' | head -10
    fi
    i=$((i + 1))
done
echo "$count 回中 $failed 回失敗"
[ "$failed" -eq 0 ]
