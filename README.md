# Netgear-6220-OpenWRT-scripts





// Extract uplink_ssid from the payload
let uplinkSsid = msg.payload.travelmate.uplink_ssid;

// Option 1: Pass only the SSID forward as the new payload
msg.payload = uplinkSsid;

// Option 2: Alternatively, keep the full message and store the SSID in a new property:
// msg.uplink_ssid = uplinkSsid;

return msg;
