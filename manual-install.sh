#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/monitoring-agent/monitoring-agent.env"

PACKAGE_PATH=""
ARCH=""
SKIP_BUILD=false
NO_START=false
declare -a SET_VARS=()

usage() {
    cat <<'EOF'
Usage: ./manual-install.sh [options]

Automates INSTALL.md Method 3:
1) Build .deb package
2) Install package with dpkg
3) Configure /etc/monitoring-agent/monitoring-agent.env
4) Enable/start monitoring-agent service

Options:
  --arch <amd64|arm64>     Build/install architecture (auto-detected by default)
  --package <path.deb>     Install this .deb package (skip auto package discovery)
  --skip-build             Skip build step
  --set KEY=VALUE          Set/update an env var in monitoring-agent.env (repeatable)
  --no-start               Do not restart/start service after install
  -h, --help               Show this help

Examples:
  ./manual-install.sh --set SERVER_TOKEN=abc123 --set POCKETBASE_URL=http://10.0.0.5:8090
  ./manual-install.sh --arch arm64 --set SERVER_TOKEN=abc123 --set POCKETBASE_URL=http://pb:8090
  SERVER_TOKEN=abc123 POCKETBASE_URL=http://pb:8090 ./manual-install.sh
EOF
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            echo "Error: unsupported architecture '$(uname -m)'. Use --arch." >&2
            exit 1
            ;;
    esac
}

is_nonempty_config_value() {
    local key="$1"
    [[ -f "$CONFIG_FILE" ]] && grep -Eq "^${key}=[^[:space:]].*" "$CONFIG_FILE"
}

set_config_var() {
    local key="$1"
    local value="$2"
    local tmp_file

    if [[ ! "$key" =~ ^[A-Z0-9_]+$ ]]; then
        echo "Error: invalid key '$key'. Use uppercase letters, numbers, underscore only." >&2
        exit 1
    fi

    tmp_file="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        BEGIN { found=0 }
        $0 ~ ("^#?[[:space:]]*" k "=") {
            print k "=" v
            found=1
            next
        }
        { print }
        END {
            if (!found) {
                print k "=" v
            }
        }
    ' "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
}

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ $# -ge 2 ]] || { echo "Error: --arch requires a value" >&2; exit 1; }
            ARCH="$2"
            shift 2
            ;;
        --package)
            [[ $# -ge 2 ]] || { echo "Error: --package requires a value" >&2; exit 1; }
            PACKAGE_PATH="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --set)
            [[ $# -ge 2 ]] || { echo "Error: --set requires KEY=VALUE" >&2; exit 1; }
            SET_VARS+=("$2")
            shift 2
            ;;
        --no-start)
            NO_START=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$ARCH" ]]; then
    ARCH="$(detect_arch)"
fi

if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
    echo "Error: --arch must be amd64 or arm64" >&2
    exit 1
fi

if [[ "$SKIP_BUILD" == false ]]; then
    echo "Building DEB package for $ARCH..."
    (cd "$SCRIPT_DIR" && ./build.sh deb "$ARCH")
fi

if [[ -z "$PACKAGE_PATH" ]]; then
    PACKAGE_PATH="$(ls -1t "$SCRIPT_DIR"/dist/monitoring-agent_*_"$ARCH".deb 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$PACKAGE_PATH" || ! -f "$PACKAGE_PATH" ]]; then
    echo "Error: DEB package not found. Build first or pass --package /path/file.deb" >&2
    exit 1
fi

echo "Installing package: $PACKAGE_PATH"
if ! dpkg -i "$PACKAGE_PATH"; then
    apt-get update
    apt-get install -f -y
fi

mkdir -p "$(dirname "$CONFIG_FILE")"
if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "/etc/monitoring-agent/monitoring-agent.env.example" ]]; then
        cp /etc/monitoring-agent/monitoring-agent.env.example "$CONFIG_FILE"
    elif [[ -f "$SCRIPT_DIR/packaging/monitoring-agent.conf" ]]; then
        cp "$SCRIPT_DIR/packaging/monitoring-agent.conf" "$CONFIG_FILE"
    else
        touch "$CONFIG_FILE"
    fi
fi

declare -A CONFIG_UPDATES=()

for key in \
    SERVER_TOKEN POCKETBASE_URL SERVER_NAME HOSTNAME IP_ADDRESS OS_TYPE \
    AGENT_ID CHECK_INTERVAL HEALTH_CHECK_PORT REMOTE_CONTROL_ENABLED \
    COMMAND_CHECK_INTERVAL REPORT_INTERVAL MAX_RETRIES REQUEST_TIMEOUT \
    MONITORING_DISK_PATH
do
    if [[ -n "${!key:-}" ]]; then
        CONFIG_UPDATES["$key"]="${!key}"
    fi
done

for pair in "${SET_VARS[@]}"; do
    if [[ "$pair" != *=* ]]; then
        echo "Error: invalid --set value '$pair'. Expected KEY=VALUE" >&2
        exit 1
    fi
    key="${pair%%=*}"
    value="${pair#*=}"
    CONFIG_UPDATES["$key"]="$value"
done

if [[ -z "${CONFIG_UPDATES[SERVER_TOKEN]:-}" ]] && ! is_nonempty_config_value "SERVER_TOKEN"; then
    echo "Error: SERVER_TOKEN is required. Set it via --set SERVER_TOKEN=... or environment." >&2
    exit 1
fi

if [[ -z "${CONFIG_UPDATES[POCKETBASE_URL]:-}" ]] && ! is_nonempty_config_value "POCKETBASE_URL"; then
    echo "Error: POCKETBASE_URL is required. Set it via --set POCKETBASE_URL=... or environment." >&2
    exit 1
fi

for key in "${!CONFIG_UPDATES[@]}"; do
    set_config_var "$key" "${CONFIG_UPDATES[$key]}"
done

if getent group monitoring-agent >/dev/null 2>&1; then
    chown root:monitoring-agent "$CONFIG_FILE"
else
    chown root:root "$CONFIG_FILE"
fi
chmod 640 "$CONFIG_FILE"

systemctl daemon-reload
systemctl enable monitoring-agent
if [[ "$NO_START" == false ]]; then
    systemctl restart monitoring-agent
fi

echo ""
echo "Installation complete."
echo "Config file: $CONFIG_FILE"
if [[ "$NO_START" == false ]]; then
    echo "Service status:"
    systemctl --no-pager --full status monitoring-agent || true
else
    echo "Service start skipped (--no-start)."
    echo "Run: sudo systemctl start monitoring-agent"
fi
