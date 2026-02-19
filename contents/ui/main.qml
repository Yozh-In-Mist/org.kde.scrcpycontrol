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

    property var pendingCreate: ({})
    property var pendingLogRequestMap: ({})

    // Active page identifier for the stacked content area.
    property string pageMode: "main"

    property string outputTitle: ""
    property string outputText: ""
    property bool outputLoading: false
    property string searchQuery: ""

    property string wifiUsbSerial: ""
    property string wifiTcpPort: "5555"
    property string wifiHost: ""
    property string wifiConnectPort: "5555"
    property string wifiStatusText: ""
    property bool wifiBusy: false

    readonly property int runningCount: {
        let count = 0;
        for (const key in instancesByDevice) count += (instancesByDevice[key] || []).length;
        return count;
    }

    readonly property bool hasDevices: adbDevices && adbDevices.length > 0
    readonly property int pollIntervalMs: Plasmoid.expanded ? 1500 : 5000

    readonly property string baseIconName: {
        if (!depsOk) return "dialog-error";
        if (hasDevices) return "smartphoneconnected";
        return "smartphonedisconnected";
    }

    readonly property string headerTitle: {
        if (pageMode === "wifi") return i18n("ADB over Wi-Fi");
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
        if (!hasDevices) return i18n("No devices detected");
        if (runningCount === 0) return i18n("No running instances.");
        return i18n("%1 instance(s) running", runningCount);
    }

    Plasmoid.icon: baseIconName
    Plasmoid.status: depsOk ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.NeedsAttentionStatus

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

    // Build unique async tags for start/log commands.
    function makeTag(prefix, payload) {
        const suffix = Date.now().toString() + "::" + Math.floor(Math.random() * 1000000).toString();
        if (payload && String(payload).length) return prefix + "::" + String(payload) + "::" + suffix;
        return prefix + "::" + suffix;
    }

    function loadUiState() {
        expandedMap = Logic.safeJsonParse(plasmoid.configuration.expandedDevicesJson, {});
        createOpenMap = Logic.safeJsonParse(plasmoid.configuration.createOpenDevicesJson, {});
    }

    function saveUiState() {
        plasmoid.configuration.expandedDevicesJson = Logic.safeJsonStringify(expandedMap, "{}");
        plasmoid.configuration.createOpenDevicesJson = Logic.safeJsonStringify(createOpenMap, "{}");
    }

    Plasma5Support.DataSource {
        id: exec

        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            const out = (data["stdout"] || "").toString();
            const err = (data["stderr"] || "").toString();
            const tag = (sourceName.split("##TAG=")[1] || "");
            handle(tag, out, err);
            exec.disconnectSource(sourceName);
        }

        function run(command, tag) {
            connectSource("sh -lc " + root.shQuote(command) + " ##TAG=" + tag);
        }
    }

    function refreshDevicesAndInstances() {
        exec.run("adb devices -l", "adb");
        exec.run("bash " + shQuote(scriptPath()) + " scan", "scan");
    }

    function showOutput(title, text, loading) {
        outputTitle = title || i18n("Output");
        outputText = text || "";
        outputLoading = !!loading;
        pageMode = "output";
    }

    function handle(tag, out, err) {
        if (tag === "deps") {
            const adbAvailable = out.includes("adb=OK");
            const scrcpyAvailable = out.includes("scrcpy=OK");
            depsOk = adbAvailable && scrcpyAvailable;

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

        if (tag === "adb") {
            adbDevices = Logic.parseAdbDevicesList(out);
            const candidates = getUsbSetupCandidates();
            if (!wifiUsbSerial.length && candidates.length) wifiUsbSerial = candidates[0].serial;
            rebuildDeviceCards();
            return;
        }

        if (tag === "scan") {
            scanned = Logic.parseScanOutput(out);
            rebuildInstances();
            rebuildDeviceCards();
            return;
        }

        if (tag.startsWith("start::")) {
            const kv = Logic.parseKvOutput(out);
            if (kv.pid && kv.uid && kv.startticks && kv.cmdhash) {
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

                const name = (pendingCreate[tag] || "").trim();
                if (name.length) Logic.setCustomName(plasmoid, key, name);

                delete pendingCreate[tag];
                pendingCreate = Object.assign({}, pendingCreate);
            }
            refreshScanSoon();
            return;
        }

        if (tag.startsWith("stop::")) {
            refreshScanSoon();
            return;
        }

        if (tag === "adb_connect") {
            wifiBusy = false;
            const message = bestMessage(out, err, i18n("ADB connect finished."));
            wifiStatusText = message;
            showBanner(message);
            refreshScanSoon();
            return;
        }

        if (tag === "adb_tcpip") {
            wifiBusy = false;
            const message = bestMessage(out, err, i18n("TCP/IP mode updated."));
            wifiStatusText = message;
            showBanner(message);
            return;
        }

        if (tag === "adb_deviceip") {
            wifiBusy = false;
            const kv = Logic.parseKvOutput(out);
            if (kv.ip && String(kv.ip).trim().length) {
                wifiHost = String(kv.ip).trim();
                wifiStatusText = i18n("Detected device IP: %1", wifiHost);
            } else {
                wifiStatusText = bestMessage(out, err, i18n("Could not detect device IP."));
            }
            return;
        }

        if (tag === "help") {
            showOutput(i18n("scrcpy Help"), bestMessage(out, err, i18n("No help output available.")), false);
            return;
        }

        if (tag.startsWith("log::")) {
            const title = pendingLogRequestMap[tag] || i18n("Instance logs");
            delete pendingLogRequestMap[tag];
            pendingLogRequestMap = Object.assign({}, pendingLogRequestMap);
            showOutput(title, bestMessage(out, err, i18n("No log output available.")), false);
            return;
        }
    }

    function refreshAll() {
        exec.run("bash " + shQuote(scriptPath()) + " deps", "deps");
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

        instancesByDevice = Logic.groupInstancesByDevice(instances);
    }

    function rebuildDeviceCards() {
        const cards = Logic.buildDevicesFromAdb(adbDevices).map(device => ({
            deviceId: device.id,
            title: device.title,
            icon: device.icon,
            isUnknown: false
        }));

        const unknown = instancesByDevice["__UNKNOWN__"] || [];
        if (unknown.length > 0) {
            cards.push({
                deviceId: "__UNKNOWN__",
                title: i18n("Unknown"),
                icon: "dialog-question",
                isUnknown: true
            });
        }
        deviceCards = cards;
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
        exec.run("bash " + shQuote(scriptPath()) + " stop " + shQuote(pid), "stop::" + key);
    }

    function renameInstance(key, newName) {
        Logic.setCustomName(plasmoid, key, newName);
        rebuildInstances();
        rebuildDeviceCards();
    }

    function saveDefaultsForDevice(serial, flagsObj) {
        Logic.setDeviceDefaultFlags(plasmoid, serial, flagsObj);
        showBanner(i18n("Saved device defaults."));
    }

    function createInstance(serial, name, args) {
        let command = "bash " + shQuote(scriptPath()) + " start " + shQuote(serial);
        for (let i = 0; i < (args || []).length; i++) command += " " + shQuote(args[i]);

        const tag = makeTag("start", serial);
        pendingCreate[tag] = (name || "");
        pendingCreate = Object.assign({}, pendingCreate);

        exec.run(command, tag);
        showBanner(i18n("Starting scrcpy..."));
    }

    function getUsbSetupCandidates() {
        return (adbDevices || []).filter(device =>
            device && device.state === "device" && Logic.inferConnTypeFromSerial(device.serial) !== "wifi");
    }

    function openWifiPage() {
        const candidates = getUsbSetupCandidates();
        if (!wifiUsbSerial.length && candidates.length) wifiUsbSerial = candidates[0].serial;
        if (!wifiTcpPort.length) wifiTcpPort = "5555";
        if (!wifiConnectPort.length) wifiConnectPort = "5555";
        pageMode = "wifi";
    }

    function enableTcpipMode() {
        if (!wifiUsbSerial.length) {
            wifiStatusText = i18n("Select a USB-connected device first.");
            return;
        }
        const port = wifiTcpPort.trim();
        if (!/^[0-9]+$/.test(port)) {
            wifiStatusText = i18n("Invalid TCP port.");
            return;
        }

        wifiBusy = true;
        wifiStatusText = i18n("Enabling TCP/IP mode...");
        exec.run("bash " + root.shQuote(root.scriptPath()) + " tcpip " + root.shQuote(wifiUsbSerial) + " " + root.shQuote(port), "adb_tcpip");
    }

    function detectDeviceIp() {
        if (!wifiUsbSerial.length) {
            wifiStatusText = i18n("Select a USB-connected device first.");
            return;
        }

        wifiBusy = true;
        wifiStatusText = i18n("Detecting device IP...");
        exec.run("bash " + root.shQuote(root.scriptPath()) + " deviceip " + root.shQuote(wifiUsbSerial), "adb_deviceip");
    }

    function connectWifiFromPage() {
        const host = wifiHost.trim();
        const port = wifiConnectPort.trim();
        const endpoint = host + ":" + port;

        if (!host.length) {
            wifiStatusText = i18n("Host/IP is required.");
            return;
        }
        if (!/^[0-9]+$/.test(port)) {
            wifiStatusText = i18n("Invalid connect port.");
            return;
        }
        if (!isValidEndpoint(endpoint)) {
            wifiStatusText = i18n("Invalid endpoint format.");
            return;
        }

        wifiBusy = true;
        wifiStatusText = i18n("Connecting to %1...", endpoint);
        exec.run("bash " + root.shQuote(root.scriptPath()) + " connect " + root.shQuote(endpoint), "adb_connect");
    }

    function openHelpPage() {
        showOutput(i18n("scrcpy Help"), i18n("Loading help..."), true);
        exec.run("bash " + root.shQuote(root.scriptPath()) + " help", "help");
    }

    function openLogPage(title, logPath, available) {
        if (!available || !logPath || !String(logPath).length) {
            showBanner(i18n("Logs are unavailable for this instance."));
            return;
        }

        const tag = makeTag("log");
        pendingLogRequestMap[tag] = title || i18n("Instance logs");
        pendingLogRequestMap = Object.assign({}, pendingLogRequestMap);

        showOutput(title || i18n("Instance logs"), i18n("Loading logs..."), true);
        exec.run("bash " + root.shQuote(root.scriptPath()) + " logread " + root.shQuote(logPath) + " 500", tag);
    }

    function isValidEndpoint(endpoint) {
        return /^\[[^\]]+\]:\d+$/.test(endpoint) || /^[A-Za-z0-9._-]+:\d+$/.test(endpoint);
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
                    Accessible.name: i18n("ADB over Wi-Fi")
                    onClicked: root.openWifiPage()
                    PlasmaComponents3.ToolTip { text: i18n("Open ADB over Wi-Fi setup") }
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
                                text: i18n("Please install: adb + scrcpy")
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
                                isUnknown: modelData.isUnknown

                                expandedWanted: !!root.expandedMap[deviceId]
                                createOpenWanted: !!root.createOpenMap[deviceId]

                                deviceDefaults: Logic.getDeviceDefaultFlags(plasmoid, deviceId)
                                instances: root.filteredInstancesForDevice(deviceId)

                                onExpandedStateChanged: (device, expanded) => root.setExpanded(device, expanded)

                                onToggleCreateRequested: (device, open) => {
                                    root.setCreateOpen(device, open);
                                    if (open) root.setExpanded(device, true);
                                }

                                onRequestKill: (pid, key) => root.killInstance(pid, key)
                                onRequestRename: (key, newName) => root.renameInstance(key, newName)
                                onRequestShowLogs: (title, logPath, available) => root.openLogPage(title, logPath, available)

                                onRequestCreate: (serial, name, args) => {
                                    root.createInstance(serial, name, args);
                                    if (root.createOpenMap[serial]) root.setCreateOpen(serial, false);
                                }

                                onRequestSaveDefaults: (serial, flagsObj) => root.saveDefaultsForDevice(serial, flagsObj)
                            }
                        }
                    }
                }

                // Guided ADB-over-TCP setup flow.
                ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents3.Frame {
                        Layout.fillWidth: true
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.smallSpacing
                            spacing: Kirigami.Units.smallSpacing

                            PlasmaComponents3.Label {
                                text: i18n("Instructions")
                                font.weight: Font.Medium
                            }

                            PlasmaComponents3.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: i18n("1. Connect the phone with USB and accept the ADB authorization prompt.\n2. Select the USB device, set the TCP port, then click Enable and Detect IP.\n3. Disconnect USB, enter Host/IP and Port, then click Connect.")
                                opacity: 0.85
                            }
                        }
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Step 1: Enable TCP/IP mode on a USB-connected device.")
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        readonly property var usbCandidates: root.getUsbSetupCandidates()

                        PlasmaComponents3.ComboBox {
                            Layout.fillWidth: true
                            model: usbCandidates.map(device => (device.model ? device.model + " " : "") + "(" + device.serial + ")")
                            enabled: model.length > 0 && !root.wifiBusy

                            onActivated: {
                                if (currentIndex >= 0 && currentIndex < usbCandidates.length) {
                                    root.wifiUsbSerial = usbCandidates[currentIndex].serial;
                                }
                            }

                            Component.onCompleted: {
                                if (!root.wifiUsbSerial.length && usbCandidates.length) root.wifiUsbSerial = usbCandidates[0].serial;
                                if (usbCandidates.length && root.wifiUsbSerial.length) {
                                    for (let i = 0; i < usbCandidates.length; i++) {
                                        if (usbCandidates[i].serial === root.wifiUsbSerial) {
                                            currentIndex = i;
                                            break;
                                        }
                                    }
                                }
                            }
                        }

                        PlasmaComponents3.TextField {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                            text: root.wifiTcpPort
                            placeholderText: i18n("Port")
                            enabled: !root.wifiBusy
                            onTextChanged: root.wifiTcpPort = text.replace(/[^0-9]/g, "")
                        }

                        PlasmaComponents3.Button {
                            text: i18n("Enable")
                            enabled: !root.wifiBusy
                            onClicked: root.enableTcpipMode()
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        PlasmaComponents3.Button {
                            text: i18n("Detect IP")
                            enabled: !root.wifiBusy
                            onClicked: root.detectDeviceIp()
                        }

                        Item { Layout.fillWidth: true }
                    }

                    PlasmaComponents3.Label {
                        text: i18n("Step 2: Connect via TCP.")
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        PlasmaComponents3.TextField {
                            Layout.fillWidth: true
                            text: root.wifiHost
                            placeholderText: i18n("Host / IP")
                            enabled: !root.wifiBusy
                            onTextChanged: root.wifiHost = text.trim()
                        }

                        PlasmaComponents3.TextField {
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                            text: root.wifiConnectPort
                            placeholderText: i18n("Port")
                            enabled: !root.wifiBusy
                            onTextChanged: root.wifiConnectPort = text.replace(/[^0-9]/g, "")
                        }

                        PlasmaComponents3.Button {
                            text: i18n("Connect")
                            enabled: !root.wifiBusy
                            onClicked: root.connectWifiFromPage()
                        }
                    }

                    PlasmaComponents3.Frame {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        QQC2.ScrollView {
                            anchors.fill: parent
                            clip: true

                            QQC2.TextArea {
                                text: root.wifiStatusText
                                readOnly: true
                                wrapMode: Text.WrapAnywhere
                                font.family: "monospace"
                                selectByMouse: true
                            }
                        }
                    }
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
