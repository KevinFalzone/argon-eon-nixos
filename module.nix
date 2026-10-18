# NixOS reimplementation of argoneon.sh for the Argon EON (Raspberry Pi NAS
# case with fan, RTC and OLED) -- CHECKDEVICE="eon", CHECKGPIOMODE="libgpiod"
# in the original installer.
#
# What this intentionally does NOT port, and why:
#   - apt-get/dpkg package install            -> replaced by Nix packages below
#   - raspi-config I2C/UART enabling          -> replaced by hardware.i2c.enable;
#                                                 firmware dtparam= lines still
#                                                 belong to whichever module owns
#                                                 your Pi's config.txt (see the
#                                                 assertion message below)
#   - the interactive argon-config / *-config.sh
#     menus that edit /etc/*.conf live via sudo tee
#                                              -> /etc is regenerated from the
#                                                 Nix store on every switch, so
#                                                 those edits wouldn't survive a
#                                                 rebuild anyway. Use the options
#                                                 below instead.
#   - IR remote config, BLSTR DAC, Argon Industria UPS, EEPROM updater,
#     desktop .desktop shortcut, argon-uninstall.sh
#                                              -> not applicable to a declarative
#                                                 NixOS/headless-NAS setup; omitted.
#
# What it does port: the argononed (fan curve + power button + OLED) and
# argoneond (RTC schedule/alarm) daemons, their systemd units, the
# system-shutdown hook that signals the MCU/RTC on poweroff, and the config
# files they read -- all generated declaratively from the options below
# instead of being hand-edited in /etc.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.argoneon;

  payload = pkgs.callPackage ./payload.nix { };

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.smbus-cffi ps.gpiod ]);

  # /etc/argon is assembled file-by-file (rather than pointing straight at
  # `payload`) so that disabling a feature actually removes the file argononed.py
  # probes for (e.g. `os.path.exists("/etc/argon/argoneonoled.py")`).
  etcArgon = pkgs.runCommand "argoneon-etc-argon" { } (''
    mkdir -p $out/oled
    ln -s ${payload}/argonsysinfo.py $out/argonsysinfo.py
    ln -s ${payload}/argonregister.py $out/argonregister.py
    ln -s ${payload}/argonpowerbutton.py $out/argonpowerbutton.py
    ln -s ${payload}/argononed.py $out/argononed.py
    ln -s ${payload}/argonstatus.py $out/argonstatus.py
    ln -s ${payload}/argondashboard.py $out/argondashboard.py
  ''
  + lib.optionalString cfg.rtc.enable ''
    ln -s ${payload}/argonrtc.py $out/argonrtc.py
    ln -s ${payload}/argoneond.py $out/argoneond.py
  ''
  + lib.optionalString cfg.oled.enable ''
    ln -s ${payload}/argoneonoled.py $out/argoneonoled.py
    for f in ${payload}/oled/*; do
      ln -s "$f" "$out/oled/$(basename "$f")"
    done
  '');

  fanCurveConfig = comment: curve: ''
    #
    # ${comment}
    #
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (t: s: "${t}=${toString s}") curve)}
  '';

  oledConfig = ''
    #
    # Argon OLED Configuration
    #
    switchduration=${toString cfg.oled.switchDuration}
    screensaver=${toString cfg.oled.screensaverSeconds}
    screenlist="${lib.concatStringsSep " " cfg.oled.screens}"
  '';

  unitConfig = ''
    #
    # Argon Unit Configuration
    #
    temperature=${cfg.unitsTemperature}
  '';

  rtcConfig = ''
    #
    # Argon RTC Configuration
    # - Follows cron general format, but with only * and csv support
    # - Each row: min hour date month dayOfWeek command(on|off)
    #     e.g. shutdown daily at 1am:      0 1 * * * off
    #     e.g. shutdown daily at 1/13:00:  0 1,13 * * * off
    #
    ${lib.concatStringsSep "\n" cfg.rtc.schedule}
  '';

  shutdownScript = pkgs.writeShellScript "argon-shutdown.sh" ''
    #!${pkgs.runtimeShell}
    # Runs as a systemd-shutdown hook: turns the fan off and (if fitted)
    # tells the RTC/MCU that this is a clean shutdown rather than a crash.
    PY=${pythonEnv}/bin/python3
    FAN=/etc/argon/argononed.py

    if [ -n "$1" ]; then
      [ -f "$FAN" ] && "$PY" "$FAN" FANOFF
      case "$1" in
        poweroff|halt)
          ${lib.optionalString cfg.rtc.enable ''[ -f /etc/argon/argoneond.py ] && "$PY" /etc/argon/argoneond.py SHUTDOWN''}
          [ -f "$FAN" ] && "$PY" "$FAN" SHUTDOWN
          ;;
      esac
    fi
  '';

  statusCli = pkgs.writeShellScriptBin "argoneon-status" ''
    #!${pkgs.runtimeShell}
    # Read-only diagnostics (temperatures/fan speed/storage/RAID/RTC
    # schedule). Needs root for I2C + smartctl access, same as upstream.
    exec sudo ${pythonEnv}/bin/python3 /etc/argon/argondashboard.py "$@"
  '';

in
{
  options.services.argoneon = {
    enable = lib.mkEnableOption "the Argon EON fan/RTC/OLED controller daemons";

    fanCurve = lib.mkOption {
      type = lib.types.attrsOf (lib.types.ints.between 0 100);
      default = { "55" = 30; "60" = 55; "65" = 100; };
      example = { "50" = 25; "60" = 60; "70" = 100; };
      description = ''
        CPU-temperature-to-fan-speed curve. Attribute names are °C
        thresholds (as strings), values are fan duty cycle percent.
        Written to /etc/argononed.conf.
      '';
    };

    hddFanCurve = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf (lib.types.ints.between 0 100));
      default = { "35" = 30; "40" = 55; "45" = 100; };
      example = null;
      description = ''
        HDD-temperature-to-fan-speed curve (read via smartctl). The higher
        of the CPU-curve and HDD-curve speed always wins. Set to `null` to
        disable HDD-based fan control entirely (CPU temperature only).
        Written to /etc/argononed-hdd.conf.
      '';
    };

    unitsTemperature = lib.mkOption {
      type = lib.types.enum [ "C" "F" ];
      default = "C";
      description = "Temperature unit used on the OLED display.";
    };

    oled = {
      enable = lib.mkEnableOption "the EON's OLED status display" // { default = true; };

      switchDuration = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 30;
        description = "Seconds each OLED screen is shown before rotating to the next. 0 disables auto-rotation.";
      };

      screensaverSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 120;
        description = "Seconds of inactivity before the OLED screen blanks.";
      };

      screens = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "clock" "cpu" "storage" "raid" "ram" "temp" "ip" ]);
        default = [ "clock" "cpu" "storage" "raid" "ram" "temp" "ip" ];
        description = "Screens to rotate through on the OLED display, in order.";
      };
    };

    rtc = {
      enable = lib.mkEnableOption "the EON's RTC daemon (clock sync + scheduled power on/off)" // { default = true; };

      schedule = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "0 1 * * * off" ];
        description = ''
          Scheduled power on/off entries in `min hour date month dayOfWeek on|off`
          format (cron-like; only `*` and comma lists are supported, month is
          ignored). Times are local time. Written to /etc/argoneonrtc.conf.
        '';
      };
    };

    i2cDeviceTreeOverlay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Patch the Raspberry Pi 4 / CM4 (bcm2711) device tree so the I2C1
        bus (`i2c1`/`i2c_arm`) is forced to `status = "okay"`.

        Enable this if `i2cdetect -y 1` finds no bus, and
        `cat /proc/device-tree/soc/i2c@7e804000/status` reads `disabled`
        even though `dtparam=i2c_arm=on` is set in `config.txt`. That
        combination means the board boots through U-Boot +
        `generic-extlinux-compatible` with a prebuilt `FDTDIR` -- a boot
        chain where the Raspberry Pi firmware never applies config.txt's
        dtparam/dtoverlay lines, since U-Boot loads a Nix-built device
        tree directly instead of letting the firmware merge overlays.

        Pi4 Model B / CM4 (bcm2711) only; a no-op on Pi5 (bcm2712). Leave
        this off if your system boots through the stock RPi firmware
        (raspberry-pi-nix, `boot.loader.raspberryPi.*`), where
        config.txt's dtparam already takes care of it and this overlay
        isn't needed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.hddFanCurve != null -> (lib.all (v: v >= 0 && v <= 100) (lib.attrValues cfg.hddFanCurve));
        message = "services.argoneon.hddFanCurve values must be fan speeds between 0 and 100.";
      }
    ];

    warnings = [
      ''
        services.argoneon enables hardware.i2c.enable, but the Argon EON's
        fan/RTC/OLED controller also needs the Raspberry Pi firmware to bring
        the I2C bus up (dtparam=i2c_arm=on in config.txt). That line is not
        managed by this module -- add it via whichever module owns your
        board's firmware config (e.g. raspberry-pi-nix's
        hardware.raspberry-pi.config, or boot.loader.raspberryPi.firmwareConfig).
        If your board instead boots via U-Boot + generic-extlinux-compatible
        with a prebuilt FDTDIR, config.txt is ignored entirely for this --
        set services.argoneon.i2cDeviceTreeOverlay = true; instead.
      ''
    ];

    hardware.i2c.enable = true;

    hardware.deviceTree.overlays = lib.mkIf cfg.i2cDeviceTreeOverlay [
      {
        name = "argon-i2c1";
        # nixpkgs documents this `filter` as a glob, but apply_overlays.py
        # actually does a literal substring check (`filter not in rel_path`)
        # -- wildcards here would silently never match anything.
        filter = "bcm2711";
        dtsText = ''
          /dts-v1/;
          /plugin/;
          / {
            compatible = "brcm,bcm2711";
            fragment@0 {
              target = <&i2c1>;
              __overlay__ {
                status = "okay";
              };
            };
          };
        '';
      }
    ];

    # NixOS already assembles /etc/systemd/system-shutdown itself (see
    # systemd.shutdown in nixpkgs' systemd.nix); writing into that path
    # directly via environment.etc collides with it, so register our hook
    # through the same option instead.
    systemd.shutdown."argon-shutdown.sh" = shutdownScript;

    environment.systemPackages = [ statusCli pkgs.i2c-tools pkgs.smartmontools ]
      ++ lib.optional cfg.rtc.enable pkgs.util-linux;

    environment.etc = {
      "argon".source = etcArgon;

      "argononed.conf".text = fanCurveConfig "Argon Fan Speed Configuration (CPU)" cfg.fanCurve;

      "argonunits.conf".text = unitConfig;
    }
    // lib.optionalAttrs (cfg.hddFanCurve != null) {
      "argononed-hdd.conf".text = fanCurveConfig "Argon Fan Speed Configuration (HDD)" cfg.hddFanCurve;
    }
    // lib.optionalAttrs cfg.oled.enable {
      "argoneonoled.conf".text = oledConfig;
    }
    // lib.optionalAttrs cfg.rtc.enable {
      "argoneonrtc.conf".text = rtcConfig;
    };

    # argononed.py shells out to lsblk/smartctl (HDD temps), and -- on the
    # OLED "raid" screen -- mdadm. argonsysinfo.py's smartctl path is patched
    # to the nix store at build time (see payload.nix); the rest resolve via
    # PATH, hence the extra packages above.
    systemd.services.argononed = {
      description = "Argon EON Fan and Button Service";
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.smartmontools pkgs.util-linux pkgs.coreutils pkgs.gawk ]
        ++ lib.optional cfg.rtc.enable pkgs.mdadm;
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RemainAfterExit = true;
        ExecStart = "${pythonEnv}/bin/python3 /etc/argon/argononed.py SERVICE";
      };
    };

    systemd.services.argoneond = lib.mkIf cfg.rtc.enable {
      description = "Argon EON RTC Service";
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RemainAfterExit = true;
        ExecStart = "${pythonEnv}/bin/python3 /etc/argon/argoneond.py SERVICE";
      };
    };
  };
}
