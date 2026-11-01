#!/usr/bin/ucode

const fs = require("fs");
const ubus = require("ubus");

// Interface meegegeven als argument vanuit het init.d script
let iface = ARGV[0];
if (!iface) die("Error: No interface specified.\n");

// Instellingen laden
let settings = json(fs.readfile("/etc/config/presence-detector.settings.json"));

// Keys (MAC adressen) in params naar lowercase omzetten
let params = {};
for (let mac in settings.params) params[lc(mac)] = settings.params[mac];

// MAC filter controle
if (!settings.filter_is_denylist && !length(settings.filter))
    die("Error: No devices specified in filter.\n");
    
let filter = {};
for (let mac in settings.filter) filter[lc(mac)] = true;

// Globale status voor geregistreerde clients om dubbele config-berichten te voorkomen
let registered_clients = {};

// Functie om berichten te publiceren (verbeterd voor zowel strings als JSON)
function mqtt_publish(topic, payload, retain, is_json) {
    let auth = "";
    if (settings.mqtt_username != "") {
        auth = sprintf("-u '%s' -P '%s' ", settings.mqtt_username, settings.mqtt_password);
    }
    let retain_flag = retain ? "-r " : "";
    
    // Als het JSON is, zetten we het om naar een string, anders sturen we de rauwe tekst
    let payload_str = is_json ? sprintf("%J", payload) : payload;
    
    // Veilige invoer via stdin pipe om escaping problemen te voorkomen
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

// Communicatie met Home Assistant via MQTT Discovery
function ha_seen(mac, is_home) {
    let mac_lc = lc(mac);
    
    // Controleer filtercriteria
    if (!settings.filter_is_denylist && !exists(filter, mac_lc)) return;
    if (settings.filter_is_denylist && exists(filter, mac_lc)) return;

    let location = is_home ? settings.location : settings.away;
    
    // Genereer de unieke device_slug (vervang : door _)
    let device_name = replace(mac_lc, ":", "_");
    let device_slug = settings.ap_name ? (settings.ap_name + "_" + device_name) : device_name;

    let config_topic = sprintf("homeassistant/device_tracker/%s/config", device_slug);
    let state_topic = sprintf("homeassistant/device_tracker/%s/state", device_slug);

    // 1. Stuur eenmalig de Discovery Config
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

    // 2. Stuur de actuele status als PURE TEKST
    mqtt_publish(state_topic, location, settings.mqtt_retain_state, false);
}

// Haal verbonden apparaten op via UBUS
function ubus_clients(conn, iface, active_clients) {
    let status = conn.call(iface, "get_clients");
    for (let m in status?.clients) {
        active_clients[lc(m)] = true; // Sla de mac op als key met waarde true
    }
    return active_clients;
}

// UBUS verbinding opzetten
let conn = ubus.connect();
if (!conn) die("Ubus connection failed.\n");

// Volledige synchronisatie bij opstarten
system(sprintf("logger -t presence-detector '(%s) Full sync at startup'", iface));
let clients = ubus_clients(conn, iface, {}); 

// Registreer apparaten die NU verbonden zijn op DEZE interface als HOME
for (let mac in clients) {
    ha_seen(mac, true);
}

// Afwezigheidscontrole: Alleen uitvoeren op de hoofdinterface om interferentie te voorkomen
if (iface == settings.interfaces[0]) {
    let all_online_clients = {};
    for (let i = 0; i < length(settings.interfaces); i++) {
        all_online_clients = ubus_clients(conn, settings.interfaces[i], all_online_clients); 
    }

    // Controleer welke apparaten uit de params/filter NIET online zijn, en zet ze op afwezig
    let macs_to_check = (settings.filter_is_denylist) ? params : filter;  
    for (let mac in macs_to_check) { 
        if (!exists(all_online_clients, mac)) {
            ha_seen(mac, false);
        }
    }
}

// De watcher: luisteren naar live assoc en disassoc events
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
