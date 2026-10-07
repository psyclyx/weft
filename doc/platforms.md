# Platforms

weft runs on Linux and macOS. Each build has one desktop **platform** (window,
input, event loop) chosen by the target OS, and one **GPU API** Skia renders
through, chosen by `-Dgpu`:

| OS    | Platform | GPU API (`-Dgpu`)              | Fonts      |
|-------|----------|--------------------------------|------------|
| Linux | Wayland  | `vulkan` (default) or `opengl` | fontconfig |
| macOS | Cocoa    | `opengl` (the only one)        | CoreText   |

Everything above these seams — core, the view, every plugin — is the same
code on both. [rendering.md](rendering.md) describes the seams; this document
describes what sits under them.

## The GPU API

Skia's Ganesh backend does all drawing, on whichever API the build targets.
The Skia shim is split to match (`src/skia/`): `shim.cpp` holds the canvas and
the frame, `shim_vulkan.cpp` and `shim_gl.cpp` create a GrDirectContext on
their API, and a build links only its own.

Each API has the same two targets in `gfx` (`gfx.context`, `gfx.headless`):

- **Vulkan** (`gfx/context.zig`, `gfx/headless_vulkan.zig`): Skia rasterizes
  into its own surface; the target copies the pixels into a swapchain image
  (or an offscreen image it reads back).
- **OpenGL** (`gfx/gl_context.zig`, `gfx/headless_gl.zig`): on screen, Skia
  draws straight into the window's default framebuffer and the target swaps
  it — nothing is copied. Headless, Skia draws into its own render target and
  reads the frame back.

`src/gl/` (`weft_gl`) is the one place weft binds a platform's GL, as `src/vk/`
is for Vulkan: EGL on Linux (Wayland windows through `wl_egl_window`; Mesa's
surfaceless platform or an EGL device offscreen), NSOpenGL/CGL on macOS. Both
ask for desktop GL 3.2+ core profile, so the Linux suite under
`-Dgpu=opengl` exercises the path a Mac runs. Neither waits for vertical sync
in a swap: weft draws only when something changed, and its frame loop must
never block on the display.

## Linux: Wayland

`src/platform/wayland.zig`: xdg-shell, xkbcommon, `wl_data_device` for the
clipboard. Key events carry xkb keysyms, and every binding is written in
xkb's keysym names.

## macOS: Cocoa

`src/platform/cocoa.zig` implements the Platform contract over AppKit, which
is driven from Objective-C (`src/platform/cocoa/window.m`) behind a C ABI —
AppKit is written for Objective-C, and compiling against its real headers is
how a Linux cross build checks that code at all. What has rules in it stays in
Zig, where the Linux suite runs it:

- **Keys** (`cocoa_keys.zig`) are translated into the same xkb keysyms and
  names Linux uses (`keysym.zig`, checked against libxkbcommon itself), with
  the same rules: a typed character names itself with Shift consumed; a chord
  names the unshifted key with Shift explicit; keys that type nothing are
  named by key code. Dead keys and input methods compose through AppKit's
  text input before weft sees the character.
- **Modifiers**: Control is `C-`, the LEFT Option key is Meta (`M-`), and
  Command is super (`s-`, Emacs's spelling). The right Option key stays the
  macOS typing modifier, so layouts that put `@`, `[` or `|` on Option still
  type them. Only the system's own shortcuts are claimed by the menu bar
  (⌘Q, ⌘H, ⌥⌘H, ⌘M, ⌃⌘F); every other ⌘ chord reaches the keymap as `s-<key>`.
- **Quit and close** (⌘Q, the Dock, the window's close button) are requests:
  weft decides, and may refuse while work is unsaved. A quit asked for by
  logout is answered the same way — so it cancels the logout, and weft quits
  on its own terms.
- **Held keys repeat**: weft turns off macOS's press-and-hold accent picker
  for itself (`ApplePressAndHoldEnabled`), which would otherwise swallow a
  held letter; accents remain a dead key or an input method away.
- **The event loop**: AppKit's events arrive on a Mach port, not an fd, so
  the platform owns the scheduler's sleep (`Scheduler.waiter`): it waits in
  AppKit's event queue with the scheduler's fds attached to the run loop as
  CFFileDescriptors. Either kind of wake ends the same sleep; nothing polls.
- **Pointer**: trackpad scrolling is pixel-precise, wheels step by line, and
  both feed the same gesture reducer as Wayland (`pointer.zig`). AppKit's
  Shift+wheel → horizontal conversion is undone, so `S-wheel-down` is one
  binding on both platforms.
- **Clipboard**: the pasteboard is read only when something pastes, and only
  if it changed — never on every copy another application makes.
- **Fonts**: CoreText resolves a family to a file; for the collections macOS
  keeps many families in (`.ttc`), the face index comes from the file itself
  (`font_provider/ttc.zig`).

Known limits:

- During a live window resize AppKit runs its own tracking loop, so the window
  shows its last frame stretched until the drag ends.
- Input methods compose, but their candidate window sits at the window's
  corner: weft does not report a caret position to AppKit yet.
- Launched from Finder or the Dock, weft.app inherits launchd's minimal `PATH`,
  not your shell's, so tools a plugin runs (git, rg, a language server) may not
  be found. Run the executable from a shell (`weft`, or
  `weft.app/Contents/MacOS/weft` — `open` goes through launchd too), or let a
  provider publish the shell's environment for the place (`core/env.zig`).
- Characters beyond Latin-1 are named `U<hex>` (`U20AC` for €), where xkb
  has older names for some (`EuroSign`); a binding written with xkb's legacy
  name for such a key does not match on a Mac.
- Apple Silicon only: the pinned nixpkgs has dropped x86_64-darwin.

`zig build` on macOS also installs `Applications/weft.app`, the install
prefix's layout under `Contents/`, so the bundled executable finds its
plugins exactly as `bin/weft` does.

## Building for macOS

On a Mac (macOS 14 or newer — nixpkgs' minimum for the libraries weft links),
the Nix shell provides everything, including the SDK:

```sh
nix-shell
zig build run -- README.md
```

From Linux, `nix/macos-cross.nix` builds the same thing against the macOS SDK
and nixpkgs' Darwin builds of every library (substituted from the binary
cache, not built). It cannot run the result, but it compiles all of it,
checks the Objective-C against AppKit's headers, and links every symbol:

```sh
nix-shell nix/macos-cross.nix --run 'zig build -Dtarget=aarch64-macos'
nix-shell nix/macos-cross.nix --run 'zig build -Dtarget=aarch64-macos test'  # links every test, runs none
```

## Keeping Linux out of the Mac

`std.os.linux` compiles for any target — a raw Linux syscall cross-compiles
to macOS without complaint and fails only when it runs. So a file that names
`std.os.linux` must be a Linux-only file: it opens with a comptime guard that
fails any non-Linux build that reaches it, and a source-scan test fails the
suite if a file uses `std.os.linux` without one. Everything compiled for both
OSes uses `std.posix`, libc, or another portable std API.
