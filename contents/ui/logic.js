// SPDX-License-Identifier: GPL-3.0-or-later

// Parse a JSON string from config storage and fall back to a known-safe value.
function safeJsonParse(serialized, fallback) {
    try {
        return JSON.parse(serialized || "");
    } catch (error) {
        return fallback;
    }
}

// Serialize config values to JSON with deterministic fallback on error.
function safeJsonStringify(value, fallback) {
    try {
        return JSON.stringify(value);
    } catch (error) {
        return fallback ?? "{}";
    }
}

function getRegistry(plasmoid) {
    return safeJsonParse(plasmoid.configuration.instanceRegistryJson, {});
}

function setRegistry(plasmoid, registry) {
    plasmoid.configuration.instanceRegistryJson = safeJsonStringify(registry, "{}");
}

function getNameMap(plasmoid) {
    return safeJsonParse(plasmoid.configuration.nameMapJson, {});
}

function setNameMap(plasmoid, map) {
    plasmoid.configuration.nameMapJson = safeJsonStringify(map, "{}");
}

function getDeviceFlags(plasmoid) {
    return safeJsonParse(plasmoid.configuration.deviceFlagConfigsJson, {});
}

function setDeviceFlags(plasmoid, map) {
    plasmoid.configuration.deviceFlagConfigsJson = safeJsonStringify(map, "{}");
}

function getTransportAliases(plasmoid) {
    const aliases = safeJsonParse(plasmoid.configuration.transportAliasesJson, {});
    return aliases && typeof aliases === "object" && !Array.isArray(aliases) ? aliases : {};
}

function setTransportAliases(plasmoid, aliases) {
    plasmoid.configuration.transportAliasesJson = safeJsonStringify(aliases, "{}");
}

function getPreferredTransports(plasmoid) {
    const preferred = safeJsonParse(plasmoid.configuration.preferredTransportsJson, {});
    return preferred && typeof preferred === "object" && !Array.isArray(preferred) ? preferred : {};
}

function setPreferredTransports(plasmoid, preferred) {
    plasmoid.configuration.preferredTransportsJson = safeJsonStringify(preferred, "{}");
}

function getTemplates(plasmoid) {
    const templates = safeJsonParse(plasmoid.configuration.templatesJson, []);
    return Array.isArray(templates) ? templates : [];
}

function setTemplates(plasmoid, templates) {
    plasmoid.configuration.templatesJson = safeJsonStringify(templates, "[]");
}

function upsertTemplate(plasmoid, name, flags) {
    const templateName = String(name || "").trim();
    if (!templateName.length) return;

    const templateFlags = String(flags || "");
    const templates = getTemplates(plasmoid);
    const index = templates.findIndex(template => template && String(template.name).trim() === templateName);

    if (index >= 0) {
        templates[index] = { name: templateName, flags: templateFlags };
    } else {
        templates.push({ name: templateName, flags: templateFlags });
    }

    setTemplates(plasmoid, templates);
}

function removeTemplate(plasmoid, name) {
    const templateName = String(name || "").trim();
    if (!templateName.length) return;

    const templates = getTemplates(plasmoid).filter(template => String(template.name).trim() !== templateName);
    setTemplates(plasmoid, templates);
}

// Use PID/start time/UID as a stable process identity key.
function instanceKey(record) {
    return `${record.pid}:${record.startticks}:${record.uid}`;
}

// Parse tab-separated process rows emitted by the helper script.
function parseScanOutput(stdout) {
    const lines = (stdout || "").split("\n").map(line => line.trim()).filter(Boolean);
    const processes = [];

    for (const line of lines) {
        const parts = line.split("\t");
        if (parts.length < 6) continue;

        const [pid, uid, startticks, exe, cmdhash, ...rest] = parts;
        processes.push({
            pid: Number(pid),
            uid: Number(uid),
            startticks: String(startticks),
            exe: String(exe),
            cmdhash: String(cmdhash),
            cmdline: String(rest.join("\t"))
        });
    }

    return processes;
}

// Parse `key=value` lines emitted by the helper script.
function parseKvOutput(stdout) {
    const output = {};
    for (const line of (stdout || "").split("\n")) {
        const delimiter = line.indexOf("=");
        if (delimiter <= 0) continue;

        const key = line.slice(0, delimiter).trim();
        const value = line.slice(delimiter + 1);
        output[key] = value;
    }
    return output;
}

// Extract the device serial argument from a scrcpy command line.
function extractSerialFromCmdline(cmdline) {
    const argv = (cmdline || "").split(/\s+/).filter(Boolean);
    for (let i = 0; i < argv.length; i++) {
        const argument = argv[i];
        if ((argument === "--serial" || argument === "-s") && i + 1 < argv.length) return argv[i + 1];
        if (argument.startsWith("--serial=")) return argument.slice("--serial=".length);
    }
    return "";
}

