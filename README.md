# ps1 — PlayStation emulator for iOS

A minimalist, console-style PS1 emulator for iPhone. Pick a game, play in one tap —
zero mandatory configuration.

- Instant resume: quit anytime, the game continues from the exact same frame next launch
- Console-style game library: horizontal carousel with covers taken from your last session
- Full gamepad support (DualShock 4, DualSense, Xbox, MFi) with menu navigation and key repeat
- Raw-multitouch on-screen controls with haptics
- ×2 enhanced resolution, aspect stretch, smoothing — five settings total, on purpose
- Fast-forward ×2 on the right trigger
- Memory card saves persisted automatically; manual save states
- Imports .chd, .cue/.bin, .pbp, .img, .iso via Files, share sheet, or "Open in ps1"

## Building

Requirements: Xcode 26+, iOS device (arm64).

1. Build the emulator core (static library):

   ```sh
   cd Vendor/pcsx_rearmed
   make -f Makefile.libretro platform=ios-arm64 STATIC_LINKING=1 -j8
   mkdir -p lib && mv pcsx_rearmed_libretro_ios.dylib lib/libpcsx_rearmed_iphoneos.a
   ```

   For the iOS Simulator (arm64 Macs):

   ```sh
   make -f Makefile.libretro platform=ios-arm64 clean
   make -f Makefile.libretro platform=ios-arm64 STATIC_LINKING=1 \
     IOSSDK="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
     MINVERSION="-mios-simulator-version-min=17.0" -j8
   mv pcsx_rearmed_libretro_ios.dylib lib/libpcsx_rearmed_iphonesimulator.a
   ```

2. Open `ps1.xcodeproj`, set your development team, build and run on a device.

BIOS is optional: the core falls back to HLE BIOS. For maximum compatibility place
your own dump (e.g. `scph1001.bin`) into the app's `Documents/System` folder via Files.

No games are included. Import disc images of games you own.

## Emulation core

The emulator core is [PCSX-ReARMed](https://github.com/libretro/pcsx_rearmed)
(libretro fork), vendored in `Vendor/pcsx_rearmed` at upstream commit
`050981b6eeb715f142854f57c68086f62921f027`, built as an interpreter
(no JIT) with the NEON GPU rasterizer. All credit for the emulation itself goes to
its authors: notaz, the PCSX team, and libretro contributors.

## License

GPL-2.0. This application links the GPLv2-licensed PCSX-ReARMed core statically,
so the entire application is distributed under the GNU General Public License v2.
See [LICENSE](LICENSE). Original license notices in `Vendor/pcsx_rearmed` are preserved.

PlayStation is a trademark of Sony Interactive Entertainment Inc. This project is not
affiliated with or endorsed by Sony.
