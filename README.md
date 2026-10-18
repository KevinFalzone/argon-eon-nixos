# argoneon-nixos

A NixOS module reimplementing [Argon40](https://argon40.com)'s `argoneon.sh`
installer for the [**Argon EON**](https://argon40.com/products/argon-eon-pi-nas) (Raspberry Pi NAS case with fan, RTC and OLED)
declaratively.

It ports the `argononed` (fan curve + power button + OLED) and `argoneond`
(RTC schedule) daemons, their systemd units, the shutdown hook that signals
the MCU/RTC on poweroff, and their config files -- generated from NixOS
options.

**This module** downloads the upstream Python scripts at build time via
`fetchurl`, pinned by sha256 hash. 

## Not ported (on purpose)

IR remote config, BLSTR DAC, Argon Industria UPS, EEPROM updater, desktop
shortcut, and `argon-uninstall.sh` -- not applicable to a declarative
headless NixOS setup.

## Usage

As a flake input:

```nix
{
  inputs.argoneon.url = "github:KevinFalzone/argoneon-nixos";

  outputs = { self, nixpkgs, argoneon, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        argoneon.nixosModules.default
        { services.argoneon.enable = true; }
        ./configuration.nix
      ];
    };
  };
}
```

Or classic import in `configuration.nix`:

```nix
{
  imports = [ ./argoneon-nixos/module.nix ];
  services.argoneon.enable = true;
}
```

### Firmware prerequisite

This module sets `hardware.i2c.enable = true`, but the Raspberry Pi
firmware also needs `dtparam=i2c_arm=on` in `config.txt` to bring the I2C
bus up -- that line is not managed here, since it depends on whichever
module owns your board's firmware config (e.g. `raspberry-pi-nix`). A
warning is emitted at activation as a reminder.

**If you boot via U-Boot + `generic-extlinux-compatible`** (a prebuilt
`FDTDIR` referenced from `/boot/extlinux/extlinux.conf`), `config.txt` is
not read for this at all -- the Raspberry Pi firmware never gets a chance
to merge its dtparam/dtoverlay lines, since U-Boot loads a Nix-built
device tree directly. Symptom: `i2cdetect -y 1` finds no bus, and
`cat /proc/device-tree/soc/i2c@7e804000/status` reads `disabled` no matter
what's in `config.txt`. Set `services.argoneon.i2cDeviceTreeOverlay = true;`
instead (Pi4 Model B / CM4 only).

### Options

```nix
services.argoneon = {
  enable = true;
  fanCurve = { "55" = 30; "60" = 55; "65" = 100; };   # °C -> fan %
  hddFanCurve = { "35" = 30; "40" = 55; "45" = 100; }; # null to disable
  unitsTemperature = "C";                              # or "F"
  oled.enable = true;
  oled.switchDuration = 30;                            # seconds/screen
  oled.screens = [ "clock" "cpu" "storage" "raid" "ram" "temp" "ip" ];
  rtc.enable = true;
  rtc.schedule = [ "0 1 * * * off" ];                  # cron-like, local time
  i2cDeviceTreeOverlay = false;                        # true if U-Boot/extlinux ignores config.txt
};
```

After `nixos-rebuild switch`:

```bash
systemctl status argononed argoneond
i2cdetect -y 1       # expect devices at 0x1a (fan) and 0x51 (RTC)
argoneon-status      # read-only dashboard
```
