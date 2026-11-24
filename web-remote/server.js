const http = require('http');
const https = require('https');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { Tapo } = require('tapo-lan');

const CONFIG_PATH = path.resolve(__dirname, '../config/profiles.json');
const SWITCHER_SCRIPT = path.resolve(__dirname, '../scripts/DeskShift.ps1');
const RUNNER_SCRIPT = path.resolve(__dirname, '../scripts/tapo-runner.js');
const CERT_PATH = path.resolve(__dirname, 'cert.pem');
const KEY_PATH = path.resolve(__dirname, 'key.pem');
const APPLE_ICON_PATH = path.resolve(__dirname, 'apple-touch-icon.png');
const FAVICON_PATH = path.resolve(__dirname, 'favicon.png');

// Pre-load icon buffers in memory for instant iOS loads
const cachedAppleIcon = fs.existsSync(APPLE_ICON_PATH) ? fs.readFileSync(APPLE_ICON_PATH) : null;
const cachedFavicon = fs.existsSync(FAVICON_PATH) ? fs.readFileSync(FAVICON_PATH) : null;

function loadConfig() {
    try {
        let raw = fs.readFileSync(CONFIG_PATH, 'utf8');
        if (raw.charCodeAt(0) === 0xFEFF) {
            raw = raw.slice(1);
        }
        return JSON.parse(raw);
    } catch (e) {
        console.error("Error reading config:", e);
        return null;
    }
}

// Kasa XOR Encryption / Decryption
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
        socket.connect(9999, ip, () => {
            socket.write(packet);
        });

        socket.on('data', (data) => {
            received = true;
            try {
                const body = kasaDecrypt(data.slice(4));
                const res = JSON.parse(body);
                if (res?.system?.set_relay_state?.err_code === 0) {
                    resolve({ success: true, ip, state: turnOn ? "ON" : "OFF" });
                } else {
                    reject(new Error(`Kasa error code: ${res?.system?.set_relay_state?.err_code}`));
                }
            } catch(e) {
                resolve({ success: true, ip, state: turnOn ? "ON" : "OFF" });
            }
            socket.destroy();
        });

        socket.on('error', (err) => {
            socket.destroy();
            reject(err);
        });

        socket.on('timeout', () => {
            socket.destroy();
            reject(new Error(`Timeout connecting to Kasa plug at ${ip}:9999`));
        });

        socket.on('close', () => {
            if (!received) {
                resolve({ success: true, ip, state: turnOn ? "ON" : "OFF" });
            }
        });
    });
}

// Unified Plug Control Helper (delegates to tapo-runner universal engine)
async function setPlugState(plugKey, plugDef, turnOn, credentials) {
    if (!plugDef) {
        return { success: false, error: `Plug '${plugKey}' definition missing` };
    }

    try {
        const { controlPlug } = require('../scripts/tapo-runner.js');
        const cfg = loadConfig();
        const tapoClient = (credentials && credentials.Email && credentials.Password)
            ? new Tapo({ user: credentials.Email, pass: credentials.Password })
            : null;

        await controlPlug(plugKey, plugDef, turnOn, tapoClient, cfg ? cfg.HomeAssistant : null);
        return { success: true, key: plugKey, state: turnOn ? "ON" : "OFF" };
    } catch(err) {
        console.error(`Plug control error for ${plugKey}:`, err.message);
        return { success: false, error: err.message };
    }
}

// Switch display profile safely without shell interpolation
function runDisplaySwitch(profileArg) {
    return new Promise((resolve) => {
        const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SWITCHER_SCRIPT, profileArg];
        console.log(`Executing display switch safely: powershell.exe`, args);

        const child = spawn('powershell.exe', args, { windowsHide: true });
        let stdout = '';
        let stderr = '';

        child.stdout.on('data', (d) => { stdout += d.toString(); });
        child.stderr.on('data', (d) => { stderr += d.toString(); });

        child.on('close', (code) => {
            if (code === 0) {
                console.log("Switch success:", stdout);
                resolve({ success: true, output: stdout });
            } else {
                console.error("Switch error:", stderr || stdout);
                resolve({ success: false, error: stderr || stdout });
            }
        });

        child.on('error', (err) => {
            console.error("Process error:", err.message);
            resolve({ success: false, error: err.message });
        });
    });
}

