//! Skia, compiled from its source by Zig: a static library against Zig's
//! libc++, so weft carries one C++ toolchain and one C++ runtime, builds the
//! same way with or without Nix, and cross-compiles Skia like any other C++.
//!
//! The file lists are not copied here. Skia generates them (from Bazel) into
//! `.gni` files of a fixed shape, `name = [ "$_src/x.cpp", ... ]`, and this
//! reads those lists at configure time — so a Skia bump needs no list edits.
//! What is chosen by hand is the *composition*: which lists make up which of
//! BUILD.gn's targets, under the one configuration weft builds. Each choice
//! cites the BUILD.gn target it mirrors; the configuration is, in GN's terms:
//!
//!   is_official_build=true is_component_build=false
//!   skia_use_vulkan=<-Dgpu=vulkan> skia_use_gl=<-Dgpu=opengl>
//!   skia_use_egl=false skia_use_x11=false     (weft hands Skia its GL procs)
//!   skia_use_freetype=true skia_use_fontconfig=false skia_use_fonthost_mac=false
//!   skia_enable_fontmgr_custom_empty=true     (every other font manager off)
//!   skia_enable_svg=true skia_use_expat=true  (system expat and FreeType)
//!   skia_use_icu=false skia_use_harfbuzz=false   (SVG text: primitive shaper)
//!   skia_enable_pdf=false skia_use_xps=false skia_use_zlib=false
//!   every image codec off but BMP/WBMP, which core always has
//!
//! plus one define GN never sets: SK_USE_VMA, which Ganesh's Vulkan backend
//! needs to make its own memory allocator (Bazel sets it; GN's build leaves
//! a client to supply one, and weft supplies none).

const std = @import("std");

pub const Backend = enum { vulkan, opengl };

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    backend: Backend,
    /// The Skia source tree (build.zig.zon `skia`).
    source: *std.Build.Dependency,
    /// VulkanMemoryAllocator's source (build.zig.zon `vulkan_memory_allocator`):
    /// Skia's Vulkan backend includes `vk_mem_alloc.h`. Vulkan builds only.
    vma: ?*std.Build.Dependency,
    /// The macOS SDK, for a macOS target: GN compiles Skia's Mac utilities
    /// (src/utils/mac: CoreGraphics and CoreText glue) into every Mac Skia.
    macos_sdk: ?[]const u8,
};

/// The pkg-config packages Skia's code calls into, which whatever links
/// Skia must link too: FreeType and expat.
pub const system_libraries = [_][]const u8{ "freetype2", "expat" };

/// The compiled library and what a translation unit compiled against its
/// headers must agree with it on.
pub const Skia = struct {
    library: *std.Build.Step.Compile,
    /// The defines that change what Skia's PUBLIC headers declare (or how they
    /// lay out a type): a client compiled without them sees a different API.
    public_flags: []const []const u8,
    /// The frameworks whatever links Skia must link too (macOS).
    frameworks: []const []const u8,
    /// The source tree's root: Skia's own `#include "include/core/..."`
    /// convention, which clients follow too.
    root: std.Build.LazyPath,
};

/// Flags every C++ unit compiled against Skia uses, Skia's own and its
/// clients': C++20 (Skia needs it), and no exceptions or RTTI (Skia is
/// written without them, and neither crosses the C ABI to Zig).
pub const cxx_flags = [_][]const u8{ "-std=c++20", "-fno-exceptions", "-fno-rtti" };

