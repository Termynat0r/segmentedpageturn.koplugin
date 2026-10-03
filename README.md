# Segmented page turns

Segmented page turns adds a directional, stepped wipe animation to ordinary
page turns in KOReader. On a supported device, the new page is revealed one
vertical display band at a time instead of appearing as one full-screen
refresh.

Segmented page turns is a plugin that aims to mimic the polished, directional
e-ink page-turn effect associated with established e-reader brands—most
recognizably, the devices sold by the market-leading online bookseller.

The plugin is deliberately small and self-contained: it uses the HWTCON
display interface directly and does not require a patched KOReader frontend.

## Requirements

- An e-reader with a compatible HWTCON display backend.
- A KOReader version compatible with this plugin's page-update and framebuffer
  hooks.

Devices with a compatible HWTCON backend should be supported. Examples include
the Kobo Libra Colour, Clara Colour, and Clara BW, along with their Tolino
counterparts: Vision Color, Shine Color, and Shine 5. Not every compatible
model has been individually tested.

## Verified compatibility

The following compatibility targets have been tested (1 October 2026):

- **KOReader v2026.07.2**
- **ZenOS v3.3.1**
- **Kobo Clara Colour** (color e-ink)

## Installation and use

1. Copy the `segmentedpageturn.koplugin` directory into KOReader's `plugins`
   directory on the device.
2. Restart KOReader and open a document.
3. In the reader settings, open **Taps and gestures** → **Page turns** and
   enable **Page turn animations**.

The switch is KOReader's existing `swipe_animations` setting. The plugin adds
the same control to the Page turns menu when it is active; disabling it returns
page turns to KOReader's normal refresh behavior.

### Color content

On Kaleido color e-ink devices, the plugin deliberately disables the
segmented animation for a page containing color content. The display driver
needs to process the color filter array across the complete update region;
revealing the page in separate bands can otherwise cause visible seams and
color artefacts. Such pages therefore use KOReader's normal color refresh
path instead of the animation.

### Recommended refresh settings

For the best balance of image quality and refresh speed, configure KOReader's
full-page refresh setting to **Flash on chapter boundaries** and enable
**Always flash on pages with images**. Also enable **Dithering** in the font
menu. These settings ensure that image-heavy and color pages receive an
appropriate high-quality refresh, while ordinary greyscale text pages can use
the segmented animation.

To change the full-refresh settings while reading, open the main menu and go
to **Screen** → **E-ink settings** → **Full refresh rate**. Enable **Always
flash on chapter boundaries** and **Always flash on pages with images** there.
To enable dithering, open the reader's **Font** menu, find **Dithering**, and
switch it on. Dithering lets KOReader identify pages containing images and
request the appropriate image-refresh path. On devices with hardware
dithering support, this enables hardware dithering for the current document.

## How it works

After a sequential, one-page turn, the plugin arms the next plain full-screen
partial refresh. It then replaces that one refresh with a sequence of vertical
HWTCON partial updates. Forward and backward turns sweep in opposite
directions. Taps, swipes, keys, and gestures are handled through KOReader's
normal page-update event rather than through separate input patches.
Only a suitable, full-screen page refresh is replaced. If the animation is
disabled, the refresh queue contains more work, or the candidate refresh is
not a plain full-screen partial update, KOReader's original refresh proceeds
unchanged.

At runtime, the plugin checks for `/proc/hwtcon/cmd` and the required
framebuffer methods. If either is unavailable, the plugin stays inactive. In
particular, Kindle MTK devices are not supported because they use a different
display-driver update ABI.

## KOReader update compatibility and resilience

This plugin hooks KOReader's reader page-update event and framebuffer
partial-refresh implementation. Those are intentionally narrow hooks, but
they are internal integration points and can change between KOReader releases.

### Other page-turn and framebuffer hooks

Do not install this plugin alongside another plugin or patch that overrides
`Screen:refreshPartialImp`, `Screen:afterPaint`, or page-turn animation
behavior. In particular, remove or disable
[Swipe_Animation.koplugin](https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin)
before enabling Segmented page turns. Two implementations intercepting the
same refresh cycle can conflict or produce unreliable display updates.

## Testing KOReader upgrades

From the root of a KOReader source tree containing this plugin, run:

```sh
./kodev test --busted front plugins/segmentedpageturn.koplugin/tests/koreader_compatibility_spec.lua
```

The test checks the KOReader page-update and refresh-hook contracts, the MTK
HWTCON marker/submission path, and the HWTCON update ABI. A passing test is a
source-level compatibility check; it does not replace a short on-device test
on each supported display family.

## License

Copyright (C) 2026 Termynat0r.

Segmented page turns is licensed under the GNU Affero General Public License,
version 3 or any later version (AGPL-3.0-or-later). See [LICENSE](LICENSE.md).


## Inspiration and credits

This plugin is inspired by two projects, in different ways:

- [NickelDissolve](https://github.com/nicoverbruggen/NickelDissolve) targets
  Kobo's native Nickel reader rather than KOReader; it provided
  the central hardware-animation idea: turn one full-screen page refresh into
  a directional sequence of partial vertical-strip updates.
- [Swipe_Animation.koplugin](https://github.com/koplugin-swipe-animation/Swipe_Animation.koplugin)
  demonstrated the value of a wipe-style page-turn animation within KOReader.
  Its implementation requires patching KOReader frontend files; Segmented page
  turns deliberately avoids that installation model by using narrow runtime
  hooks instead.
