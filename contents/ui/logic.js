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

// Infer transport type from serial format.
function inferConnTypeFromSerial(serial) {
    if (!serial) return "unknown";
    if (/^\d{1,3}(\.\d{1,3}){3}:\d+$/.test(serial)) return "wifi";
    return "usb";
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

// Build device cards from ADB output for known online devices only.
function buildDevicesFromAdb(deviceList) {
    return (deviceList || [])
    .filter(device => device && device.state === "device")
    .map(device => ({
        id: device.serial,
        title: device.model ? device.model : device.serial,
        icon: "smartphone"
    }));
}

// Parse `adb devices -l` output and extract basic metadata.
function parseAdbDevicesList(stdout) {
    const devices = [];
    for (const rawLine of (stdout || "").split("\n")) {
        const line = rawLine.trim();
        if (!line || line.startsWith("List of devices")) continue;

        const parts = line.split(/\s+/);
        if (parts.length < 2) continue;

        const serial = parts[0];
        const state = parts[1];
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

// Group instances by serial while preserving unknown-device entries.
function groupInstancesByDevice(instances) {
    const grouped = {};
    for (const instance of instances || []) {
        const key = instance.serial || "__UNKNOWN__";
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
