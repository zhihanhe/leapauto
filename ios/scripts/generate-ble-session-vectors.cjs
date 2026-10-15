// Independent, synthetic OFFLINE frame fixtures for the Swift session port.
// OpenSSL provides SM4; no private app data, network or Bluetooth is used.
const crypto = require('node:crypto');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const upstream = JSON.parse(execFileSync(process.execPath,
    [path.join(__dirname, '../../API/fixtures/bluetooth/generate-sm2-vectors.cjs')], { encoding: 'utf8' }));
const le = (value, size) => {
    const data = Buffer.alloc(size);
    if (size === 4) data.writeUInt32LE(value); else data.writeUInt16LE(value);
    return data;
};
const authentication = (fields, calibration, flags) => {
    const text = Buffer.from(`1800000000;${fields};${calibration};${flags}`);
    const plain = Buffer.concat([le(text.length, 4), text, Buffer.from('0102030405060708090a0b0c0d0e0f10', 'hex')]);
    const cipher = crypto.createCipheriv('sm4-cbc', Buffer.from(upstream.key), Buffer.from(upstream.iv));
    const encoded = Buffer.from(Buffer.concat([cipher.update(plain), cipher.final()]).toString('base64'));
    const payload = Buffer.concat([le(0x78563412, 4), Buffer.from(upstream.local, 'hex'), encoded, Buffer.from([1, 9])]);
    return Buffer.concat([Buffer.from([0xaa, 0xae]), le(payload.length, 2), payload]).toString('base64');
};
const fields = 'v1;test-account;test-device;TESTVIN0000000001;1700000000;1900000000';
process.stdout.write(JSON.stringify({
    onePaoC10: authentication(fields, '69;1.00;04;21', '1;0;0;0;'),
    legacyExtraFields: authentication(fields + ';extra;;', '56;2.00;08;16', '0;0;'),
    onePaoExtraFields: authentication(fields, '56;2.00;08;16', '1;0;0;0;')
}, null, 2) + '\n');
