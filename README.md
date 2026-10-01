# Segmented page turns

This is a self-contained KOReader plugin implementation of the HWTCON display-band page-turn
animation used by the companion core prototype. It submits 10 bands on panels
whose longest edge is below 1600 pixels and 12 bands on larger panels, matching
NickelDissolve's automatic defaults.

It detects Kobo HWTCON directly through `/proc/hwtcon/cmd` and embeds its own
HWTCON update ABI, markers, and submission waits. Other devices, including
Kindle MTK devices, are not treated as compatible because their display-driver
update ABI is different.

After installing the plugin, enable **Page turn animations** in the reader's
**Taps and gestures** settings. The option uses KOReader's existing
`swipe_animations` setting.

The plugin deliberately hooks KOReader's reader page-update event and the
framebuffer partial-refresh implementation, so it should be tested against
each KOReader release before distribution.