pub fn build(b: *std.Build, opts: Options) Skia {
    const target = opts.target.result;
    const x86_64 = target.cpu.arch == .x86_64;
    const linux = target.os.tag == .linux;
    const macos = target.os.tag == .macos;
    const vulkan = opts.backend == .vulkan;
    const src = opts.source;

    var lists = Gni.init(b, src);
    for ([_][]const u8{
        "gn/codec.gni",                "gn/core.gni",                         "gn/effects.gni",
        "gn/effects_imagefilters.gni", "gn/gpu.gni",                          "gn/opts.gni",
        "gn/pathops.gni",              "gn/ports.gni",                        "gn/sksl.gni",
        "gn/svg.gni",                  "gn/utils.gni",                        "gn/xml.gni",
        "modules/skcms/skcms.gni",     "modules/skresources/skresources.gni", "modules/skshaper/skshaper.gni",
        "modules/svg/svg.gni",
    }) |file| lists.load(file);

    // ---- Public defines (BUILD.gn `skia_public`, and every enabled
    // `optional`'s `public_defines`) ----
    var public: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), items: []const []const u8) void {
            list.appendSlice(alloc, items) catch @panic("OOM");
        }
    }.f;
    add(b.allocator, &public, &.{
        // Release, said outright: the shim is compiled in weft's own optimize
        // mode, and Skia's headers lay types out differently under SK_DEBUG.
        "-DSK_RELEASE",
        "-DSK_CODEC_DECODES_BMP",
        "-DSK_CODEC_DECODES_WBMP",
        "-DSK_ENABLE_PRECOMPILE",
        "-DSK_GANESH",
        "-DSK_DISABLE_TRACING", // is_official_build
        "-DSK_TYPEFACE_FACTORY_FREETYPE", // :typeface_freetype
        "-DSK_FONTMGR_FREETYPE_EMPTY_AVAILABLE", // :fontmgr_custom_empty
        "-DSK_XML", // :xml
        "-DSK_ENABLE_SVG", // modules/svg
        "-DSK_SHAPER_PRIMITIVE_AVAILABLE", // modules/skshaper
    });
    if (linux) add(b.allocator, &public, &.{"-DSK_R32_SHIFT=16"});
    if (macos) add(b.allocator, &public, &.{"-DSK_ASSUME_GL=1"}); // skia_gl_standard = "gl"
    add(b.allocator, &public, if (vulkan) &.{
        "-DSK_VULKAN", // :gpu_shared
        // `use_skia_vulkan_headers`: the Vulkan headers in Skia's tree, so a
        // client's own Vulkan headers never have to match Skia's.
        "-DSK_USE_INTERNAL_VULKAN_HEADERS",
    } else &.{"-DSK_GL"});

    // ---- The library's own flags (`skia_private`, `skia_library`, and
    // gn/skia/BUILD.gn's defaults for a non-Windows clang) ----
    var flags: std.ArrayList([]const u8) = .empty;
    add(b.allocator, &flags, &cxx_flags);
    add(b.allocator, &flags, public.items);
    add(b.allocator, &flags, &.{
        "-DNDEBUG",
        "-DSK_GAMMA_APPLY_TO_A8",
        "-DSK_ENABLE_AVX512_OPTS",
        "-DSKIA_IMPLEMENTATION=1",
        "-DSKSHAPER_IMPLEMENTATION=1",
        // gn/skia/BUILD.gn's `optimize` for a release build: -O3 (Zig's
        // ReleaseFast says -O2 to clang), each function and datum in its own
        // section so the link drops what weft never calls.
        "-O3",
        "-ffunction-sections",
        "-fdata-sections",
        "-fstrict-aliasing",
        "-ffp-contract=off",
        "-fvisibility=hidden",
        "-fvisibility-inlines-hidden",
        // Skia is not weft's code to keep warning-clean; its own build is
        // what holds it to that.
        "-w",
    });
    if (macos) {
        // The SDK's own headers searched last, as weft's other Mac sources
        // do (build.zig `macosCFlags`): Zig's Darwin libc headers first.
        const sdk = opts.macos_sdk orelse @panic("a macOS Skia needs the macOS SDK");
        add(b.allocator, &flags, &.{ "-idirafter", b.pathJoin(&.{ sdk, "usr/include" }) });
    }
    if (vulkan) add(b.allocator, &flags, &.{"-DSK_USE_VMA"});
    // Skia's assertion messages carry __FILE__: name its files from the
    // source root, not by the absolute path this machine fetched it to — a
    // Nix store path there would make the whole source tree a runtime
    // dependency of the binary.
    if (src.builder.build_root.path) |abs|
        add(b.allocator, &flags, &.{b.fmt("-fmacro-prefix-map={s}/=", .{abs})});

    // ---- Sources, target by target ----
    var sources: Sources = .{ .b = b };
    // :core, :pathops
    sources.addList(&lists, "skia_core_sources");
    sources.addList(&lists, "skia_pathops_sources");
    // :skia
    for ([_][]const u8{
        "skia_utils_private",            "skia_effects_sources",
        "skia_colorfilters_sources",     "skia_effects_imagefilter_sources",
        "skia_codec_shared",             "skia_codec_decode_bmp",
        "skia_encode_srcs",              "skia_sksl_core_sources",
        "skia_sksl_core_module_sources", "skia_sksl_tracing_sources",
        "skia_ports_sources",            "skia_android_core_srcs",
    }) |name| sources.addList(&lists, name);
    sources.add(&.{
        "src/android/SkAndroidFrameworkUtils.cpp",
        "src/codec/SkAndroidCodec.cpp",
        "src/codec/SkAndroidCodecAdapter.cpp",
        "src/codec/SkSampledCodec.cpp",
        "src/ports/SkDiscardableMemory_none.cpp",
        "src/ports/SkMemory_malloc.cpp",
        "src/sfnt/SkOTTable_name.cpp",
        "src/sfnt/SkOTUtils.cpp",
        // Not Windows; `is_linux` and `is_mac` alike.
        "src/ports/SkOSFile_posix.cpp",
        "src/ports/SkLog_stdio.cpp",
        // :pdf, disabled: its `sources_when_disabled`.
        "src/pdf/SkDocument_PDF_None.cpp",
    });
    sources.removeList(&lists, "skia_clipstack_utils_sources");
    // :typeface_freetype, :fontmgr_custom, :fontmgr_custom_empty
    sources.addList(&lists, "skia_ports_freetype_sources");
    sources.addList(&lists, "skia_ports_fontmgr_custom_sources");
    sources.addList(&lists, "skia_ports_fontmgr_empty_sources");
    // :xml
    sources.addList(&lists, "skia_xml_sources");
    sources.addList(&lists, "skia_codec_xmp");
    sources.addList(&lists, "skia_svg_writer_sources");
    // :gpu_shared
    sources.addList(&lists, "skia_shared_gpu_sources");
    sources.addList(&lists, "skia_sksl_pipeline_sources");
    sources.addList(&lists, "skia_sksl_codegen_sources");
    // :gpu
    sources.addList(&lists, "skia_ganesh_private");
    if (vulkan) {
        sources.addList(&lists, "skia_shared_vk_sources");
        sources.addList(&lists, "skia_vma_sources");
        sources.addList(&lists, "skia_gpu_vk_private");
    } else {
        sources.addList(&lists, "skia_gpu_gl_private");
        // No EGL, GLX or CGL: weft builds the GL interface from the procs it
        // hands Skia, so the native-interface lookup is the stub, everywhere.
        sources.addList(&lists, "skia_null_gpu_sources");
    }
    // modules/skcms (its x86 transforms below)
    sources.addList(&lists, "skcms_public");
    sources.addList(&lists, "skcms_TransformBaseline");
    // modules/skresources, modules/skshaper (primitive only), modules/svg
    sources.addList(&lists, "skia_skresources_sources");
    sources.addList(&lists, "skia_shaper_primitive_sources");
    sources.addList(&lists, "skia_svg_renderer_sources");

    // Skia is compiled optimized whatever weft's own mode: a Debug Skia is
    // slow to draw with, and Zig's Debug C++ would also instrument all of it
    // with UBSan. It is compiled once and cached either way. Frame pointers
    // are omitted, as GN's release build does (Zig keeps them by default).
    const root = src.path("");
    const module = struct {
        fn make(owner: *std.Build, skia: *std.Build.Dependency, target_: std.Build.ResolvedTarget, vk: bool) *std.Build.Module {
            const m = owner.createModule(.{
                .target = target_,
                .optimize = .ReleaseFast,
                .omit_frame_pointer = true,
                .link_libc = true,
                .link_libcpp = true,
            });
            m.addIncludePath(skia.path(""));
            for ([_][]const u8{ "modules/svg/include", "modules/skresources/include", "modules/skshaper/include" }) |dir|
                m.addIncludePath(skia.path(dir));
            if (vk) m.addIncludePath(skia.path("include/third_party/vulkan"));
            return m;
        }
    }.make;
    // Skia is built for the target's BASELINE CPU, whatever `-Dcpu` weft
    // itself is built for: it picks its fast paths at run time (SkOpts and
    // skcms, the per-CPU units below), which is how Skia is designed to be
    // built. It is measurably the faster build, too: on a Zen 3 host the
    // bench-raster frames took ~25% longer with Skia built for that host's
    // own CPU. And one cached Skia serves every `-Dcpu`.
    var baseline = opts.target.query;
    baseline.cpu_model = .baseline;
    baseline.cpu_features_add = .empty;
    baseline.cpu_features_sub = .empty;
    const mod = module(b, src, b.resolveTargetQuery(baseline), vulkan);
    if (opts.macos_sdk) |sdk| mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    mod.addCSourceFiles(.{ .root = root, .files = sources.items(), .flags = flags.items, .language = .cpp });

    // The CPU-specific units: each is compiled for the CPU it is named for
    // and only ever called after a runtime check that this CPU has it. GN
    // says so with `-march`; Zig, whose own CPU flags would override that,
    // with a target of that CPU — one small library apiece.
    var opt_libraries: std.ArrayList(*std.Build.Step.Compile) = .empty;
    if (x86_64) {
        const opt_units = [_]struct { name: []const u8, lists: []const []const u8, cpu: *const std.Target.Cpu.Model }{
            // :ml3 (`-march=haswell`), and skcms's :skcms_TransformHsw
            // (`-mavx2 -mf16c`, which Haswell has).
            .{ .name = "skia_haswell", .lists = &.{ "ml3", "skcms_TransformHsw" }, .cpu = &std.Target.x86.cpu.haswell },
            // :ml4 (`-march=skylake-avx512`), and :skcms_TransformSkx
            // (`-mavx512{f,dq,cd,bw,vl}`, which Skylake-AVX512 has).
            .{ .name = "skia_skylake_avx512", .lists = &.{ "ml4", "skcms_TransformSkx" }, .cpu = &std.Target.x86.cpu.skylake_avx512 },
        };
        for (opt_units) |unit| {
            var query = opts.target.query;
            query.cpu_model = .{ .explicit = unit.cpu };
            query.cpu_features_add = .empty;
            query.cpu_features_sub = .empty;
            const unit_mod = module(b, src, b.resolveTargetQuery(query), vulkan);
            for (unit.lists) |list|
                unit_mod.addCSourceFiles(.{ .root = root, .files = lists.sources(list), .flags = flags.items, .language = .cpp });
            const unit_library = b.addLibrary(.{ .linkage = .static, .name = unit.name, .root_module = unit_mod });
            opt_libraries.append(b.allocator, unit_library) catch @panic("OOM");
            mod.linkLibrary(unit_library);
        }
    } else {
        // skcms gates its x86 transforms itself only on x86_64.
        mod.addCMacro("SKCMS_DISABLE_HSW", "1");
        mod.addCMacro("SKCMS_DISABLE_SKX", "1");
    }

    if (vulkan) {
        // //src/gpu/vk/vulkanmemoryallocator: VMA's implementation, behind
        // Skia's wrapper (which includes `vk_mem_alloc.h` with the defines
        // Skia wants).
        const vma = opts.vma orelse @panic("the Vulkan backend needs VulkanMemoryAllocator (build.zig.zon `vulkan_memory_allocator`)");
        mod.addIncludePath(vma.path("include"));
        mod.addCSourceFiles(.{
            .root = root,
            .files = &.{"src/gpu/vk/vulkanmemoryallocator/VulkanMemoryAllocatorWrapper.cpp"},
            .flags = flags.items,
            .language = .cpp,
        });
    }

    // Third-party code Skia uses, from the system: FreeType for every font
    // weft draws, expat for SVG (src/xml). Only their headers here — the
    // binary that links Skia links them (`system_libraries`): a static
    // library given a shared one to link would archive the .so inside itself.
    for (system_libraries) |name| {
        const cflags = b.run(&.{ "pkg-config", "--cflags-only-I", name });
        var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
        while (it.next()) |flag| {
            if (!std.mem.startsWith(u8, flag, "-I")) continue;
            const dir: std.Build.LazyPath = .{ .cwd_relative = b.dupe(flag[2..]) };
            mod.addIncludePath(dir);
            for (opt_libraries.items) |unit| unit.root_module.addIncludePath(dir);
        }
    }

    const library = b.addLibrary(.{ .linkage = .static, .name = "skia", .root_module = mod });
    return .{
        .library = library,
        .public_flags = public.items,
        .root = root,
        // :skia's `frameworks` for `is_mac`, less OpenGL (weft's GL target
        // links it; Skia's GL calls go through the procs weft hands it).
        .frameworks = if (macos) &.{"ApplicationServices"} else &.{},
    };
}

