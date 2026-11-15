# PartyBox Wake for Mac

Wake a JBL PartyBox from standby or send it a power-off request using your Mac’s built-in Bluetooth. The tool opens a Bluetooth Low Energy (BLE) connection to the speaker you select and sends the selected power request. You can run it while the Mac is disconnected from the speaker for audio. Add `--connect` to a wake command to reconnect for playback.

**Wake and power-off manually verified on the JBL PartyBox Encore 2** with an Apple silicon MacBook Pro. The speaker was plugged into the wall, its power button was dim white, and the wake was physically confirmed. Other PartyBox models and battery-only standby are unverified.

## Build

Open Terminal in the cloned repository and build the executable.

```sh
make
```

This compiles `build/partybox-wake` using Swift and Apple’s CoreBluetooth framework. The first build also copies the standard config beside the executable. You need a Mac with Bluetooth LE and a Swift 5.7 or newer compiler. If the compiler or `make` is missing, run `xcode-select --install`, finish the installation, and run `make` again.

## Choose a speaker

For a paired speaker, save its exact Bluetooth name once. Replace the example with the name shown in **System Settings → Bluetooth**. The speaker can be disconnected for audio.

```sh
./build/partybox-wake --save-name "My living room PartyBox"
./build/partybox-wake --connect
```

Using `--save-name` clears the previous default UUID and preserves wake history. You can also set just `default_name` in the local config and leave `default_uuid` blank. Existing configs with both fields continue to work. If you prefer to select an entry by UUID, use these steps.

1. With the speaker in standby and within Bluetooth range, scan from your Mac.

   ```sh
   ./build/partybox-wake --list
   ```

   Allow Bluetooth access if macOS asks. The 15-second scan lists nearby BLE devices with their names and UUIDs. Find your speaker by its advertised name, including any custom name you gave it.

2. Replace `YOUR-UUID` with the UUID beside your speaker and try it once.

   ```sh
   ./build/partybox-wake --id YOUR-UUID
   ```

   Check whether the speaker’s power light brightens or it plays its startup sound. A single PartyBox can appear under two UUIDs with the same name. During the Encore 2 test, only one entry woke the speaker. If the first entry connects and the speaker stays asleep, try the other entry for your speaker.

3. Save the UUID that worked.

   ```sh
   ./build/partybox-wake --save YOUR-UUID
   ```

   If your speaker has a distinctive Bluetooth name, you can also save that exact name. This helps when macOS shows a different UUID later. Replace both example values with the ones from your scan.

   ```sh
   ./build/partybox-wake --save YOUR-UUID "My living room PartyBox"
   ```

## Wake the default or the last speaker

```sh
./build/partybox-wake
```

With no arguments, the tool wakes the default set with `--save-name` or `--save`. To wake the last speaker that successfully responded, run this instead.

```sh
./build/partybox-wake --wake-last
```

For example, save speaker A with `--save`, then successfully wake speaker B with `--id`. Running the tool without arguments wakes A. Running it with `--wake-last` immediately after waking B targets B. A scan, a save, or a failed wake preserves the previous history. A fresh installation reports an empty history until its first successful wake.

Wake and power-off use the same Bluetooth LE selection. With a saved name, the tool scans for up to 15 seconds and uses the saved UUID as soon as it appears. At the end of the scan, it considers exact, case-sensitive name matches. If several entries share the name, the tool looks for the Mac’s paired audio address in their manufacturer data. It chooses a single address match, or prints the candidates if the match is ambiguous. A single exact name match works on its own. With only a UUID, the tool can also connect using macOS’s cached entry.

## Connect for audio after waking

Pair the PartyBox once in **System Settings → Bluetooth** while it is on. Once the speaker is in standby, use either command:

```sh
./build/partybox-wake --connect
./build/partybox-wake --wake-last --connect
```

The first uses the saved default and the second uses the last successfully woken speaker. You can also use `--id YOUR-UUID --connect` for a specific speaker. Either flag order works with `--wake-last`.

