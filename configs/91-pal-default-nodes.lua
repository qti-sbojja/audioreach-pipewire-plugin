-- Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
-- SPDX-License-Identifier: BSD-3-Clause
--
-- 91-pal-default-nodes.lua
--
-- Ensures a PAL sink/source is always set as the PipeWire default,
-- even when WirePlumber has no stored preference or the stored name
-- refers to a node that no longer exists.
--
-- Problem: WirePlumber picks the default node by priority.session.
-- When all PAL nodes have the same priority (0), the selection is
-- non-deterministic (last-created wins).  Additionally, a stale
-- stored default (e.g. from a previous session with a different
-- board) can leave PipeWire with no default at all.
--
-- Fix:
--   1. pw-pal-plugin.conf sets priority.session = 1010 on the
--      preferred speaker sink and mic source so WirePlumber's
--      find-best-default-node hook always picks them first.
--   2. This script watches for the "default" metadata object and,
--      if no valid default sink/source is set, explicitly writes
--      the PAL speaker sink/source as the default.

log = Log.open_topic("pal-default-nodes")

-- Preferred PAL nodes — must match node.name in pw-pal-plugin.conf.
-- These are the always-present fallback devices (speaker + mic).
local PREFERRED_SINK   = "pal_sink_speaker_ll"
local PREFERRED_SOURCE = "pal_source_speaker_mic"

-- How long to wait (ms) after metadata is ready before checking/setting
-- the default.  Gives PAL modules time to finish registering their nodes.
local SETTLE_DELAY_MS = 1500

local default_metadata = nil
local nodes_om = nil

----------------------------------------------------------------------
-- Helper: return true if node_name exists in the active node list
----------------------------------------------------------------------
local function node_exists(name)
    if not nodes_om then return false end
    local node = nodes_om:lookup {
        Constraint { "node.name", "=", name },
    }
    return node ~= nil
end

----------------------------------------------------------------------
-- Helper: read the current default sink or source name from metadata
----------------------------------------------------------------------
local function get_default(is_sink)
    if not default_metadata then return nil end
    local key = is_sink and "default.audio.sink" or "default.audio.source"
    local raw = default_metadata:find(0, key)
    if not raw then return nil end
    -- value is JSON: {"name":"..."}
    local name = tostring(raw):match('"name"%s*:%s*"([^"]+)"')
    return name
end

----------------------------------------------------------------------
-- Helper: write default sink or source to metadata
----------------------------------------------------------------------
local function set_default(is_sink, name)
    if not default_metadata then return end
    local runtime_key    = is_sink and "default.audio.sink"
                                    or "default.audio.source"
    local configured_key = is_sink and "default.configured.audio.sink"
                                    or "default.configured.audio.source"
    local v = '{"name":"' .. name .. '"}'
    local ok, err = pcall(function()
        default_metadata:set(0, runtime_key,    "Spa:String:JSON", v)
        default_metadata:set(0, configured_key, "Spa:String:JSON", v)
    end)
    if ok then
        log:info("set default " .. (is_sink and "sink" or "source")
                 .. " -> " .. name)
    else
        log:warning("failed to set default: " .. tostring(err))
    end
end

----------------------------------------------------------------------
-- Core check: run after settle delay
----------------------------------------------------------------------
local function check_and_set_defaults()
    for _, is_sink in ipairs({ true, false }) do
        local preferred = is_sink and PREFERRED_SINK or PREFERRED_SOURCE
        local label     = is_sink and "sink" or "source"

        -- Only act if the preferred node actually exists on this board
        if not node_exists(preferred) then
            log:debug("preferred " .. label .. " '" .. preferred
                      .. "' not present on this board, skipping")
            goto continue
        end

        local current = get_default(is_sink)

        -- If no default is set, or the stored name no longer exists,
        -- write the preferred node as the new default.
        if not current or not node_exists(current) then
            log:info("default " .. label .. " is '"
                     .. tostring(current)
                     .. "' (missing or unset); setting to '"
                     .. preferred .. "'")
            set_default(is_sink, preferred)
        else
            log:debug("default " .. label .. " is '" .. current
                      .. "' (valid); no change needed")
        end

        ::continue::
    end
end

----------------------------------------------------------------------
-- ObjectManager for nodes — needed by node_exists()
----------------------------------------------------------------------
nodes_om = ObjectManager {
    Interest {
        type = "node",
        Constraint { "media.class", "c",
            "Audio/Sink", "Audio/Source" },
    }
}
nodes_om:activate()

----------------------------------------------------------------------
-- ObjectManager for the "default" metadata object
----------------------------------------------------------------------
local metadata_om = ObjectManager {
    Interest {
        type = "metadata",
        Constraint { "metadata.name", "=", "default" },
    }
}

metadata_om:connect("objects-changed", function(om)
    if default_metadata then return end

    local obj = om:lookup()
    if not obj then return end

    default_metadata = obj
    log:info("default metadata ready; scheduling default-node check in "
             .. SETTLE_DELAY_MS .. " ms")

    -- Delay to let all PAL module nodes finish registering
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, SETTLE_DELAY_MS, function()
        check_and_set_defaults()
        return GLib.SOURCE_REMOVE
    end)
end)

metadata_om:activate()
