using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace AwpInstall {
    internal static class RepairTransaction {
        private const string JournalName = "repair-plan.tsv";
        private const string ReadyName = "repair-committed";
        private const string OriginalName = "repair-originals";

        private sealed class Entry {
            public string Path;
            public string Before;
            public string After;
        }

        public static bool HasJournal(string stage) {
            return Baseline.PlainFile(Baseline.Destination(stage, JournalName));
        }

        public static string Apply(string root, string stage, Dictionary<string,string> plan, Dictionary<string,string> inventory) {
            var records = plan.OrderBy(row => row.Key, StringComparer.OrdinalIgnoreCase)
                .Select(row => new Entry { Path = row.Key, Before = row.Value, After = inventory[row.Key] }).ToArray();
            string contents = String.Concat(records.Select(row => row.Path + "\t" + (row.Before ?? "-") + "\t" + row.After + "\n"));
            string pending = Baseline.Destination(stage, JournalName + ".pending");
            string journal = Baseline.Destination(stage, JournalName);
            Baseline.WriteStable(pending, contents);
            File.Move(pending, journal);
            try {
                for (int i = 0; i < records.Length; i++) {
                    var row = records[i];
                    string target = Baseline.Destination(root, row.Path);
                    string verified = Baseline.Destination(stage, row.Path);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    Baseline.NoReparse(target);
                    if (row.Before == null) {
                        if (Baseline.Attributes(target).HasValue) throw new IOException("A file appeared during repair: " + row.Path);
                        File.Move(verified, target);
                    } else {
                        if (!Baseline.Matches(target, row.Before)) throw new IOException("A damaged file changed after you approved repair: " + row.Path);
                        string backup = EntryBackup(stage, i);
                        Directory.CreateDirectory(Path.GetDirectoryName(backup));
                        File.Replace(verified, target, backup);
                        if (!Baseline.Matches(backup, row.Before)) throw new IOException("Could not verify the repair backup: " + row.Path);
                    }
                }
                Baseline.WriteStable(Baseline.Destination(stage, ReadyName), Baseline.Tag);
            } catch {
                Recover(root, stage, inventory);
                throw;
            }
            return Recover(root, stage, inventory);
        }

        public static string Recover(string root, string stage, Dictionary<string,string> inventory) {
            if (!HasJournal(stage)) return null;
            string journal = Baseline.Destination(stage, JournalName);
            if (new FileInfo(journal).Length > 8 * 1024 * 1024) throw new IOException("The installer repair journal is too large.");
            string text = File.ReadAllText(journal, Baseline.Utf8);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var rows = File.ReadLines(journal, Baseline.Utf8).Select(line => {
                string[] fields = line.Split('\t');
                if (fields.Length != 3) throw new IOException("The installer repair journal is invalid.");
                Baseline.ValidateRelative(fields[0], false);
                string digest;
                bool ordinary = inventory.TryGetValue(fields[0], out digest) && fields[2] == digest;
                bool prior = fields[1] == "-" || (Baseline.IsDigest(fields[1]) && Baseline.Essential.Contains(fields[0]));
                if (fields[0] == Baseline.Profile || !seen.Add(fields[0]) || !ordinary || !prior)
                    throw new IOException("The installer repair journal does not match this baseline.");
                return new Entry { Path = fields[0], Before = fields[1] == "-" ? null : fields[1], After = fields[2] };
            }).ToArray();
            if (rows.Length == 0 || rows.Length > inventory.Count) throw new IOException("The installer repair journal is empty or too large.");

            string committed = Baseline.Destination(stage, ReadyName);
            string destination = null;
            if (Baseline.PlainFile(committed)) {
                if (File.ReadAllText(committed, Baseline.Utf8) != Baseline.Tag) throw new IOException("The installer repair commit marker is invalid.");
                destination = SaveBackups(root, stage, rows, text);
            } else {
                for (int i = rows.Length - 1; i >= 0; i--) RestoreEntry(root, stage, rows[i], i);
            }
            File.Delete(journal);
            return destination;
        }

        private static string EntryBackup(string stage, int index) {
            return Baseline.Destination(stage, OriginalName + "/" + index.ToString("D5") + ".original");
        }

        private static void RestoreEntry(string root, string stage, Entry entry, int index) {
            string target = Baseline.Destination(root, entry.Path);
            if (entry.Before == null) {
                string prepared = Baseline.Destination(stage, entry.Path);
                if (!Baseline.Attributes(prepared).HasValue && Baseline.Matches(target, entry.After)) File.Delete(target);
                return;
            }
            string backup = EntryBackup(stage, index);
            if (!Baseline.Attributes(backup).HasValue) return;
            if (!Baseline.Matches(backup, entry.Before)) throw new IOException("The repair backup does not match the recorded original: " + entry.Path);
            if (Baseline.Matches(target, entry.Before)) return;
            if (!Baseline.Attributes(target).HasValue) File.Move(backup, target);
            else if (Baseline.Matches(target, entry.After)) File.Replace(backup, target, null);
            else throw new IOException("A file changed outside the launcher during rollback. Its original backup is retained: " + entry.Path);
        }

        private static string SaveBackups(string root, string stage, Entry[] rows, string text) {
            if (!rows.Any(row => row.Before != null)) return null;
            string originals = Baseline.Destination(stage, OriginalName);
            string destination = Baseline.Destination(root, ".awp-repair-backups/" + Path.GetFileName(stage));
            if (Directory.Exists(originals)) {
                if (Baseline.Attributes(destination).HasValue) throw new IOException("The repair backup destination already exists.");
                string receipt = Baseline.Destination(originals, JournalName);
                if (!Baseline.Attributes(receipt).HasValue) Baseline.WriteStable(receipt, text);
                CheckRetainedBackups(originals, rows, text);
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                Baseline.NoReparse(destination);
                Directory.Move(originals, destination);
            }
            CheckRetainedBackups(destination, rows, text);
            return destination;
        }

        private static void CheckRetainedBackups(string directory, Entry[] rows, string text) {
            string journal = Baseline.Destination(directory, JournalName);
            if (!Baseline.PlainFile(journal) || File.ReadAllText(journal, Baseline.Utf8) != text)
                throw new IOException("The retained repair backup inventory is missing or does not match.");
            for (int i = 0; i < rows.Length; i++) {
                if (rows[i].Before != null && !Baseline.Matches(Baseline.Destination(directory, i.ToString("D5") + ".original"), rows[i].Before))
                    throw new IOException("The retained repair backup does not match: " + rows[i].Path);
            }
        }
    }
}
