--- Webview widget wrapper.
--
-- The webview module wraps the webview widget provided by luakit, adding
-- several convenience APIs and providing basic functionality.
--
-- @module webview
-- @copyright 2017 Aidan Holm <aidanholm@gmail.com>
-- @copyright 2012 Mason Larobina <mason.larobina@gmail.com>

local window = require("window")
local lousy = require("lousy")
local settings = require("settings")

local _M = {}

lousy.signal.setup(_M, true)

local web_module = require_web_module("webview_wm")

web_module:add_signal("form-active", function (_, page_id)
    for _, w in pairs(window.bywidget) do
        if w.view.id == page_id then
            w.view:emit_signal("form-active")
        end
    end
end)

web_module:add_signal("navigate", function (_, page_id, uri)
    msg.verbose("Got luakit:// -> file:// navigation: %s", uri)
    for _, w in pairs(window.bywidget) do
        if w.view.id == page_id then w.view.uri = uri end
    end
end)

local webview_state = setmetatable({}, { __mode = "k" })

-- Table of functions which are called on new webview widgets.
local init_funcs = {
    -- Update window and tab titles
    title_update = function (view)
        view:add_signal("property::title", function (v)
            local w = _M.window(v)
            if w and w.view == v then
                w:update_win_title()
            end
        end)
    end,

    -- Clicking a form field automatically enters insert mode.
    form_insert_mode = function (view)
        -- Emit root-active event in button release to prevent "missing"
        -- buttons or links when the input bar hides.
        view:add_signal("button-press", function (v, _, button, context)
            if button == 1 then
                v:emit_signal(context.editable and "form-active" or "root-active")
            end
        end)
        view:add_signal("form-active", function (v)
            local w = _M.window(v)
            if not w.mode.passthrough then
                w:set_mode("insert")
            end
        end)
        view:add_signal("root-active", function (v)
            local w = _M.window(v)
            if w.mode.reset_on_focus ~= false then
                w:set_mode()
            end
        end)
        view:add_signal("load-status", function (v, status, _, err)
            if status == "finished" or (status == "failed" and err == "Load request cancelled") then
                web_module:emit_signal(v, "load-finished")
            end
        end)
    end,

    -- Try to match a button event to a users button binding else let the
    -- press hit the webview.
    button_bind_match = function (view)
        view:add_signal("button-release", function (v, mods, button, context)
            local w = _M.window(v)
            if w:hit(mods, button, { context = context }) then
                return true
            end
        end)
        view:add_signal("scroll", function (v, mods, dx, dy, context)
            local w = _M.window(v)
            if w:hit(mods, "Scroll", { context = context, dx = dx, dy = dy }) then
                return true
            end
        end)
    end,

    -- Reset the mode on navigation
    mode_reset_on_nav = function (view)
        view:add_signal("load-status", function (v, status)
            local w = _M.window(v)
            if status == "provisional" and w and w.view == v then
                if w.mode.reset_on_navigation ~= false then
                    w:set_mode()
                end
            end
        end)
    end,

    -- Action to take on mime type decision request.
    mime_decision = function (view)
        -- Return true to accept or false to reject from this signal.
        view:add_signal("mime-type-decision", function (_, uri, mime)
            msg.info("Requested link: %s (%s)", uri, mime)
            -- i.e. block binary files like *.exe
            --if mime == "application/octet-stream" then
            --    return false
            --end
        end)
    end,

    -- Action to take on window open request.
    --window_decision = function (view, w)
    --    view:add_signal("new-window-decision", function (v, uri, reason)
    --        if reason == "link-clicked" then
    --            window.new({uri})
    --        else
    --            w:new_tab(uri)
    --        end
    --        return true
    --    end)
    --end,

    create_webview = function (view)
        -- Return a newly created webview in a new tab
        view:add_signal("create-web-view", function (v)
            return _M.window(v):new_tab(nil, { private = v.private })
        end)
    end,

    popup_fix_open_link_label = function (view)
        view:add_signal("populate-popup", function (_, menu)
            for _, item in ipairs(menu) do
                if type(item) == "table" then
                    -- Optional underscore represents alt-key shortcut letter
                    item[1] = string.gsub(item[1], "New (_?)Window", "New %1Tab")
                end
            end
        end)
    end,
}

