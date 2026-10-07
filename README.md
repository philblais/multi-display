# Multi Display

A personal macOS menu bar app for a MacBook Pro, two LG 4K monitors, and a Samsung HG50U701FNF TV (model code HG50U701FNFXZA). It offers per-display brightness, a shared brightness slider, optional per-display brightness keys, existing macOS resolution modes, external-display rotation, and manual saved setups.

The current version is shown at the bottom of the app menu. Each delivered app update advances the second number: 1.1, 1.2, 1.3, and so on.

## Build and run

1. Open `MultiDisplayManagement.xcodeproj` in Xcode 27 or newer.
2. Select the `MultiDisplayManagement` scheme and **My Mac**.
3. Build and Run. Look for the two-display icon in the menu bar.

For everyday use and keyboard testing, launch `Build/Multi Display.app` from its stable path. Xcode's Run command launches a separate copy in DerivedData, which macOS may treat as a different app for Accessibility permission.

The app targets macOS 26 and Apple Silicon. It uses the `displayplacer` command already installed at `/opt/homebrew/bin/displayplacer` or `/usr/local/bin/displayplacer` for rotation. The app is not sandboxed because the DDC transport requires hardware access.

`project.yml` is the XcodeGen source for the included Xcode project. Run `xcodegen generate` after changing the project configuration.

Run the focused model and brightness tests with `xcodebuild -project MultiDisplayManagement.xcodeproj -scheme MultiDisplayManagement -destination 'platform=macOS' test`. They use fake brightness transports and do not change connected displays.

This personal project is configured to use the Apple Development certificate available on this Mac. If you build on another Mac, select its development team and signing identity in Xcode. Keep the same bundle identifier and signing identity for Accessibility permission to survive rebuilds.

## How controls work

- MacBook brightness uses macOS DisplayServices. That interface is undocumented and may change in future macOS releases.
- External brightness uses the MIT-licensed [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC) transport and the standard DDC luminance command. The library is included in `Vendor/AppleSiliconDDC`; its license is retained there. DDC may not work through some ports, docks, or while HDR is enabled.
- The Samsung HG50U701FNF profile tries DDC first. If the connection does not respond, the slider and brightness keys use a click-through software dimming layer. The menu labels this as **Software dimming**: it darkens the Mac's image without changing the TV backlight or power consumption. Set the TV backlight with its remote. Software dimming starts at 100% and is cleared on disconnect or app exit; saved setups can apply a chosen dimming level manually. Once fallback is active it stays in use until disconnect or a model-selection change, so Refresh preserves the dimming level.
- If macOS reports the full Samsung model number, the app recognizes it automatically. If it reports only **SAMSUNG** or another generic name, select **Samsung HG50U701FNF** under **Display model** on that screen's card. The selection is remembered for that display's persistent ID. Other Samsung models are not identified from the brand alone. The profile recognizes the model, full model code, and HG50U701F type number on the label. Samsung lists it as the [HU7010F hospitality TV](https://www.samsung.com/ca/business/commercial-tvs/hotel-tv/hu7010f-uhd-4k-hg50u701fnfxza/).
- Keyboard brightness control starts on for new users and remembers later changes to the toggle. Grant Accessibility access in System Settings, then choose **Retry** in the menu. The default target is the display under the pointer; you can instead use the display with keyboard focus. F1/F2 only changes that display. Option+Shift makes smaller steps; Option alone keeps macOS's normal Displays shortcut. Mirrored screens are left to macOS.
- Brightness-key changes show a short brightness indicator on the affected display with its name and percentage. If an external brightness write fails, the indicator reports that brightness is unavailable.
- At 0%, each external display is covered by a click-through black layer. Press brightness up while the pointer is on that display, move its slider above 0%, or choose **Reveal screens** in the app menu to bring the image back. Reveal screens also resets Samsung software dimming to 100%. The monitor remains powered, so its backlight may still glow slightly. The app removes the black layer when it quits, a display disconnects, or keyboard recovery becomes unavailable. On launch, a saved 0% black layer is restored only when keyboard control is active. Software dimming is disabled for mirrored screens.
- Resolution uses the modes macOS already reports for each display. The app does not create custom HiDPI modes.
- Rotation uses the locally installed `displayplacer` helper, which depends on undocumented macOS behavior. The MacBook display rotation control is disabled.
- Rotation can also affect display arrangement on some macOS setups. Check the arrangement after a rotation, and use System Settings if macOS moves a screen unexpectedly.
- Resolution and rotation changes ask for confirmation and revert after 15 seconds. Applying a saved setup reverts after 35 seconds unless confirmed.
- Saved setups are applied manually. Automatic application on reconnect is deferred until the hardware paths have been tested after sleep and reconnect.

## First hardware check

Connect both LG monitors, then open the app and check that all three screens appear. Try each brightness slider at a moderate setting, starting with the 27UD68-W. Try the 32UN500-W with HDR both off and on. Test rotation and resolution one display at a time, confirming each change before proceeding. During these checks, quit BetterDisplay manually so its controls do not race with this app.

For keyboard control, grant Accessibility access to the app in `Build/Multi Display.app` and choose **Retry** in the menu. Put the pointer on each screen in turn and press the brightness keys; only that screen should change. Hold a key to check repeats. Then try **Display with keyboard focus** while using a window on each screen. If macOS revokes access after a rebuild, remove the old entry in Accessibility, add this same app path again, and choose **Retry**. Keep BetterDisplay's brightness-key handling off during this check.

For the 0% check, dim one LG at a time to 0%, then press brightness up while the pointer is still on it. Also try the slider and **Reveal screens**. Repeat on the rotated LG and, if you use it, with HDR or a full-screen app open. The MacBook screen must stay unaffected while testing either LG.

The display details in the app expose the IDs used for saved setups and troubleshooting. If a control is unavailable, the app leaves that screen unchanged and shows a message.

For the Samsung check, connect the TV as an extended Mac display and select its model if needed. Start around 75%; check that the slider, shared slider, and F1/F2 affect only their intended screens. If the card says Software dimming, the remote still controls the TV's physical backlight. Try 0%, brightness up, and Reveal screens, then Refresh, rotation, sleep/wake, disconnect/reconnect, and quitting while dimmed. Save and manually apply a setup to check its dimming level. Resolution choices are limited to what the Mac reports for the current cable/adapter.
