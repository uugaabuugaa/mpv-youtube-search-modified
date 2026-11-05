local input = require("mp.input")
local utils = require("mp.utils")
local msg = require("mp.msg")

--------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------

local opts = {
    use_uosc = true,
    uosc_search = true,           -- search box as a uosc popup  
    search_results_uosc = false,  -- true = search results as a uosc list instead of the grid
    yt_dlp_path = "yt-dlp",
    ffmpeg_path = "ffmpeg",
    cookie_path = "~~/cookies.txt",
    browser = "firefox",
    browser_profile = "",
    page_size = 8,
    search_key = "Ctrl+alt+s",
    feed_key = "Ctrl+alt+y",
    cache_ttl_home = 30,       -- minutes a saved Home list stays fresh (0 = off)
    cache_ttl_related = 60,   -- minutes a saved Related list stays fresh (0 = off)
    cache_ttl_search = 60,   -- minutes a saved search stays fresh (0 = off)
}

(require("mp.options")).read_options(opts, "mpv-youtube-search")

local function resolve_path(path)
    if path and path:sub(1, 3) == "~~/" then
        return mp.command_native({"expand-path", path})
    end
    return path
end

opts.yt_dlp_path = resolve_path(opts.yt_dlp_path)
opts.ffmpeg_path = resolve_path(opts.ffmpeg_path)

local THUMB_W, THUMB_H = 320, 180
local COLS = 4
local BASE_ID = 1
local EXPECTED_SIZE = THUMB_W * THUMB_H * 4
local GRID_WIDTH, GRID_HEIGHT = 1360, 900
local MAX_THUMB_CACHE_BYTES = 64 * 1024 * 1024

--------------------------------------------------------------------------
-- Feed config
--------------------------------------------------------------------------

local FEEDS = {
    {
        key = "home",
        label = "Home / Recommended",
        browse_id = "FEwhat_to_watch",
    },
    {
        key = "subscriptions",
        label = "Subscriptions",
        browse_id = "FEsubscriptions",
    },
    {
        key = "history",
        label = "Watch history",
        browse_id = "FEhistory",
    },
    {
        key = "watch_later",
        label = "Watch Later",
        playlist_url = "https://www.youtube.com/playlist?list=WL",
    },
    {
        key = "liked",
        label = "Liked videos",
        playlist_url = "https://www.youtube.com/playlist?list=LL",
    },
    {
        key = "related_all",
        label = "Related videos (All)",
        related = "all",
    },
    {
        key = "related_tab",
        label = "Related videos (Related tab)",
        related = "tab",
    },
}

local FEED_URLS_BY_KEY = {
    home = "https://www.youtube.com/feed/recommended",
    subscriptions = "https://www.youtube.com/feed/subscriptions",
    history = "https://www.youtube.com/feed/history",
    watch_later = "https://www.youtube.com/playlist?list=WL",
    liked = "https://www.youtube.com/playlist?list=LL",
}

local function get_feed_url(feed_key)
    return FEED_URLS_BY_KEY[feed_key]
end

local feed_menu_key = "Ctrl+alt+y"
local direct_feed_keys = {
    home = "Ctrl+H",
    subscriptions = "Ctrl+S",
    history = "Ctrl+R",
    watch_later = "Ctrl+W",
    liked = "Ctrl+L",
    related_all = "Ctrl+Alt+r",
    related_tab = "Ctrl+Alt+e",
}
--------------------------------------------------------------------------
-- Paths & Cookie handling
--------------------------------------------------------------------------

local is_windows = package.config:sub(1,1) == "\\"
local thumb_dir = mp.command_native({"expand-path", "~~/"}) .. "/ytsearch_bgra"
thumb_dir = thumb_dir:gsub("\\", "/")

if is_windows then
    os.execute('mkdir "' .. thumb_dir:gsub("/", "\\") .. '" 2>nul')
else
    os.execute('mkdir -p "' .. thumb_dir .. '"')
end

local temp_cookie_file = nil
local cookies_ready = false
local cookies_refresh_failed = false

local function refresh_cookies_from_browser(callback)
    local tmp_base = mp.command_native({"expand-path", "~~/"})
    tmp_base = tmp_base:gsub("\\", "/")
    local tmp_path = tmp_base .. "/ytsearch_cookies.txt"

    local browser_arg = opts.browser or "firefox"
    if opts.browser_profile and opts.browser_profile ~= "" then
        browser_arg = browser_arg .. ":" .. opts.browser_profile
    end

    local args = {
        opts.yt_dlp_path,
        "--cookies-from-browser", browser_arg,
        "--cookies", tmp_path,
        "--no-warnings",
        "--simulate",
        "--no-playlist",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    }

    msg.info("YT-Search: Refreshing cookies via yt-dlp --cookies-from-browser=" .. browser_arg)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            msg.warn("Cookie refresh failed; keeping existing cookie file if present.")

            cookies_refresh_failed = true
            cookies_ready = true

            callback(nil)
            return
        end
        temp_cookie_file = tmp_path
        msg.info("YT-Search: Refreshed cookies -> " .. tmp_path)
        cookies_ready = true
        callback(tmp_path)
    end)
end

local function get_existing_cookie_file()
    if opts.cookie_path and opts.cookie_path ~= "" then
        return resolve_path(opts.cookie_path)
    end
    local cands = {
        mp.command_native({"expand-path", "~~/cookies.txt"}),
        mp.command_native({"expand-path", "~~/yt_cookies.txt"}),
        "cookies.txt",
        "yt_cookies.txt",
    }

    for _, path in ipairs(cands) do
        local f = io.open(path, "r")
        if f then f:close() return path end
    end
    return nil
end

temp_cookie_file = get_existing_cookie_file()

if temp_cookie_file then
    msg.info("YT-Search: Using existing cookie file: " .. temp_cookie_file)
else
    msg.warn("YT-Search: No cookie file found yet.")
end

-- Keep this false until the refresh subprocess finishes.
cookies_ready = false

local page_cache = {}

local function clear_cache()
    page_cache = {}
end



--------------------------------------------------------------------------
-- Persistent disk cache (shared by all mpv instances)
--------------------------------------------------------------------------

local disk_cache_dir = mp.command_native({"expand-path", "~~/"}):gsub("\\", "/") .. "/ytsearch_cache"

if is_windows then
    os.execute('mkdir "' .. disk_cache_dir:gsub("/", "\\") .. '" 2>nul')
else
    os.execute('mkdir -p "' .. disk_cache_dir .. '"')
end

-- feed key -> minutes the saved list stays fresh. Add more feeds here,
-- e.g.  subscriptions = 15,
local feed_cache_minutes = {
    home = opts.cache_ttl_home,
    related_all = opts.cache_ttl_related,
    related_tab = opts.cache_ttl_related,
    search = opts.cache_ttl_search,
}

local force_refresh = false   -- set briefly by Ctrl+R to skip the disk cache

local KEEP_FIELDS = { "id", "title", "channel", "uploader", "duration",
                      "dur_str", "url", "ie_key", "_type", "webpage_url" }

local function disk_cache_path(feed_key, vid)
    local name = feed_key .. (vid and ("_" .. vid) or "")
    name = name:gsub("[^%w_%-]", "_")
    return disk_cache_dir .. "/" .. name .. ".json"
end

