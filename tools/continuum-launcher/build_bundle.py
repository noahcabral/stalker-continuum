"""Build the portable Windows launcher from this source directory."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from zipfile import ZIP_DEFLATED, ZipFile


root = Path(__file__).resolve().parent
launcher = root / "launcher"
installer = root / "installer-src"
output = root / "build"
compiler = Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
executable_name = "STALKER-Continuum-Launcher.exe"


def compile_code(target, output_path, sources, references, bundle=None, icon=None):
    command = [str(compiler), "/nologo", "/optimize+", f"/target:{target}", f"/out:{output_path}"]
    command.extend(f"/reference:{name}" for name in references)
    if bundle:
        command.append(f"/resource:{bundle},AwpLauncher.bundle.zip")
    if icon:
        command.append(f"/win32icon:{icon}")
    command.extend(str(path) for path in sources)
    subprocess.run(command, check=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build():
    output.mkdir(exist_ok=True)
    version = json.loads((launcher / "version.json").read_text(encoding="utf-8"))["version"]
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        raise ValueError("Launcher version must contain three numeric components")
    metadata = output / "AssemblyInfo.cs"
    metadata.write_text(
        "using System.Reflection;\n"
        '[assembly: AssemblyTitle("S.T.A.L.K.E.R.: Continuum Launcher")]\n'
        '[assembly: AssemblyProduct("S.T.A.L.K.E.R.: Continuum")]\n'
        f'[assembly: AssemblyVersion("{version}.0")]\n'
        f'[assembly: AssemblyFileVersion("{version}.0")]\n', encoding="utf-8"
    )

    core_files = ("AwpInstallCore.cs", "AwpInstallNetwork.cs", "AwpRepairTransaction.cs")
    core = output / "AwpInstallCore.dll"
    compile_code("library", core,
                 (installer / name for name in core_files),
                 ("System.IO.Compression.dll", "System.Web.Extensions.dll"))

    core_member = "launcher/AwpInstallCore.dll"
    members = {path.relative_to(root).as_posix(): path for path in sorted(launcher.rglob("*"))
               if path.is_file() and path != launcher / core.name}
    members[core_member] = core
    bundle = output / "launcher.bundle.zip"
    with ZipFile(bundle, "w", ZIP_DEFLATED) as archive:
        for name, path in sorted(members.items()):
            archive.write(path, name)
    exe = output / executable_name
    compile_code("winexe", exe, (installer / "AwpLauncherBootstrap.cs", metadata),
                 ("System.IO.Compression.dll", "System.Windows.Forms.dll"), bundle=bundle,
                 icon=launcher / "Continuum.ico")

    receipt = {"version": version, "executableName": executable_name, "executable": sha(exe),
               "bundle": sha(bundle),
               "members": {name: sha(path) for name, path in members.items()}}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print(f"{exe}, {exe.stat().st_size} bytes, SHA-256 {receipt['executable']}")


if __name__ == "__main__":
    build()
