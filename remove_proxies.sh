#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# remove_proxies.sh — Self-intelligent macOS proxy & DNS cleaner
#
# Discovers all network services dynamically and removes every proxy type
# (SOCKS, HTTP, HTTPS, FTP, PAC auto-proxy, proxy auto-discovery) and
# custom DNS server entries, restoring each service to a clean DHCP state.
#
# Usage: ./remove_proxies.sh [--dry-run] [--verbose] [--force] [--help]
# ---------------------------------------------------------------------------

# ── Global state ────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
FORCE=false
BACKUP_FILE=""
declare -a ALL_SERVICES=()
declare -a CHANGED_SERVICES=()
declare -a SKIPPED_SERVICES=()
declare -a ERROR_SERVICES=()

NETWORKSETUP=/usr/sbin/networksetup

# ── Output helpers ──────────────────────────────────────────────────────────
log_verbose() { $VERBOSE && echo "  [verbose] $*" || true; }

log_change() {
    local service="$1" desc="$2"
    if $DRY_RUN; then
        echo "  [dry-run] would remove: $desc"
    else
        echo "  [removed] $desc"
    fi
    # Append only once per service
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

# ── Argument parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Removes all proxy and custom DNS configurations from every macOS network
service, restoring them to clean DHCP-managed defaults.

Options:
  --dry-run    Show what would be changed without making any changes
  --verbose    Also report services that are already clean
  --force      Suppress VPN service warnings and clean them too
  --help       Show this help message

Examples:
  ./remove_proxies.sh --dry-run --verbose   # Preview all changes
  sudo ./remove_proxies.sh                  # Apply changes (may need sudo)
  ./remove_proxies.sh --force               # Also clean VPN services
EOF
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --verbose) VERBOSE=true ;;
            --force)   FORCE=true ;;
            --help|-h) usage; exit 0 ;;
            *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
        esac
    done
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
    if [[ "$EUID" -eq 0 ]]; then
        log_verbose "Running as root."
    elif sudo -n true 2>/dev/null; then
        log_verbose "sudo available without password."
    else
        echo "Warning: Not running as root. Some services may fail due to permissions."
        echo "         Re-run with sudo if changes are not applied."
        echo
    fi
}

