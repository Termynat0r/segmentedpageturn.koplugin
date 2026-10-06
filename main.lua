-- SPDX-FileCopyrightText: 2026 Termynat0r
-- SPDX-License-Identifier: AGPL-3.0-or-later

--[[--
@module koplugin.segmentedpageturn

Implements animated page turns without changing KOReader core:
the plugin arms itself after an ordinary one-page turn, then replaces that
turn's single full-screen partial refresh with a sequence of HWTCON bands.
--]]

local ffi = require("ffi")
require("ffi/mxcfb_kobo_h")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Dispatcher = require("dispatcher")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local Screen = Device.screen
local C = ffi.C
local uint8pt = ffi.typeof("const uint8_t*")

-- Track the HWTCON ABI exposed by the running KOReader version.
local HWTCON_SEND_UPDATE = C.HWTCON_SEND_UPDATE
local HWTCON_FLAG_CFA_SKIP = C.HWTCON_FLAG_CFA_SKIP
local HWTCON_WAVEFORM_REAGL = C.HWTCON_WAVEFORM_MODE_GLR16
local HWTCON_WAVEFORM_KALEIDO_REAGL = C.HWTCON_WAVEFORM_MODE_GCK16
local HWTCON_WAVEFORM_NIGHT = C.HWTCON_WAVEFORM_MODE_GLKW16
local UPDATE_MODE_PARTIAL = C.UPDATE_MODE_PARTIAL

local function has_hwtcon_backend()
    return Screen.fd ~= nil
        and lfs.attributes("/proc/hwtcon/cmd", "mode") ~= nil
        and type(Screen._get_next_marker) == "function"
        and type(Screen.mech_wait_update_submission) == "function"
end

