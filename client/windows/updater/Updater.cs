// Built with the Windows .NET Framework compiler. No Python, PowerShell, or
// FFmpeg from PATH is used on the user's machine. Runs outside the payload.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

internal static class Updater {
    const string Manifest = "bb-payload.sha256";
    static string root, transaction, old, staged;
    static readonly StringComparer Names = StringComparer.OrdinalIgnoreCase;

    static void SafeTree(string path) {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Reparse point refused: " + path);
        if (Directory.Exists(path)) foreach (var child in Directory.GetFileSystemEntries(path)) SafeTree(child);
    }
    static void SafeParents(string path) {
        for (var dir = new DirectoryInfo(path); dir != null; dir = dir.Parent)
            if (dir.Exists && (dir.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Reparse parent refused.");
    }
    static string Relative(string value) {
        if (String.IsNullOrEmpty(value) || value.Contains("\\") || value.StartsWith("/") || value.Length > 180)
            throw new IOException("Unsafe payload path.");
        foreach (string part in value.Split('/')) {
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".") || part.EndsWith(" ") ||
                part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || part.Contains(":" ) ||
                Regex.IsMatch(part, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase))
                throw new IOException("Unsafe payload path: " + value);
        }
        return value;
    }
    static string Hash(string file) {
        using (var input = File.OpenRead(file)) using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
    }
    static Dictionary<string, string> ReadManifest(string directory, bool verify) {
        var result = new Dictionary<string, string>(Names);
        var manifest = Path.Combine(directory, Manifest);
        if (!File.Exists(manifest)) throw new IOException("Installation has no payload manifest; use manual installation.");
        foreach (string line in File.ReadAllLines(manifest, Encoding.UTF8)) {
            var match = Regex.Match(line, @"^([0-9a-f]{64})  (.+)$");
            if (!match.Success) throw new IOException("Invalid payload manifest.");
            string name = Relative(match.Groups[2].Value);
            if (result.ContainsKey(name) || Names.Equals(name, Manifest)) throw new IOException("Duplicate manifest entry.");
            result.Add(name, match.Groups[1].Value);
            if (verify && Hash(Path.Combine(directory, name)) != match.Groups[1].Value)
                throw new IOException("Payload hash mismatch: " + name);
        }
        foreach (string required in new [] {"bb_client.exe", "bb_updater.exe", "flutter_windows.dll", "data/icudtl.dat", "ffmpeg/ffmpeg.exe", "ffmpeg/FFMPEG-LICENSE.txt", "ffmpeg/FFMPEG-NOTICE.txt", "bb-build.json"})
            if (!result.ContainsKey(required)) throw new IOException("Incomplete payload: " + required);
        if (!result.Keys.Any(x => x.StartsWith("data/flutter_assets/", StringComparison.Ordinal))) throw new IOException("Missing Flutter assets.");
        return result;
    }
    static void Extract(string archive) {
        Directory.CreateDirectory(staged);
        var names = new HashSet<string>(Names);
        long total = 0;
        using (var zip = ZipFile.OpenRead(archive)) {
            if (zip.Entries.Count > 30000) throw new IOException("Too many ZIP entries.");
            foreach (var entry in zip.Entries) {
                bool directory = entry.FullName.EndsWith("/");
                string name = Relative(directory ? entry.FullName.TrimEnd('/') : entry.FullName);
                int kind = (entry.ExternalAttributes >> 16) & 0xf000;
                if ((kind != 0 && kind != 0x8000 && kind != 0x4000) ||
                    (entry.ExternalAttributes & 0x400) != 0 || !names.Add(name)) throw new IOException("Link or duplicate ZIP entry.");
                total = checked(total + entry.Length);
                if (total > 4L * 1024 * 1024 * 1024) throw new IOException("Unpacked payload exceeds 4 GiB.");
                string target = Path.Combine(staged, name);
                if (directory) { Directory.CreateDirectory(target); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                using (var input = entry.Open()) using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    var buffer = new byte[65536]; long copied = 0; int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                        copied += count;
                        if (copied > entry.Length) throw new IOException("ZIP length mismatch.");
                        output.Write(buffer, 0, count);
                    }
                    if (copied != entry.Length) throw new IOException("Truncated ZIP entry.");
                    output.Flush(true);
                }
            }
        }
        var owned = ReadManifest(staged, true);
        foreach (string file in Directory.GetFiles(staged, "*", SearchOption.AllDirectories)) {
            var relative = file.Substring(staged.Length + 1).Replace('\\', '/');
            if (relative != Manifest && !owned.ContainsKey(relative)) throw new IOException("Unmanifested payload file.");
        }
    }
    static void PreserveUserFiles() {
        SafeTree(root);
        var owned = ReadManifest(root, true); // Modified owned payload is not overwritten silently.
        foreach (string file in Directory.GetFiles(root, "*", SearchOption.AllDirectories)) {
            string relative = file.Substring(root.Length + 1).Replace('\\', '/');
            if (Names.Equals(relative, Manifest) || owned.ContainsKey(relative)) continue;
            string destination = Path.Combine(staged, relative);
            if (File.Exists(destination) || Directory.Exists(destination)) throw new IOException("Update collides with user file: " + relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            File.Copy(file, destination, false);
        }
        // Preserve empty user directories too.
        foreach (string directory in Directory.GetDirectories(root, "*", SearchOption.AllDirectories)) {
            string relative = directory.Substring(root.Length + 1);
            Directory.CreateDirectory(Path.Combine(staged, relative));
        }
    }
    static void State(string value) {
        string temp = Path.Combine(transaction, "state.tmp"), dest = Path.Combine(transaction, "state");
        using (var file = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None)) {
            byte[] bytes = Encoding.UTF8.GetBytes(value); file.Write(bytes, 0, bytes.Length); file.Flush(true);
        }
        if (File.Exists(dest)) File.Replace(temp, dest, null); else File.Move(temp, dest);
    }
    static void Fault(string point) {
        // Deterministic fault injection used only with isolated fixture installs.
        if (Environment.GetEnvironmentVariable("BB_UPDATE_FAULT") == point) throw new IOException("Injected failure: " + point);
        if (Environment.GetEnvironmentVariable("BB_UPDATE_CRASH") == point) Environment.Exit(91);
    }
    static string Quote(string path) { return "\"" + path.Replace("\"", "\\\"") + "\""; }
    static void Launch(bool healthCheck) {
        string token = "Local\\BBUpdate-" + Guid.NewGuid().ToString("N");
        using (var ready = new EventWaitHandle(false, EventResetMode.ManualReset, token)) {
            var start = new ProcessStartInfo(Path.Combine(root, "bb_client.exe"));
            start.UseShellExecute = false; start.WorkingDirectory = root;
            start.Arguments = healthCheck ? "--bb-update-ready=" + token : "";
            using (var app = Process.Start(start)) {
                File.WriteAllText(Path.Combine(transaction, "launched.pid"), app.Id.ToString());
                if (healthCheck && !ready.WaitOne(TimeSpan.FromSeconds(30))) {
                    if (!app.HasExited) { app.Kill(); app.WaitForExit(10000); }
                    throw new IOException("Updated app did not render its first frame; restored old installation.");
                }
            }
        }
    }
    static void Recover(bool launch) {
        SafeParents(transaction); SafeTree(transaction);
        string state = File.Exists(Path.Combine(transaction, "state")) ? File.ReadAllText(Path.Combine(transaction, "state")) : "preparing";
        if (state == "committed" || state == "rolled-back") return;
        if (Directory.Exists(old)) {
            if (Directory.Exists(root)) {
                SafeTree(root);
                Directory.Move(root, Path.Combine(transaction, "failed-" + Guid.NewGuid().ToString("N")));
            }
            Directory.Move(old, root);
        }
        State("rolled-back");
        if (launch && File.Exists(Path.Combine(root, "bb_client.exe"))) Launch(false);
    }
    static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        bool parentExited = false;
        try {
            // Recovery helper is copied into the transaction; double-clicking
            // it needs no shell script and cannot interpret paths as commands.
            if (args.Length == 0) {
                transaction = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                root = File.ReadAllText(Path.Combine(transaction, "root.txt"), Encoding.UTF8);
            } else {
                if (args.Length != 5 || args[0] != "--apply") throw new IOException("Invalid updater arguments.");
                root = Path.GetFullPath(args[1]).TrimEnd(Path.DirectorySeparatorChar);
                transaction = Path.Combine(Path.GetDirectoryName(root), "." + Path.GetFileName(root) + ".bb-update");
            }
            SafeParents(root); SafeParents(transaction);
            old = Path.Combine(transaction, "old"); staged = Path.Combine(transaction, "new");
            string lockPath = transaction + ".lock";
            using (var gate = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) {
                if (args.Length == 0) { Recover(true); return 0; }
                if (Directory.Exists(transaction)) {
                    Recover(false);
                    Directory.Move(transaction, transaction + ".saved-" + Guid.NewGuid().ToString("N"));
                }
                Directory.CreateDirectory(transaction);
                File.WriteAllText(Path.Combine(transaction, "root.txt"), root, new UTF8Encoding(false));
                File.Copy(System.Reflection.Assembly.GetExecutingAssembly().Location, Path.Combine(transaction, "Recover BB.exe"));
                State("preparing");
                if (!Regex.IsMatch(args[3], "^[0-9a-f]{64}$") || Hash(args[2]) != args[3]) throw new IOException("Archive SHA-256 mismatch.");
                SafeTree(root);
                ReadManifest(root, true);
                Extract(args[2]);
                // Parent must exist before READY. Keep its process handle, not
                // a PID lookup after it exits (PIDs can be reused).
                using (var parent = Process.GetProcessById(Int32.Parse(args[4]))) {
                    var handle = parent.Handle;
                    State("prepared");
                    Console.WriteLine("READY"); Console.Out.Flush();
                    if (!parent.WaitForExit(90000)) throw new IOException("Old app is still running; update cancelled.");
                    parentExited = true;
                }
                // Copy user files after parent exit so the snapshot is final.
                PreserveUserFiles();
                Fault("before-move");
                State("replacing");
                Directory.Move(root, old);
                Fault("after-old-move");
                Directory.Move(staged, root);
                Fault("after-new-move");
                Launch(true);
                State("committed");
                return 0;
            }
        } catch (Exception error) {
            try {
                if (transaction != null && Directory.Exists(transaction)) {
                    File.AppendAllText(Path.Combine(transaction, "update.log"), DateTime.UtcNow.ToString("o") + " " + error.Message + Environment.NewLine, Encoding.UTF8);
                    // A lock contender must never roll back another updater.
                    using (var gate = new FileStream(transaction + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) Recover(parentExited);
                }
            } catch (Exception recovery) {
                Console.Error.WriteLine("Recovery required: " + recovery.Message);
            }
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
