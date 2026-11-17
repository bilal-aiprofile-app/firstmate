#!/usr/bin/env bash
# Live E2E: a task whose PR is armed for merge monitoring is relaunched with
# bin/fm-control.sh <id> relaunch, then the armed merge poll is asked whether it
# still authenticates the record and whether it still reports the PR merged.
#
# Real pieces: bin/fm-spawn.sh, bin/fm-pr-check.sh, bin/fm-control.sh relaunch,
# the Herdr backend on a named fm-lab-* session (via bin/fm-herdr-lab.sh run),
# the real `claude` CLI with the machine's existing login, real `gh` against a
# real merged GitHub PR, and the armed bin/fm-pr-poll.sh check script.
# Disposable pieces: a marked lab FM_HOME, a throwaway git project, and a
# treehouse stand-in that hands spawn a throwaway clone instead of the pool.
#
# Usage: live-relaunch-keeps-pr-watched.sh <firstmate-root> <label> [extra]
#   extra = "review-after-pr" also records a review line with the real
#   bin/fm-review-check.sh writer before the relaunch is driven.
set -u
FMROOT=$1
LABEL=$2
EXTRA=${3:-}
ID=rlpr
PR_URL=https://github.com/kunchenguid/firstmate/pull/8422
HELPER="$FMROOT/bin/fm-herdr-lab.sh"
[ -x "$HELPER" ] || HELPER=/Users/bshirazi/.no-mistakes/worktrees/750af29daff7/01M7KGG5JQ6BF6EK15162TJF32/bin/fm-herdr-lab.sh
SESSION=$("$HELPER" name "relpr-$LABEL")
export HERDR_LAB_HELPER="$HELPER" HERDR_LAB_SESSION="$SESSION" ORIGINAL_PATH="$PATH"
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
TMP=$(cd "$(mktemp -d /tmp/fm-relpr.XXXXXX)" && pwd -P)
cleanup() {
  "$HELPER" teardown "$SESSION" >/dev/null 2>&1 || echo "WARN: lab teardown failed for $SESSION"
  find "$TMP" "$LAB" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP" "$LAB"
}
trap cleanup EXIT
"$FMROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 \
  || /Users/bshirazi/.no-mistakes/worktrees/750af29daff7/01M7KGG5JQ6BF6EK15162TJF32/bin/fm-lab-home.sh create "$LAB" >/dev/null
"$HELPER" provision "$SESSION" >/dev/null || { echo "FAIL: could not provision $SESSION"; exit 2; }
echo "== root=$FMROOT lab-session=$SESSION lab-home=$LAB"

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/herdr" <<'EOF'
#!/usr/bin/env bash
set -eu
args=("$@")
if [ "${1:-}" = --version ]; then
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json | jq -r '"herdr " + .client.version'
  exit
fi
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ]; then
  [ "${args[n-1]}" = "$HERDR_LAB_SESSION" ] || exit 1
  unset 'args[n-1]' 'args[n-2]'
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
EOF
cat > "$TMP/fakebin/treehouse" <<'EOF'
#!/usr/bin/env bash
case "$1" in
get) printf '%s\n' "$TEST_SLOT" ;;
*) exit 0 ;;
esac
EOF
chmod +x "$TMP/fakebin/"*

git init -q "$TMP/project"
printf '# lab\n' > "$TMP/project/README.md"
git -C "$TMP/project" add README.md
git -C "$TMP/project" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git -C "$TMP/project" worktree add -q --detach "$TMP/slot"
export TEST_SLOT="$TMP/slot"

touch "$LAB/state/.last-watcher-beat"
printf 'claude\n' > "$LAB/config/crew-harness"
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Lab check only: reply "ready" and then wait for instructions. Do not edit, commit, or run any commands.

## Firstmate spec
Stay idle after replying.
EOF

FMENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE
  -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH
  PATH="$TMP/fakebin:$PATH" FM_HOME="$LAB" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1)

