#!/bin/sh
# Reinstall must not surface OpenWrt ubus "Command failed: Not found".
set -e
root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$root/src/service-ctl.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
init=$tmp/init

cat > "$init" <<'EOF'
#!/bin/sh
case "$1" in
  running) exit 1 ;;
  start)
    echo "Command failed: Not found" >&2
    echo "started cfg-guardian"
    exit 0
    ;;
  restart)
    echo "should-not-restart" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$init"
out=$(cfg_guardian_service_ctl "$init")
printf '%s\n' "$out" | grep -qx "started cfg-guardian"
printf '%s\n' "$out" | grep -q "Command failed" && exit 1
printf '%s\n' "$out" | grep -q "should-not-restart" && exit 1

cat > "$init" <<'EOF'
#!/bin/sh
case "$1" in
  running) exit 0 ;;
  restart)
    echo "Command failed: Not found" >&2
    exit 0
    ;;
  start)
    echo "should-not-start"
    exit 9
    ;;
esac
EOF
out=$(cfg_guardian_service_ctl "$init")
[ -z "$out" ]

cat > "$init" <<'EOF'
#!/bin/sh
case "$1" in
  running) exit 1 ;;
  start)
    echo "Command failed: Not found" >&2
    echo "procd: /usr/bin/cfg-guardian.sh: not found" >&2
    exit 1
    ;;
esac
EOF
set +e
out=$(cfg_guardian_service_ctl "$init" 2>"$tmp/err")
status=$?
set -e
[ "$status" -eq 1 ]
printf '%s\n' "$out" | grep -q "cfg-guardian.sh: not found"
printf '%s\n' "$out" | grep -qx "Command failed: Not found" && exit 1
grep -q "service control failed (exit 1)" "$tmp/err"

# Same calls under set -e, which is how install.sh runs.
cat > "$init" <<'EOF'
#!/bin/sh
case "$1" in
  running) exit 1 ;;
  start) echo "Command failed: Not found" >&2; exit 0 ;;
esac
EOF
sh -c "set -e; . '$root/src/service-ctl.sh'; cfg_guardian_service_ctl '$init'" >"$tmp/sete.out"
grep -q "Command failed" "$tmp/sete.out" && exit 1
echo "ok"