local function build_band_edges(width, strips, alignment)
    local edges = { 0 }
    for i = 1, strips - 1 do
        local edge = math.floor((width * i / strips + alignment / 2) / alignment) * alignment
        if edge > edges[#edges] and edge < width then
            table.insert(edges, edge)
        end
    end
    table.insert(edges, width)
    return edges
end

local SegmentedPageTurn = WidgetContainer:extend{
    name = "segmentedpageturn",
    is_doc_only = true,
}

local active_plugin
local hooks_installed = false
local original_refresh_partial_imp
local original_after_paint

function SegmentedPageTurn:isEnabled()
    return self.supported and G_reader_settings:isTrue("swipe_animations")
end

function SegmentedPageTurn:arm(forward)
    self.pending_direction = forward
end

function SegmentedPageTurn:clearPendingPageTurn()
    self.pending_direction = nil
end

function SegmentedPageTurn:getBandEdges(width, height, alignment)
    local cache = self.band_edge_cache
    if cache
      and cache.width == width
      and cache.height == height
      and cache.alignment == alignment then
        return cache.edges
    end

    -- Keep each band close to 105 display pixels wide.
    local strips = math.floor(width / 105 + 0.5)
    local edges = build_band_edges(width, strips, alignment)
    self.band_edge_cache = {
        width = width,
        height = height,
        alignment = alignment,
        edges = edges,
    }
    return edges
end

function SegmentedPageTurn:getBandUpdateSettings(fb)
    local night_mode = fb.night_mode == true
    return {
        waveform = night_mode and HWTCON_WAVEFORM_NIGHT
            or (fb.device and fb.device:hasColorScreen()
                and HWTCON_WAVEFORM_KALEIDO_REAGL
                or HWTCON_WAVEFORM_REAGL),
        update_mode = UPDATE_MODE_PARTIAL,
        wait_for_update = fb.mech_wait_update_submission,
        wait_name = "HWTCON_WAIT_FOR_UPDATE_SUBMISSION",
    }
end

-- Kaleido uses an RGB framebuffer.  Dithering is merely a rendering hint, so
-- determine whether the painted page actually contains color by checking its
-- red, green, and blue channels.  The page-turn candidate is full-screen, so
-- scanning the active framebuffer covers precisely the pending update.
function SegmentedPageTurn:isColorContentUpdate(fb)
    if not (fb.device:hasKaleidoWfm() and fb:isColorEnabled()) then
        return false
    end
    local bb = fb.bb
    if not bb:isRGB() then
        return false
    end
    local bytes_per_pixel = bb:getBytesPerPixel()

    -- Color Kobo devices use BBRGB32.  Scan its native storage directly to
    -- avoid allocating a copy or creating a Lua Color object per pixel.
    if bytes_per_pixel >= 3 then
        local data = ffi.cast(uint8pt, bb.data)
        for y = 0, bb.h - 1 do
            local row = data + bb.stride * y
            for x = 0, bb.w - 1 do
                local pixel = row + bytes_per_pixel * x
                if pixel[0] ~= pixel[1] or pixel[1] ~= pixel[2] then
                    return true
                end
            end
        end
        return false
    end

    -- Retain correctness should a future color device expose RGB565 instead.
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do
            local pixel = bb:getPixel(x, y):getColorRGB32()
            if pixel.r ~= pixel.g or pixel.g ~= pixel.b then
                return true
            end
        end
    end
    return false
end

-- Reader modules receive PageUpdate for every real page change.  Tracking it
-- here avoids patching ReaderPaging internals, and also makes this work with
-- all normal page-turn inputs (tap, swipe, key, and gesture).
function SegmentedPageTurn:onPageUpdate(new_page, orig_mode)
    local old_page = self.last_page
    self.last_page = new_page
    if not self:isEnabled()
      or not old_page
      or orig_mode
      or self.ui.view.page_scroll
      or math.abs(new_page - old_page) ~= 1 then
        return
    end

    local forward = new_page > old_page
    if self.ui.view.inverse_reading_order then
        forward = not forward
    end
    self:arm(forward)
    logger.dbg("SegmentedPageTurn: armed", forward and "forward" or "backward", "page turn")
end

function SegmentedPageTurn:refreshSegmentedPageTurn(fb, x, y, w, h, dither)
    local forward = self.pending_direction
    if forward == nil then
        return false
    end
    if not self:isEnabled() then
        logger.dbg("SegmentedPageTurn: discarded pending turn; animation setting is off")
        return false
    end
    if #UIManager._refresh_stack ~= 1 then
        logger.dbg("SegmentedPageTurn: discarded pending turn; refresh queue has", #UIManager._refresh_stack, "entries")
        return false
    end
    if self:isColorContentUpdate(fb) then
        logger.dbg("SegmentedPageTurn: discarded pending turn; color content needs KOReader's Kaleido waveform")
        return false
    end
    if dither or x ~= 0 or y ~= 0 or w ~= fb.bb:getWidth() or h ~= fb.bb:getHeight() then
        logger.dbg("SegmentedPageTurn: discarded pending turn; refresh is not a plain full-screen partial update")
        return false
    end

    local update_settings = self:getBandUpdateSettings(fb)

    local alignment = fb.alignment_constraint or 1
    local edges = self:getBandEdges(w, h, alignment)
    if #edges < 3 then
        return false
    end

    fb:refreshWaitForLast()
    local bb = fb.full_bb or fb.bb
    for i = 1, #edges - 1 do
        local edge_index = forward and (#edges - i) or i
        local left = edges[edge_index]
        local right = edges[edge_index + 1]
        local rx, ry, rw, rh = bb:getBoundedRect(left, 0, right - left, h, alignment)
        rx, ry, rw, rh = bb:getPhysicalRect(rx, ry, rw, rh)

        self.update_data.waveform_mode = update_settings.waveform
        self.update_data.update_mode = update_settings.update_mode
        self.update_data.update_region.left = rx
        self.update_data.update_region.top = ry
        self.update_data.update_region.width = rw
        self.update_data.update_region.height = rh
        -- Use KOReader's shared marker sequence. The next ordinary refresh
        -- must see the final band marker, otherwise it can wait on or reuse
        -- a stale marker after a long reading session.
        local marker = fb:_get_next_marker()
        self.update_data.update_marker = marker

        fb.debug(string.format("segmented page turn plugin: %ux%u @ (%u, %u), marker %u", rw, rh, rx, ry, marker))
        if C.ioctl(fb.fd, HWTCON_SEND_UPDATE, self.update_data) == -1 then
            local err = ffi.errno()
            fb.debug("HWTCON_SEND_UPDATE ioctl failed:", ffi.string(C.strerror(err)))
            return false
        end

        if update_settings.wait_for_update(fb, marker) == -1 then
            local err = ffi.errno()
            fb.debug(update_settings.wait_name .. " ioctl failed:", ffi.string(C.strerror(err)))
            return false
        end
        if update_settings.update_mode == UPDATE_MODE_FULL then
            fb.dont_wait_for_marker = marker
        end
    end
    logger.dbg("SegmentedPageTurn: submitted", #edges - 1, "HWTCON bands")
    return true
end

local function install_hooks()
    if hooks_installed then
        return
    end
    hooks_installed = true

    -- UIManager caches Screen:refreshPartial at load time, but the cached
    -- wrapper dynamically dispatches to this implementation method.  This
    -- gives the plugin a narrow hook without copying UIManager:_repaint().
    original_refresh_partial_imp = Screen.refreshPartialImp
    Screen.refreshPartialImp = function(fb, x, y, w, h, dither)
        local plugin = active_plugin
        if plugin and plugin:refreshSegmentedPageTurn(fb, x, y, w, h, dither) then
            return
        end
        return original_refresh_partial_imp(fb, x, y, w, h, dither)
    end

    -- A page update normally paints in this same cycle.  Clearing afterwards
    -- prevents a failed or ineligible refresh from affecting a later update.
    original_after_paint = Screen.afterPaint
    Screen.afterPaint = function(fb, ...)
        local plugin = active_plugin
        if plugin then
            plugin:clearPendingPageTurn()
        end
        return original_after_paint(fb, ...)
    end
end

function SegmentedPageTurn:init()
    -- Plugin discovery happens before the framebuffer is guaranteed to be
    -- fully initialized. Check here, when a reader instance is being created.
    self.supported = has_hwtcon_backend()
    if not self.supported then
        logger.info("SegmentedPageTurn: inactive; HWTCON backend was not detected")
        return
    end
    self.update_data = ffi.new("struct hwtcon_update_data")
    self.update_data.flags = Screen.device:hasColorScreen() and HWTCON_FLAG_CFA_SKIP or 0
    self.update_data.dither_mode = 0
    active_plugin = self
    install_hooks()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    logger.info("SegmentedPageTurn: initialized; HWTCON backend detected")
end

function SegmentedPageTurn:onCloseDocument()
    self:clearPendingPageTurn()
    if active_plugin == self then
        active_plugin = nil
    end
end

function SegmentedPageTurn:addToMainMenu(menu_items)
    local page_turns = menu_items.page_turns
    if not page_turns then
        return
    end
    table.insert(page_turns.sub_item_table, {
        text = _("Page turn animations"),
        checked_func = function()
            return G_reader_settings:isTrue("swipe_animations")
        end,
        callback = function()
            G_reader_settings:flipNilOrFalse("swipe_animations")
        end,
    })
end

function SegmentedPageTurn:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_segmented_page_turn", {
        category = "none",
        event = "ToggleSegmentedPageTurn",
        title = "SegmentedPageTurn: " .. _("Toggle page turn animations"),
        reader = true,
        condition = has_hwtcon_backend()
    })
end

function SegmentedPageTurn:onToggleSegmentedPageTurn()
    G_reader_settings:flipNilOrFalse("swipe_animations")
    Notification:notify(_("Toggle page turn animations"))
end

return SegmentedPageTurn