local function disk_cache_save(feed_key, vid, entries)
    if (feed_cache_minutes[feed_key] or 0) <= 0 then return end
    if type(entries) ~= "table" or #entries == 0 then return end

    local slim = {}
    for i, e in ipairs(entries) do
        local o = {}
        for _, k in ipairs(KEEP_FIELDS) do
            if e[k] ~= nil then o[k] = e[k] end
        end
        slim[i] = o
    end

    local json = utils.format_json({ ts = os.time(), entries = slim })
    if not json then return end

    local f = io.open(disk_cache_path(feed_key, vid), "wb")
    if not f then return end
    f:write(json)
    f:close()
end

-- returns entries, age_in_seconds  (or nil if missing/expired)
local function disk_cache_load(feed_key, vid)
    local minutes = feed_cache_minutes[feed_key] or 0
    if minutes <= 0 then return nil end

    local f = io.open(disk_cache_path(feed_key, vid), "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()

    local ok, data = pcall(utils.parse_json, raw)
    if not ok or type(data) ~= "table" or type(data.entries) ~= "table"
       or #data.entries == 0 then
        return nil
    end

    local age = os.time() - (tonumber(data.ts) or 0)
    if age > minutes * 60 then return nil end

    msg.info("YT-Search: disk cache hit for " .. feed_key .. " (" .. math.floor(age / 60) .. " min old)")
    return data.entries, age
end

-- delete saved lists older than 7 days (one file is saved per video for Related)
local function cleanup_disk_cache()
    local files = utils.readdir(disk_cache_dir, "files") or {}
    local cutoff = os.time() - 7 * 24 * 3600
    for _, name in ipairs(files) do
        if name:match("%.json$") then
            local path = disk_cache_dir .. "/" .. name
            local info = utils.file_info(path)
            if info and info.mtime and info.mtime < cutoff then
                os.remove(path)
            end
        end
    end
end

cleanup_disk_cache()




-- Turns a search query into a short filename-safe id.
-- Case and extra spaces are ignored ("Lo-fi  Beats" == "lo-fi beats").
local function search_cache_id(query)
    local q = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    local h1, h2 = 5381, 52711
    for i = 1, #q do
        local b = q:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 131 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end




local function cleanup_thumbnail_cache()
    local files = utils.readdir(thumb_dir, "files") or {}
    local cached = {}
    local total_size = 0

    for _, name in ipairs(files) do
        if name:match("%.bgra$") then
            local path = thumb_dir .. "/" .. name
            local info = utils.file_info(path)
            if info and info.size then
                total_size = total_size + info.size
                table.insert(cached, {
                    path = path,
                    size = info.size,
                    mtime = info.mtime or 0,
                })
            end
        end
    end

    if total_size <= MAX_THUMB_CACHE_BYTES then return end

    table.sort(cached, function(left, right)
        return left.mtime < right.mtime
    end)

    for _, file in ipairs(cached) do
        if total_size <= MAX_THUMB_CACHE_BYTES then break end
        if os.remove(file.path) then
            total_size = total_size - file.size
        end
    end
end

local function get_bgra_path(vid_id, page)
    return thumb_dir .. "/" .. tostring(vid_id) .. "_p" .. tostring(page) .. ".bgra"
end

local function get_thumb_key(vid_id, page)
    return tostring(vid_id) .. "_p" .. tostring(page)
end

--------------------------------------------------------------------------
-- InnerTube helpers (kept, but no longer used for feeds)
--------------------------------------------------------------------------

local function get_sapisid_from_cookies(cookie_file)
    if not cookie_file then
        msg.error("InnerTube: cookie_file is nil")
        return nil
    end

    local f = io.open(cookie_file, "r")
    if not f then
        msg.error("InnerTube: cannot open cookie file: " .. cookie_file)
        return nil
    end

    local sapisid = nil
    for line in f:lines() do
        if not line:match("^#") and line:match("%S") then
            local fields = {}
            for field in line:gmatch("%S+") do
                table.insert(fields, field)
            end
            if #fields >= 7 then
                local name = fields[6]
                local value = fields[7]
                if name == "SAPISID" or name == "__Secure-3PAPISID" or name == "__Secure-1PAPISID" then
                    sapisid = value
                    msg.info("InnerTube: found SAPISID-like cookie: " .. name)
                end
            end
        end
    end
    f:close()

    if not sapisid then
        msg.error("InnerTube: no SAPISID / __Secure-3PAPISID / __Secure-1PAPISID found in " .. cookie_file)
    end

    return sapisid
end

local function compute_sapisid_hash(sapisid, origin, callback)
    local now = tostring(os.time())
    local raw_str = now .. " " .. sapisid .. " " .. origin

    msg.info("InnerTube: SAPISIDHASH input: " .. raw_str)

    local cmd
    if is_windows then
        local ps_script = string.format(
            "$bytes = [System.Text.Encoding]::UTF8.GetBytes('%s'); " ..
            "$hash = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes); " ..
            "[System.BitConverter]::ToString($hash).Replace('-','').ToLower()",
            raw_str:gsub("'", "''")
        )
        cmd = { "powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script }
    else
        local escaped = raw_str:gsub("'", "'\\''")
        cmd = { "sh", "-c", "printf '%s' '" .. escaped .. "' | sha1sum | awk '{print $1}'" }
    end

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = cmd,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success then
            msg.error("InnerTube: subprocess failed for SHA1")
            callback(nil)
            return
        end
        local stdout = res.stdout or ""
        local stderr = res.stderr or ""
        local hash = stdout:gsub("%s+", "")

        if hash == "" or #hash ~= 40 then
            msg.error("InnerTube: invalid SHA1 output: stdout=" .. stdout .. " stderr=" .. stderr)
            callback(nil)
            return
        end

        msg.info("InnerTube: SAPISIDHASH = " .. hash)
        callback(now .. "_" .. hash)
    end)
end

local function find_continuation(node, depth)
    if type(node) ~= "table" then return nil end
    if (depth or 0) > 30 then return nil end

    if node.continuationCommand and node.continuationCommand.token then
        return node.continuationCommand.token
    end
    if node.continuationEndpoint and node.continuationEndpoint.continuationCommand then
        local cmd = node.continuationEndpoint.continuationCommand
        if cmd.token then return cmd.token end
    end
    if node.continuation then
        return node.continuation
    end

    local containers = {
        node.onResponseReceivedActions,
        node.onResponseReceivedEndpoints,
        node.contents,
        node.tabs,
        node.sectionListRenderer and node.sectionListRenderer.contents,
        node.itemSectionRenderer and node.itemSectionRenderer.contents,
        node.twoColumnBrowseResults and node.twoColumnBrowseResults.tabs,
        node.twoColumnBrowseResults,
        node.richGridRenderer and node.richGridRenderer.contents,
    }

    for _, container in ipairs(containers) do
        if type(container) == "table" then
            if #container > 0 then
                for _, item in ipairs(container) do
                    local t = find_continuation(item, (depth or 0) + 1)
                    if t then return t end
                end
            else
                local t = find_continuation(container, (depth or 0) + 1)
                if t then return t end
            end
        end
    end

    for _, v in pairs(node) do
        if type(v) == "table" then
            local t = find_continuation(v, (depth or 0) + 1)
            if t then return t end
        end
    end

    return nil
end

local function fetch_innertube_feed(browse_id, continuation_token, callback)
    -- No longer used for feeds; kept if you want to experiment later.
    msg.warn("InnerTube fetch called but disabled for feeds.")
    callback({}, nil)
end

--------------------------------------------------------------------------
-- State & UI
--------------------------------------------------------------------------

local ov_ass = mp.create_osd_overlay("ass-events")

local state = {
    active = false,
    mode = "search",
    query = nil,
    page = 1,
    results = {},
    raw_entries = {},
    cursor = 1,
    fetching = false,
    thumbnail_status = {},
    saved_geometry = nil,
    feedback = nil,
    feedback_timer = nil,
    continuation = nil,
}

local feedback_ass = mp.create_osd_overlay("ass-events")

local function clear_feedback()
    feedback_ass:remove()
end

local function show_standalone_feedback(text, seconds)
    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720

    feedback_ass.res_x = osd_w
    feedback_ass.res_y = osd_h
    feedback_ass.data = string.format(
        "{\\an5\\pos(%d,%d)}" ..
        "{\\fs30\\b1\\1c&000000&\\3c&FCBCCD&\\bord3}" ..
        "%s",
        math.floor(osd_w / 2),
        math.floor(osd_h / 2),
        tostring(text):gsub("{", "\\{"):gsub("}", "\\}")
    )
    feedback_ass:update()

    mp.add_timeout(seconds or 3, function()
        feedback_ass:remove()
    end)
end

local shown_overlays = {}   -- slot -> "x,y,path" of what is currently displayed

local function clear_overlays()
    for i = 1, opts.page_size do
        mp.commandv("overlay-remove", BASE_ID + i)
    end
    shown_overlays = {}
end

local function resize_for_grid()
    if state.saved_geometry or mp.get_property_bool("fullscreen", false)
    or mp.get_property_bool("window-maximized", false) then
        return
    end

    local window_width = mp.get_property_number("osd-width") or mp.get_property_number("window-width")
    local window_height = mp.get_property_number("osd-height") or mp.get_property_number("window-height")
    if window_width and window_height and window_width >= GRID_WIDTH and window_height >= GRID_HEIGHT then
        return
    end

    local target_width = math.max(GRID_WIDTH, window_width or GRID_WIDTH)
    local target_height = math.max(GRID_HEIGHT, window_height or GRID_HEIGHT)
    state.saved_geometry = mp.get_property("geometry") or ""
    mp.set_property("geometry", target_width .. "x" .. target_height)
end

local function restore_window()
    if state.saved_geometry then
        mp.set_property("geometry", state.saved_geometry)
        state.saved_geometry = nil
    end
end


-- Hide uosc elements only while the grid is open (uosc's own settings are untouched)
local UOSC_HIDE = "pause_indicator,buffering_indicator,idle_indicator"

local function hide_uosc_elements()
    mp.commandv("script-message-to", "uosc", "disable-elements", mp.get_script_name(), UOSC_HIDE)
end

local function show_uosc_elements()
    mp.commandv("script-message-to", "uosc", "disable-elements", mp.get_script_name(), "")
end




local function show_feedback(text)
    state.feedback = text
    if state.feedback_timer then state.feedback_timer:kill() end
    state.feedback_timer = mp.add_timeout(2.5, function()
        state.feedback = nil
        state.feedback_timer = nil
        if state.active then draw_grid() end
    end)
    draw_grid()
end

local function escape_ass(str)
    if not str then return "" end
    return str:gsub("{", "\\{"):gsub("}", "\\}")
end

local function fmt_duration(sec)
    if not sec then return "" end
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function entry_url(entry)
    if entry.url and entry.url:match("^https?://") then
        return entry.url
    end

    if entry.id then
        -- Force RD* (mix/radio) IDs to be treated as single videos
        if entry.id:find("^RD") then
            return "https://www.youtube.com/watch?v=" .. entry.id
        end

        if entry.ie_key == "YoutubePlaylist" or entry._type == "playlist" then
            return "https://www.youtube.com/playlist?list=" .. entry.id
        end

        return "https://www.youtube.com/watch?v=" .. entry.id
    end

    return entry.webpage_url or entry.url
end

--------------------------------------------------------------------------
-- Thumbnails
--------------------------------------------------------------------------



local ROUND_CORNERS = true
local CORNER_RADIUS = 14

local thumb_filter
if ROUND_CORNERS then
    local r = CORNER_RADIUS
    local m = string.format(
        "if(gt(abs(W/2-X),W/2-%d)*gt(abs(H/2-Y),H/2-%d),clip(%d-hypot(%d-(W/2-abs(W/2-X)),%d-(H/2-abs(H/2-Y)))+0.5,0,1),1)",
        r, r, r, r, r)
    thumb_filter = string.format(
        "scale=%d:%d,format=gbrap,geq=r='r(X,Y)*(%s)':g='g(X,Y)*(%s)':b='b(X,Y)*(%s)':a='255*(%s)',format=bgra",
        THUMB_W, THUMB_H, m, m, m, m)
else
    thumb_filter = "scale=" .. THUMB_W .. ":" .. THUMB_H
end



local function fetch_thumbnail(vid_id, page)
    if not vid_id or not page then return end
    local out_file = get_bgra_path(vid_id, page)

    local f = io.open(out_file, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size >= EXPECTED_SIZE then
            state.thumbnail_status[get_thumb_key(vid_id, page)] = "ready"
            if state.active and state.page == page then draw_grid() end
            return
        end
    end

    state.thumbnail_status[get_thumb_key(vid_id, page)] = "loading"

    local thumb_base = thumb_dir .. "/" .. tostring(vid_id) .. "_p" .. tostring(page)
    local thumb_jpg = thumb_base .. ".jpg"

    local img_url = "https://i.ytimg.com/vi/" .. vid_id .. "/mqdefault.jpg"
    local curl_args = { "curl", "-s", "-L", "-o", thumb_jpg, img_url }

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
        args = curl_args,
    }, function(success, res)
        if not success or not res or res.status ~= 0 then
            state.thumbnail_status[get_thumb_key(vid_id, page)] = "failed"
            if state.active and state.page == page then draw_grid() end
            return
        end

        local ffmpeg_args = {
            opts.ffmpeg_path,
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", thumb_jpg,
            "-vf", thumb_filter,
            "-f", "rawvideo", "-pix_fmt", "bgra", out_file,
        }

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = false,
            capture_stderr = true,
            args = ffmpeg_args,
        }, function(ffmpeg_success, ffmpeg_res)
            os.remove(thumb_jpg)
            if not ffmpeg_success or not ffmpeg_res or ffmpeg_res.status ~= 0 then
                state.thumbnail_status[get_thumb_key(vid_id, page)] = "failed"
                if state.active and state.page == page then draw_grid() end
            elseif state.active and state.page == page then
                state.thumbnail_status[get_thumb_key(vid_id, page)] = "ready"
                draw_grid()
            else
                state.thumbnail_status[get_thumb_key(vid_id, page)] = "ready"
            end
        end)
    end)
