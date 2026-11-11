# XR64 Multiplayer LAN preview

Download `XR64-Multiplayer-Setup.exe` from the [GitHub Releases page](https://github.com/noahcabral/xr64multiplayer/releases). The repository is private, so the account downloading it needs access to the repository.

Run Setup, browse to the compatible local XR64/IWP x64 runtime, and choose a new install folder. Setup copies the game files, applies the embedded OpenXRay update, and creates `Play XR64.cmd`. It can also use an HTTPS backup ZIP of the same compatible runtime with its SHA-256. The ZIP must contain `bin`, `database`, `gamedata`, and `fsgame.ltx` at its root.

The preview requires the XR64/IWP runtime with the handheld PDA compatibility data already staged. A stock IWP installation cannot supply that data. The update contains OpenXRay binaries and a local script patch. The game database, IWP assets, xrMPE assets and xrMPE server are excluded. Setup creates a separate game profile on first launch. Existing saves can be copied over from the previous runtime's `appdata\savedgames` when both builds support the same save format.

To connect to a running Cordon co-op host on your local network, choose **Join LAN** above **New Game**, select the server, and click **Join**. This preview covers LAN. Steam joins are still in development.

## Building Setup

Use the tested Windows x64 runtime as input. The generator selects the OpenXRay DLLs and creates a SHA-256-checked byte patch for the local Dynamic News script. Keep the local runtime outside the Git checkout.

```powershell
python misc/windows/build_xr64_release_payload.py "D:\XR64 runtime" runtime-update.zip
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /optimize+ /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /resource:runtime-update.zip,XR64.RuntimeUpdate /out:XR64-Multiplayer-Setup.exe misc/XR64Installer.cs
```

The installed copy opens through the installer’s **Play** button or the launcher in the new folder. Players only need the EXE and their compatible runtime.
