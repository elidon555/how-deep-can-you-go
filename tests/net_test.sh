#!/usr/bin/env bash
# Online co-op test: a host and a client, two headless game processes talking over localhost.
# The host prints the results (and exits non-zero if anything failed).
cd "$(dirname "$0")/.."
PORT=${PORT:-24711}
OUT=$(mktemp -d)
nice godot --headless --path . res://tests/net_test.tscn -- --role=host --port=$PORT >"$OUT/host.log" 2>&1 &
HOST=$!
sleep 1
nice godot --headless --path . res://tests/net_test.tscn -- --role=client --port=$PORT >"$OUT/client.log" 2>&1 &
CLIENT=$!
wait $HOST
STATUS=$?
sleep 1
kill $CLIENT 2>/dev/null
grep -E "PASS|FAIL|RESULT|SCRIPT ERROR|ERROR" "$OUT/host.log"
if grep -q "SCRIPT ERROR" "$OUT/client.log"; then
	echo "--- client errors:"
	grep -A3 "SCRIPT ERROR" "$OUT/client.log" | head -40
fi
echo "(logs in $OUT)"
exit $STATUS