--- These methods are present when you index a window instance and no window
-- method is found in `window.methods`. The window then checks if there is an
-- active webview and calls the following methods with the given view instance
-- as the first argument. All methods must take `view` & `w` as the first two
-- arguments.
-- @readwrite
-- @type {[string]=function}
_M.methods = {
    -- Reload with or without ignoring cache
    reload = function (view, _, bypass_cache)
        if bypass_cache then
            view:reload_bypass_cache()
        else
            view:reload()
        end
    end,

    -- Toggle source view
    toggle_source = function (view, _, show)
        if show == nil then
            view.view_source = not view.view_source
        else
            view.view_source = show
        end
        view:reload()
    end,

    -- Zoom functions
    zoom_in = function (view, _, step)
        step = step or settings.window.zoom_step
        view.zoom_level = view.zoom_level + step
    end,

    zoom_out = function (view, _, step)
        step = step or settings.window.zoom_step
        view.zoom_level = math.max(0.01, view.zoom_level) - step
    end,

    zoom_set = function (view, _, level)
        view.zoom_level = level or 1.0
    end,

    -- History traversing functions
    back = function (view, _, n)
        view:go_back(n or 1)
        view:emit_signal("go-back-forward", -(n or 1))
    end,

    forward = function (view, _, n)
        view:go_forward(n or 1)
        view:emit_signal("go-back-forward", (n or 1))
    end,
}

--- Scroll the current webview by a given amount.
-- @tparam widget view The webview widget to scroll.
-- @tparam table w The window class table for the window containing `view`.
-- @tparam table new Table of scroll information.
function _M.methods.scroll(view, w, new)
    local s = view.scroll
    for _, axis in ipairs{ "x", "y" } do
        -- Relative px movement
        if rawget(new, axis.."rel") then
            s[axis] = s[axis] + new[axis.."rel"]

        -- Relative page movement
        elseif rawget(new, axis .. "pagerel") then
            s[axis] = s[axis] + math.ceil(s[axis.."page_size"] * new[axis.."pagerel"])

        -- Absolute px movement
        elseif rawget(new, axis) then
            local n = new[axis]
            if n == -1 then
                local dir = axis == "x" and "Width" or "Height"
                local js = string.format([=[
                    Math.max(window.document.documentElement.scroll%s - window.inner%s, 0)
                ]=], dir, dir)
                w.view:eval_js(js, { callback = function (max)
                    s[axis] = max
                end})
            else
                s[axis] = n
            end

        -- Absolute page movement
        elseif rawget(new, axis.."page") then
            s[axis] = math.ceil(s[axis.."page_size"] * new[axis.."page"])

        -- Absolute percent movement
        elseif rawget(new, axis .. "pct") then
            local dir = axis == "x" and "Width" or "Height"
            local js = string.format([=[
                Math.max(window.document.documentElement.scroll%s - window.inner%s, 0)
            ]=], dir, dir)
            w.view:eval_js(js, { callback = function (max)
                s[axis] = math.ceil(max * (new[axis.."pct"]/100))
            end})
        end
    end
end

local wrap_widget_metatable
do
    local wrapped = false
    wrap_widget_metatable = function (view)
        if wrapped then return end
        wrapped = true

        local mt = getmetatable(view)
        local oi = mt.__index
        mt.__index = function (w, k)
            if (k == "uri" or k == "session_state") and oi(w, "type") == "webview" then
                local ws = webview_state[w]
                if not next(ws.blockers) then return oi(w, k) end
                local ql = ws.queued_location or {}
                if k == "uri" then
                    return ql.uri or oi(w, k)
                end
                if k == "session_state" then
                    return ql.session_state or oi(w, k)
                end
            end
            return oi(w, k)
        end
    end
end

--- Create a new webview instance.
-- @tparam table opts Table of options. Currently only `private` is recognized
-- as a key.
-- @treturn table The newly-created webview widget.
function _M.new(opts)
    assert(opts)
    local view = widget{type = "webview", private = opts.private}

    webview_state[view] = { blockers = {} }
    wrap_widget_metatable(view)

    -- Call webview init functions
    for _, func in pairs(init_funcs) do
        func(view)
    end
    _M.emit_signal("init", view)

    return view
end

luakit.idle_add(function ()
    local undoclose = package.loaded.undoclose
    if not undoclose then return end
    undoclose.add_signal("save", function (view)
        if view.private then return false end
    end)
end)

