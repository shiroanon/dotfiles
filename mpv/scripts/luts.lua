local utils = require 'mp.utils'
local lut_dir = mp.command_native({ "expand-path", "~~/luts/" })
local files = utils.readdir(lut_dir, "files")
local luts = {}

if files then
    for _, f in ipairs(files) do
        if f:match("%.cube$") then table.insert(luts, lut_dir .. f) end
    end
end

local index = 0
function cycle_lut()
    if #luts == 0 then return mp.osd_message("No LUTs found in " .. lut_dir) end

    index = (index % #luts) + 1
    local current_lut = luts[index]

    -- Set the target-lut property directly
    mp.set_property("target-lut", current_lut)

    mp.osd_message("Target LUT: " .. current_lut:match("([^/]+)$"))
end

-- Function to clear the LUT (optional but recommended)
function clear_lut()
    mp.set_property("target-lut", "")
    mp.osd_message("LUT Cleared")
end

mp.add_key_binding(nil, "cycle-luts", cycle_lut)
mp.add_key_binding(nil, "clear-lut", clear_lut)
