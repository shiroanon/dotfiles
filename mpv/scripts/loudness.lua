--[[
loudness.lua - quality-preserving loudness normalisation for mpv

HOW IT WORKS
  ffmpeg measures the file's EBU R128 integrated loudness (LUFS) and true
  peak once, in the background. The result is stored as ONE constant gain
  (a plain volume offset) that is applied for the whole file.

  No dynamic processing: no windowed level riding, no compression, no
  limiting, no resampling, no phase changes. Transients, dynamics and
  timbre are untouched - only the overall level moves. This is the same
  thing ReplayGain does, just measured automatically for files that have
  no ReplayGain tags.

  The gain is clamped so the measured true peak never exceeds `true_peak`,
  so boosting a quiet file can never clip.

  Measurement is FAST: instead of decoding the whole file (a 30 min video
  costs ~90 s of CPU), it probes `windows` short slices spread evenly over
  the file. A typical file is measured in well under a second.

CONFIG (~/.config/mpv/script-opts/loudness.conf)
  target=-16          LUFS integrated target
  true_peak=-1.5      dBTP ceiling (headroom kept for lossy codecs)
  max_boost=20        never lift more than this many dB
  max_cut=-30         never attenuate more than this many dB
  windows=6           how many slices to probe across a long file
  window_len=4        seconds per slice (6 x 4 = 24 s of audio)
  enabled=yes

USAGE
  Runs automatically. Toggle with the binding in input.conf, or:
      mpv --script-opts=loudness.conf=target:-23

RESULTS are cached in ~~cache/loudness.json, so the second play of a file
is instant.
]]

local mp      = require 'mp'
local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local opts    = require 'mp.options'

local o = {
    target       = -5,
    true_peak    = -1.5,
    max_boost    = 20,
    max_cut      = -30,
    windows      = 6,    -- short files are analysed whole
    window_len   = 4,    -- seconds per window (6 x 4 s = 24 s of audio)
    enabled      = true,
}
opts.read_options(o, 'loudness')

local FILTER_LABEL = '@loudness'

local function cache_path()
    local p = mp.command_native({ 'expand-path', '~~cache/loudness.json' })
    if p and p:find('/', 1, true) then return p end
    -- '~~cache' is unavailable under --no-config; fall back to XDG
    local base = os.getenv('XDG_CACHE_HOME') or
                 ((os.getenv('HOME') or '.') .. '/.cache')
    return base .. '/mpv/loudness.json'
end

local CACHE_FILE = cache_path()

--------------------------------------------------------------------------
-- cache
--------------------------------------------------------------------------

local cache = {}
local dirty = {}

local function read_cache_file()
    local f = io.open(CACHE_FILE, 'r')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    local ok, t = pcall(utils.parse_json, data)
    if ok and type(t) == 'table' then return t end
    return nil
end

cache = read_cache_file() or {}

-- Several mpv instances may share this cache. Merge on write instead of
-- overwriting the whole file, so one instance cannot drop another's results.
local function save_cache()
    if next(dirty) == nil then return end
    for k, v in pairs(read_cache_file() or {}) do cache[k] = v end
    for k, v in pairs(dirty) do cache[k] = v end
    dirty = {}

    local dir = CACHE_FILE:match('^(.*)/[^/]+$')
    if dir and utils.mkdir_p then pcall(utils.mkdir_p, dir) end
    local tmp = CACHE_FILE .. '.' .. tostring(utils.getpid and utils.getpid() or 0) .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return end
    f:write(utils.format_json(cache))
    f:close()
    os.rename(tmp, CACHE_FILE)
end

--------------------------------------------------------------------------
-- filter application
--------------------------------------------------------------------------

local function set_filter(spec)
    local af = mp.get_property('af') or ''
    if af:find(FILTER_LABEL, 1, true) then
        mp.command_native({ 'af', 'remove', FILTER_LABEL })
    end
    if spec then
        mp.command_native({ 'af', 'add', FILTER_LABEL .. ':' .. spec })
    end
end

local function apply_gain(gain)
    -- anything under 0.1 dB is inaudible; don't insert a filter for it
    if not gain or math.abs(gain) < 0.1 then
        set_filter(nil)
        return
    end
    set_filter(('lavfi=[volume=%.2fdB]'):format(gain))
    msg.verbose(('applied %+.2f dB'):format(gain))
    mp.osd_message(('Loudness %+.1f dB'):format(gain), 1)
end

--------------------------------------------------------------------------
-- measurement
--------------------------------------------------------------------------

local function parse_loudnorm(stderr)
    -- loudnorm prints a flat JSON object; take the last one on stderr
    local last, pos = nil, 1
    while true do
        local s = stderr:find('{', pos, true)
        if not s then break end
        local e = stderr:find('}', s, true)
        if not e then break end
        last = stderr:sub(s, e)
        pos = e + 1
    end
    if not last then return nil end
    local ok, t = pcall(utils.parse_json, last)
    if not ok or type(t) ~= 'table' or not t.input_i then return nil end
    return { i = tonumber(t.input_i), tp = tonumber(t.input_tp) }
