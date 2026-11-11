using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace StartupFolderLauncher
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            string appDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(appDir, "launcher.ps1");

            if (!File.Exists(scriptPath))
            {
                return;
            }

            // Self-healing: Ensure launcher.ps1 and other ps1 scripts have UTF-8 BOM
            // to prevent syntax crashes under Windows PowerShell 5.1
            EnsureAllScriptsHaveBom(appDir);

            string passArgs = (args != null && args.Length > 0) ? " " + string.Join(" ", args) : "";
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"" + passArgs,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(psi);
        }

        private static void EnsureAllScriptsHaveBom(string appDir)
        {
            try
            {
                foreach (string psFile in Directory.GetFiles(appDir, "*.ps1", SearchOption.TopDirectoryOnly))
                {
                    EnsureUtf8WithBom(psFile);
                }

                string scriptsDir = Path.Combine(appDir, "scripts");
                if (Directory.Exists(scriptsDir))
                {
                    foreach (string psFile in Directory.GetFiles(scriptsDir, "*.ps1", SearchOption.TopDirectoryOnly))
                    {
                        EnsureUtf8WithBom(psFile);
                    }
                }
            }
            catch
            {
                // Suppress errors to prevent blocking execution
            }
        }

        private static void EnsureUtf8WithBom(string filePath)
        {
            try
            {
                if (!File.Exists(filePath)) return;

                byte[] bytes = File.ReadAllBytes(filePath);
                // Check if already has UTF-8 BOM (0xEF, 0xBB, 0xBF)
                if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
                {
                    return;
                }

                // Check if UTF-16 BOM
                if (bytes.Length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF)))
                {
                    return;
                }

                // Read as UTF-8 and re-write with UTF-8 BOM
                string content = Encoding.UTF8.GetString(bytes);
                File.WriteAllText(filePath, content, new UTF8Encoding(true));
            }
            catch
            {
                // Suppress errors to prevent blocking execution
            }
        }
    }
}
