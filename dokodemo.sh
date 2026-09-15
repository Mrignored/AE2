#!/usr/bin/env bash
# =============================================================================
# dokodemo.sh — Dokodemo-Door tunnel manager + relay network tuning (Xray core)
#
# Main menu:
#   1) Add New Doko
#   2) Manage Doko
#   3) Uninstall Doko
#   0) Exit
#
# aestun is NOT touched by uninstall.
# =============================================================================

set -uo pipefail

DEFAULT_DEST="${DOKO_DEST:-10.8.0.2}"
DEFAULT_PORT="${DOKO_PORT:-2522}"
API_PORT=62789

CONF_DIR="/usr/local/etc/xray"
CONF="${CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

SYSCTL_FILE="/etc/sysctl.d/99-zz-dokodemo.conf"
UNIT_DROPIN_DIR="/etc/systemd/system/xray.service.d"
UNIT_DROPIN="${UNIT_DROPIN_DIR}/20-dokodemo-tuning.conf"
DISABLED_FILE="${CONF_DIR}/dokodemo-disabled.json"
BUFFER_KB="${DOKO_BUFFER_KB:-512}"

if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'
    D=$'\e[2m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
    R=""; G=""; Y=""; C=""; D=""; BOLD=""; N=""
fi

msg()  { printf '%s\n' "${G}[OK]${N} $*"; }
warn() { printf '%s\n' "${Y}[!]${N} $*"; }
err()  { printf '%s\n' "${R}[X]${N} $*" >&2; }
hdr()  { printf '\n%s\n' "${BOLD}${C}== $* ==${N}"; }
pause(){ printf '\n%s' "${D}Press Enter to continue...${N}"; read -r _; }

need_root() {
    [[ $EUID -eq 0 ]] || { err "Run as root (sudo)."; exit 1; }
}

valid_port() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

valid_addr() {
    local a="${1:-}"
    [[ -n "$a" ]] || return 1
    [[ "$a" =~ ^[0-9a-fA-F:.\-]+$ || "$a" =~ ^[A-Za-z0-9.-]+$ ]]
}

py() {
    python3 -c "$1" "${@:2}"
}

# =============================================================================
# Disabled Doko state
# =============================================================================

ensure_disabled_file() {
    mkdir -p "$CONF_DIR"
    [[ -f "$DISABLED_FILE" ]] || printf '{}\n' > "$DISABLED_FILE"
}

is_disabled() {
    local port="$1"
    [[ -f "$DISABLED_FILE" ]] || return 1

    py '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if data.get(sys.argv[2]) is True else 1)
' "$DISABLED_FILE" "$port"
}