--- Wrapper for @ref{window/ancestor|window.ancestor}.
-- @tparam widget view The webview whose ancestor to find.
-- @treturn table|nil The window class table for the window that contains `view`,
-- or `nil` if `view` is not contained within a window.
function _M.window(view)
    assert(type(view) == "widget" and view.type == "webview")
    return window.ancestor(view)
end

--- Add/remove a load block on the given webview.
-- If a block is enabled on a webview, load requests will be suspended until the
-- block is removed. This is useful for pausing network operations while a
-- module is initializing.
-- @tparam widget view The view on which to add/remove the load block.
-- @tparam string name The name of the block to add/remove.
-- @tparam boolean enable Whether the block should be enabled.
function _M.modify_load_block(view, name, enable)
    assert(type(view) == "widget" and view.type == "webview")
    assert(type(name) == "string")

    local ws = webview_state[view]
    ws.blockers[name] = enable and true or nil
    msg.verbose("%s %s %s", view, name, enable and "block" or "unblock")

    if not next(ws.blockers) and ws.queued_location then
        msg.verbose("fully unblocked %s", view)
        local queued = ws.queued_location
        ws.queued_location = nil
        _M.set_location(view, queued)
    end
end

--- Set the location of the webview. This method will respect any load blocks in
-- place (see @ref{modify_load_block}).
-- @tparam widget view The view whose location to modify.
-- @tparam table arg The new location. Can be a URI, a JavaScript URI, or a
-- table with `session_state` and `uri` keys.
function _M.set_location(view, arg)
    assert(type(view) == "widget" and view.type == "webview")
    assert(type(arg) == "string" or type(arg) == "table")

    -- Always execute JS URIs immediately, even when webview is blocked
    if type(arg) == "string" and arg:match("^javascript:") then
        local js = string.match(arg, "^javascript:(.+)$")
        return view:eval_js(luakit.uri_decode(js))
    end

    if type(arg) == "string" then arg = { uri = arg } end
    assert(arg.uri or arg.session_state)

    local ws = webview_state[view]
    if next(ws.blockers) then
        ws.queued_location = arg
        if arg.uri then view:emit_signal("property::uri") end
        return
    end

    if arg.session_state then
        view.session_state = arg.session_state
        if view.uri == "about:blank" and arg.uri then
            view.uri = arg.uri
        end
    else
        view.uri = arg.uri
    end
end

-- Insert webview method lookup on window structure
table.insert(window.indexes, 1, function (w, k)
    if k == "view" then
        local view = w.tabs[w.tabs:current()]
        if view and type(view) == "widget" and view.type == "webview" then
            w.view = view
            return view
        end
    end
    -- Lookup webview method
    local func = _M.methods[k]
    if not func then return end
    local view = w.view
    if view then
        return function (_, ...) return func(view, w, ...) end
    end
end)

