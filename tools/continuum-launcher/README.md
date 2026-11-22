# Continuum Launcher

Build the Windows launcher with Python 3 and the .NET Framework compiler included in 64-bit Windows 10 and 11.

```powershell
python build_bundle.py
Start-Process .\build\STALKER-Continuum-Launcher.exe -ArgumentList '--verify-layout' -Wait
```

The launcher works from outside the game directory. When it needs to install, it streams the published baseline to a staging directory and verifies its archive parts and game files against the bundled SHA-256 manifests. A healthy install offers Play. The launcher shows Repair when required and Update when a compatible game package is available.

## Release versions

Use matching versions in `launcher/version.json` and the GitHub release tag `continuum-launcher-vX.Y.Z`. Attach the built `STALKER-Continuum-Launcher.exe` to the release. The launcher checks that release stream independently from game updates.

Continue to publish game updates under `awp-standalone-vX.Y.Z` with an asset named `awp-standalone-update.zip`. Use `pack_update.py` to build its manifest and include the files being changed. When applying an update, the launcher records the resulting file checksums and game version in the same transaction.

In Settings, **Check versions** compares the launcher and game versions to published releases. **Verify files** reports missing, changed, and unreadable game files against the selected installation's known release. Personal settings, saves, and optional extra files stay outside that comparison.
