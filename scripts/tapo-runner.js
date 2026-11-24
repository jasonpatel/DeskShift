const { Tapo } = require('../web-remote/node_modules/tapo-lan');
const fs = require('fs');
const path = require('path');
const net = require('net');
const http = require('http');
const https = require('https');
const { exec } = require('child_process');

const CONFIG_PATH = path.resolve(__dirname, '../config/profiles.json');

function loadConfig() {
    try {
        let raw = fs.readFileSync(CONFIG_PATH, 'utf8');
        if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
        return JSON.parse(raw);
    } catch(e) {
        return null;
    }
}

// ==============================================================================
// 1. Kasa Protocol (Port 9999 XOR)
// ==============================================================================
function kasaEncrypt(buffer) {
    let key = 0xAB;
    const result = Buffer.alloc(buffer.length);
    for (let i = 0; i < buffer.length; i++) {
        result[i] = buffer[i] ^ key;
        key = result[i];
    }
    return result;
}

function kasaDecrypt(buffer) {
    let key = 0xAB;
    const result = Buffer.alloc(buffer.length);
    for (let i = 0; i < buffer.length; i++) {
        result[i] = buffer[i] ^ key;
        key = buffer[i];
    }
    return result.toString('utf8');
}

function sendKasaCommand(ip, turnOn, timeoutMs = 3000) {
    return new Promise((resolve, reject) => {
        const state = turnOn ? 1 : 0;
        const jsonCmd = JSON.stringify({ system: { set_relay_state: { state: state } } });
        const payload = kasaEncrypt(Buffer.from(jsonCmd));
        const header = Buffer.alloc(4);
        header.writeUInt32BE(payload.length, 0);
        const packet = Buffer.concat([header, payload]);

        const socket = new net.Socket();
        let received = false;
        socket.setTimeout(timeoutMs);

        socket.connect(9999, ip, () => socket.write(packet));

        socket.on('data', (data) => {
            received = true;
            try {
                const body = kasaDecrypt(data.slice(4));
                const res = JSON.parse(body);
                const errCode = res?.system?.set_relay_state?.err_code;
                if (errCode === 0) resolve(true);
                else reject(new Error(`Kasa error code: ${errCode}`));
            } catch(e) {
                resolve(true);
            }
            socket.destroy();
        });

        socket.on('error', (err) => { socket.destroy(); reject(err); });
        socket.on('timeout', () => { socket.destroy(); reject(new Error(`Timeout connecting to Kasa plug at ${ip}:9999`)); });
        socket.on('close', () => { if (!received) resolve(true); });
    });
}

// ==============================================================================
// 2. HTTP / REST / Webhook Protocol (Shelly, Tasmota, Generic)
// ==============================================================================
function sendHttpRequest(targetUrl, timeoutMs = 4000) {
    return new Promise((resolve, reject) => {
        try {
            const u = new URL(targetUrl);
            const client = u.protocol === 'https:' ? https : http;
            const req = client.request(u, { method: 'GET', timeout: timeoutMs }, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                    if (res.statusCode >= 200 && res.statusCode < 400) {
                        resolve(true);
                    } else {
                        reject(new Error(`HTTP status ${res.statusCode}: ${data.substring(0, 80)}`));
                    }
                });
            });
            req.on('error', reject);
            req.on('timeout', () => { req.destroy(); reject(new Error(`Timeout calling ${targetUrl}`)); });
            req.end();
        } catch(err) {
            reject(err);
        }
    });
}

// ==============================================================================
// 3. Home Assistant REST API
// ==============================================================================
function callHomeAssistant(haUrl, token, entityId, turnOn, timeoutMs = 4000) {
    return new Promise((resolve, reject) => {
        try {
            const domain = entityId.split('.')[0] || 'switch';
            const service = turnOn ? 'turn_on' : 'turn_off';
            const base = (haUrl || 'http://homeassistant.local:8123').replace(/\/+$/, '');
            const targetUrl = new URL(`${base}/api/services/${domain}/${service}`);
            
            const payload = JSON.stringify({ entity_id: entityId });
            const client = targetUrl.protocol === 'https:' ? https : http;
            
            const req = client.request(targetUrl, {
                method: 'POST',
                timeout: timeoutMs,
                headers: {
                    'Authorization': `Bearer ${token}`,
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(payload)
                }
            }, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                    if (res.statusCode >= 200 && res.statusCode < 300) {
                        resolve(true);
                    } else {
                        reject(new Error(`Home Assistant error (${res.statusCode}): ${data.substring(0, 100)}`));
                    }
                });
            });
            
            req.on('error', reject);
            req.on('timeout', () => { req.destroy(); reject(new Error(`Timeout calling Home Assistant at ${base}`)); });
            req.write(payload);
            req.end();
        } catch(err) {
            reject(err);
        }
    });
}

// ==============================================================================
// 4. Custom Local Shell Command
// ==============================================================================
function runCustomCommand(cmd, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
        exec(cmd, { timeout: timeoutMs }, (error, stdout, stderr) => {
            if (error) reject(new Error(stderr || error.message));
            else resolve(true);
        });
    });
}

