# FindMyHistory

A RootHide (Relaxin) jailbreak tweak that locally records the **location, battery, and firmware history of your
AirTags** from inside Apple's Find My app, and shows it as a timeline + map trail with export. **All data stays
on-device**, inside Find My's own sandbox container. Nothing is uploaded. AirTags only — owned and shared-with-you;
never unknown/tracking-alert beacons, AirPods, or devices.

iPhone 15 Pro Max · iOS 17.3.1 · Relaxin/RootHide (ElleKit) · arm64e.

## Features
- **History timeline** per AirTag: open a tag in Find My, tap the **clock button**, get a reverse-chronological list
  of every recorded fix (time, accuracy, source, battery, owned/shared).
- **Map trail**: time-ordered polyline + pins, with 24h / 7d / 30d / All windows.
- **Stats header**: current battery (raw backend value — scale unverified, shown as-is), firmware, serial, ownership,
  fix count, date range.
- **Export**: self-describing CSV or JSON (tag id/name/serial + per-fix data) via the share sheet.
- **In-app Settings** (gear button): master logging on/off, retention (30/90/180/365 days / Forever), per-AirTag
  on/off toggles, and clear-all-data.
- **Owned vs shared** resolved automatically and labeled on every row.

## How it works
Two read-only hooks in Apple's SearchParty client layer (see `findmyhistory/Tweak.xm`):
`SPOwnerSessionLocationFetch -receivedUpdatedLocation:` (locations) and
`SPBeaconManagerSimpleBeaconUpdateInterface -receivedSimpleBeaconUpdates:` (name/battery/firmware/serial/owner).
Updates are joined in memory and written to WAL SQLite in a batched transaction (5 s debounce, force-flushed on
background/terminate under a background-task assertion). No main-thread I/O — the logging path, the History queries,
and every settings write run on background queues. The hooked methods complete in under 1 ms (measured), so there is
no perceptible refresh lag. Every hook is guarded — if a Find My update removes a hooked class *or selector*, the tweak
logs a warning, skips, and the History screen shows a visible "needs an update" banner instead of failing silently.

The item-detail History button is injected via `MSHookMessageEx` on `FindMy.FMItemDetailContentViewController`;
the tag identity comes from a single known-offset read of `itemViewModel.identifier` (no memory scanning).

## Known limitation — capture is foreground-only
History is recorded **only while Find My is open/refreshing**. AirTag locations are fetched by the `searchpartyd`
daemon and handed to the app on refresh (mostly foreground), so you must open Find My to record new points.
AirTags also don't report continuously — location comes from nearby iPhones and is throttled by Apple — so history
is inherently sparse, not a live track. Passive background capture (hooking `searchpartyd`) was investigated and found
infeasible in scope: `searchpartyd` only fetches/stores AirTag locations when a client (Find My) subscribes, is
sandbox-isolated from Find My's container, and its stores are encrypted at rest — so a background daemon cannot feed the
in-app History. Foreground capture is the practical ceiling.

## Requirements
- iPhone on iOS 16.5.1–17.3.1, jailbroken with Relaxin/RootHide (ElleKit), with `openssh`. **Tested only on iOS 17.3.1
  (iPhone 15 Pro Max, arm64e)**; other versions are plausible but unverified, and Find My's internals may differ.
- To build from source: a Mac with the RootHide Theos fork at `~/theos-roothide`.

## Install
**Prebuilt (easiest):** download the `.deb` from the [latest release](../../releases/latest) and install it in Sileo
(or `dpkg -i`). Then open Find My.

**Build from source:**
```bash
THEOS=~/theos-roothide make -C findmyhistory package        # builds the roothide .deb into packages/
THEOS=~/theos-roothide make -C findmyhistory package install THEOS_DEVICE_IP=<device-ip>   # build + install over SSH
```
Logs: `idevicesyslog -m '[FMH]'`.

## Data, privacy & uninstall
- DB: `<Find My data container>/Library/Application Support/FindMyHistory/history.sqlite` (WAL), resolved at runtime
  via `NSHomeDirectory()`. One row per AirTag fix:
  `tag_id, tag_name, lat, lon, h_acc, timestamp, source, battery_raw, battery_label, firmware, is_owned, serial_number, created_at`.
- Only your AirTags, only on your device, only inside Find My's sandbox. No keychain access, no accessory keys,
  no network. Owner email handles are used in memory only to classify owned/shared and are never written to the DB.
- **Uninstall**: remove the package (`dpkg -r com.liam.findmyhistory` or via Sileo) — it installs only
  `FindMyHistory.dylib` + `.plist`. The history DB lives in Find My's container; use **Settings → Clear all history**
  first if you want it gone.

## Status
v0.2.0. Logging, History UI (list + map), settings, and hardening complete, plus an optional **Precise accuracy**
toggle (0.1 m vs whole-meter display). Background capture was investigated and found infeasible in scope (see the
known-limitation note above). Battery-over-time chart and a low-battery alert were intentionally skipped (battery value
barely changes over the logged window; Apple already alerts for owned tags).