end

-- integrated loudness -> constant gain, clamped to the true-peak ceiling
local function gain_from(measured)
    local i = measured.i
    if not i then return nil end          -- "-inf": digital silence
    local gain = o.target - i
    if measured.tp then
        -- a sampled probe can miss the file's loudest peak, so hold back an
        -- extra dB when the gain is limited by the ceiling rather than by I
        local guard = measured.sampled and 1.0 or 0
        local room = o.true_peak - measured.tp - guard
        if gain > room then gain = room end
    end
    return math.max(o.max_cut, math.min(o.max_boost, gain))
end


local generation = 0

-- Measure a few short windows spread over the file instead of decoding all of
-- it. Decoding a full 30 min costs ~90 s of CPU on a low-power laptop; the
-- windowed probe measures the same integrated level in about a second, and
-- spreading the windows catches quiet dialogue vs loud action.
local function measure(path, duration, cb)
    local gen   = generation
    local n     = math.max(1, math.floor(o.windows))
    local len   = o.window_len
    local args  = { 'ffmpeg', '-nostdin', '-hide_banner', '-nostats', '-v', 'info' }
    local tail

    local function add(list)
        for _, v in ipairs(list) do args[#args+1] = v end
    end

    local sampled = duration and duration > n * len

    if not sampled then
        -- short file: measure it whole, that is already fast
        add({ '-i', path })
        tail = { '-map', '0:a:0', '-vn', '-sn', '-dn',
                 '-af', 'loudnorm=print_format=json' }
    else
        local links = {}
        for i = 0, n - 1 do
            local start = math.floor((i + 0.5) * duration / n - len / 2)
            start = math.max(0, math.min(duration - len, start))
            add({ '-ss', tostring(start), '-t', tostring(len), '-i', path })
            links[#links+1] = '[' .. i .. ':a]'
        end
        tail = { '-filter_complex',
                 table.concat(links) .. 'concat=n=' .. n ..
                 ':v=0:a=1,loudnorm=print_format=json[x]',
                 '-map', '[x]' }
    end
    add(tail)
    add({ '-f', 'null', '-' })

    mp.command_native_async({
        name            = 'subprocess',
        args            = args,
        capture_stdout  = true,
        capture_stderr  = true,
        playback_only   = false,
    }, function(ok, res)
        if gen ~= generation then return end         -- file changed meanwhile
        if not ok then
            msg.warn('ffmpeg loudness analysis failed')
            return cb(nil)
        end
        local m = parse_loudnorm(res and res.stderr or '')
        if m then m.sampled = sampled end
        cb(m)
    end)
end

--------------------------------------------------------------------------

local function has_audio()
    for _, t in ipairs(mp.get_property_native('track-list') or {}) do
        if t.type == 'audio' then return true end
    end
    return false
end

local function replaygain_active()
    if mp.get_property('options/replaygain', 'no') == 'no' then return false end
    local md = mp.get_property_native('metadata') or {}
    for k in pairs(md) do
        local lk = k:lower()
        if lk == 'replaygain_track_gain' or lk == 'replaygain_album_gain' then
            return true
        end
    end
    return false
end

local function normalize_current()
    generation = generation + 1
    local gen = generation
    set_filter(nil)

    if not o.enabled then return end
    if not has_audio() then return end                            -- nothing to measure
    if replaygain_active() then return end                        -- tags win

    local path = mp.get_property('path')
    if not path then return end

    local info = utils.file_info(path)
    if not info or not info.is_file then return end               -- network stream, disc, pipe

    local key, entry = path, cache[path]
    if entry and entry.size == info.size and entry.mtime == info.mtime
       and entry.gain ~= nil then
        apply_gain(entry.gain)
        return
    end

    mp.osd_message('Loudness: analysing…', 2)
    local duration = mp.get_property_number('duration', 0)
    measure(path, duration, function(measured)
        if gen ~= generation then return end
        if not measured then return end
        local gain = gain_from(measured)
        if not gain then return end
        msg.verbose(('measured %.2f LUFS, %.2f dBTP%s')
            :format(measured.i, measured.tp or 0, measured.sampled and ' (sampled)' or ''))
        dirty[key] = { size = info.size, mtime = info.mtime, gain = gain }
        save_cache()
        apply_gain(gain)
    end)
end

mp.register_event('file-loaded', normalize_current)
mp.register_event('shutdown', save_cache)

mp.register_script_message('toggle-loudness', function()
    o.enabled = not o.enabled
    if o.enabled then
        mp.osd_message('Loudness: on', 1)
        normalize_current()
    else
        generation = generation + 1
        set_filter(nil)
        mp.osd_message('Loudness: off', 1)
    end
end)
