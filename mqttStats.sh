#!/bin/sh
# travelmate_mqtt_report.sh
# Collects router stats, Travelmate uplink, and 2.4GHz AP clients
# then publishes a JSON payload to an MQTT broker.
#
# Install:
#   cp travelmate_mqtt_report.sh /usr/local/bin/
#   chmod +x /usr/local/bin/travelmate_mqtt_report.sh
#
# Add to crontab (crontab -e):
#   */15 * * * * /usr/local/bin/travelmate_mqtt_report.sh
#
# Dependencies: travelmate, mosquitto-client-nossl (or mosquitto-client)
#   opkg update && opkg install mosquitto-client-nossl

# ─── Configuration ────────────────────────────────────────────────────────────
MQTT_BROKER="192.168.8.239"
MQTT_PORT="1883"
MQTT_TOPIC="router/conroy31fk/status"
MQTT_CLIENT_ID="r6220-travelmate"
# MQTT_USER="your_user"       # Uncomment if broker requires auth
# MQTT_PASS="your_password"   # Uncomment if broker requires auth

AP_SSID="CONROY31FK"
AP_IFACE="phy1-ap0"        # 2.4GHz interface (verify with: iw dev)
UPLINK_IFACE="phy1-sta0"    # 5GHz uplink interface (verify with: iw dev)

TRMD_STATUS_FILE="/var/run/travelmate/travelmate.json"
# ──────────────────────────────────────────────────────────────────────────────

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Escape a string for safe JSON embedding
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# ─── Router Stats ─────────────────────────────────────────────────────────────
UPTIME_SECS=$(cat /proc/uptime | awk '{print int($1)}')
UPTIME_HUMAN=$(awk -v s="$UPTIME_SECS" 'BEGIN{
    d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60)
    printf "%dd %dh %dm", d, h, m
}')

# Load averages (1m, 5m, 15m)
LOAD=$(cat /proc/loadavg)
LOAD1=$(echo "$LOAD" | awk '{print $1}')
LOAD5=$(echo "$LOAD" | awk '{print $2}')
LOAD15=$(echo "$LOAD" | awk '{print $3}')

# Memory (in kB)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
MEM_USED=$((MEM_TOTAL - MEM_FREE))
MEM_PCT=$(awk -v u="$MEM_USED" -v t="$MEM_TOTAL" 'BEGIN{printf "%.1f", (u/t)*100}')

# CPU temp (if available)
CPU_TEMP="null"
TEMP_FILE="/sys/class/thermal/thermal_zone0/temp"
if [ -f "$TEMP_FILE" ]; then
    RAW=$(cat "$TEMP_FILE")
    CPU_TEMP=$(awk -v t="$RAW" 'BEGIN{printf "%.1f", t/1000}')
fi

# Firmware / hostname
HOSTNAME=$(cat /proc/sys/kernel/hostname)
FW_VERSION=$(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d'"' -f2)
ROUTER_MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "unknown")

# ─── Travelmate: Active Uplink ─────────────────────────────────────────────────
UPLINK_NAME="unknown"
UPLINK_BSSID="unknown"
UPLINK_SIGNAL="null"
TRMD_STATUS="unknown"
TRMD_VERSION="unknown"

if [ -f "$TRMD_STATUS_FILE" ]; then
    # travelmate writes a JSON status file — parse the key fields with awk
    UPLINK_NAME=$(awk -F'"' '/"station_connection"/{print $4}' "$TRMD_STATUS_FILE" 2>/dev/null)
    TRMD_STATUS=$(awk -F'"' '/"travelmate_status"/{print $4}' "$TRMD_STATUS_FILE" 2>/dev/null)
    TRMD_VERSION=$(awk -F'"' '/"travelmate_version"/{print $4}' "$TRMD_STATUS_FILE" 2>/dev/null)
    [ -z "$UPLINK_NAME" ] && UPLINK_NAME="none"
else
    # Fallback: check iwinfo on the uplink interface directly
    UPLINK_NAME=$(iwinfo "$UPLINK_IFACE" info 2>/dev/null | awk -F'"' '/ESSID/{print $2}')
    [ -z "$UPLINK_NAME" ] && UPLINK_NAME="none"
fi

# Signal strength of uplink
UPLINK_SIGNAL_RAW=$(iwinfo "$UPLINK_IFACE" info 2>/dev/null | awk '/Signal/{print $2}')
[ -n "$UPLINK_SIGNAL_RAW" ] && UPLINK_SIGNAL="$UPLINK_SIGNAL_RAW"

UPLINK_BSSID=$(iwinfo "$UPLINK_IFACE" info 2>/dev/null | awk '/Access Point/{print $3}')
[ -z "$UPLINK_BSSID" ] && UPLINK_BSSID="none"

# ─── 2.4GHz AP: Connected Clients ─────────────────────────────────────────────
# iw dev wlan0 station dump gives us MAC + signal for associated stations
# Cross-reference /tmp/dhcp.leases for IP and hostname

CLIENT_JSON=""
CLIENT_COUNT=0