end

--------------------------------------------------------------------------
-- Grid rendering(edited)
--------------------------------------------------------------------------

local function wrap_title(title, max_chars, max_lines)
    local lines, cur = {}, ""
    for word in title:gmatch("%S+") do
        if cur ~= "" and #cur + #word + 1 > max_chars then
            table.insert(lines, cur)
            cur = word
        else
            cur = (cur == "") and word or (cur .. " " .. word)
        end
    end
    if cur ~= "" then table.insert(lines, cur) end

    if #lines > max_lines then
        local trimmed = {}
        for i = 1, max_lines do trimmed[i] = lines[i] end
        trimmed[max_lines] = trimmed[max_lines]:sub(1, max_chars - 3) .. "..."
        lines = trimmed
    end
    return table.concat(lines, "\\N")  -- ASS line break
end





-- ASS path for a rounded rectangle (w x h, corner radius r)
local function rounded_path(w, h, r)
    local k = r * 0.5523
    local p = {
        string.format("m %.1f 0", r),
        string.format("l %.1f 0", w - r),
        string.format("b %.1f 0 %.1f %.1f %.1f %.1f", w - r + k, w, r - k, w, r),
        string.format("l %.1f %.1f", w, h - r),
        string.format("b %.1f %.1f %.1f %.1f %.1f %.1f", w, h - r + k, w - r + k, h, w - r, h),
        string.format("l %.1f %.1f", r, h),
        string.format("b %.1f %.1f %.1f %.1f %.1f %.1f", r - k, h, 0, h - r + k, 0, h - r),
        string.format("l 0 %.1f", r),
        string.format("b 0 %.1f %.1f 0 %.1f 0", r - k, r - k, r),
    }
    return table.concat(p, " ")