local webview_settings = {
    ["webview.allow_file_access_from_file_uris"] = {
        type = "boolean",
        default = false,
        domain_specific = false,
    },
    ["webview.allow_modal_dialogs"] = {
        type = "boolean",
        default = false,
    },
    ["webview.allow_universal_access_from_file_uris"] = {
        type = "boolean",
        default = false,
        domain_specific = false,
    },
    ["webview.auto_load_images"] = {
        type = "boolean",
        default = true,
    },
    ["webview.cursive_font_family"] = {
        type = "string",
        default = "serif",
    },
    ["webview.default_charset"] = {
        type = "string",
        default = "iso-8859-1",
    },
    ["webview.default_font_family"] = {
        type = "string",
        default = "sans-serif",
    },
    ["webview.default_font_size"] = {
        type = "number", min = 0,
        default = "16",
    },
    ["webview.default_monospace_font_size"] = {
        type = "number", min = 0,
        default = "13",
    },
    ["webview.draw_compositing_indicators"] = {
        type = "boolean",
        default = false,
    },
    ["webview.editable"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_accelerated_2d_canvas"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_caret_browsing"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_developer_extras"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_dns_prefetching"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_frame_flattening"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_fullscreen"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_html5_database"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_html5_local_storage"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_hyperlink_auditing"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_java"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_javascript"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_mediasource"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_media_stream"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_offline_web_application_cache"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_page_cache"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_plugins"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_resizable_text_areas"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_site_specific_quirks"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_smooth_scrolling"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_spatial_navigation"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_tabs_to_links"] = {
        type = "boolean",
        default = true,
    },
    ["webview.enable_webaudio"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_webgl"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_write_console_messages_to_stdout"] = {
        type = "boolean",
        default = false,
    },
    ["webview.enable_xss_auditor"] = {
        type = "boolean",
        default = true,
    },
    ["webview.fantasy_font_family"] = {
        type = "string",
        default = "serif",
    },
    ["webview.hardware_acceleration_policy"] = {
        type = "enum",
        options = {
            ["on-demand"] = { desc = "Enable/disable hardware acceleration as necessary." },
            ["always"] = { desc = "Always enable hardware acceleration." },
            ["never"] = { desc = "Always disable hardware acceleration." },
        },
        default = "on-demand",
    },
    ["webview.javascript_can_access_clipboard"] = {
        type = "boolean",
        default = false,
    },
    ["webview.javascript_can_open_windows_automatically"] = {
        type = "boolean",
        default = false,
    },
    ["webview.load_icons_ignoring_image_load_setting"] = {
        type = "boolean",
        default = false,
    },
    ["webview.media_playback_allows_inline"] = {
        type = "boolean",
        default = true,
    },
    ["webview.media_playback_requires_user_gesture"] = {
        type = "boolean",
        default = false,
    },
    ["webview.minimum_font_size"] = {
        type = "number", min = 0,
        default = 0,
    },
    ["webview.monospace_font_family"] = {
        type = "string",
        default = "monospace",
    },
    ["webview.pictograph_font_family"] = {
        type = "string",
        default = "serif",
    },
    ["webview.print_backgrounds"] = {
        type = "boolean",
        default = true,
    },
    ["webview.sans_serif_font_family"] = {
        type = "string",
        default = "sans-serif",
    },
    ["webview.serif_font_family"] = {
        type = "string",
        default = "serif",
    },
    ["webview.zoom_level"] = {
        type = "number", min = 0,
        default = 100,
    },
    ["webview.zoom_text_only"] = {
        type = "boolean",
        default = false,
    },
}
settings.register_settings(webview_settings)
settings.register_settings({
    ["webview.user_agent"] = {
        type = "string",
        default = "",
    },
})

_M.add_signal("init", function (view)
    local set = function (wv, k, v, match)
        if v then
            k = k:sub(9) -- Strip off "webview." prefix
            if k == "zoom_level" then v = v/100.0 end
            if k == "user_agent" and v == "" then v = nil end
            match = match and (" (matched '"..match.."')") or ""
            msg.verbose("setting property %s = %s" .. match, k, v, match)
            wv[k] = v
        end
    end
    local set_all = function (vv)
        for k in pairs(webview_settings) do
            local v, match = settings.get_setting_for_view(vv, k)
            set(vv, k, v, match)
        end
    end
    -- Set domain-specific values on page load
    view:add_signal("load-status", function (v, status)
        if v.uri == "about:blank" then
            return
        elseif status == "provisional" or status == "redirected" then
            local val, match = settings.get_setting_for_view(v, "webview.user_agent")
            set(v, "webview.user_agent", val, match)
        elseif status == "committed" then set_all(v) end
    end)
    view:add_signal("web-extension-loaded", function (v)
        -- Explicitly set the zoom, due to a WebKit bug that resets the
        -- apparent zoom level to 100% after a crash
        set(v, "webview.zoom_level", settings.get_setting("webview.zoom_level"))
    end)
end)

settings.migrate_global("webview.zoom_level", "default_zoom_level")
settings.migrate_global("webview.user_agent", "user_agent")

-- Migrate from globals.domain_props
local globals = package.loaded.globals or {}
local dp = globals.domain_props or {}
local dp_all = dp.all or {}
dp.all = nil
for domain, props in pairs(dp) do
    for k, v in pairs(props) do
        if k == "enable_scripts" then k = "enable_javascript" end
        if k == "zoom_level" then v = v*100 end
        settings.add_migration_warning(string.format('on["%s"].webview.%s', domain, k), v)
        settings.on[domain].webview[k] = v
    end
end
for k, v in pairs(dp_all) do
    if k == "enable_scripts" then k = "enable_javascript" end
    if k == "zoom_level" then v = v*100 end
    settings.add_migration_warning("webview.".. k, v)
    settings.webview[k] = v
end

return _M

-- vim: et:sw=4:ts=8:sts=4:tw=80
