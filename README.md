# FindMyHistory

A rootless jailbreak tweak that locally records the **location, battery, and firmware history of your
AirTags** from inside Apple's Find My app, and shows it as a timeline + map trail with export. **All data stays
on-device**, inside Find My's own sandbox container. Nothing is uploaded. AirTags only — owned and shared-with-you;
never unknown/tracking-alert beacons, AirPods, or devices.

iPhone 15 Pro Max · iOS 17.3.1 · Relaxin/RootHide (ElleKit) · arm64e.

Packages use the standard **rootless** scheme and Debian architecture **`iphoneos-arm64`**. The dylib contains
arm64 and arm64e slices. RootHide uses its own native package format and may require conversion with its tooling.

## Features
- **History timeline**: the clock matches Apple's close-button style. History shows the tag name, calendar-day sections,
  times with seconds, readable sources and accuracy. Tap a fix to show it on the map with its accuracy circle.
- **Map trail**: full time-ordered polyline, with 24h / 7d / 30d / All windows. The map loads when selected. Large
  histories show fewer pins while retaining every fix in the trail and export.
- **Item Details**: expandable raw battery (scale unverified), firmware, serial and ownership at the latest recorded
  fix. The summary shows fix count, date range and age of the latest fix.
- **Export**: CSV or JSON via the share sheet, with escaped text fields and fractional timestamp/accuracy precision.
  Files are prepared off the main thread, errors are shown, and temporary files are cleaned after sharing.
- **In-app Settings** (gear button): master logging on/off, retention (30/90/180/365 days / Forever), per-AirTag
  on/off toggles, precise accuracy formatting, and clear-all-data. Disabled tags remain selectable after clearing.
- **Consistent updates**: saved fixes, clearing and accuracy-format changes refresh open history. Superseded range
  queries and exports cannot replace newer selections. Pull-to-refresh reloads saved history only.
- **Reliable storage**: failed batches remain pending for retry; clearing runs on the logger queue and discards queued
  pre-clear fixes only after successful deletion. No history is deleted when updating the tweak.

## How it works
Two read-only hooks in Apple's SearchParty client layer (see `findmyhistory/Tweak.xm`):
`SPOwnerSessionLocationFetch -receivedUpdatedLocation:` (locations) and
`SPBeaconManagerSimpleBeaconUpdateInterface -receivedSimpleBeaconUpdates:` (name/battery/firmware/serial/owner).
Updates are joined in memory and written to WAL SQLite in a batched transaction (5 s debounce, force-flushed on
background/terminate under a background-task assertion). No main-thread I/O — the logging path, the History queries,
and every settings write run on background queues. Every hook is guarded — if a Find My update removes a hooked class *or selector*, the tweak
logs a warning, skips, and the History screen shows a visible "needs an update" banner instead of failing silently.

The item-detail History button is injected via `MSHookMessageEx` on `FindMy.FMItemDetailContentViewController`;
the tag identity comes from a single known-offset read of `itemViewModel.identifier` (no memory scanning).

## Known limitation — capture is foreground-only
History is recorded **only while Find My is open/refreshing**. AirTag locations are fetched by the `searchpartyd`
daemon and handed to the app on refresh (mostly foreground), so you must open Find My to record new points.
AirTags also don't report continuously — location comes from nearby iPhones and is throttled by Apple — so history
is inherently sparse, not a live track. Passive daemon hooks do not themselves request fresh reports. An active,
bounded background wake/fetch is still being investigated; this release adds no scheduler or permanent keepalive.

A startup metadata gap is also under investigation: logging can wait for the first AirTag metadata update even when
cached items are visible. The in-memory location buffer is limited, so capture gaps are possible. A reliable initial
metadata snapshot is needed before background refresh is added.

## Requirements
- iPhone on iOS 16.5.1–17.3.1, jailbroken with Relaxin/RootHide (ElleKit), with `openssh`. **Tested only on iOS 17.3.1
  (iPhone 15 Pro Max, arm64e)**; other versions are plausible but unverified, and Find My's internals may differ.
- To build from source: a Mac with Theos and the iOS 16.5 SDK. The commands below use the tested RootHide Theos fork
  at `~/theos-roothide`, with its **rootless** package scheme.

## Install
**Prebuilt (easiest):** download the `.deb` from the [latest release](../../releases/latest) and install it in Sileo
(or `dpkg -i`). Then open Find My.

**Build from source:**
```bash
make -C findmyhistory THEOS=~/theos-roothide clean package FINALPACKAGE=1
# Output: findmyhistory/packages/com.liam.findmyhistory_0.2.1_iphoneos-arm64.deb
make -C findmyhistory THEOS=~/theos-roothide install THEOS_DEVICE_IP=<device-ip>
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
v0.2.1 updates the rootless packaging, storage reliability, exports and History UI. The source includes the same tweak
implementation currently installed on the test iPhone; package version metadata advances from the local development
build. A clean build from this repository produces the release package. Battery values remain raw while their meaning
is investigated; no battery percentage is claimed. Background refresh remains experimental and is not enabled.