Plain wake sends only the power command. The Encore 2 can then reconnect to its last Bluetooth device on its own, even after you clicked **Disconnect** on the Mac. We observed the speaker return as an available Mac audio output about ten seconds after a plain wake. [JBL Encore 2 manual, §6.1](https://support.jbl.com/on/demandware.static/-/Sites-masterCatalog_Harman/default/dw7bcebe57/pdfs/JBL_PARTYBOX_Encore_2_OM_EN_V7.pdf)

With `--connect`, the tool also checks whether the speaker is available for Mac audio. It identifies the paired device by the Classic Bluetooth address in the speaker’s settings, or by a unique exact name when the address is unavailable. If the output is missing, the tool requests a reconnect when possible and checks for the output, asking macOS to connect if needed. The command succeeds once the speaker is available. macOS controls the selected playback output. You can choose the PartyBox in **Sound → Output**.

If the wake succeeds but the audio connection fails, the command returns exit code `3` and retains the successful wake in history. For a manual test, start with the speaker asleep and disconnected for audio, run the first command, then check **Sound → Output** and play a short clip through the speaker. Put it back in standby, disconnect it for audio, and repeat with the second command.

## Turn off a speaker

With the speaker on, run the command for your intended target.

| Command | Target |
| --- | --- |
| `./build/partybox-wake --off` | Configured default speaker |
| `./build/partybox-wake --off-last` | Last successfully woken speaker |
| `./build/partybox-wake --off --id YOUR-UUID` | The Bluetooth entry you specify |

Power-off preserves wake history. Only `--off` targeting the default speaker can refresh `default_uuid` when automatic updates are enabled. Exit code `0` means the speaker acknowledged the power-off request. If it disconnects before acknowledging, the tool reports an unconfirmed result (exit code `2`). Check the power button on the Encore 2: dim white indicates standby and unlit indicates power off.

## Configuration and build files

The repository root contains the standard `partybox-wake.config` template. The first `make` copies it into `build/`. Later builds preserve that local copy. Git ignores the entire `build/` directory, including the executable, local config, and lock file. To personalize this Mac, edit **`build/partybox-wake.config`** or use `--save-name` or `--save`.

The file uses UTF-8 text with one `key=value` pair per line. Blank lines and lines beginning with `#` are allowed. Enter names literally, including any spaces, without surrounding quotes.

```ini
default_uuid=
default_name=
autoupdate_uuid=false
last_wake_uuid=
last_wake_name=
```

| Key | Used for |
| --- | --- |
| `default_uuid` | Optional default device UUID from `--list` on this Mac. Set it with `--save UUID`. |
| `default_name` | Exact Bluetooth name for name-based discovery, optional when a UUID is saved. |
| `autoupdate_uuid` | Set to `true` to save a replacement UUID when a scan finds the default speaker by name. Defaults to `false` when omitted. |
| `last_wake_uuid` | The actual connected UUID from the most recent successful wake, including an entry selected by name or paired address. |
| `last_wake_name` | The Bluetooth name for that speaker when available, used as a fallback by `--wake-last`. |

To enable automatic updates on an existing installation, add `autoupdate_uuid=true` to `build/partybox-wake.config` or change the existing setting. On a default wake, `--connect`, or `--off`, the saved UUID takes priority. When the UUID is blank or absent for the full scan, the tool saves the selected UUID before connecting, even if the subsequent power request fails. With the setting off, it uses that match for the current run only. Unresolved matches leave the config untouched and the command prints their UUIDs. Commands targeting the last speaker or an explicit UUID keep the default selection intact.

A successful wake for history purposes means the speaker acknowledged the power command, or the Bluetooth write succeeded and the speaker returned settings during the request. The Encore 2 showed the latter behavior in a physically confirmed wake test. Check its power light when testing a new speaker. The local config must be writable to record history.

When upgrading from the earlier layout, the first build imports the UUID and optional name from a root `config.txt` as the default. The first successful wake populates the history.

## Troubleshooting

- **Speaker missing from the scan.** Check that Bluetooth is on, the speaker is within range, and it is in the same standby state used for setup. On the tested Encore 2, the power button glowed dim white. If macOS denied access, check **System Settings → Privacy & Security → Bluetooth** for the tool or the terminal app that launched it.
- **Saved connection times out.** Run `--list` again on this Mac. Try the currently visible UUID for your speaker with `--id`, then save it if it wakes the unit.
- **The write succeeds but the speaker stays asleep.** Bluetooth can accept the write while the speaker remains in standby. Check for another entry with the same speaker name. An absent JBL control service or write characteristic means that entry cannot receive this command through the tested protocol.
- **Using the tool in a script.** For a wake attempt, exit code `0` means the speaker acknowledged the command or returned settings after the write was accepted. The Encore 2 returned settings during the confirmed wake. Code `1` indicates a setup, connection, or transport failure. Code `2` indicates a rejected request or insufficient reply evidence. Invalid command-line arguments return `64`.

## Protocol

The tool discovers the JBL control service, subscribes to replies when available, and writes `AA 03 01 05` for wake or `AA 03 01 04` for power off to characteristic `65786365-6C70-6F69-6E74-2E636F6D0002`. It uses a Bluetooth write with response and waits up to ten seconds for JBL replies.

## References

- The paired-address match comes from observing the Encore 2 on a Mac. One of two same-name BLE entries included the paired audio address in manufacturer data with company ID `0x0ECB`. Other models may advertise differently.
- The control service, write and notify characteristics, four-byte power command, and JBL reply format came from the PartyBox 520 protocol findings. [partybox-companion findings](https://github.com/jklingberg/partybox-companion/blob/main/docs/reverse-engineering/discoveries.md)
- The initial BLE wake experiment was informed by independent tests on the PartyBox 710. The Encore 2 procedure above comes from testing on the Encore 2 itself. [PartyPair protocol notes](https://github.com/louim-lbs/PartyPair/blob/main/docs/PROTOCOL.md#5-waking-a-speaker)
- The macOS implementation uses Apple’s BLE central workflow for discovering devices, connecting, finding characteristics, and subscribing to replies. [Apple Core Bluetooth Programming Guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonCentralRoleTasks/PerformingCommonCentralRoleTasks.html)
- JBL documents the dim white standby indicator and Bluetooth reactivation from networked standby in the speaker’s owner’s manual. [JBL PartyBox Encore 2 manual, sections 3.1 and 11](https://support.jbl.com/on/demandware.static/-/Sites-masterCatalog_Harman/default/dw7bcebe57/pdfs/JBL_PARTYBOX_Encore_2_OM_EN_V7.pdf)
- The speaker-initiated audio reconnect uses the Mac’s Classic Bluetooth address. macOS can also initiate the link to the paired speaker. [PartyPair audio reconnect command](https://github.com/louim-lbs/PartyPair/blob/main/docs/PROTOCOL.md#7-other-useful-commands) · [Apple IOBluetooth connection](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openconnection())

## License

PartyBox Wake for Mac is available under the [MIT License](LICENSE).
