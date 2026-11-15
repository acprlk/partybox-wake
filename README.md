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

With no arguments, the tool wakes the default set with `--save`. To wake the last speaker that successfully responded, run this instead.

```sh
./build/partybox-wake --wake-last
```

For example, save speaker A with `--save`, then successfully wake speaker B with `--id`. Running the tool without arguments wakes A. Running it with `--wake-last` immediately after waking B targets B. A scan, a save, or a failed wake preserves the previous history. A fresh installation reports an empty history until its first successful wake.

The tool reads your selection, connects, sends one wake request, and disconnects. With a name configured, it scans for the saved UUID first. If that UUID is absent after 15 seconds, it connects to a single exact name match. If several entries match the name, it prints their UUIDs so you can test the right one. You can also invoke the executable by its full path from another directory.

## Connect for audio after waking

Pair the PartyBox once in **System Settings → Bluetooth** while it is on. Once the speaker is in standby, use either command:

```sh
./build/partybox-wake --connect
./build/partybox-wake --wake-last --connect
```

The first uses the saved default and the second uses the last successfully woken speaker. You can also use `--id YOUR-UUID --connect` for a specific speaker. Either flag order works with `--wake-last`.

After the speaker replies to the wake request, the tool asks it to reconnect to this Mac and, if needed, initiates the paired Bluetooth connection from macOS. It matches the paired device by the Classic Bluetooth address from the speaker’s settings when available, or by a unique exact Bluetooth name. The command succeeds once macOS lists the speaker as a Bluetooth sound output. If macOS keeps another output selected, choose the PartyBox in **Sound → Output** for playback.

If the wake succeeds but the audio connection fails, the command returns exit code `3` and retains the successful wake in history. For a manual test, start with the speaker asleep and disconnected for audio, run the first command, then check **Sound → Output** and play a short clip through the speaker. Put it back in standby, disconnect it for audio, and repeat with the second command.

## Turn off a speaker

With the speaker on, run the command for your intended target.

| Command | Target |
| --- | --- |
| `./build/partybox-wake --off` | Configured default speaker |
| `./build/partybox-wake --off-last` | Last successfully woken speaker |
| `./build/partybox-wake --off --id YOUR-UUID` | The Bluetooth entry you specify |

Power-off preserves the saved default and wake history. Exit code `0` means the speaker acknowledged the power-off request. If it disconnects before acknowledging, the tool reports an unconfirmed result (exit code `2`). Check the power button on the Encore 2: dim white indicates standby and unlit indicates power off.

## Configuration and build files

The repository root contains the standard `partybox-wake.config` template. The first `make` copies it into `build/`. Later builds preserve that local copy. Git ignores the entire `build/` directory, including the executable, local config, and lock file. To personalize this Mac, edit **`build/partybox-wake.config`** or use `--save`.

The file uses UTF-8 text with one `key=value` pair per line. Blank lines and lines beginning with `#` are allowed. Enter names literally, including any spaces, without surrounding quotes.

```ini
default_uuid=
default_name=
last_wake_uuid=
last_wake_name=
```

| Key | Used for |
| --- | --- |
| `default_uuid` | The default device UUID from `--list` on this Mac. Set it with `--save UUID`. |
| `default_name` | Optional exact Bluetooth name for the default speaker if its UUID changes. |
| `last_wake_uuid` | The actual connected UUID from the most recent successful wake, including a connection found by name. |
| `last_wake_name` | The Bluetooth name for that speaker when available, used as a fallback by `--wake-last`. |

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

- The control service, write and notify characteristics, four-byte power command, and JBL reply format came from the PartyBox 520 protocol findings. [partybox-companion findings](https://github.com/jklingberg/partybox-companion/blob/main/docs/reverse-engineering/discoveries.md)
- The initial BLE wake experiment was informed by independent tests on the PartyBox 710. The Encore 2 procedure above comes from testing on the Encore 2 itself. [PartyPair protocol notes](https://github.com/louim-lbs/PartyPair/blob/main/docs/PROTOCOL.md#5-waking-a-speaker)
- The macOS implementation uses Apple’s BLE central workflow for discovering devices, connecting, finding characteristics, and subscribing to replies. [Apple Core Bluetooth Programming Guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/PerformingCommonCentralRoleTasks/PerformingCommonCentralRoleTasks.html)
- JBL documents the dim white standby indicator and Bluetooth reactivation from networked standby in the speaker’s owner’s manual. [JBL PartyBox Encore 2 manual, sections 3.1 and 11](https://support.jbl.com/on/demandware.static/-/Sites-masterCatalog_Harman/default/dw7bcebe57/pdfs/JBL_PARTYBOX_Encore_2_OM_EN_V7.pdf)
- The speaker-initiated audio reconnect uses the Mac’s Classic Bluetooth address. macOS can also initiate the link to the paired speaker. [PartyPair audio reconnect command](https://github.com/louim-lbs/PartyPair/blob/main/docs/PROTOCOL.md#7-other-useful-commands) · [Apple IOBluetooth connection](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openconnection())
