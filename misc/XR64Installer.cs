using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class XR64Installer
{
    private static readonly string[] Entries = { "bin", "database", "gamedata", "fsgame.ltx" };

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 3 && args[0] == "--install")
        {
            try { Install(args[1], "", args[2]); return 0; }
            catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
        }

        Application.EnableVisualStyles();
        using (var window = new Form { Text = "XR64 Multiplayer Setup", ClientSize = new Size(550, 330), StartPosition = FormStartPosition.CenterScreen })
        {
            var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(12) };
            var source = new TextBox { Width = 520 };
            var hash = new TextBox { Width = 520, Enabled = false };
            var destination = new TextBox { Width = 520 };
            var chooseSource = new Button { Text = "Browse for existing XR64 runtime", AutoSize = true };
            var chooseDestination = new Button { Text = "Browse for install location", AutoSize = true };
            var install = new Button { Text = "Install", AutoSize = true };
            var play = new Button { Text = "Play", AutoSize = true, Enabled = false };
            var status = new Label { AutoSize = true, MaximumSize = new Size(520, 0) };
            var buttons = new FlowLayoutPanel { AutoSize = true };
            buttons.Controls.Add(install);
            buttons.Controls.Add(play);

            layout.Controls.Add(new Label { Text = "Compatible XR64/IWP x64 folder or backup ZIP URL", AutoSize = true });
            layout.Controls.Add(source);
            layout.Controls.Add(chooseSource);
            layout.Controls.Add(new Label { Text = "SHA-256 for a ZIP download", AutoSize = true });
            layout.Controls.Add(hash);
            layout.Controls.Add(new Label { Text = "New install folder", AutoSize = true });
            layout.Controls.Add(destination);
            layout.Controls.Add(chooseDestination);
            layout.Controls.Add(buttons);
            layout.Controls.Add(status);
            window.Controls.Add(layout);

            source.TextChanged += (sender, eventArgs) => hash.Enabled = IsHttps(source.Text.Trim());
            chooseSource.Click += (sender, eventArgs) =>
            {
                using (var picker = new FolderBrowserDialog { Description = "Select your existing XR64/IWP x64 folder", ShowNewFolderButton = false })
                    if (picker.ShowDialog(window) == DialogResult.OK)
                        source.Text = picker.SelectedPath;
            };
            chooseDestination.Click += (sender, eventArgs) =>
            {
                using (var picker = new FolderBrowserDialog { Description = "Select where to create the XR64 Multiplayer folder" })
                    if (picker.ShowDialog(window) == DialogResult.OK)
                        destination.Text = Path.Combine(picker.SelectedPath, "XR64 Multiplayer");
            };

            string installedPath = null;
            bool installing = false;
            window.FormClosing += (sender, eventArgs) => eventArgs.Cancel = installing;
            install.Click += async (sender, eventArgs) =>
            {
                installing = true;
                install.Enabled = chooseSource.Enabled = chooseDestination.Enabled = play.Enabled = false;
                status.Text = "Copying the local game files and applying the XR64 update...";
                string input = source.Text.Trim(), checksum = hash.Text.Trim(), output = destination.Text.Trim();
                try
                {
                    await Task.Run(() => Install(input, checksum, output));
                    installedPath = Path.GetFullPath(output);
                    play.Enabled = true;
                    status.Text = "Installed. Click Play or open Play XR64.cmd in the install folder.";
                }
                catch (Exception error) { status.Text = error.Message; }
                finally
                {
                    installing = false;
                    install.Enabled = chooseSource.Enabled = chooseDestination.Enabled = true;
                }
            };

            play.Click += (sender, eventArgs) =>
            {
                try
                {
                    Process.Start(new ProcessStartInfo(Path.Combine(installedPath, "bin", "xrEngine.exe"))
                    {
                        WorkingDirectory = installedPath,
                        Arguments = "-nosplash -nointro",
                        UseShellExecute = false
                    });
                }
                catch (Exception error) { status.Text = error.Message; }
            };
            Application.Run(window);
        }
        return 0;
    }

    private static bool IsHttps(string source)
    {
        Uri url;
        return Uri.TryCreate(source, UriKind.Absolute, out url) && url.Scheme == Uri.UriSchemeHttps;
    }

    private static void Install(string source, string checksum, string destination)
    {
        if (source.Length == 0 || destination.Length == 0)
            throw new ArgumentException("Enter a runtime source and a new install folder.");

        destination = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("Choose a new install folder.");

        bool remote = IsHttps(source);
        if (remote && !System.Text.RegularExpressions.Regex.IsMatch(checksum, "^[a-fA-F0-9]{64}$"))
            throw new ArgumentException("Enter the runtime archive's SHA-256 hash.");

        if (!remote)
        {
            source = Path.GetFullPath(source);
            Validate(source);
            if (IsInside(source, destination))
                throw new IOException("Choose a destination outside the source folder.");
        }

        string parent = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(parent))
            throw new IOException("Choose a folder within a drive.");

        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("XR64.RuntimeUpdate"))
        {
            if (payload == null)
                throw new IOException("This installer has no embedded XR64 update. Use the release EXE.");
            using (var update = new ZipArchive(payload, ZipArchiveMode.Read))
            {
                if (!remote)
                    ApplyUpdate(source, update, false);

                string staging = Path.Combine(parent, ".xr64-" + Guid.NewGuid().ToString("N").Substring(0, 8));
                Directory.CreateDirectory(staging);
                string runtime = Path.Combine(staging, "game");
                try
                {
                    if (remote)
                    {
                        string archive = Path.Combine(staging, "runtime.zip");
                        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                        using (var client = new WebClient()) client.DownloadFile(source, archive);
                        VerifyHash(archive, checksum);
                        ZipFile.ExtractToDirectory(archive, runtime);
                    }
                    else
                    {
                        Directory.CreateDirectory(runtime);
                        foreach (string entry in Entries)
                        {
                            string input = Path.Combine(source, entry), output = Path.Combine(runtime, entry);
                            if (Directory.Exists(input)) CopyDirectory(input, output);
                            else File.Copy(input, output);
                        }
                    }

                    Validate(runtime);
                    ApplyUpdate(runtime, update, true);
                    Directory.Move(runtime, destination);
                }
                finally { Directory.Delete(staging, true); }
            }
        }
    }

    private static bool IsInside(string root, string path)
    {
        string prefix = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static void Validate(string root)
    {
        if (!File.Exists(Path.Combine(root, "bin", "xrEngine.exe")) ||
            !File.Exists(Path.Combine(root, "fsgame.ltx")) ||
            !Directory.Exists(Path.Combine(root, "database")) ||
            !Directory.Exists(Path.Combine(root, "gamedata")))
            throw new IOException("Select a compatible XR64/IWP x64 runtime containing bin, database, gamedata and fsgame.ltx.");
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string file in Directory.GetFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        foreach (string directory in Directory.GetDirectories(source))
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }

    private static void ApplyUpdate(string root, ZipArchive archive, bool write)
    {
        using (var manifest = new StreamReader(archive.GetEntry("manifest.tsv").Open()))
        {
            string line;
            while ((line = manifest.ReadLine()) != null)
            {
                string[] entry = line.Split('\t');
                string relative = entry[1];
                string path = Path.GetFullPath(Path.Combine(root, relative));
                if (!IsInside(root, path))
                    throw new IOException("Invalid update path " + relative);
                switch (entry[0])
                {
                    case "require":
                        VerifyHash(path, entry[2], relative);
                        break;
                    case "file":
                        if (write)
                        {
                            archive.GetEntry(relative).ExtractToFile(path, true);
                            VerifyHash(path, entry[2], relative);
                        }
                        break;
                    case "patch":
                        string current = GetHash(path);
                        if (string.Equals(current, entry[2], StringComparison.OrdinalIgnoreCase))
                            break;
                        if (!string.Equals(current, entry[3], StringComparison.OrdinalIgnoreCase))
                            throw new IOException("The source runtime has an incompatible version of " + relative + ".");
                        if (write)
                        {
                            using (var edits = new BinaryReader(new MemoryStream(ReadEntry(archive, entry[4]))))
                                PatchFile(path, edits);
                            VerifyHash(path, entry[2], relative);
                        }
                        break;
                    default:
                        throw new IOException("Unsupported update entry.");
                }
            }
        }
    }

    private static byte[] ReadEntry(ZipArchive archive, string name)
    {
        using (var input = archive.GetEntry(name).Open())
        using (var output = new MemoryStream())
        {
            input.CopyTo(output);
            return output.ToArray();
        }
    }

    private static void PatchFile(string path, BinaryReader edits)
    {
        byte[] original = File.ReadAllBytes(path);
        using (var output = new MemoryStream())
        {
            int cursor = 0;
            while (edits.BaseStream.Position < edits.BaseStream.Length)
            {
                int offset = edits.ReadInt32(), removed = edits.ReadInt32(), added = edits.ReadInt32();
                if (offset < cursor || offset > original.Length || removed < 0 ||
                    removed > original.Length - offset || added < 0 || added > edits.BaseStream.Length - edits.BaseStream.Position)
                    throw new IOException("Invalid embedded patch.");
                output.Write(original, cursor, offset - cursor);
                output.Write(edits.ReadBytes(added), 0, added);
                cursor = offset + removed;
            }
            output.Write(original, cursor, original.Length - cursor);
            File.WriteAllBytes(path, output.ToArray());
        }
    }

    private static string GetHash(string path)
    {
        if (!File.Exists(path)) return null;
        using (var file = File.OpenRead(path))
        using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "");
    }

    private static void VerifyHash(string path, string expected, string name = "runtime archive")
    {
        if (!string.Equals(GetHash(path), expected, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Missing or incompatible " + name + ".");
    }
}