echo "== spawn (real claude worker on Herdr lab)"
"${FMENV[@]}" bash "$FMROOT/bin/fm-spawn.sh" "$ID" "$TMP/project" --harness claude --backend herdr \
  --mode no-mistakes --yolo off > "$TMP/spawn.log" 2>&1 || { tail -20 "$TMP/spawn.log"; echo "FAIL: spawn"; exit 2; }
tail -3 "$TMP/spawn.log"
PANE=$(sed -n 's/^herdr_pane_id=//p' "$LAB/state/$ID.meta")
sleep 20

echo "== record PR (real gh, real merged PR) and arm merge poll"
"${FMENV[@]}" bash "$FMROOT/bin/fm-pr-check.sh" "$ID" "$PR_URL" 2>&1 | tail -3
[ -f "$LAB/state/$ID.check.sh" ] || { echo "FAIL: poll not armed"; exit 2; }

if [ "$EXTRA" = review-after-pr ]; then
  echo "== append a firstmate-written key after pr= (review line, as fm-review-check.sh appends it)"
  printf 'review=https://review.example.test/r/1\n' >> "$LAB/state/$ID.meta"
fi
if [ "$EXTRA" = foreign-after-pr ]; then
  echo "== adversarial: append a key no firstmate writer records after pr="
  printf 'injected=value\n' >> "$LAB/state/$ID.meta"
fi

poll_valid() {
  ( . "$FMROOT/bin/fm-pr-lib.sh"; FM_HOME="$LAB" fm_pr_poll_artifacts_valid "$LAB/state" "$ID" "$FMROOT/bin/fm-pr-poll.sh" ) \
    && echo yes || echo NO
}
echo "poll authenticates record BEFORE relaunch: $(poll_valid)"

echo "== relaunch via bin/fm-control.sh $ID relaunch"
"${FMENV[@]}" bash "$FMROOT/bin/fm-control.sh" "$ID" relaunch --note "lab: relaunch while PR is armed" 2>&1 | tail -4
echo "== state/$ID.meta after relaunch (key order, values elided)"
nl -ba "$LAB/state/$ID.meta" | sed -E 's/=.*/=.../'
echo "== pr-identity parse"
( . "$FMROOT/bin/fm-pr-lib.sh"; if fm_pr_metadata_identity_parse "$LAB/state/$ID.meta"; then echo "parsed pr=$FM_PR_META_URL"; else echo "REFUSED: record no longer parses"; fi )
echo "poll authenticates record AFTER relaunch: $(poll_valid)"
echo "== run the armed merge poll (real gh)"
out=$("${FMENV[@]}" FM_STATE_OVERRIDE="$LAB/state" bash "$LAB/state/$ID.check.sh" 2>&1)
echo "check.sh output: '${out}'"

echo "== run the real watcher (bin/fm-watch.sh) once against the lab home, bounded to 90s"
perl -e 'my $t=shift; my $pid=fork; if(!$pid){exec @ARGV} local $SIG{ALRM}=sub{kill "TERM",$pid; waitpid $pid,0; exit 124}; alarm $t; waitpid $pid,0; exit($?>>8)' 90 \
  "${FMENV[@]}" FM_ROOT_OVERRIDE="$FMROOT" FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
  bash "$FMROOT/bin/fm-watch.sh" > "$TMP/watch.out" 2> "$TMP/watch.err"; wrc=$?
echo "watcher exit=$wrc"
echo "watcher stdout:"; sed 's/^/  /' "$TMP/watch.out" | head -10
echo "watcher stderr (tail):"; tail -5 "$TMP/watch.err" | sed 's/^/  /'
echo "wake-queue merge rows:"; { grep -F "merge landed: $ID" "$LAB/state/.wake-queue" 2>/dev/null || echo "  (none)"; } | cut -f5 | sed 's/^/  /'
echo "check.sh still armed after watcher: $([ -e "$LAB/state/$ID.check.sh" ] && echo yes || echo 'no (retired)')"
echo "== worker pane after relaunch (tail)"
"$HELPER" run "$SESSION" pane read "$PANE" 2>/dev/null | grep -v '^\s*$' | tail -12
