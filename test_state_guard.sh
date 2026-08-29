#!/bin/bash
# The state-file guard from Panel.qml, verbatim. Keep the two in step.
guard() { timeout 1 sh -c 's=$(stat -Lc%s "$0" 2>/dev/null) || exit 0; [ "$s" -le 4096 ] || : > "$0"' "$1"; }

d=$(mktemp -d) && trap 'rm -rf "$d"' EXIT
fail() { echo "test_state_guard.sh: FAIL — $1"; exit 1; }

# A real state file is left alone.
printf '{"active":true,"temperature":4000}\n' > "$d/ok.json"
guard "$d/ok.json"
[ -s "$d/ok.json" ] || fail "emptied a state file under the cap"

# An oversized file is emptied, so FileView never reads it into the shell.
head -c 5000 /dev/zero > "$d/big.json"
guard "$d/big.json"
[ -s "$d/big.json" ] && fail "left an oversized file for FileView to read"

# A missing file is not created; the load falls back to defaults.
guard "$d/gone.json"
[ -e "$d/gone.json" ] && fail "created a file that was not there"

# A FIFO is left for FileView to refuse, and the guard does not hang on it.
mkfifo "$d/pipe.json"
guard "$d/pipe.json" || fail "guard blocked or failed on a FIFO"
[ -p "$d/pipe.json" ] || fail "guard touched a FIFO instead of leaving it"

echo "test_state_guard.sh: PASS"
