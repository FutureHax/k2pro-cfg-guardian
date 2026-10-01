# Start or restart the init script.
#
# OpenWrt procd's restart deletes the service over ubus first. When no
# instance is registered (first install, or a reinstall after the process
# has exited), ubus prints "Command failed: Not found" and exits 4. The
# installer runs under set -e, and that line was shown as the whole
# failure. A missing procd instance is a normal update: start the service
# and do not report that line.
cfg_guardian_service_ctl() {
    init=$1
    tmp=/tmp/cfg-guardian-ctl.$$
    status=0
    if "$init" running >/dev/null 2>&1; then
        "$init" restart >"$tmp" 2>&1 || status=$?
    else
        "$init" start >"$tmp" 2>&1 || status=$?
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "Command failed: Not found"|"Not found") ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    if [ "$status" -ne 0 ]; then
        echo "cfg-guardian service control failed (exit $status)" >&2
        return "$status"
    fi
    return 0
}
