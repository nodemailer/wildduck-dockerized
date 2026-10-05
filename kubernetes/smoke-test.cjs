// Run inside the WildDuck pod in an isolated test cluster; see README.md.
// Creates a temporary mailbox, tests edge submission AUTH and inbound STARTTLS,
// verifies that Kirin stored the message, and deletes the mailbox afterwards.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const https = require('node:https');
const tls = require('node:tls');
const nodemailer = require('nodemailer');

const domain = process.env.APPCONF_emailDomain;
const hostname = process.env.APPCONF_imap_setup_hostname;
const username = `k8s-smoke-${Date.now()}`;
const address = `${username}@${domain}`;
const password = crypto.randomBytes(24).toString('hex');
const edge = 'traefik.traefik.svc.cluster.local';
const api = (method, path, payload) => new Promise((resolve, reject) => {
    const data = payload ? JSON.stringify(payload) : '';
    const request = http.request({host:'127.0.0.1',port:8080,path,method,
        headers:{'X-Access-Token':process.env.APPCONF_api_accessToken,
            'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)}}, response => {
        let body = '';
        response.on('data', chunk => {body += chunk});
        response.on('end', () => {
            if (response.statusCode !== 200) return reject(new Error(`API ${method} ${path}: ${response.statusCode}`));
            try {resolve(JSON.parse(body))} catch (error) {reject(error)}
        });
    });
    request.setTimeout(10000, () => request.destroy(new Error('API timeout')));
    request.on('error', reject);
    request.end(data);
});

(async () => {
    let user;
    try {
        for (const [port, greeting] of [[993, '* OK'], [995, '+OK']]) {
            await new Promise((resolve, reject) => {
                const socket = tls.connect({host:edge,port,servername:hostname,rejectUnauthorized:false});
                socket.setTimeout(10000, () => socket.destroy(new Error('Mail TLS timeout')));
                socket.once('error', reject);
                socket.once('data', data => {
                    socket.end();
                    if (!data.toString().startsWith(greeting)) return reject(new Error(`Unexpected greeting on ${port}`));
                    resolve();
                });
            });
        }
        console.log('PASS: IMAPS and POP3S through Traefik');
        await new Promise((resolve, reject) => {
            const request = https.get({host:edge,port:443,servername:hostname,rejectUnauthorized:false,
                headers:{Host:hostname}}, response => {
                response.resume();
                if (response.statusCode !== 200) return reject(new Error(`Webmail HTTP ${response.statusCode}`));
                const session = (response.headers['set-cookie'] || []).find(cookie => cookie.startsWith('webmail='));
                if (!session || !/; Secure(?:;|$)/i.test(session)) return reject(new Error('Webmail session cookie must be Secure'));
                if (!(response.headers['set-cookie'] || []).every(cookie => /; Secure(?:;|$)/i.test(cookie))) {
                    return reject(new Error('All webmail cookies must be Secure'));
                }
                resolve();
            });
            request.setTimeout(10000, () => request.destroy(new Error('Webmail timeout')));
            request.once('error', reject);
        });
        console.log('PASS: HTTPS webmail and Secure session cookie');
        user = await api('POST', '/users', {username,address,password});
        assert.ok(user.id, 'API must create a mailbox');
        const submission = nodemailer.createTransport({host:edge,port:465,
            secure:true,auth:{user:address,pass:password},
            tls:{servername:hostname,rejectUnauthorized:false}});
        await submission.verify();
        submission.close();
        console.log('PASS: SMTPS authentication through Traefik');
        const inbound = nodemailer.createTransport({host:edge,port:25,
            requireTLS:true,tls:{servername:hostname,rejectUnauthorized:false}});
        await inbound.sendMail({from:'smoke@example.invalid',to:address,
            subject:'Kubernetes smoke test',text:'Inbound delivery through Traefik, Kirin, and Rspamd.'});
        inbound.close();
        const mailboxes = await api('GET', `/users/${user.id}/mailboxes?counters=true`);
        const inbox = mailboxes.results.find(mailbox => mailbox.path === 'INBOX');
        assert.ok(inbox, 'INBOX must exist');
        const messages = await api('GET', `/users/${user.id}/mailboxes/${inbox.id}/messages`);
        assert.ok(messages.results.some(message => message.subject === 'Kubernetes smoke test'), 'INBOX must contain the message');
        console.log('PASS: SMTP STARTTLS and inbound message storage');
    } finally {
        if (user?.id) await api('DELETE', `/users/${user.id}`);
    }
})().catch(error => {console.error(error.message);process.exitCode = 1});
