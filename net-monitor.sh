#!/bin/sh
# Monitor outbound TCP connections and write the same per-application logs
# as net-monitor.ps1.
#
# Start:  ./net-monitor.sh
#         ./net-monitor.sh --interval 5
# Stop:   Ctrl+C
#
# Logs:   logs/<application>_<YYYY-MM-DD>.log next to this script.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOGDIR=$ROOT/logs
INTERVAL=2
ONCE=0

usage() {
    printf '%s\n' "Usage: $0 [--interval SECONDS] [--once]"
}

while [ $# -gt 0 ]; do
    case $1 in
        --interval)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            INTERVAL=$2
            shift 2
            ;;
        --interval=*)
            INTERVAL=${1#*=}
            shift
            ;;
        --once)
            ONCE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case $INTERVAL in
    ''|*[!0-9]*)
        printf 'Interval must be a number of seconds from 1 to 3600.\n' >&2
        exit 2
        ;;
esac
if [ "$INTERVAL" -lt 1 ] || [ "$INTERVAL" -gt 3600 ]; then
    printf 'Interval must be a number of seconds from 1 to 3600.\n' >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'Для полного списка приложений и путей нужны права root.'
    if command -v sudo >/dev/null 2>&1; then
        if [ "$ONCE" -eq 1 ]; then
            if sudo -- "$0" --once --interval "$INTERVAL"; then
                exit 0
            fi
        elif sudo -- "$0" --interval "$INTERVAL"; then
            exit 0
        fi
    fi
    printf '%s\n' 'Продолжаю с правами текущего пользователя.'
fi

if ! command -v ss >/dev/null 2>&1; then
    printf '%s\n' 'Нужна утилита ss из пакета iproute2.' >&2
    exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
    printf '%s\n' 'Нужна утилита flock из пакета util-linux.' >&2
    exit 1
fi

mkdir -p "$LOGDIR"
exec 9>"$LOGDIR/.lock"
if ! flock -n 9; then
    printf '%s\n' 'Мониторинг уже запущен.'
    exit 1
fi

RUNDIR=$(mktemp -d)
mkdir -p "$RUNDIR/apps" "$RUNDIR/nodomain"
: > "$RUNDIR/q_pub"
: > "$RUNDIR/q_priv"

cleanup() {
    [ -n "${RUNDIR:-}" ] && rm -rf "$RUNDIR"
    printf '\n%s\n' 'Мониторинг остановлен.'
}
trap cleanup EXIT INT TERM

safe_name() {
    _raw=$1
    _s=$(printf '%s' "$_raw" | tr -c 'A-Za-z0-9._+-' '_' | sed 's/^_*//;s/_*$//')
    [ -n "$_s" ] || _s=unknown
    _s=$(printf '%.80s' "$_s" | sed 's/_*$//')
    [ -n "$_s" ] || _s=unknown
    _up=$(printf '%s' "$_s" | tr '[:lower:]' '[:upper:]')
    case $_up in
        CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) _s=_$_s ;;
    esac
    printf '%s\n' "$_s"
}

is_ignored() {
    case $1 in
        ''|0.*|127.*|::|::1) return 0 ;;
        *) return 1 ;;
    esac
}

is_private() {
    case $1 in
        10.*|192.168.*|169.254.*|fe80:*|fc*:*|fd*:*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

format_ep() {
    _ip=$(printf '%s' "$1" | tr 'A-F' 'a-f')
    _port=$2
    case $_ip in
        *:*) printf '[%s]:%s\n' "$_ip" "$_port" ;;
        *) printf '%s:%s\n' "$_ip" "$_port" ;;
    esac
}

proc_info() {
    _pid=$1
    _name=$2
    _path=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
    _path=${_path% (deleted)}
    if [ -n "$_path" ]; then
        _name=$(basename -- "$_path")
    fi
    [ -n "$_name" ] || _name=pid-$_pid
    printf '%s\t%s\n' "$_name" "$_path"
}

