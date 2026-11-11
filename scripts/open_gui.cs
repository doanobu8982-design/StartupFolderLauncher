using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace StartupFolderLauncher
{
    static class Program
    {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);

        private const int SW_RESTORE = 9;
        private const string WindowTitle = "スタートアップランチャー - ステータス管理";
        private const string MutexName = "Global\\StartupFolderLauncher_GUI_Mutex";

        [STAThread]
        static void Main()
        {
            IntPtr existingHwnd = FindWindow(null, WindowTitle);
            if (existingHwnd != IntPtr.Zero)
            {
                ShowWindow(existingHwnd, SW_RESTORE);
                SwitchToThisWindow(existingHwnd, true);
                SetForegroundWindow(existingHwnd);
                return;
            }

            bool isNew;
            using (var mutex = new Mutex(true, MutexName, out isNew))
            {
                if (!isNew)
                {
                    IntPtr hWnd = FindWindow(null, WindowTitle);
                    if (hWnd != IntPtr.Zero)
                    {
                        ShowWindow(hWnd, SW_RESTORE);
                        SwitchToThisWindow(hWnd, true);
                        SetForegroundWindow(hWnd);
                    }
                    return;
                }

                string appDir = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(appDir, "view_status.ps1");

                if (!File.Exists(scriptPath))
                {
                    return;
                }

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                Process.Start(psi);
            }
        }
    }
}