// Sync smart plugs for profile
async function syncSmartPlugsForProfile(profileName, config) {
    if (!config.SmartPlugs) return;
    
    const profile = (config.Profiles || []).find(p => 
        (p.Name && p.Name.toLowerCase() === profileName.toLowerCase()) || 
        (p.Label && p.Label.toLowerCase() === profileName.toLowerCase())
    );
    if (!profile || !profile.Plugs) return;

    for (const [plugKey, targetState] of Object.entries(profile.Plugs)) {
        const plugDef = config.SmartPlugs[plugKey];
        if (plugDef && plugDef.Ip) {
            console.log(`Syncing plug ${plugDef.Name || plugKey} (${plugDef.Ip}) -> ${targetState ? 'ON' : 'OFF'}`);
            await setPlugState(plugKey, plugDef, !!targetState, config.TapoCredentials);
        }
    }
}

// HTML Dashboard Template
function renderDashboard(config) {
    const plugs = config.SmartPlugs || {};
    
    // Determine visible profiles on Web Remote
    const allProfiles = config.Profiles || [];
    const webProfiles = allProfiles.filter(p => !p.Separator && !p.Hidden && p.WebVisible !== false);

    // Profile icon & style helper
    function getProfileStyle(p) {
        if (p.WebColor) return { color: p.WebColor, icon: p.WebIcon || '🖥️' };
        const name = (p.Name || '').toLowerCase();
        const label = (p.Label || '').toLowerCase();
        if (p.WebIcon) return { color: '#38bdf8', icon: p.WebIcon };
        if (name.includes('tv') || label.includes('tv')) return { color: '#f59e0b', icon: '📺' };
        if (name.includes('race') || name.includes('rig') || label.includes('race')) return { color: '#ef4444', icon: '🏎️' };
        if (name.includes('vr') || label.includes('vr')) return { color: '#ec4899', icon: '🥽' };
        if (p.IsToggle || name.includes('single') || label.includes('toggle')) return { color: '#8b5cf6', icon: '🔄' };
        return { color: '#3b82f6', icon: '🖥️' };
    }

    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="DeskShift Remote">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    <link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
    <link rel="shortcut icon" href="/favicon.png">
    <title>DeskShift Web Remote</title>
    <style>
        :root {
            --bg: #0f172a;
            --card-bg: #1e293b;
            --accent: #38bdf8;
            --accent-hover: #0284c7;
            --text: #f8fafc;
            --text-dim: #94a3b8;
            --success: #10b981;
        }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
            margin: 0;
            padding: env(safe-area-inset-top, 20px) 16px env(safe-area-inset-bottom, 20px);
            background: var(--bg);
            color: var(--text);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        .header {
            width: 100%;
            max-width: 500px;
            text-align: center;
            padding: 16px 0 20px;
        }
        h1 { margin: 0; font-size: 1.6rem; font-weight: 700; letter-spacing: -0.5px; }
        .sub { font-size: 0.85rem; color: var(--text-dim); margin-top: 4px; }
        .grid {
            width: 100%;
            max-width: 500px;
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 14px;
            margin-bottom: 24px;
        }
        .btn {
            background: var(--card-bg);
            border: 1px solid rgba(255,255,255,0.08);
            border-radius: 16px;
            padding: 20px 12px;
            color: var(--text);
            font-size: 1.0rem;
            font-weight: 600;
            cursor: pointer;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            gap: 10px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.25);
            transition: transform 0.1s ease, filter 0.15s ease;
            text-align: center;
            line-height: 1.25;
        }
        .btn:active {
            transform: scale(0.96);
            filter: brightness(1.2);
        }
        .btn .icon {
            font-size: 2.2rem;
        }
        
        .section-title {
            width: 100%;
            max-width: 500px;
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: var(--text-dim);
            margin: 0 0 12px 6px;
        }
        .plugs-list {
            width: 100%;
            max-width: 500px;
            display: flex;
            flex-direction: column;
            gap: 10px;
            margin-bottom: 24px;
        }
        .plug-item {
            background: var(--card-bg);
            border: 1px solid rgba(255,255,255,0.08);
            border-radius: 14px;
            padding: 14px 18px;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .plug-info { display: flex; flex-direction: column; gap: 3px; }
        .plug-name { font-weight: 600; font-size: 1rem; }
        .plug-meta { font-size: 0.8rem; color: var(--text-dim); display: flex; gap: 6px; align-items: center; }
        .badge {
            background: #334155;
            color: #94a3b8;
            padding: 1px 6px;
            border-radius: 4px;
            font-size: 0.72rem;
            font-weight: 600;
            text-transform: uppercase;
        }
        .badge-kasa { background: #0f766e; color: #5eead4; }
        .badge-tapo { background: #1e3a8a; color: #93c5fd; }
        .plug-actions { display: flex; gap: 8px; }
        .plug-btn {
            border: none;
            border-radius: 8px;
            padding: 8px 14px;
            font-weight: 600;
            font-size: 0.85rem;
            cursor: pointer;
        }
        .plug-btn-on { background: #065f46; color: #a7f3d0; }
        .plug-btn-off { background: #334155; color: #cbd5e1; }
        .plug-btn:active { transform: scale(0.94); }

        #toast {
            position: fixed;
            bottom: calc(env(safe-area-inset-bottom, 20px) + 20px);
            left: 50%;
            transform: translateX(-50%) translateY(100px);
            background: rgba(15, 23, 42, 0.95);
            border: 1px solid var(--accent);
            color: #fff;
            padding: 12px 24px;
            border-radius: 30px;
            font-size: 0.95rem;
            font-weight: 500;
            opacity: 0;
            transition: all 0.25s ease;
            pointer-events: none;
            box-shadow: 0 10px 25px rgba(0,0,0,0.5);
            z-index: 100;
            white-space: nowrap;
        }
        #toast.show {
            transform: translateX(-50%) translateY(0);
            opacity: 1;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>DeskShift Remote</h1>
        <div class="sub">RTX 5080 • Display & Hardware Remote</div>
    </div>

    <div class="grid">
        ${webProfiles.map(p => {
            const st = getProfileStyle(p);
            const title = p.Label || p.Name;
            return `
            <button class="btn" style="border-left: 4px solid ${st.color};" onclick="switchProfile('${p.Name.replace(/'/g, "\\'")}')">
                <span class="icon">${st.icon}</span>
                <span>${title}</span>
            </button>`;
        }).join('')}
    </div>

    <div class="section-title">Smart Power Controls</div>
    <div class="plugs-list">
        ${Object.entries(plugs).map(([key, plug]) => {
            const isKasa = (plug.Type || '').toLowerCase().includes('kasa');
            const badgeClass = isKasa ? 'badge-kasa' : 'badge-tapo';
            const typeLabel = isKasa ? 'Kasa' : 'Tapo';
            return `
            <div class="plug-item">
                <div class="plug-info">
                    <span class="plug-name">${plug.Name || key}</span>
                    <span class="plug-meta">
                        <span class="badge ${badgeClass}">${typeLabel}</span>
                        <span>${plug.Ip}</span>
                    </span>
                </div>
                <div class="plug-actions">
                    <button class="plug-btn plug-btn-on" onclick="togglePlug('${key}', 'on')">ON</button>
                    <button class="plug-btn plug-btn-off" onclick="togglePlug('${key}', 'off')">OFF</button>
                </div>
            </div>`;
        }).join('')}
    </div>

    <div id="toast"></div>

    <script>
        function showToast(msg, isSuccess = true) {
            const t = document.getElementById('toast');
            t.innerText = msg;
            t.style.borderColor = isSuccess ? '#10b981' : '#ef4444';
            t.classList.add('show');
            setTimeout(() => t.classList.remove('show'), 2500);
        }

        async function switchProfile(name) {
            showToast('Switching to ' + name + '...');
            try {
                const res = await fetch('/api/profile/' + encodeURIComponent(name), { method: 'POST' });
                const data = await res.json();
                if (data.success) {
                    showToast('Switched to ' + name + ' successfully!');
                } else {
                    showToast('Switch failed: ' + (data.error || 'Unknown'), false);
                }
            } catch (err) {
                showToast('Network error triggering switch', false);
            }
        }

        async function togglePlug(key, state) {
            showToast('Turning ' + key + ' ' + state.toUpperCase() + '...');
            try {
                const res = await fetch('/api/plug/' + encodeURIComponent(key) + '/' + state, { method: 'POST' });
                const data = await res.json();
                if (data.success) {
                    showToast('Plug turned ' + state.toUpperCase());
                } else {
                    showToast('Error: ' + (data.error || 'Failed'), false);
                }
            } catch(e) {
                showToast('Network error toggling plug', false);
            }
        }
    </script>
</body>
</html>`;
}

// Request Handler
async function handleRequest(req, res, proto) {
    // Basic CORS & Security Headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.setHeader('X-Content-Type-Options', 'nosniff');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    const url = new URL(req.url, `${proto}://${req.headers.host}`);
    const pathname = url.pathname;

    console.log(`[${proto.toUpperCase()}] ${req.method} ${pathname}`);

    // Serve Web App Dashboard
    if (pathname === '/' || pathname === '/index.html') {
        const cfg = loadConfig() || {};
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(renderDashboard(cfg));
        return;
    }

    // Serve Favicon & Apple Touch Icon (cached in memory)
    if (pathname === '/apple-touch-icon.png' && cachedAppleIcon) {
        res.writeHead(200, {
            'Content-Type': 'image/png',
            'Cache-Control': 'public, max-age=604800, immutable'
        });
        res.end(cachedAppleIcon);
        return;
    }
    if ((pathname === '/favicon.png' || pathname === '/favicon.ico') && cachedFavicon) {
        res.writeHead(200, {
            'Content-Type': 'image/png',
            'Cache-Control': 'public, max-age=604800, immutable'
        });
        res.end(cachedFavicon);
        return;
    }

    // API: Switch Profile (supports friendly clean slugs, exact names, and legacy aliases)
    if (pathname.startsWith('/api/profile/')) {
        let requestedSlug = decodeURIComponent(pathname.replace('/api/profile/', '')).trim().toLowerCase();
        
        function toCleanSlug(str) {
            return (str || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
        }

        const cfg = loadConfig();
        let matchedProfile = null;

        // 1. Check exact name or label match
        for (const p of (cfg && cfg.Profiles || [])) {
            if (p.Separator) continue;
            const pName = (p.Name || '').trim();
            const pLabel = (p.Label || '').trim();
            const slug1 = toCleanSlug(pName);
            const slug2 = toCleanSlug(pLabel);

            if (pName.toLowerCase() === requestedSlug ||
                pLabel.toLowerCase() === requestedSlug ||
                slug1 === requestedSlug ||
                slug2 === requestedSlug) {
                matchedProfile = p;
                break;
            }
        }

        // 2. Convenience aliases if no exact slug matched
        if (!matchedProfile) {
            if (requestedSlug === 'tv' || requestedSlug === '4ktv') {
                matchedProfile = (cfg.Profiles || []).find(p => (p.Name || '').toLowerCase().includes('tv'));
            } else if (requestedSlug === 'desk' || requestedSlug === 'dual' || requestedSlug === 'dual-desktop') {
                matchedProfile = (cfg.Profiles || []).find(p => (p.Name || '').toLowerCase().includes('dual'));
            } else if (requestedSlug === 'single' || requestedSlug === 'toggle') {
                matchedProfile = (cfg.Profiles || []).find(p => p.IsToggle || (p.Name || '').toLowerCase().includes('single'));
            } else if (requestedSlug === 'rig' || requestedSlug === 'triple' || requestedSlug === 'sim-rig') {
                matchedProfile = (cfg.Profiles || []).find(p => (p.Name || '').toLowerCase().includes('rig') || (p.Name || '').toLowerCase().includes('triple'));
            } else if (requestedSlug === 'vr') {
                matchedProfile = (cfg.Profiles || []).find(p => (p.Name || '').toLowerCase().includes('vr'));
            }
        }

        if (!matchedProfile) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: false, error: 'Profile not found matching slug: ' + requestedSlug }));
            return;
        }

        const profileName = matchedProfile.Name;
        const switchResult = await runDisplaySwitch(profileName);
        
        if (switchResult.success && cfg) {
            syncSmartPlugsForProfile(profileName, cfg).catch(e => console.error("Smart plug sync error:", e));
        }

        res.writeHead(switchResult.success ? 200 : 500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(switchResult));
        return;
    }

    // API: Direct Smart Plug Toggle (e.g. /api/plug/:key/on)
    if (pathname.startsWith('/api/plug/')) {
        const parts = pathname.replace('/api/plug/', '').split('/');
        const plugKey = decodeURIComponent(parts[0]);
        const state = (parts[1] || 'on').toLowerCase() === 'on';

        const cfg = loadConfig();
        const plug = cfg && cfg.SmartPlugs && cfg.SmartPlugs[plugKey];

        if (!plug || !plug.Ip) {
            res.writeHead(404, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: false, error: `Plug '${plugKey}' not found or has no IP` }));
            return;
        }

        const result = await setPlugState(plugKey, plug, state, cfg.TapoCredentials);
        res.writeHead(result.success ? 200 : 500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
        return;
    }

    // API: Config check & status
    if (pathname === '/api/status') {
        const cfg = loadConfig();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status: "online",
            host: "JP-PC",
            ssl: !!req.socket.encrypted,
            profiles: (cfg && cfg.Profiles || []).map(p => p.Name),
            plugs: (cfg && cfg.SmartPlugs) ? Object.keys(cfg.SmartPlugs) : []
        }));
        return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Endpoint not found' }));
}

