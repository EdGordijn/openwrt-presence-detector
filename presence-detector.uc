#!/usr/bin/ucode

const fs = require("fs");
const ubus = require("ubus");

// Interface passed as an argument from the init.d script
let iface = ARGV[0];
if (!iface) die("Error: No interface specified.\n");

// Load settings
let settings = json(fs.readfile("/etc/config/presence-detector.settings.json"));

// Convert keys (MAC addresses) in params to lowercase
let params = {};
for (let mac in settings.params) params[lc(mac)] = settings.params[mac];

// MAC filter check
if (!settings.filter_is_denylist && !length(settings.filter))
    die("Error: No devices specified in filter.\n");
    
let filter = {};
for (let mac in settings.filter) filter[lc(mac)] = true;

// Global status for registered clients to prevent duplicate config messages
let registered_clients = {};

// Function to publish messages (improved for both strings and JSON)
function mqtt_publish(topic, payload, retain, is_json) {
    let auth = "";
    if (settings.mqtt_username != "") {
        auth = sprintf("-u '%s' -P '%s' ", settings.mqtt_username, settings.mqtt_password);
    }
    let retain_flag = retain ? "-r " : "";
    
    // If it is JSON, we convert it to a string, otherwise we send the raw text
    let payload_str = is_json ? sprintf("%J", payload) : payload;
    
    // Secure input via stdin pipe to prevent escaping issues
    let cmd = sprintf("echo -n '%s' | mosquitto_pub -h '%s' -p %d %s%s-t '%s' -l", 
                      payload_str, settings.mqtt_host, settings.mqtt_port, auth, retain_flag, topic);
    
    if (system(cmd) != 0) {
        system(sprintf("logger -t presence-detector '(%s) Error: MQTT publish failed to %s'", iface, topic));
        return false;
    }
    else {
        system(sprintf("logger -t presence-detector '(%s) topic: %s, payload: %s'", iface, topic, payload_str));
    }

    return true;
}

// Communication with Home Assistant via MQTT Discovery
function ha_seen(mac, is_home) {
    let mac_lc = lc(mac);
    
    // Check filter criteria
    if (!settings.filter_is_denylist && !exists(filter, mac_lc)) return;
    if (settings.filter_is_denylist && exists(filter, mac_lc)) return;

    let location = is_home ? settings.location : settings.away;
    
    // Generate the unique device_slug (replace : with _)
    let device_name = replace(mac_lc, ":", "_");
    let device_slug = settings.ap_name ? (settings.ap_name + "_" + device_name) : device_name;

    let config_topic = sprintf("homeassistant/device_tracker/%s/config", device_slug);
    let state_topic = sprintf("homeassistant/device_tracker/%s/state", device_slug);

    // 1. Send the Discovery Config once
    if (!exists(registered_clients, device_slug)) {
        let final_name = device_name;
        
        if (exists(params, mac_lc) && params[mac_lc].dev_id) {
            final_name = params[mac_lc].dev_id;
        }

        let config_payload = {
            "state_topic": state_topic,
            "name": final_name,
            "platform": "device_tracker",
            "payload_home": settings.location,
            "payload_not_home": settings.away,
            "source_type": settings.source_type,
            "device": { 
                "connections": [["mac", mac_lc]],
                "identifiers": [ device_slug ],
                "name": final_name + "_" + settings.ap_name
            },
            "unique_id": device_slug
        };

        if (mqtt_publish(config_topic, config_payload, false, true)) {
            registered_clients[device_slug] = true;
        }
    }

    // 2. Send the current state as PURE TEXT
    mqtt_publish(state_topic, location, settings.mqtt_retain_state, false);
}

// Fetch connected devices via UBUS
function ubus_clients(conn, iface, active_clients) {
    let status = conn.call(iface, "get_clients");
    for (let m in status?.clients) {
        active_clients[lc(m)] = true; // Save the mac as key with value true
    }
    return active_clients;
}

// Establish UBUS connection
let conn = ubus.connect();
if (!conn) die("Ubus connection failed.\n");

// Full synchronization at startup
system(sprintf("logger -t presence-detector '(%s) Full sync at startup'", iface));
let clients = ubus_clients(conn, iface, {}); 

// Register devices that are NOW connected to THIS interface as HOME
for (let mac in clients) {
    ha_seen(mac, true);
}

// Absence check: Only execute on the main interface to prevent interference
if (iface == settings.interfaces[0]) {
    let all_online_clients = {};
    for (let i = 0; i < length(settings.interfaces); i++) {
        all_online_clients = ubus_clients(conn, settings.interfaces[i], all_online_clients); 
    }

    // Check which devices from the params/filter are NOT online, and set them to away
    let macs_to_check = (settings.filter_is_denylist) ? params : filter;  
    for (let mac in macs_to_check) { 
        if (!exists(all_online_clients, mac)) {
            ha_seen(mac, false);
        }
    }
}

// The watcher: listen to live assoc and disassoc events
let p = fs.popen(sprintf("ubus subscribe %s", iface), "r");
if (p) {
    system(sprintf("logger -t presence-detector 'Watcher started for %s'", iface));
    while (true) {
        let line = p.read("line");
        if (!line) break;
        let event_data = json(line);
        if (event_data?.assoc) ha_seen(event_data.assoc.address, true);
        else if (event_data?.disassoc) ha_seen(event_data.disassoc.address, false);
    }
    p.close();
}
