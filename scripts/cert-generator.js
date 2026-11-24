const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const webRemoteDir = path.resolve(__dirname, '../web-remote');

function getLocalIpAddresses() {
    const list = [];
    const ifaces = os.networkInterfaces();
    for (const [name, addrs] of Object.entries(ifaces)) {
        for (const a of addrs) {
            if (a.family === 'IPv4' && !a.internal && !a.address.startsWith('169.254')) {
                list.push(a.address);
            }
        }
    }
    return list;
}

function generateCert(domainOrIp, outDir) {
    const targetDir = outDir || webRemoteDir;
    const certPath = path.join(targetDir, 'cert.pem');
    const keyPath = path.join(targetDir, 'key.pem');

    const ips = getLocalIpAddresses();
    const dnsNames = ['localhost', os.hostname()];
    if (domainOrIp && !dnsNames.includes(domainOrIp) && !ips.includes(domainOrIp)) {
        if (/^\d+\.\d+\.\d+\.\d+$/.test(domainOrIp)) {
            ips.unshift(domainOrIp);
        } else {
            dnsNames.unshift(domainOrIp);
        }
    }

    const allNames = Array.from(new Set([...dnsNames, ...ips]));
    const dnsArgs = allNames.map(n => "'" + n + "'").join(', ');

    const psScript = [
        "$dnsList = @(" + dnsArgs + ")",
        "$cert = New-SelfSignedCertificate -DnsName $dnsList -CertStoreLocation 'Cert:\\CurrentUser\\My' -NotAfter (Get-Date).AddYears(5) -FriendlyName 'DeskShift Web Remote'",
        "$pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'DeskShift')",
        "$certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxBytes, 'DeskShift', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)",
        "$certB64 = [System.Convert]::ToBase64String($certObj.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)",
        "$certPem = \"-----BEGIN CERTIFICATE-----\" + [Environment]::NewLine + $certB64 + [Environment]::NewLine + \"-----END CERTIFICATE-----\" + [Environment]::NewLine",
        "$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certObj)",
        "$keyBytes = $rsa.ExportPkcs8PrivateKey()",
        "$keyB64 = [System.Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks)",
        "$keyPem = \"-----BEGIN PRIVATE KEY-----\" + [Environment]::NewLine + $keyB64 + [Environment]::NewLine + \"-----END PRIVATE KEY-----\" + [Environment]::NewLine",
        "[System.IO.File]::WriteAllText('" + certPath.replace(/\\/g, '\\\\') + "', $certPem, [System.Text.Encoding]::UTF8)",
        "[System.IO.File]::WriteAllText('" + keyPath.replace(/\\/g, '\\\\') + "', $keyPem, [System.Text.Encoding]::UTF8)",
        "Remove-Item (Join-Path 'Cert:\\CurrentUser\\My' $cert.Thumbprint) -Force -ErrorAction SilentlyContinue",
        'Write-Output "SUCCESS"'
    ].join('; ');

    const res = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psScript], { encoding: 'utf8' });
    if (res.status === 0 && res.stdout.includes('SUCCESS') && fs.existsSync(certPath) && fs.existsSync(keyPath)) {
        return { success: true, certPath, keyPath, san: allNames };
    } else {
        return { success: false, error: res.stderr || res.stdout || 'Unknown error' };
    }
}

function importCert(pfxOrCertPath, keyPathOrPass) {
    const certPath = path.join(webRemoteDir, 'cert.pem');
    const keyPath = path.join(webRemoteDir, 'key.pem');

    if (!fs.existsSync(pfxOrCertPath)) {
        return { success: false, error: 'File does not exist: ' + pfxOrCertPath };
    }

    const ext = path.extname(pfxOrCertPath).toLowerCase();
    if (ext === '.pfx' || ext === '.p12') {
        const password = keyPathOrPass || '';
        const psScript = [
            "$certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2('" + pfxOrCertPath.replace(/\\/g, '\\\\') + "', '" + password.replace(/'/g, "''") + "', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)",
            "$certB64 = [System.Convert]::ToBase64String($certObj.RawData, [System.Base64FormattingOptions]::InsertLineBreaks)",
            "$certPem = \"-----BEGIN CERTIFICATE-----\" + [Environment]::NewLine + $certB64 + [Environment]::NewLine + \"-----END CERTIFICATE-----\" + [Environment]::NewLine",
            "$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certObj)",
            "if (-not $rsa) { throw 'Private key not exportable or not RSA' }",
            "$keyBytes = $rsa.ExportPkcs8PrivateKey()",
            "$keyB64 = [System.Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks)",
            "$keyPem = \"-----BEGIN PRIVATE KEY-----\" + [Environment]::NewLine + $keyB64 + [Environment]::NewLine + \"-----END PRIVATE KEY-----\" + [Environment]::NewLine",
            "[System.IO.File]::WriteAllText('" + certPath.replace(/\\/g, '\\\\') + "', $certPem, [System.Text.Encoding]::UTF8)",
            "[System.IO.File]::WriteAllText('" + keyPath.replace(/\\/g, '\\\\') + "', $keyPem, [System.Text.Encoding]::UTF8)",
            'Write-Output "SUCCESS"'
        ].join('; ');

        const res = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psScript], { encoding: 'utf8' });
        if (res.status === 0 && res.stdout.includes('SUCCESS')) {
            return { success: true };
        } else {
            return { success: false, error: res.stderr || res.stdout || 'Failed to extract PFX' };
        }
    } else {
        // Assume PEM format: cert file passed as first arg, key file passed as second arg
        if (!fs.existsSync(keyPathOrPass)) {
            return { success: false, error: 'Key file does not exist: ' + keyPathOrPass };
        }
        fs.copyFileSync(pfxOrCertPath, certPath);
        fs.copyFileSync(keyPathOrPass, keyPath);
        return { success: true };
    }
}

if (require.main === module) {
    const cmd = process.argv[2] || 'gen';
    const arg1 = process.argv[3] || '';
    const arg2 = process.argv[4] || '';

    if (cmd === 'gen') {
        console.log(JSON.stringify(generateCert(arg1), null, 2));
    } else if (cmd === 'import') {
        console.log(JSON.stringify(importCert(arg1, arg2), null, 2));
    } else if (cmd === 'info') {
        const certPath = path.join(webRemoteDir, 'cert.pem');
        if (fs.existsSync(certPath)) {
            try {
                const c = new (require('crypto')).X509Certificate(fs.readFileSync(certPath));
                console.log(JSON.stringify({
                    exists: true,
                    subject: c.subject,
                    issuer: c.issuer,
                    validFrom: c.validFrom,
                    validTo: c.validTo,
                    san: c.subjectAltName
                }, null, 2));
            } catch(e) {
                console.log(JSON.stringify({ exists: true, error: e.message }, null, 2));
            }
        } else {
            console.log(JSON.stringify({ exists: false }, null, 2));
        }
    }
}

module.exports = { generateCert, importCert, getLocalIpAddresses };
