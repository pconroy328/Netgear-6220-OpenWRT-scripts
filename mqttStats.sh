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
AP_IFACE="phy1-ap0"      # 2.4GHz virtual AP interface
UPLINK_IFACE="phy1-sta0" # 5GHz uplink station interface

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
# iw dev phy1-ap0 station dump returns nothing — the R6220 driver does not
# report AP-side associations via nl80211 on this interface.
# Instead: use the DHCP lease file as the authoritative client list, then
# cross-reference the kernel ARP table to confirm reachability and get
# the current IP→MAC binding. Only include clients whose ARP entry is
# in a reachable/stale state (i.e. they have communicated recently).

CLIENTS_TMPFILE="/tmp/trmd_clients_$$.json"
: > "$CLIENTS_TMPFILE"

# ARP table format (/proc/net/arp):
# IP address       HW type  Flags  HW address          Mask  Device
# 192.168.8.189    0x1      0x2    64:5a:04:c8:ce:6b   *     br-lan
# Flags: 0x2 = reachable/stale, 0x0 = incomplete — skip 0x0

# DHCP leases format:
# <expiry> <mac> <ip> <hostname> <clientid>

# Read leases into the loop; for each lease check ARP confirms it's active
while read -r EXPIRY MAC CLIENT_IP CLIENT_NAME CLIENTID; do
    # Skip blank lines
    [ -z "$MAC" ] && continue

    MAC_UPPER=$(echo "$MAC" | tr 'a-z' 'A-Z')
    [ -z "$CLIENT_NAME" ]    && CLIENT_NAME="unknown"
    [ "$CLIENT_NAME" = "*" ] && CLIENT_NAME="unknown"

    # Check ARP table — match on IP AND MAC, restrict to br-lan
    # This prevents the uplink gateway (on phy1-sta0) from leaking into client list
    ARP_FLAGS=$(awk -v ip="$CLIENT_IP" -v mac="$MAC" \
        'tolower($1)==tolower(ip) && tolower($4)==tolower(mac) && $6=="br-lan" {print $3}' \
        /proc/net/arp 2>/dev/null | head -1)

    # No matching ARP entry, or entry is 0x0 (incomplete) — skip
    if [ -z "$ARP_FLAGS" ] || [ "$ARP_FLAGS" = "0x0" ]; then
        continue
    fi

    # Signal: not available via this method — use null
    CLIENT_SIGNAL="null"
    TX_BYTES="0"
    RX_BYTES="0"

    ESC_NAME=$(printf '%s' "$CLIENT_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
    ESC_IP=$(printf '%s'   "$CLIENT_IP"   | sed 's/\\/\\\\/g; s/"/\\"/g')

    printf '{"mac":"%s","ip":"%s","hostname":"%s","signal_dbm":%s,"tx_bytes":%s,"rx_bytes":%s}\n' \
        "$MAC_UPPER" "$ESC_IP" "$ESC_NAME" "$CLIENT_SIGNAL" "$TX_BYTES" "$RX_BYTES" \
        >> "$CLIENTS_TMPFILE"

done < /tmp/dhcp.leases

# Reassemble in main shell — no subshell, CLIENT_COUNT/CLIENT_JSON persist
CLIENT_COUNT=0
CLIENT_JSON=""
if [ -s "$CLIENTS_TMPFILE" ]; then
    while IFS= read -r LINE; do
        CLIENT_COUNT=$((CLIENT_COUNT + 1))
        if [ -z "$CLIENT_JSON" ]; then
            CLIENT_JSON="$LINE"
        else
            CLIENT_JSON="$CLIENT_JSON,$LINE"
        fi
    done < "$CLIENTS_TMPFILE"
fi
rm -f "$CLIENTS_TMPFILE"

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
