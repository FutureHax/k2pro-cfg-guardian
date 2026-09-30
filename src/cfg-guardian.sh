#!/bin/sh
# Puts back Klipper config that a Creality K2 firmware update removes.
#   cfg-guardian.sh once|daemon|status

base=${CFG_HOME:-/mnt/UDISK/cfg-guardian}
vault=$base/vault
patch_file=$base/patches.json
includes_file=$base/printer.cfg.includes
log_file=$base/guardian.log
state_dir=$base/state
config_dir=${CFG_CONFIG:-/mnt/UDISK/printer_data/config}
printer_cfg=$config_dir/printer.cfg
printer_url=${CFG_PRINTER:-http://127.0.0.1:7125}
every=${CFG_EVERY:-300}
first_wait=${CFG_FIRST_WAIT:-45}
log_limit=262144

changed=0
firmware_changed=0

firmware_version() {
    version=$(fw_printenv -n version 2>/dev/null)
    [ -n "$version" ] && { echo "$version"; return; }
    cat /etc/openwrt_version 2>/dev/null || echo unknown
}

log() {
    mkdir -p "$base"
    if [ -f "$log_file" ] && [ "$(wc -c < "$log_file")" -gt "$log_limit" ]; then
        mv -f "$log_file" "$log_file.1"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime)s fw=$(firmware_version) $*" >> "$log_file"
}

wait_for_config() {
    tries=60
    while [ ! -d "$config_dir" ] && [ $tries -gt 0 ]; do
        sleep 1
        tries=$((tries - 1))
    done
    [ -d "$config_dir" ]
}

# \r\n has to live in the printf format. In a quoted variable it is literal
# text and Moonraker ignores the request. response_body stops after
# Content-Length so nc does not sit on an open socket.
printer_request() {
    host=$(printf '%s' "$printer_url" | sed -n 's#^http://\([^:/]*\).*#\1#p')
    port=$(printf '%s' "$printer_url" | sed -n 's#^http://[^:/]*:\([0-9]*\).*#\1#p')
    [ -n "$host" ] || host=127.0.0.1
    [ -n "$port" ] || port=7125
    # Set before the pipe. The if on the left runs in a subshell.
    if [ "$1" = "POST" ]; then
        wait_sec=90
    else
        wait_sec=20
    fi
    if [ "$1" = "POST" ]; then
        printf '%s %s HTTP/1.0\r\nHost: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' \
            "$1" "$2" "$host"
    else
        printf '%s %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' \
            "$1" "$2" "$host"
    fi | nc -w "$wait_sec" "$host" "$port" 2>/dev/null | response_body
}

response_body() {
    length=0
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '\r')
        [ -z "$line" ] && break
        case "$line" in
            Content-Length:*)
                length=$(printf '%s' "$line" | awk '{print $2}')
                ;;
        esac
    done
    if [ -n "$length" ] && [ "$length" -gt 0 ] 2>/dev/null; then
        dd bs="$length" count=1 2>/dev/null
    fi
}

json_value() {
    awk -v marker="$1" -v key="$2" '
        {
            i = index($0, "\"" marker "\"")
            if (i == 0) exit
            rest = substr($0, i)
            needle = "\"" key "\": \""
            j = index(rest, needle)
            if (j == 0) {
                needle = "\"" key "\":\""
                j = index(rest, needle)
            }
            if (j == 0) exit
            rest = substr(rest, j + length(needle))
            quote = index(rest, "\"")
            if (quote <= 1) exit
            print substr(rest, 1, quote - 1)
        }
    '
}

note_firmware() {
    mkdir -p "$state_dir"
    current=$(firmware_version)
    previous=$(cat "$state_dir/last_version" 2>/dev/null)
    if [ -z "$previous" ]; then
        log "first run, firmware $current"
    elif [ "$previous" != "$current" ]; then
        firmware_changed=1
        log "firmware $previous -> $current, putting patch values back"
    fi
    echo "$current" > "$state_dir/last_version"
}