// Infer the ADB transport from all serial forms used by USB, TCP/IP and mDNS.
function inferConnTypeFromSerial(serial) {
    if (!serial) return "unknown";
    if (/^emulator-\d+$/.test(serial)) return "emulator";
    if (/^\[[^\]]+\]:\d+$/.test(serial)) return "wifi";
    if (/^[A-Za-z0-9._-]+:\d+$/.test(serial)) return "wifi";
    if (/\._adb(?:-tls)?-connect\._tcp\.?$/.test(serial)) return "wifi";
    return "usb";
}

// Wireless debugging mDNS serials embed the device serial before the service suffix.
function stableIdFromMdnsSerial(serial) {
    const match = /^adb-([A-Za-z0-9]+)-.+\._adb-tls-connect\._tcp\.?$/.exec(serial || "");
    return match ? match[1] : "";
}

function stableDeviceId(serial, aliases) {
    if (!serial) return "__UNKNOWN__";
    const aliasMap = aliases && typeof aliases === "object" ? aliases : {};
    if (aliasMap[serial] && String(aliasMap[serial]).length) return String(aliasMap[serial]);
    return stableIdFromMdnsSerial(serial) || serial;
}

function isValidPort(value) {
    if (!/^\d+$/.test(String(value || ""))) return false;
    const port = Number(value);
    return Number.isInteger(port) && port >= 1 && port <= 65535;
}

function parseEndpoint(value) {
    const endpoint = String(value || "").trim();
    let host = "";
    let port = "";
    let match = /^\[([^\]]+)\]:(\d+)$/.exec(endpoint);

    if (match) {
        host = "[" + match[1] + "]";
        port = match[2];
    } else {
        match = /^([A-Za-z0-9._-]+):(\d+)$/.exec(endpoint);
        if (match) {
            host = match[1];
            port = match[2];
        }
    }

    if (!host.length || !isValidPort(port)) {
        return { ok: false, endpoint: endpoint, host: "", port: "" };
    }
    return { ok: true, endpoint: host + ":" + String(Number(port)), host: host, port: String(Number(port)) };
}

// Return scrcpy flags while excluding device-selection flags.
function extractFlagsFromCmdline(cmdline) {
    const argv = (cmdline || "").split(/\s+/).filter(Boolean);
    const flags = [];

    for (let i = 0; i < argv.length; i++) {
        const argument = argv[i];
        if (!argument.startsWith("--")) continue;
        if (argument === "--serial") {
            i++;
            continue;
        }
        if (argument.startsWith("--serial=")) continue;
        flags.push(argument);
    }

    return flags;
}

// Return the smallest unused positive instance number among active assignments.
function nextFreeInstanceNumberIn(registry, requestedKey) {
    if (!registry._numbers) registry._numbers = {};

    const used = {};
    for (const registryKey in registry._numbers) {
        if (registryKey === requestedKey) continue;
        if (!registry[registryKey]) continue;

        const value = Number(registry._numbers[registryKey]);
        if (Number.isInteger(value) && value > 0) used[value] = true;
    }

    let candidate = 1;
    while (used[candidate]) candidate++;
    return candidate;
}

// Allocate and persist the lowest available number used by automatic names.
function ensureNumberForInstanceIn(registry, key) {
    if (!registry._numbers) registry._numbers = {};
    if (!registry._numbers[key]) {
        registry._numbers[key] = nextFreeInstanceNumberIn(registry, key);
    }
    return registry._numbers[key];
}

function defaultInstanceNameIn(registry, key, isOutside, i18nFunc) {
    const number = ensureNumberForInstanceIn(registry, key);
    if (isOutside) return i18nFunc("scrcpy instance (outside) %1", number);
    return i18nFunc("scrcpy instance %1", number);
}

function getDisplayNameIn(registry, plasmoid, key, isOutside, i18nFunc) {
    const map = getNameMap(plasmoid);
    if (map[key] && String(map[key]).trim().length) return String(map[key]);
    return defaultInstanceNameIn(registry, key, isOutside, i18nFunc);
}

function setCustomName(plasmoid, key, name) {
    const map = getNameMap(plasmoid);
    const normalized = String(name || "").trim();

    if (normalized.length) map[key] = normalized;
    else delete map[key];

    setNameMap(plasmoid, map);
}

function statePriority(state) {
    if (state === "device") return 4;
    if (state === "unauthorized") return 3;
    if (state === "offline") return 2;
    if (state === "no_permissions") return 1;
    return 0;
}