# ── Service discovery ─────────────────────────────────────────────────────────
discover_services() {
    local line
    while IFS= read -r line; do
        # Skip the header line and disabled services (prefixed with *)
        [[ "$line" == An\ asterisk* ]] && continue
        [[ "$line" == \** ]] && continue
        [[ -z "$line" ]] && continue
        ALL_SERVICES+=("$line")
    done < <("$NETWORKSETUP" -listallnetworkservices 2>/dev/null)

    if [[ ${#ALL_SERVICES[@]} -eq 0 ]]; then
        echo "No network services found." >&2
        exit 1
    fi
    log_verbose "Found ${#ALL_SERVICES[@]} active network service(s)."
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
    log_verbose "Settings backed up to: $BACKUP_FILE"
}

# ── Run a networksetup mutation, detecting soft errors ───────────────────────
# networksetup often exits 0 but prints "** Error: ..." -- capture and check.
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

# ── Generic probe/remove for proxy types that have Enabled/Server/Port ───────
# probe_proxy <service> <get-flag>
# Returns: "ACTIVE", "CONFIGURED_DISABLED", or "CLEAN"
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

# remove_standard_proxy <service> <label> <get-flag> <state-flag> <set-flag>
remove_standard_proxy() {
    local service="$1" label="$2" get_flag="$3" state_flag="$4" set_flag="$5"
    local state
    state=$(probe_proxy "$service" "$get_flag")
    case "$state" in
        CLEAN)
            log_verbose "$label: already clean"
            return 0
            ;;
        ACTIVE|CONFIGURED_DISABLED)
            log_change "$service" "$label proxy on '$service'"
            $DRY_RUN && return 0
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
    if [[ "$state" == "CLEAN" ]]; then
        log_verbose "PAC auto-proxy: already clean"
        return 0
    fi
    log_change "$service" "PAC auto-proxy URL on '$service'"
    $DRY_RUN && return 0
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
    if [[ "$state" == "CLEAN" ]]; then
        log_verbose "Auto-proxy discovery: already clean"
        return 0
    fi
    log_change "$service" "Proxy auto-discovery on '$service'"
    $DRY_RUN && return 0
    if ! ns_run "$service" -setproxyautodiscovery "$service" off > /dev/null 2>&1; then
        log_error "$service" "Failed to disable proxy auto-discovery on '$service'"
    fi
}

# ── DNS servers ───────────────────────────────────────────────────────────────
probe_dns() {
    local service="$1"
    local out
    { set +e; out=$("$NETWORKSETUP" -getdnsservers "$service" 2>&1); set -e; } || true
    # "There aren't any DNS Servers set on..." means no custom DNS
    echo "$out" | grep -qi "aren't any" && echo "CLEAN" || echo "ACTIVE"
}

remove_dns() {
    local service="$1"
    local state
    state=$(probe_dns "$service")
    if [[ "$state" == "CLEAN" ]]; then
        log_verbose "DNS servers: already clean (using DHCP)"
        return 0
    fi
    log_change "$service" "Custom DNS servers on '$service'"
    $DRY_RUN && return 0
    if ! ns_run "$service" -setdnsservers "$service" empty > /dev/null 2>&1; then
        log_error "$service" "Failed to clear DNS servers on '$service'"
    fi
}

# ── VPN service guard ─────────────────────────────────────────────────────────
is_vpn_service() {
    local service="$1"
    echo "$service" | grep -qiE "vpn|l2tp|ipsec|ikev?2|wireguard|pptp"
}

# ── Process one service ───────────────────────────────────────────────────────
process_service() {
    local service="$1"
    local changed_before=${#CHANGED_SERVICES[@]}

    echo ""
    echo "-- ${service} --"

    # VPN guard
    if is_vpn_service "$service" && ! $FORCE; then
        echo "  [skipped] VPN service -- use --force to clean VPN services"
        SKIPPED_SERVICES+=("$service (VPN -- skipped)")
        return 0
    fi

    remove_standard_proxy "$service" "SOCKS"  -getsocksproxy    -setsocksproxystate    -setsocksproxy
    remove_standard_proxy "$service" "HTTP"   -getwebproxy      -setwebproxystate      -setwebproxy
    remove_standard_proxy "$service" "HTTPS"  -getsecurewebproxy -setsecurewebproxystate -setsecurewebproxy
    remove_standard_proxy "$service" "FTP"    -getftpproxy      -setftpproxystate      -setftpproxy
    remove_pac_proxy       "$service"
    remove_auto_discovery  "$service"
    remove_dns             "$service"

    # Track services with nothing to do
    if [[ ${#CHANGED_SERVICES[@]} -eq $changed_before ]]; then
        local in_errors=false
        local s; for s in "${ERROR_SERVICES[@]+"${ERROR_SERVICES[@]}"}"; do
            [[ "$s" == "$service" ]] && in_errors=true && break
        done
        if ! $in_errors; then
            SKIPPED_SERVICES+=("$service")
            log_verbose "  -> nothing to change"
        fi
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    echo
    echo "============================== Summary =============================="

    if [[ ${#CHANGED_SERVICES[@]} -gt 0 ]]; then
        local label="Cleaned"
        $DRY_RUN && label="Would clean"
        echo "${label} (${#CHANGED_SERVICES[@]}):"
        local s; for s in "${CHANGED_SERVICES[@]}"; do echo "  * $s"; done
    fi

    if [[ ${#SKIPPED_SERVICES[@]} -gt 0 ]]; then
        echo "Already clean / skipped (${#SKIPPED_SERVICES[@]}):"
        local s; for s in "${SKIPPED_SERVICES[@]}"; do echo "  * $s"; done
    fi

    if [[ ${#ERROR_SERVICES[@]} -gt 0 ]]; then
        echo "Errors (${#ERROR_SERVICES[@]}):"
        local s; for s in "${ERROR_SERVICES[@]}"; do echo "  * $s"; done
        echo "  Tip: Re-run with sudo if permission errors occurred."
    fi

    echo
    echo "Pre-change backup: ${BACKUP_FILE}"

    if $DRY_RUN; then
        echo
        echo "Dry-run mode -- no changes were made."
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    require_macos
    check_privileges

    echo "macOS Proxy & DNS Cleaner"
    echo "Active location: $("$NETWORKSETUP" -getcurrentlocation 2>/dev/null || echo unknown)"
    $DRY_RUN && echo "[dry-run mode -- no changes will be made]"
    echo

    discover_services
    backup_settings

    local service
    for service in "${ALL_SERVICES[@]}"; do
        process_service "$service"
    done

    print_summary
}

main "$@"
