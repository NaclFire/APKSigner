using System;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Windows.Forms;

public sealed class InstallerForm : Form
{
    private readonly TextBox pathBox;
    private readonly Button installButton;

    public InstallerForm()
    {
        Text = "APK Signer Setup";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 190);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;

        var title = new Label {
            AutoSize = true,
            Location = new Point(24, 20),
            Text = "Choose an installation folder for APK Signer:"
        };
        Controls.Add(title);

        pathBox = new TextBox {
            Location = new Point(24, 56),
            Size = new Size(390, 24),
            Text = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs\\APKSigner")
        };
        Controls.Add(pathBox);

        var browse = new Button {
            Location = new Point(424, 54),
            Size = new Size(95, 28),
            Text = "Browse..."
        };
        browse.Click += BrowseClick;
        Controls.Add(browse);

        var hint = new Label {
            AutoSize = true,
            ForeColor = Color.DimGray,
            Location = new Point(24, 92),
            Text = "Shortcuts will be created on the desktop and in the Start menu."
        };
        Controls.Add(hint);

        installButton = new Button {
            Location = new Point(328, 132),
            Size = new Size(92, 32),
            Text = "Install",
            DialogResult = DialogResult.None
        };
        installButton.Click += InstallClick;
        Controls.Add(installButton);

        var cancel = new Button {
            Location = new Point(427, 132),
            Size = new Size(92, 32),
            Text = "Cancel",
            DialogResult = DialogResult.Cancel
        };
        Controls.Add(cancel);
        CancelButton = cancel;
        AcceptButton = installButton;
    }

    private void BrowseClick(object sender, EventArgs e)
    {
        using (var dialog = new FolderBrowserDialog()) {
            dialog.Description = "Choose an installation folder";
            dialog.SelectedPath = pathBox.Text;
            if (dialog.ShowDialog(this) == DialogResult.OK) {
                pathBox.Text = dialog.SelectedPath;
            }
        }
    }

    private void InstallClick(object sender, EventArgs e)
    {
        var target = pathBox.Text.Trim();
        if (target.Length == 0) {
            MessageBox.Show(this, "Please choose a valid installation folder.", "Installation failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        try {
            var exePath = Path.Combine(target, "apk_signer.exe");
            if (File.Exists(exePath)) {
                var answer = MessageBox.Show(this,
                    "The selected folder already exists. Overwrite the existing files?",
                    "Confirm installation", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (answer != DialogResult.Yes) return;
            }

            Directory.CreateDirectory(target);
            var tempZip = Path.Combine(Path.GetTempPath(), "APKSigner-" + Guid.NewGuid().ToString("N") + ".zip");
            try {
                ExtractEmbeddedPayload(tempZip);
                ExtractZip(tempZip, target);
            } finally {
                TryDelete(tempZip);
            }

            CreateShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), "APK Signer.lnk"), exePath, target);
            var startMenu = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft\\Windows\\Start Menu\\Programs\\APK Signer");
            Directory.CreateDirectory(startMenu);
            CreateShortcut(Path.Combine(startMenu, "APK Signer.lnk"), exePath, target);

            MessageBox.Show(this, "Installation completed.\r\n\r\nInstall folder: " + target,
                "APK Signer", MessageBoxButtons.OK, MessageBoxIcon.Information);
            Close();
        } catch (Exception ex) {
            MessageBox.Show(this, "Installation failed: " + ex.Message,
                "Installation failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void ExtractZip(string zipPath, string target)
    {
        using (var archive = ZipFile.OpenRead(zipPath)) {
            foreach (var entry in archive.Entries) {
                var destination = Path.GetFullPath(Path.Combine(target, entry.FullName));
                var root = Path.GetFullPath(target) + Path.DirectorySeparatorChar;
                if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase)) {
                    throw new InvalidDataException("Invalid archive entry.");
                }
                if (entry.FullName.EndsWith("/", StringComparison.Ordinal) || entry.FullName.EndsWith("\\", StringComparison.Ordinal)) {
                    Directory.CreateDirectory(destination);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(destination));
                entry.ExtractToFile(destination, true);
            }
        }
    }

    private static void ExtractEmbeddedPayload(string outputZip)
    {
        const int footerSize = 16;
        const string magic = "APKSIEXE";
        var self = Application.ExecutablePath;
        using (var input = new FileStream(self, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            if (input.Length < footerSize) throw new InvalidDataException("Installer payload is missing.");
            input.Seek(-footerSize, SeekOrigin.End);
            var footer = new byte[footerSize];
            ReadFully(input, footer, 0, footer.Length);
            var marker = System.Text.Encoding.ASCII.GetString(footer, 0, 8);
            var length = BitConverter.ToInt64(footer, 8);
            if (marker != magic || length <= 0 || length > input.Length - footerSize) {
                throw new InvalidDataException("Installer payload is invalid.");
            }
            input.Seek(input.Length - footerSize - length, SeekOrigin.Begin);
            using (var output = new FileStream(outputZip, FileMode.Create, FileAccess.Write)) {
                var buffer = new byte[1024 * 1024];
                var remaining = length;
                while (remaining > 0) {
                    var count = input.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                    if (count <= 0) throw new EndOfStreamException();
                    output.Write(buffer, 0, count);
                    remaining -= count;
                }
            }
        }
    }

    private static void ReadFully(Stream stream, byte[] buffer, int offset, int count)
    {
        while (count > 0) {
            var read = stream.Read(buffer, offset, count);
            if (read <= 0) throw new EndOfStreamException();
            offset += read;
            count -= read;
        }
    }

    private static void CreateShortcut(string path, string target, string workingDirectory)
    {
        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType == null) return;
        dynamic shell = Activator.CreateInstance(shellType);
        dynamic shortcut = shell.CreateShortcut(path);
        shortcut.TargetPath = target;
        shortcut.WorkingDirectory = workingDirectory;
        shortcut.IconLocation = target + ",0";
        shortcut.Description = "APK Signer";
        shortcut.Save();
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new InstallerForm());
    }
}
