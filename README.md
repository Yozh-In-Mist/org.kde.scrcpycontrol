# scrcpy Control

A KDE Plasma 6 widget for starting and managing multiple scrcpy instances per Android device over USB or Wi-Fi.

## Features

- Lists authorized, unauthorized and offline ADB devices.
- Groups USB and Wi-Fi connections of the same phone into one device card.
- Starts multiple scrcpy instances with per-device defaults and reusable flag templates.
- Shows and terminates running scrcpy processes, including instances started outside the widget.
- Supports Android 11+ Wireless debugging pairing, USB-assisted legacy TCP/IP setup and manual ADB endpoints.

## Requirements

- KDE Plasma 6
- Bash
- `adb`
- `scrcpy`
- GNU coreutils (`base64`, `timeout`, `realpath` and `sha256sum`)

On Debian and derivatives, the runtime dependencies are normally available as the `adb` and `scrcpy` packages.

## Install

From the repository root:

```bash
kpackagetool6 --type Plasma/Applet --install .
```

Then add **scrcpy Control** through Plasma's **Add Widgets** interface. It can also be enabled in the System Tray settings under **Entries**. Restarting Plasma is not normally required.

To upgrade or remove a development installation:

```bash
kpackagetool6 --type Plasma/Applet --upgrade .
kpackagetool6 --type Plasma/Applet --remove org.kde.scrcpycontrol
```

## USB quick start

1. Enable Developer options and USB debugging on the phone.
2. Connect the phone and accept the ADB authorization prompt.
3. Open the widget, expand the device card and start a scrcpy instance.

An `unauthorized` or permission warning is shown in the device list instead of silently hiding the phone.

## Wi-Fi connection

Open **Connect a device** from the wireless button in the widget header.

### Wireless debugging — Android 11+

1. Put the computer and phone on the same network.
2. On Android, open **Developer options → Wireless debugging → Pair device with pairing code**.
3. In the widget, select **Wireless debugging (Android 11+)** and enter the displayed pairing address and six-digit code.
4. Android should expose the connection automatically after pairing. If the device does not appear, select **Manual connection** and enter the separate IP address and port shown on the main Wireless debugging screen.

The pairing port and connection port are often different. The pairing code is cleared from the widget immediately after the command starts and is not saved in its configuration.

### USB-assisted setup

Use this for older Android versions or as a fallback:

1. Connect and authorize the phone over USB, and keep the cable attached.
2. Select **Set up through USB** and the required phone.
3. Press **Set up Wi-Fi**. The widget detects the Wi-Fi address, enables ADB TCP/IP mode, connects to the endpoint and verifies that it is online.

Port `5555` is the default. Use a different port only when you know the device is configured for it.

### Disconnecting

The bottom section of the connection page can disconnect an active wireless transport. **Return to USB mode** restarts `adbd` in USB mode and requires the cable to remain connected.

Legacy ADB TCP/IP should only be used on a trusted network. Guest networks, client isolation, firewalls and VPN routing may prevent devices from reaching each other.

## Troubleshooting

- **Authorization required**: unlock the phone and accept the USB debugging fingerprint prompt.
- **No USB permissions**: install the appropriate Android udev rules and ensure your user has access to the device.
- **Offline**: reconnect the cable or toggle Wireless debugging, then refresh the widget.
- **Pairing succeeds but no device appears**: use the connection address from the main Wireless debugging screen, not the temporary pairing address.
- **IP address not found**: confirm that Wi-Fi is connected on the phone and retry; VPN and unusual Android network interfaces may require manual connection.
- **Connection times out**: verify that both devices are on the same LAN and that client/AP isolation is disabled.

Technical ADB output is available through **Show technical details** after each connection operation.

## Development and checks

Run the non-Plasma tests with:

```bash
bash tests/run.sh
```

For interactive development, load the widget with `plasmoidviewer -a .` or `plasmawindowed org.kde.scrcpycontrol` rather than repeatedly restarting the Plasma shell.

## License

GPL-3.0-or-later. Contributions and translations are welcome.