set_disabled() {
    local port="$1"
    ensure_disabled_file

    py '
import json, sys
file, port = sys.argv[1], sys.argv[2]
try:
    with open(file) as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data[port] = True
with open(file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$DISABLED_FILE" "$port"
}

clear_disabled() {
    local port="$1"
    ensure_disabled_file

    py '
import json, sys
file, port = sys.argv[1], sys.argv[2]
try:
    with open(file) as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
data.pop(port, None)
with open(file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$DISABLED_FILE" "$port"
}

# =============================================================================
# Network tuning
# =============================================================================

write_sysctl() {
    cat > "$SYSCTL_FILE" <<'EOF'
# Managed by dokodemo.sh — relay-side tuning only.

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_no_metrics_save = 1
EOF
}

net_tune() {
    local quiet="${1:-}"

    write_sysctl

    if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
        [[ "$quiet" == "quiet" ]] || msg "Relay sysctl applied (${SYSCTL_FILE})."
    else
        warn "Some sysctl keys were rejected by this kernel:"
        sysctl -p "$SYSCTL_FILE" 2>&1 | grep -i "cannot\|error" | head -5
    fi

    mkdir -p "$UNIT_DROPIN_DIR"

    cat > "$UNIT_DROPIN" <<'EOF'
# Managed by dokodemo.sh.
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
Restart=always
RestartSec=3
EOF

    systemctl daemon-reload
    [[ "$quiet" == "quiet" ]] || msg "Xray service limits applied (${UNIT_DROPIN})."
}

tune_off() {
    hdr "Reverting relay tuning"
    rm -f "$SYSCTL_FILE" "$UNIT_DROPIN"
    systemctl daemon-reload
    msg "Removed Dokodemo relay tuning."
    warn "aestun's own sysctl file was not touched."
    warn "Kernel values stay as-is until reboot or: sysctl --system"
}

show_tuning() {
    hdr "Relay tuning in effect"

    sysctl -n \
        net.core.somaxconn \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_notsent_lowat \
        net.ipv4.tcp_no_metrics_save \
        2>/dev/null |
    paste -d'|' - - - - - |
    while IFS='|' read -r a b c d e; do
        printf '  somaxconn=%s  local_ports=%s  tw_reuse=%s  notsent_lowat=%s  no_metrics_save=%s\n' \
            "$a" "$b" "$c" "$d" "$e"
    done

    hdr "Left to aestun (unchanged)"
    printf '  congestion=%s  qdisc=%s  rmem_max=%s  mtu_probing=%s\n' \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null)" \
        "$(sysctl -n net.core.rmem_max 2>/dev/null)" \
        "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
}

# =============================================================================
# Xray config
# =============================================================================

backup_conf() {
    [[ -f "$CONF" ]] || return 0
    cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    ls -1t "${CONF}".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
}

ensure_conf() {
    mkdir -p "$CONF_DIR" /var/log/xray
    [[ -f "$CONF" ]] || echo '{}' > "$CONF"

    py '
import json, sys

conf, api_port, buf = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

try:
    with open(conf) as f:
        c = json.load(f)
except (ValueError, OSError):
    c = {}

if not isinstance(c, dict):
    c = {}

c["log"] = {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
}

c["policy"] = {
    "levels": {
        "0": {
            "handshake": 4,
            "connIdle": 300,
            "uplinkOnly": 2,
            "downlinkOnly": 5,
            "bufferSize": buf,
        }
    },
    "system": {
        "statsInboundUplink": False,
        "statsInboundDownlink": False,
    },
}

ibs = c.setdefault("inbounds", [])
ibs[:] = [i for i in ibs if i.get("tag") != "api"]

ibs.insert(0, {
    "listen": "127.0.0.1",
    "port": api_port,
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"},
    "tag": "api",
})

c["outbounds"] = [
    {
        "protocol": "freedom",
        "tag": "direct",
        "settings": {"domainStrategy": "AsIs"},
        "streamSettings": {
            "sockopt": {
                "tcpNoDelay": True,
                "tcpKeepAliveIdle": 60,
                "tcpKeepAliveInterval": 15,
                "tcpcongestion": "bbr",
            }
        },
    },
    {"protocol": "blackhole", "tag": "blocked"},
]

with open(conf, "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
' "$CONF" "$API_PORT" "$BUFFER_KB" || {
        err "Could not normalise ${CONF}"
        return 1
    }
}

# =============================================================================
# Add / Delete
# =============================================================================

add_rule() {
    local lport="$1" dport="$2" daddr="$3"

    backup_conf
    ensure_conf || return 1
    clear_disabled "$lport"

    py '
import json, sys

conf, lport, dport, daddr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

with open(conf) as f:
    c = json.load(f)

ibs = c.setdefault("inbounds", [])

ibs[:] = [
    i for i in ibs
    if not (
        i.get("protocol") == "dokodemo-door"
        and i.get("tag") != "api"
        and i.get("port") == lport
    )
]

ibs.append({
    "listen": None,
    "port": lport,
    "protocol": "dokodemo-door",
    "settings": {
        "address": daddr,
        "followRedirect": False,
        "network": "tcp,udp",
        "port": dport,
    },
    "streamSettings": {
        "sockopt": {
            "tcpFastOpen": True,
            "tcpNoDelay": True,
            "tcpKeepAliveIdle": 60,
            "tcpKeepAliveInterval": 15,
            "tcpcongestion": "bbr",
        }
    },
    "tag": "inbound-%d" % lport,
})

with open(conf, "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
' "$CONF" "$lport" "$dport" "$daddr" || {
        err "Failed to edit ${CONF}"
        return 1
    }

    msg "Rule set: ${BOLD}:${lport}${N} -> ${BOLD}${daddr}:${dport}${N}"
}

del_rule() {
    local lport="$1"

    [[ -f "$CONF" ]] || {
        err "No config at ${CONF}"
        return 1
    }

    backup_conf
    ensure_conf || return 1

    local removed

    removed=$(py '
import json, sys

conf, lport = sys.argv[1], int(sys.argv[2])

with open(conf) as f:
    c = json.load(f)

ibs = c.get("inbounds", [])
before = len(ibs)

ibs[:] = [
    i for i in ibs
    if not (
        i.get("protocol") == "dokodemo-door"
        and i.get("tag") != "api"
        and i.get("port") == lport
    )
]

with open(conf, "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")

print(before - len(ibs))
' "$CONF" "$lport") || {
        err "Failed to edit ${CONF}"
        return 1
    }

    clear_disabled "$lport"

    if [[ "$removed" == "0" ]]; then
        warn "No rule was listening on ${lport}."
    else
        msg "Removed the rule on port ${lport}."
    fi
}

# =============================================================================
# List rules
# =============================================================================

list_rules() {
    [[ -f "$CONF" ]] || {
        printf '  (no config yet)\n'
        return 0
    }

    py '
import json, sys

try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception:
    print("  (config unreadable)")
    raise SystemExit

rows = [
    i for i in c.get("inbounds", [])
    if i.get("protocol") == "dokodemo-door"
    and i.get("tag") != "api"
]

if not rows:
    print("  (no forwarding rules)")
else:
    print("  %-8s %-10s %-28s %s" % (
        "LISTEN", "STATUS", "DESTINATION", "TAG"
    ))

    disabled = {}

    try:
        with open(sys.argv[2]) as f:
            disabled = json.load(f)
    except Exception:
        pass

    for i in sorted(rows, key=lambda r: r.get("port", 0)):
        port = i.get("port")
        s = i.get("settings", {})
        status = "STOPPED" if disabled.get(str(port)) is True else "RUNNING"

        print("  %-8s %-10s %-28s %s" % (
            port,
            status,
            "%s:%s" % (s.get("address"), s.get("port")),
            i.get("tag", "")
        ))
' "$CONF" "$DISABLED_FILE"
}

# =============================================================================
# Install Xray
# =============================================================================

install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        msg "Xray present: $("$XRAY_BIN" version 2>/dev/null | head -1)"
        return 0
    fi

    hdr "Installing Xray core"

    command -v curl >/dev/null || {
        apt-get update -qq &&
        apt-get install -y curl
    }

    bash -c "$(curl -L "$INSTALL_URL")" @ install || {
        err "Xray install failed."
        return 1
    }

    [[ -x "$XRAY_BIN" ]] || {
        err "Xray binary missing after install."
        return 1
    }

    msg "Xray installed: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

# =============================================================================
# Apply
# =============================================================================

apply() {
    hdr "Applying configuration"

    if ! "$XRAY_BIN" run -test -config "$CONF" >/dev/null 2>&1; then
        err "Config failed validation — service NOT restarted."
        "$XRAY_BIN" run -test -config "$CONF" 2>&1 | tail -10
        return 1
    fi

    msg "Config syntax is valid."

    systemctl enable xray >/dev/null 2>&1

    systemctl restart xray || {
        err "systemctl restart xray failed."
        return 1
    }

    sleep 1

    if systemctl is-active --quiet xray; then
        msg "xray is running."
    else
        err "xray is not running:"
        journalctl -u xray -n 20 --no-pager
        return 1
    fi
}

# =============================================================================
# Status
# =============================================================================

show_status() {
    hdr "Services"

    printf '  xray:            %s\n' \
        "$(systemctl is-active xray 2>/dev/null || echo not-installed)"

    printf '  aestun (tunnel): %s\n' \
        "$(systemctl is-active aestun 2>/dev/null || echo absent)"

    hdr "Forwarding rules"
    list_rules

    hdr "Listening sockets"

    ss -tulnp 2>/dev/null |
        grep -i xray ||
        echo "  (none)"

    hdr "Destination reachability"

    [[ -f "$CONF" ]] || return 0

    while read -r addr port; do
        [[ -n "${addr:-}" ]] || continue

        if timeout 4 bash -c \
            "cat < /dev/null > /dev/tcp/${addr}/${port}" \
            2>/dev/null; then

            printf '  %s%s:%s reachable%s\n' \
                "$G" "$addr" "$port" "$N"
        else
            printf '  %s%s:%s NOT reachable%s\n' \
                "$R" "$addr" "$port" "$N"
        fi
    done < <(
        py '
import json, sys

try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception:
    raise SystemExit

for i in c.get("inbounds", []):
    if (
        i.get("protocol") == "dokodemo-door"
        and i.get("tag") != "api"
    ):
        s = i.get("settings", {})
        print(s.get("address"), s.get("port"))
' "$CONF"
    )

    show_tuning
}

# =============================================================================
# Manage one Doko
# =============================================================================

manage_one_doko() {
    local port="$1"
    local choice
    local ans

    while true; do
        clear 2>/dev/null
        hdr "Manage Doko :${port}"

        py '
import json, sys

with open(sys.argv[1]) as f:
    c = json.load(f)

port = int(sys.argv[2])

for i in c.get("inbounds", []):
    if (
        i.get("protocol") == "dokodemo-door"
        and i.get("tag") != "api"
        and i.get("port") == port
    ):
        s = i.get("settings", {})
        print("  Listen      : :%s" % port)
        print("  Destination: %s:%s" % (s.get("address"), s.get("port")))
        raise SystemExit

print("  Rule not found.")
' "$CONF" "$port"

        if is_disabled "$port"; then
            printf '  Status      : %sSTOPPED%s\n' "$R" "$N"
        else
            printf '  Status      : %sRUNNING%s\n' "$G" "$N"
        fi

        printf '\n'
        printf '  1) Remove\n'
        printf '  2) Stop\n'
        printf '  3) Restart\n'
        printf '  0) Back\n\n'
        printf '  Choice: '

        read -r choice

        case "$choice" in
            1)
                printf '  Are you sure you want to remove :%s? [y/N]: ' "$port"
                read -r ans

                if [[ "$ans" =~ ^[yY]$ ]]; then
                    if del_rule "$port" && apply; then
                        msg "Doko :${port} removed."
                    fi
                    pause
                    return
                fi
                ;;

            2)
                if is_disabled "$port"; then
                    warn "Doko :${port} is already stopped."
                else
                    set_disabled "$port"

                    if apply; then
                        msg "Doko :${port} stopped."
                    else
                        clear_disabled "$port"
                        err "Could not stop Doko :${port}."
                    fi
                fi

                pause
                ;;

            3)
                clear_disabled "$port"

                if apply; then
                    msg "Doko :${port} restarted."
                else
                    err "Could not restart Doko :${port}."
                fi

                pause
                ;;

            0)
                return
                ;;

            *)
                err "Unknown choice."
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# Manage Doko list
# =============================================================================