end




function draw_grid()
    if not state.active then return end

    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720

    ov_ass.res_x = osd_w
    ov_ass.res_y = osd_h

    local PAD_X = math.floor((osd_w - (COLS * THUMB_W)) / (COLS + 1))
    if PAD_X < 10 then PAD_X = 10 end
    local START_X = PAD_X

    local PAD_Y = 100
    local TOTAL_H = (2 * THUMB_H) + PAD_Y
    local START_Y = math.floor((osd_h - TOTAL_H) / 2) + 10

    local ass = string.format("{\\an7\\pos(0,0)}{\\1a&H15&}{\\1c&H000000&}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}\n", osd_w, osd_w, osd_h, osd_h)

    local head_y = math.max(10, START_Y - 70)

    local title_text
    if state.mode == "search" then
        title_text = "⌕ Search: " .. escape_ass(state.query)
    else
        local feed_label = "Feed"
        for _, f in ipairs(FEEDS) do
            if f.key == state.query then
                feed_label = f.label
                break
            end
        end
        title_text = "📺 " .. feed_label
    end

    ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\fs40\\b1\\1a&H00&\\1c&FCBCCD&}%s (Page %d){\\b0}\n", START_X, head_y, title_text, state.page)

    if state.feedback then
        ass = ass .. string.format("{\\an8\\pos(%d,55)}{\\fs24\\b1\\1c&000000&\\3c&FCBCCD&\\bord3} %s {\\b0}\n", osd_w / 2, escape_ass(state.feedback))
    end

    

    for i = 1, math.min(#state.results, opts.page_size) do
        local e = state.results[i]
        local col = (i - 1) % COLS
        local row = math.floor((i - 1) / COLS)

        local x = START_X + col * (THUMB_W + PAD_X)
        local y = START_Y + row * (THUMB_H + PAD_Y)

        local has_image = false
        if e.id then
            local bgra_path = get_bgra_path(e.id, state.page)
            local f = io.open(bgra_path, "r")
            if f then
                local size = f:seek("end")
                f:close()
                if size and size >= EXPECTED_SIZE then
                    local sig = math.floor(x) .. "," .. math.floor(y) .. "," .. bgra_path
                    if shown_overlays[i] ~= sig then
                        mp.commandv("overlay-add", BASE_ID + i, math.floor(x), math.floor(y), bgra_path, 0, "bgra", THUMB_W, THUMB_H, THUMB_W * 4)
                        shown_overlays[i] = sig
                    end
                    has_image = true
                end
            end
        end

        if not has_image then
                if shown_overlays[i] then
                mp.commandv("overlay-remove", BASE_ID + i)
                shown_overlays[i] = nil
            end
            local thumb_status = e.id and state.thumbnail_status[get_thumb_key(e.id, state.page)] or "failed"
            local placeholder = thumb_status == "loading" and "Loading..." or "No Image"
            ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\1a&H00&}{\\1c&H222222&}{\\p1}%s{\\p0}\n", x, y, rounded_path(THUMB_W, THUMB_H, CORNER_RADIUS))
            ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\fs26\\1c&H777777&}%s\n", x + (THUMB_W/2) - 45, y + (THUMB_H/2) - 15, placeholder)
        end

        -- solid black box behind the title + channel text
        ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\1a&H00&\\1c&H000000&\\bord0\\shad0}{\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}\n", x, y + THUMB_H + 4, THUMB_W, THUMB_W, 80, 80)

        local title = escape_ass(wrap_title(e.title or "(no title)", 38, 2)) --edited

        local clip_tag = string.format("\\clip(%d,%d,%d,%d)", x, 0, x + THUMB_W - 5, osd_h)
        ass = ass .. string.format("{\\an7\\pos(%d,%d)%s}{\\fs18\\b1\\1a&H00&\\1c&FCBCCD&}%s\n", x, y + THUMB_H + 10, clip_tag, title)

        local channel = e.channel or e.uploader or ""
        if #channel > 20 then channel = channel:sub(1, 17) .. "..." end
        channel = escape_ass(channel)

        local dur = e.dur_str or (e.duration and e.duration > 0 and fmt_duration(e.duration)) or "VIDEO"
        ass = ass .. string.format("{\\an7\\pos(%d,%d)%s}{\\fs14\\b0\\1c&F0DCF5&}👤 %s | ⏱ %s\n", x, y + THUMB_H + 55, clip_tag, channel, dur) --edited

        if i == state.cursor then
            local bx, by = x - 4, y - 4
            local bw, bh = THUMB_W + 8, THUMB_H + 8
            ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\3c&FCBCCD&}{\\bord4}{\\1a&HFF&}{\\p1}%s{\\p0}\n", bx, by, rounded_path(bw, bh, CORNER_RADIUS + 4))
        end
    end



    for i = math.min(#state.results, opts.page_size) + 1, opts.page_size do
        if shown_overlays[i] then
            mp.commandv("overlay-remove", BASE_ID + i)
            shown_overlays[i] = nil
        end
    end



    local footer_y = START_Y + (2 * (THUMB_H + PAD_Y)) - 15
    ass = ass .. string.format("{\\an7\\pos(%d,%d)}{\\fs18\\1a&H00&\\1c&F0DCF5&}⌨ [Arrows] Navigate [Enter] Play [Shift+Enter] Append [N] Next Page [P] Prev Page [Ctrl+R] Refresh [ESC] Close\n", START_X, footer_y)

    ov_ass.data = ass
    ov_ass:update()
end

--------------------------------------------------------------------------
-- Navigation & control
--------------------------------------------------------------------------

local function close_grid()
    state.active = false
    state.pending_cursor = nil
    ov_ass:remove()
    clear_overlays()
    if state.feedback_timer then state.feedback_timer:kill() end
    state.feedback = nil
    state.feedback_timer = nil
    restore_window()
    show_uosc_elements()
    mp.remove_key_binding("grid-up")
    mp.remove_key_binding("grid-down")
    mp.remove_key_binding("grid-left")
    mp.remove_key_binding("grid-right")
    mp.remove_key_binding("grid-enter")
    mp.remove_key_binding("grid-append")
    mp.remove_key_binding("grid-esc")
    mp.remove_key_binding("grid-next")
    mp.remove_key_binding("grid-prev")
    mp.remove_key_binding("grid-refresh")
end

local function move_cursor(dx, dy)
    local idx = state.cursor - 1
    local col = idx % COLS
    local row = math.floor(idx / COLS)

    col = (col + dx) % COLS

    local max_rows = math.ceil(#state.results / COLS)
    if max_rows == 0 then return end
    row = (row + dy) % max_rows

    local new_idx = row * COLS + col + 1
    if new_idx > #state.results then
        new_idx = #state.results
    end

    state.cursor = new_idx
    draw_grid()
end

local function execute_selection(append)
    local e = state.results[state.cursor]
    if not e then return end

    local url = entry_url(e)
    if append then
        mp.commandv("loadfile", url, "append-play")
        show_feedback("Added to playlist: " .. (e.title or url))
    else
        mp.commandv("loadfile", url, "replace")
        close_grid()
    end
end

local fetch_and_render
local open_uosc_results

local function bind_keys()
    mp.add_forced_key_binding("UP", "grid-up", function() move_cursor(0, -1) end)
    mp.add_forced_key_binding("DOWN", "grid-down", function() move_cursor(0, 1) end)

       mp.add_forced_key_binding("LEFT", "grid-left", function()
        if state.cursor > 1 then
            state.cursor = state.cursor - 1
            draw_grid()
        elseif state.page > 1 then
            -- first video on the page: go back a page, landing on its last video
            state.pending_cursor = "last"
            fetch_and_render(state.mode, state.query, state.page - 1)
        end
    end)

    mp.add_forced_key_binding("RIGHT", "grid-right", function()
        if state.cursor < #state.results then
            state.cursor = state.cursor + 1
            draw_grid()
        elseif state.page * opts.page_size < #state.raw_entries then
            -- last video on the page: go to the next page
            fetch_and_render(state.mode, state.query, state.page + 1)
        else
            show_feedback("Last page")
        end
    end)
    
    
    mp.add_forced_key_binding("ENTER", "grid-enter", function() execute_selection(false) end)
    mp.add_forced_key_binding("Shift+ENTER", "grid-append", function() execute_selection(true) end)
    mp.add_forced_key_binding("ESC", "grid-esc", close_grid)
    
    
    
        mp.add_forced_key_binding("Ctrl+r", "grid-refresh", function()
        if not state.active or state.fetching then return end
        clear_cache()
        force_refresh = true
        fetch_and_render(state.mode, state.query, 1)
        force_refresh = false
    end)
    
    
    

    mp.add_forced_key_binding("n", "grid-next", function()
        if not state.active then return end
        state.page = state.page + 1
        fetch_and_render(state.mode, state.query, state.page)
    end)
    mp.add_forced_key_binding("p", "grid-prev", function()
        if not state.active then return end
        if state.page > 1 then
            state.page = state.page - 1
            fetch_and_render(state.mode, state.query, state.page)
        end
    end)
end

--------------------------------------------------------------------------
-- Feed menu
--------------------------------------------------------------------------

local feed_menu = {
    active = false,
    index = 1,
    ass = mp.create_osd_overlay("ass-events"),
}

local function close_feed_menu()
    if not feed_menu.active then return end
    feed_menu.active = false
    feed_menu.ass:remove()
    if not state.active then
        mp.remove_key_binding("feed-menu-up")
        mp.remove_key_binding("feed-menu-down")
        mp.remove_key_binding("feed-menu-select")
        mp.remove_key_binding("feed-menu-esc")
    end
end

local function render_feed_menu()
    if not feed_menu.active then return end

    local osd_w = mp.get_property_number("osd-width") or 1280
    local osd_h = mp.get_property_number("osd-height") or 720

    feed_menu.ass.res_x = osd_w
    feed_menu.ass.res_y = osd_h

    local box_w = 500
    local box_h = 40 + (#FEEDS * 40) + 60
    local box_x = math.floor((osd_w - box_w) / 2)
    local box_y = math.floor((osd_h - box_h) / 2)

    local ass = string.format(
        "{\\an7\\pos(%d,%d)}{\\1a&H00&\\1c&H101010&\\3a&H40&\\3c&H404040&\\bord1}{\\p1}" ..
        "m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
        box_x, box_y, box_w, box_w, box_h, box_h
    )

    ass = ass .. string.format(
        "{\\an7\\pos(%d,%d)}{\\fs32\\b1\\1a&H00&\\1c&HFFFFFF&}YouTube feeds{\\b0}\n",
        box_x + 20, box_y + 15
    )

    for i, feed in ipairs(FEEDS) do
        local marker = (i == feed_menu.index) and "▶ " or "  "
        local color = (i == feed_menu.index) and "&H00FFFF&" or "&HCCCCCC&"
        ass = ass .. string.format(
            "{\\an7\\pos(%d,%d)}{\\fs22\\1a&H00&\\1c&H%s&}%s%d  %s\n",
            box_x + 20,
            box_y + 55 + (i - 1) * 40,
            color,
            marker,
            i,
            feed.label
        )
    end

    ass = ass .. string.format(
        "{\\an7\\pos(%d,%d)}{\\fs16\\1a&H00&\\1c&H888888&}" ..
        "↑/↓ or j/k: select  Enter: open  Esc: close\n",
        box_x + 20,
        box_y + box_h - 35
    )

    feed_menu.ass.data = ass
    feed_menu.ass:update()
end

local function feed_menu_up()
    if not feed_menu.active then return end
    feed_menu.index = feed_menu.index - 1
    if feed_menu.index < 1 then
        feed_menu.index = #FEEDS
    end
    render_feed_menu()
end

local function feed_menu_down()
    if not feed_menu.active then return end
    feed_menu.index = feed_menu.index + 1
    if feed_menu.index > #FEEDS then
        feed_menu.index = 1
    end
    render_feed_menu()
end

local function show_cookies_not_ready_feedback()
    if cookies_ready then
        return
    end

    show_standalone_feedback(
        "Refreshing YouTube cookies...\nPlease wait.",
        4
    )
end

local function feed_menu_select()
    if not feed_menu.active then return end

    local feed = FEEDS[feed_menu.index]
    if not feed then return end

    if not cookies_ready then
        show_cookies_not_ready_feedback()
        return
    end

    close_feed_menu()

    clear_cache()
    cleanup_thumbnail_cache()
    resize_for_grid()

    fetch_and_render("feed", feed.key, 1)
end

local function open_feed_menu()
    if state.active then
        close_grid()
        return
    end

    feed_menu.active = true
    feed_menu.index = 1

    mp.add_forced_key_binding("UP", "feed-menu-up", feed_menu_up)
    mp.add_forced_key_binding("DOWN", "feed-menu-down", feed_menu_down)
    mp.add_forced_key_binding("j", "feed-menu-down-j", feed_menu_down)
    mp.add_forced_key_binding("k", "feed-menu-up-k", feed_menu_up)
    mp.add_forced_key_binding("ENTER", "feed-menu-select", feed_menu_select)
    mp.add_forced_key_binding("ESC", "feed-menu-esc", close_feed_menu)

    render_feed_menu()
end

--------------------------------------------------------------------------
-- Direct feed keys
--------------------------------------------------------------------------

local function open_feed_direct(feed_key)
    if state.active or feed_menu.active then
        return
    end

    if not cookies_ready then
        show_cookies_not_ready_feedback()
        return
    end

    clear_cache()
    cleanup_thumbnail_cache()
    resize_for_grid()
    fetch_and_render("feed", feed_key, 1)
end

local function register_direct_feed_keys()
    for _, feed in ipairs(FEEDS) do
        local key = direct_feed_keys[feed.key]
        if key then
            mp.add_key_binding(key, "feed-direct-" .. feed.key, function()
                open_feed_direct(feed.key)
            end)
        end
    end
end


--------------------------------------------------------------------------
-- Related videos (watch-page scrape, uses cookies) (edited)
--------------------------------------------------------------------------

local function current_video_id()
    for _, prop in ipairs({ "path", "stream-open-filename", "filename" }) do
        local s = mp.get_property(prop) or ""
        local id = s:match("[?&]v=([%w_-]+)")
            or s:match("youtu%.be/([%w_-]+)")
            or s:match("/shorts/([%w_-]+)")
        if id and #id == 11 then return id end
    end
    return nil
end

local function dig(t, ...)
    for _, k in ipairs({ ... }) do
        if type(t) ~= "table" then return nil end
        t = t[k]
    end
    return t
end

-- Cut one balanced {...} object out of a big string (respects JSON strings)
local function extract_json_object(s, start)
    local depth, i = 0, start
    while true do
        local p = s:find('[{}"]', i)
        if not p then return nil end
        local c = s:sub(p, p)
        if c == '"' then
            local j = p + 1
            while true do
                local q = s:find('["\\]', j)
                if not q then return nil end
                if s:sub(q, q) == "\\" then
                    j = q + 2
                else
                    j = q + 1
                    break
                end
            end
            i = j
        elseif c == "{" then
            depth = depth + 1
            i = p + 1
        else
            depth = depth - 1
            if depth == 0 then return s:sub(start, p) end
            i = p + 1
        end
    end
end

local function add_related(out, seen, id, title, channel, dur_str)
    if not id or #id ~= 11 or seen[id] then return end
    seen[id] = true
    table.insert(out, {
        id = id,
        title = title or "(no title)",
        channel = channel or "",
        dur_str = dur_str,
    })
end

local function walk_related(node, out, seen, depth)
    if type(node) ~= "table" or depth > 40 then return end

    -- Older layout
    local vr = node.compactVideoRenderer
    if type(vr) == "table" and vr.videoId then
        local title = dig(vr, "title", "simpleText") or dig(vr, "title", "runs", 1, "text")
        local channel = dig(vr, "longBylineText", "runs", 1, "text")
            or dig(vr, "shortBylineText", "runs", 1, "text")
        add_related(out, seen, vr.videoId, title, channel, dig(vr, "lengthText", "simpleText"))
        return
    end

    -- Newer layout
    local lv = node.lockupViewModel
    if type(lv) == "table" and lv.contentId then
        if lv.contentType == "LOCKUP_CONTENT_TYPE_VIDEO" then
            local meta = dig(lv, "metadata", "lockupMetadataViewModel")
            local title = dig(meta, "title", "content")
            local channel = dig(meta, "metadata", "contentMetadataViewModel",
                "metadataRows", 1, "metadataParts", 1, "text", "content")

            local dur
            local overlays = dig(lv, "contentImage", "thumbnailViewModel", "overlays")
            if type(overlays) == "table" then
                for _, ov in ipairs(overlays) do
                    local badges = dig(ov, "thumbnailBottomOverlayViewModel", "badges")
                    if type(badges) == "table" then
                        for _, b in ipairs(badges) do
                            local txt = dig(b, "thumbnailBadgeViewModel", "text")
                            if txt then dur = txt break end
                        end
                    end
                    if dur then break end
                end
            end
            add_related(out, seen, lv.contentId, title, channel, dur)
        end
        return
    end

    if #node > 0 then
        for _, v in ipairs(node) do walk_related(v, out, seen, depth + 1) end
    else
        for _, v in pairs(node) do walk_related(v, out, seen, depth + 1) end
    end
end




-- Token that loads "more" items at the end of a list (not the chip tokens)
local CONT_ITEM_PATTERN = '"continuationItemRenderer":%s*{.-"token":%s*"([^"]+)"'

local function find_token(node, depth)
    if type(node) ~= "table" or depth > 12 then return nil end
    local cc = node.continuationCommand
    if type(cc) == "table" and cc.token then return cc.token end
    for _, v in pairs(node) do
        local t = find_token(v, depth + 1)
        if t then return t end
    end
    return nil
end

-- Returns the continuation token of the "Related" chip, or nil if absent
local function find_related_chip(node, depth)
    depth = depth or 0
    if type(node) ~= "table" or depth > 40 then return nil end

    local chip = node.chipCloudChipRenderer or node.chipViewModel
    if type(chip) == "table" then
        local label = dig(chip, "text", "simpleText")
            or dig(chip, "text", "content")
            or dig(chip, "text", "runs", 1, "text")
            or (type(chip.text) == "string" and chip.text)
        if label and label:lower() == "related" then
            return find_token(chip, 0)
        end
        return nil
    end

    for _, v in pairs(node) do
        local t = find_related_chip(v, depth + 1)
        if t then return t end
    end
    return nil
end

local function post_next(token, client_version, callback)
    local body = utils.format_json({
        context = { client = { clientName = "WEB", clientVersion = client_version, hl = "en" } },
        continuation = token,
    })
    local args = {
        "curl", "-s", "-L", "--compressed", "-X", "POST",
        "-A", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
        "-H", "Content-Type: application/json",
        "-H", "Origin: https://www.youtube.com",
    }
    if temp_cookie_file then
        table.insert(args, "-b")
        table.insert(args, temp_cookie_file)
    end
    table.insert(args, "--data")
    table.insert(args, body)
    table.insert(args, "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            callback(nil)
        else
            callback(res.stdout)
        end
    end)
end



local RELATED_EXTRA_PAGES = 2   -- each extra page is roughly 15-20 more videos

local TOKEN_PATTERN = '"continuationCommand":%s*{%s*"token":%s*"([^"]+)"'

local function fetch_more(token, client_version, out, seen, pages_left, done)
    if not token or pages_left <= 0 then
        done()
        return
    end

    local body = utils.format_json({
        context = { client = { clientName = "WEB", clientVersion = client_version, hl = "en" } },
        continuation = token,
    })

    local args = {
        "curl", "-s", "-L", "--compressed",
        "-X", "POST",
        "-A", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
        "-H", "Content-Type: application/json",
        "-H", "Origin: https://www.youtube.com",
    }
    if temp_cookie_file then
        table.insert(args, "-b")
        table.insert(args, temp_cookie_file)
    end
    table.insert(args, "--data")
    table.insert(args, body)
    table.insert(args, "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.warn("related: continuation request failed")
            done()
            return
        end

        local ok, data = pcall(utils.parse_json, res.stdout)
        if ok and type(data) == "table" then
            walk_related(data, out, seen, 0)
        else
            msg.warn("related: continuation parse failed")
            done()
            return
        end

        local next_token = res.stdout:match(CONT_ITEM_PATTERN)
        fetch_more(next_token, client_version, out, seen, pages_left - 1, done)
    end)
end



local function fetch_related(vid, source, callback)
    local args = {
        "curl", "-s", "-L", "--compressed",
        "-A", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
        "-H", "Accept-Language: en-US,en;q=0.9",
    }
    if temp_cookie_file then
        table.insert(args, "-b")
        table.insert(args, temp_cookie_file)
    end
    table.insert(args, "https://www.youtube.com/watch?v=" .. vid)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res)
        if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.error("related: curl failed: " .. tostring(res and res.status)
                .. " " .. tostring(res and res.stderr))
            callback(nil, "Request failed (is curl in PATH?)")
            return
        end

        local html = res.stdout
        local k = html:find('"secondaryResults":{', 1, true)
        if not k then
            if html:find("consent.youtube.com", 1, true) then
                callback(nil, "YouTube consent page (cookies not accepted)")
            else
                callback(nil, "No related-video data in page")
            end
            return
        end

        local chunk = extract_json_object(html, html:find("{", k, true))
        if not chunk then
            callback(nil, "Could not extract related data")
            return
        end

        local ok, data = pcall(utils.parse_json, chunk)
        if not ok or type(data) ~= "table" then
            msg.error("related: parse_json failed on " .. #chunk .. " bytes")
            callback(nil, "JSON parse failed")
            return
        end

                local out, seen = {}, { [vid] = true }
        walk_related(data, out, seen, 0)

                        local version = html:match('"INNERTUBE_CONTEXT_CLIENT_VERSION":"([^"]+)"')
            or "2.20250101.00.00"

        local MIN_RESULTS = 60     -- target size when topping up from "All"
        local TAB_TOPUP = false    -- true = fill a short Related-tab list from All

        local all_token = chunk:match(CONT_ITEM_PATTERN)

        local function top_up(list)
            local have = { [vid] = true }
            for _, e in ipairs(list) do have[e.id] = true end
            for _, e in ipairs(out) do
                if #list >= MIN_RESULTS then break end
                if not have[e.id] then
                    table.insert(list, e)
                    have[e.id] = true
                end
            end
            msg.info("related: topped up to " .. #list .. " videos with All results")
        end

        local function finish(list, token, topup)
            local function done()
                if topup and #list < MIN_RESULTS then
                    if all_token then
                        local s = { [vid] = true }
                        for _, e in ipairs(out) do s[e.id] = true end
                        fetch_more(all_token, version, out, s, RELATED_EXTRA_PAGES, function()
                            top_up(list)
                            callback(list, nil)
                        end)
                        return
                    end
                    top_up(list)
                end
                callback(list, nil)
            end

            if token then
                local s = { [vid] = true }
                for _, e in ipairs(list) do s[e.id] = true end
                fetch_more(token, version, list, s, RELATED_EXTRA_PAGES, done)
            else
                done()
            end
        end

        -- Option 1: All tab only
        if source ~= "tab" then
            msg.info("related: using All tab (" .. #out .. " videos in first batch)")
            finish(out, all_token, false)
            return
        end

        -- Option 2: Related chip (falls back to All)
        local chip_token = find_related_chip(data)

        if not chip_token then
            msg.info("related: no 'Related' chip found, using All (" .. #out .. " videos)")
            finish(out, all_token, false)
            return
        end

        post_next(chip_token, version, function(body)
            local rel, rseen = {}, { [vid] = true }
            local rtoken = nil
            if body then
                local ok2, rdata = pcall(utils.parse_json, body)
                if ok2 and type(rdata) == "table" then
                    walk_related(rdata, rel, rseen, 0)
                end
                rtoken = body:match(CONT_ITEM_PATTERN)
            end

            if #rel > 0 then
                msg.info("related: using 'Related' tab (" .. #rel .. " videos)")
                finish(rel, rtoken, TAB_TOPUP)
            else
                msg.warn("related: 'Related' tab request gave nothing, falling back to All")
                finish(out, all_token, false)
            end
        end)
    end)
end


--------------------------------------------------------------------------
-- Main fetch_and_render
--------------------------------------------------------------------------

function fetch_and_render(mode, query, page)
    if state.fetching then return end

    local cache_key = mode .. ":" .. tostring(query)

    local function render_page_from_entries(all_entries)
    
        if mode == "search" and opts.search_results_uosc and open_uosc_results then
            open_uosc_results(all_entries, query)
            return
        end
        state.raw_entries = all_entries
        local start_idx = (page - 1) * opts.page_size + 1
        local end_idx = math.min(page * opts.page_size, #all_entries)

        local page_results = {}
        for i = start_idx, end_idx do
            table.insert(page_results, all_entries[i])
        end

        state.results = page_results
        state.mode = mode
        state.query = query
        state.page = page
        state.cursor = 1

                if state.pending_cursor == "last" then
            state.cursor = math.max(1, #page_results)
        end
        
        state.pending_cursor = nil
        state.active = true
        hide_uosc_elements()

        clear_overlays()
        bind_keys()
        draw_grid()

        for _, e in ipairs(state.results) do
            if e.id then
                fetch_thumbnail(e.id, state.page)
            end
        end
    end

    -- Feed mode: all feeds via yt-dlp + cookies
    if mode == "feed" then
        local feed_def = nil
        for _, f in ipairs(FEEDS) do
            if f.key == query then
                feed_def = f
                break
            end
        end

        if not feed_def then
            msg.error("YT-Search: Unknown feed key: " .. tostring(query))
            show_feedback("Unknown feed: " .. tostring(query))
            return
        end


        if feed_def.related then
            if page_cache[cache_key] then
                local cached = page_cache[cache_key]
                if (page - 1) * opts.page_size + 1 <= #cached then
                    render_page_from_entries(cached)
                else
                    state.page = math.max(1, page - 1)
                    show_feedback("No more related videos")
                end
                return
            end

            local vid = current_video_id()
            if not vid then
                restore_window()
                show_standalone_feedback("Related videos: current file is not a YouTube video", 3)
                return
            end
            
            
            
            if not force_refresh then
                local cached, age = disk_cache_load(feed_def.key, vid)
                if cached then
                    page_cache[cache_key] = cached
                    render_page_from_entries(cached)
                    show_feedback(string.format("Cached %d min ago - Ctrl+R to refresh", math.floor(age / 60)))
                    return
                end
            end
            
            

            state.fetching = true
            clear_overlays()

            local osd_w = mp.get_property_number("osd-width") or 1280
            local osd_h = mp.get_property_number("osd-height") or 720
            ov_ass.res_x, ov_ass.res_y = osd_w, osd_h
            ov_ass.data = string.format(
                "{\\an5}{\\pos(%d,%d)}{\\fs50\\b1}Fetching related videos...{\\b0}",
                osd_w / 2, osd_h / 2
            )
            ov_ass:update()

                        fetch_related(vid, feed_def.related, function(entries, err)
                state.fetching = false
                if not entries or #entries == 0 then
                    ov_ass.data = string.format(
                        "{\\an5}{\\pos(%d,%d)}{\\fs36\\1c&000000&\\3c&H0000FF&\\bord3}Related: %s",
                        osd_w / 2, osd_h / 2, escape_ass(err or "no results")
                    )
                    ov_ass:update()
                    restore_window()
                    return
                end
                page_cache[cache_key] = entries
                disk_cache_save(feed_def.key, vid, entries)
                render_page_from_entries(entries)
            end)
            return
        end


        local feed_url = get_feed_url(feed_def.key)
        if not feed_url then
            msg.error("YT-Search: No URL mapped for feed key: " .. tostring(feed_def.key))
            show_feedback("No URL for feed: " .. tostring(feed_def.key))
            return
        end

        if page_cache[cache_key] then
            local start_idx = (page - 1) * opts.page_size + 1
            if start_idx <= #page_cache[cache_key] then
                render_page_from_entries(page_cache[cache_key])
                state.fetching = false
                return
            end
            state.fetching = false
            show_feedback("No more items in this feed")
            render_page_from_entries(page_cache[cache_key])
            return
        end
        
        
        
        
        if not force_refresh then
            local cached, age = disk_cache_load(feed_def.key, nil)
            if cached then
                page_cache[cache_key] = cached
                render_page_from_entries(cached)
                show_feedback(string.format("Cached %d min ago - Ctrl+R to refresh", math.floor(age / 60)))
                return
            end
        end
        
        

        state.fetching = true
        clear_overlays()

        local osd_w = mp.get_property_number("osd-width") or 1280
        local osd_h = mp.get_property_number("osd-height") or 720
        ov_ass.res_x, ov_ass.res_y = osd_w, osd_h

        ov_ass.data = string.format(
            "{\\an5}{\\pos(%d,%d)}{\\fs50\\b1}Fetching Feed: %s{\\b0}",
            osd_w/2, osd_h/2, feed_def.label
        )
        ov_ass:update()

        local args = {
            opts.yt_dlp_path,
            "--no-warnings",
            "-J",
            "--flat-playlist",
            "--extractor-args", "youtube:flat-playlist=true",
            "--playlist-end", tostring(opts.page_size * 6),
            feed_url,
        }

        if temp_cookie_file then
            table.insert(args, 3, "--cookies")
            table.insert(args, 4, temp_cookie_file)
        end

        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            args = args,
            capture_stdout = true,
            capture_stderr = true,
        }, function(success, res, err)
            state.fetching = false

            if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
                msg.error("yt-dlp feed failed: status=" .. tostring(res and res.status)
                    .. " stderr=" .. tostring(res and res.stderr))
                ov_ass.data = string.format(
                    "{\\an5}{\\pos(%d,%d)}{\\fs40\\1c&000000&\\3c&H0000FF&\\bord3}Feed Failed. Check console.",
                    osd_w/2, osd_h/2
                )
                ov_ass:update()
                restore_window()
                return
            end

            local ok, data = pcall(utils.parse_json, res.stdout)
            local entries = (ok and data and data.entries) or {}
            local filtered = {}
            for _, e in ipairs(entries) do
                if not (e.id and e.id:find("^RD")) then
                    table.insert(filtered, e)
                end
            end
            entries = filtered

            if #entries == 0 then
                ov_ass.data = string.format(
                    "{\\an5}{\\pos(%d,%d)}{\\fs40\\1c&000000&\\3c&H0000FF&\\bord3}Feed empty: %s",
                    osd_w/2, osd_h/2, feed_def.label
                )
                ov_ass:update()
                restore_window()
                return
            end

            page_cache[cache_key] = entries
            disk_cache_save(feed_def.key, nil, entries)
            state.continuation = nil
            render_page_from_entries(entries)
        end)

        return
    end

    -- Search mode (yt-dlp)
    
    
    
    
    local search_id = search_cache_id(query)

    -- N/P paging: reuse the list already in memory
    if page_cache[cache_key] then
        local cached = page_cache[cache_key]
        if (page - 1) * opts.page_size + 1 <= #cached then
            render_page_from_entries(cached)
        else
            state.page = math.max(1, page - 1)
            show_feedback("No more results")
        end
        return
    end

    -- Same search as before (any mpv instance): load from disk
    if not force_refresh then
        local cached, age = disk_cache_load("search", search_id)
        if cached then
            page_cache[cache_key] = cached
            render_page_from_entries(cached)
            show_feedback(string.format("Cached %d min ago - Ctrl+R to refresh", math.floor(age / 60)))
            return
        end
    end
    
    
    
    
    local want = 40
    local args = { opts.yt_dlp_path, "--no-warnings", "-J", "--flat-playlist", "ytsearch" .. tostring(want) .. ":" .. query }

    if temp_cookie_file then
        table.insert(args, 3, "--cookies")
        table.insert(args, 4, temp_cookie_file)
    else
        msg.warn("YT-Search: No cookie file; running search without authentication.")
    end

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = args,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res, err)
        state.fetching = false

        if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            msg.error("yt-dlp failed: status=" .. tostring(res and res.status) .. " stderr=" .. tostring(res and res.stderr))
            local osd_w = mp.get_property_number("osd-width") or 1280
            local osd_h = mp.get_property_number("osd-height") or 720
            ov_ass.data = string.format(
                "{\\an5}{\\pos(%d,%d)}{\\fs40\\1c&000000&\\3c&H0000FF&\\bord3}Search Failed. Check console.",
                osd_w/2, osd_h/2
            )
            ov_ass:update()
            restore_window()
            return
        end

        local ok, data = pcall(utils.parse_json, res.stdout)
        local entries = data and data.entries or {}

        page_cache[cache_key] = entries
        disk_cache_save("search", search_id, entries)
        render_page_from_entries(entries)
    end)
end

--------------------------------------------------------------------------
-- Init & bindings
--------------------------------------------------------------------------

mp.observe_property("osd-dimensions", "native", function(name, val)
    if state.active then draw_grid() end
end)

refresh_cookies_from_browser(function(new_file)
    if new_file then
        msg.info("YT-Search: Initial cookie refresh succeeded.")
    else
        if not temp_cookie_file then
            msg.error("YT-Search: No cookie file available after initial refresh.")
        else
            msg.warn("YT-Search: Initial cookie refresh failed; using existing cookies.")
        end
    end
end)

--------------------------------------------------------------------------
-- uosc menu integration
--------------------------------------------------------------------------


local last_search = ""

local function run_search(query)
    if query == nil or query:match("^%s*$") then return end
    last_search = query
    cleanup_thumbnail_cache()
    if opts.search_results_uosc then
        show_standalone_feedback("Searching YouTube...", 15)
    else
        resize_for_grid()
    end
    fetch_and_render("search", query, 1)
end

local function open_search_prompt()
    if state.active then
        close_grid()
        return
    end

    clear_cache()

    if opts.uosc_search then
        local self = mp.get_script_name()
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
            type = "yt_search",
            title = "Search YouTube",
            palette = true,
            search_debounce = "submit",
            search_suggestion = last_search,
            on_search = { "script-message-to", self, "yt-search-submit" },
            items = {
                { title = "Type a search and press Enter", muted = true, selectable = false },
            },
        }))
        return
    end

    input.get({
        prompt = "Search YouTube:",
        default_text = last_search,
        submit = run_search,
    })
end

mp.register_script_message("yt-search-submit", function(query)
    mp.commandv("script-message-to", "uosc", "close-menu", "yt_search")
    run_search(query)
end)



open_uosc_results = function(entries, query)
    clear_feedback()
    local self = mp.get_script_name()
    local items = {}

    for _, e in ipairs(entries) do
        local url = entry_url(e)
        if url then
            local channel = e.channel or e.uploader or ""
            local dur = e.dur_str or (e.duration and e.duration > 0 and fmt_duration(e.duration)) or ""
            local hint = channel
            if dur ~= "" then
                hint = (hint ~= "" and (hint .. "  •  ") or "") .. dur
            end
            table.insert(items, {
                title = e.title or "(no title)",
                hint = hint,
                value = { "script-message-to", self, "yt-play", url },
            })
        end
    end

    if #items == 0 then
        show_standalone_feedback("No results", 3)
        return
    end

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "yt_results",
        title = "Search: " .. tostring(query),
        items = items,
    }))
