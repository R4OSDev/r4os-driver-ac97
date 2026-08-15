AC97.R4D
========

AC97.R4D ist der ladbare AC97-Hardwaretreiber fuer die 0.38.X-Auslagerung.

Stand 0.38.5:
- echter R4D-Container mit Treibername AC97 und Typ audio
- PCI-Suche nach Multimedia/Audio-Geraeten
- I/O-BAR-Erkennung fuer NAM und NABM
- Aktivierung von I/O-Space und Bus Mastering ueber DriverApi
- AC97-Codec-Grundreset und 48-kHz-Rate-Setup
- DMA-BDL- und Samplepuffer-Allokation ueber DriverApi
- Audio-Output-Backend-Registrierung ueber DriverApi
- PCM-Normalisierung nach 48 kHz stereo s16le ueber `r4os.audio_pcm`
- BDL-/DMA-Pufferfuellung fuer echte PCM-Ausgabe
- Stop, Drain/Timeout, Statuszaehler und Shutdown-Cleanup

`AC97.R4D` ist seit 0.38.3 der produktive AC97-Ausgabepfad fuer
`DRIVER=AC97`. Seit 0.38.4 ist der alte Built-in-AC97-Quellpfad entfernt;
AC97 hat keinen stillen Kernel-Produktiv-Fallback mehr. Seit 0.38.5 sichert
`Tests/Gate/CheckAudioR4D038.zig` diesen Abschluss als
statischen Guard ab.

Projektstruktur seit 0.51.22
--------------------------------

Dieses Verzeichnis ist ein eigenstaendiges R4OS-SDK-Projekt fuer AC97.R4D.

Build:

    cd Code\System\Driver\AC97
    ..\..\..\DevTools\Zig\zig.exe build

Artefakt:

    zig-out\AC97.R4D

Manifest:

    module.R4MF

Image-Zielpfad: C:\R4OS\DRIVERS\AC97.R4D