manage_doko() {
    local ports=()
    local choice
    local selected_port

    [[ -f "$CONF" ]] || {
        warn "No Dokodemo configuration exists."
        pause
        return
    }

    mapfile -t ports < <(
        py '
import json, sys

try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception:
    raise SystemExit

rows = [
    i for i in c.get("inbounds", [])
    if (
        i.get("protocol") == "dokodemo-door"
        and i.get("tag") != "api"
    )
]

for i in sorted(rows, key=lambda x: x.get("port", 0)):
    print(i.get("port"))
' "$CONF"
    )

    if (( ${#ports[@]} == 0 )); then
        warn "No Dokodemo rules found."
        pause
        return
    fi

    while true; do
        clear 2>/dev/null
        hdr "Manage Doko"

        local i=1
        local port

        for port in "${ports[@]}"; do
            local destination

            destination=$(
                py '
import json, sys

with open(sys.argv[1]) as f:
    c = json.load(f)

port = int(sys.argv[2])

for x in c.get("inbounds", []):
    if (
        x.get("protocol") == "dokodemo-door"
        and x.get("tag") != "api"
        and x.get("port") == port
    ):
        s = x.get("settings", {})
        print("%s:%s" % (s.get("address"), s.get("port")))
        break
' "$CONF" "$port"
            )

            if is_disabled "$port"; then
                printf '  %d) :%s -> %s  [%sSTOPPED%s]\n' \
                    "$i" "$port" "$destination" "$R" "$N"
            else
                printf '  %d) :%s -> %s  [%sRUNNING%s]\n' \
                    "$i" "$port" "$destination" "$G" "$N"
            fi

            ((i++))
        done

        printf '\n  0) Back\n\n'
        printf '  Select Doko: '
        read -r choice

        if [[ "$choice" == "0" ]]; then
            return
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            (( choice >= 1 && choice <= ${#ports[@]} )); then

            selected_port="${ports[$((choice - 1))]}"

            manage_one_doko "$selected_port"

            mapfile -t ports < <(
                py '
import json, sys

try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception:
    raise SystemExit

rows = [
    i for i in c.get("inbounds", [])
    if (
        i.get("protocol") == "dokodemo-door"
        and i.get("tag") != "api"
    )
]

for i in sorted(rows, key=lambda x: x.get("port", 0)):
    print(i.get("port"))
' "$CONF"
            )

            (( ${#ports[@]} == 0 )) && return
        else
            err "Invalid selection."
            sleep 1
        fi
    done
}

# =============================================================================
# Wizard
# =============================================================================

wizard() {
    local daddr lport dport ans ports p n=0

    hdr "Destination"

    printf '  Address on the far side of the tunnel [%s]: ' "$DEFAULT_DEST"
    read -r daddr
    daddr="${daddr:-$DEFAULT_DEST}"

    valid_addr "$daddr" || {
        err "That does not look like an address."
        return 1
    }

    if timeout 3 ping -c 1 -W 2 "$daddr" >/dev/null 2>&1; then
        msg "$daddr answers ping."
    else
        warn "$daddr does not answer ping — continuing anyway."
    fi

    hdr "Ports"

    printf '  %s\n' \
        "${D}Enter one or several ports (space or comma separated).${N}"

    while true; do
        if (( n == 0 )); then
            printf '  Port(s) to forward [%s]: ' "$DEFAULT_PORT"
            read -r ports
            ports="${ports:-$DEFAULT_PORT}"
        else
            printf '  Additional port(s): '
            read -r ports
            [[ -n "${ports// /}" ]] || break
        fi

        for p in ${ports//,/ }; do
            valid_port "$p" || {
                err "Skipping '${p}' — not a valid port."
                continue
            }

            if ss -tuln 2>/dev/null |
                grep -qE "[:.]${p}\b" &&
                ! grep -q "\"port\": ${p}," "$CONF" 2>/dev/null; then

                warn "Port ${p} already has a listener from another service."
                printf '  Use it anyway? [y/N]: '
                read -r ans

                [[ "$ans" =~ ^[yY]$ ]] || continue
            fi

            printf '  Destination port for :%s [%s]: ' "$p" "$p"
            read -r dport
            dport="${dport:-$p}"

            valid_port "$dport" || {
                err "Invalid destination port — skipping ${p}."
                continue
            }

            if add_rule "$p" "$dport" "$daddr"; then
                n=$((n + 1))
            fi
        done

        printf '\n  Add another port? [y/N]: '
        read -r ans

        [[ "$ans" =~ ^[yY]$ ]] || break
    done

    (( n > 0 )) || {
        warn "No rules were added."
        return 1
    }

    return 0
}

# =============================================================================
# Uninstall
# =============================================================================

uninstall() {
    hdr "Uninstall Dokodemo"

    printf '%s\n' \
        "${Y}This removes Xray and files created by dokodemo.sh.${N}"
    printf '%s\n' \
        "${Y}aestun and its configuration will NOT be touched.${N}"

    printf '\n  Continue? [y/N]: '
    read -r ans

    [[ "$ans" =~ ^[yY]$ ]] || {
        warn "Cancelled."
        return
    }

    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    if command -v curl >/dev/null 2>&1; then
        bash -c "$(curl -fsSL "$INSTALL_URL")" @ remove --purge \
            >/tmp/dokodemo-xray-uninstall.log 2>&1 ||
            warn "Official Xray uninstall returned an error."
    else
        warn "curl is unavailable; removing Xray files manually."
    fi

    rm -f "$SYSCTL_FILE"
    rm -f "$UNIT_DROPIN"
    rm -f "$DISABLED_FILE"

    systemctl daemon-reload

    rm -rf "$CONF_DIR"
    rm -rf /var/log/xray
    rm -f "$XRAY_BIN"

    rmdir "$UNIT_DROPIN_DIR" 2>/dev/null || true

    sysctl --system >/dev/null 2>&1 || true

    msg "Dokodemo/Xray installation removed."

    printf '\n  aestun status: %s\n' \
        "$(systemctl is-active aestun 2>/dev/null || echo absent)"

    msg "aestun was not modified."
}

# =============================================================================
# Main menu
# =============================================================================

menu() {
    while true; do
        clear 2>/dev/null

        printf '%s\n' \
            "${BOLD}${C}  Dokodemo-Door tunnel manager${N}"

        printf '%s\n' \
            "${D}  Xray core · relay tuning · aestun untouched${N}"

        hdr "Current state"

        printf '  xray: %s   |   tunnel (aestun): %s\n' \
            "$(systemctl is-active xray 2>/dev/null || echo not-installed)" \
            "$(systemctl is-active aestun 2>/dev/null || echo absent)"

        printf '\n'
        printf '  1) Add New Doko\n'
        printf '  2) Manage Doko\n'
        printf '  3) Uninstall Doko\n'
        printf '  0) Exit\n\n'
        printf '  Choice: '

        read -r ch

        case "$ch" in
            1)
                install_xray &&
                    wizard &&
                    apply
                pause
                ;;

            2)
                manage_doko
                ;;

            3)
                uninstall
                pause
                ;;

            0)
                exit 0
                ;;

            *)
                err "Unknown choice."
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# Entry
# =============================================================================

need_root

command -v python3 >/dev/null || {
    apt-get update -qq &&
    apt-get install -y python3
}

CMD="${1:-menu}"

case "$CMD" in
    list|status|logs|tune-off|uninstall)
        ;;
    *)
        [[ "${DOKO_TUNE:-1}" == "1" ]] &&
            net_tune quiet
        ;;
esac

case "$CMD" in
    menu)
        menu
        ;;

    wizard)
        printf '%s\n' "${BOLD}${C}Dokodemo-Door setup${N}"
        printf '%s\n' "${D}Network tuning applied. aestun tunnel settings untouched.${N}"

        if [[ -f "$CONF" ]]; then
            hdr "Existing rules"
            list_rules
        fi

        install_xray || exit 1
        wizard || exit 1
        apply || exit 1
        show_status
        ;;

    install)
        install_xray || exit 1
        add_rule \
            "${2:-$DEFAULT_PORT}" \
            "${3:-${2:-$DEFAULT_PORT}}" \
            "${4:-$DEFAULT_DEST}" ||
            exit 1
        apply || exit 1
        show_status
        ;;

    add)
        valid_port "${2:-}" || {
            err "Usage: $0 add LISTEN_PORT [DEST_PORT] [DEST_ADDR]"
            exit 1
        }

        add_rule \
            "$2" \
            "${3:-$2}" \
            "${4:-$DEFAULT_DEST}" &&
            apply
        ;;

    del|delete|rm)
        valid_port "${2:-}" || {
            err "Usage: $0 del LISTEN_PORT"
            exit 1
        }

        del_rule "$2" && apply
        ;;

    list)
        list_rules
        ;;

    status)
        show_status
        ;;

    restart)
        apply
        ;;

    logs)
        journalctl -u xray -f --no-pager
        ;;

    tune)
        net_tune
        show_tuning
        ;;

    tune-off)
        tune_off
        ;;

    uninstall)
        uninstall
        ;;

    *)
        err "Unknown command: $CMD"
        exit 1
        ;;
esac
