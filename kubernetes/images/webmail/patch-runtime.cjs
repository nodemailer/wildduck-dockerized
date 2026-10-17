'use strict';

const { readFileSync, writeFileSync } = require('node:fs');

function replaceOnce(path, before, after) {
    const source = readFileSync(path, 'utf8');
    if (source.split(before).length !== 2) {
        throw new Error(`Unexpected upstream source in ${path}; review the compatibility patch`);
    }
    writeFileSync(path, source.replace(before, after));
}

// wild-config 1.6.1 compares the nested value to the string "object" instead
// of checking its type. As a result, "false" stays truthy for nested settings.
replaceOnce('/app/node_modules/wild-config/index.js',
    "if (eParent[key] === 'object') {",
    "if (typeof eParent[key] === 'object') {");

// The HTTP backend still needs Secure cookies behind the trusted TLS proxy.
replaceOnce('/app/app.js', 'secure: !!config.www.secure', "secure: true,\n            sameSite: 'lax'");
replaceOnce('/app/lib/passport.js', 'cookie: true',
    "cookie: { secure: true, httpOnly: true, sameSite: 'lax' }");