# Missing vault files are copied back. If you edited the live file, that
# copy becomes the vault and the old vault is kept as .bak.
restore_missing() {
    [ -d "$vault" ] || return 0
    for saved in "$vault"/*.cfg; do
        [ -f "$saved" ] || continue
        name=$(basename "$saved")
        live=$config_dir/$name
        if [ ! -f "$live" ]; then
            cp -f "$saved" "$live" && sync
            log "restored $name from vault"
            changed=1
        elif ! cmp -s "$saved" "$live"; then
            cp -f "$saved" "$saved.bak"
            cp -f "$live" "$saved" && sync
            log "vault updated from live $name (old copy is $name.bak)"
        fi
    done
}

restore_includes() {
    [ -f "$includes_file" ] || return 0
    [ -f "$printer_cfg" ] || { log "printer.cfg is missing, skipped includes"; return 0; }
    missing=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        grep -qxF "$line" "$printer_cfg" && continue
        target=$(echo "$line" | sed -n 's/^\[include[[:space:]]*\([^]]*\)\].*/\1/p')
        if [ -n "$target" ] && [ ! -f "$config_dir/$target" ]; then
            log "skipped $line, $target is not on disk"
            continue
        fi
        missing="$missing$line
"
    done < "$includes_file"
    [ -n "$missing" ] || return 0

    cp -f "$printer_cfg" "$state_dir/printer.cfg.before-heal"
    tmp=$printer_cfg.guardian.tmp
    printf '%s' "$missing" > "$state_dir/missing_includes"
    awk -v inc="$state_dir/missing_includes" '
        BEGIN { done = 0 }
        !done && /^\[/ {
            while ((getline l < inc) > 0) print l
            close(inc)
            done = 1
        }
        { print }
        END {
            if (!done) { while ((getline l < inc) > 0) print l }
        }
    ' "$printer_cfg" > "$tmp" && mv -f "$tmp" "$printer_cfg" && sync
    rm -f "$state_dir/missing_includes"
    printf '%s' "$missing" | while IFS= read -r line; do
        [ -n "$line" ] && log "added to printer.cfg: $line"
    done
    changed=1
}

# One record per change, fields split by ASCII 034:
# file, section, setting, from, to, enabled, insert_after, line.
# setting is empty when from/to are whole lines such as "G0 E-10 F360".
# enabled is empty when the field is omitted, and that means off.
list_changes() {
    [ -f "$patch_file" ] || return 0
    awk '
        function val(line) {
            sub(/^[^:]*:[[:space:]]*"/, "", line)
            sub(/",?[[:space:]]*$/, "", line)
            return line
        }
        /"file"/ { file = val($0); next }
        /"section"/ { section = val($0); next }
        /"setting"/ { setting = val($0); next }
        /"insert_after"/ { insert_after = val($0); next }
        /"from"/ { from = val($0); next }
        /"to"/ { to = val($0); next }
        /"line"/ { added = val($0); next }
        /"enabled"/ {
            if ($0 ~ /:[[:space:]]*false/) enabled = "false"
            else enabled = "true"
            next
        }
        /^[[:space:]]*}/ {
            if (file != "") {
                printf "%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n", file, section, setting, from, to, enabled, insert_after, added
                file = section = setting = from = to = enabled = insert_after = added = ""
            }
        }
    ' "$patch_file"
}

apply_one_change() {
    file=$1
    section=$2
    setting=$3
    from=$4
    to=$5
    enabled=$6
    insert_after=$7
    added=$8
    [ "$enabled" = "true" ] || return 0
    live=$config_dir/$file
    [ -f "$live" ] || { log "skipped $file, not in the config dir"; return 0; }
    if [ -n "$insert_after" ]; then
        mode=insert
        detail=$insert_after
        stock=
        want=$added
    elif [ -n "$setting" ]; then
        mode=setting
        detail=$setting
        stock=$from
        want=$to
    else
        mode=line
        detail=$(printf '%s' "$from" | sed -n 's/.*\(F[0-9.][0-9.]*\).*/\1/p')
        stock=$(printf '%s' "$from" | sed -n 's/.*E\(-[0-9.][0-9.]*\).*/\1/p')
        want=$(printf '%s' "$to" | sed -n 's/.*E\(-[0-9.][0-9.]*\).*/\1/p')
    fi
    tmp=$live.guardian.tmp
    awk -v section="$section" -v mode="$mode" -v detail="$detail" \
        -v stock="$stock" -v want="$want" -v force="$firmware_changed" '
        NR == FNR {
            if ($0 == section) { scanning = 1; next }
            if (scanning && /^\[/) { scanning = 0 }
            if (scanning && $0 ~ ("^[ \t]*" want "[ \t]*$")) { seen = 1 }
            next
        }
        function apply_line() {
            if (match($0, /^[ \t]*G0 E-?[0-9.]+[ \t]+/)) {
                if ($0 ~ ("E" stock "[ \t]+" detail) || force == 1) {
                    sub(/E-?[0-9.]+/, "E" want)
                }
            }
        }
        function apply_setting() {
            if (match($0, "^" detail ":[ \t]*-?[0-9.]+")) {
                if ($0 ~ ("^" detail ":[ \t]*" stock "([ \t]|$)") || force == 1) {
                    sub("^" detail ":[ \t]*-?[0-9.]+", detail ": " want)
                }
            }
        }
        $0 == section { in_section = 1; print; next }
        in_section && /^\[/ { in_section = 0 }
        in_section && mode == "line" { apply_line() }
        in_section && mode == "setting" { apply_setting() }
        in_section && mode == "insert" && !seen && !placed && index($0, detail) {
            print
            print "    " want
            placed = 1
            next
        }
        { print }
    ' "$live" "$live" > "$tmp" || { rm -f "$tmp"; log "could not edit $file"; return 0; }
    if cmp -s "$live" "$tmp"; then
        rm -f "$tmp"
    else
        cp -f "$live" "$state_dir/$file.before-patch"
        mv -f "$tmp" "$live" && sync
        if [ -n "$added" ]; then
            label=$added
        else
            label=$to
        fi
        log "updated $file $section to $label"
        changed=1
    fi
}

apply_patches() {
    list_changes > "$state_dir/changes.list" || return 0
    while IFS="$(printf '\034')" read -r file section setting from to enabled insert_after added; do
        [ -n "$file" ] || continue
        apply_one_change "$file" "$section" "$setting" "$from" "$to" "$enabled" "$insert_after" "$added"
    done < "$state_dir/changes.list"
    rm -f "$state_dir/changes.list"
}

restart_if_idle() {
    [ "$changed" = 1 ] || return 0
    klippy_pid=$(cat /var/run/klippy.pid 2>/dev/null)
    if [ -z "$klippy_pid" ] || ! kill -0 "$klippy_pid" 2>/dev/null; then
        log "klipper is not running, the next start loads the fix"
        rm -f "$state_dir/restart_pending"
        return 0
    fi

    info=$(printer_request GET /printer/info)
    state=$(printf '%s' "$info" | json_value result state)
    case "$state" in
        error|shutdown)
            ;;
        ready)
            status_json=$(printer_request GET "/printer/objects/query?print_stats&idle_timeout")
            print_state=$(printf '%s' "$status_json" | json_value print_stats state)
            idle_state=$(printf '%s' "$status_json" | json_value idle_timeout state)
            case "$print_state" in
                printing|paused)
                    log "printer is $print_state, restart waits"
                    echo 1 > "$state_dir/restart_pending"
                    return 0 ;;
            esac
            if [ "$idle_state" = "Printing" ]; then
                log "printer is busy, restart waits"
                echo 1 > "$state_dir/restart_pending"
                return 0
            fi
            ;;
        *)
            log "klipper state is '$state', restart waits"
            echo 1 > "$state_dir/restart_pending"
            return 0 ;;
    esac
    reply=$(printer_request POST /printer/firmware_restart)
    if [ -n "$reply" ]; then
        log "firmware restart (printer was $state): $reply"
        rm -f "$state_dir/restart_pending"
    else
        log "firmware restart returned nothing (printer was $state), will try again"
        echo 1 > "$state_dir/restart_pending"
    fi
}

