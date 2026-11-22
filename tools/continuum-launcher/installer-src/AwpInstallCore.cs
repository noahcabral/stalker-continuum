using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace AwpInstall {
    public sealed class Part {
        public string Name { get; set; }
        public long Size { get; set; }
        public string Digest { get; set; }
        public string Url { get; set; }
    }

    public sealed class Release {
        public string Tag { get; set; }
        public Part[] Assets { get; set; }
    }

    public static class Baseline {
        public const string Tag = "awp-standalone-20261121-01-baseline";
        public const string Marker = ".awp-baseline-release";
        public const string Profile = "appdata/awp-user.ltx";
        private static readonly Regex Digest = new Regex(@"^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
        private static readonly Regex Device = new Regex(@"^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|(?:COM|LPT)[0-9\u00b9\u00b2\u00b3])(?:\.|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        public static readonly string[] Essential = { "Launch-Standalone.cmd", "fsgame.ltx", "bin/xrEngine.exe", "bin/xrGame.dll" };
        public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        public static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
        public static bool IsDigest(string text) { return text != null && Digest.IsMatch(text); }
        public static string FileHash(string file) {
            using (var input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var hash = SHA256.Create()) return Hex(hash.ComputeHash(input));
        }
        public static string TextHash(string text) {
            using (var hash = SHA256.Create()) return Hex(hash.ComputeHash(Utf8.GetBytes(text)));
        }

        public static void ValidateRelative(string name, bool directory) {
            if (String.IsNullOrEmpty(name) || name.Length > 234 || name.Any(Char.IsControl))
                throw new InvalidDataException("Invalid archive path: " + name);
            var segments = name.Split('/');
            foreach (var segment in segments) {
                if (segment.Length == 0 || segment.EndsWith(".") || segment.EndsWith(" ") ||
                    segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || Device.IsMatch(segment))
                    throw new InvalidDataException("Invalid archive path: " + name);
            }
            var root = segments[0];
            if (root == "bin" || root == "database" || root == "gamedata") {
                if (directory || segments.Length > 1) return;
            } else if (directory && name == "appdata") return;
            else if (!directory && (name == Profile || name == "Launch-Standalone.cmd" || name == "fsgame.ltx")) return;
            throw new InvalidDataException("Archive path is outside the runtime allowlist: " + name);
        }

        public static FileAttributes? Attributes(string path) {
            try { return File.GetAttributes(path); }
            catch (FileNotFoundException) { return null; }
            catch (DirectoryNotFoundException) { return null; }
        }
        public static void NoReparse(string path) {
            string current = Path.GetPathRoot(path);
            foreach (var segment in path.Substring(current.Length).Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries)) {
                current = Path.Combine(current, segment);
                var attributes = Attributes(current);
                if (attributes.HasValue && (attributes.Value & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("The selected path contains a link: " + current);
            }
        }
        public static bool PlainFile(string path) {
            var attrs = Attributes(path);
            return attrs.HasValue && (attrs.Value & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;
        }
        public static string Destination(string root, string name) {
            var path = Path.GetFullPath(Path.Combine(root, name.Replace('/', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("The path is outside the installation: " + name);
            if (path.Length > 248) throw new IOException("Choose an installation folder with a shorter path.");
            NoReparse(path);
            return path;
        }
        public static string Root(string root) {
            if (String.IsNullOrWhiteSpace(root)) throw new IOException("Choose an installation folder.");
            if (!Regex.IsMatch(root, @"^(?:[a-zA-Z]:[\\/]|\\\\[^?\.][^\\]*\\[^\\]+\\?)"))
                throw new IOException("Choose a fully qualified Windows installation folder.");
            var full = Path.GetFullPath(root);
            if (full.TrimEnd('\\', '/') == Path.GetPathRoot(full).TrimEnd('\\', '/'))
                throw new IOException("Choose a folder inside the drive.");
            full = full.TrimEnd('\\', '/');
            NoReparse(full);
            return full;
        }

        public static Dictionary<string,string> ReadManifest(string file, bool runtime) {
            var rows = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in File.ReadLines(file, Utf8)) {
                if (line.Length < 67 || !Digest.IsMatch(line.Substring(0, 64)) ||
                    (line.Substring(64, 2) != " *" && line.Substring(64, 2) != "  "))
                    throw new InvalidDataException("Invalid baseline digest inventory.");
                var name = line.Substring(66);
                if (runtime) ValidateRelative(name, false);
                if (rows.ContainsKey(name)) throw new InvalidDataException("Duplicate baseline inventory path: " + name);
                rows.Add(name, line.Substring(0, 64));
            }
            if (rows.Count == 0) throw new InvalidDataException("The baseline inventory is empty.");
            return rows;
        }
        public static Part[] ValidateRelease(Release release, string runtimeFile, string partsFile) {
            if (release == null || release.Tag != Tag || release.Assets == null || release.Assets.Length != 18)
                throw new InvalidDataException("Invalid standalone baseline release metadata.");
            var map = new Dictionary<string,Part>(StringComparer.Ordinal);
            foreach (var asset in release.Assets) {
                if (asset == null || String.IsNullOrEmpty(asset.Name) || asset.Size <= 0 || asset.Digest == null ||
                    !asset.Digest.StartsWith("sha256:", StringComparison.Ordinal) || !Digest.IsMatch(asset.Digest.Substring(7)) ||
                    asset.Url != "https://github.com/noahcabral/stalker-continuum/releases/download/" + Tag + "/" + asset.Name ||
                    map.ContainsKey(asset.Name)) throw new InvalidDataException("Invalid baseline asset metadata.");
                map.Add(asset.Name, asset);
            }
            foreach (var file in new[] { runtimeFile, partsFile }) {
                Part asset;
                if (!map.TryGetValue(Path.GetFileName(file), out asset) || new FileInfo(file).Length != asset.Size ||
                    "sha256:" + FileHash(file) != asset.Digest)
                    throw new InvalidDataException("The bundled baseline manifest does not match GitHub: " + Path.GetFileName(file));
            }
            var manifest = ReadManifest(partsFile, false);
            if (manifest.Count != 16) throw new InvalidDataException("The split archive must have exactly 16 parts.");
            var ordered = new List<Part>();
            for (int n = 0; n < 16; n++) {
                string name = "awp-baseline.tar.part-" + n.ToString("D3", CultureInfo.InvariantCulture);
                Part asset;
                string checksum;
                if (!map.TryGetValue(name, out asset) || !manifest.TryGetValue(name, out checksum) || asset.Digest != "sha256:" + checksum)
                    throw new InvalidDataException("Missing or mismatched baseline part: " + name);
                ordered.Add(asset);
            }
            return ordered.ToArray();
        }

        public static string[] MissingFiles(string root, Dictionary<string,string> files, bool broad) {
            var paths = broad ? files.Keys.Where(name => name != Profile) :
                Essential.Concat(files.Keys.Where(name => name.StartsWith("database/", StringComparison.Ordinal)));
            var missing = new List<string>();
            foreach (var name in paths) {
                var path = Destination(root, name);
                if (!PlainFile(path) || (Essential.Contains(name) && new FileInfo(path).Length == 0)) missing.Add(name);
            }
            return missing.ToArray();
        }

        public static string State(string root, Dictionary<string,string> files) {
            if (String.IsNullOrWhiteSpace(root)) return "Absent";
            root = Root(root);
            if (!Directory.Exists(root)) return "Absent";
            bool managed = MarkerIs(root, Marker, Tag);
            if (!managed && !PlainFile(Destination(root, "Launch-Standalone.cmd")) &&
                !PlainFile(Destination(root, "Launch-AWP-GUI.cmd")) && !PlainFile(Destination(root, Profile))) return "Absent";
            if (Directory.Exists(Destination(root, ".awp-update"))) return "Recovery";
            if (Installer.HasInterruptedRepair(root)) return "RepairRecovery";
            return MissingFiles(root, files, managed).Length == 0 && CriticalDamage(root, files).Count == 0 ? "Ready" : "Broken";
        }

        private static bool MarkerIs(string root, string name, string value) {
            string marker = Destination(root, name);
            return PlainFile(marker) && new FileInfo(marker).Length <= 128 && File.ReadAllText(marker, Utf8).Trim() == value;
        }
        public static bool ManagedBaseline(string root) {
            return MarkerIs(root, Marker, Tag) && MarkerIs(root, ".awp-version", "0.0.0");
        }
        public static Dictionary<string,string> CriticalDamage(string root, Dictionary<string,string> files) {
            var damage = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            if (!ManagedBaseline(root)) return damage;
            foreach (var name in Essential) {
                string target = Destination(root, name);
                string expected;
                if (!PlainFile(target) || !files.TryGetValue(name, out expected)) continue;
                string actual = FileHash(target);
                if (actual != expected) damage.Add(name, actual);
            }
            return damage;
        }
        public static string RepairApproval(string root, Dictionary<string,string> damage) {
            return damage.Count == 0 ? "" : TextHash(Root(root).ToUpperInvariant() + "\n" +
                String.Concat(damage.OrderBy(row => row.Key, StringComparer.OrdinalIgnoreCase)
                    .Select(row => row.Key + "\t" + row.Value + "\n")));
        }

        public static bool Matches(string path, string hash) { return PlainFile(path) && FileHash(path) == hash; }

        public static void WriteStable(string path, string text) {
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                byte[] bytes = Utf8.GetBytes(text);
                output.Write(bytes, 0, bytes.Length);
                output.Flush(true);
            }
        }
    }

    public sealed class VerifiedPartStream : Stream {
        private readonly Part[] parts;
        private readonly Func<Part,Stream> source;
        private readonly Action<long,long> progress;
        private readonly string cache;
        private readonly long total;
        private long downloaded;
        private int index;
        private FileStream current;

        public VerifiedPartStream(Part[] assets, Func<Part,Stream> getPart, string cacheFile, Action<long,long> report) {
            parts = assets;
            source = getPart;
            cache = cacheFile;
            progress = report;
            total = parts.Sum(part => part.Size);
        }
        private bool NextPart() {
            if (current != null) { current.Dispose(); current = null; File.Delete(cache); }
            if (index == parts.Length) return false;
            Part part = parts[index++];
            using (var input = source(part))
            using (var output = new FileStream(cache, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var hash = SHA256.Create()) {
                var buffer = new byte[1024 * 1024];
                long written = 0;
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) != 0) {
                    written += count;
                    if (written > part.Size) throw new InvalidDataException("The downloaded part exceeds its expected size: " + part.Name);
                    output.Write(buffer, 0, count);
                    hash.TransformBlock(buffer, 0, count, buffer, 0);
                    downloaded += count;
                    if (progress != null) progress(downloaded, total);
                }
                hash.TransformFinalBlock(buffer, 0, 0);
                if (written != part.Size || "sha256:" + Baseline.Hex(hash.Hash) != part.Digest)
                    throw new InvalidDataException("The downloaded part failed SHA-256 verification: " + part.Name);
            }
            current = new FileStream(cache, FileMode.Open, FileAccess.Read, FileShare.Read);
            return true;
        }
        public override int Read(byte[] buffer, int offset, int count) {
            if (count == 0) return 0;
            for (;;) {
                if (current == null && !NextPart()) return 0;
                int available = current.Read(buffer, offset, count);
                if (available != 0) return available;
                if (!NextPart()) return 0;
            }
        }
        protected override void Dispose(bool disposing) {
            if (disposing && current != null) { current.Dispose(); current = null; }
            base.Dispose(disposing);
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return total; } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }

    public static class TarRuntime {
        private const int Block = 512;
        private static void ReadExactly(Stream input, byte[] buffer, int size) {
            int position = 0;
            while (position < size) {
                int length = input.Read(buffer, position, size - position);
                if (length == 0) throw new InvalidDataException("The baseline archive ended unexpectedly.");
                position += length;
            }
        }
        private static bool Zero(byte[] data, int length) {
            for (int index = 0; index < length; index++) if (data[index] != 0) return false;
            return true;
        }
        private static string Field(byte[] data, int first, int length) {
            int size = 0;
            while (size < length && data[first + size] != 0) size++;
            return Baseline.Utf8.GetString(data, first, size);
        }
        private static long Octal(byte[] data, int first, int length) {
            var text = Field(data, first, length).Trim();
            if (text.Length == 0 || text.Any(ch => ch < '0' || ch > '7')) throw new InvalidDataException("Invalid TAR number.");
            return Convert.ToInt64(text, 8);
        }
        private static long Size(byte[] header) {
            var signed = header[124];
            if (signed < 128) return Octal(header, 124, 12);
            if (signed != 128) throw new InvalidDataException("Unsupported TAR size encoding.");
            long n = 0;
            for (int i = 125; i < 136; i++) n = checked(n * 256 + header[i]);
            return n;
        }
        private static void Payload(Stream input, byte[] buffer, long size, Stream output, SHA256 hash) {
            for (long left = size; left > 0;) {
                int length = (int)Math.Min(left, buffer.Length);
                ReadExactly(input, buffer, length);
                if (output != null) output.Write(buffer, 0, length);
                if (hash != null) hash.TransformBlock(buffer, 0, length, buffer, 0);
                left -= length;
            }
            if (hash != null) hash.TransformFinalBlock(buffer, 0, 0);
            int padding = (int)((Block - size % Block) % Block);
            ReadExactly(input, buffer, padding);
            if (!Zero(buffer, padding)) throw new InvalidDataException("Invalid TAR payload padding.");
        }
        public static void Extract(Stream input, string stage, Dictionary<string,string> files, ISet<string> wanted,
                                   Action<int,int> progress) {
            var header = new byte[Block];
            var buffer = new byte[1024 * 1024];
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string longName = null;
            while (true) {
                ReadExactly(input, header, Block);
                if (Zero(header, Block)) {
                    ReadExactly(input, header, Block);
                    if (!Zero(header, Block) || longName != null) throw new InvalidDataException("Invalid TAR terminator.");
                    int read;
                    while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
                        if (!Zero(buffer, read)) throw new InvalidDataException("Unexpected data beyond the TAR archive.");
                    break;
                }
                var checksum = Octal(header, 148, 8);
                long actual = 0;
                for (var i = 0; i < Block; i++) actual += i >= 148 && i < 156 ? 32 : header[i];
                if (actual != checksum || Field(header, 257, 5) != "ustar")
                    throw new InvalidDataException("The TAR header is invalid.");
                var name = Field(header, 0, 100);
                var type = header[156];
                var size = Size(header);
                if (type == 'L') {
                    if (name != "././@LongLink" || size < 2 || size > 4096 || longName != null)
                        throw new InvalidDataException("Invalid GNU long filename record.");
                    using (var value = new MemoryStream()) {
                        Payload(input, buffer, size, value, null);
                        var bytes = value.ToArray();
                        if (bytes[bytes.Length - 1] != 0) throw new InvalidDataException("GNU filename is not terminated.");
                        longName = Baseline.Utf8.GetString(bytes, 0, bytes.Length - 1);
                    }
                    continue;
                }
                if (longName != null) { name = longName; longName = null; }
                else if (header[262] == 0) {
                    string prefix = Field(header, 345, 155);
                    if (prefix.Length != 0) name = prefix + "/" + name;
                }
                if (type == '5') {
                    Baseline.ValidateRelative(name.TrimEnd('/'), true);
                    if (size != 0) throw new InvalidDataException("A TAR directory contains a payload.");
                    continue;
                }
                if (type != '0' && type != 0) throw new InvalidDataException("Unsupported TAR member type for " + name);
                Baseline.ValidateRelative(name, false);
                string digest;
                if (!files.TryGetValue(name, out digest) || !seen.Add(name))
                    throw new InvalidDataException("Unexpected or repeated TAR file: " + name);
                string target = wanted.Contains(name) ? Baseline.Destination(stage, name) : null;
                if (target != null) Directory.CreateDirectory(Path.GetDirectoryName(target));
                using (var output = target == null ? null : new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var hash = SHA256.Create()) {
                    Payload(input, buffer, size, output, hash);
                    if (Baseline.Hex(hash.Hash) != digest) throw new InvalidDataException("Runtime file failed SHA-256 verification: " + name);
                }
                if (progress != null) progress(seen.Count, files.Count);
            }
            if (seen.Count != files.Count) throw new InvalidDataException("The baseline archive is missing runtime files.");
        }
    }

    public static class Installer {
        private static readonly Regex StagePattern = new Regex(@"^\.awp-stage-[0-9a-f]{12}$", RegexOptions.CultureInvariant);
        private static void DeleteOwnedStage(string parent, string stage, string owner) {
            if (Path.GetDirectoryName(stage) != parent || !StagePattern.IsMatch(Path.GetFileName(stage)))
                throw new IOException("Invalid installer staging location.");
            var marker = stage + ".owner";
            Baseline.NoReparse(marker);
            if (!Baseline.PlainFile(marker) || File.ReadAllText(marker, Baseline.Utf8) != owner)
                throw new IOException("The installer staging ownership marker is missing or incorrect.");
            var attributes = Baseline.Attributes(stage);
            if (attributes.HasValue) {
                if ((attributes.Value & FileAttributes.Directory) == 0 || (attributes.Value & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("The installer staging path changed type.");
                DeletePlainTree(stage);
            }
            File.Delete(marker);
        }
        private static void DeletePlainTree(string root) {
            Baseline.NoReparse(root);
            foreach (var path in Directory.EnumerateFileSystemEntries(root)) {
                var attrs = File.GetAttributes(path);
                if ((attrs & FileAttributes.ReparsePoint) != 0) throw new IOException("Unexpected link in installer staging: " + path);
                if ((attrs & FileAttributes.Directory) != 0) DeletePlainTree(path);
                else File.Delete(path);
            }
            Directory.Delete(root);
        }

        private static void CheckNewRoot(string root) {
            var attrs = Baseline.Attributes(root);
            if (attrs.HasValue && (!Directory.Exists(root) || Directory.EnumerateFileSystemEntries(root).Any()))
                throw new IOException("Choose an empty folder for a new standalone installation.");
        }
        private static void CheckBaselineVersion(string root) {
            string file = Baseline.Destination(root, ".awp-version");
            Version version;
            if (Baseline.Attributes(file).HasValue && (!Baseline.PlainFile(file) || new FileInfo(file).Length > 128 ||
                !Version.TryParse(File.ReadAllText(file, Baseline.Utf8).Trim(), out version) || version != new Version(0, 0, 0)))
                throw new IOException("This installation has a different release version. Baseline repair would mix versions.");
        }

        private static void WriteStageJournal(FileStream gate, string name) {
            byte[] bytes = Baseline.Utf8.GetBytes(name);
            gate.Position = 0;
            gate.Write(bytes, 0, bytes.Length);
            gate.SetLength(bytes.Length);
            gate.Flush(true);
        }

        private static string ReadStageJournal(string parent, FileStream gate) {
            if (gate.Length == 0) return null;
            if (gate.Length != 23) throw new IOException("The installer coordination file is not a valid stage journal.");
            var bytes = new byte[gate.Length];
            if (gate.Read(bytes, 0, bytes.Length) != bytes.Length) throw new IOException("The installer stage journal is incomplete.");
            string name = Baseline.Utf8.GetString(bytes);
            if (!StagePattern.IsMatch(name)) throw new IOException("The installer stage journal has an invalid path.");
            return Path.Combine(parent, name);
        }

        private static string RestoreOwnedStage(string root, string parent, FileStream gate, string owner, Dictionary<string,string> files,
                                                bool allowRepair) {
            string stage = ReadStageJournal(parent, gate);
            if (stage == null) return null;
            string backup = null;
            string marker = stage + ".owner";
            Baseline.NoReparse(marker);
            if (Baseline.PlainFile(marker) && File.ReadAllText(marker, Baseline.Utf8) == owner && Directory.Exists(stage) &&
                RepairTransaction.HasJournal(stage)) {
                if (!allowRepair || !Directory.Exists(root)) throw new IOException("An interrupted repair requires its original installation folder.");
                CheckBaselineVersion(root);
                backup = RepairTransaction.Recover(root, stage, files);
            }
            if (Baseline.Attributes(stage).HasValue || Baseline.Attributes(stage + ".owner").HasValue)
                DeleteOwnedStage(parent, stage, owner);
            WriteStageJournal(gate, "");
            return backup;
        }

        private static string Owns(string root) { return Baseline.TextHash(root.ToUpperInvariant()); }
        private static string GatePath(string root, string owner) {
            return Path.Combine(Path.GetDirectoryName(root), ".awp-setup-" + owner.Substring(0, 20) + ".lock");
        }

        public static bool HasInterruptedRepair(string root) {
            string owner = Owns(root);
            string gatePath = GatePath(root, owner);
            Baseline.NoReparse(gatePath);
            if (!Baseline.PlainFile(gatePath)) return false;
            try {
                using (var gate = new FileStream(gatePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                    string stage = ReadStageJournal(Path.GetDirectoryName(root), gate);
                    if (stage == null || !Directory.Exists(stage)) return false;
                    var marker = stage + ".owner";
                    Baseline.NoReparse(marker);
                    return Baseline.PlainFile(marker) && File.ReadAllText(marker, Baseline.Utf8) == owner && RepairTransaction.HasJournal(stage);
                }
            } catch (IOException) { return false; }
        }

        public static string RecoverRepair(string requestedRoot, Dictionary<string,string> files, Action assertStopped) {
            string root = Baseline.Root(requestedRoot);
            string owner = Owns(root);
            string gatePath = GatePath(root, owner);
            Baseline.NoReparse(gatePath);
            using (var gate = new FileStream(gatePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            using (var updateGate = new FileStream(Baseline.Destination(root, ".awp-update.lock"), FileMode.OpenOrCreate,
                                                   FileAccess.ReadWrite, FileShare.None)) {
                if (assertStopped != null) assertStopped();
                return RestoreOwnedStage(root, Path.GetDirectoryName(root), gate, owner, files, true);
            }
        }

        private static Dictionary<string,string> CheckRepair(string root, Dictionary<string,string> files, string approval,
                                                             Action report) {
            if (!Directory.Exists(root) || Baseline.State(root, files) == "Absent")
                throw new IOException("The selected folder does not contain an identifiable standalone installation.");
            if (Directory.Exists(Baseline.Destination(root, ".awp-update")))
                throw new IOException("Recover the interrupted update before repairing files.");
            CheckBaselineVersion(root);
            var plan = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            var damage = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            bool managed = Baseline.ManagedBaseline(root);
            int checks = 0;
            foreach (var row in files) {
                if (row.Key == Baseline.Profile) continue;
                var path = Baseline.Destination(root, row.Key);
                if (!Baseline.Attributes(path).HasValue) plan.Add(row.Key, null);
                else {
                    string actual = Baseline.PlainFile(path) ? Baseline.FileHash(path) : null;
                    if (actual != row.Value) {
                        if (!managed || actual == null || !Baseline.Essential.Contains(row.Key))
                            throw new IOException("Baseline repair would mix in older files because this runtime contains an edited or damaged file: " + row.Key);
                        plan.Add(row.Key, actual);
                        damage.Add(row.Key, actual);
                    }
                }
                if (++checks % 200 == 0 && report != null) report();
            }
            if (Baseline.RepairApproval(root, damage) != (approval ?? ""))
                throw new IOException("The damaged managed files differ from the approved repair. Select the folder again to review them.");
            return plan;
        }

        public static string Apply(string requestedRoot, Dictionary<string,string> files, Part[] parts, Func<Part,Stream> source,
                                   bool repair, Action<string,int> progress, Action assertStopped, string approval = null) {
            string root = Baseline.Root(requestedRoot);
            string parent = Path.GetDirectoryName(root);
            if (!Directory.Exists(parent)) throw new IOException("The installation's parent folder must already exist.");
            if (!repair) CheckNewRoot(root);
            else {
                if (Baseline.State(root, files) == "Absent") throw new IOException("The selected folder is not an identifiable standalone.");
                CheckBaselineVersion(root);
            }
            // Verify ZIP/TAR path length limits before downloading. The stage sibling
            // has a generated name and is checked here as well.
            string stage = Path.Combine(parent, ".awp-stage-" + Guid.NewGuid().ToString("N").Substring(0, 12));
            foreach (var name in files.Keys) {
                Baseline.ValidateRelative(name, false);
                if (Path.Combine(stage, name).Length > 248 || Path.Combine(root, name).Length > 248)
                    throw new IOException("Choose an installation folder with a shorter path.");
            }
            string owner = Owns(root);
            string lockPath = GatePath(root, owner);
            Baseline.NoReparse(lockPath);
            // The lock file persists as a coordination object so no new opener
            // can race deletion and recreate it under another writer.
            using (var gate = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
            using (var updateGate = repair ? new FileStream(Baseline.Destination(root, ".awp-update.lock"), FileMode.OpenOrCreate,
                                                            FileAccess.ReadWrite, FileShare.None) : null) {
                if (assertStopped != null) assertStopped();
                RestoreOwnedStage(root, parent, gate, owner, files, repair);
                Action<string,int> report = progress ?? delegate { };
                report(repair ? "Checking the installed release and files..." : "Checking the destination...", 0);
                HashSet<string> wanted;
                Dictionary<string,string> repairPlan = null;
                if (repair) {
                    repairPlan = CheckRepair(root, files, approval, () => report("Checking surviving runtime files...", 0));
                    wanted = new HashSet<string>(repairPlan.Keys, StringComparer.OrdinalIgnoreCase);
                    if (wanted.Count == 0) { report("All baseline runtime files are present.", 100); return null; }
                } else {
                    CheckNewRoot(root);
                    wanted = new HashSet<string>(files.Keys, StringComparer.OrdinalIgnoreCase);
                }
                long total = parts.Sum(part => part.Size);
                long peak = checked(total + parts.Max(part => part.Size) + 16 * 1024 * 1024);
                try {
                    var drive = new DriveInfo(Path.GetPathRoot(root));
                    if (drive.AvailableFreeSpace < peak)
                        throw new IOException("The selected drive needs approximately " + Math.Ceiling(peak / 1073741824.0) + " GiB free.");
                } catch (ArgumentException) { /* A supported network path does not expose local drive statistics. */ }
                if (Baseline.Attributes(stage).HasValue) throw new IOException("An installer staging folder already exists.");
                Baseline.WriteStable(stage + ".owner", owner);
                WriteStageJournal(gate, Path.GetFileName(stage));
                Directory.CreateDirectory(stage);
                try {
                    using (var archive = new VerifiedPartStream(parts, source, Path.Combine(stage, "part-cache"),
                        (done, size) => report("Downloading and verifying the baseline...", (int)(90.0 * done / size)))) {
                        TarRuntime.Extract(archive, stage, files, wanted,
                            (done, count) => { if (done == count) report("Verifying the complete runtime...", 93); });
                    }
                    if (assertStopped != null) assertStopped();
                    report("Installing verified files...", 95);
                    string backup = null;
                    if (repair) {
                        CheckBaselineVersion(root);
                        if (repairPlan.Values.Any(value => value != null) && !Baseline.ManagedBaseline(root))
                            throw new IOException("The baseline recovery marker changed before the repair could be committed.");
                        backup = RepairTransaction.Apply(root, stage, repairPlan, files);
                    }
                    else {
                        Baseline.WriteStable(Path.Combine(stage, Baseline.Marker), Baseline.Tag + "\n");
                        Baseline.WriteStable(Path.Combine(stage, ".awp-version"), "0.0.0\n");
                        CheckNewRoot(root);
                        bool existed = Directory.Exists(root);
                        if (existed) Directory.Delete(root);
                        try { Directory.Move(stage, root); }
                        catch { if (existed && !Baseline.Attributes(root).HasValue) Directory.CreateDirectory(root); throw; }
                    }
                    report(repair ? "Repair completed." : "Standalone installed.", 100);
                    return backup;
                } finally {
                    if (!Directory.Exists(stage) || !RepairTransaction.HasJournal(stage)) {
                        DeleteOwnedStage(parent, stage, owner);
                        WriteStageJournal(gate, "");
                    }
                }
            }
        }

    }
}
