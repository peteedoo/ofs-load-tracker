# OFS Load Tracker

A native macOS (SwiftUI) app for tracking active OFS freight loads. Pulls live status from Mac Mail, ingests TMS screenshots for the canonical load list, surfaces conflicts between the two, and provides one-click tracking links for LTL carriers.

## What it does today

### FTL (truckload)
- Scans the Mac Mail account `poldfield@onlinefreight.com` (inbox + Sent) over the last 14 days for any subject matching `Load # <7-digit ID>`.
- For each load, classifies status: **Dispatched** / **At pickup** / **Loaded & rolling** / **At delivery** / **Delivered ✓** / **Silent** / **No carrier reply** / **Handled (Glenn)**.
- Per-row actions: **Check-in** (opens a Mail draft replying to the latest message with full quoted thread); **Forward POD** (forwards the carrier's POD email to `accounting@onlinefreight.com` with the subject `POD Load # <id>` and body `See attached, thank you :)`).
- Caches scan results to `~/Library/Application Support/OFSLoadTracker/cache.json` so launches after the first are instant. The first scan can take 30–60s; subsequent refreshes can run in the background.
- Conflict detection between Mail status and TMS screenshot status — surfaces a warning chip when they disagree (e.g. "Email shows POD; TMS still 'In Progress'").

### LTL (less-than-truckload, separate tab)
- Drag/drop or paste a screenshot of the OFS TMS view; the app OCRs (Apple Vision) and extracts rows that have a Carrier Pro #.
- Each row gets a Track button that copies the PRO to the clipboard *and* opens the carrier's public tracking page. Carriers wired up: Estes, TForce, Saia, FedEx Freight, ODFL, RXO/XPO, R+L, ABF, Forward Air, Roadrunner, Averitt, Southeastern, Dayton, Holland, Pitt Ohio, AAA Cooper, North Park.
- Echo Logistics rows that don't have a PRO yet still show in the LTL tab with a "No PRO yet" badge; if their pickup date has passed, the badge turns red and a "Call carrier" indicator appears.

## How to build

```sh
bash build.sh
open "OFS Load Tracker.app"
```

Requires Xcode command-line tools (for `swiftc`). macOS 13+. The app is unsigned and asks for Mail automation permission on first launch.

Project layout:

| File | Role |
|---|---|
| `OFSLoadTracker/main.swift` | `@main` SwiftUI App |
| `OFSLoadTracker/Loads.swift` | `Load`, `LoadStatus` types |
| `OFSLoadTracker/MailScanner.swift` | AppleScript Mail bulk scan + classifier + cache |
| `OFSLoadTracker/LoadActions.swift` | Draft check-in + Forward POD AppleScripts |
| `OFSLoadTracker/LTL.swift` | `LTLLoad`, `LTLCarrier`, `ScreenshotLoad`, tracking URLs |
| `OFSLoadTracker/LTLOCR.swift` | Apple Vision OCR + heuristic row parser |
| `OFSLoadTracker/ScreenshotStore.swift` | Persistence + import flow for TMS screenshots |
| `OFSLoadTracker/ContentView.swift` | Main UI: tab picker, FTL list, LTL view |
| `OFSLoadTracker/LTLView.swift` | LTL tab + drag/drop + per-row UI |
| `Info.plist` | Bundle config (Mail automation usage description) |
| `build.sh` | swiftc → app bundle (no DMG, single-user tool) |

## Known limitations / next steps

1. **OCR accuracy**: Apple Vision struggles with the dense 22-column TMS view — column anchors drift, "Status" sometimes mis-OCRs as garbage. The honest fix is to send the screenshot to the Claude API with vision and parse the returned JSON instead of doing column-anchor heuristics in Swift. This is the next planned change.
2. **Multi-account Sent scan**: Today only `poldfield@onlinefreight.com` Sent is scanned. Other teammates' Sent folders are ignored.
3. **No FedEx Freight live API yet**: The `API` badge appears next to FedEx rows but Phase 2 (calling FedEx's tracking API for live status) is not wired up. All other carriers will only ever be tracking-URL-deep.
4. **Hardcoded carrier list**: New LTL carriers need to be added to `LTLCarrier` (with their tracking URL pattern) — there's no auto-discovery.
5. **Unsigned app**: Distribution requires `xattr -d com.apple.quarantine` or right-click → Open the first time on a new Mac.

## Workflow rules baked in

These mirror the team's standard practice:

- **POD-received**: when a carrier sends in a POD (PDF/CamScanner/BOL attachment), reply "Thank you!!" to the carrier and forward to `accounting@onlinefreight.com` with subject `POD Load # <id>` and body `See attached, thank you :)`. If Glenn Bachman has already replied to the POD email, skip — assume he handled the forward.
- **Check-in template** for silent loads: `Hey <name> — checking in on this one. Did we get delivered? If so, can you send the POD over?  Thanks, Petee`. Drafts always preserve the quoted email thread.
- **LTL = Echo Logistics** in this TMS view; FTL is everything else. The two flows are separate.
- **Lumper receipt = delivery in progress** — don't push for POD yet.