iw dev "$AP_IFACE" station dump 2>/dev/null | grep "^Station" | awk '{print $2}' | while read -r MAC; do
    MAC_UPPER=$(echo "$MAC" | tr 'a-z' 'A-Z')

    # Look up in DHCP leases: format is "expiry mac ip hostname ..."
    LEASE_LINE=$(grep -i "$MAC" /tmp/dhcp.leases 2>/dev/null | head -1)
    CLIENT_IP=$(echo "$LEASE_LINE" | awk '{print $3}')
    CLIENT_NAME=$(echo "$LEASE_LINE" | awk '{print $4}')
    [ -z "$CLIENT_IP" ]   && CLIENT_IP="unknown"
    [ -z "$CLIENT_NAME" ] && CLIENT_NAME="unknown"
    [ "$CLIENT_NAME" = "*" ] && CLIENT_NAME="unknown"

    # Per-client signal
    CLIENT_SIGNAL=$(iw dev "$AP_IFACE" station get "$MAC" 2>/dev/null \
        | awk '/signal:/{print $2}' | head -1)
    [ -z "$CLIENT_SIGNAL" ] && CLIENT_SIGNAL="null"

    # TX/RX bytes
    TX_BYTES=$(iw dev "$AP_IFACE" station get "$MAC" 2>/dev/null \
        | awk '/tx bytes:/{print $3}')
    RX_BYTES=$(iw dev "$AP_IFACE" station get "$MAC" 2>/dev/null \
        | awk '/rx bytes:/{print $3}')
    [ -z "$TX_BYTES" ] && TX_BYTES="0"
    [ -z "$RX_BYTES" ] && RX_BYTES="0"

    ESC_NAME=$(json_escape "$CLIENT_NAME")
    ESC_IP=$(json_escape "$CLIENT_IP")

    ENTRY="{\"mac\":\"$MAC_UPPER\",\"ip\":\"$ESC_IP\",\"hostname\":\"$ESC_NAME\",\"signal_dbm\":$CLIENT_SIGNAL,\"tx_bytes\":$TX_BYTES,\"rx_bytes\":$RX_BYTES}"

    if [ -z "$CLIENT_JSON" ]; then
        CLIENT_JSON="$ENTRY"
    else
        CLIENT_JSON="$CLIENT_JSON,$ENTRY"
    fi

    CLIENT_COUNT=$((CLIENT_COUNT + 1))

    # Write count and array to temp files so the subshell values survive
    echo "$CLIENT_COUNT" > /tmp/trmd_client_count
    echo "$CLIENT_JSON"  > /tmp/trmd_client_json
done

# Read back from temp files (subshell limitation workaround)
if [ -f /tmp/trmd_client_count ]; then
    CLIENT_COUNT=$(cat /tmp/trmd_client_count)
    CLIENT_JSON=$(cat /tmp/trmd_client_json)
    rm -f /tmp/trmd_client_count /tmp/trmd_client_json
else
    CLIENT_COUNT=0
    CLIENT_JSON=""
fi

# ─── Assemble JSON Payload ─────────────────────────────────────────────────────
PAYLOAD=$(cat <<EOF
{
  "timestamp": "$(timestamp)",
  "router": {
    "hostname": "$(json_escape "$HOSTNAME")",
    "model": "$(json_escape "$ROUTER_MODEL")",
    "firmware": "$(json_escape "$FW_VERSION")",
    "uptime_seconds": $UPTIME_SECS,
    "uptime_human": "$(json_escape "$UPTIME_HUMAN")",
    "load": { "1m": $LOAD1, "5m": $LOAD5, "15m": $LOAD15 },
    "memory": {
      "total_kb": $MEM_TOTAL,
      "used_kb": $MEM_USED,
      "free_kb": $MEM_FREE,
      "used_pct": $MEM_PCT
    },
    "cpu_temp_c": $CPU_TEMP
  },
  "travelmate": {
    "version": "$(json_escape "$TRMD_VERSION")",
    "status": "$(json_escape "$TRMD_STATUS")",
    "uplink_ssid": "$(json_escape "$UPLINK_NAME")",
    "uplink_bssid": "$(json_escape "$UPLINK_BSSID")",
    "uplink_signal_dbm": $UPLINK_SIGNAL,
    "uplink_interface": "$UPLINK_IFACE"
  },
  "ap": {
    "ssid": "$AP_SSID",
    "interface": "$AP_IFACE",
    "client_count": $CLIENT_COUNT,
    "clients": [$CLIENT_JSON]
  }
}
EOF
)

# ─── Publish to MQTT ──────────────────────────────────────────────────────────
# Build auth args if credentials are set
MQTT_AUTH=""
# Uncomment below if you set MQTT_USER/MQTT_PASS above:
# MQTT_AUTH="-u $MQTT_USER -P $MQTT_PASS"

mosquitto_pub \
    -h "$MQTT_BROKER" \
    -p "$MQTT_PORT" \
    -i "$MQTT_CLIENT_ID" \
    -t "$MQTT_TOPIC" \
    -m "$PAYLOAD" \
    $MQTT_AUTH

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    logger -t travelmate_mqtt "Published stats to $MQTT_BROKER:$MQTT_PORT/$MQTT_TOPIC ($CLIENT_COUNT clients)"
else
    logger -t travelmate_mqtt "ERROR: mosquitto_pub failed with exit code $EXIT_CODE"
fi

exit $EXIT_CODE