// Start HTTP Server
const initialCfg = loadConfig() || {};
const HTTP_PORT = (initialCfg.WebRemote && initialCfg.WebRemote.Port) ? initialCfg.WebRemote.Port : 8088;
const httpServer = http.createServer((req, res) => handleRequest(req, res, 'http'));
httpServer.listen(HTTP_PORT, '0.0.0.0', () => {
    console.log(`[HTTP] Web Remote listening on http://0.0.0.0:${HTTP_PORT}`);
});

// Start HTTPS Server
const HTTPS_PORT = 443;
const HTTPS_ALT_PORT = 8443;

if (fs.existsSync(CERT_PATH) && fs.existsSync(KEY_PATH)) {
    try {
        const httpsOptions = {
            cert: fs.readFileSync(CERT_PATH),
            key: fs.readFileSync(KEY_PATH)
        };

        const httpsServer = https.createServer(httpsOptions, (req, res) => handleRequest(req, res, 'https'));
        httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => {
            console.log(`[HTTPS] Secure Web Remote listening on https://0.0.0.0:${HTTPS_PORT}`);
        });

        httpsServer.on('error', (err) => {
            if (err.code === 'EACCES' || err.code === 'EADDRINUSE') {
                console.warn(`[HTTPS] Port 443 occupied or restricted (${err.message}). Starting on alternate port ${HTTPS_ALT_PORT}...`);
                const altHttpsServer = https.createServer(httpsOptions, (req, res) => handleRequest(req, res, 'https'));
                altHttpsServer.listen(HTTPS_ALT_PORT, '0.0.0.0', () => {
                    console.log(`[HTTPS] Secure Web Remote listening on https://0.0.0.0:${HTTPS_ALT_PORT}`);
                });
            } else {
                console.error("[HTTPS] Server startup error:", err);
            }
        });
    } catch (e) {
        console.error("[HTTPS] Failed to initialize SSL certificates:", e.message);
    }
} else {
    console.warn(`[HTTPS] SSL certificate or key not found in ${CERT_PATH}. HTTPS disabled.`);
}
