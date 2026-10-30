# windows11-provisioning

A USB flash drive that installs and sets up Windows 11 Pro on a new computer: from booting the USB to a ready
desktop, without clicking through the installer.

## Table of Contents

1. [What it is](#1-what-it-is)
2. [WARNING](#2-warning)
3. [Requirements](#3-requirements)
4. [What gets configured](#4-what-gets-configured)
5. [Building the install USB](#5-building-the-install-usb)
6. [Installing](#6-installing)
7. [How it works](#7-how-it-works)
8. [After the script](#8-after-the-script)
9. [Riskiest things to change](#9-riskiest-things-to-change)
10. [Troubleshooting](#10-troubleshooting)
11. [Security notes](#11-security-notes)
12. [Lessons learned](#12-lessons-learned)
13. [Language note](#13-language-note)
14. [License](#14-license)

---

## 1. What it is

**Problem:** every new computer had to be set up by hand: Windows installation, OOBE screens, time zone, regional
format, keyboards, apps, drivers, and a check at the end that nothing was missed.

**Solution:** a standard Windows 11 install USB plus three files from this repo:

- `autounattend.xml` - Windows Setup reads it and installs Windows 11 Pro without questions (no OOBE screens),
  creates a local account and logs in once automatically;
- `Setup\Unattend\Check-Disk.cmd` - runs before anything is erased and stops the installation if the disk
  layout looks wrong;
- `Setup\Setup.ps1` (started by `Setup\Start.bat`) - after the first logon it sets region and keyboards, checks
  the network, installs apps with Ninite, installs drivers through Windows Update, cleans up after itself and
  leaves a report on the desktop.

This is my own working setup, published as documentation. It is not a product: adapt it to your needs. The
sections below say what is safe to change and what is risky.

## 2. WARNING

> **This USB ERASES Disk 0 of the computer it boots in.**

- **One internal disk:** Disk 0 is erased **without any question**.
- **More than one internal disk** (for example NVMe + HDD): before anything is erased, a console window lists all
  disks (type, model, size, number of partitions, volumes) and asks:

  ```
  Upisi DA za nastavak, bilo sta drugo = stop:
  ```

  ("Type DA to continue, anything else = stop"). Only exactly `DA` or `da` continues - and then only **Disk 0** is
  erased, other disks are not touched. Anything else (other text, empty Enter) stops the installation and shuts
  the computer down; nothing is erased. There is no timeout: it waits until you answer.
- The installation also stops (shutdown, nothing erased) if Disk 0 is a USB disk or a disk of unknown type, if any
  disk of unknown type exists, or if this USB already installed Windows on this computer (the computer booted from
  the USB again after installation).
- Disk 0 is chosen by the firmware and storage driver, not by size or by what is on it. On a computer with two disks,
  read the list before typing `DA`.
- Windows Setup looks for `autounattend.xml` on **every** USB drive that is plugged in. **Do not leave this USB in a
  computer you do not want erased**, and do not keep it plugged in while you install Windows from a different USB.

## 3. Requirements

| What | Details |
|---|---|
| Computer | Supported for Windows 11: TPM 2.0, Secure Boot, supported CPU. The project does **not** bypass the Windows 11 hardware check. |
| Architecture | **x64 only** (`processorArchitecture="amd64"` in `autounattend.xml`). ARM computers are not supported. |
| Boot mode | UEFI. Disk 0 is partitioned as GPT (EFI + MSR + Windows); Legacy/CSM boot is not supported. |
| USB flash drive | 8 GB or larger. Everything on it is erased when the Windows USB is created. |
| Network | **LAN cable.** Wi-Fi is **not** configured automatically (no Wi-Fi passwords on the USB). Without internet the Network section fails; connect Wi-Fi by hand and run `Start.bat` again. |
| Language of the script | Serbian (Latin script, ASCII only). The only thing you type is `DA` in the multi-disk confirmation. |

## 4. What gets configured

> **Built for Serbia:** time zone `Central Europe Standard Time` (Belgrade), regional format `sr-Latn-RS`,
> keyboards US + Serbian (Latin) + Serbian (Cyrillic), home location Serbia. Computer name `pc1`, local account
> `admin` with password `admin`, which Windows forces you to change at the next logon. Change these values for
> your country **in both files** where they appear (see the "Where to change" column).

Line numbers below are for the current version of the files.

### `autounattend.xml` (Windows Setup)

| What | Value | Where to change |
|---|---|---|
| Setup language, Windows display language | `en-US` | `autounattend.xml` lines 19-24, 133-134 - **keep it, see [section 9](#9-riskiest-things-to-change)** |
| Disk check before erasing | `Setup\Unattend\Check-Disk.cmd` | `autounattend.xml` lines 35-48 |
| Disk 0: wipe + GPT partitions | EFI 260 MB (FAT32), MSR 16 MB, Windows = rest (NTFS, `C:`). No separate Recovery partition (Windows keeps WinRE in `C:\Recovery`). | `autounattend.xml` lines 52-104 |
| Edition | Windows 11 Pro, Microsoft's public **generic installation key** `VK7JG-NPHTM-C97JM-9MPGT-3V66T`. It only selects the edition, it does **not** activate Windows. | `autounattend.xml` line 111 |
| Computer name | `pc1` | `autounattend.xml` line 121 (also used by `Check-Disk.cmd` line 285) |
| Time zone | `Central Europe Standard Time` | `autounattend.xml` line 122 **and** `Setup.ps1` `$RegionTimeZoneId` (line 1497) |
| Keyboards | `0409:00000409;241A:0000081A;281A:00000C1A` = US (default), Serbian (Latin), Serbian (Cyrillic) | `autounattend.xml` line 132 **and** `Setup.ps1` `$RegionLanguages` / `$UsKeyboardLayout` (lines 1500-1501) |
| Regional format | `sr-Latn-RS` | `autounattend.xml` line 135 **and** `Setup.ps1` `$RegionCulture` (line 1498) |
| System locale (non-Unicode programs) | `en-US` - not changed | `autounattend.xml` line 133 |
| OOBE screens | All hidden; `ProtectYourPC` = `3` (recommended privacy settings off - least data sent to Microsoft) | `autounattend.xml` lines 139-147 |
| Local account | `admin`, member of Administrators (the built-in `Administrator` stays disabled), password `admin` | `autounattend.xml` lines 150-162; the password is in **two** `<Value>` fields (lines 157 and 170), they must be the same. If you rename the account, also change `$AdminAccountName` in `Setup.ps1` (line 933). |
| Automatic logon | Once, as `admin` | `autounattend.xml` lines 165-173 |
| After first logon | Searches all drive letters for `Setup\Start.bat` and starts it in a new window | `autounattend.xml` lines 177-183 |

### `Setup\Setup.ps1` (after the first logon)

Sections run in this order. Every section is logged; an error in one section does not stop the others.

| # | Section | What it does | Where to change |
|---|---|---|---|
| 1 | Foundation (always) | Admin rights (asks for UAC if missing), log and transcript, lock against running twice, `state.json` for resuming, deletes the AutoLogon password and the answer file cache, blocks automatic Windows Update restarts while it runs | - |
| 2 | `Region` | Time zone -> keyboards -> regional format -> home location (GeoId `271`, checked by name "Serbia") -> copies format, home location and keyboards to the Welcome screen and to new user accounts | lines 1497-1501; the name check for GeoId is on line 1599 |
| 3 | `Network` | Internet check (`http://www.msftconnecttest.com/connecttest.txt`, fallback `https://www.microsoft.com`). Network driver from the USB **only** when there is no internet **and** no physical adapter is `Up` (or a network device has no driver). Waits up to 6 x 10 s. Clock sync (`w32tm /resync`); a clock off by more than 5 minutes fails the section. | lines 1634-1640 |
| 4 | `Apps` | Runs the Ninite installer from `Setup\Apps\` **only** if the signature is `Valid` and the signer is exactly `Secure By Design Inc.`. Waits for Ninite to finish (max 60 min), closes its window, logs new programs. No Ninite on the USB = normal, no error. | lines 1891-1911; optional required apps: see below |
| 5 | `Browser` | If Chrome is installed: Chrome becomes the default browser (`.htm`, `.html`, `http`, `https`) **for new user accounts** (`Dism /Online /Import-DefaultAppAssociations`, merged with the existing Windows defaults). The account running the script is not changed (see [Lessons learned](#12-lessons-learned)). | lines 2560-2565 |
| 6 | `Drivers` | Restart first if Windows is already waiting for one. Drivers from Windows Update (built-in COM API, up to 3 rounds). **BIOS/firmware updates are not installed**, only listed in the report. Second pass: drivers from `Setup\Drivers\` on the USB (`pnputil`, up to 3 passes). Devices still without a driver go to the report with their Hardware ID. | lines 2712-2716 |
| - | Password | Only at the end of a full run (not with `-Section`): account `admin` must set a new password at the next logon | `Set-AdminPasswordChange` (line 962) |
| 7 | `Report` | Report on the desktop; if Chrome is installed and is not the default for this account, opens Settings > Default apps on the Chrome page | lines 3064-3400 |

> **Required apps (optional).** `$NiniteRequiredApps` (`Setup.ps1` lines 1905-1911) is **empty** by default: the
> script logs what Ninite installed, but does not require any specific app. If you always install the same package,
> you can list apps there (examples are in the comment above the list). Then, if one of them is missing after
> Ninite, the `Apps` section ends as `Failed`, the report shows `!!! NIJE INSTALIRANO: ...` and the exit code is
> `1`. Only list apps that really are in your Ninite package.

**Not configured on purpose:** Windows display language (chosen by the install media), system locale, Wi-Fi,
BitLocker (left at the Windows default, only reported), domain join, computer rename, BIOS/firmware updates,
personal or cosmetic settings.

## 5. Building the install USB

You need: a USB flash drive, 8 GB or larger (EVERYTHING on it will be erased), and any Windows PC with internet
access.

### Step 1 - Create a bootable Windows 11 USB

1. Open https://www.microsoft.com/software-download/windows11
2. Under "Create Windows 11 Installation Media", click "Download Now".
3. Run the downloaded file, click "Yes" when Windows asks for permission.
4. Click "Accept" on the license screen.
5. Uncheck "Use the recommended options for this PC" and select Language: **English (United States)** (required -
   see [section 9](#9-riskiest-things-to-change)), Edition: Windows 11. Click "Next".
6. Choose "USB flash drive" -> Next -> select your USB -> Next.
7. Wait until it finishes (20-60 min), then click "Finish".

### Step 2 - Add this project to the USB

1. Download the latest ZIP from
   https://github.com/Lazar433/windows11-provisioning/releases
2. Right-click the ZIP -> "Extract All".
3. Open the extracted folder, then open the `usb` folder.
4. Select everything inside (Ctrl+A), copy (Ctrl+C) and paste (Ctrl+V) into the root of the USB - where `setup.exe`
   is. Copy the CONTENTS of `usb`, not the folder itself. `autounattend.xml` must end up next to `setup.exe`.

### Step 3 - Add your apps (Ninite)

1. Open https://ninite.com
2. Tick the apps you want. Include Chrome if you want it as the default browser.
3. Click "Get Your Ninite". A file like "Ninite Chrome 7Zip Installer.exe" is downloaded.
4. Copy it to `Setup\Apps\` on the USB. Do not rename it - the script only runs a file named `Ninite*.exe` that is
   digitally signed by Ninite's publisher (`Secure By Design Inc.`). If there are several, the newest one is used.

Skipping this step is fine: no apps are installed, the script continues.

### Step 4 (optional) - Network driver for computers without internet

Only needed if Windows has no built-in driver for the network card.

1. On a computer where the network card is visible: Device Manager -> right-click the card -> Properties -> Details
   -> Hardware Ids -> copy the top value.
2. Search it on https://www.catalog.update.microsoft.com, click "Download", then the .cab link in the window that
   opens.
3. Double-click the .cab, select all files, extract to a new folder.
4. Copy that folder into `Setup\Drivers\Network\` - one subfolder per driver package, with the `.inf`, `.sys` and
   `.cat` files (not an installer `.exe`).

Drivers anywhere under `Setup\Drivers\` are also used in the second driver pass of the `Drivers` section.

### Step 5 (optional) - Installers you run by hand

Put them into `Rucno\` (Serbian for "manual") in the root of the USB. The script never runs or touches them; the
report reminds you to install them.

### Your finished USB

```
USB:\
|-- boot\                      <- from Microsoft (Step 1)
|-- efi\
|-- sources\
|-- support\
|-- autorun.inf
|-- bootmgr
|-- bootmgr.efi
|-- setup.exe
|-- autounattend.xml           <- from this project (Step 2)
|-- Setup\
|   |-- Start.bat
|   |-- Setup.ps1
|   |-- Unattend\
|   |   `-- Check-Disk.cmd
|   |-- Apps\
|   |   |-- README.txt
|   |   `-- Ninite ... Installer.exe       <- Step 3 (optional)
|   `-- Drivers\
|       `-- Network\
|           |-- README.txt
|           `-- <driver folder>\           <- Step 4 (optional)
|-- Rucno\
|   |-- README.txt
|   `-- <your installers>                  <- Step 5 (optional)
`-- Logs\                      <- created by the scripts during installation
```

## 6. Installing

1. Plug in the LAN cable and the USB.
2. Power on and press the **Boot Menu** key (one-time boot menu - do not change the boot order in BIOS):

   | Manufacturer | Boot Menu key |
   |---|---|
   | Dell | F12 |
   | Lenovo | F12 |
   | HP | F9, or Esc and then F9 |
   | ASUS | laptop: Esc / desktop: F8 |
   | Acer | F12 |
   | MSI | F11 |

   Keys can differ between models and BIOS versions - check the manual if none of these works.
3. Choose the entry that starts with **`UEFI:`** followed by the name of your USB. If the USB is listed twice, the
   `UEFI:` entry is the right one.
4. **Leave the USB in** until the end. The script runs from it and writes logs to it.

What you see, in order:

1. **Windows Setup starts, Check-Disk runs.** With one internal disk there is nothing to answer. With more than one
   internal disk you get the disk list and the `DA` question ([section 2](#2-warning)). If the check fails, a `STOP:`
   message with the reason is shown and the computer shuts down after 30 seconds - nothing is erased.
2. **Windows installation** - progress screen and several automatic restarts, no questions.
3. **Automatic logon** as `admin` (once). No OOBE screens.
4. **The script** starts in a window titled "Provisioning" with colored log lines. If Windows asks for permission
   (UAC), click "Yes".
   - If a section needs a restart (for example after Windows Update drivers), the script says so in red and restarts
     after 60 seconds (cancel with `shutdown /a`). There is **no** automatic logon after this restart: log in as
     `admin` / `admin`, and the script continues by itself about 30 seconds after logon. At most 3 restarts.
5. **End:** red `!!!` warnings (same as at the top of the report), the path to the report, the Settings page for the
   default browser (if Chrome is installed) and `Setup.ps1 je zavrsio. Exit code: N` (`0` = OK, `1` = there were
   errors, `2` = not started). Press any key to close the window.

Duration: roughly 20 minutes to an hour per computer. It depends on the disk, the internet connection, the size of
the Ninite package, the number of Windows Update drivers and whether a restart is needed.

## 7. How it works

### Phase 1 - WinPE (Windows Setup, before anything is erased)

`autounattend.xml`, pass `windowsPE`:

1. `RunSynchronous` command 1 looks for `Setup\Unattend\Check-Disk.cmd` on drive letters C-Z (without X, the WinPE
   RAM disk) and calls it with the USB letter.
2. `Check-Disk.cmd` runs `diskpart` (`detail disk`) for Disk 0-7 and reads the `Type` line:
   - internal = `NVMe`, `SATA`, `SAS`, `ATA`, `RAID`, `SCSI`; `USB` = USB; anything else = unknown;
   - Disk 0 must be internal, no disk may be unknown, and the answer file cached by Windows
     (`\Windows\Panther\unattend.xml` on any drive) must not contain `WINPROV-AUTOUNATTEND` or the computer name
     `pc1` - otherwise this is a reboot from the USB after a finished installation;
   - more than one internal disk -> disk list + `DA` question;
   - everything is appended to `<USB>\Logs\Disk_check.txt`.

   Only when everything passes does it write `X:\Windows\Temp\disk-ok.txt`.
3. `RunSynchronous` command 2: if `disk-ok.txt` does not exist -> `wpeutil shutdown`, and if shutdown fails, an
   endless loop. Windows Setup continues after a failed command, so the exit code is not the protection: the command
   simply never returns, and Setup never reaches the disk step.
4. Disk 0 is wiped and partitioned, Windows 11 Pro is installed.

Passes `specialize` and `oobeSystem`: computer name, time zone, locale and keyboards, account `admin`, one automatic
logon, and `FirstLogonCommands` that start `Setup\Start.bat` from the USB.

### Phase 2 - Setup.ps1

`Start.bat` runs `powershell.exe -NoProfile -ExecutionPolicy Bypass` (only for this one process) and passes its
arguments on to `Setup.ps1`. Requires Windows PowerShell 5.1 (built into Windows 11).

1. **Foundation:** if the process has no full admin token it starts an elevated copy of itself (UAC). Log folder
   `C:\ProgramData\Provisioning\Logs`, transcript, lock file, `state.json`. Deletes the resume task (see below),
   deletes the AutoLogon password and the answer file cache, and blocks automatic restarts by Windows Update while
   the script runs (`NoAutoRebootWithLoggedOnUsers` + active hours; original values are restored at the end of every
   run).
2. **Sections** `Region`, `Network`, `Apps`, `Browser`, `Drivers` - in that order. Each section's status is saved
   in `state.json`: `Done` sections are skipped on the next run, `Failed` sections run again. A section interrupted
   3 times in a row (power loss, closed window) is marked `Failed`.
3. **Password:** account `admin` must change its password at the next logon (full run only).
4. **Cleanup** and its verification, then the **report**.

### Restart and resume

A section asks for a restart when Windows Update reports `RebootRequired`, `pnputil` returns `3010`, or Windows was
already waiting for a restart before drivers. Then:

- the section is `RebootPending`, the following sections wait;
- a scheduled task **`Provisioning-Resume`** is created: "At logon" of the same account, +30 s delay, highest
  privileges. It runs `C:\ProgramData\Provisioning\Resume.ps1`, which finds the USB (any drive letter, up to 6 x 10 s),
  checks that `Setup.ps1` has the same SHA256 as when the restart was planned, and starts `Start.bat` with the same
  arguments;
- logs are copied to the USB, then `shutdown /r /t 60`;
- at the start of the next run the task and `Resume.ps1` are deleted immediately, so a crash cannot cause a loop;
- at most 3 restarts; a 4th request marks the waiting sections as `Failed`.

### Cleanup at the end

- restart protection restored to the original values;
- task `Provisioning-Resume` and `Resume.ps1` deleted;
- AutoLogon: `DefaultPassword` and `AutoLogonCount` deleted, `AutoAdminLogon` = `0`;
- answer file cache deleted (`C:\Windows\Panther\unattend.xml`, `Panther\autounattend.xml`,
  `Panther\Unattend\unattend.xml`);
- each item is then **read back** from the system and shown in the report (`CISCENJE`: `OK` / `OSTALO`, with the
  exact command for manual cleanup);
- logs are copied to the USB and checked with SHA256. Only if the copy is complete **and** there were no errors,
  `C:\ProgramData\Provisioning` is deleted. With errors it stays, and a shortcut `Provisioning LOGOVI.lnk` is placed on
  the desktop; after a successful re-run both are deleted.

### Parameters

| Parameter | What it does |
|---|---|
| `-DryRun` | Reads the system and logs what it would do. Changes nothing, does not write `state.json`. The report goes to the log folder, not to the desktop. |
| `-Section <names>` | Runs only the listed sections: `Region`, `Network`, `Apps`, `Browser`, `Drivers`, `Report`. For them `state.json` is ignored (they run even if `Done`). The foundation always runs. The admin password step is skipped. |

Run `Start.bat` as administrator (right-click -> "Run as administrator"), from a Command Prompt in the `Setup` folder
of the USB:

```bat
Start.bat
Start.bat -DryRun
Start.bat -Section Apps,Browser,Report
```

Exit code: `0` = all OK, `1` = errors in sections, `2` = the script did not start (no admin rights, already running,
cannot create the log folder, wrong section name).

## 8. After the script

### The report

- **Name:** `Provisioning_Izvestaj_<COMPUTERNAME>_<yyyyMMdd_HHmmss>.txt`
- **Where:** on the desktop of the account that ran the script (`admin`), and a copy in the computer's log folder on
  the USB.
- **Contents:** warnings at the top in capitals with `!!!`, then sections: `RACUNAR` (manufacturer, model, serial
  number, BIOS, Windows version, edition, activation, license key type in BIOS), `BITLOCKER (C:)`, `SEKCIJE` (status
  and time of every section, number of restarts), `PROGRAMI`, `CHROME DEFAULT`, `UREDJAJI BEZ DRAJVERA` (devices
  without a driver, with Hardware ID, a ready Google search line and a Microsoft Update Catalog link),
  `BIOS / FIRMWARE`, `CISCENJE`, `RUCNO PRE PREDAJE` (manual steps), `LOGOVI`.

> **Check the password line** in `RUCNO PRE PREDAJE`:
> `- Lozinka naloga admin (podrazumevana "admin"): nova pri sledecem logovanju - ...`
> - `podeseno - Windows trazi novu lozinku pri sledecem logovanju` = OK, Windows will ask for a new password;
> - `NIJE podeseno ...` = **change the password now**: `net user admin *`

### Logs on the USB

`<USB>\Logs\<BIOS serial number>_<yyyy-MM-dd_HHmm>\` (the computer name is used if the serial number is empty or a
placeholder). Contains `Setup_*.log`, `Transcript_*.txt`, `state.json`, a copy of the report, Windows Setup's
`setupact.log`, and the part of `Disk_check.txt` for this computer. With errors also `Diagnostics_*.zip` (logs,
Event Viewer errors and warnings, system info). `<USB>\Logs\Disk_check.txt` collects the disk checks of all
computers. The answer file cache is never copied (it can contain the password).

### What stays manual

- **Password** of `admin`, if the report says it was not forced (see above).
- **Computer name** (`pc1`) and **domain join**.
- **Apps from `Rucno\`** on the USB.
- **Default browser for the `admin` account** - the Settings page opens at the end; click "Set default".
- **BIOS/firmware updates** listed in the report: Settings > Windows Update > Advanced options > Optional updates >
  Driver updates, on AC power.
- **Activation**, if the report says the BIOS has a Home license and Pro was installed.
- **Wi-Fi.**

## 9. Riskiest things to change

| Change | What happens | Where |
|---|---|---|
| **Windows language other than English (United States)** on the install media | `Check-Disk.cmd` reads the English output of `diskpart` (`Type`, `No Media`, `is now the selected disk`, `Volume ###`, `Partition`) and the en-US format of `%time%`. With a different language it finds nothing and stops the installation (or behaves unpredictably). `autounattend.xml` also asks for `en-US`, which other media do not contain. | Language in Step 1 of [section 5](#5-building-the-install-usb); `Check-Disk.cmd` lines 129-133, 146, 212-222, 318-324; `autounattend.xml` lines 19-24, 133-134 |
| **Editing `.ps1` / `.bat` / `.cmd` with anything other than Notepad, or adding non-ASCII characters** (c with accents, s/z/dj with diacritics, typographic quotes, em dash...) | Windows PowerShell 5.1 reads a `.ps1` without BOM as ANSI, and `cmd.exe` uses the OEM code page. Non-ASCII characters break strings and comparisons; some editors also change line endings (these files must be CRLF). Keep them ASCII only. | All `.ps1`, `.bat`, `.cmd` files; `.gitattributes` keeps CRLF |
| **Renaming the Ninite file** | The script looks only for `Ninite*.exe`. Any other name: "no Ninite" - no apps, no error. | `Setup.ps1` `$NiniteFilter` (line 1892) |
| **Removing or changing the `WINPROV-AUTOUNATTEND` marker** | It is how `Check-Disk.cmd` recognizes that this USB already installed Windows on this computer. Without it, only the `pc1` name check is left; if you also changed the computer name, booting from the USB again after installation **erases the freshly installed Windows**. | `autounattend.xml` line 2; `Check-Disk.cmd` lines 283-285 |
| **Wrong value for time zone, regional format, keyboard or GeoId** | In `autounattend.xml`: Windows Setup can stop with an answer file error. In `Setup.ps1`: the `Region` section fails, the report shows `!!! SEKCIJA REGION: FAILED`. After changing the GeoId, also change the name check `'*Serbia*'`, or the section fails. | `autounattend.xml` lines 122, 132, 135; `Setup.ps1` lines 1497-1501, 1599 |
| **Ninite signer name** | The signer is compared exactly. If Ninite ever signs with a certificate under a different name, a newly downloaded Ninite is rejected: not run, `Apps` = `Failed`, report `!!! NINITE ODBIJEN ...` with the actual signer. Check the new file (`Get-AuthenticodeSignature`) and update the name only if it really is Ninite. | `Setup.ps1` `$NiniteSignerName` (line 1897) |
| **`autounattend.xml` always installs to Disk 0** | `DiskID` 0 is hard-coded. To install to a different disk: rename `autounattend.xml` to `autounattend.xml.off`, install Windows by hand, then run `Setup\Start.bat` as administrator. Rename it back afterwards. | `autounattend.xml` lines 55, 99 |

## 10. Troubleshooting

| Problem | Cause and fix |
|---|---|
| Check-Disk stops: `Disk 0 nije unutrasnji disk, nego NEMA` / Windows Setup does not see any disk | **Intel VMD / RST** (common on Dell) hides the NVMe disk from Windows Setup. In BIOS, switch the storage mode (for example "SATA/NVMe Operation") from RAID / RST / VMD to **AHCI**. The disk is erased anyway, so the existing installation does not matter. |
| Windows Setup stops shortly after it starts with a generic "Windows installation has failed" | Often the Windows 11 hardware check (TPM 2.0, Secure Boot, supported CPU) - in an unattended install it does not say so. Before clicking OK, press Shift+F10 and copy `X:\$WINDOWS.~BT\Sources\Panther\setupact.log` to the USB; a last entry from `hwreqchk` confirms it (see [Lessons learned](#12-lessons-learned)). Enable TPM and Secure Boot in BIOS; an unsupported CPU cannot be fixed - this project does not bypass the check. |
| Two internal disks | You get the disk list and the `DA` question ([section 2](#2-warning)). To install to the other disk: `autounattend.xml` -> `autounattend.xml.off`, manual installation, then `Setup\Start.bat` as administrator. |
| `STOP: Na X: je vec instalacija sa ovog flesa` | The computer booted from the USB again after installation. Nothing is erased. Remove the USB, power on, and once at the desktop plug the USB in and run `Setup\Start.bat` as administrator. Next time use the one-time Boot Menu instead of changing the boot order. |
| The script did not start after the first logon | Run `<USB>\Setup\Start.bat` as administrator. It continues where it stopped. |
| `NINITE ODBIJEN` in the report | The file is not validly signed by `Secure By Design Inc.` - the reason and the actual signer are in the report and the log. Download Ninite again from https://ninite.com. |
| Ninite not on the USB | Normal: `Ninite nije na flesu ... (nije greska)`, no apps installed. |
| `NIJE INSTALIRANO: ...` / `Apps` failed after Ninite | An app you listed in `$NiniteRequiredApps` is not installed - it is not in your Ninite package, or its installer failed (see the log). Fix the list or the package ([section 4](#4-what-gets-configured)). |
| `Network` failed: `Nema interneta` | Check the cable, or connect Wi-Fi by hand, then run `Start.bat` again. For a card without a built-in driver see Step 4 of [section 5](#5-building-the-install-usb). |
| A section failed | Run `Start.bat` again: only `Failed` sections run again; when everything passes, the logs on the computer are deleted. |
| Where are the logs? | WinPE / disk check: `<USB>\Logs\Disk_check.txt`. Script: `<USB>\Logs\<serial>_<date>\`, and with errors also `C:\ProgramData\Provisioning\` (shortcut `Provisioning LOGOVI` on the desktop). Windows installation: `C:\Windows\Panther\setupact.log` (also copied to the USB). |

## 11. Security notes

**Ninite signature check.** A USB is an easy way to bring malware into a computer, so the script runs Ninite only if
both are true:

- `Get-AuthenticodeSignature` returns `Valid`, and
- the signer's CN (common name) is **exactly** `Secure By Design Inc.` (case-sensitive comparison).

Why not "contains": a "contains" check also accepts any other name that includes the same text. Why not the full
Subject: other fields (`E=`, `L=`, `S=`) can change when the certificate is renewed. Why not the thumbprint: it changes
with every renewal, and the check would break on every new Ninite. The signature has a DigiCert **timestamp**, so a
file signed while the certificate was valid stays `Valid` after the certificate expires.

**Why `admin` / `admin` must be changed.** The password is public (it is in this repo) and identical on every
computer installed with this USB - one known password is enough to move from one computer to the next. At the end of
a full run `Setup.ps1` turns off "Password never expires", allows the user to change the password and runs
`net user admin /logonpasswordchg:yes`, then reads the account back (`PasswordExpired = 1`). If the password was
already changed after installation, it does not ask again. For many computers, Windows LAPS is the long-term
solution.

**What the script removes after itself:**

- the AutoLogon password (`DefaultPassword`), `AutoLogonCount`, and `AutoAdminLogon` = `0` - at the start of every
  run, verified at the end;
- the answer file cache in `C:\Windows\Panther\` (it can contain the password) - never copied to the USB;
- the scheduled task `Provisioning-Resume` and `Resume.ps1` - nothing runs with admin rights after the script ends;
- the Windows Update restart protection - restored to the original values;
- the logs in `C:\ProgramData\Provisioning` - after a verified (SHA256) copy to the USB, if there were no errors.

The AutoLogon password value is never written to a log - only whether it exists.

## 12. Lessons learned

- **`findstr`, `timeout` and `choice` do not exist in WinPE** (`boot.wim` on Media Creation Tool media). The first
  version of `Check-Disk.cmd` used `findstr`, found "no Disk 0" and stopped. Now it uses only built-in `cmd`
  commands plus `find.exe`, `diskpart.exe` and `wpeutil.exe`, and waits with a loop over `%time%`. Rule: anything that
  fails or returns nothing = STOP.
- **`Set-WinUserLanguageList` resets the regional format** to the display language (`sr-Latn-RS` -> `en-US`) right
  after the keyboards are changed. The `Region` section now sets keyboards *before* the format, and checks the format
  again before copying it to the Welcome screen.
- **Read the WinPE logs before you reboot.** On a test PC with two disks and an Intel Pentium G4400 (6th gen),
  Check-Disk listed the disks, I confirmed with `DA`, and Windows Setup started - then stopped after ~25 seconds with
  a generic "Windows installation has failed" message. `X:` in WinPE is a RAM disk and is wiped on reboot, so before
  clicking OK I opened a command prompt (Shift+F10) and copied the logs to the USB
  (`X:\$WINDOWS.~BT\Sources\Panther\setupact.log`, `setuperr.log` and `X:\Windows\setupact.log`, `setuperr.log`).
  `setuperr.log` only had harmless noise (no network in WinPE). The real clue was timing in `setupact.log`: the last
  entry, right before it stopped, came from `hwreqchk` - the Windows 11 hardware requirements check. A `reg query` in
  WinPE confirmed the CPU (G4400, not on Microsoft's supported list). In an unattended install this shows up as a
  generic failure instead of "This PC can't run Windows 11". Lesson: check requirements before you start, and save
  WinPE logs before rebooting.
- **UCPD and the default browser.** Windows protects the user's default browser choice (UserChoice, protected by the
  UCPD driver), so it cannot be set reliably by a script for an *existing* account without bypassing that protection.
  `Dism /Import-DefaultAppAssociations` works for *new* accounts (it is applied at their first logon); for `admin`
  the script only opens the right Settings page.
- **Ninite check: "contains" -> exact comparison** of the signer's CN (see [Security notes](#11-security-notes)).
- **Intel VMD hides the NVMe disk** from Windows Setup - the disk check sees "no Disk 0" and stops. Switching to
  AHCI in BIOS fixes it.

## 13. Language note

Messages, code comments, logs and the report are in Serbian (Latin script, ASCII only); this README is in English.
This project was built with AI assistance (Claude).

## 14. License

[MIT](LICENSE). The project is provided "as is", without warranty of any kind. It erases disks: read
[section 2](#2-warning) and test it on a computer you can afford to wipe before you use it on real ones.
