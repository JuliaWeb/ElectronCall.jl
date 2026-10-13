# Testing utilities for ElectronCall.
#
# Provides a clean, @testset/@test-compatible harness for Electron-based
# end-to-end tests. Combines the best patterns from BonitoBook, BonitoAgents,
# and TestKit into a single reusable module.
#
# Usage:
#     using ElectronCall
#     using ElectronCall.Testing
#
#     @testset "My App" begin
#         ctx = open_window("http://localhost:8080")
#         try
#             @test dom_exists(ctx, ".my-element")
#             wait_for(ctx, "document.querySelector('.loaded') !== null")
#             @test dom_text(ctx, ".title") == "Hello"
#             screenshot(ctx; path="test.png")
#         finally
#             close(ctx)
#         end
#     end
#
# Or with the context-manager form:
#     open_window("http://localhost:8080") do ctx
#         @test dom_exists(ctx, ".my-element")
#     end

module Testing

using ..ElectronCall
import ..ElectronCall: development_config, secure_defaults, ElectronCallError
using JSON, Base64

export TestContext, open_window, close, set_window_size
export eval_js, dom_count, dom_exists, dom_rect, dom_text, dom_html, dom_attr
export dom_click, dom_value, dom_query, dom_query_all
export type_into, press_key, focus_element, blur_element
export wait_for, wait_for_dom, wait_for_gone, click_until
export screenshot, emit_screenshot
export install_error_sink, js_errors, clear_js_errors
# Animated cursor + smooth frame-pump recording (see recording.jl)
export install_cursor, set_cursor, cursor_pos
export Sel, JS, Lazy, resolve_point
export move_to, mouse_down, mouse_up, click, drag, type_text, press_key, steer_slider, select_option
export wheel, send_input
export InteractionEvent, MouseTo, MouseDown, MouseUp, Click, RightClick, Drag, Steer, SelectOption
export TypeText, KeyPress, Wait, Focus, Do, play
export start_recording, stop_recording, record_video
export pause_recording, resume_recording, without_recording
export relative_pos
export @js_str

# ── TestContext ────────────────────────────────────────────────────────────

"""
    TestContext

Holds the Electron application, window, and associated state for a test session.
Create via [`open_window`](@ref), clean up via [`close`](@ref).
"""
mutable struct TestContext
    app::Application
    window::Window
    error_sink_installed::Bool
end

"""
    open_window(url; show=false, width=1280, height=800, devtools=false,
                electron_args=String[], security=development_config()) -> TestContext
    open_window(html; kwargs...) -> TestContext
    open_window(; kwargs...) -> TestContext

Open a headless Electron window and load the given URL or HTML. Returns a
`TestContext` that wraps the application and window.

When called with a do-block, the context is automatically closed after the block
executes:

    open_window("http://localhost:8080") do ctx
        @test dom_exists(ctx, ".my-element")
    end

# Keywords
- `show`: Whether to show the window (default: `false` for headless)
- `width`, `height`: Initial window dimensions
- `devtools`: Open Chromium devtools on launch
- `electron_args`: Extra arguments passed to the Electron process
- `security`: SecurityConfig for the application
"""
function open_window end

function open_window(f::Function, url::AbstractString; kwargs...)
    ctx = open_window(url; kwargs...)
    try
        f(ctx)
    finally
        close(ctx)
    end
end

function open_window(f::Function; kwargs...)
    ctx = open_window(; kwargs...)
    try
        f(ctx)
    finally
        close(ctx)
    end
end

# `offscreen` controls Electron's offscreen-rendering (OSR) mode, and it is ON BY
# DEFAULT. A plain hidden (`show = false`) window has no on-screen surface, so
# Chromium's compositor produces frames lazily (~1.5 fps measured) — which starves
# `requestAnimationFrame`, even though timers and the main thread run at full
# speed. OSR drives its OWN BeginFrame source at a fixed rate (60 fps default),
# independent of visibility, so rAF-paced code (scroll momentum, follow-mode
# restore, animations) runs at real-browser cadence. Since this Testing module
# exists to drive headless UI tests, faithful rAF timing is the correct default;
# pass `offscreen = false` to opt a window back onto the plain hidden-window path.
function _test_web_prefs(offscreen::Bool)
    # `disableDialogs`: an `alert`/`confirm` nobody stubbed would show a native,
    # focused dialog and wait for a click; `confirm` returns false instead.
    wp = Dict{String,Any}("backgroundThrottling" => false,
                          "paintWhenInitiallyHidden" => true,
                          "disableDialogs" => true)
    offscreen && (wp["offscreen"] = true)
    return wp
