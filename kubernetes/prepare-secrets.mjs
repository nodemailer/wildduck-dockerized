#!/usr/bin/env node
// Generate an untracked production env file without printing any credentials.
import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const destination = fileURLToPath(new URL('./overlays/production/secrets.env', import.meta.url));
const values = {};
if (process.argv[2]) {
    // Accept ordinary KEY=value assignments; never execute the Compose env file.
    for (const line of readFileSync(process.argv[2], 'utf8').split(/\r?\n/)) {
        const match = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
        if (!match) continue;
        let value = match[2].trim();
        if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
            value = value.slice(1, -1);
        }
        if (/\$\{|\$\(/.test(value)) throw new Error(`Shell interpolation is not supported for ${match[1]}`);
        values[match[1]] = value;
    }
}
const secret = () => randomBytes(32).toString('hex');
const output = {};
for (const name of ['WILDDUCK_API_ACCESS_TOKEN', 'WILDDUCK_API_ACCESSCONTROL_SECRET',
    'WILDDUCK_LOOP_SECRET', 'WILDDUCK_DKIM_SECRET', 'WILDDUCK_TOTP_SECRET',
    'WEBMAIL_SESSION_SECRET', 'WEBMAIL_TOTP_SECRET']) {
    output[name] = values[name] || secret();
}
output.MONGO_ROOT_USERNAME = values.MONGO_ROOT_USERNAME || 'wildduck-root';
output.MONGO_ROOT_PASSWORD = values.MONGO_ROOT_PASSWORD || secret();
output.MONGO_APP_USERNAME = values.MONGO_APP_USERNAME || 'wildduck';
output.MONGO_APP_PASSWORD = values.MONGO_APP_PASSWORD || secret();
const credentials = `${encodeURIComponent(output.MONGO_APP_USERNAME)}:${encodeURIComponent(output.MONGO_APP_PASSWORD)}`;
for (const name of ['WILDDUCK', 'WEBMAIL', 'ZONEMTA', 'KIRIN']) {
    const database = name === 'WEBMAIL' ? 'wildduck-webmail' : 'wildduck';
    output[`${name}_MONGO_URL`] = values[`${name}_MONGO_URL`] || `mongodb://${credentials}@mongo:27017/${database}?authSource=admin`;
}
for (const [name, database] of [['WILDDUCK', 3], ['WEBMAIL', 5], ['ZONEMTA', 2]]) {
    output[`${name}_REDIS_URL`] = values[`${name}_REDIS_URL`] || `redis://redis:6379/${database}`;
}
writeFileSync(destination, Object.entries(output).map(([key, value]) => `${key}=${value}`).join('\n') + '\n', {
    flag: 'wx', mode: 0o600
});
console.log('Created kubernetes/overlays/production/secrets.env (mode 0600). Existing files are never overwritten.');
