-- SPDX-FileCopyrightText: 2026 Termynat0r
-- SPDX-License-Identifier: AGPL-3.0-or-later

local ffi = require("ffi")
local lfs = require("lfs")

local plugin

local function find_koreader_root()
    local path = lfs.currentdir()
    for _ = 1, 8 do
        if lfs.attributes(path .. "/base/ffi/framebuffer.lua", "mode") == "file" then
            return path
        end
        path = path .. "/.."
    end
    error("could not find the KOReader source tree")
end

local koreader_root = find_koreader_root()

local function read_file(path)
    local filename = koreader_root .. "/" .. path
    local file = assert(io.open(filename, "rb"), "missing KOReader file: " .. filename)
    local contents = file:read("*a")
    file:close()
    return contents
end

local function assert_contains(path, needle)
    assert.is_not_nil(read_file(path):find(needle, 1, true),
        string.format("KOReader compatibility contract changed: %s no longer contains %q", path, needle))
end

describe("Segmented page turns KOReader compatibility", function()
    setup(function()
        require("commonrequire")
        disable_plugins()
        plugin = dofile("plugins/segmentedpageturn.koplugin/main.lua")
    end)

    it("derives the band count from display width", function()
        local instance = plugin:new{}
        local small = instance:getBandEdges(1000, 1500, 1)
        local large = instance:getBandEdges(1600, 1000, 1)

        assert.are.equal(11, #small)
        assert.are.equal(0, small[1])
        assert.are.equal(1000, small[#small])
        assert.are.equal(16, #large)
        assert.are.equal(0, large[1])
        assert.are.equal(1600, large[#large])
    end)

    it("uses full updates with non-blocking submission waits for all page-turn bands", function()
        local instance = plugin:new{}
        local function wait_for_submission()
            return 0
        end
        local framebuffer = {
            mech_wait_update_submission = wait_for_submission,
        }

        local day = instance:getBandUpdateSettings(framebuffer)
        assert.are.equal(4, day.waveform)
        assert.are.equal(1, day.update_mode)
        assert.are.equal(wait_for_submission, day.wait_for_update)

        framebuffer.night_mode = true
        local night = instance:getBandUpdateSettings(framebuffer)
        assert.are.equal(9, night.waveform)
        assert.are.equal(1, night.update_mode)
        assert.are.equal(wait_for_submission, night.wait_for_update)
    end)

    it("keeps the reader refresh and page-update hook contracts", function()
        assert_contains("base/ffi/framebuffer.lua", "function fb:refreshPartialImp")
        assert_contains("base/ffi/framebuffer.lua", "function fb:afterPaint")
        assert_contains("frontend/ui/uimanager.lua", "_refresh_stack = {}")
        assert_contains("frontend/ui/uimanager.lua", "Screen:afterPaint()")
        assert_contains("frontend/apps/reader/modules/readerpaging.lua", "function ReaderPaging:onPageUpdate(new_page_no, orig_mode)")
    end)

    it("keeps the MTK HWTCON refresh contracts", function()
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "function framebuffer:_get_next_marker()")
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "local function kobo_mtk_wait_for_update_submission")
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "self.mech_wait_update_submission = kobo_mtk_wait_for_update_submission")
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "self.waveform_reagl = C.HWTCON_WAVEFORM_MODE_GLR16")
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "self.waveform_partial = self.waveform_reagl")
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "self.waveform_night = C.HWTCON_WAVEFORM_MODE_GLKW16")
        assert_contains("base/ffi/framebuffer_mxcfb.lua", "self.night_is_reagl = true")
    end)

    it("loads KOReader's HWTCON update ABI", function()
        require("ffi/mxcfb_kobo_h")

        assert.are.equal(1076119086, tonumber(ffi.C.HWTCON_SEND_UPDATE))
        assert.are.equal(4, tonumber(ffi.C.HWTCON_WAVEFORM_MODE_GLR16))
        assert.are.equal(9, tonumber(ffi.C.HWTCON_WAVEFORM_MODE_GLKW16))
        assert.are.equal(32768, tonumber(ffi.C.HWTCON_FLAG_CFA_SKIP))
        assert.is_not_nil(ffi.new("struct hwtcon_update_data"))
    end)
end)