end

# Nothing the page does may put a window on the screen. A link to a new tab or
# `window.open` gets a BrowserWindow, which Electron shows and focuses unless
# told otherwise; a download asks where to save it in a dialog.
function keep_headless!(app::Application, win::Window)
    run(app, """(() => {
        const wc = electron.BrowserWindow.fromId($(win.id)).webContents;
        wc.setWindowOpenHandler(() => ({action: 'allow',
            overrideBrowserWindowOptions: {show: false, webPreferences: {offscreen: true}}}));
        wc.session.on('will-download', (e, item) =>
            item.setSavePath(electron.app.getPath('temp') + '/' + item.getFilename()));
        return true; })()""")
    return win
end

function open_window(url::AbstractString;
                     show::Bool = false,
                     offscreen::Bool = true,
                     width::Int = 1280,
                     height::Int = 800,
                     devtools::Bool = false,
                     electron_args::Vector{String} = String[],
                     security = development_config())
    # --ozone-platform=x11: Electron 28+ defaults to Wayland, but
    # capturePage on show:false windows only works for the first call on
    # Wayland. X11 gives a stable offscreen surface for repeat captures.
    args = String["--ozone-platform=x11"]
    append!(args, electron_args)
    if devtools
        push!(args, "--enable-logging", "--v=0")
    end

    app = Application(; name = "TestApp", security = security,
                       additional_electron_args = args)
    # Pass BrowserWindow options as KWARGS — `Window` merges kwargs into the
    # top-level options dict. An `options = Dict(...)` kwarg would instead nest
    # the dict under an `"options"` key, so `show` never reaches BrowserWindow
    # and Electron's `show:true` default pops a visible window (the bug that made
    # "headless" test windows flash + steal focus).
    # Window auto-detects HTML vs URL/path.
    win = Window(app, url;
                 show = show, width = width, height = height,
                 webPreferences = _test_web_prefs(offscreen))
    keep_headless!(app, win)
    return TestContext(app, win, false)
end

function open_window(; show::Bool = false,
                      offscreen::Bool = true,
                      width::Int = 1280,
                      height::Int = 800,
                      devtools::Bool = false,
                      electron_args::Vector{String} = String[],
                      security = development_config())
    args = String["--ozone-platform=x11"]
    append!(args, electron_args)
    if devtools
        push!(args, "--enable-logging", "--v=0")
    end

    app = Application(; name = "TestApp", security = security,
                       additional_electron_args = args)
    # Options as KWARGS (top-level), NOT `options = Dict(...)` which would nest
    # them and drop `show` → Electron's `show:true` default pops a window.
    win = Window(app;
                 show = show, width = width, height = height,
                 webPreferences = _test_web_prefs(offscreen))
    keep_headless!(app, win)
    return TestContext(app, win, false)
end

function Base.close(ctx::TestContext)
    # Best-effort teardown: the window or app may already be gone (process
    # exited, IPC dead), which shows up as an ElectronCallError. Tolerate those,
    # but let anything unexpected (a bug, InterruptException) propagate.
    if isopen(ctx.window)
        try
            close(ctx.window)
        catch e
            e isa ElectronCallError || rethrow()
            @debug "error closing window during teardown" exception = e
        end
    end
    if ctx.app.exists
        try
            close(ctx.app)
        catch e
            e isa ElectronCallError || rethrow()
            @debug "error closing application during teardown" exception = e
        end
    end
    return nothing
end

# ── JS evaluation ──────────────────────────────────────────────────────────

"""
    eval_js(ctx, code) -> Any

Execute a JavaScript expression in the renderer process and return the result.
"""
eval_js(ctx::TestContext, code::AbstractString) = run(ctx.window, code)

"""
    @js_str code

String macro for JavaScript code. Returns the string as-is; useful for
syntax highlighting in editors.
"""
macro js_str(code)
    return code
end

# ── DOM probes ─────────────────────────────────────────────────────────────

