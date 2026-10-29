# RFC: an Electron-shaped desktop surface for jsz

Status: **implemented as an opt-in v1 subset** (2026-10-29). `jsz --desktop`
ships the main-process surface, the restricted preload context, the zig-webui
window backend, and the bridge described below. The gates and limitations in
this document still apply: this is not Electron, not Chromium, and not a
security boundary equivalent to Electron's process model.

Packaging follow-up (2026-10-29): compiled desktop apps are now supported
through `jszc` and the `sea.json` `assets`/`desktop` keys. Preload and HTML are
embedded and resolved from the payload; see
[docs/single-executable.md](single-executable.md). This supersedes the
packaging proposal below for v1, but not the signing, notarization, installer,
or auto-update work.

## Summary and compatibility claim

Offer a first-class `electron` builtin to **a documented subset** of Electron applications, not an Electron runtime or a drop-in replacement. The first deliverable is a main-process jsz application controlling native WebView windows through zig-webui, with an explicit preload capability bridge to ordinary browser JavaScript. Chromium, V8, Node's complete API, Electron's multi-process architecture, and Electron's full security guarantees are **not** included. An external-browser backend is a possible explicit fallback, never a silent substitute for `BrowserWindow`. No percentage of real-world Electron usage is asserted: coverage requires a reproducible application corpus and measured API-call inventory before any percentage claim.

**Reference baseline:** Electron **39.5.0 documentation**, selected as a fixed comparison target for this proposal (not a claim that jsz implements that release). Before coding, pin exact Electron docs/API types and the three native dependency commits in `build.zig.zon`; rerun signature and behavior comparisons against that pinned baseline. Electron's latest documentation may move independently. Deviations below override Electron behavior, and tests must assert the deviations.

## Existing constraints

`build.zig.zon` pins Zig >=0.17.0; `mise.toml` uses 0.17.0. `build.zig` links QuickJS-ng and zio; `src/runtime.zig` owns a single-executor zio runtime, QuickJS runtime/context, job queue and event loop. `src/event_loop.zig` dispatches jobs and drains QuickJS jobs; queue waits can block indefinitely while a window is open unless GUI wakeups are integrated. `src/module.zig` registers embedded `node:*` ES modules and private native modules, and currently treats unknown bare package names as missing; `.mjs` is ESM and `.js` is syntax-detected. `src/builtins/events.js` supplies EventEmitter; `src/js/host.zig` holds context-local host state. Existing filesystem is async-only; `fs.*Sync` throws, `existsSync` is absent. `docs/roadmap.md` and `docs/plan/plan.md` record deferred Node features. Electron compatibility must not imply they exist.

## Module and process contract

- `import { app, BrowserWindow, ipcMain, dialog, shell } from 'electron'` resolves through the **canonical `electron` builtin** only when desktop mode is enabled (proposed invocation `jsz --desktop main.mjs`, exact CLI flag to confirm). Never resolve an npm `electron` package or `node:electron`; `node:electron` raises `ERR_UNKNOWN_BUILTIN_MODULE`. In ordinary jsz mode, importing `electron` throws `ERR_DESKTOP_NOT_ENABLED` at module load. No hidden GUI initialization from an import.
- Canonical module identity is per QuickJS context and role. **Conditional on the preload feasibility gates below**, main exports `app`, `BrowserWindow`, `ipcMain`, `dialog`, `shell`; preload exports only `contextBridge`, `ipcRenderer`; renderer page **cannot import** `electron`, receives only explicitly exposed `window.*` properties. Importing an unavailable named ESM export fails at link time (QuickJS missing-export error); only role-appropriate named exports exist. No fake inert classes for unsupported modules. If the gated preload cannot ship, omit its exports and do not market the three-file example as supported.
- The proposed preload is an absolute-path `.mjs` only **if** pre-document injection and restricted execution are proved; main is `.mjs` (or syntax-detected `.js`). The proposed ESM preload runs in a separate QuickJS context with a restricted module allowlist; ordinary jsz `node:*` imports are unavailable there except explicitly audited helpers. This design is not Electron preload fidelity. Main may use existing supported `node:*` modules, with their documented limits.
- `process.type` is proposed as `'browser'` in main and `'renderer'` in preload; the browser page has no jsz `process` global. `process.versions.electron` must **not** impersonate Electron 39.5.0; omit it or expose an explicitly suffixed compatibility identifier after a decision. `app.getVersion()` reads explicit application metadata; do not synthesize an Electron version. One OS process with separate QuickJS contexts plus a native browser engine is not Electron's process isolation.

