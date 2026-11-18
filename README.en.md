# StartupFolderLauncher

[Japanese Documentation (README.md)](README.md)

**StartupFolderLauncher** is a portable Windows startup launcher that keeps the drag-and-drop simplicity of the Windows Startup folder while adding **UAC-free elevated launch**, **GUI startup reordering**, **zero console window flashing**, **smart auto-tray-minimize (with two-stage startup protection for apps like LINE)**, and **opt-in process watchdog recovery on workstation unlock**.

---

## Quick Start (3 Steps)

1. **Download the latest release ZIP** (e.g., `StartupFolderLauncher_v1.1.0.zip`) from the [Releases page](https://github.com/doanobu8982-design/StartupFolderLauncher/releases/latest) and extract it to a permanent folder (e.g., `C:\Tools\StartupFolderLauncher`).
2. **Drop your shortcuts (`.lnk`) or executables (`.exe`, `.bat`, `.cmd`)** into the **`スタートアップ`** folder.
3. **Double-click `インストール.bat`** and accept the UAC prompt to register the scheduled tasks.

> Use **`管理画面を開く.exe`** anytime to reorder apps, toggle Administrator privileges, or configure the watchdog via GUI.

---

## Key Features

* **Zero Console Window Flashing (`launcher.exe` / `管理画面を開く.exe`)**:
  * Lightweight native Windows GUI binaries eliminate the brief console window flash caused by running `powershell.exe` directly.
* **GUI Privilege Toggling**:
  * Check the "管理者" (Admin) box in the GUI to launch an app with elevated privileges (skipping UAC prompts). Unchecked items launch safely as a standard user via Explorer's `Shell.Application` COM interface.
* **Custom Startup Ordering & Taskbar Readiness Wait**:
  * Arrange startup order with "▲ Up" / "▼ Down" in the GUI. On logon, the launcher waits for `Shell_TrayWnd` before launching apps sequentially so system tray icons register reliably.
* **Auto Tray-Minimize & Two-Stage Startup Profile (`auto_close_profile`)**:
  * Automatically closes main windows after startup to keep apps minimized in the system tray (`auto_close_window`).
  * **Built-in LINE preset in `config.default.json`**: Using `auto_close_profile.wait_process` (`LineMediaPlayer`), the closer waits until the main gate process is running before sending a close signal—preventing premature termination during splash-screen or initialization phases.
* **Safe Watchdog (Default: OFF)**:
  * On workstation unlock (`SessionUnlock`), only apps explicitly enabled for monitoring are checked and restarted if closed. Includes a point-and-click Process Picker in the GUI.
* **Concurrency Control, Unicode Path Safety & Log Rotation**:
  * Uses a named mutex (`Global\StartupFolderLauncher_Mutex`), `-LiteralPath` throughout PowerShell scripts, and automatic line-count rotation for `launcher.log` (UTF-8 without BOM).

---

## Package Structure

```text
StartupFolderLauncher/
├── スタートアップ/             # Place shortcuts and executables to auto-launch
│   └── .gitkeep
├── インストール.bat            # Setup: Double-click to register tasks (auto UAC elevation)
├── アンインストール.bat        # Teardown: Double-click to remove tasks (auto UAC elevation)
├── 管理画面を開く.exe          # GUI: Open management control panel (no console flash)
├── launcher.exe                # Engine: Completely invisible native launcher
├── config.default.json         # Template config (includes LINE auto_close_profile preset)
├── config.json                 # Active config (auto-generated on first run)
├── launcher.ps1                # Main launcher engine script
├── view_status.ps1             # GUI management script (Windows Forms)
├── scripts/                    # Internal helper scripts
│   ├── register_task.ps1       # Task Scheduler registration script
│   ├── unregister_task.ps1     # Task Scheduler unregistration script
│   └── window_closer.ps1       # Auto tray-minimize watcher script
├── launcher.log                # Execution log (auto-generated on first run)
├── LICENSE                     # MIT License
├── README.md                   # Japanese documentation
└── README.en.md                # English documentation
```

---

## Setup & Uninstallation

### Register Scheduled Tasks
Double-clicking `インストール.bat` registers two tasks in Windows Task Scheduler:
* **`StartupFolderLauncher`**: Runs `launcher.exe` at user logon (`LogonTrigger`).
* **`StartupFolderLauncher_Unlock`**: Runs `launcher.exe -IsUnlockTrigger` on workstation unlock (`SessionUnlock`).

### Uninstall
Double-click `アンインストール.bat` to remove both scheduled tasks cleanly.

---

## Configuration (`config.json` / `config.default.json`)

On first run, `config.json` is generated from `config.default.json`. Changes made in `管理画面を開く.exe` are saved automatically.

```json
{
  "settings": {
    "stagger_interval_ms": 500,
    "logon_check_shell": true,
    "shell_timeout_sec": 30,
    "auto_close_timeout_sec": 300,
    "max_log_lines": 200,
    "window_width": 860,
    "window_height": 600,
    "launch_order": []
  },
  "overrides": [
    {
      "match_name": "LINE.lnk",
      "enabled_watch": true,
      "run_as_admin": false,
      "auto_close_window": true,
      "auto_close_profile": {
        "wait_process": "LineMediaPlayer"
      },
      "watch_process_name": "LINE",
      "arguments": "",
      "hidden": false
    }
  ]
}
```

### `settings`
| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `stagger_interval_ms` | Number | `500` | Delay in milliseconds between launching each item. |
| `logon_check_shell` | Boolean | `true` | Wait for Windows taskbar readiness on logon. |
| `shell_timeout_sec` | Number | `30` | Maximum wait timeout (seconds) for taskbar readiness. |
| `auto_close_timeout_sec` | Number | `300` | Maximum timeout (seconds) for `window_closer.ps1` auto-close monitoring. |
| `max_log_lines` | Number | `200` | Maximum lines retained in `launcher.log`. |
| `window_width` | Number | `860` | Saved GUI window width (pixels, minimum 860). |
| `window_height` | Number | `600` | Saved GUI window height (pixels, minimum 500). |
| `launch_order` | Array | `[]` | Ordered list of item filenames to launch. |

### `overrides`
| Key | Description |
| :--- | :--- |
| `match_name` | Wildcard filename pattern (e.g., `LINE.lnk`, `Discord*`). |
| `enabled_watch` | Enables unlock watchdog monitoring when `true` (default: `false`). |
| `run_as_admin` | Launches with elevated privileges (skipping UAC) when `true`. |
| `auto_close_window` | Automatically closes the main window after launch to minimize to tray. |
| `auto_close_profile` | Profile for two-stage auto-close. `wait_process` delays closing until the specified gate process is running (e.g., `LineMediaPlayer` for LINE, preventing premature exit during splash-screen startup). |
| `watch_process_name` | Process name (without `.exe`) to monitor. |
| `arguments` | Additional command-line arguments. |
| `hidden` | Launches the application with a hidden window when `true`. |

---

## License

Released under the [MIT License](LICENSE).