"""
    dom_count(ctx, selector) -> Int

Return the number of elements matching the CSS `selector`.
"""
dom_count(ctx::TestContext, sel::AbstractString) =
    eval_js(ctx, "document.querySelectorAll($(JSON.json(sel))).length")

"""
    dom_exists(ctx, selector) -> Bool

Return `true` if at least one element matches the CSS `selector`.
"""
dom_exists(ctx::TestContext, sel::AbstractString) =
    eval_js(ctx, "document.querySelector($(JSON.json(sel))) !== null")

"""
    dom_rect(ctx, selector) -> Union{Dict,Nothing}

Return the bounding client rect of the first matching element as a Dict with
keys `x`, `y`, `w`, `h`, `top`, `bottom`, `left`, `right`. Returns `nothing`
if no element matches.
"""
dom_rect(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return {x: r.x, y: r.y, w: r.width, h: r.height,
                top: r.top, bottom: r.bottom, left: r.left, right: r.right};
    })()
""")

"""
    dom_text(ctx, selector) -> Union{String,Nothing}

Return the `innerText` of the first matching element, or `nothing` if absent.
"""
dom_text(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        return el ? el.innerText : null;
    })()
""")

"""
    dom_html(ctx, selector) -> Union{String,Nothing}

Return the `innerHTML` of the first matching element, or `nothing` if absent.
"""
dom_html(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        return el ? el.innerHTML : null;
    })()
""")

"""
    dom_attr(ctx, selector, attr) -> Union{String,Nothing}

Return the value of attribute `attr` on the first matching element, or `nothing`.
"""
dom_attr(ctx::TestContext, sel::AbstractString, attr::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        return el ? el.getAttribute($(JSON.json(attr))) : null;
    })()
""")

"""
    dom_value(ctx, selector) -> Union{String,Nothing}

Return the `.value` property of the first matching element (useful for inputs).
"""
dom_value(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        return el ? el.value : null;
    })()
""")

"""
    dom_query(ctx, js_expr) -> Any

Run an arbitrary JS expression scoped to `document.querySelector` result.
The expression receives `el` as the matched element, or `null` if absent.

    dom_query(ctx, "el => el.children.length")
"""
dom_query(ctx::TestContext, js_expr::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector('body');
        return ($js_expr)(el);
    })()
""")

"""
    dom_query_all(ctx, selector) -> Vector

Return an array of matching elements' `innerText` values.
"""
dom_query_all(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    Array.from(document.querySelectorAll($(JSON.json(sel)))).map(e => e.innerText)
""")

"""
    dom_click(ctx, selector) -> Bool

Click the first element matching the CSS `selector`. Returns `true` if an
element was found and clicked, `false` otherwise.
"""
dom_click(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => { const el = document.querySelector($(JSON.json(sel)));
              if (el) el.click(); return el !== null; })()
""") === true

# ── User interaction ───────────────────────────────────────────────────────

"""
    type_into(ctx, selector, text)

Set `.value` on an input/textarea matching `selector` and dispatch an `input`
event so Julia-side handlers fire.
"""
function type_into(ctx::TestContext, sel::AbstractString, text::AbstractString)
    eval_js(ctx, """
        (() => {
            const el = document.querySelector($(JSON.json(sel)));
            if (!el) return false;
            el.value = $(JSON.json(text));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            return true;
        })()
    """)
end

"""
    press_key(ctx, selector, key; shift=false, ctrl=false, alt=false, meta=false)

Dispatch a `keydown` event on the matched element with the given modifier state.
"""
function press_key(ctx::TestContext, sel::AbstractString, key::AbstractString;
                   shift::Bool = false, ctrl::Bool = false,
                   alt::Bool = false, meta::Bool = false)
    eval_js(ctx, """
        (() => {
            const el = document.querySelector($(JSON.json(sel)));
            if (!el) return false;
            el.dispatchEvent(new KeyboardEvent('keydown', {
                key: $(JSON.json(key)), shiftKey: $(shift), ctrlKey: $(ctrl),
                altKey: $(alt), metaKey: $(meta), bubbles: true}));
            return true;
        })()
    """)
end

"""
    focus_element(ctx, selector)

Focus the first element matching the CSS `selector`.
"""
focus_element(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        if (el) el.focus();
        return el !== null;
    })()
""")

"""
    blur_element(ctx, selector)

