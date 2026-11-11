using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class XR64Installer
{
    private static readonly string[] Entries = { "bin", "database", "gamedata", "fsgame.ltx" };

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        using (var window = new Form { Text = "XR64 Multiplayer Setup", Width = 540, Height = 300, StartPosition = FormStartPosition.CenterScreen })
        {
            var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(12) };
            var source = new TextBox { Width = 480 };
            var hash = new TextBox { Width = 480 };
            var destination = new TextBox { Width = 480 };
            var choose = new Button { Text = "Browse for install location", AutoSize = true };
            var install = new Button { Text = "Install", AutoSize = true };
            var status = new Label { AutoSize = true, MaximumSize = new System.Drawing.Size(480, 0) };
            layout.Controls.Add(new Label { Text = "IWP runtime folder or HTTPS ZIP URL", AutoSize = true });
            layout.Controls.Add(source);
            layout.Controls.Add(new Label { Text = "SHA-256 (required for a download)", AutoSize = true });
            layout.Controls.Add(hash);
            layout.Controls.Add(new Label { Text = "New install folder", AutoSize = true });
            layout.Controls.Add(destination);
            layout.Controls.Add(choose);
            layout.Controls.Add(install);
            layout.Controls.Add(status);
            window.Controls.Add(layout);

            choose.Click += (sender, args) =>
            {
                using (var picker = new FolderBrowserDialog())
                    if (picker.ShowDialog(window) == DialogResult.OK)
                        destination.Text = Path.Combine(picker.SelectedPath, "XR64 Multiplayer");
            };
            install.Click += async (sender, args) =>
            {
                install.Enabled = false;
                choose.Enabled = false;
                status.Text = "Installing...";
                string input = source.Text.Trim(), checksum = hash.Text.Trim(), output = destination.Text.Trim();
                try
                {
                    await Task.Run(() => Install(input, checksum, output));
                    status.Text = "Installed. Open bin\\xrEngine.exe in the install folder to launch.";
                }
                catch (Exception error) { status.Text = error.Message; }
                finally { install.Enabled = true; choose.Enabled = true; }
            };
            Application.Run(window);
        }
    }

    private static void Install(string source, string checksum, string destination)
    {
        if (source.Length == 0 || destination.Length == 0)
            throw new ArgumentException("Enter a runtime source and a new install folder.");
        destination = Path.GetFullPath(destination);
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new IOException("Choose a new install folder.");
        Uri url;
        bool remote = Uri.TryCreate(source, UriKind.Absolute, out url) && url.Scheme == Uri.UriSchemeHttps;
        if (remote && !System.Text.RegularExpressions.Regex.IsMatch(checksum, "^[a-fA-F0-9]{64}$"))
            throw new ArgumentException("Enter the runtime archive's SHA-256 hash.");
        if (!remote)
        {
            source = Path.GetFullPath(source);
            Validate(source);
            if (destination.StartsWith(source.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("Choose a destination outside the source folder.");
        }

        var staging = Path.Combine(Path.GetDirectoryName(destination), ".xr64-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        string runtime = Path.Combine(staging, "game");
        try
        {
            if (remote)
            {
                string archive = Path.Combine(staging, "runtime.zip");
                using (var client = new WebClient()) client.DownloadFile(url, archive);
                using (var file = File.OpenRead(archive))
                using (var sha = SHA256.Create())
                    if (!string.Equals(BitConverter.ToString(sha.ComputeHash(file)).Replace("-", ""), checksum, StringComparison.OrdinalIgnoreCase))
                        throw new IOException("The download did not match the expected SHA-256.");
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
            Directory.Move(runtime, destination);
        }
        finally { Directory.Delete(staging, true); }
    }

    private static void Validate(string root)
    {
        if (!File.Exists(Path.Combine(root, "bin", "xrEngine.exe")) ||
            !File.Exists(Path.Combine(root, "fsgame.ltx")) ||
            !Directory.Exists(Path.Combine(root, "database")) ||
            !Directory.Exists(Path.Combine(root, "gamedata")))
            throw new IOException("The runtime must contain bin, database, gamedata and fsgame.ltx.");
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (string file in Directory.GetFiles(source))
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        foreach (string directory in Directory.GetDirectories(source))
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)));
    }
}