rewrite_log() {
    _safe=$1
    _dir=$RUNDIR/apps/$_safe
    _file=$LOGDIR/${_safe}_$(date +%Y-%m-%d).log
    _tmp=$_file.tmp.$$
    {
        printf '# %s\n' "$(cat "$_dir/name")"
        if [ -s "$_dir/paths" ]; then
            while IFS= read -r _path || [ -n "$_path" ]; do
                [ -n "$_path" ] || continue
                printf '# %s\n' "$_path"
            done < "$_dir/paths"
        else
            printf '%s\n' '# (путь недоступен)'
        fi
        if [ -s "$_dir/eps" ]; then
            while IFS=$(printf '\t') read -r _ep _ip _dom || [ -n "${_ep:-}" ]; do
                [ -n "${_ep:-}" ] || continue
                if [ -n "${_dom:-}" ]; then
                    printf '%s    %s\n' "$_ep" "$_dom"
                else
                    printf '%s\n' "$_ep"
                fi
            done < "$_dir/eps"
        fi
    } > "$_tmp"
    mv "$_tmp" "$_file"
}

ensure_app() {
    _safe=$1
    _name=$2
    _path=$3
    _dir=$RUNDIR/apps/$_safe
    mkdir -p "$_dir"
    if [ ! -f "$_dir/name" ]; then
        printf '%s\n' "$_name" > "$_dir/name"
        : > "$_dir/paths"
        : > "$_dir/eps"
    fi
    if [ -n "$_path" ] && ! grep -Fxq "$_path" "$_dir/paths"; then
        printf '%s\n' "$_path" >> "$_dir/paths"
        return 0
    fi
    return 1
}

enqueue_ip() {
    _ip=$1
    [ -n "$_ip" ] || return 0
    [ -e "$RUNDIR/nodomain/$_ip" ] && return 0
    if grep -Fxq "$_ip" "$RUNDIR/q_pub" "$RUNDIR/q_priv"; then
        return 0
    fi
    if is_private "$_ip"; then
        printf '%s\n' "$_ip" >> "$RUNDIR/q_priv"
    else
        printf '%s\n' "$_ip" >> "$RUNDIR/q_pub"
    fi
}

add_endpoint() {
    _name=$1
    _path=$2
    _ip=$(printf '%s' "$3" | tr 'A-F' 'a-f')
    _port=$4
    _safe=$(safe_name "$_name")
    _dir=$RUNDIR/apps/$_safe
    _ep=$(format_ep "$_ip" "$_port")
    _path_added=1
    if ensure_app "$_safe" "$_name" "$_path"; then
        _path_added=0
    fi
    _exists=1
    if [ -s "$_dir/eps" ] && awk -F '\t' -v ep="$_ep" '$1 == ep { found = 1 } END { exit !found }' "$_dir/eps"; then
        _exists=0
    fi
    if [ "$_exists" -ne 0 ]; then
        printf '%s\t%s\t\n' "$_ep" "$_ip" >> "$_dir/eps"
        printf '%s  %s  %s\n' "$(date +%H:%M:%S)" "$_name" "$_ep"
        rewrite_log "$_safe"
        enqueue_ip "$_ip"
    elif [ "$_path_added" -eq 0 ]; then
        rewrite_log "$_safe"
    fi
}