// ==============================================================================
// Universal Plug Dispatcher
// ==============================================================================
async function controlPlug(plugKey, plugDef, turnOn, tapoClient, haConfig) {
    if (!plugDef) {
        throw new Error(`Plug '${plugKey}' definition missing in configuration`);
    }

    const type = (plugDef.Type || 'tapo').toLowerCase();
    const friendlyName = plugDef.Name || plugKey;
    const actionStr = turnOn ? 'ON' : 'OFF';

    console.log(`[PLUG] ${friendlyName} (${plugDef.Ip || plugDef.EntityId || plugDef.Url || 'custom'}) [${type.toUpperCase()}] -> ${actionStr}`);

    if (type.includes('kasa') || type.includes('hs')) {
        if (!plugDef.Ip) throw new Error(`Plug '${plugKey}' missing IP address`);
        return await sendKasaCommand(plugDef.Ip, turnOn);
    } 
    else if (type.includes('tapo') || type.includes('p100') || type.includes('p110')) {
        if (!plugDef.Ip) throw new Error(`Plug '${plugKey}' missing IP address`);
        if (!tapoClient) throw new Error("Tapo client not initialized - missing TapoCredentials in configuration");
        const dev = await tapoClient.connect(plugDef.Ip);
        if (turnOn) await dev.turnOn(); else await dev.turnOff();
        return true;
    }
    else if (type.includes('homeassistant') || type.includes('hass')) {
        const entity = plugDef.EntityId || plugDef.Ip;
        const haUrl = plugDef.HaUrl || (haConfig && haConfig.Url) || 'http://homeassistant.local:8123';
        const token = plugDef.Token || (haConfig && haConfig.Token);
        if (!token) throw new Error(`Missing Home Assistant Long-Lived Access Token for '${plugKey}'`);
        if (!entity) throw new Error(`Missing Home Assistant Entity ID (e.g. switch.rig_displays) for '${plugKey}'`);
        return await callHomeAssistant(haUrl, token, entity, turnOn);
    }
    else if (type.includes('webhook') || type.includes('http') || type.includes('shelly') || type.includes('tasmota')) {
        let targetUrl = '';
        if (turnOn && plugDef.OnUrl) targetUrl = plugDef.OnUrl;
        else if (!turnOn && plugDef.OffUrl) targetUrl = plugDef.OffUrl;
        else if (plugDef.Url) targetUrl = plugDef.Url.replace('{state}', turnOn ? 'on' : 'off');
        else if (plugDef.Ip) {
            // Shelly default fallback
            targetUrl = `http://${plugDef.Ip}/relay/0?turn=${turnOn ? 'on' : 'off'}`;
        }
        if (!targetUrl) throw new Error(`No valid URL configured for '${plugKey}' for state ${actionStr}`);
        return await sendHttpRequest(targetUrl);
    }
    else if (type.includes('cmd') || type.includes('script') || type.includes('custom')) {
        const cmd = turnOn ? (plugDef.OnCommand || plugDef.Command) : (plugDef.OffCommand || plugDef.Command);
        if (!cmd) throw new Error(`No command configured for '${plugKey}' state ${actionStr}`);
        return await runCustomCommand(cmd.replace('{state}', turnOn ? 'on' : 'off'));
    }
    else {
        throw new Error(`Unsupported smart plug protocol type: '${plugDef.Type}'`);
    }
}

async function main() {
    const args = process.argv.slice(2);
    const command = args[0] || 'sync';
    const target = args[1];
    const action = args[2];

    const config = loadConfig();
    if (!config || !config.SmartPlugs) {
        console.error("Missing config or SmartPlugs in profiles.json");
        process.exit(1);
    }

    let tapoClient = null;
    if (config.TapoCredentials && config.TapoCredentials.Email && config.TapoCredentials.Password) {
        tapoClient = new Tapo({ user: config.TapoCredentials.Email, pass: config.TapoCredentials.Password });
    }

    const haConfig = config.HomeAssistant || null;

    if (command === 'set') {
        const plugKey = target;
        const turnOn = (action || 'on').toLowerCase() === 'on';
        const plugDef = config.SmartPlugs[plugKey];

        if (!plugDef) {
            console.error(`Plug '${plugKey}' does not exist in configuration.`);
            process.exit(1);
        }

        try {
            await controlPlug(plugKey, plugDef, turnOn, tapoClient, haConfig);
            console.log(`Success: Set '${plugKey}' -> ${turnOn ? 'ON' : 'OFF'}`);
            process.exit(0);
        } catch(err) {
            console.error(`Error controlling plug '${plugKey}':`, err.message);
            process.exit(1);
        }
    } else if (command === 'sync') {
        const profileName = target;
        const profile = (config.Profiles || []).find(p => 
            (p.Name && p.Name.toLowerCase() === profileName.toLowerCase()) || 
            (p.Label && p.Label.toLowerCase() === profileName.toLowerCase())
        );

        if (!profile || !profile.Plugs) {
            console.log(`No plug profile mappings for: ${profileName}`);
            process.exit(0);
        }

        for (const [plugKey, state] of Object.entries(profile.Plugs)) {
            const plugDef = config.SmartPlugs[plugKey];
            if (plugDef) {
                const turnOn = !!state;
                try {
                    await controlPlug(plugKey, plugDef, turnOn, tapoClient, haConfig);
                } catch(err) {
                    console.error(`Failed to toggle ${plugKey}:`, err.message);
                }
            }
        }
    }
}

if (require.main === module) {
    main();
}

module.exports = { controlPlug, sendKasaCommand, sendHttpRequest, callHomeAssistant, runCustomCommand };
