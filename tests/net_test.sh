#!/usr/bin/env bash
# Online co-op test: a host and two clients (one joins mid-run), separate game processes
# talking over localhost. The host prints the results (and exits non-zero if anything failed).
# SHOTS=dir also renders offscreen (xvfb) and saves what the clients see there.
cd "$(dirname "$0")/.."
PORT=${PORT:-24711}
OUT=$(mktemp -d)
run() {
	if [ -n "$SHOTS" ]; then
		mkdir -p "$SHOTS"
		timeout 240 xvfb-run -a nice godot --path . --rendering-driver opengl3 --audio-driver Dummy res://tests/net_test.tscn -- "$@" --shots="$SHOTS"
	else
		timeout 240 nice godot --headless --path . res://tests/net_test.tscn -- "$@"
	fi
}
run --role=host --port=$PORT >"$OUT/host.log" 2>&1 &
HOST=$!
sleep 1
run --role=client --port=$PORT >"$OUT/client.log" 2>&1 &
CLIENT=$!
run --role=client --port=$PORT --delay=20 >"$OUT/client2.log" 2>&1 &
CLIENT2=$!
wait $HOST
STATUS=$?
sleep 1
kill $CLIENT $CLIENT2 2>/dev/null
grep -E "PASS|FAIL|RESULT|SCRIPT ERROR|ERROR" "$OUT/host.log"
for c in client client2; do
	if grep -q "SCRIPT ERROR" "$OUT/$c.log"; then
		echo "--- $c errors:"
		grep -A3 "SCRIPT ERROR" "$OUT/$c.log" | head -40
	fi
done
echo "(logs in $OUT)"
exit $STATUS
