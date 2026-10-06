#!/usr/bin/env bash
# tests/fm-launch-secrets.test.sh - config/launch-secrets.json launches a worker
# inside a secret injector, so the named secret reaches only that worker.
#
# The spawn runs for real against a fake pane that EXECUTES the launch it is
# handed, a fake `av` injector, and a harness binary replaced by a probe that
# records the environment it started with. What the probe records is what a
# real worker would have received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-secrets)
SECRET_VALUE="sk-or-test-$$-do-not-leak"

# The fake injector mirrors `av inject +NAME... -- <command>`: it puts each
# named secret in the command's environment and runs it. FAKE_AV_MODE selects
# a refusal (an approval denied) or a slow approval (FAKE_AV_DELAY seconds).
install_fake_av() {  # <fakebin>
  cat > "$1/av" <<'SH'
#!/bin/sh
[ "${1:-}" = inject ] || exit 64
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    +*) name=${1#+}; eval "$name=\$FAKE_AV_SECRET; export $name"; shift ;;
    *) exit 64 ;;
  esac
done
case "${FAKE_AV_MODE:-grant}" in
  refuse) echo 'av: approval denied' >&2; exit 3 ;;
  slow) sleep "${FAKE_AV_DELAY:-2}" ;;
esac
exec "$@"
SH
  chmod +x "$1/av"
}

# The probe stands in for the harness. It answers the spawn's --help probe and
# otherwise records whether it started and the secret it saw.
install_probe() {  # <fakebin> <harness> <record-file>
  cat > "$1/$2" <<SH
#!/bin/sh
case "\${1:-}" in --help|--version) exit 0 ;; esac
printf 'started secret=%s\n' "\${OPENROUTER_API_KEY-unset}" >> '$3'
SH
  chmod +x "$1/$2"
}

# The fixture's tmux records launches; this wrapper also runs the staged launch
# file in the background, the way a pane shell sourcing it would.
install_running_pane() {  # <fakebin> <pane-output>
  mv "$1/tmux" "$1/tmux.recorder"
  cat > "$1/tmux" <<SH
#!/usr/bin/env bash
'$1/tmux.recorder' "\$@" || exit \$?
[ "\${1:-}" = send-keys ] || exit 0
for a in "\$@"; do
  case "\$a" in
    ". '"*"'")
      staged=\${a#". '"}
      staged=\${staged%"'"}
      ( /bin/sh "\$staged" >>'$2' 2>&1 </dev/null & )
      ;;
  esac
done
exit 0
SH
  chmod +x "$1/tmux"
}

# make_case <name> <harness> <id> -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG PANE_OUT PROBE_LOG
make_case() {
  local name=$1 harness=$2 id=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_OUT="$CASE_DIR/pane.out"
  PROBE_LOG="$CASE_DIR/probe.log"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  install_fake_av "$FAKEBIN"
  install_probe "$FAKEBIN" "$harness" "$PROBE_LOG"
  install_running_pane "$FAKEBIN" "$PANE_OUT"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
  : > "$PANE_OUT"
}

write_config() {  # <harness> [names-json]
  printf '{"injector": ["av", "inject", "+{name}", "--"], "harnesses": {"%s": %s}}\n' \
    "$1" "${2:-[\"OPENROUTER_API_KEY\"]}" > "$HOME_DIR/config/launch-secrets.json"
}

run_spawn() {  # <id> [extra spawn args...]
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FAKE_AV_SECRET="$SECRET_VALUE" \
    FM_LAUNCH_SECRETS_TIMEOUT="${TIMEOUT:-20}" FM_LAUNCH_SECRETS_POLL=0.05 \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off "$@"
}

# wait_for_probe <want-lines>: the pane runs in the background.
wait_for_probe() {
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(wc -l < "$PROBE_LOG" 2>/dev/null || echo 0)" -ge "$1" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# The secret value must never be written anywhere Firstmate keeps text: the
# home (task record, status, data), the staged launch namespace, the launch
# text the pane received, the pane's own output, or the spawn's output.
assert_secret_not_leaked() {  # <id> <spawn-output> <label>
  local id=$1 out=$2 label=$3 hits
  hits=$(grep -rlF -- "$SECRET_VALUE" "$HOME_DIR" "$LAUNCH_LOG" "$PANE_OUT" /tmp/fm-"$id"+* 2>/dev/null || true)
  [ -z "$hits" ] || fail "$label: the secret value was written to: $hits"
  case "$out" in
    *"$SECRET_VALUE"*) fail "$label: the secret value appeared in the spawn output" ;;
  esac
}

