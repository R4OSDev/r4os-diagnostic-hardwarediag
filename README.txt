HWDIAG.R4X
==========

HWDIAG.R4X ist die Hardware-Inventory-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\HardwareDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\HardwareDiag\zig-out\HWDIAG.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `hwdiag_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4DEV`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\HWDIAG.R4X`