check_config() {
    changed=0
    firmware_changed=0
    wait_for_config || { log "config dir $config_dir never showed up"; return 1; }
    mkdir -p "$state_dir"
    note_firmware
    restore_missing
    restore_includes
    apply_patches
    [ -f "$state_dir/restart_pending" ] && changed=1
    restart_if_idle
    date '+%Y-%m-%d %H:%M:%S' > "$state_dir/last_pass"
}

show_status() {
    echo "firmware:   $(firmware_version)"
    echo "last seen:  $(cat "$state_dir/last_version" 2>/dev/null || echo -)"
    echo "last check: $(cat "$state_dir/last_pass" 2>/dev/null || echo -)"
    echo "vault:      $vault"
    for saved in "$vault"/*.cfg; do
        [ -f "$saved" ] || continue
        name=$(basename "$saved")
        if [ -f "$config_dir/$name" ]; then
            cmp -s "$saved" "$config_dir/$name" && note="in sync" || note="live copy differs, vault will follow it"
        else
            note="missing from config"
        fi
        echo "  $name: $note"
    done
    echo "includes:"
    [ -f "$includes_file" ] && while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        grep -qxF "$line" "$printer_cfg" 2>/dev/null && note=present || note=missing
        echo "  $line: $note"
    done < "$includes_file"
    echo "patches:"
    if [ -f "$patch_file" ]; then
        while IFS="$(printf '\034')" read -r file section setting from to enabled insert_after added; do
            [ -n "$file" ] || continue
            live=$config_dir/$file
            if [ -n "$added" ]; then
                expect=$added
            elif [ -n "$setting" ]; then
                expect="$setting: $to"
            else
                expect=$to
            fi
            if [ "$enabled" != "true" ]; then
                echo "  $file $expect: disabled"
            elif [ -f "$live" ] && grep -qF "$expect" "$live"; then
                echo "  $file $expect: applied"
            else
                echo "  $file $expect: not applied"
            fi
        done <<EOF
$(list_changes)
EOF
    else
        echo "  (none)"
    fi
    [ -f "$state_dir/restart_pending" ] && echo "restart:    waiting until the printer is idle"
    echo "log:        $log_file"
    tail -n 5 "$log_file" 2>/dev/null | sed 's/^/  /'
}

case "${1:-once}" in
    once)
        check_config
        log "check finished (changed=$changed)" ;;
    daemon)
        log "checker started, first pass in ${first_wait}s, then every ${every}s"
        sleep "$first_wait"
        while :; do
            check_config
            sleep "$every"
        done ;;
    status)
        show_status ;;
    *)
        echo "usage: $0 {once|daemon|status}" >&2
        exit 2 ;;
esac