/// The source lists Skia's `.gni` files define, by name, as paths relative
/// to the source root. Only C++ (and C) translation units are kept: the
/// lists name headers too, which are not compiled.
const Gni = struct {
    b: *std.Build,
    source: *std.Build.Dependency,
    lists: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn init(b: *std.Build, source: *std.Build.Dependency) Gni {
        return .{ .b = b, .source = source };
    }

    fn sources(self: *const Gni, name: []const u8) []const []const u8 {
        return self.lists.get(name) orelse
            std.debug.panic("Skia's .gni files define no source list `{s}`: has a Skia bump renamed it?", .{name});
    }

    /// Parse one `.gni` file. Its grammar, as Skia generates it: comments
    /// (`#` to end of line); `_x = get_path_info("<dir>", "abspath")`, which
    /// names a directory relative to the file; and `name = [ "<string>", ... ]`,
    /// whose strings begin `$_x/`. Anything else (`declare_args() {...}`) is
    /// stepped over. A list holding anything but strings is an error: that
    /// would be a generated file of a new shape, which this must not misread.
    fn load(self: *Gni, file: []const u8) void {
        const b = self.b;
        const text = self.source.builder.build_root.handle.readFileAlloc(b.graph.io, file, b.allocator, .unlimited) catch |err|
            std.debug.panic("reading Skia's {s}: {t}", .{ file, err });
        const dir = std.fs.path.dirname(file) orelse ".";
        var dirs: std.StringHashMapUnmanaged([]const u8) = .empty;
        var tokens = Tokenizer{ .text = text };
        var prev: [2]Token = .{ .none, .none };
        while (tokens.next()) |tok| {
            // `name = [`
            if (tok == .open_bracket and prev[1] == .equals and prev[0] == .ident) {
                var list: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const item = tokens.next() orelse std.debug.panic("{s}: unterminated list", .{file});
                    switch (item) {
                        .close_bracket => break,
                        .comma => {},
                        .string => |s| {
                            const path = expand(b, &dirs, file, s);
                            if (isTranslationUnit(path)) list.append(b.allocator, path) catch @panic("OOM");
                        },
                        else => std.debug.panic("{s}: a list holds something other than strings", .{file}),
                    }
                }
                self.lists.put(b.allocator, prev[0].ident, list.items) catch @panic("OOM");
                prev = .{ .none, .none };
                continue;
            }
            // `_x = get_path_info("<dir>", "abspath")`
            if (tok == .ident and std.mem.eql(u8, tok.ident, "get_path_info") and prev[1] == .equals and prev[0] == .ident) {
                if ((tokens.next() orelse Token.none) != .open_paren) std.debug.panic("{s}: get_path_info without arguments", .{file});
                const rel = switch (tokens.next() orelse .none) {
                    .string => |s| s,
                    else => std.debug.panic("{s}: get_path_info of a non-string", .{file}),
                };
                const resolved = std.fs.path.resolvePosix(b.allocator, &.{ dir, rel }) catch @panic("OOM");
                dirs.put(b.allocator, prev[0].ident, resolved) catch @panic("OOM");
            }
            prev = .{ prev[1], tok };
        }
    }

    fn expand(b: *std.Build, dirs: *const std.StringHashMapUnmanaged([]const u8), file: []const u8, s: []const u8) []const u8 {
        if (s.len == 0 or s[0] != '$') return s;
        const end = std.mem.indexOfScalar(u8, s, '/') orelse s.len;
        const dir = dirs.get(s[1..end]) orelse
            std.debug.panic("{s}: `{s}` names no directory the file defines", .{ file, s[0..end] });
        return b.fmt("{s}{s}", .{ dir, s[end..] });
    }

    fn isTranslationUnit(path: []const u8) bool {
        const ext = std.fs.path.extension(path);
        return std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".c");
    }
};