end

mp.register_script_message("yt-play", function(url)
    mp.commandv("loadfile", url, "replace")
end)




local feed_icons = {
    home = "home",
    subscriptions = "subscriptions",
    history = "history",
    watch_later = "watch_later",
    liked = "thumb_up",
    related_all = "playlist_add",
    related_tab = "queue",
}

local function open_uosc_feed_menu()
    if state.active then
        close_grid()
        return
    end

    local self = mp.get_script_name()
    local items = {
        {
            title = "Search YouTube",
            hint = opts.search_key,
            icon = "search",
            value = { "script-message-to", self, "yt-search" },
        },
    }

    for _, feed in ipairs(FEEDS) do
        table.insert(items, {
            title = feed.label,
            icon = feed_icons[feed.key] or "video_library",
            value = { "script-message-to", self, "yt-feed", feed.key },
        })
    end

    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "yt_feeds",
        title = "YouTube",
        items = items,
    }))
end

mp.register_script_message("yt-feed", function(feed_key)
    open_feed_direct(feed_key)
end)

mp.register_script_message("yt-search", open_search_prompt)
mp.register_script_message("yt-menu", open_uosc_feed_menu)

mp.add_key_binding(opts.search_key, "mpv-youtube-search", open_search_prompt)

mp.add_key_binding(feed_menu_key, "mpv-youtube-feed-menu", function()
    if opts.use_uosc then
        open_uosc_feed_menu()
    else
        open_feed_menu()
    end
end)

register_direct_feed_keys()