apply_domain() {
    _ip=$1
    _dom=$2
    [ -n "$_dom" ] || return 0
    for _dir in "$RUNDIR"/apps/*; do
        [ -d "$_dir" ] || continue
        [ -s "$_dir/eps" ] || continue
        _changed=1
        _tmp=$_dir/eps.new
        : > "$_tmp"
        while IFS=$(printf '\t') read -r _ep _eip _edom || [ -n "${_ep:-}" ]; do
            [ -n "${_ep:-}" ] || continue
            if [ "$_eip" = "$_ip" ] && [ -z "${_edom:-}" ]; then
                _edom=$_dom
                _changed=0
                printf '%s  %s  %s  %s\n' "$(date +%H:%M:%S)" "$(cat "$_dir/name")" "$_ep" "$_dom"
            fi
            printf '%s\t%s\t%s\n' "$_ep" "$_eip" "${_edom:-}" >> "$_tmp"
        done < "$_dir/eps"
        mv "$_tmp" "$_dir/eps"
        if [ "$_changed" -eq 0 ]; then
            rewrite_log "$(basename -- "$_dir")"
        fi
    done
}

lookup_domain() {
    _ip=$1
    command -v getent >/dev/null 2>&1 || return 0
    command -v timeout >/dev/null 2>&1 || return 0
    _line=$(timeout 2 getent hosts "$_ip" 2>/dev/null | head -n 1 || true)
    [ -n "$_line" ] || return 0
    printf '%s\n' "$_line" | awk -v ip="$1" '
        NF >= 2 {
            name = $2
            sub(/\.$/, "", name)
            if (name != "" && name != ip && name != $1) print name
        }
    '
}

dequeue_ip() {
    for _q in "$RUNDIR/q_pub" "$RUNDIR/q_priv"; do
        if [ -s "$_q" ]; then
            _ip=$(head -n 1 "$_q")
            tail -n +2 "$_q" > "$_q.next"
            mv "$_q.next" "$_q"
            printf '%s\n' "$_ip"
            return 0
        fi
    done
    return 1
}

resolve_some() {
    _left=$1
    while [ "$_left" -gt 0 ]; do
        _ip=$(dequeue_ip) || return 0
        _dom=$(lookup_domain "$_ip" || true)
        if [ -n "$_dom" ]; then
            apply_domain "$_ip" "$_dom"
        else
            : > "$RUNDIR/nodomain/$_ip"
        fi
        _left=$((_left - 1))
    done
}

import_logs() {
    _today=$(date +%Y-%m-%d)
    for _file in "$LOGDIR"/*_"$_today".log; do
        [ -f "$_file" ] || continue
        _base=$(basename -- "$_file" .log)
        _safe=${_base%_"$_today"}
        [ -n "$_safe" ] || continue
        _dir=$RUNDIR/apps/$_safe
        mkdir -p "$_dir"
        : > "$_dir/paths"
        : > "$_dir/eps"
        _header=0
        while IFS= read -r _line || [ -n "$_line" ]; do
            case $_line in
                '') continue ;;
                '#'*)
                    _val=$(printf '%s' "$_line" | sed 's/^#[[:space:]]*//')
                    if [ "$_header" -eq 0 ]; then
                        printf '%s\n' "$_val" > "$_dir/name"
                        _header=1
                    else
                        case $_val in
                            '(путь недоступен)') ;;
                            *) printf '%s\n' "$_val" >> "$_dir/paths" ;;
                        esac
                    fi
                    ;;
                '['*)
                    _ip=${_line%%]*}
                    _ip=${_ip#\[}
                    _rest=${_line#*]:}
                    _port=${_rest%%[[:space:]]*}
                    _dom=$(printf '%s' "${_rest#"$_port"}" | sed 's/^[[:space:]]*//')
                    _ip=$(printf '%s' "$_ip" | tr 'A-F' 'a-f')
                    _ep=$(format_ep "$_ip" "$_port")
                    printf '%s\t%s\t%s\n' "$_ep" "$_ip" "$_dom" >> "$_dir/eps"
                    [ -n "$_dom" ] || enqueue_ip "$_ip"
                    ;;
                *)
                    _ip=${_line%%:*}
                    _rest=${_line#*:}
                    _port=${_rest%%[[:space:]]*}
                    _dom=$(printf '%s' "${_rest#"$_port"}" | sed 's/^[[:space:]]*//')
                    _ip=$(printf '%s' "$_ip" | tr 'A-F' 'a-f')
                    _ep=$(format_ep "$_ip" "$_port")
                    printf '%s\t%s\t%s\n' "$_ep" "$_ip" "$_dom" >> "$_dir/eps"
                    [ -n "$_dom" ] || enqueue_ip "$_ip"
                    ;;
            esac
        done < "$_file"
        if [ ! -s "$_dir/name" ]; then
            printf '%s\n' "$_safe" > "$_dir/name"
        fi
    done
}

collect_connections() {
    _snap=$RUNDIR/ss.out
    _parsed=$RUNDIR/parsed.tsv
    if ! ss -tnp > "$_snap" 2>/dev/null; then
        : > "$_snap"
    fi
    awk '
        function is_state(s) {
            return s ~ /^(ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT-1|FIN-WAIT-2|TIME-WAIT|CLOSE|CLOSE-WAIT|LAST-ACK|CLOSING|LISTEN)$/
        }
        function host_of(addr,    n, i, parts, ip) {
            if (addr ~ /^\[/) {
                sub(/^\[/, "", addr)
                n = index(addr, "]:")
                if (n > 0) return substr(addr, 1, n - 1)
            }
            n = split(addr, parts, ":")
            ip = parts[1]
            for (i = 2; i < n; i++) ip = ip ":" parts[i]
            return ip
        }
        function port_of(addr,    n, parts) {
            if (addr ~ /^\[/) {
                n = index(addr, "]:")
                if (n > 0) return substr(addr, n + 2)
            }
            n = split(addr, parts, ":")
            return parts[n]
        }
        function emit(kind, lport, rip, rport, proc,    rest, token, name, pid) {
            if (proc == "") return
            rest = proc
            while (match(rest, /\("[^"]*",pid=[0-9]+/)) {
                token = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                name = token
                sub(/^\("/, "", name)
                sub(/",pid=[0-9]+$/, "", name)
                pid = token
                sub(/^.*pid=/, "", pid)
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", kind, pid, name, lport, rip, rport
            }
        }
        {
            line = $0
            proc = ""
            if (match(line, /users:\(\(.*\)\)/)) {
                proc = substr(line, RSTART, RLENGTH)
                line = substr(line, 1, RSTART - 1)
            }
            n = split(line, f, /[ \t]+/)
            local = ""
            peer = ""
            for (i = 1; i <= n; i++) {
                if (is_state(f[i]) && i + 4 <= n) {
                    local = f[i + 3]
                    peer = f[i + 4]
                    break
                }
            }
            if (local == "" || peer == "") next
            lport = port_of(local)
            rip = host_of(peer)
            rport = port_of(peer)
            if (rport == "*" || rport == "0" || rip == "*" || rip == "0.0.0.0" || rip == "::") {
                emit("listen", lport, "", "", proc)
            } else {
                emit("conn", lport, rip, rport, proc)
            }
        }
    ' "$_snap" > "$_parsed"

    : > "$RUNDIR/listen.list"
    : > "$RUNDIR/conns.list"
    while IFS=$(printf '\t') read -r _kind _pid _name _lport _rip _rport || [ -n "${_kind:-}" ]; do
        [ -n "${_kind:-}" ] || continue
        case $_kind in
            listen)
                printf '%s:%s\n' "$_pid" "$_lport" >> "$RUNDIR/listen.list"
                ;;
            conn)
                printf '%s\t%s\t%s\t%s\t%s\n' "$_pid" "$_name" "$_lport" "$_rip" "$_rport" >> "$RUNDIR/conns.list"
                ;;
        esac
    done < "$_parsed"

    while IFS=$(printf '\t') read -r _pid _name _lport _rip _rport || [ -n "${_pid:-}" ]; do
        [ -n "${_pid:-}" ] || continue
        case $_rport in
            ''|*[!0-9]*) continue ;;
        esac
        is_ignored "$_rip" && continue
        if grep -Fxq "$_pid:$_lport" "$RUNDIR/listen.list"; then
            continue
        fi
        _info=$(proc_info "$_pid" "$_name")
        _pname=${_info%%	*}
        _ppath=${_info#*	}
        add_endpoint "$_pname" "$_ppath" "$_rip" "$_rport"
    done < "$RUNDIR/conns.list"
}

import_logs

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'Без прав root видны не все приложения, а путь к программе может быть пустым.'
fi
printf 'Мониторинг сети запущен.\n'
printf 'Логи: %s\n' "$LOGDIR"
printf 'Интервал: %s сек. Остановка: Ctrl+C\n\n' "$INTERVAL"

while true; do
    collect_connections
    resolve_some 4
    if [ "$ONCE" -eq 1 ]; then
        _deadline=$(( $(date +%s) + 8 ))
        while [ "$(date +%s)" -lt "$_deadline" ]; do
            if [ ! -s "$RUNDIR/q_pub" ] && [ ! -s "$RUNDIR/q_priv" ]; then
                break
            fi
            resolve_some 4
        done
        break
    fi
    sleep "$INTERVAL"
done