test_absent_config_is_unchanged() {
  local out status
  make_case absent pi absent-a1
  out=$(run_spawn absent-a1)
  status=$?
  expect_code 0 "$status" "spawn without launch secrets should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "$FAKEBIN/av" \
    "an absent config must not wrap the launch in an injector"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'spawn already gave up' \
    "an absent config must not add the launch handshake"
  wait_for_probe 1 || fail "absent config: the worker never started; pane output: $(cat "$PANE_OUT")"
  assert_equals 'started secret=unset' "$(cat "$PROBE_LOG")" \
    "an absent config must launch the worker with no injected secret"
  pass "an absent launch-secrets config launches the worker unwrapped"
}

test_other_harness_is_unchanged() {
  local out status
  make_case other-harness pi other-a1
  write_config claude
  out=$(run_spawn other-a1)
  status=$?
  expect_code 0 "$status" "spawn with secrets only for another harness should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "$FAKEBIN/av" \
    "secrets configured for another harness must not wrap this launch"
  pass "secrets configured for another harness leave this harness's launch unwrapped"
}

test_configured_injects_the_secret() {
  local allowlist out status launch
  for allowlist in absent enabled; do
    make_case "inject-$allowlist" pi "inject-$allowlist-a1"
    write_config pi
    [ "$allowlist" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_spawn "inject-$allowlist-a1")
    status=$?
    expect_code 0 "$status" "allowlist=$allowlist: spawn with launch secrets should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "'$FAKEBIN/av' 'inject' '+OPENROUTER_API_KEY' '--' /bin/sh -c" \
      "allowlist=$allowlist: the launch must run inside the configured injector"
    wait_for_probe 1 || fail "allowlist=$allowlist: the worker never started; pane output: $(cat "$PANE_OUT")"
    assert_equals "started secret=$SECRET_VALUE" "$(cat "$PROBE_LOG")" \
      "allowlist=$allowlist: the worker must start with the injected secret"
    assert_secret_not_leaked "inject-$allowlist-a1" "$out" "allowlist=$allowlist"
  done
  pass "a configured injector hands the secret to the worker alone, with or without the env allowlist"
}

test_every_listed_name_is_injected() {
  local out status
  make_case two-names pi two-a1
  write_config pi '["OPENROUTER_API_KEY", "OTHER_KEY"]'
  out=$(run_spawn two-a1)
  status=$?
  expect_code 0 "$status" "spawn with two secrets should succeed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "'inject' '+OPENROUTER_API_KEY' '+OTHER_KEY' '--'" \
    "each listed name must expand the {name} element once, in order"
  pass "every listed secret name expands the injector's {name} element in order"
}

