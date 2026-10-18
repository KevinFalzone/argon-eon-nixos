# Pinned re-fetch of the Argon EON runtime payload that argoneon.sh otherwise
# downloads unauthenticated, at install time, straight into /etc/argon.
#
# Upstream (download.argon40.com) ships no versioning and no checksums, so
# pinning here just means: hashes were captured on 2026-10-18 from the files
# the stock installer itself would fetch for CHECKDEVICE=eon,
# CHECKGPIOMODE=libgpiod. Bump `version` and re-fetch if Argon ships an update.
{ lib, stdenvNoCC, fetchurl, smartmontools }:

let
  server = "https://download.argon40.com";

  script = name: hash:
    fetchurl {
      url = "${server}/scripts/${name}";
      sha256 = hash;
    };

  oledAsset = name: hash:
    fetchurl {
      url = "${server}/oled/${name}.bin";
      sha256 = hash;
    };

  # Files as laid out by argoneon.sh under /etc/argon for CHECKDEVICE="eon".
  files = {
    "argonsysinfo.py" = script "argonsysinfo.py" "sha256-DlofcNESZ/CcILj94btdxEw+SfH5EqSy3yOLoIByPkw=";
    "argonregister.py" = script "argonregister.py" "sha256-Cs6zOKHlZ6kcLeQxesPFf2dOJF9BIFJaQZX82gFnwEs=";
    # Installed as argonpowerbutton.py (CHECKGPIOMODE=libgpiod variant).
    "argonpowerbutton.py" = script "argonpowerbutton-libgpiod.py" "sha256-FNRDcLWea0bWAaD7RVsH2jaxrxyEsgiUJ7fIO6bA3ck=";
    "argononed.py" = script "argononed.py" "sha256-/g3452E+eVhTcXbBjoe7yNAneyoYJobo/rMILEOEN+I=";
    "argonrtc.py" = script "argonrtc.py" "sha256-xM8LZ8Kj9GrFpsPLpHiSS3zBpLNUUvT8zZKtHFHF6yQ=";
    "argoneond.py" = script "argoneond.py" "sha256-S+kfMa/YpoXPVHPmhsuuVo/VLhFAlRGkaENyNBLLn2s=";
    "argoneonoled.py" = script "argoneonoled.py" "sha256-rdCWdvT8Bqp9IhZxtX+vX7aom3q7tM+CjA5kkdI9dmk=";
    "argonstatus.py" = script "argonstatus.py" "sha256-n9RiST6LQATDVTiYTClSYJGjZ0TgPobAidolfPQ5iGs=";
    "argondashboard.py" = script "argondashboard.py" "sha256-JvpT0+wZFDc80GJF0Rz2dX3TZzoaoLp12FqQjwEP5ts=";

    "oled/font8x6.bin" = oledAsset "font8x6" "sha256-IuZe8YPAmsKs+EHJB1X7vv0l/MYDCW+FJV3FQy18l20=";
    "oled/font16x12.bin" = oledAsset "font16x12" "sha256-08C6R7BAiAmP8JStwwvpj2wx7eR+i0N90IOdNFh96K0=";
    "oled/font16x8.bin" = oledAsset "font16x8" "sha256-JcZJV1DrX0F+KUK367xsdc1FprtY1VAExoFM3yIBTcA=";
    "oled/font24x16.bin" = oledAsset "font24x16" "sha256-RhNpaKCEwVBpPSSgDHEmlMYUcxG82YmzMC/q+y4kJbE=";
    "oled/font32x24.bin" = oledAsset "font32x24" "sha256-HbQvTsicL2Y7k9AJo8FvDTa0HVXZiJ59/wkVxe5peVU=";
    "oled/font48x32.bin" = oledAsset "font48x32" "sha256-V+xlzZGHlN2sR769a+dOqGYFXjhoWCx1n31xTWZvBc8=";
    "oled/font64x48.bin" = oledAsset "font64x48" "sha256-+VwvAzGdd2ltL2SwCowpxzLClDhjzDEeCJ6j5oI1I8g=";
    "oled/bgdefault.bin" = oledAsset "bgdefault" "sha256-mzfAIfdvfsj7r3AV/bedT138EMR9+qWB4QixAwfrU/c=";
    "oled/bgram.bin" = oledAsset "bgram" "sha256-GUEWXx5lmshvjqeKhu6k7aLkq6gowFhjwLJUcLbuKBI=";
    "oled/bgip.bin" = oledAsset "bgip" "sha256-e7XKrfbDpqKk02owTm7Aici1+ji358x65ybGyAoSjGY=";
    "oled/bgtemp.bin" = oledAsset "bgtemp" "sha256-ix9p9zOvn+kZ7EATtdhRd0q1OsCGT9bqzruRNTQDCAA=";
    "oled/bgcpu.bin" = oledAsset "bgcpu" "sha256-1QmYRE6fcmIm+FuJnepukKY9UIJaS3QEXk1xM2iQxGA=";
    "oled/bgraid.bin" = oledAsset "bgraid" "sha256-bSET7nPr+iMPqjx4SR5+sUdcTFbTLG790Xqbibejz/s=";
    "oled/bgstorage.bin" = oledAsset "bgstorage" "sha256-6DO6vuyP9D3saEJJ7hi4PRAGni5bSbJS7rDTzo8Ol0Y=";
    "oled/bgtime.bin" = oledAsset "bgtime" "sha256-VarB0DWSs7zMVDjjcITimBSjFjkzafSs3MhE2AGSaCw=";
  };

  installOne = dest: src: "install -D -m444 ${src} $out/${dest}";
in
stdenvNoCC.mkDerivation {
  pname = "argoneon-payload";
  version = "2026-10-18";

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/oled
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList installOne files)}

    # argonsysinfo.py shells out to a hardcoded Debian path for HDD
    # temperatures; point it at our smartmontools instead.
    chmod u+w $out/argonsysinfo.py
    substituteInPlace $out/argonsysinfo.py \
      --replace-quiet "/usr/sbin/smartctl" "${smartmontools}/bin/smartctl"
    chmod 444 $out/argonsysinfo.py

    runHook postInstall
  '';

  meta = {
    description = "Pinned Argon EON fan/RTC/OLED Python payload (upstream: download.argon40.com)";
    # Upstream states no license for these scripts; left unset rather than
    # guessed, which also avoids an `allowUnfree` gate for personal use.
  };
}
