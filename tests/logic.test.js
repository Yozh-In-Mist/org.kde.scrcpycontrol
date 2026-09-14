#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const logicPath = path.join(__dirname, "..", "contents", "ui", "logic.js");
const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(logicPath, "utf8"), context, { filename: logicPath });

const transportCases = new Map([
    ["43081FDAS000VS", "usb"],
    ["emulator-5554", "emulator"],
    ["192.168.1.20:5555", "wifi"],
    ["phone.local:5555", "wifi"],
    ["[fe80::1%wlan0]:5555", "wifi"],
    ["adb-43081FDAS000VS-QXjCrW._adb-tls-connect._tcp", "wifi"]
]);
for (const [serial, expected] of transportCases) {
    assert.strictEqual(context.inferConnTypeFromSerial(serial), expected, serial);
}

for (const endpoint of ["phone.local:5555", "192.168.1.20:1", "[fe80::1%wlan0]:65535"]) {
    assert.strictEqual(context.parseEndpoint(endpoint).ok, true, endpoint);
}
for (const endpoint of ["phone.local", "phone.local:0", "phone.local:65536", ":5555"]) {
    assert.strictEqual(context.parseEndpoint(endpoint).ok, false, endpoint);
}

const parsed = context.parseAdbDevicesList([
    "* daemon started successfully",
    "List of devices attached",
    "USB123 device product:foo model:Pixel_7 transport_id:1",
    "USB456 unauthorized usb:1-2",
    "USB789 no permissions (user in plugdev group)"
].join("\n"));
assert.deepStrictEqual(
    JSON.parse(JSON.stringify(parsed)),
    [
        { serial: "USB123", state: "device", model: "Pixel 7" },
        { serial: "USB456", state: "unauthorized", model: "" },
        { serial: "USB789", state: "no_permissions", model: "" }
    ]
);

const mdnsSerial = "adb-USB123-QXjCrW._adb-tls-connect._tcp";
const grouped = context.buildDevicesFromAdb([
    { serial: "USB123", state: "device", model: "Pixel 7" },
    { serial: mdnsSerial, state: "device", model: "Pixel 7" }
], {});
assert.strictEqual(grouped.length, 1);
assert.strictEqual(grouped[0].id, "USB123");
assert.strictEqual(grouped[0].transports.length, 2);

const endpointAlias = { "192.168.1.20:5555": "USB123" };
const aliased = context.buildDevicesFromAdb([
    { serial: "USB123", state: "device", model: "Pixel 7" },
    { serial: "192.168.1.20:5555", state: "device", model: "Pixel 7" }
], endpointAlias);
assert.strictEqual(aliased.length, 1);
assert.strictEqual(aliased[0].transports.length, 2);

const instances = context.groupInstancesByDevice([
    { serial: "USB123", pid: 1 },
    { serial: "192.168.1.20:5555", pid: 2 }
], endpointAlias);
assert.strictEqual(instances.USB123.length, 2);

console.log("logic tests passed");