// Group ADB transports into physical devices. Aliases are learned after identity checks.
function buildDevicesFromAdb(deviceList, aliases) {
    const grouped = {};
    const order = [];

    for (const device of (deviceList || [])) {
        if (!device || !device.serial) continue;

        const id = stableDeviceId(device.serial, aliases);
        if (!grouped[id]) {
            grouped[id] = {
                id,
                title: device.model || id,
                icon: "smartphone",
                state: device.state || "unknown",
                transports: []
            };
            order.push(id);
        }

        const target = grouped[id];
        if (!target.title.length || target.title === id) target.title = device.model || id;
        if (statePriority(device.state) > statePriority(target.state)) target.state = device.state;
        target.transports.push({
            serial: device.serial,
            type: inferConnTypeFromSerial(device.serial),
            state: device.state || "unknown",
            model: device.model || ""
        });
    }

    return order.map(id => {
        const device = grouped[id];
        device.transports.sort((left, right) => {
            if (left.state === "device" && right.state !== "device") return -1;
            if (right.state === "device" && left.state !== "device") return 1;
            const rank = { usb: 0, wifi: 1, emulator: 2, unknown: 3 };
            return (rank[left.type] ?? 9) - (rank[right.type] ?? 9);
        });
        return device;
    });
}

// Parse `adb devices -l` output and extract basic metadata.
function parseAdbDevicesList(stdout) {
    const devices = [];
    for (const rawLine of (stdout || "").split("\n")) {
        const line = rawLine.trim();
        if (!line || line.startsWith("List of devices") || line.startsWith("*")) continue;

        const parts = line.split(/\s+/);
        if (parts.length < 2) continue;

        const serial = parts[0];
        const state = /^\S+\s+no permissions\b/.test(line) ? "no_permissions" : parts[1];
        let model = "";

        for (const part of parts.slice(2)) {
            if (part.startsWith("model:")) {
                model = part.slice("model:".length).replace(/_/g, " ");
            }
        }

        devices.push({ serial, state, model });
    }
    return devices;
}

// Group instances by physical device while preserving unknown-device entries.
function groupInstancesByDevice(instances, aliases) {
    const grouped = {};
    for (const instance of instances || []) {
        const key = stableDeviceId(instance.serial, aliases);
        if (!grouped[key]) grouped[key] = [];
        grouped[key].push(instance);
    }
    return grouped;
}

function getDeviceDefaultFlags(plasmoid, serial) {
    const map = getDeviceFlags(plasmoid);
    return map[serial] || {};
}

function setDeviceDefaultFlags(plasmoid, serial, flagsObj) {
    const map = getDeviceFlags(plasmoid);
    map[serial] = flagsObj;
    setDeviceFlags(plasmoid, map);
}

// Remove control characters and normalize whitespace in advanced flag input.
function sanitizeFlagsInput(raw) {
    return String(raw || "")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "");
}

// Tokenize shell-like input with simple quote and escape handling.
function tokenizeFlagsInput(input) {
    const src = String(input || "");
    const args = [];
    let token = "";
    let quote = "";
    let escaped = false;

    for (let i = 0; i < src.length; i++) {
        const ch = src[i];

        if (escaped) {
            token += ch;
            escaped = false;
            continue;
        }

        if (ch === "\\") {
            escaped = true;
            continue;
        }

        if (quote) {
            if (ch === quote) {
                quote = "";
            } else {
                token += ch;
            }
            continue;
        }

        if (ch === "'" || ch === "\"") {
            quote = ch;
            continue;
        }

        if (/\s/.test(ch)) {
            if (token.length) {
                args.push(token);
                token = "";
            }
            continue;
        }

        token += ch;
    }

    if (escaped) return { ok: false, args: [], errorCode: "trailing_escape" };
    if (quote) return { ok: false, args: [], errorCode: "unterminated_quote" };
    if (token.length) args.push(token);

    return { ok: true, args, errorCode: "" };
}

// Block flags that alter target-device selection; selection is controlled by UI.
function detectForbiddenFlag(args) {
    const forbiddenMatchers = [
        /^-s$/,
        /^-s.+$/,
        /^--serial$/,
        /^--serial=.*/,
        /^-d$/,
        /^-e$/,
        /^--select-usb$/,
        /^--select-tcpip$/,
        /^--tcpip$/,
        /^--tcpip=.*/,
        /^--tunnel-host$/,
        /^--tunnel-host=.*/,
        /^--tunnel-port$/,
        /^--tunnel-port=.*/
    ];

    for (const arg of args || []) {
        for (const matcher of forbiddenMatchers) {
            if (matcher.test(arg)) return arg;
        }
    }
    return "";
}

function validateAdditionalFlagsInput(rawInput) {
    const sanitized = sanitizeFlagsInput(rawInput);
    const parsed = tokenizeFlagsInput(sanitized);
    if (!parsed.ok) {
        return {
            ok: false,
            args: [],
            sanitized,
            errorCode: parsed.errorCode,
            forbiddenFlag: ""
        };
    }

    const forbidden = detectForbiddenFlag(parsed.args);
    if (forbidden.length) {
        return {
            ok: false,
            args: [],
            sanitized,
            errorCode: "forbidden_flag",
            forbiddenFlag: forbidden
        };
    }

    return {
        ok: true,
        args: parsed.args,
        sanitized,
        errorCode: "",
        forbiddenFlag: ""
    };
}