Blur (unfocus) the first element matching the CSS `selector`.
"""
blur_element(ctx::TestContext, sel::AbstractString) = eval_js(ctx, """
    (() => {
        const el = document.querySelector($(JSON.json(sel)));
        if (el) el.blur();
        return el !== null;
    })()
""")

# ── Waiting ────────────────────────────────────────────────────────────────

"""
    wait_for(ctx, predicate_js; timeout=5.0, interval=0.05) -> Bool

Poll a JS expression that returns a boolean. Returns `true` the moment the
expression yields `true`, `false` on timeout. Transient ElectronCall errors
during rendering (renderer not ready) are ignored; other exceptions propagate.
"""
function wait_for(ctx::TestContext, predicate_js::AbstractString;
                  timeout::Float64 = 5.0, interval::Float64 = 0.05)
    deadline = time() + timeout
    while time() < deadline
        try
            eval_js(ctx, "(() => { return ($predicate_js); })()") === true && return true
        catch e
            # The renderer may not be ready yet (mid-navigation, JS not loaded),
            # which throws an ElectronCallError; keep polling on those. Anything
            # else is a real problem.
            e isa ElectronCallError || rethrow()
        end
        sleep(interval)
    end
    return false
end

"""
    wait_for_dom(ctx, selector; timeout=5.0) -> Bool

Wait until at least one element matching `selector` exists in the DOM.
"""
wait_for_dom(ctx::TestContext, sel::AbstractString; timeout::Float64 = 5.0) =
    wait_for(ctx, "document.querySelector($(JSON.json(sel))) !== null"; timeout = timeout)

"""
    wait_for_gone(ctx, selector; timeout=5.0) -> Bool

Wait until no elements matching `selector` exist in the DOM.
"""
wait_for_gone(ctx::TestContext, sel::AbstractString; timeout::Float64 = 5.0) =
    wait_for(ctx, "document.querySelector($(JSON.json(sel))) === null"; timeout = timeout)

"""
    click_until(ctx, selector, predicate_js; timeout=10.0, interval=0.3) -> Bool

Click the first *visible* element matching `selector` (offsetParent set),
repeatedly, until the JS expression `predicate_js` yields `true` (returns
`true`) or `timeout` elapses (returns `false`).

For clicks whose effect is wired asynchronously: a framework that attaches the
handler only after the element mounts means a single synthetic `click()` can
race ahead of the handler and be silently dropped, so a plain
`click` + `wait_for` hangs forever. `click_until` re-clicks until the awaited
state appears. The clicked control must be idempotent w.r.t. that state (e.g. a
button that sets a flag), since it may be clicked more than once.
"""
function click_until(ctx::TestContext, selector::AbstractString, predicate_js::AbstractString;
                     timeout::Float64 = 10.0, interval::Float64 = 0.3)
    deadline = time() + timeout
    while time() < deadline
        try
            eval_js(ctx, """(() => {
                const el = [...document.querySelectorAll($(JSON.json(selector)))]
                    .find(e => e && e.offsetParent !== null);
                if (el) el.click();
                return el !== null;
            })()""")
            eval_js(ctx, "(() => { return ($predicate_js); })()") === true && return true
        catch e
            e isa ElectronCallError || rethrow()
        end
        sleep(interval)
    end
    return false
end

# ── Screenshots ────────────────────────────────────────────────────────────

"""
    screenshot(ctx; path=tempname()*".png") -> String

Capture the current Electron viewport to a PNG file. Returns the file path.
Uses `webContents.capturePage()` on the main process.
"""
function screenshot(ctx::TestContext; path::AbstractString = tempname() * ".png")
    win_id = ctx.window.id
    b64 = run(ctx.app, """
        (async () => {
            const win = electron.BrowserWindow.fromId($win_id);
            const img = await win.webContents.capturePage();
            return img.toPNG().toString('base64');
        })()
    """)
    b64 isa AbstractString || error("screenshot returned non-string: $(typeof(b64))")
    write(path, Base64.base64decode(b64))
    return path
end

"""
    emit_screenshot(ctx; label="")

Capture a screenshot and print the path. Returns the path.
"""
function emit_screenshot(ctx::TestContext; label::AbstractString = "")
    path = screenshot(ctx)
    println("--- ", isempty(label) ? "screenshot" : label, " saved -> ", path, " ---")
    return path
end

# ── Window management ──────────────────────────────────────────────────────

"""
    set_window_size(ctx, w, h)