const Token = union(enum) {
    none,
    ident: []const u8,
    string: []const u8,
    equals,
    open_bracket,
    close_bracket,
    open_paren,
    comma,
    other,
};

const Tokenizer = struct {
    text: []const u8,
    i: usize = 0,

    fn next(t: *Tokenizer) ?Token {
        while (t.i < t.text.len) {
            const c = t.text[t.i];
            switch (c) {
                ' ', '\t', '\r', '\n' => t.i += 1,
                '#' => while (t.i < t.text.len and t.text[t.i] != '\n') {
                    t.i += 1;
                },
                '"' => {
                    const start = t.i + 1;
                    const end = std.mem.indexOfScalarPos(u8, t.text, start, '"') orelse return null;
                    t.i = end + 1;
                    return .{ .string = t.text[start..end] };
                },
                '=' => {
                    t.i += 1;
                    if (t.i < t.text.len and t.text[t.i] == '=') {
                        t.i += 1;
                        return .other;
                    }
                    return .equals;
                },
                '[' => {
                    t.i += 1;
                    return .open_bracket;
                },
                ']' => {
                    t.i += 1;
                    return .close_bracket;
                },
                '(' => {
                    t.i += 1;
                    return .open_paren;
                },
                ',' => {
                    t.i += 1;
                    return .comma;
                },
                else => {
                    if (std.ascii.isAlphabetic(c) or c == '_') {
                        const start = t.i;
                        while (t.i < t.text.len and (std.ascii.isAlphanumeric(t.text[t.i]) or t.text[t.i] == '_')) t.i += 1;
                        return .{ .ident = t.text[start..t.i] };
                    }
                    t.i += 1;
                    return .other;
                },
            }
        }
        return null;
    }
};

/// An ordered set of source paths: GN dedups a target's sources, and some
/// lists overlap.
const Sources = struct {
    b: *std.Build,
    list: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Sources, paths: []const []const u8) void {
        for (paths) |path| {
            const gop = self.seen.getOrPut(self.b.allocator, path) catch @panic("OOM");
            if (!gop.found_existing) self.list.append(self.b.allocator, path) catch @panic("OOM");
        }
    }

    fn addList(self: *Sources, lists: *const Gni, name: []const u8) void {
        self.add(lists.sources(name));
    }

    fn removeList(self: *Sources, lists: *const Gni, name: []const u8) void {
        for (lists.sources(name)) |path| {
            if (!self.seen.remove(path)) continue;
            for (self.list.items, 0..) |item, i| if (std.mem.eql(u8, item, path)) {
                _ = self.list.orderedRemove(i);
                break;
            };
        }
    }

    fn items(self: *const Sources) []const []const u8 {
        return self.list.items;
    }
};
