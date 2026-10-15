# home-manager module: `programs.weft`. Installs weft wrapped so that it runs a
# config (by default the reference config/config.js the package ships), finds
# the grammars that config registers, and has its language servers on PATH —
# for `weft` from a shell, the desktop entry on Linux, and, on macOS, a
# `weft.app` that Finder and the Dock launch with no arguments and launchd's
# bare environment.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.weft;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  grammarDir = pkgs.callPackage ./grammars.nix { names = cfg.grammars; };

  # One set of wrapper arguments for both launchers, so the CLI and the app
  # cannot disagree about config or environment. `--config` goes first, so a
  # `--config` on the command line (the later one wins) still overrides it. The
  # declared grammars go FIRST on the grammar search path — an inherited
  # `WEFT_GRAMMAR_PATH` (weft's own dev shell exports one) is searched after
  # them, never instead. Programs go LAST on PATH: a project's own tools win.
  wrapArgs = lib.escapeShellArgs (
    lib.concatMap
      (flag: [
        "--add-flag"
        flag
      ])
      (
        [
          "--config"
          "${cfg.configDir}/${cfg.configFile}"
        ]
        ++ cfg.extraArgs
      )
    ++ [
      "--prefix"
      "WEFT_GRAMMAR_PATH"
      ":"
      "${grammarDir}"
    ]
    ++ lib.optionals (cfg.extraPackages != [ ]) [
      "--suffix"
      "PATH"
      ":"
      (lib.makeBinPath cfg.extraPackages)
    ]
  );

  # The wrapped binary runs the real one in place, so it still finds its plugins
  # beside itself (`<exe>/../lib/weft/plugins`) — the bundle needs only its
  # Info.plist, its icon and the wrapper.
  wrapped =
    pkgs.runCommand "weft-${cfg.package.version}-wrapped"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        inherit (cfg.package) meta;
      }
      (
        ''
          mkdir -p $out/bin
          makeWrapper ${cfg.package}/bin/weft $out/bin/weft ${wrapArgs}
          ln -s ${cfg.package}/share $out/share
        ''
        + lib.optionalString isDarwin ''
          app=Applications/weft.app/Contents
          mkdir -p $out/$app/MacOS
          cp ${cfg.package}/$app/Info.plist $out/$app/
          cp -r ${cfg.package}/$app/Resources $out/$app/
          makeWrapper ${cfg.package}/$app/MacOS/weft $out/$app/MacOS/weft ${wrapArgs}
        ''
      );
in
{
  options.programs.weft = {
    enable = lib.mkEnableOption "weft, the text editor";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.weft or (import ../. { inherit pkgs; }).packages.weft;
      defaultText = lib.literalExpression "pkgs.weft, or weft built from this repository";
      description = "The weft package to wrap.";
    };

    configDir = lib.mkOption {
      type = with lib.types; either path str;
      default = "${cfg.package}/share/weft/config";
      defaultText = lib.literalExpression ''"''${cfg.package}/share/weft/config"'';
      example = lib.literalExpression "./weft";
      description = ''
        The directory weft's config lives in: `weft.use(name)` imports the
        fragments beside it. A Nix path is copied into the store whole; a
        string outside the store is read live, so it can be edited without a
        rebuild (`app.reload-config` picks the change up).

        A config copied from this repository's `config/` sets
        `languages.query-root` to `"assets"`, which resolves against weft's
        working directory; point it at the package's
        `share/weft/queries` instead.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "config.js";
      example = "helix.js";
      description = ''
        The config in {option}`programs.weft.configDir` weft runs. The shipped
        directory has three: `config.js` (vim, the reference), `helix.js` and
        `ide.js` (conventional, non-modal).
      '';
    };

    grammars = lib.mkOption {
      type = with lib.types; listOf str;
      default = import ./grammar-names.nix;
      example = [
        "go"
        "rust"
      ];
      description = ''
        tree-sitter grammars on weft's grammar search path, by name
        (`pkgs.tree-sitter-grammars.tree-sitter-<name>`). The config decides
        which of them it registers; the default is the set the reference
        config does.
      '';
    };

    extraPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = with pkgs; [
        zls
        gopls
        go
        fennel-ls
        git
        ripgrep
      ];
      defaultText = lib.literalExpression "with pkgs; [ zls gopls go fennel-ls git ripgrep ]";
      description = ''
        Programs weft's plugins run — language servers, formatters, git and
        ripgrep — appended to its PATH. Appended, so a project's own (a direnv
        `zls` matching its Zig) wins; on macOS they are the only ones an app
        launched from Finder sees.
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [
        "--em"
        "18"
      ];
      description = "Arguments every launch of weft passes, after `--config`.";
    };

    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = wrapped;
      description = "The wrapped weft this module installs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # On macOS home-manager puts the bundle in ~/Applications/Home Manager Apps
    # (or copies it, with `targets.darwin.copyApps`).
    home.packages = [ cfg.finalPackage ];
  };
}
