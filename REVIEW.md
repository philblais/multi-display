# Code review: version 1.8 (build 9)

Reviewed on October 18, 2026. Scope: all app Swift sources, vendored DDC Swift/Objective-C bridge, saved setup storage, XcodeGen configuration, and tests. The review combined static inspection, an independent review of display routing and recovery decisions, deterministic regression tests, and a packaged build. Connected displays were not changed during verification.

## Fixed findings

| Priority | Finding and trigger | Change |
| --- | --- | --- |
| P1 | Identical or weakly identified monitors could independently select the same DDC service, changing the wrong screen. | Resolve across all active displays; require a mutual, unique, positive best match. Reject missing services, ties, duplicate proxy records, and inactive display IDs. |
| P1 | An external slider or saved setup could create a black or nearly black screen without working recovery, including mirrored screens. | Normalize unsafe external values below 1/16 before every write path. Check live mirror state, protect the blackout controller, and clear saved blackout intent when recovery is unavailable. The safety check also detects near-zero software dimming. |
| P2 | A failed I²C read inherited a successful request-write result, skipping retries and potentially enabling sticky software fallback. | Read success requires a valid reply. Clear retry buffers and validate source, length, opcode, status, command, and checksum. Retry counts no longer overflow at 255. |
| P2 | Repeated DDC operations leaked registry references and path buffers; a failed path read could consume uninitialized memory. | Release skipped and consumed iterator objects, free scoped buffers, check path retrieval, and clear reused proxy service fields. Balance the native framework's library handle. |
| P2 | Late reads could overwrite newer brightness values or enable software fallback after disconnect, profile changes, or display-ID changes. Queued writes could also outlive their connection. | Track connection identities, request revisions, and cancellation leases. Discard obsolete read results and cancel queued I/O for invalidated connections. Reject non-finite readings/writes and clamp valid values. |
| P2 | Repeated rotation requests, early Keep, and setup application could overlap; setup timers started before work finished. | Use a single configuration lifecycle with operation tokens. Keep controls locked through application, confirmation, and rollback; start setup confirmation after completion. Ignore old operation completions. |
| P2 | Immediate rollback could inspect cached rotation or a stale connection/baseline. | Scan fresh inventory before taking transaction snapshots and before rollback; restore using the current display ID. Report unavailable previous modes. |
| P2 | A setup applied before the initial brightness read could write a saved value without a known value for Revert. | Skip that brightness change and explain why; retry once the current brightness is available. |
| P2 | Reveal during setup application could be followed by another dimming write that blacked the screen again. | Clear overlays and pending slider edits immediately, recover brightness, and skip remaining setup dimming writes. Mode and rotation work can still finish. |
| P2 | Locking display controls during a setup could also block brightness-up recovery. | Allow upward keyboard recovery for black or near-black screens throughout applying and confirmation; suppress remaining setup dimming writes. |
| P2 | A hung or verbose displayplacer process could block rotation indefinitely through a full output pipe or endless wait. | Capture to a temporary file, bound returned output, enforce a timeout, and terminate/kill the helper when needed. |
| P2 | Lost key-up events left brightness keys targeting an old display after a tap timeout or a new physical press. | Clear stale captures on disabled taps and fresh key-downs. Preserve held-repeat targeting. Retry rechecks Accessibility trust and recreates invalid taps. |
| P2 | Refreshes could overwrite a slider drag; a disconnect during a drag could leave its later slider unavailable. | Track active edits, reject stale callbacks, and clear obsolete edit state on connection changes. |
| P2 | Saved mode matching treated 59.94 and 60 Hz as interchangeable. | Reduce refresh-rate matching tolerance from 0.5 to 0.01 Hz while retaining the saved JSON format. |
| P3 | Display discovery stopped at 16; fallback persistent IDs could collide for identical serial-less displays. | Query the display count dynamically and include the transient display ID only when UUID lookup fails. |
| P3 | Floating-point truncation displayed values such as 29% as 28%. | Round brightness percentages consistently with the HUD. |

## Optimization

Brightness commits now reread only the affected screen instead of rescanning every display's resolution modes and brightness. Inventory scans reuse one NSScreen name lookup table. Removing DDC resource leaks prevents repeated key presses from accumulating registry references. Persistent hardware-service caching was deliberately deferred because reconnect and sleep/wake invalidation must be proven on the actual hardware first.

## Verification

The regression suite covers DDC decoding/retries/routing; connection and request invalidation; software fallback; keyboard captures; refresh-rate matching; configuration exclusivity, rollback, and emergency reveal; unsafe zero requests; slider refresh behavior; subprocess output, errors, timeout, and cleanup. Fake transports replace brightness hardware, and helper tests run shell fixtures. The test target includes the app sources without its entry point, with separate UserDefaults suites for store tests.

All 49 tests pass (42 added beyond the original 7). The Release app is built for arm64 and x86_64 with the existing Apple Development signing identity. Bundle metadata is version 1.8, build 9; the menu reads that same version from the bundle. Final logs are recorded in `Build/review-tests.log` and `Build/review-release.log`.

## Remaining limits and hardware validation

- DDC routing is conservative. Some docks or identical monitors may expose insufficient information, leaving brightness unavailable. Verify each LG independently, then both together after reconnect and sleep/wake.
- Test physical brightness, HDR, Samsung software dimming, rotation, resolution rollback, full-screen overlays, and recovery with Accessibility revoked. These effects cannot be established by fake transports.
- DisplayServices, CoreDisplay/IOAVService transport, and displayplacer's rotation path rely on undocumented macOS interfaces. OS updates may change their behavior.
- Kept resolution settings use the existing session-scoped CoreGraphics API; they may revert to macOS's permanent configuration when the app exits.
- When macOS cannot provide a UUID, the fallback identity can change on reconnect. This avoids confusing identical monitors but can require recreating their saved setup/model selection.
- In-progress hardware I/O cannot be undone after it has already started. UI callbacks and queued work require connection validity; test unplug/replug during repeated brightness input on the actual adapter.
- The main view still queries whether BetterDisplay is running during redraw. No measured UI bottleneck justified adding a workspace-observer subsystem in this change.
