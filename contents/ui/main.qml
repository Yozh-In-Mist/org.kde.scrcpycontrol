// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15 as QQC2

import org.kde.plasma.plasma5support 2.0 as Plasma5Support
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.extras 2.0 as PlasmaExtras

import "logic.js" as Logic

PlasmoidItem {
    id: root

    preferredRepresentation: PlasmoidItem.CompactRepresentation
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 12

    implicitWidth: Kirigami.Units.gridUnit * 30
    implicitHeight: Kirigami.Units.gridUnit * 28

    property bool depsOk: false
    property var adbDevices: []
    property var scanned: []
    property var instancesByDevice: ({})
    property var deviceCards: []

    property var expandedMap: ({})
    property var createOpenMap: ({})

    property var pendingJobs: ({})
    property var inFlightKinds: ({})
    property var pendingIdentitySerials: ({})
    property var identityCheckedSerials: ({})

    property var transportAliases: ({})
    property var preferredTransports: ({})

    // Active page identifier for the stacked content area.
    property string pageMode: "main"

    property string outputTitle: ""
    property string outputText: ""
    property bool outputLoading: false
    property string searchQuery: ""

    property string wifiStatusText: ""
    property string wifiStatusKind: "information"
    property string wifiDetailsText: ""
    property bool wifiBusy: false
    property string wifiOperationToken: ""

    readonly property int runningCount: {
        let count = 0;
        for (const key in instancesByDevice) count += (instancesByDevice[key] || []).length;
        return count;
    }

    readonly property bool hasDevices: (adbDevices || []).some(device => device && device.state === "device")
    readonly property bool hasProblemDevices: (adbDevices || []).some(device => device && device.state !== "device")
    readonly property int pollIntervalMs: Plasmoid.expanded ? 1500 : 5000

    readonly property string baseIconName: {
        if (!depsOk) return "dialog-error";
        if (hasDevices) return "smartphoneconnected";
        if (hasProblemDevices) return "dialog-warning";
        return "smartphonedisconnected";
    }

    readonly property string headerTitle: {
        if (pageMode === "wifi") return i18n("Connect a device");
        if (pageMode === "output") return outputTitle.length ? outputTitle : i18n("Output");
        return i18n("scrcpy Control");
    }
    readonly property string helpIconName: {
        if (helpIconContextual.valid) return "help-contextual";
        if (helpIconBrowser.valid) return "help-browser";
        if (helpIconContents.valid) return "help-contents";
        return "dialog-information";
    }

    readonly property var filteredDeviceCards: {
        const query = String(searchQuery || "").trim().toLowerCase();
        if (!query.length) return deviceCards;

        const filtered = [];
        for (const card of (deviceCards || [])) {
            if (!card) continue;
            const titleMatch = String(card.title || "").toLowerCase().includes(query)
                || String(card.deviceId || "").toLowerCase().includes(query);
            const hasMatchingInstances = filteredInstancesForDevice(card.deviceId).length > 0;
            if (titleMatch || hasMatchingInstances) filtered.push(card);
        }
        return filtered;
    }

    toolTipMainText: i18n("scrcpy Control")
    toolTipSubText: {
        if (!depsOk) return i18n("Missing dependencies");
        if (!hasDevices && hasProblemDevices) return i18n("A device needs attention");
        if (!hasDevices) return i18n("No devices detected");
        if (runningCount === 0) return i18n("No running instances.");
        return i18np("%1 instance running", "%1 instances running", runningCount);
    }

    Plasmoid.icon: baseIconName
    Plasmoid.status: depsOk && !(hasProblemDevices && !hasDevices)
        ? PlasmaCore.Types.ActiveStatus
        : PlasmaCore.Types.NeedsAttentionStatus

    Kirigami.Icon {
        id: helpIconContextual
        visible: false
        source: "help-contextual"
    }

    Kirigami.Icon {
        id: helpIconBrowser
        visible: false
        source: "help-browser"
    }

    Kirigami.Icon {
        id: helpIconContents
        visible: false
        source: "help-contents"
    }

    function scriptPath() {
        const url = Qt.resolvedUrl("../scripts/scrcpyctl.sh").toString();
        return url.startsWith("file://") ? url.replace("file://", "") : url;
    }

    function shQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    // Select the most informative command output for UI messages.
    function bestMessage(out, err, fallbackText) {
        const stdout = (out || "").trim();
        if (stdout.length) return stdout;
        const stderr = (err || "").trim();
        if (stderr.length) return stderr;
        return fallbackText;
    }

    // Build opaque tags. User-controlled values never become part of the shell command marker.
    function makeTag(prefix) {
        const safePrefix = String(prefix || "job").replace(/[^A-Za-z0-9_-]/g, "_");
        return safePrefix + "_" + Date.now().toString() + "_" + Math.floor(Math.random() * 1000000).toString();
    }

    function decodeBase64Utf8(encoded) {
        if (!encoded || !String(encoded).length) return "";
        try {
            const binary = Qt.atob(String(encoded));
            let escaped = "";
            for (let i = 0; i < binary.length; i++) {
                escaped += "%" + ("0" + binary.charCodeAt(i).toString(16)).slice(-2);
            }
            return decodeURIComponent(escaped);
        } catch (error) {
            return "";
        }
    }

    function parseHelperResult(out, err, exitCode) {
        const kv = Logic.parseKvOutput(out);
        return {
            ok: kv.status === "success" && Number(exitCode) === 0,
            status: kv.status || "error",
            code: kv.code || (Number(exitCode) === 0 ? "unknown_result" : "command_failed"),
            detail: decodeBase64Utf8(kv.detail_b64) || (err || "").trim(),
            endpoint: decodeBase64Utf8(kv.endpoint_b64),
            serial: decodeBase64Utf8(kv.serial_b64),
            stableId: decodeBase64Utf8(kv.stable_id_b64)
        };
    }

    function loadUiState() {
        expandedMap = Logic.safeJsonParse(plasmoid.configuration.expandedDevicesJson, {});
        createOpenMap = Logic.safeJsonParse(plasmoid.configuration.createOpenDevicesJson, {});
        transportAliases = Logic.getTransportAliases(plasmoid);
        preferredTransports = Logic.getPreferredTransports(plasmoid);
    }

    function saveUiState() {
        plasmoid.configuration.expandedDevicesJson = Logic.safeJsonStringify(expandedMap, "{}");
        plasmoid.configuration.createOpenDevicesJson = Logic.safeJsonStringify(createOpenMap, "{}");
    }

    function savePreferredTransport(deviceId, serial) {
        if (!deviceId || !serial) return;
        preferredTransports[deviceId] = serial;
        preferredTransports = Object.assign({}, preferredTransports);
        Logic.setPreferredTransports(plasmoid, preferredTransports);
    }

    function storeTransportAlias(serial, stableId) {
        const transportSerial = String(serial || "");
        const deviceId = String(stableId || "");
        if (!transportSerial.length || !deviceId.length || transportSerial === deviceId) return;

        const hadAlias = !!transportAliases[transportSerial];
        const oldDeviceId = Logic.stableDeviceId(transportSerial, transportAliases);
        transportAliases[transportSerial] = deviceId;
        transportAliases = Object.assign({}, transportAliases);
        Logic.setTransportAliases(plasmoid, transportAliases);

        if (oldDeviceId !== deviceId && !hadAlias) {
            const flags = Logic.getDeviceFlags(plasmoid);
            if (flags[oldDeviceId] && !flags[deviceId]) flags[deviceId] = flags[oldDeviceId];
            delete flags[oldDeviceId];
            Logic.setDeviceFlags(plasmoid, flags);

            if (expandedMap[oldDeviceId] !== undefined && expandedMap[deviceId] === undefined) {
                expandedMap[deviceId] = expandedMap[oldDeviceId];
            }
            if (createOpenMap[oldDeviceId] !== undefined && createOpenMap[deviceId] === undefined) {
                createOpenMap[deviceId] = createOpenMap[oldDeviceId];
            }
            delete expandedMap[oldDeviceId];
            delete createOpenMap[oldDeviceId];
            saveUiState();

            if (preferredTransports[oldDeviceId] && !preferredTransports[deviceId]) {
                preferredTransports[deviceId] = preferredTransports[oldDeviceId];
            }
            delete preferredTransports[oldDeviceId];
            preferredTransports = Object.assign({}, preferredTransports);
            Logic.setPreferredTransports(plasmoid, preferredTransports);
        }

        rebuildInstances();
        rebuildDeviceCards();
    }

    Plasma5Support.DataSource {
        id: exec

        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            const out = (data["stdout"] || "").toString();
            const err = (data["stderr"] || "").toString();
            const marker = " #SCRCPYCTL_JOB=";
            const markerIndex = sourceName.lastIndexOf(marker);
            const tag = markerIndex >= 0 ? sourceName.slice(markerIndex + marker.length) : "";
            const job = root.pendingJobs[tag] || { kind: "unknown", context: ({}) };
            delete root.pendingJobs[tag];
            root.pendingJobs = Object.assign({}, root.pendingJobs);
            if (job.dedupe) {
                delete root.inFlightKinds[job.kind];
                root.inFlightKinds = Object.assign({}, root.inFlightKinds);
            }
            const exitCode = data["exit code"] !== undefined ? Number(data["exit code"]) : -1;
            handle(job.kind, out, err, exitCode, job.context || ({}));
            exec.disconnectSource(sourceName);
        }

        function run(command, kind, context, dedupe) {
            if (dedupe && root.inFlightKinds[kind]) return "";
            const tag = root.makeTag(kind);
            root.pendingJobs[tag] = { kind: kind, context: context || ({}), dedupe: !!dedupe };
            root.pendingJobs = Object.assign({}, root.pendingJobs);
            if (dedupe) {
                root.inFlightKinds[kind] = true;
                root.inFlightKinds = Object.assign({}, root.inFlightKinds);
            }
            connectSource(command + " #SCRCPYCTL_JOB=" + tag);
            return tag;
        }
    }

    function refreshDevicesAndInstances() {
        exec.run("adb devices -l", "adb", ({}), true);
        exec.run("bash " + shQuote(scriptPath()) + " scan", "scan", ({}), true);
    }

    function showOutput(title, text, loading) {
        outputTitle = title || i18n("Output");
        outputText = text || "";
        outputLoading = !!loading;
        pageMode = "output";
    }

    function handle(kind, out, err, exitCode, context) {
        if (kind === "deps") {
            const adbAvailable = out.includes("adb=OK");
            const scrcpyAvailable = out.includes("scrcpy=OK");
            const coreutilsAvailable = out.includes("coreutils=OK");
            depsOk = adbAvailable && scrcpyAvailable && coreutilsAvailable;

            if (depsOk) {
                refreshDevicesAndInstances();
            } else {
                adbDevices = [];
                scanned = [];
                instancesByDevice = ({ });
                deviceCards = [];
            }
            return;
        }

        if (kind === "adb") {
            adbDevices = Logic.parseAdbDevicesList(out);
            const presentSerials = {};
            for (const device of adbDevices) presentSerials[device.serial] = true;
            for (const serial in identityCheckedSerials) {
                if (!presentSerials[serial]) delete identityCheckedSerials[serial];
            }
            identityCheckedSerials = Object.assign({}, identityCheckedSerials);
            rebuildDeviceCards();
            resolveUnknownWifiIdentities();
            return;
        }

        if (kind === "scan") {
            scanned = Logic.parseScanOutput(out);
            rebuildInstances();
            rebuildDeviceCards();
            return;
        }

        if (kind === "start") {
            const kv = Logic.parseKvOutput(out);
            if (exitCode === 0 && kv.pid && kv.uid && kv.startticks && kv.cmdhash) {
                const record = {
                    pid: Number(kv.pid),
                    uid: Number(kv.uid),
                    startticks: String(kv.startticks),
                    cmdhash: String(kv.cmdhash)
                };

                const key = Logic.instanceKey(record);
                const registry = Logic.getRegistry(plasmoid);
                registry[key] = {
                    origin: "internal",
                    uid: record.uid,
                    startticks: record.startticks,
                    cmdhash: record.cmdhash,
                    logfile: kv.logfile ? String(kv.logfile) : ""
                };
                Logic.setRegistry(plasmoid, registry);

                const name = String(context.name || "").trim();
                if (name.length) Logic.setCustomName(plasmoid, key, name);
            } else {
                showBanner(bestMessage(out, err, i18n("Could not start scrcpy.")));
            }
            refreshScanSoon();
            return;
        }

        if (kind === "stop") {
            if (exitCode !== 0) showBanner(bestMessage(out, err, i18n("Could not stop the scrcpy instance.")));
            refreshScanSoon();
            return;
        }

        if (kind === "identity") {
            const serial = String(context.serial || "");
            delete pendingIdentitySerials[serial];
            pendingIdentitySerials = Object.assign({}, pendingIdentitySerials);
            identityCheckedSerials[serial] = true;
            identityCheckedSerials = Object.assign({}, identityCheckedSerials);

            const result = parseHelperResult(out, err, exitCode);
            if (result.ok && result.serial.length && result.stableId.length) {
                storeTransportAlias(result.serial, result.stableId);
            }
            return;
        }

        if (kind.startsWith("wifi_")) {
            handleWifiResult(kind, parseHelperResult(out, err, exitCode), context);
            return;
        }

        if (kind === "help") {
            showOutput(i18n("scrcpy Help"), bestMessage(out, err, i18n("No help output available.")), false);
            return;
        }

        if (kind === "log") {
            const title = String(context.title || "") || i18n("Instance logs");
            showOutput(title, bestMessage(out, err, i18n("No log output available.")), false);
            return;
        }
    }

    function refreshAll() {
        exec.run("bash " + shQuote(scriptPath()) + " deps", "deps", ({}), true);
    }

    Timer {
        id: scanTimer
        interval: root.pollIntervalMs
        repeat: true
        running: true
        onTriggered: refreshAll()
    }

    function refreshScanSoon() {
        delayedRefresh.restart();
    }

    Timer {
        id: delayedRefresh
        interval: 250
        repeat: false
        onTriggered: refreshAll()
    }

    property bool bannerVisible: false
    property string bannerText: ""

    function showBanner(text) {
        bannerText = text;
        bannerVisible = true;
        bannerHide.restart();
    }

    Timer {
        id: bannerHide
        interval: 3500
        repeat: false
        onTriggered: bannerVisible = false
    }

    function rebuildInstances() {
        const registry = Logic.getRegistry(plasmoid);
        if (!registry._numbers) registry._numbers = {};

        const liveKeys = {};
        const pendingInstances = [];

        for (const process of scanned) {
            if (!process || process.exe !== "scrcpy") continue;

            const serial = Logic.extractSerialFromCmdline(process.cmdline);
            const flags = Logic.extractFlagsFromCmdline(process.cmdline);
            const connType = Logic.inferConnTypeFromSerial(serial);
            const key = Logic.instanceKey(process);

            const stored = registry[key];
            const isInternal = stored
                && stored.origin === "internal"
                && stored.uid === process.uid
                && stored.startticks === process.startticks
                && stored.cmdhash === process.cmdhash;
            const logPath = isInternal && stored.logfile ? String(stored.logfile) : "";

            liveKeys[key] = true;
            pendingInstances.push({
                key,
                pid: process.pid,
                uid: process.uid,
                startticks: process.startticks,
                cmdhash: process.cmdhash,
                cmdline: process.cmdline,
                serial,
                connType,
                flags,
                outside: !isInternal,
                logPath,
                logAvailable: logPath.length > 0
            });
        }

        for (const key in registry) {
            if (key === "_numbers") continue;
            if (!liveKeys[key]) delete registry[key];
        }
        for (const key in registry._numbers) {
            if (!liveKeys[key]) delete registry._numbers[key];
        }

        const instances = pendingInstances.map(instance => ({
            key: instance.key,
            pid: instance.pid,
            uid: instance.uid,
            startticks: instance.startticks,
            cmdhash: instance.cmdhash,
            cmdline: instance.cmdline,
            serial: instance.serial,
            connType: instance.connType,
            flags: instance.flags,
            outside: instance.outside,
            logPath: instance.logPath,
            logAvailable: instance.logAvailable,
            displayName: Logic.getDisplayNameIn(registry, plasmoid, instance.key, instance.outside, i18n)
        }));

        Logic.setRegistry(plasmoid, registry);

        instancesByDevice = Logic.groupInstancesByDevice(instances, transportAliases);
    }

    function rebuildDeviceCards() {
        const cards = Logic.buildDevicesFromAdb(adbDevices, transportAliases).map(device => ({
            deviceId: device.id,
            title: device.title,
            icon: device.icon,
            state: device.state,
            transports: device.transports,
            preferredSerial: preferredTransportForDevice(device.id, device.transports),
            isUnknown: false
        }));

        const unknown = instancesByDevice["__UNKNOWN__"] || [];
        if (unknown.length > 0) {
            cards.push({
                deviceId: "__UNKNOWN__",
                title: i18n("Unknown"),
                icon: "dialog-question",
                state: "unknown",
                transports: [],
                preferredSerial: "",
                isUnknown: true
            });
        }
        deviceCards = cards;
    }

    function preferredTransportForDevice(deviceId, transports) {
        const online = (transports || []).filter(transport => transport && transport.state === "device");
        if (!online.length) return "";
        const preferred = String(preferredTransports[deviceId] || "");
        if (online.some(transport => transport.serial === preferred)) return preferred;
        return online[0].serial;
    }

    function filteredInstancesForDevice(deviceId) {
        const query = String(searchQuery || "").trim().toLowerCase();
        const list = (instancesByDevice[deviceId] || []).map(instance => instance);
        if (!query.length) return list;

        return list.filter(instance =>
            String(instance.displayName || "").toLowerCase().includes(query)
            || String(instance.serial || "").toLowerCase().includes(query)
            || String(instance.connType || "").toLowerCase().includes(query)
            || String(instance.pid || "").toLowerCase().includes(query)
            || String((instance.flags || []).join(" ")).toLowerCase().includes(query)
        );
    }

    function setExpanded(deviceId, expanded) {
        expandedMap[deviceId] = !!expanded;
        expandedMap = Object.assign({}, expandedMap);
        saveUiState();
    }

    function setCreateOpen(deviceId, opened) {
        createOpenMap[deviceId] = !!opened;
        createOpenMap = Object.assign({}, createOpenMap);
        saveUiState();
    }

    function killInstance(pid, key) {
        exec.run("bash " + shQuote(scriptPath()) + " stop " + shQuote(pid), "stop", { key: key });
    }

    function renameInstance(key, newName) {
        Logic.setCustomName(plasmoid, key, newName);
        rebuildInstances();
        rebuildDeviceCards();
    }

    function saveDefaultsForDevice(deviceId, flagsObj) {
        Logic.setDeviceDefaultFlags(plasmoid, deviceId, flagsObj);
        showBanner(i18n("Saved device defaults."));
    }

    function createInstance(serial, name, args) {
        let command = "bash " + shQuote(scriptPath()) + " start " + shQuote(serial);
        for (let i = 0; i < (args || []).length; i++) command += " " + shQuote(args[i]);

        exec.run(command, "start", { name: name || "" });
        showBanner(i18n("Starting scrcpy..."));
    }

    function resolveUnknownWifiIdentities() {
        for (const device of (adbDevices || [])) {
            if (!device || device.state !== "device") continue;
            if (Logic.inferConnTypeFromSerial(device.serial) !== "wifi") continue;
            if (Logic.stableIdFromMdnsSerial(device.serial).length) continue;
            if (pendingIdentitySerials[device.serial] || identityCheckedSerials[device.serial]) continue;

            pendingIdentitySerials[device.serial] = true;
            pendingIdentitySerials = Object.assign({}, pendingIdentitySerials);
            exec.run(
                "bash " + shQuote(scriptPath()) + " identity " + shQuote(device.serial),
                "identity",
                { serial: device.serial }
            );
        }
    }

    function openWifiPage() {
        pageMode = "wifi";
    }

    function setWifiStatus(kind, message, details) {
        wifiStatusKind = kind;
        wifiStatusText = message || "";
        wifiDetailsText = details || "";
    }

    function startWifiOperation(kind, command, progressMessage, extraContext) {
        wifiBusy = true;
        wifiOperationToken = makeTag("wifi_operation");
        setWifiStatus("information", progressMessage, "");
        wifiOperationTimeout.restart();
        const context = Object.assign({}, extraContext || ({}), { token: wifiOperationToken });
        exec.run(command, kind, context);
    }

    function pairWirelessDevice(endpointValue, pairingCodeValue) {
        const parsed = Logic.parseEndpoint(endpointValue);
        const pairingCode = String(pairingCodeValue || "").trim();
        if (!parsed.ok) {
            setWifiStatus("error", i18n("Enter the pairing address as host:port."), "");
            return;
        }
        if (!/^[0-9]{6}$/.test(pairingCode)) {
            setWifiStatus("error", i18n("The pairing code must contain six digits."), "");
            return;
        }

        const command = "bash " + shQuote(scriptPath()) + " pair "
            + shQuote(parsed.endpoint) + " " + shQuote(pairingCode);
        startWifiOperation("wifi_pair", command, i18n("Pairing with %1...", parsed.endpoint));
    }

    function setupWifiViaUsb(serialValue, portValue) {
        const serial = String(serialValue || "");
        if (!serial.length) {
            setWifiStatus("error", i18n("Connect and select an authorized USB device first."), "");
            return;
        }
        const port = String(portValue || "").trim();
        if (!Logic.isValidPort(port)) {
            setWifiStatus("error", i18n("The port must be from 1 to 65535."), "");
            return;
        }

        const command = "bash " + shQuote(scriptPath()) + " legacy-setup "
            + shQuote(serial) + " " + shQuote(port);
        startWifiOperation(
            "wifi_legacy",
            command,
            i18n("Detecting the address and enabling wireless ADB..."),
            { sourceSerial: serial }
        );
    }

    function connectManualEndpoint(endpointValue) {
        const parsed = Logic.parseEndpoint(endpointValue);
        if (!parsed.ok) {
            setWifiStatus("error", i18n("Enter the connection address as host:port."), "");
            return;
        }

        startWifiOperation(
            "wifi_connect",
            "bash " + shQuote(scriptPath()) + " connect " + shQuote(parsed.endpoint),
            i18n("Connecting to %1...", parsed.endpoint)
        );
    }

    function disconnectWifiDevice(serialValue) {
        const serial = String(serialValue || "");
        if (!serial.length) {
            setWifiStatus("error", i18n("No connected wireless device is selected."), "");
            return;
        }
        startWifiOperation(
            "wifi_disconnect",
            "bash " + shQuote(scriptPath()) + " disconnect " + shQuote(serial),
            i18n("Disconnecting %1...", serial)
        );
    }

    function returnDeviceToUsbMode(serialValue) {
        const serial = String(serialValue || "");
        if (!serial.length) {
            setWifiStatus("error", i18n("No connected wireless device is selected."), "");
            return;
        }
        startWifiOperation(
            "wifi_usb",
            "bash " + shQuote(scriptPath()) + " usb " + shQuote(serial),
            i18n("Restarting ADB in USB mode...")
        );
    }

    function wifiResultMessage(kind, result) {
        if (result.ok) {
            if (kind === "wifi_pair") {
                return i18n("Pairing succeeded. The device should connect automatically; use Manual connection if it does not appear.");
            }
            if (kind === "wifi_legacy" || kind === "wifi_connect") {
                return i18n("Connected to %1 over Wi-Fi.", result.endpoint || result.serial);
            }
            if (kind === "wifi_disconnect") return i18n("Wireless device disconnected.");
            if (kind === "wifi_usb") return i18n("ADB restarted in USB mode. Keep the cable connected.");
            return i18n("Operation completed.");
        }

        const messages = {
            invalid_endpoint: i18n("The address or port is invalid."),
            invalid_pairing_code: i18n("The pairing code must contain six digits."),
            device_unavailable: i18n("The selected device is no longer online or authorized."),
            ip_not_found: i18n("No active Wi-Fi IPv4 address was found on the phone."),
            tcpip_failed: i18n("Could not enable wireless ADB on the phone."),
            pair_failed: i18n("Pairing failed. Check the address and request a new code."),
            connect_failed: i18n("ADB could not connect to the device."),
            verification_failed: i18n("ADB answered, but the device did not become available."),
            timeout: i18n("The ADB operation timed out."),
            disconnect_failed: i18n("Could not disconnect the wireless device."),
            usb_mode_failed: i18n("Could not return ADB to USB mode."),
            command_failed: i18n("The ADB operation failed."),
            unknown_result: i18n("ADB returned an unexpected result.")
        };
        return messages[result.code] || i18n("The ADB operation failed.");
    }

    function handleWifiResult(kind, result, context) {
        if (!context || context.token !== wifiOperationToken) return;
        wifiOperationTimeout.stop();
        wifiOperationToken = "";
        wifiBusy = false;

        if (result.ok && result.serial.length && result.stableId.length) {
            storeTransportAlias(result.serial, result.stableId);
            if (kind === "wifi_legacy" && context.sourceSerial) {
                storeTransportAlias(String(context.sourceSerial), result.stableId);
            }
        }

        const message = wifiResultMessage(kind, result);
        setWifiStatus(result.ok ? "positive" : "error", message, result.detail);
        showBanner(message);
        refreshScanSoon();
    }

    function openHelpPage() {
        showOutput(i18n("scrcpy Help"), i18n("Loading help..."), true);
        exec.run("bash " + root.shQuote(root.scriptPath()) + " help", "help", ({}));
    }

    function openLogPage(title, logPath, available) {
        if (!available || !logPath || !String(logPath).length) {
            showBanner(i18n("Logs are unavailable for this instance."));
            return;
        }

        showOutput(title || i18n("Instance logs"), i18n("Loading logs..."), true);
        exec.run(
            "bash " + root.shQuote(root.scriptPath()) + " logread " + root.shQuote(logPath) + " 500",
            "log",
            { title: title || i18n("Instance logs") }
        );
    }

    Timer {
        id: wifiOperationTimeout
        interval: 70000
        repeat: false
        onTriggered: {
            if (!root.wifiBusy) return;
            root.wifiOperationToken = "";
            root.wifiBusy = false;
            root.setWifiStatus("error", i18n("The ADB operation timed out."), i18n("The command may still finish in the background. Refresh the device list before trying again."));
        }
    }

    Component.onCompleted: {
        loadUiState();
        refreshAll();
    }

    fullRepresentation: PlasmaExtras.Representation {
        id: full

        collapseMarginsHint: true
        implicitWidth: Kirigami.Units.gridUnit * 32
        implicitHeight: Kirigami.Units.gridUnit * 26
        Layout.minimumWidth: Kirigami.Units.gridUnit * 30
        Layout.minimumHeight: Kirigami.Units.gridUnit * 24
        Layout.preferredWidth: Kirigami.Units.gridUnit * 32
        Layout.preferredHeight: Kirigami.Units.gridUnit * 26

        header: PlasmaExtras.PlasmoidHeading {
            contentItem: RowLayout {
                Layout.fillWidth: true

                PlasmaComponents3.ToolButton {
                    visible: root.pageMode !== "main"
                    icon.name: "go-previous"
                    Accessible.name: i18n("Back")
                    onClicked: root.pageMode = "main"
                    PlasmaComponents3.ToolTip { text: i18n("Back") }
                }

                PlasmaComponents3.Label {
                    visible: root.pageMode !== "main"
                    text: root.headerTitle
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                PlasmaComponents3.TextField {
                    visible: root.pageMode === "main"
                    Layout.fillWidth: true
                    placeholderText: i18n("Search devices and instances")
                    text: root.searchQuery
                    onTextChanged: root.searchQuery = text
                }

                PlasmaComponents3.ToolButton {
                    visible: root.pageMode === "main"
                    icon.name: "network-wireless"
                    Accessible.name: i18n("Connect a device")
                    onClicked: root.openWifiPage()
                    PlasmaComponents3.ToolTip { text: i18n("Pair or connect a wireless ADB device") }
                }

                PlasmaComponents3.ToolButton {
                    visible: root.pageMode === "main"
                    icon.name: "view-refresh"
                    Accessible.name: i18n("Refresh")
                    onClicked: root.refreshAll()
                    PlasmaComponents3.ToolTip { text: i18n("Refresh devices and instances") }
                }

                PlasmaComponents3.ToolButton {
                    visible: root.pageMode === "main"
                    icon.name: root.helpIconName
                    Accessible.name: i18n("Help")
                    onClicked: root.openHelpPage()
                    PlasmaComponents3.ToolTip { text: i18n("Show scrcpy help") }
                }

            }
        }

        contentItem: ColumnLayout {
            implicitWidth: Kirigami.Units.gridUnit * 30
            implicitHeight: Kirigami.Units.gridUnit * 22
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Frame {
                visible: bannerVisible
                Layout.fillWidth: true
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Label {
                        text: bannerText
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.9
                    }

                    PlasmaComponents3.ToolButton {
                        icon.name: "window-close"
                        onClicked: bannerVisible = false
                        PlasmaComponents3.ToolTip { text: i18n("Close") }
                    }
                }
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: {
                    if (root.pageMode === "wifi") return 1;
                    if (root.pageMode === "output") return 2;
                    return 0;
                }

                // Main device/instance overview.
                ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Frame {
                        visible: !depsOk
                        Layout.fillWidth: true
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label { text: i18n("Missing dependencies") }
                            PlasmaComponents3.Label {
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                                text: i18n("Please install: adb + scrcpy + coreutils")
                            }
                        }
                    }

                    PlasmaComponents3.ScrollView {
                        visible: depsOk
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

                        contentItem: ListView {
                            id: listView

                            width: parent ? parent.width : implicitWidth
                            height: parent ? parent.height : implicitHeight
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            spacing: Kirigami.Units.smallSpacing
                            topMargin: Kirigami.Units.smallSpacing * 2
                            bottomMargin: Kirigami.Units.smallSpacing * 2
                            leftMargin: Kirigami.Units.smallSpacing * 2
                            rightMargin: Kirigami.Units.smallSpacing * 2
                            currentIndex: -1
                            focus: false
                            activeFocusOnTab: false

                            model: root.filteredDeviceCards

                            delegate: DeviceCard {
                                width: Math.max(0, listView.width - listView.leftMargin - listView.rightMargin)

                                deviceId: modelData.deviceId
                                titleText: modelData.title
                                iconName: modelData.icon
                                deviceState: modelData.state
                                transports: modelData.transports
                                preferredSerial: modelData.preferredSerial
                                isUnknown: modelData.isUnknown

                                expandedWanted: !!root.expandedMap[deviceId]
                                createOpenWanted: !!root.createOpenMap[deviceId]

                                deviceDefaults: Logic.getDeviceDefaultFlags(plasmoid, deviceId)
                                instances: root.filteredInstancesForDevice(deviceId)

                                onExpandedStateChanged: (device, expanded) => root.setExpanded(device, expanded)
                                onPreferredTransportChanged: (device, serial) => root.savePreferredTransport(device, serial)

                                onToggleCreateRequested: (device, open) => {
                                    root.setCreateOpen(device, open);
                                    if (open) root.setExpanded(device, true);
                                }

                                onRequestKill: (pid, key) => root.killInstance(pid, key)
                                onRequestRename: (key, newName) => root.renameInstance(key, newName)
                                onRequestShowLogs: (title, logPath, available) => root.openLogPage(title, logPath, available)

                                onRequestCreate: (serial, name, args) => {
                                    root.createInstance(serial, name, args);
                                    if (root.createOpenMap[deviceId]) root.setCreateOpen(deviceId, false);
                                }

                                onRequestSaveDefaults: (serial, flagsObj) => root.saveDefaultsForDevice(serial, flagsObj)
                            }
                        }
                    }
                }

                WifiConnectionPage {
                    adbDevices: root.adbDevices
                    operationBusy: root.wifiBusy
                    statusText: root.wifiStatusText
                    statusKind: root.wifiStatusKind
                    detailsText: root.wifiDetailsText

                    onPairRequested: (endpoint, code) => root.pairWirelessDevice(endpoint, code)
                    onLegacySetupRequested: (serial, port) => root.setupWifiViaUsb(serial, port)
                    onManualConnectRequested: endpoint => root.connectManualEndpoint(endpoint)
                    onDisconnectRequested: serial => root.disconnectWifiDevice(serial)
                    onUsbModeRequested: serial => root.returnDeviceToUsbMode(serial)
                }

                // Generic text output viewer for help/log content.
                PlasmaComponents3.Frame {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents3.Label {
                            visible: root.outputLoading
                            text: i18n("Loading...")
                        }

                        QQC2.ScrollView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true

                            QQC2.TextArea {
                                text: root.outputText
                                readOnly: true
                                wrapMode: Text.NoWrap
                                font.family: "monospace"
                                selectByMouse: true
                                persistentSelection: true
                            }
                        }
                    }
                }

            }
        }
    }
}
