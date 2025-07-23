#!/bin/bash

# === CONFIGURATION ===
REMOTE_RPC="https://aztec-alpha-testnet-fullnode.zkv.xyz"
AZTECSCAN_API_URL="https://aztec-alpha-testnet-fullnode.zkv.xyz"
DEFAULT_PORT=8080
CHECK_INTERVAL=10
MAX_RETRIES=3
LOCAL_IPS=("IP1" "IP2" "IP3") # укажи свои IP

# === TELEGRAM ===
bot_token="${BOT_TOKEN:-PASTE_YOUR_BOT_TOKEN_HERE}"
chat_id="${CHAT_ID:-PASTE_YOUR_CHAT_ID_HERE}"
server_name="$(hostname -I | awk '{print $1}')"
max_telegram_lines=30

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() {
    echo -e "${1}${2}${NC}" >&2
}

cleanup() {
    print_status $YELLOW "\n🛑 Monitoring interrupted by user."
    exit 0
}
trap cleanup SIGINT SIGTERM

check_dependencies() {
    for dep in jq curl; do
        if ! command -v $dep &>/dev/null; then
            print_status $RED "❌ Missing dependency: $dep"
            exit 1
        fi
    done
}

format_number() {
    [[ "$1" == "N/A" ]] && echo "N/A" && return
    echo "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'
}

calculate_percentage() {
    [[ "$1" == "N/A" || "$2" == "N/A" || "$2" -eq 0 ]] && echo "N/A" && return
    echo "scale=2; $1 * 100 / $2" | bc -l 2>/dev/null || echo "N/A"
}

get_latest_proven_block() {
    local latest=$(curl -s "$AZTECSCAN_API_URL?from=0&to=0" | jq -r '.[0].height')
    [[ -z "$latest" || "$latest" == "null" ]] && echo "N/A" && return
    echo "$latest"
}

get_remote_block() {
    print_status $CYAN "🔍 Getting remote block..."
    local rpc_resp=$(curl -s -m 5 -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' "$REMOTE_RPC")
    if [[ "$rpc_resp" != *"error"* ]]; then
        local block=$(echo "$rpc_resp" | jq -r ".result.proven.number")
        [[ "$block" =~ ^[0-9]+$ ]] && echo "$block|RPC" && return
    fi
    print_status $YELLOW "⚠️ RPC failed, trying AztecScan..."
    local fallback=$(get_latest_proven_block)
    [[ "$fallback" =~ ^[0-9]+$ ]] && echo "$fallback|AztecScan" && return
    echo "N/A|None"
}

escape_markdown() {
    sed -e 's/\`/\\`/g' -e 's/_/\\_/g' -e 's/\*/\\*/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$bot_token/sendMessage" \
        -d "chat_id=$chat_id" \
        -d "text=*[$server_name]* $(echo "$message" | escape_markdown)" \
        -d "parse_mode=Markdown" > /dev/null
}

# === INIT ===
check_dependencies
print_status $BLUE "🌐 Starting Aztec sync monitor..."
print_status $BLUE "⏱ Interval: ${CHECK_INTERVAL}s | Port: $DEFAULT_PORT"

check_count=0
error_count=0

while true; do
    ((check_count++))
    now=$(date '+%Y-%m-%d %H:%M:%S')
    print_status $PURPLE "\n🔄 Check #$check_count at $now"

    REMOTE_DATA=$(get_remote_block)
    REMOTE=$(echo "$REMOTE_DATA" | cut -d'|' -f1)
    REMOTE_SOURCE=$(echo "$REMOTE_DATA" | cut -d'|' -f2)

    if [[ "$REMOTE" == "N/A" ]]; then
        print_status $RED "❌ Failed to get remote block"
        ((error_count++))
        sleep $CHECK_INTERVAL
        continue
    fi

    REMOTE_DISPLAY=$(format_number "$REMOTE")
    print_status $GREEN "✅ Remote block: $REMOTE_DISPLAY ($REMOTE_SOURCE)"

    TELEGRAM_REPORT="Aztec Node Sync Report\nCheck: #$check_count\nTime: $now\nRemote: $REMOTE ($REMOTE_SOURCE)\n"

    for IP in "${LOCAL_IPS[@]}"; do
        LOCAL_RPC="http://$IP:$DEFAULT_PORT"
        print_status $CYAN "\n🌍 Checking $LOCAL_RPC"

        retry=0
        LOCAL_RESPONSE=""
        while [[ $retry -lt $MAX_RETRIES ]]; do
            LOCAL_RESPONSE=$(curl -s -m 5 -X POST -H 'Content-Type: application/json' \
                -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":1}' "$LOCAL_RPC")
            [[ -n "$LOCAL_RESPONSE" ]] && break
            ((retry++))
            print_status $YELLOW "⏳ Retry $retry/$MAX_RETRIES..."
            sleep 1
        done

        if [[ -z "$LOCAL_RESPONSE" || "$LOCAL_RESPONSE" == *"error"* ]]; then
            print_status $RED "❌ $IP unreachable"
            TELEGRAM_REPORT+="\n$IP: ❌ Unreachable"
            ((error_count++))
            continue
        fi

        LOCAL=$(echo "$LOCAL_RESPONSE" | jq -r ".result.proven.number")
        [[ "$LOCAL" == "null" || -z "$LOCAL" ]] && LOCAL="N/A"

        LOCAL_DISPLAY=$(format_number "$LOCAL")
        PERCENTAGE=$(calculate_percentage "$LOCAL" "$REMOTE")

        print_status $CYAN "📊 $IP — Local: $LOCAL_DISPLAY | Remote: $REMOTE_DISPLAY | Progress: $PERCENTAGE%"
        TELEGRAM_REPORT+="\n$IP: Block $LOCAL / $REMOTE ($PERCENTAGE%)"
    done

    SUCCESS=$((check_count - error_count))
    TELEGRAM_REPORT+="\n\nSuccess: $SUCCESS\nErrors: $error_count\n"

    send_telegram_message "$TELEGRAM_REPORT"

    print_status $PURPLE "⏰ Sleeping ${CHECK_INTERVAL}s..."
    sleep $CHECK_INTERVAL
done
