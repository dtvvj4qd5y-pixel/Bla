#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# remove_proxies.sh -- Self-intelligent macOS proxy & DNS cleaner
#
# Discovers all network services dynamically and removes every proxy type
# (SOCKS, HTTP, HTTPS, FTP, PAC auto-proxy, proxy auto-discovery) and
# custom DNS server entries on EVERY service (including VPN services),
# restoring each one to a clean DHCP state. Runs unconditionally -- no
# flags, no confirmation, no dry-run.
# ---------------------------------------------------------------------------

# ── Global state ────────────────────────────────────────────────────────────
BACKUP_FILE=""
declare -a ALL_SERVICES=()
declare -a CHANGED_SERVICES=()
declare -a SKIPPED_SERVICES=()
declare -a ERROR_SERVICES=()

NETWORKSETUP=/usr/sbin/networksetup

# ── Output helpers ──────────────────────────────────────────────────────────
log_change() {
    local service="$1" desc="$2"
    echo "  [removed] $desc"
    local already=false
    local s; for s in "${CHANGED_SERVICES[@]+"${CHANGED_SERVICES[@]}"}"; do
        [[ "$s" == "$service" ]] && already=true && break
    done
    $already || CHANGED_SERVICES+=("$service")
}

log_error() {
    local service="$1" msg="$2"
    echo "  [error] $msg" >&2
    local already=false
    local s; for s in "${ERROR_SERVICES[@]+"${ERROR_SERVICES[@]}"}"; do
        [[ "$s" == "$service" ]] && already=true && break
    done
    $already || ERROR_SERVICES+=("$service")
}

# ── macOS requirement check ───────────────────────────────────────────────────
require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "Error: This script requires macOS." >&2
        exit 1
    fi
    if [[ ! -x "$NETWORKSETUP" ]]; then
        echo "Error: networksetup not found at $NETWORKSETUP" >&2
        exit 1
    fi
}