Force the renderer viewport via Chromium device-emulation. More reliable than
`BrowserWindow.setSize` on Linux/offscreen where the latter only shrinks the
viewport and is subject to OS window-manager minimum-size constraints.
"""
function set_window_size(ctx::TestContext, w::Int, h::Int)
    win_id = ctx.window.id
    run(ctx.app, """
        const win = electron.BrowserWindow.fromId($win_id);
        win.webContents.enableDeviceEmulation({
            screenPosition: 'desktop',
            screenSize:  { width: $w, height: $h },
            viewSize:    { width: $w, height: $h },
            deviceScaleFactor: 0,
            scale: 1,
        });
        win.setMinimumSize(0, 0);
        win.setSize($w, $h);
        win.setContentSize($w, $h);
        null
    """)
    # Wait for the renderer's reported width to catch up
    deadline = time() + 2
    while time() < deadline
        try
            iw = run(ctx.window, "window.innerWidth")
            iw isa Number && abs(iw - w) < 30 && break
        catch e
            e isa ElectronCallError || rethrow()   # renderer not ready yet; keep polling
        end
        sleep(0.05)
    end
    return nothing
end

"""
    toggle_devtools(ctx)

Open the Chromium devtools for the test window.
"""
toggle_devtools(ctx::TestContext) = toggle_devtools(ctx.window)

# ── JS error tracking ─────────────────────────────────────────────────────

"""
    install_error_sink(ctx)

Install a JavaScript error sink that captures all `error` and
`unhandledrejection` events. Call once after loading your page; then use
[`js_errors`](@ref) to check what fired.
"""
function install_error_sink(ctx::TestContext)
    eval_js(ctx, """
        window.__errs = [];
        window.addEventListener('error', e =>
            window.__errs.push({type: 'error', message: String(e.message),
                                filename: e.filename, lineno: e.lineno}));
        window.addEventListener('unhandledrejection', e =>
            window.__errs.push({type: 'unhandledrejection',
                                message: String(e.reason && e.reason.message || e.reason),
                                stack: String((e.reason && e.reason.stack) || '')}));
    """)
    ctx.error_sink_installed = true
    return nothing
end

"""
    js_errors(ctx) -> Vector

Return the list of JavaScript errors captured by the error sink. Each entry is
a Dict with keys `type`, `message`, and optionally `filename`/`lineno` (thrown
errors) or `stack` (rejections — a bare rejection message like "Cannot read
properties of null" names no file at all, so the stack is the only way to find
which library threw). Returns an empty vector if no error sink is installed or
no errors occurred.
"""
function js_errors(ctx::TestContext)
    ctx.error_sink_installed || return Any[]
    e = eval_js(ctx, "window.__errs || []")
    return e === nothing ? Any[] : e
end

"""
    clear_js_errors(ctx)

Clear the error sink contents.
"""
clear_js_errors(ctx::TestContext) = (eval_js(ctx, "window.__errs = []"); nothing)

# ── Animated cursor + smooth interaction recording ──────────────────────────
# The Electron counterpart to Makie's fake_interaction.jl: an animated on-screen
# cursor driven through real pointer events, recorded as a smooth video via a
# main-process frame pump into ffmpeg. See recording.jl for the details.
include("recording.jl")

"""
    relative_pos(element_rect, rel_x, rel_y) -> (x, y)

Convert a relative position (0..1) within a bounding rect to absolute pixel
coordinates. `element_rect` should be a Dict from [`dom_rect`](@ref).
"""
function relative_pos(rect::AbstractDict, rel_x::Real, rel_y::Real)
    x = rect["x"] + rel_x * rect["w"]
    y = rect["y"] + rel_y * rect["h"]
    return (x, y)
end

"""
    relative_pos(ctx, selector, rel_x, rel_y) -> (x, y)

Convenience: look up the element rect and compute relative position in one call.
"""
function relative_pos(ctx::TestContext, sel::AbstractString, rel_x::Real, rel_y::Real)
    r = dom_rect(ctx, sel)
    r === nothing && error("no element matched selector: $sel")
    return relative_pos(r, rel_x, rel_y)
end

end # module Testing