test_refusing_injector_stops_the_spawn() {
  local out status
  make_case refuse pi refuse-a1
  write_config pi
  out=$(FAKE_AV_MODE=refuse run_spawn refuse-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a refusing injector must fail the spawn: $out"
  assert_contains "$out" 'refused (exit 3)' "the spawn must report the injector's refusal"
  assert_contains "$(cat "$HOME_DIR/state/refuse-a1.status")" 'the secret injector refused (exit 3)' \
    "the task status must record the refusal"
  assert_contains "$(cat "$PANE_OUT")" 'av: approval denied' \
    "the injector's own message stays visible in the pane"
  [ ! -s "$PROBE_LOG" ] || fail "a refusing injector must not start the worker: $(cat "$PROBE_LOG")"
  assert_secret_not_leaked refuse-a1 "$out" "refusal"
  pass "a refusing injector stops the spawn with its exit status and never starts the worker"
}

test_slow_injector_times_out_and_cannot_start_late() {
  local out status i
  make_case slow pi slow-a1
  write_config pi
  out=$(FAKE_AV_MODE=slow FAKE_AV_DELAY=2 TIMEOUT=1 run_spawn slow-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "an injector that never starts the worker in time must fail the spawn: $out"
  assert_contains "$out" 'did not start the worker within 1s' "the spawn must report the timeout"
  # Let the late approval land: it must find the spawn's claim and refuse.
  i=0
  until grep -q 'spawn already gave up' "$PANE_OUT" 2>/dev/null || [ "$i" -ge 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  assert_contains "$(cat "$PANE_OUT")" 'spawn already gave up' \
    "a late approval must not start the worker the spawn already failed"
  [ ! -s "$PROBE_LOG" ] || fail "a late approval started the worker: $(cat "$PROBE_LOG")"
  pass "a timed-out injector fails the spawn and its late approval cannot start the worker"
}

test_missing_injector_refuses_before_any_record() {
  local out status
  make_case missing pi missing-a1
  printf '{"injector": ["fm-no-such-injector", "+{name}"], "harnesses": {"pi": ["OPENROUTER_API_KEY"]}}\n' \
    > "$HOME_DIR/config/launch-secrets.json"
  out=$(run_spawn missing-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing injector must refuse the spawn: $out"
  assert_contains "$out" "injector 'fm-no-such-injector'" "the refusal must name the missing injector"
  [ ! -e "$HOME_DIR/state/missing-a1.meta" ] || fail "a missing injector must refuse before any task record exists"
  [ ! -s "$LAUNCH_LOG" ] || fail "a missing injector must refuse before any launch: $(cat "$LAUNCH_LOG")"
  pass "a missing injector refuses the spawn before any record or launch exists"
}

test_malformed_config_refuses() {
  local bad out status
  for bad in '{"injector": ["av", "inject", "--"], "harnesses": {"pi": ["OPENROUTER_API_KEY"]}}' \
    '{"injector": ["av", "inject", "+{name}", "--"], "harnesses": {"pi": ["NOT-A-NAME"]}}' \
    '{"injector": ["{name}"], "harnesses": {"pi": ["K"]}}' \
    'not json'; do
    make_case malformed pi malformed-a1
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-secrets.json"
    out=$(run_spawn malformed-a1)
    status=$?
    [ "$status" -ne 0 ] || fail "malformed config '$bad' must refuse the spawn: $out"
    assert_contains "$out" 'config/launch-secrets.json must be' "malformed config '$bad' must name the schema"
    [ ! -e "$HOME_DIR/state/malformed-a1.meta" ] || fail "malformed config '$bad' must refuse before any task record exists"
    rm -rf "$CASE_DIR"
  done
  pass "a malformed launch-secrets config refuses the spawn before any record exists"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch rebuilds the launch through bin/fm-spawn.sh
# --relaunch. This stub models the pane just enough for that transaction: the
# harness exit command leaves a shell behind, and the staged launch both
# restarts the harness and runs, so the replacement worker really starts.
make_relaunch_stub() {  # <fakebin> <fake-state-dir> <pane-output>
  cat > "$1/tmux" <<SH
#!/usr/bin/env bash
set -u
D='$2'
case "\${1:-}" in
  send-keys)
    shift
    literal=0
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=\${1:-}
    if [ "\$literal" = 1 ]; then
      case "\$payload" in
        ". '"*"'")
          staged=\${payload#". '"}
          staged=\${staged%"'"}
          if [ -f "\$staged" ]; then
            payload=\$(cat "\$staged")
            printf 'codex' > "\$D/command"
            ( /bin/sh "\$staged" >>'$3' 2>&1 </dev/null & )
          fi
          ;;
      esac
      printf '%s\n' "\$payload" >> "\$D/literal"
      case "\$payload" in
        /exit|/quit) printf 'zsh' > "\$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "\$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "\$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "\$D/windows" ] && cat "\$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

test_relaunch_injects_the_secret() {
  local id=relaunch-a1 dir home proj wt fb out status probe pane
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  fb="$dir/fakebin"
  probe="$dir/probe.log"
  pane="$dir/pane.out"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$fb" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  printf '{"injector": ["av", "inject", "+{name}", "--"], "harnesses": {"codex": ["OPENROUTER_API_KEY"]}}\n' \
    > "$home/config/launch-secrets.json"
  make_relaunch_stub "$fb" "$dir/fake" "$pane"
  install_fake_av "$fb"
  install_probe "$fb" codex "$probe"
  fm_git_worktree "$proj" "$wt" wt-relaunch
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"
  : > "$pane"
  printf 'codex' > "$dir/fake/command"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"

  out=$(env PATH="$fb:$PATH" FM_HOME="$home" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FAKE_AV_SECRET="$SECRET_VALUE" \
    FM_LAUNCH_SECRETS_TIMEOUT=20 FM_LAUNCH_SECRETS_POLL=0.05 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$id" relaunch --note 'replacement continues the same task' 2>&1)
  status=$?
  expect_code 0 "$status" "relaunch with launch secrets should succeed: $out"
  assert_contains "$(cat "$dir/fake/literal")" "'$fb/av' 'inject' '+OPENROUTER_API_KEY' '--'" \
    "the replacement launch must run inside the configured injector"
  PROBE_LOG=$probe
  wait_for_probe 1 || fail "relaunch: the replacement worker never started; pane output: $(cat "$pane")"
  assert_equals "started secret=$SECRET_VALUE" "$(cat "$probe")" \
    "the replacement worker must start with the injected secret"
  HOME_DIR=$home LAUNCH_LOG="$dir/fake/literal" PANE_OUT=$pane \
    assert_secret_not_leaked "$id" "$out" relaunch
  pass "relaunch rebuilds the launch inside the injector and the replacement worker gets the secret"
}

test_absent_config_is_unchanged
test_other_harness_is_unchanged
test_configured_injects_the_secret
test_every_listed_name_is_injected
test_refusing_injector_stops_the_spawn
test_slow_injector_times_out_and_cannot_start_late
test_missing_injector_refuses_before_any_record
test_malformed_config_refuses
test_relaunch_injects_the_secret
