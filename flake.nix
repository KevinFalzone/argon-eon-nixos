{
  description = "NixOS module for the Argon EON fan/RTC/OLED controller daemons (argononed/argoneond) -- fetches the upstream payload at build time, pinned by hash";

  outputs = { self }: {
    nixosModules.default = import ./module.nix;
    nixosModules.argoneon = import ./module.nix;
  };
}
