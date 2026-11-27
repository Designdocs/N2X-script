#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^fetch_upgrade_data() (/,/^)/p' "$root/install.sh")"
fail() { echo "FAIL: $CASE: $*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
log_warn() { echo "$*"; }
maintenance_apply_window() { [[ "$scheduled_day" != closed ]]; }
cat > "$work/candidate" <<'CANDIDATE'
#!/usr/bin/env bash
echo "${GODEBUG:-unset}" >> "$TEST_DIR/attempts"
case "$CASE" in
    recovered)
        if [[ "$GODEBUG" == *,http2client=0 ]]; then echo prepared > "$5"; exit 0; fi ;;
    success) echo prepared > "$5"; exit 0 ;;
    denied)
        echo 'WARN context deadline exceeded'
        echo 'Execute command failed err="Nodes[0] artx #376: get node config: unauthorized"'; exit 1 ;;
    certificate) echo 'Execute command failed err="read local TLS certificate: i/o timeout"'; exit 1 ;;
    interrupted) exit 130 ;;
esac
echo 'Execute command failed err="Nodes[0] artx #376: get node config: context deadline exceeded"'
exit 1
CANDIDATE
chmod +x "$work/candidate"
export TEST_DIR="$work" GODEBUG=multipathtcp=0
for CASE in success recovered timeout denied certificate interrupted closed; do
    export CASE
    mkdir "$work/$CASE"
    : > "$work/attempts"
    scheduled_day=''
    if [[ "$CASE" == closed ]]; then scheduled_day=closed; fi
    result=0
    fetch_upgrade_data "$work/candidate" config "$work/$CASE" > "$work/out" || result=$?
    case "$CASE" in
        success|recovered) [[ $result == 0 && -s "$work/$CASE/data" ]] || fail "expected prepared data" ;;
        *) [[ $result != 0 && ! -e "$work/$CASE/data" ]] || fail "expected preparation failure" ;;
    esac
    expected=multipathtcp=0
    case "$CASE" in recovered|timeout) expected+=$'\nmultipathtcp=0,http2client=0' ;; esac
    [[ "$(cat "$work/attempts")" == "$expected" && "$GODEBUG" == multipathtcp=0 ]] || fail "unexpected attempts or changed environment"
done
echo "upgrade_preflight_retry_test: OK"