# ── Privilege check ───────────────────────────────────────────────────────────
check_privileges() {
    if [[ "$EUID" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        echo "Warning: Not running as root. Some services may fail due to permissions."
        echo "         Re-run with sudo if changes are not applied."
        echo
    fi
}

# ── Service discovery ─────────────────────────────────────────────────────────
discover_services() {
    local line
    while IFS= read -r line; do
        [[ "$line" == An\ asterisk* ]] && continue
        [[ "$line" == \** ]] && continue
        [[ -z "$line" ]] && continue
        ALL_SERVICES+=("$line")
    done < <("$NETWORKSETUP" -listallnetworkservices 2>/dev/null)

    if [[ ${#ALL_SERVICES[@]} -eq 0 ]]; then
        echo "No network services found." >&2
        exit 1
    fi
    echo "Found ${#ALL_SERVICES[@]} active network service(s)."
}

# ── Backup current settings ──────────────────────────────────────────────────
backup_settings() {
    BACKUP_FILE=$(mktemp /tmp/proxy_backup_XXXXXX.txt)
    local service
    {
        echo "Proxy backup -- $(date)"
        echo "Active location: $("$NETWORKSETUP" -getcurrentlocation 2>/dev/null || echo unknown)"
        echo
        for service in "${ALL_SERVICES[@]}"; do
            echo "### BEGIN SERVICE: ${service} ###"
            echo "SOCKS:            $("$NETWORKSETUP" -getsocksproxy        "$service" 2>&1 || true)"
            echo "HTTP:             $("$NETWORKSETUP" -getwebproxy           "$service" 2>&1 || true)"
            echo "HTTPS:            $("$NETWORKSETUP" -getsecurewebproxy     "$service" 2>&1 || true)"
            echo "FTP:              $("$NETWORKSETUP" -getftpproxy            "$service" 2>&1 || true)"
            echo "PAC URL:          $("$NETWORKSETUP" -getautoproxyurl        "$service" 2>&1 || true)"
            echo "AUTO DISCOVERY:   $("$NETWORKSETUP" -getproxyautodiscovery  "$service" 2>&1 || true)"
            echo "DNS:              $("$NETWORKSETUP" -getdnsservers          "$service" 2>&1 || true)"
            echo "### END SERVICE: ${service} ###"
            echo
        done
    } > "$BACKUP_FILE" 2>/dev/null || true
    echo "Settings backed up to: $BACKUP_FILE"
}

# ── Run a networksetup mutation, detecting soft errors ───────────────────────
ns_run() {
    local service="$1"; shift
    local out
    out=$("$NETWORKSETUP" "$@" 2>&1) || true
    if echo "$out" | grep -qi "^\*\* error"; then
        echo "$out"
        return 1
    fi
    return 0
}

# ── Generic probe for Enabled/Server/Port proxies ────────────────────────────
probe_proxy() {
    local service="$1" flag="$2"
    local out enabled server
    { set +e; out=$("$NETWORKSETUP" "$flag" "$service" 2>&1); set -e; } || true
    enabled=$(echo "$out" | grep -i "^Enabled:" | awk '{print $2}' || true)
    server=$(echo  "$out" | grep -i "^Server:"  | awk '{print $2}' || true)
    if [[ "$enabled" == "Yes" ]]; then
        echo "ACTIVE"
    elif [[ -n "$server" && "$server" != "(null)" ]]; then
        echo "CONFIGURED_DISABLED"
    else
        echo "CLEAN"
    fi
}

remove_standard_proxy() {
    local service="$1" label="$2" get_flag="$3" state_flag="$4" set_flag="$5"
    local state
    state=$(probe_proxy "$service" "$get_flag")
    case "$state" in
        CLEAN) return 0 ;;
        ACTIVE|CONFIGURED_DISABLED)
            log_change "$service" "$label proxy on '$service'"
            if ! ns_run "$service" "$state_flag" "$service" off > /dev/null 2>&1; then
                log_error "$service" "Failed to disable $label proxy on '$service'"
                return 1
            fi
            if ! ns_run "$service" "$set_flag" "$service" "" 0 > /dev/null 2>&1; then
                log_error "$service" "Failed to clear $label proxy server on '$service'"
                return 1
            fi
            ;;
    esac
}

# ── PAC proxy ────────────────────────────────────────────────────────────────
probe_pac() {
    local service="$1"
    local out enabled
    { set +e; out=$("$NETWORKSETUP" -getautoproxyurl "$service" 2>&1); set -e; } || true
    enabled=$(echo "$out" | grep -i "^Enabled:" | awk '{print $2}' || true)
    [[ "$enabled" == "Yes" ]] && echo "ACTIVE" || echo "CLEAN"
}

remove_pac_proxy() {
    local service="$1"
    local state
    state=$(probe_pac "$service")
    [[ "$state" == "CLEAN" ]] && return 0
    log_change "$service" "PAC auto-proxy URL on '$service'"
    if ! ns_run "$service" -setautoproxystate "$service" off > /dev/null 2>&1; then
        log_error "$service" "Failed to disable PAC proxy on '$service'"
    fi
    ns_run "$service" -setautoproxyurl "$service" "" > /dev/null 2>&1 || true
}

# ── Proxy auto-discovery ──────────────────────────────────────────────────────
probe_auto_discovery() {
    local service="$1"
    local out
    { set +e; out=$("$NETWORKSETUP" -getproxyautodiscovery "$service" 2>&1); set -e; } || true
    echo "$out" | grep -qi "On$" && echo "ACTIVE" || echo "CLEAN"
}

remove_auto_discovery() {
    local service="$1"
    local state
    state=$(probe_auto_discovery "$service")
    [[ "$state" == "CLEAN" ]] && return 0
    log_change "$service" "Proxy auto-discovery on '$service'"
    if ! ns_run "$service" -setproxyautodiscovery "$service" off > /dev/null 2>&1; then
        log_error "$service" "Failed to disable proxy auto-discovery on '$service'"
    fi
}

# ── DNS servers ───────────────────────────────────────────────────────────────
probe_dns() {
    local service="$1"
    local out
    { set +e; out=$("$NETWORKSETUP" -getdnsservers "$service" 2>&1); set -e; } || true
    echo "$out" | grep -qi "aren't any" && echo "CLEAN" || echo "ACTIVE"
}

remove_dns() {
    local service="$1"
    local state
    state=$(probe_dns "$service")
    [[ "$state" == "CLEAN" ]] && return 0
    log_change "$service" "Custom DNS servers on '$service'"
    if ! ns_run "$service" -setdnsservers "$service" empty > /dev/null 2>&1; then
        log_error "$service" "Failed to clear DNS servers on '$service'"
    fi
}

# ── Process one service ───────────────────────────────────────────────────────
process_service() {
    local service="$1"
    local changed_before=${#CHANGED_SERVICES[@]}

    echo
    echo "-- ${service} --"

    remove_standard_proxy "$service" "SOCKS"  -getsocksproxy    -setsocksproxystate    -setsocksproxy
    remove_standard_proxy "$service" "HTTP"   -getwebproxy      -setwebproxystate      -setwebproxy
    remove_standard_proxy "$service" "HTTPS"  -getsecurewebproxy -setsecurewebproxystate -setsecurewebproxy
    remove_standard_proxy "$service" "FTP"    -getftpproxy      -setftpproxystate      -setftpproxy
    remove_pac_proxy       "$service"
    remove_auto_discovery  "$service"
    remove_dns             "$service"

    if [[ ${#CHANGED_SERVICES[@]} -eq $changed_before ]]; then
        local in_errors=false
        local s; for s in "${ERROR_SERVICES[@]+"${ERROR_SERVICES[@]}"}"; do
            [[ "$s" == "$service" ]] && in_errors=true && break
        done
        if ! $in_errors; then
            SKIPPED_SERVICES+=("$service")
            echo "  (already clean)"
        fi
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    echo
    echo "============================== Summary =============================="

    if [[ ${#CHANGED_SERVICES[@]} -gt 0 ]]; then
        echo "Cleaned (${#CHANGED_SERVICES[@]}):"
        local s; for s in "${CHANGED_SERVICES[@]}"; do echo "  * $s"; done
    fi

    if [[ ${#SKIPPED_SERVICES[@]} -gt 0 ]]; then
        echo "Already clean (${#SKIPPED_SERVICES[@]}):"
        local s; for s in "${SKIPPED_SERVICES[@]}"; do echo "  * $s"; done
    fi

    if [[ ${#ERROR_SERVICES[@]} -gt 0 ]]; then
        echo "Errors (${#ERROR_SERVICES[@]}):"
        local s; for s in "${ERROR_SERVICES[@]}"; do echo "  * $s"; done
        echo "  Tip: Re-run with sudo if permission errors occurred."
    fi

    echo
    echo "Pre-change backup: ${BACKUP_FILE}"
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    require_macos
    check_privileges

    echo "macOS Proxy & DNS Cleaner"
    echo "Active location: $("$NETWORKSETUP" -getcurrentlocation 2>/dev/null || echo unknown)"
    echo

    discover_services
    backup_settings

    local service
    for service in "${ALL_SERVICES[@]}"; do
        process_service "$service"
    done

    print_summary
}

main
