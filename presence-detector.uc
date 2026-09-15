#!/usr/bin/ucode

const fs = require("fs");
const ubus = require("ubus");

// Interface passed as an argument from the init.d script
let iface = ARGV[0];
if (!iface) die("Error: No interface specified.\n");

// Read settings
let settings = json(fs.readfile("/etc/config/presence-detector.settings.json"));

// Convert keys (MAC addresses) in params to lowercase
let params = {};
for (let mac in settings.params) params[lc(mac)] = settings.params[mac];

// MAC filter check
if (!settings.filter_is_denylist && !length(settings.filter))
    die("Error: No devices specified in filter.\n");
    
let filter = {};
for (let mac in settings.filter) filter[lc(mac)] = true;

// Debug
if (settings.debug) system(sprintf("logger -t presence-detector 'Filter: %J'", filter));

// Function to restore connection with Home Assistant
function handle_connection_failure() {
    let interval = settings.fallback_sync_interval;

    // Intrval must be greater than 0
    if (!interval || interval <= 0) {
        interval = 10;
        system("logger -t presence-detector 'WARNING: fallback_sync_interval invalid, use 10s as fallback.'");
    }
    
    system(sprintf("logger -t presence-detector '(%s) HA offline, start retry loop (interval: %ds).'", iface, interval));

    while (true) {
        sleep(interval * 1000); 
        let check_cmd = sprintf("wget -q --spider --header='Authorization: Bearer %s' %s/api/", 
                                settings.hass_token, settings.hass_url);     
        if (system(check_cmd) == 0) {
            system(sprintf("logger -t presence-detector '(%s) HA online, restart service...'", iface));
            system(sprintf("(sleep 1; /etc/init.d/presence-detector restart) &"));           
            exit(0); 
        }
    }
}



// Communication with Home Assistant
function ha_seen(mac, is_home) {
    let mac_lc = lc(mac);
    
    // Only process MAC if it passes the filter criteria
    if (!settings.filter_is_denylist && !exists(filter, mac_lc)) return;
    if (settings.filter_is_denylist && exists(filter, mac_lc)) return;

    let location = is_home ? settings.location : settings.away;
    let ha_mac = settings.ap_name ? (settings.ap_name + "_" + mac_lc) : mac_lc;

    let payload = {
        "mac": ha_mac,
        "location_name": location,
        "source_type": settings.source_type,
        "dev_id": ha_mac
    };
    
    // Add any additional parameters
    let device_params = params[mac_lc];
    for (let key in device_params) payload[key] = device_params[key];

    let cmd = sprintf("wget -q -O - --header='Authorization: Bearer %s' --header='Content-Type: application/json' --post-data='%s' %s/api/services/device_tracker/see", 
                 settings.hass_token, sprintf("%J", payload), settings.hass_url);
    
    if (system(cmd) != 0) {
        handle_connection_failure();
    }
    else {
        system(sprintf("logger -t presence-detector '(%s) Event: %s is %s'", iface, mac_lc, location));
    }
}


// Get connected devices on the interface
function ubus_clients(conn, iface, active_clients) {
    let status = conn.call(iface, "get_clients");
    for (let m in status?.clients) {
        active_clients[lc(m)] = status.clients[m];
    }
    return active_clients;
}


// Establish UBUS connection
let conn = ubus.connect();
if (!conn) die("Ubus connection failed.\n");


// Generate events for all devices after service startup
system(sprintf("logger -t presence-detector '(%s) Full sync at startup'", iface));
let clients = ubus_clients(conn, iface, {}); 
for (let mac in clients) ha_seen(mac, true);

// Event if the device is not connected to any interface
if (iface == settings.interfaces[0]) {
    
    let clients = {};
    for (let other_iface in settings.interfaces) {
        clients = ubus_clients(conn, other_iface, clients); 
    }

    // Check filter devices for allow-list or params devices for deny-list
    let macs_to_check = (settings.filter_is_denylist) ? params : filter;  
    for (let mac in macs_to_check) { 
        if (!exists(clients, mac)) ha_seen(mac, false);
    }
}

// The watcher: events on assoc or disassoc
let p = fs.popen(sprintf("ubus subscribe %s", iface), "r");
if (p) {
    system(sprintf("logger -t presence-detector 'Watcher gestart voor %s'", iface));
    while (true) {
        let line = p.read("line");
        if (!line) break;
        let event_data = json(line);
        if (event_data?.assoc) ha_seen(event_data.assoc.address, true);
        else if (event_data?.disassoc) ha_seen(event_data.disassoc.address, false);
    }
    p.close();
}
