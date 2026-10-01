--[[--
@module koplugin.segmentedpageturn

Implements NickelDissolve-style page turns without changing KOReader core:
the plugin arms itself after an ordinary one-page turn, then replaces that
turn's single full-screen partial refresh with a sequence of HWTCON bands.
--]]

local ffi = require("ffi")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen
local C = ffi.C

-- Private copies of the Kobo HWTCON ABI. Keeping them in this plugin avoids
-- relying on KOReader's internal HWTCON cdefs or its recycled update object.
ffi.cdef[[
struct segmented_hwtcon_rect { unsigned int top; unsigned int left; unsigned int width; unsigned int height; };
struct segmented_hwtcon_update_data {
    struct segmented_hwtcon_rect update_region;
    unsigned int waveform_mode; unsigned int update_mode; unsigned int update_marker;
    unsigned int flags; int dither_mode;
};
]]

local HWTCON_SEND_UPDATE = 1076119086
local HWTCON_FLAG_CFA_SKIP = 32768
local HWTCON_WAVEFORM_REAGL = 4
local HWTCON_WAVEFORM_NIGHT = 9
local UPDATE_MODE_PARTIAL = 0

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

    -- Match NickelDissolve's automatic defaults.
    local strips = math.max(width, height) >= 1600 and 12 or 10
    local edges = build_band_edges(width, strips, alignment)
    self.band_edge_cache = {
        width = width,
        height = height,
        alignment = alignment,
        edges = edges,
    }
    return edges
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
    logger.info("SegmentedPageTurn: armed", forward and "forward" or "backward", "page turn")
end

function SegmentedPageTurn:refreshSegmentedPageTurn(fb, x, y, w, h, dither)
    local forward = self.pending_direction
    if forward == nil then
        return false
    end
    if not self:isEnabled() then
        logger.info("SegmentedPageTurn: discarded pending turn; animation setting is off")
        return false
    end
    if #UIManager._refresh_stack ~= 1 then
        logger.info("SegmentedPageTurn: discarded pending turn; refresh queue has", #UIManager._refresh_stack, "entries")
        return false
    end
    if dither or x ~= 0 or y ~= 0 or w ~= fb.bb:getWidth() or h ~= fb.bb:getHeight() then
        logger.info("SegmentedPageTurn: discarded pending turn; refresh is not a plain full-screen partial update")
        return false
    end

    local waveform = fb.night_mode and HWTCON_WAVEFORM_NIGHT or HWTCON_WAVEFORM_REAGL

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

        self.update_data.waveform_mode = waveform
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

        if fb:mech_wait_update_submission(marker) == -1 then
            local err = ffi.errno()
            fb.debug("HWTCON_WAIT_FOR_UPDATE_SUBMISSION ioctl failed:", ffi.string(C.strerror(err)))
            return false
        end
    end
    logger.info("SegmentedPageTurn: submitted", #edges - 1, "HWTCON bands")
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
    self.update_data = ffi.new("struct segmented_hwtcon_update_data")
    self.update_data.flags = Screen.device:hasColorScreen() and HWTCON_FLAG_CFA_SKIP or 0
    self.update_data.dither_mode = 0
    self.update_data.update_mode = UPDATE_MODE_PARTIAL
    active_plugin = self
    install_hooks()
    self.ui.menu:registerToMainMenu(self)
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

return SegmentedPageTurn
