# USB deployment and provisioning

Scripts for setting up the kiosk phones from a laptop over USB: pushing game
folders into RWA Player's Documents directory, and provisioning each phone's
operator settings (identity, GPS source, default game, ...) without touching the
Settings tab on the device.

| File | Role |
| --- | --- |
| `deploy_games.sh` | main entry point: discovers connected phones, pushes games and (with `-s`) per-phone settings |
| `deploy_games_afc.py` | helper for iOS 16 phones, driven by `deploy_games.sh` — not run directly |
| `provisioning.example.plist` | annotated template for the per-phone settings file |

## Prerequisites

- **Xcode 15+** — `xcrun devicectl` handles iOS 17+ phones.
- **pymobiledevice3** — only needed for iOS 16 phones, which are invisible to
  devicectl. Install once:

  ```sh
  brew install pipx && pipx install pymobiledevice3
  ```

- Phones must be **paired** with the laptop (trusted once via Finder/Xcode) and
  **unlocked** while deploying. `devicectl` mounts the developer disk image
  first, and a locked phone fails fails the procedure. The script detects this
  and tells you which phone to unlock.

## Deploying games

A *game folder* is a directory containing a `<name>.rwa` plus its `assets/`
folder (same layout as `rwaGames/rwatest`). Each game lands in
`Documents/<name>/` of `com.fhnw.rwa.player`, where `GameManager` picks it up
on the next Games-tab scan (relaunch the app after deploying).

```sh
./deploy_games.sh [-an] [-s <settings-plist>] <games-folder> [device ...]
```

- `<games-folder>`: either a single game folder, or a folder whose immediate
  subdirectories are game folders (all are deployed; subdirectories without a
  `.rwa` are skipped with a warning). It may be omitted for a settings-only
  run, see [Provisioning without deploying games](#provisioning-without-deploying-games).
- `[device ...]`: device names or UDIDs. Default: every paired USB-connected
  phone.
- `-a`: also target Wi-Fi-connected phones (iOS 17+ only; the iOS 16 path is
  always USB).
- `-n`: dry run: show what would be copied where, copy nothing.
- `-s <plist>`: push per-phone settings too, see
  [Provisioning settings](#provisioning-settings).

Before copying, each game is staged and cleaned: macOS junk (`.DS_Store`,
`._*`) and the Creator's working files (`tilecache/`, `tmp/`, `undo/`,
`layouts.ini`) are stripped so they never land on the device. Unmodified files
are skipped on re-deploys (`devicectl` natively; the iOS 16 path keeps a
`.deploy-manifest.json` per game on the device to emulate it).

Things that will bite you:

- **Deploys only add and overwrite; stale games are NOT removed.** To delete a
  game, use the Files app on the phone (On My iPhone -> RWA Player), Finder's
  file-sharing pane, or:

  ```sh
  pymobiledevice3 apps rm com.fhnw.rwa.player "Documents/<game>" --udid <udid>
  ```

- devicectl's `--remove-existing-content` flag is **not** a per-folder mirror:
  it wipes the *entire* app container before copying: all games, the app's settings in
  `Library/Preferences`, pending telemetry. Don't.
- The in-app "fetch new games" flow wipes Documents entirely before downloading.
  Don't mix it with USB deployment on the same phone.

## Provisioning settings

`deploy_games.sh -s <plist>` pushes each phone its own settings, so a batch of
kiosk units can be configured identically and repeatably from one file. The
mechanism has two halves:

1. **Push**: the settings file is a single plist dictionary with **one entry
   per phone, keyed by the phone's hardware UDID**. For each discovered phone
   the script extracts its entry and pushes it as
   `Documents/player-settings.plist`. Phones with no matching entry get a
   warning and no settings push (games still deploy).
2. **Apply**: at next launch,
   [`ProvisioningLoader.swift`](../rwaClient/src/ProvisioningLoader.swift)
   reads that file and writes the values into the app's UserDefaults — the
   same store the Settings tab uses.

**Apply semantics: once per file content.** The loader remembers the content
it last applied and skips it on subsequent launches. So operators may still
change settings on the phone afterwards, and a relaunch will not revert them;
pushing a *changed* plist applies again (and overrides manual changes for the
keys it carries). To force a re-apply with identical values, touch the file
content (e.g. edit a comment).

All keys inside an entry are optional. Omit what should stay untouched:

| Key | Meaning |
| --- | --- |
| `unitId` | the unit label (`rwa-hs-N`): telemetry `device_id`, the phone's hotspot name, and (by convention) the BLE name of the assembly to connect to |
| `assemblyId` | override of the BLE name to connect to; set it **only** when this phone runs with an assembly that is not its unit's own (a spare, an RWAHT, or an un-provisioned board advertising `rtkrover-<chip-id>`). Equal to `unitId` it is dropped as redundant |
| `gpsSource` | `"rtk"` (RTK headtracker) or `"internal"` (phone GPS) |
| `useHeadtracker` | heading from the assembly IMU (`true`) or CoreMotion (`false`) |
| `inverseElevation` | flip the elevation sign from the tracker |
| `calibrateOnStart` | run north calibration automatically when a walk starts |
| `defaultGame` | game to auto-load at launch: Documents-relative `.rwa` path, e.g. `rwatest/rwatest.rwa` |
| `creatorIP` | IP of the machine running RWA Creator (OSC simulator) |

Identity follows the glossary (`PROJECT-PLAN.md` §1.1): the *unit* is
phone + headset assembly, and one label normally covers device_id, hotspot and
BLE name, so a unit usually needs only `unitId`.

Unknown keys are ignored with an error in the app log; boolean values may be
written as plist `<true/>`/`<false/>` or strings.

See [`provisioning.example.plist`](./provisioning.example.plist) for a complete
annotated example, including the stand-in-assembly case.

### Provisioning without deploying games

Games and settings are pushed independently, so re-provisioning a batch of
phones does not mean re-pushing their games. Leave the games folder out:

```sh
./deploy_games.sh -s settings.plist [device ...]
```

Nothing is copied but each phone's `Documents/player-settings.plist`; the games
already on the phones are untouched. Everything else works as above: `-n` dry
runs, `-a`, and an explicit device list.

Since there is no games folder to name, every positional argument is a device
name or UDID. An argument that looks like a path (contains a `/`, or starts
with `.` or `~`) but is not a directory is rejected, so a mistyped games folder
cannot silently become a device name. And because a settings-only run that
matches no phone does nothing at all, that case exits non-zero instead of
reporting success.

### Finding a phone's UDID

The plist is keyed by the *hardware* UDID (`00008030-...`), not the CoreDevice identifier:

```sh
pymobiledevice3 usbmux list
```

or from devicectl: `xcrun devicectl list devices` → the device's
`hardwareProperties.udid` in the JSON output. A dry run
(`./deploy_games.sh -n -s settings.plist <games>`) shows which entry would go
to which phone without copying anything.

### Typical workflow for a batch of units

1. Copy `provisioning.example.plist`, add one entry per phone keyed by UDID
   (the real settings file lives outside the repo, it maps physical hardware
   and doesn't belong in git).
2. Connect the phones over USB, unlock them.
3. Dry-run: `./deploy_games.sh -n -s settings.plist <games-folder>`, check
   every phone gets the games and a settings entry.
4. Run it without `-n`.
5. Relaunch RWA Player on each phone: it rescans Documents for games and
   applies the pushed settings.
6. Later settings changes need no game deploy: edit the plist and run
   `./deploy_games.sh -s settings.plist`, then relaunch the app on each phone.
