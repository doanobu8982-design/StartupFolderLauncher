# StartupFolderLauncher

[Japanese Documentation (README.md)](README.md)

**StartupFolderLauncher** is a portable Windows startup launcher that preserves the simple drag-and-drop convenience of the standard Windows Startup folder, while adding:
- **Run as Administrator** without UAC confirmation dialogs
- **Custom startup order reordering** via GUI
- **Shell / Taskbar readiness wait** to prevent missing system tray icons
- **Zero console window flashing (`launcher.exe`)** using an ultra-lightweight native C# binary
- **Automated process watchdog and recovery** upon workstation unlock

All items are managed inside a single unified `スタートアップ` (Startup) folder. Privilege switching, ordering, and watchdog toggles can all be controlled with one click in the intuitive desktop GUI.

---

## 1. Key Features & Architecture

* **Zero Console Window Flashing (`launcher.exe`)**:
  * Employs an ultra-compact native GUI binary compiled with Windows standard C# compiler (`csc.exe`).
  * Completely eliminates the 0.05-second console flash that occurred with `powershell.exe -WindowStyle Hidden`.
* **Unified Folder & GUI Privilege Toggling**:
  * Store all shortcuts and executables in a single `スタートアップ` folder.
  * Toggling the "管理者" (Admin) checkbox in the GUI runs the application with elevated privileges (UAC prompt skipped). Standard user execution runs safely via Explorer's `Shell.Application` COM interface.
* **Custom Startup Ordering**:
  * Use "▲ Up" and "▼ Down" buttons in the GUI to arrange startup sequence. Applications launch sequentially according to this order.
* **Window Size Memory**:
  * Automatically saves window dimensions upon closing and restores them on the next run.
* **Flicker-Free GUI & Differential Real-Time Log Streaming**:
  * DataGridView uses double-buffering and redraw locking to eliminate visual flicker.
  * Safe 2-second timer automatically appends and scrolls only new log entries without redrawing the entire form.
* **Automatic UAC Elevation for Batch Files**:
  * `インストール.bat` and `アンインストール.bat` automatically trigger UAC elevation when double-clicked.
* **Taskbar Readiness Check**:
  * Detects when `Shell_TrayWnd` is ready via Win32 API before launching apps to ensure tray icons register properly.
* **Safe Watchdog (Default: OFF)**:
  * Only applications with watchdog explicitly enabled are checked upon workstation unlock (`SessionUnlock`). Unmonitored applications are skipped to avoid accidental duplicate instances.
* **GUI Process Picker**:
  * Select from running processes with a point-and-click dialog to configure watchdog process names without manually editing JSON.
* **Mutex Concurrency Control**:
  * Named mutex (`Global\StartupFolderLauncher_Mutex`) guarantees only one instance runs during overlapping system triggers.
* **Robust Japanese / Unicode Path Support**:
  * Strict `-LiteralPath` throughout PowerShell scripts prevents errors with brackets or special characters.
* **Automatic Log Rotation**:
  * Logs entries in UTF-8 without BOM, automatically trimming older lines when exceeding configured limits.

---

## 2. Directory Structure

```text
StartupFolderLauncher/
├── スタートアップ/             # Place all shortcuts and executables here
│   └── .gitkeep
├── インストール.bat            # Setup: Double-click to register tasks (auto UAC elevation)
├── アンインストール.bat        # Teardown: Double-click to unregister tasks (auto UAC elevation)
├── 管理画面を開く.exe          # GUI: Double-click to open management control panel
├── launcher.exe                # Engine: Completely invisible native launcher
├── config.default.json         # Configuration template (tracked in Git)
├── config.json                 # Active configuration (auto-generated on first run, gitignored)
├── launcher.ps1                # Main launcher engine script
├── view_status.ps1             # GUI management application script (Windows Forms)
├── scripts/
│   ├── build_package.ps1       # Distribution ZIP builder script
│   ├── launcher.cs             # launcher.exe C# source code
│   ├── register_task.ps1       # Task Scheduler registration script
│   └── unregister_task.ps1     # Task Scheduler unregistration script
├── launcher.log                # Execution log (auto-generated on first run)
├── README.md                   # Japanese documentation
└── README.en.md                # English documentation
```

---

## 3. Quick Setup

### 3.1 Installation (Task Scheduler)
1. Extract or clone this folder to a permanent location (e.g. `C:\Tools\StartupFolderLauncher`).
2. Double-click **`インストール.bat`**.
3. Accept the UAC prompt.
4. Two tasks will be automatically registered in Windows Task Scheduler:
   * **`StartupFolderLauncher`**:
     * Trigger: User Logon (`LogonTrigger`)
     * Action: `launcher.exe`
   * **`StartupFolderLauncher_Unlock`**:
     * Trigger: Workstation Unlock (`SessionStateChangeTrigger` - SessionUnlock)
     * Action: `launcher.exe -IsUnlockTrigger`

### 3.2 Uninstallation
1. Double-click **`アンインストール.bat`** (auto UAC elevation).
2. All registered tasks are cleanly removed.

---

## 4. Usage

### 4.1 Adding Applications
* Place shortcuts (`.lnk`) or executables (`.exe`, `.bat`, `.cmd`) inside the `スタートアップ` folder.
* Open `管理画面を開く.exe` to check the "管理者" (Admin) box if you want elevated privileges.

### 4.2 Watchdog Behavior
* **On Logon**:
  * Launches all registered items sequentially according to `launch_order`. Running apps are skipped to prevent duplicates.
* **On Unlock**:
  * Only items with watchdog set to **ON** are checked and revived if terminated. Unmonitored items are skipped.

### 4.3 Configuration (`config.json`)
The active configuration is automatically saved when changed through the GUI.

```json
{
  "settings": {
    "stagger_interval_ms": 500,
    "logon_check_shell": true,
    "shell_timeout_sec": 30,
    "max_log_lines": 200,
    "window_width": 1040,
    "window_height": 680,
    "launch_order": []
  },
  "overrides": []
}
```

* **`config.default.json`**: Shipped template configuration.
* **`config.json`**: Generated from template on first run. Stored locally and ignored by Git.

---

## 5. Building Releases
To generate a clean portable distribution ZIP package without affecting your local settings or shortcuts, run:

```powershell
pwsh scripts/build_package.ps1 -Version "v1.0.0"
```

The output package will be created in `dist/StartupFolderLauncher-v1.0.0.zip`.

---

## 6. License
MIT License.
