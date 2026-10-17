const admin = db.getSiblingDB('admin');
const username = process.env.MONGO_APP_USERNAME;
const password = process.env.MONGO_APP_PASSWORD;

if (!username || !password) {
    throw new Error('MONGO_APP_USERNAME and MONGO_APP_PASSWORD are required');
}

if (!admin.getUser(username)) {
    admin.createUser({
        user: username,
        pwd: password,
        roles: [
            { role: 'readWrite', db: 'wildduck' },
            { role: 'readWrite', db: 'zone-mta' },
            { role: 'readWrite', db: 'wildduck-webmail' }
        ]
    });
}
