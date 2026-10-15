# fedora-migrate.sh

One script to **back up** a Fedora Workstation (apps, repositories, GNOME desktop, configs,
virtual machines) and **restore** it onto a freshly installed Fedora, without cloning the drive.

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [What is backed up](#what-is-backed-up)
- [What is restored (in order)](#what-is-restored-in-order)
- [Backup layout](#backup-layout)
- [Options](#options)
- [Testing on the new laptop - checklist](#testing-on-the-new-laptop---checklist)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

---

## Quick start

### 1. On the old system - back up

Close browsers, VS Code, Steam and running VMs first so their data is copied consistently.

```bash
cd ~/Downloads
./fedora-migrate.sh backup
```

- Default destination: `~/Documents/LINUX/BACKUP-RESTORE/` (pass another path as the 2nd argument,
  e.g. `./fedora-migrate.sh backup /run/media/$USER/USBDISK`).
- You are asked for your sudo password once.
- Questions you will see (Enter = default shown in capitals):
  - include SSH/GPG keys and the GNOME keyring (saved passwords)? `[Y/n]`
  - include installed Steam games (~22 GB, re-downloadable)? `[y/N]`
  - include each folder bigger than 1 GB (Bottles, `.wine`, `.lmstudio`, Flatpak app data ...)? `[Y/n]`
  - back up VM `Win10` (shuts it down first if it is running)? `[Y/n]`
  - pack everything into a single `.tar`? `[Y/n]` and then delete the unpacked folder? `[Y/n]`

Result:

```
~/Documents/LINUX/BACKUP-RESTORE/fedora_backup_YYYYMMDD_HHMMSS.tar
~/Documents/LINUX/BACKUP-RESTORE/fedora_backup_YYYYMMDD_HHMMSS.log   (only if the folder was deleted)
```

A copy of the script is also stored inside the `.tar`.

### 2. Copy to the new laptop

Copy **two files** to the same folder on the new laptop (USB disk, network, `rsync`, LocalSend ...):

```
fedora-migrate.sh
fedora_backup_YYYYMMDD_HHMMSS.tar
```

> Free space needed on the new laptop: about **2x the .tar size** (the archive + its extracted copy),
> plus the size of the installed apps. You can delete the `.tar` after a successful restore.

### 3. On the new laptop - restore

Install Fedora, create your user, log in to **GNOME** (not over SSH / a TTY), connect to the internet, then:

```bash
cd /path/where/you/copied/them
chmod +x fedora-migrate.sh
./fedora-migrate.sh restore
```

The newest `fedora_backup_*` folder or `.tar` in the current directory is found automatically.
You can also point to it explicitly:

```bash
./fedora-migrate.sh restore ~/fedora_backup_YYYYMMDD_HHMMSS.tar
```

Every step asks before changing anything. At the end **reboot** (needed for the NVIDIA driver,
group memberships, services and GNOME extensions).

---

## Requirements

|         |                                                                                                                                         |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| OS      | Fedora Workstation (written/tested on Fedora 44, dnf5). Restore onto the **same or newer** Fedora release.                              |
| User    | Run as your normal user, **not** with `sudo`; the script calls sudo itself.                                                             |
| Session | Restore must run inside a GNOME session so dconf/GNOME settings can be applied.                                                         |
| Network | Required on restore (packages, Flatpaks, COPR, RPM Fusion).                                                                             |
| Tools   | `bash`, `tar`, `zstd`, `dnf`, `flatpak`, `rpm` - all present on Fedora Workstation by default. `virsh`/`qemu-img` only if you have VMs. |

---

## What is backed up

| Area              | What                                                                                                                                                                                                                                                          | Where in backup                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| DNF packages      | Every user-installed package (`dnf repoquery --userinstalled`) with arch and source repo; full `rpm -qa`; installed groups; locally installed packages plus retrievable RPM payloads                                                                          | `packages/`                      |
| VS Code           | Extension list (`code --list-extensions`); restore adds the Microsoft repository and reinstalls `code` when needed                                                                                                                                            | `packages/vscode-extensions.txt` |
| Repositories      | All `/etc/yum.repos.d/*.repo`, which RPM owns each one, which repos were enabled, COPR list, GPG keys in `/etc/pki/rpm-gpg` not owned by any package                                                                                                          | `repos/`                         |
| Flatpak           | Remotes (name, URL, system/user), apps with origin + installation, runtimes, remote GPG keys, permission overrides (Flatseal etc.)                                                                                                                            | `flatpak/`                       |
| GNOME settings    | Full `dconf dump /` (wallpaper, keybindings, dock, extensions settings, app settings) and list of enabled extensions                                                                                                                                          | `gnome/`                         |
| Home configs      | All hidden files/folders in `~`: `.config`, `.local/share` (incl. `gnome-shell/extensions`, `icons`, `themes`, `fonts`, `keyrings`), `.var/app` (Flatpak app data), `.ssh`, `.gnupg`, `.bashrc`, `.gitconfig`, `.themes`, `.icons`, `.mozilla`, `.vscode` ... | `home.tar.zst`                   |
| System assets     | Icon/cursor/theme/font/background/extension folders under `/usr/share` and `/usr/local/share` that were copied in manually (not owned by any RPM), user avatar                                                                                                | `system/`                        |
| Services & groups | Enabled system and user systemd units; your supplementary groups (`libvirt`, `wheel`, ...)                                                                                                                                                                    | `system/`                        |
| Virtual machines  | libvirt (system + session): domain XML, disk images (snapshot chains are flattened), UEFI NVRAM, swtpm (TPM) state, networks and storage pools. Also `~/VirtualBox VMs`, `~/vmware`, GNOME Boxes (Flatpak) images                                             | `vms/`                           |

### Excluded automatically

- `~/.cache`, Trash, all `Cache`/`Code Cache`/`GPUCache`/`ShaderCache` folders, `.var/app/*/cache`
- npm / cargo / gradle / maven / pnpm download caches
- `~/.local/share/flatpak` (Flatpaks are reinstalled), `~/.local/share/containers`
- `~/.config/dconf` (settings are restored via `dconf load` instead)
- `~/.vscode/extensions` (reinstalled from the list)
- Steam shader cache, downloads, logs (and the games themselves unless you said yes)
- The backup destination folder itself

### Not included

- **Personal folders**: `Documents`, `Pictures`, `Music`, `Videos`, `Downloads`, `Desktop`, `Games`, etc.
  Copy them separately (e.g. with FreeFileSync).
- System configuration in `/etc` other than repositories (e.g. custom `fstab`, NetworkManager
  Wi-Fi/VPN connections, `/etc/hosts`). Re-create those by hand if you changed them.
- Docker/Podman containers and images.

---

## What is restored (in order)

| #   | Step                                                                                                                                                                                                               | Asks       | Notes                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Third-party repos**: RPM Fusion free + nonfree, `fedora-workstation-repositories` + `fedora-third-party enable`, Cisco openh264, Flathub (unfiltered)                                                            | **always** | Then optionally full multimedia codecs (`ffmpeg-free` -> `ffmpeg`, `@multimedia`).                                           |
| 2   | **Your extra repos**: COPRs via `dnf copr enable`, custom repo files (VS Code, AnyDesk, NordVPN, Master PDF ...), extra GPG keys, re-enables previously enabled repos (Chrome, PyCharm, Steam ...)                 | yes        | Existing repo files are never overwritten. VS Code also has a direct fallback during its restore step.                       |
| 3   | **System update** `dnf upgrade --refresh`                                                                                                                                                                          | yes        | Recommended before the NVIDIA driver.                                                                                        |
| 4   | **NVIDIA driver** (only if an NVIDIA GPU is detected): `akmod-nvidia`, `xorg-x11-drv-nvidia-cuda` + all NVIDIA packages you had (32-bit libs, power, settings), enables suspend/resume services, builds the module | **always** | If Secure Boot is on, creates a signing key and asks for a one-time MOK password - enrol it in the blue screen at next boot. |
| 5   | **DNF packages**: archived local RPMs first, then bulk install with `--skip-unavailable --skip-broken`                                                                                                             | yes        | Kernels, kmods and release packages are skipped. Anything that failed is written to `~/fedora-restore-missing-packages.txt`. |
| 6   | **Flatpaks**: remotes, apps from their original remote (falls back to Flathub), overrides                                                                                                                          | yes        |                                                                                                                              |
| 7   | **VS Code extensions**                                                                                                                                                                                             | yes        | Only if `code` got installed.                                                                                                |
| 8   | **Home configs** from `home.tar.zst`                                                                                                                                                                               | yes        | Your current configs are first saved to `~/pre-restore-configs-*.tar.gz`. SELinux labels fixed, font cache rebuilt.          |
| 9   | **System assets** (custom icons/themes in `/usr/share`) and user avatar                                                                                                                                            | yes        | Existing files are not overwritten.                                                                                          |
| 10  | **GNOME settings**: `dconf load /` (falls back to key-by-key)                                                                                                                                                      | yes        | Paths with the old home dir are rewritten if your username changed. Lists extensions that are enabled but missing.           |
| 11  | **Services & groups**: re-enable units that exist on the new system; add you back to groups                                                                                                                        | yes        |                                                                                                                              |
| 12  | **Virtual machines**: installs the `virtualization` group if needed, restores networks, pools, disks to their original paths, NVRAM/TPM, `virsh define`                                                            | yes        | Existing VMs/files are never overwritten.                                                                                    |
| 13  | **Reboot**                                                                                                                                                                                                         | yes        |                                                                                                                              |

Logs: `~/fedora-restore-YYYYMMDD_HHMMSS.log`. A summary of all warnings is printed at the end.

---

## Backup layout

```
fedora_backup_YYYYMMDD_HHMMSS/
├── backup.log
├── fedora-migrate.sh            copy of the script used
├── home.tar.zst                 hidden files/folders of your home
├── meta/       info.env (user, home, Fedora/GNOME version), gpu.txt, home-members.txt
├── packages/   userinstalled.tsv, rpm-all.txt, groups.txt, local-rpms.txt, local-rpms/, vscode-extensions.txt
├── repos/      yum.repos.d/, rpm-gpg/, owners.tsv, enabled.txt, copr.txt
├── flatpak/    remotes.tsv, apps.tsv, runtimes.tsv, keys/, *-overrides/
├── gnome/      dconf.ini, enabled-extensions.txt, user-extensions.txt, system-extensions.txt
├── system/     enabled-units.txt, enabled-user-units.txt, groups.txt, system-assets.tar.zst, avatar
└── vms/
    ├── system/<VM name>/   domain.xml, disk0_*.qcow2, nvram0_*, tpm0_*, files.tsv
    ├── system/networks/, system/pools/
    ├── session/<VM name>/
    └── folders/, folders.tsv   (VirtualBox / VMware / Boxes)
```

All lists are plain text - you can inspect or edit them (e.g. remove packages from
`packages/userinstalled.tsv`) before restoring.

> **Privacy:** the backup can contain SSH/GPG keys, browser profiles and saved passwords.
> The backup folder is created with `chmod 700`; keep the `.tar` on trusted storage.

---

## Options

```
./fedora-migrate.sh                       interactive menu
./fedora-migrate.sh backup  [DEST_DIR]
./fedora-migrate.sh restore [BACKUP]      folder or .tar
./fedora-migrate.sh -y backup             accept all defaults (unattended)
./fedora-migrate.sh -y restore            accept defaults, but STILL asks about
                                          third-party repos and the NVIDIA driver
./fedora-migrate.sh --help
```

---

## Testing on the new laptop - checklist

After the restore and a reboot:

- [ ] `cat ~/fedora-restore-*.log | grep -A50 Warnings` - review warnings
- [ ] `cat ~/fedora-restore-missing-packages.txt` - packages that could not be installed (if file exists)
- [ ] `dnf repo list` - VS Code, Chrome, AnyDesk, NordVPN, COPRs, RPM Fusion present
- [ ] `flatpak list --app` - all apps present
- [ ] NVIDIA: `nvidia-smi` works, `lsmod | grep nvidia` shows the module
- [ ] GNOME: wallpaper, dock, keybindings, extensions active (`gnome-extensions list --enabled`), icon/cursor theme
- [ ] Fonts: `fc-list | wc -l` similar to old system
- [ ] Apps: VS Code (settings + extensions), Firefox profile, Steam login, Bottles, terminal/bash (`ble.sh`)
- [ ] VMs: `virsh -c qemu:///system list --all` shows `Win10`; start it in virt-manager
- [ ] Groups: `id` shows `libvirt`, `nordvpn`, ...

---

## Troubleshooting

| Problem                               | Fix                                                                                                                                                                          |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "No graphical session detected"       | You ran restore via SSH/TTY. Log in to GNOME and run `./fedora-migrate.sh restore` again - every step can be answered `n` except the ones you still need.                    |
| Extensions not active after restore   | Log out / in. If GNOME was upgraded, update them in **Extension Manager**. Missing ones are listed in the log.                                                               |
| Black screen / no NVIDIA after reboot | Wait 5 min after first boot (akmods may still be building), then reboot again. Check `sudo journalctl -b -u akmods`. With Secure Boot: make sure you enrolled the MOK key.   |
| A package failed                      | See `~/fedora-restore-missing-packages.txt`; usually renamed/removed in the newer Fedora, or came from a local `.rpm` (`anydesk`, `msttcore-fonts-installer`, `openssl1.1`). |
| VM does not start                     | Check the disk path in virt-manager; if the `default` network is missing: `sudo virsh net-start default`.                                                                    |
| Want to undo configs                  | Your previous configs are in `~/pre-restore-configs-*.tar.gz`: `tar -C ~ -xzf ~/pre-restore-configs-*.tar.gz`.                                                               |
| Re-run only one part                  | Run `restore` again and answer `n` to the other steps - all steps are safe to repeat.                                                                                        |
| Old backups from `backup.sh`          | Not compatible (`fedora_backup_*.tar.gz` without `meta/info.env`); use `restore.sh` for those.                                                                               |

---

## Limitations

- Restoring onto an **older** Fedora release than the backup is not supported (packages may be missing).
- A downloaded RPM is archived when its exact installed version, or a current replacement, is available from a configured repository during backup. Keep an original RPM file separately when it is unavailable.
- libvirt snapshot metadata is not migrated (disks are flattened, so the current state is kept).
- Apps that store absolute paths (e.g. Bottles, Steam libraries on other drives) may need paths fixed if your username or disk layout changed.
- Hardware-specific settings (monitors layout, Wi-Fi) are restored only as far as GNOME stores them in dconf.
