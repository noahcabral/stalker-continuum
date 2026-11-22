using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

internal static class Program {
    [STAThread]
    private static int Main(string[] args) {
        bool verify = args.Length == 1 && args[0] == "--verify-layout";
        if (!verify && args.Length != 0) return 2;
        string temp = Path.Combine(Path.GetTempPath(), "AwpLauncher-" + Guid.NewGuid().ToString("N"));
        bool replacementScheduled = false;
        try {
            Directory.CreateDirectory(temp);
            ExtractEmbeddedFiles(temp);
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string launcher = Path.Combine(temp, "launcher", "AwpLauncher.ps1");
            string updateRequest = Path.Combine(temp, "launcher-update.request");
            string origin = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd('\\');
            if (origin.Length == 2 && origin[1] == ':') origin += "\\.";
            var launch = new ProcessStartInfo {
                FileName = Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File " + Quote(launcher) +
                    " -Portable -Origin " + Quote(origin) + (verify ? " -VerifyLayout" : " -LauncherUpdateRequest " + Quote(updateRequest)),
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = temp,
            };
            // Use the Windows PowerShell modules even when launched from another PowerShell or profile.
            launch.EnvironmentVariables["PSModulePath"] = Path.Combine(system, "WindowsPowerShell", "v1.0", "Modules");
            using (var process = Process.Start(launch)) {
                process.WaitForExit();
                if (process.ExitCode != 0) throw new InvalidOperationException("Windows PowerShell could not start the launcher.");
            }
            if (!verify && File.Exists(updateRequest)) {
                string helper = Path.Combine(temp, "launcher", "AwpLauncherReplace.ps1");
                string target = Assembly.GetExecutingAssembly().Location;
                launch.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File " + Quote(helper) +
                    " -Target " + Quote(target) + " -ParentId " + Process.GetCurrentProcess().Id;
                using (var process = Process.Start(launch)) { replacementScheduled = true; }
            }
            return 0;
        } catch (Exception error) {
            if (!verify) MessageBox.Show(error.Message, "S.T.A.L.K.E.R.: Continuum Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        } finally {
            try { if (!replacementScheduled) RemoveExtractedFiles(temp); } catch { }
        }
    }

    private static string Quote(string value) { return "\"" + value + "\""; }

    private static void ExtractEmbeddedFiles(string destination) {
        using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("AwpLauncher.bundle.zip"))
        using (var zip = new ZipArchive(payload, ZipArchiveMode.Read)) {
            foreach (var entry in zip.Entries) {
                if (!entry.FullName.StartsWith("launcher/", StringComparison.Ordinal) || entry.FullName.IndexOf('\\') >= 0)
                    throw new InvalidDataException("The launcher bundle contains an invalid path.");
                string path = Path.GetFullPath(Path.Combine(destination, entry.FullName.Replace('/', '\\')));
                if (!path.StartsWith(destination + "\\", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The launcher bundle contains an invalid path.");
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                using (var source = entry.Open())
                using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) source.CopyTo(file);
            }
        }
    }

    private static void RemoveExtractedFiles(string directory) {
        if (!Directory.Exists(directory) || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) return;
        foreach (string file in Directory.EnumerateFiles(directory)) {
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0) File.Delete(file);
        }
        foreach (string sub in Directory.EnumerateDirectories(directory)) RemoveExtractedFiles(sub);
        Directory.Delete(directory);
    }
}