## Illustrative supported application (ESM only)

`main.mjs`:

```js
import { app, BrowserWindow, ipcMain, dialog } from 'electron';

// Replace with absolute paths to trusted application resources on this OS.
const preloadPath = '/absolute/path/to/preload.mjs';
const htmlPath = '/absolute/path/to/index.html';
let win;
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
await app.whenReady();
ipcMain.handle('pick-file', async (event) => {
  // Validate caller identity before performing privileged work.
  if (event.sender !== win.webContents) throw new Error('unexpected sender');
  return dialog.showOpenDialog(win, {
    properties: ['openFile'], filters: [{ name: 'Text', extensions: ['txt'] }],
  });
});
win = new BrowserWindow({
  width: 800, height: 600,
  webPreferences: { preload: preloadPath, contextIsolation: true,
    nodeIntegration: false, sandbox: true },
});
await win.loadFile(htmlPath);
```

`preload.mjs` (a restricted jsz context, **not** Electron's Chromium preload):

```js
import { contextBridge, ipcRenderer } from 'electron';
contextBridge.exposeInMainWorld('desktop', {
  pickFile: () => ipcRenderer.invoke('pick-file'),
});
```

`index.html` (normal WebView browser JavaScript, no `electron` imports):

```html
<!doctype html><html><body>
<button id="pick">Pick file</button><output id="result"></output>
<script>
  document.querySelector('#pick').onclick = async () => {
    const { canceled, filePaths } = await window.desktop.pickFile();
    document.querySelector('#result').textContent = canceled ? 'Canceled' : filePaths[0];
  };
</script></body></html>
```

This example is **target behavior, not runnable today**. The bridge must establish `desktop` before any page script executes; if zig-webui cannot guarantee that ordering, the example and preload feature are blocked, not downgraded silently.

## v1 API contract and support matrix

`S` = planned scoped surface **only after its prerequisite gates pass**; `G` = gated behind a native/platform proof; `U` = unsupported in v1. In particular, preload `ipcRenderer` is conditional on the contextBridge transport gate even where marked `S`. Signatures describe the proposed jsz behavior; where narrower than Electron they are explicit. EventEmitter `on/once/off(event, listener) -> this` applies to `app`, `BrowserWindow`, `webContents`, `ipcMain`, and `ipcRenderer` where events are listed. Unsupported named exports do not exist; unsupported options on supported APIs throw `ERR_ELECTRON_UNSUPPORTED_OPTION` (with option name), rather than being ignored. Invalid types throw `TypeError`; OS/backend failures reject promises or emit `did-fail-load` as specified. No broad proxy that returns `undefined` for arbitrary methods.

| Role / API | Status | Signature, options, result and events |
| --- | --- | --- |
| Main `app` | S | `whenReady() -> Promise<void>`; `isReady() -> boolean`; `quit() -> void`; `exit(code = 0) -> void` (force stop, no cancelable quit); `getVersion() -> string` from packaged metadata. `ready`, `before-quit(event)`, `will-quit(event)`, `quit(event, exitCode)`, `window-all-closed`, `activate` (macOS only). `before-quit`/`will-quit` accept synchronous `preventDefault`; asynchronous cancellation is not supported. |
| Main `new BrowserWindow(options = {})` | G | After readiness only. Options: `width=800`, `height=600` positive integers, `title=''`, `show=true`, `resizable=true`, `webPreferences: {preload?: absolute .mjs path, contextIsolation: true, nodeIntegration: false, sandbox: true}` only. Returns window with unique `id` and `webContents`; unsupported/false security settings reject construction. Native window creation and `show:false` semantics require platform verification. |
| Main `BrowserWindow.getAllWindows()` | S | `BrowserWindow[]` of live windows, stable object identities. |
| Window methods | G | `loadFile(filePath: string) -> Promise<void>`; `loadURL(url: string) -> Promise<void>` (v1 only packaged app origin or explicit allowlisted loopback HTTP(S)); `show()`, `hide()`, `close()`, `destroy() -> void`; `isDestroyed()`, `isVisible() -> boolean`. `close` emits cancelable `close(event)` then `closed`; `destroy` skips `close`, emits `closed`. `show`/`hide` emit same-name events on actual state transition; `ready-to-show` only when first paint can be observed, otherwise **do not expose it and revise the sample**. `load*` rejects on load error, emits `webContents.did-fail-load`; successful load emits `webContents.did-finish-load`. No `executeJavaScript`, DevTools, browser history, window bounds, capture, or `webviewTag`. |
| Main `win.webContents` | G | Readonly per-window object: `send(channel: string, ...cloneable: unknown[]) -> void`, `getURL() -> string`, `isDestroyed() -> boolean`. `did-finish-load`, `did-fail-load(event, errorCode, errorDescription, validatedURL)`; `send` queues until bridge ready, bounded queue; rejects synchronously for invalid channel, payload, closed window, or limit. No synchronous IPC or arbitrary page JS execution. |
| Main `ipcMain` | S | `handle(channel: string, listener: (event, ...args) => unknown | Promise<unknown>) -> void`; `removeHandler(channel) -> void`; `on(channel, listener: (event, ...args) => void) -> this`. Duplicate `handle` throws; `event.sender` is a stable `webContents`, `event.senderFrame` is **not** supplied. Handler exceptions reject invoking promise with a sanitized error message/code, never native stacks. `on` is for `send` only; registering reserved internal channel throws. |
| Preload `ipcRenderer` | S | `invoke(channel, ...args) -> Promise<cloneable>`; `send(channel, ...args) -> void`; `on(channel, (event, ...args) => void) -> this`; `removeListener(channel, fn) -> this`. Events from main `webContents.send` only; `event.sender` is not exposed. No `sendSync`, `postMessage`, or MessagePort. Pending invocations reject `ERR_WINDOW_CLOSED` on close/navigation. |
| Preload `contextBridge` | G | `exposeInMainWorld(key: string, api: object) -> void`, only before first page script, unique non-reserved key; bounded plain JSON-like data and explicitly wrapped functions returning cloneable values/promises. Repeated keys, prototypes/accessors, native handles, cycles, functions nested in non-allowlisted shapes and oversized payloads throw `ERR_BRIDGE_UNSUPPORTED_VALUE`. Exposed data is copied/frozen where feasible; functions are RPC proxies, not shared references. No `executeInMainWorld`. |
| Main `dialog` | G | `showOpenDialog([browserWindow], options?: {title?: string, defaultPath?: string, buttonLabel?: string, filters?: {name:string, extensions:string[]}[], properties?: ('openFile'|'openDirectory'|'multiSelections')[]}) -> Promise<{canceled:boolean,filePaths:string[]}>`; cancellation resolves `{canceled:true,filePaths:[]}`. Native OS picker **only**, backed by an audited OS adapter; no browser `<input type=file>` path masquerading as a native dialog. `showSaveDialog` and `showMessageBox` are outside v1. |
| Main `shell` | G | `openExternal(url: string) -> Promise<void>` only `https:`/`http:` with explicit confirmation/allowlist policy; reject other schemes and remote links from untrusted IPC. `openPath` is outside v1. |
| Tray / Menu / Notification | U | No `Tray`, `Menu`, `MenuItem`, or `Notification` export in v1. Possible later scoped adapters below; do not expose placeholders. |
| Other Electron namespaces | U | `session`, `protocol`, `nativeImage`, `screen`, `globalShortcut`, `powerMonitor`, `autoUpdater`, `webFrame`, `webUtils`, `crashReporter`, `utilityProcess`, `webContents` global registry, etc. fail named-import linkage; no blanket compatibility assertion. |

`loadURL` never silently opens an external browser. Native dialogs are separate from DOM file pickers: browser `<input type=file>` may return browser-managed handles, not OS paths, and must not be fed to `showOpenDialog` semantics. Renderer is untrusted even when HTML is packaged.

## Post-v1 scoped API roadmap (not v1 commitments)

Each row below is a *candidate main-process ESM named export* from `electron`, absent until its own native adapter, security review and per-OS tests pass. Preload retains only its v1 gated imports; the browser renderer receives only explicitly bridged methods, never these objects. The signatures are proposed jsz subsets, not promises of Electron parity; unsupported options must fail rather than be ignored. No native library is assumed to provide a capability merely because its README mentions it. Stage A follows the v1 F0–F4 gates; stages B and C are independent opt-in releases, and each feature may remain unavailable on some platforms.

| Stage / candidate | Proposed scoped signature | Required gate and limitation |
| --- | --- | --- |
| A: `app` paths | `app.getPath(name: 'home'|'appData'|'userData'|'temp') -> string`; `app.setPath(name: 'userData', absolutePath: string) -> void` before first access | Audit OS directory conventions and writable permissions, sandbox/packaging behavior, canonicalization and symlink escapes; do not claim every Electron path name or create directories implicitly. Test macOS/Windows/Linux individually. |
| A: window controls | `win.minimize()`, `win.restore()`, `win.maximize()`, `win.unmaximize() -> void`; `win.isMinimized()`, `win.isMaximized() -> boolean`; `win.setTitle(title: string) -> void` | Verify native state transitions, event ordering and close races on each window manager (Wayland may restrict control); expose only operations with observable behavior. Existing v1 `show`, `hide`, `close`, `destroy` stay as specified; no bounds/always-on-top parity implied. |
| A: `dialog` additions | `showSaveDialog([browserWindow], options?: {title?: string, defaultPath?: string, buttonLabel?: string, filters?: {name:string, extensions:string[]}[]}) -> Promise<{canceled:boolean,filePath?:string}>`; `showMessageBox([browserWindow], options: {type?: 'none'|'info'|'warning'|'error', message:string, detail?:string, buttons?:string[], defaultId?:number, cancelId?:number}) -> Promise<{response:number}>` | Independently audit native save and message-box adapters; cancellation for save yields `{canceled:true}`; define and test close/escape response and modality before shipping message box. Enforce validated paths/buttons, UI-thread dispatch, no fake DOM dialogs, and per-platform smoke. |
| A: `shell` addition | `openPath(path: string) -> Promise<string>` (empty string on success, diagnostic string on OS failure) | Accept canonical, authorized local absolute paths only; never pass untrusted IPC input to an OS launcher. Audit shell argument handling and path traversal; no arbitrary scheme launch. |
| A: `nativeTheme` | `nativeTheme.shouldUseDarkColors: boolean` (readonly), `nativeTheme.on('updated', listener)` / `.off('updated', listener)` | Require real OS appearance observation and UI-to-JS thread marshaling; test light/dark changes and listener teardown per platform. Do not imply theme-source overrides or reliable Linux portal availability. |
| B: `Menu` / `MenuItem` | `Menu.buildFromTemplate(items: MenuItemOptions[]) -> Menu`; `Menu.setApplicationMenu(menu: Menu|null) -> void`; `new MenuItem(options: MenuItemOptions)`; `menu.append(item: MenuItem) -> void`. `MenuItemOptions = {label:string, type?:'normal'|'separator'|'checkbox', enabled?:boolean, checked?:boolean, click?:() => void, submenu?: MenuItemOptions[]}`. | Probe ztray or another audited native adapter with Zig 0.17; validate nested template depth, callback ownership, accelerator omission, update/removal and teardown. macOS requires AppKit main-thread menu handling and app menu semantics; Windows needs message-loop dispatch; Linux desktop/global-menu behavior varies, so disable unsupported variants explicitly. No renderer callbacks, arbitrary HTML menu or full Electron roles/accelerators in this subset. |
| B: `Tray` | `new Tray(iconPath: string)`; `tray.setToolTip(text: string) -> void`; `tray.setContextMenu(menu: Menu) -> void`; `tray.destroy() -> void`; `tray.on('click', listener)` / `.off('click', listener)` only if OS delivers clicks | Gate on a proven icon-file format/packaged-resource loader, UI thread and callback lifetime, ztray integration and real desktop smoke. macOS status item and Windows notification area differ; Linux StatusNotifier/AppIndicator and session D-Bus may be absent or suppress click events. Constructor must fail visibly where unusable; no guarantee of icon visibility or click delivery. |
| C: `Notification` | `new Notification({title:string, body?:string})`; `notification.show() -> void`; `notification.on('click'|'close'|'failed', listener)` / `.off(...)` only for events the backend actually provides; `Notification.isSupported() -> boolean` | First verify permissions, OS notification service, app identity and async delivery/cleanup, then specify exact events per supported backend. zig-notify's advertised macOS 13+ osascript/Linux libnotify paths need build/runtime and escaping probes; it has no advertised Windows backend. A Windows adapter needs separate proof. Do not synthesize click events or treat successful submission as display. |

For B, prove a menu-only UI-thread/event-pump spike before exposing `Menu` or `MenuItem`; then test tray creation, icon loading, menu association, missing Linux service, events and shutdown on each advertised OS. For C, isolate notification submission from the JS event loop, test denied permissions, absent daemon, injection-safe text, repeated delivery and teardown; gate each OS and event separately. Neither milestone is required for v1 release, and failure does not widen v1's backend promise. Any later IPC exposure of these privileged actions requires separately reviewed, narrow application methods and sender checks.

## Lifecycle, browser model and security

State machine: uninitialized -> initializing -> ready -> quitting -> terminated. `whenReady` resolves on the JS task after GUI/bridge initialization, rejecting on startup failure. Before ready, `new BrowserWindow` throws `ERR_APP_NOT_READY`. Each window owns a native handle, webContents identity, preload context, pending IPC map, and explicit loop ref. Closing the last window emits `window-all-closed`; absent listener, quit on all OSes (Electron behavior). With listener, caller controls quit (sample retains macOS process). `quit()` emits cancelable `before-quit`, asks windows to close, then `will-quit` and `quit`; canceled window close aborts quit. `exit()` bypasses those events; signal/exception shutdown follows existing `Runtime.finish` semantics and must be tested separately. Close must reject pending loads/IPC, release refs once, drop callbacks and native handles in defined order. Native callbacks must not invoke QuickJS directly.

Choose **embedded OS WebView** for `BrowserWindow`: WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux, subject to a real zig-webui spike. These are different engines/versions, not bundled Chromium; styling, CSP, navigation, cookies, permissions and DevTools are not Electron-parity. zig-webui's standard browser mode is a separate potential `--desktop-browser=external` experiment: it requires an installed browser, may have tab/window/profile differences, cannot honor `show`, hide, close or preload ordering identically, and thus must not claim the same API until demonstrated. If embedded mode or isolation cannot work reliably on a target, disable that target/feature with an explicit startup error.

A proposed preload is a jsz QuickJS isolate, **not a Chromium isolated world nor an OS sandbox**; WebUI's browser bridge by itself is neither an isolated preload nor a trusted sender identity. Browser page and jsz contexts would communicate only through a narrowly framed, separately audited transport. Threat model: malicious page content, navigation, localhost cross-origin requests, injected browser extensions, stale-window IDs, reconnects after navigation or WebView restart, oversized messages and forged channel names. Bind transport to a per-window, per-navigation unguessable session; on each reconnect invalidate the old session, reject/revoke pending calls and bridge capabilities, revalidate exact origin, window identity and navigation epoch before delivering any message (none of these checks alone is a security boundary). Require a testable handshake that cannot be claimed by a different tab, frame or local client; if backend APIs cannot prove sender binding, **disable privileged IPC/preload** rather than relying on token secrecy alone. Deny non-app navigation by default, restrict access to localhost server, protect against DNS rebinding/CSRF, set strict CSP and response MIME types, and validate sender and arguments again in `ipcMain`. Do not expose `ipcRenderer` or generic `send(channel, ...)` in page world. Cap message size, concurrency and queue length; reject cycles and unknown types. No claim that `sandbox:true` enables Electron/Chromium OS sandbox: it means the jsz bridge restricts capabilities, and must be documented as a compatibility setting with distinct guarantees. Security review and hostile-page tests are release gates, not optional polish. No remote URL gets privileged preload in v1.

## Native integration and platform gates

- **zig-webui** (`webui-dev/zig-webui`) advertises Zig 0.16/0.17 CI and WebView plus external-browser modes. Pin commit, compile a minimal 0.17 executable with this repo's target/optimize and link settings, run on each OS, verify WebView availability, first-paint and navigation callbacks, pre-document script injection, local content handler/CSP, thread affinity and wake integration. Its C callbacks may run on worker threads; copy owned data into a bounded queue and wake the JS task. Do not rely on `webui_wait()` blocking jsz's event loop. If pre-document injection is absent, preload v1 is blocked pending a separate native backend/patch.
- **ztray** (`StaffinityAI/ztray`) supports Zig >=0.16 and native menus/tray, with `pumpEvents()` on the owning UI thread; it is **not required for v1**. Gate future `Tray`/`Menu` work on 0.17 compile and GUI-pump coexistence, macOS AppKit main thread, Windows message loop, Linux session D-Bus/StatusNotifier availability; Linux tray success does not guarantee a visible icon. No DVUI dependency for core.
- **zig-notify** (`Jesssullivan/zig-notify`) describes Zig >=0.15.2, macOS 13+ `osascript` and Linux libnotify; **no Windows backend** and not an Electron Notification replacement. Gate a future `Notification` subset on 0.17 build, OS runtime tests, permission semantics, daemon availability, async/nonblocking delivery and escaping of title/body to avoid command injection. Do not add it to a universal dependency graph without platform guards.

Pump plan: one designated JS task owns every QuickJS context; OS UI thread requirements must be reconciled with current `zio.Runtime.init(.executors=.exact(1), .enable_main_executor=false)` and sync child-process bridging before GUI code lands. WebUI/native callbacks can arrive from other threads and must never dereference `Host`, invoke JS or retain borrowed event buffers: copy plain owned data into a bounded thread-safe queue, enqueue to `jobs.Queue` and wake the JS task. JS task drains them and microtasks before next GUI event. Integrate native event wake source with `EventLoop.run` deadline/queue wait and timers, using bounded batches and backpressure; no busy polling and no nested GUI run loop from JS. If AppKit requires a main-thread pump, spike an architecture where main UI thread pumps while the JS task remains single-owner, and serialize all native UI calls onto that thread; do not assume zio task == OS main thread. Record shutdown sequence and verify no use-after-free/reentrancy. Check Zig APIs using `mise exec -- zigdoc` before writing any Zig; dependency APIs require pinned-source inspection and 0.17 compile probes where zigdoc cannot resolve them.

| Target | v1 candidate | Required release proof / honest limitation |
| --- | --- | --- |
| macOS arm64/x86_64 | Embedded WKWebView candidate | Main-thread Cocoa pump, codesigned app bundle, local resource loading/preload ordering; ztray menu later; notification via osascript later. |
| Windows x86_64 | Embedded WebView2 candidate | WebView2 runtime availability/install messaging, native message loop, packaging and path handling; no zig-notify. ARM64 separate gate. |
| Linux x86_64 | Embedded WebKitGTK candidate | GTK/WebKitGTK system packages, X11/Wayland smoke, display/server session, native picker; headless CI skips visible GUI. aarch64 separate gate. |
| Headless/CI/unsupported OS | No GUI guarantee | Resolver and IPC unit tests can run headless with fake backend; GUI launch must fail explicitly, not pretend a window exists. |

## Packaging and loading

Explicit `jsz --desktop path/to/main.mjs` development entry; no `package.json` main resolution, npm dependencies, asar loading or Electron Forge/builder compatibility in v1. Production packaging proposal: signed/notarized OS app or platform installer containing jsz binary, main/preload modules, immutable renderer assets and manifest (app ID/version, allowed entry, resource root, allowed origins). Resolve canonical resource paths within package root, reject `..`, symlink escapes, unknown schemes and unexpected MIME; never interpret untrusted URL as local file. Prefer immutable embedded resources or a loopback server bound to 127.0.0.1 with secret-bound requests, strict origin/CSP, no wildcard CORS or open HTTP listener. Windows WebView2 and Linux WebKitGTK are system prerequisites, not bundled Chromium. Signing, notarization, installer, auto-update and resource integrity workflow require separate designs; no `asar` or Electron-specific metadata claim. `loadFile` resolves explicitly supplied absolute path or packaged-root-relative path (not cwd-dependent once packaged); missing resources reject. Dev mode may allow only explicit loopback origins, never automatic remote-site elevation.

## Staged feasibility gates (stop/go before shipping)

These are sequential proofs, not implementation milestones. Record the pinned commit, target OS/runtime, probe source, observable pass/fail result and fallback decision for each; failure blocks dependent API exports and examples. Do not reinterpret a browser transport as proof of preload isolation.

1. **F0 — toolchain and backend:** pin Electron-doc baseline and dependency commits; compile/link WebUI on Zig 0.17 for each proposed target and display a real local page. Failure: target unsupported; no implicit external-browser fallback.
2. **F1 — pump/thread ownership:** instrument callback thread IDs and borrowed-data lifetimes; prove callbacks are copied/marshaled to a single QuickJS-owning task, while the required OS main/UI thread pumps without starving zio timers, I/O or shutdown. Exercise idle GUI, burst events, concurrent I/O, close/reopen and sync child-process calls. Failure: redesign scheduler/backend before exposing windows.
3. **F2 — content and event semantics:** prove package-scoped load, navigation denial, load success/error, first paint if advertised, close/show/hide and exact cleanup on each OS. If first paint cannot be observed, omit `ready-to-show` and change the example; if window semantics fail, do not claim `BrowserWindow` on that target.
4. **F3 — privileged preload and IPC:** prove before-page-script bridge installation, restricted QuickJS preload context, per-window/navigation sender binding and reconnect revocation. Attack probes must cover other frame/tab/local client, URL changes and reload, stale token/window IDs, close races, forged origin, oversized payloads and pending promises. Failure: **no preload/contextBridge/ipcRenderer or privileged renderer IPC**, even if a WebUI callback mechanism works; revise sample and support matrix before release.
5. **F4 — native platform extras and release:** separately prove OS picker, URL opener, packaging and asset integrity, signed artifact/prerequisite behavior, and native GUI smoke. Unsupported platform-specific exports stay absent; tests/documentation name precise supported configurations.

## Ordered implementation plan (future work, no changes in this RFC)

1. **Version and feasibility gate:** run F0–F3 with disposable probes; record pass/fail per OS before promising `BrowserWindow` or preload. No production code until F1/F2 are viable; no privileged preload until F3 passes.
2. **Resolver and role skeleton:** `src/module.zig` canonical `electron` registration and role-aware export gate; `src/builtins/electron_main.js`, `src/builtins/electron_preload.js` wrappers; `src/js/host.zig` role/capability state; `tests/zig/module_test.zig` plus `tests/fixtures/electron/` for identity, restricted exports, errors, ESM sample. Only role-appropriate ESM imports are proposed in this phase.
3. **App lifecycle and backend seam:** `src/desktop.zig` owns desktop lifetime/handles and fake backend; `src/runtime.zig` opt-in desktop initialization and teardown; `src/cli/cli.zig` explicit CLI switch; `src/event_loop.zig`/`src/jobs.zig` bounded GUI wake/dispatch. Test cancellation, timers and shutdown without a display.
4. **Native WebView windows:** add pinned zig-webui to `build.zig.zon` and platform-conditional wiring to `build.zig`, backend implementation in `src/desktop/webview.zig`, JS facade in `src/builtins/electron_main.js`; verify lifecycle, first-paint and load/error signals; fail unsupported options early. Do not ship if preload ordering is unresolved.
5. **Preload bridge and IPC:** `src/desktop/bridge.zig`, `src/js/electron.zig` private binding and per-window isolated QuickJS context, `src/builtins/electron_preload.js`; origin/token checks, structured-copy subset, channels, quotas, cleanup; hostile-page tests and cross-window sender tests.
6. **Dialogs and shell (separately gated):** `src/desktop/dialog.zig` per-OS native picker, `src/desktop/shell.zig` URL allowlist; never use DOM picker as a fake native result. Add only platforms passing interactive tests.
7. **Distribution/release:** `examples/electron/`, `tests/fixtures/electron/`, `tests/zig/electron_test.zig` registered via `tests/zig/main.zig`; OS smoke workflows under `.forgejo/workflows/`; documentation updates to `README.md`, `docs/cli.md`, `docs/testing.md`, `docs/roadmap.md` only when implementation ships. Package/signing design and support table audited against observed results. Post-v1 path, window, dialog and shell additions and the independent menu/tray/notification stages above require their own release gates.

## Test and acceptance gates

- Headless module tests: role-specific named imports, absent ESM exports, `node:electron` rejection, disabled-desktop error, no package fallback, stable identities and no leaked contexts.
- Fake backend: ready/quit cancellation, zero/multiple windows, macOS activate, canceled close, destroy, exact ref accounting; event ordering and load rejection; IPC duplicate handlers, sender identity, errors, navigation/close races, ordering and size limits; microtasks/timers and zio I/O stay live under GUI traffic; allocator leak checks.
- Real macOS, Windows and Linux display tests: launch sample, click and cancel native picker, load assets, close/reopen, accessibility/first paint, wrong-origin requests, disabled scripting preloads and unavailable WebView runtime; tests on each claimed OS in CI with interactive smoke where CI cannot validate GUI. Capture OS/version/backend evidence.
- Security gate: adversarial HTML cannot import `electron`, access Node/QuickJS globals, invoke unauthorized channels, spoof another window/frame/client, access local files through path traversal, bypass origin/CSP, reuse a bridge session on reload/reconnect, or keep privileged IPC or unresolved promises after navigation/close. Independent review of transport and packaged asset server. Fail closed if isolation or pre-document bridge cannot be proven.
- **Acceptance:** `jsz --desktop examples/electron/main.mjs` reproduces the three-file example on every *claimed* platform; supported calls match matrix return/event shape, unsupported calls fail visibly; no deadlock/busy spin/leak during closing, pending IPC, zio timers and shutdown; packaging does not expose privileged resources. Only then describe the implemented subset as Electron-shaped, with explicit OS and feature limitations. No numeric compatibility percentage without a measured corpus.

## Non-goals and open decisions

Non-goals: running arbitrary Electron apps; Chromium parity, Chrome extensions/DevTools protocol, renderer Node integration, native Node addons, Electron auto-updater, full protocol/session/permissions, `asar`, synchronous IPC, webview tag, GPU/OS sandbox equivalence, bundled Chromium, or silently replacing unsupported operations with no-ops.

Decide before implementation: (1) can zig-webui guarantee pre-page-script injection and a sufficiently isolated IPC transport? (2) What architecture satisfies AppKit main-thread requirements alongside zio and the existing sync child-process bridge? (3) Should the CLI flag be `--desktop`, and should a packaged manifest supersede it? (4) Should `show:false`/`ready-to-show` be gated out if first-paint detection differs? (5) Which native dialog adapters and which platform baseline can pass CI? (6) What exact serialization format, size bounds and error codes can be sustained? (7) Should external-browser mode use a separate API/flag instead of `BrowserWindow`? (8) What measured Electron-app corpus would justify a future coverage statement?

## References

- Electron 39.5.0: [process model](https://github.com/electron/electron/blob/v39.5.0/docs/tutorial/process-model.md), [app](https://github.com/electron/electron/blob/v39.5.0/docs/api/app.md), [BrowserWindow](https://github.com/electron/electron/blob/v39.5.0/docs/api/browser-window.md), [webContents](https://github.com/electron/electron/blob/v39.5.0/docs/api/web-contents.md), [IPC tutorial](https://github.com/electron/electron/blob/v39.5.0/docs/tutorial/ipc.md), [contextBridge](https://github.com/electron/electron/blob/v39.5.0/docs/api/context-bridge.md), [sandbox](https://github.com/electron/electron/blob/v39.5.0/docs/tutorial/sandbox.md), [security](https://github.com/electron/electron/blob/v39.5.0/docs/tutorial/security.md).
- Native candidates: [zig-webui](https://github.com/webui-dev/zig-webui) / [WebUI](https://github.com/webui-dev/webui), [ztray](https://github.com/StaffinityAI/ztray), [zig-notify](https://github.com/Jesssullivan/zig-notify). Their current README claims are feasibility inputs, **not** evidence of integration in jsz.
- Repository context: [architecture](architecture.md), [testing](testing.md), [roadmap](roadmap.md), [prior Node-compatibility plan](plan/plan.md), [README](../README.md).
