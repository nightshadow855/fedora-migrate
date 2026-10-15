#!/usr/bin/env bash
# fedora-migrate.sh - back up a Fedora Workstation (packages, repos, Flatpaks, GNOME,
# configs, virtual machines) and restore it onto a fresh install, without cloning the drive.
#
# Usage:
#   ./fedora-migrate.sh                         interactive menu
#   ./fedora-migrate.sh backup  [DEST_DIR]      default DEST_DIR: ~/Documents/LINUX/BACKUP-RESTORE
#   ./fedora-migrate.sh restore [BACKUP]        BACKUP = fedora_backup_* folder or a .tar/.tar.zst/.tar.gz of it
#                                               (default: newest backup found in ., script dir or DEST_DIR)
# Options:
#   -y, --yes   accept the default answer for every question, EXCEPT third-party repos and
#               NVIDIA drivers, which are always asked.
#   Logs: backup.log and dnf.log are saved in each backup; restore logs are saved in $HOME.
#   -h, --help  show this help
#
# Run as your normal user inside your GNOME session (not with sudo); sudo is called when needed.
# Personal folders (Documents, Pictures, Music, ...) are NOT included - copy those separately.

set -o pipefail
shopt -s nullglob

readonly DEFAULT_DEST="$HOME/Documents/LINUX/BACKUP-RESTORE"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly LARGE_MB=1024                      # folders bigger than this are confirmed individually
readonly ZSTD='zstd -T0 -3'
ASSUME_YES=0
WARNINGS=()
SUDO_PID=
BK=
RUN_LOG=
DNF_LOG=

if [[ -t 1 ]]; then
    BOLD=$'\e[1m' RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' CYN=$'\e[36m' RST=$'\e[0m'
else
    BOLD='' RED='' GRN='' YEL='' CYN='' RST=''
fi

# ----------------------------------------------------------------------------- helpers
section() { printf '\n%s==> %s%s\n' "$BOLD$CYN" "$*" "$RST"; }
info()    { printf '  [*] %s\n' "$*"; }
ok()      { printf '  %s[ok]%s %s\n' "$GRN" "$RST" "$*"; }
warn()    { printf '  %s[!]%s %s\n' "$YEL" "$RST" "$*"; WARNINGS+=("$*"); }
die()     { printf '%s[x] %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
have()    { command -v "$1" &>/dev/null; }

dnf_run() {
    local description=$1 command
    shift
    printf -v command '%q ' sudo dnf "$@"
    info "$description"
    info "Running: ${command% }"
    sudo dnf "$@" 2>&1 | tee -a "$DNF_LOG"
}

dnf_capture_stderr() {
    # Keep structured stdout clean while preserving DNF diagnostics in both logs.
    tee -a "$DNF_LOG" >&2
}

_prompt() {
    local q=$1 def=$2 ans hint='y/N'
    [[ $def == Y ]] && hint='Y/n'
    while true; do
        read -r -p "  ${BOLD}?${RST} $q [$hint] " ans </dev/tty || ans=$def
        ans=${ans:-$def}
        case $ans in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
    done
}
# ask "question" [Y|N]  - honours --yes
ask() {
    local def=${2:-N}
    if ((ASSUME_YES)); then info "$1 -> $def (auto)"; [[ $def == Y ]]; return; fi
    _prompt "$1" "$def"
}
# ask_always "question" [Y|N] - always interactive (third-party repos, NVIDIA)
ask_always() { _prompt "$1" "${2:-N}"; }

start_sudo() {
    info "Administrator (sudo) rights are needed for some steps."
    sudo -v || die "sudo authentication failed"
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_PID=$!
    trap '[[ -n $SUDO_PID ]] && kill "$SUDO_PID" 2>/dev/null' EXIT
}

preflight() {
    [[ $EUID -ne 0 ]] || die "Run this as your normal user, not as root/sudo."
    [[ -r /etc/fedora-release ]] || die "This script is meant for Fedora."
    have dnf || die "dnf not found."
}

meta_get() { sed -n "s/^$1=//p" "$BK/meta/info.env" 2>/dev/null | head -n1; }

# Packages that must not be reinstalled blindly (kernel-specific, or handled by the NVIDIA / third-party steps)
readonly PKG_SKIP_RE='^(kernel($|[.-])|kmod-|akmod-|gpg-pubkey|rpmfusion-(free|nonfree)-release)'

# ============================================================================= BACKUP
backup_meta() {
    section "System information"
    {
        echo "user=$USER"
        echo "home=$HOME"
        echo "hostname=$(hostname)"
        echo "fedora=$(rpm -E %fedora)"
        echo "arch=$(uname -m)"
        echo "kernel=$(uname -r)"
        echo "gnome=$(gnome-shell --version 2>/dev/null)"
        echo "date=$(date -Is)"
    } >"$BK/meta/info.env"
    lspci 2>/dev/null | grep -Ei 'vga|3d|display' >"$BK/meta/gpu.txt"
    cat /etc/fedora-release
    ok "Saved system info"
}

backup_packages() {
    section "DNF packages"
    info "Querying user-installed packages; DNF may refresh repository metadata. Details: $DNF_LOG"
    if ! dnf repoquery --userinstalled --qf $'%{name}\t%{arch}\t%{from_repo}\n' \
        2> >(dnf_capture_stderr) | sort -u >"$BK/packages/userinstalled.tsv"; then
        warn "Could not query all user-installed DNF packages - see $DNF_LOG"
    fi
    rpm -qa --qf '%{NAME}.%{ARCH}\n' | sort -u >"$BK/packages/rpm-all.txt"
    dnf group list --installed >"$BK/packages/groups.txt" 2> >(dnf_capture_stderr) ||
        warn "Could not list installed DNF groups - see $DNF_LOG"
    awk -F'\t' '$3=="@commandline" || $3=="<unknown>" {print $1}' "$BK/packages/userinstalled.tsv" \
        | grep -Ev "$PKG_SKIP_RE" >"$BK/packages/local-rpms.txt"
    mkdir -p "$BK/packages/local-rpms"
    local pkg nevra
    while IFS= read -r pkg; do
        [[ -n $pkg ]] || continue
        nevra=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$pkg" 2>/dev/null)
        info "Saving local RPM for $nevra"
        if ! dnf download --destdir "$BK/packages/local-rpms" "$nevra" >>"$DNF_LOG" 2>&1; then
            info "Exact version unavailable; saving the current repository RPM for $pkg"
            dnf download --destdir "$BK/packages/local-rpms" "$pkg" >>"$DNF_LOG" 2>&1 ||
                warn "Could not download an RPM for $pkg; keep its original .rpm file"
        fi
    done <"$BK/packages/local-rpms.txt"
    ok "$(wc -l <"$BK/packages/userinstalled.tsv") user-installed packages"
    if [[ -s $BK/packages/local-rpms.txt ]]; then
        info "Installed from local .rpm files: $(paste -sd' ' "$BK/packages/local-rpms.txt")"
    fi
    if have code; then
        code --list-extensions >"$BK/packages/vscode-extensions.txt" 2>/dev/null &&
            ok "$(wc -l <"$BK/packages/vscode-extensions.txt") VS Code extensions"
    fi
}

backup_repos() {
    section "Repositories"
    local f name owner
    : >"$BK/repos/owners.tsv"
    for f in /etc/yum.repos.d/*.repo; do
        name=$(basename "$f")
        sudo cat "$f" >"$BK/repos/yum.repos.d/$name"
        owner=$(rpm -qf --qf '%{NAME}\n' "$f" 2>/dev/null | head -n1) || owner='-'
        printf '%s\t%s\n' "$name" "${owner:--}" >>"$BK/repos/owners.tsv"
    done
    dnf repo list --enabled 2> >(dnf_capture_stderr) | awk 'NR>1 {print $1}' >"$BK/repos/enabled.txt"
    dnf copr list 2> >(dnf_capture_stderr) >"$BK/repos/copr.txt"
    for f in /etc/pki/rpm-gpg/*; do
        [[ -f $f ]] && ! rpm -qf "$f" &>/dev/null && cp -L "$f" "$BK/repos/rpm-gpg/"
    done
    ok "$(wc -l <"$BK/repos/owners.tsv") repo files, $(grep -c . "$BK/repos/copr.txt") COPR repos, $(wc -l <"$BK/repos/enabled.txt") enabled repos"
}

backup_flatpak() {
    section "Flatpak"
    have flatpak || { info "Flatpak not installed - skipping"; return; }
    local name dir
    flatpak remotes --columns=name,url,options >"$BK/flatpak/remotes.tsv"
    flatpak list --app --columns=application,origin,installation,branch >"$BK/flatpak/apps.tsv"
    flatpak list --runtime --columns=application,origin,installation,branch >"$BK/flatpak/runtimes.tsv"
    mkdir -p "$BK/flatpak/keys"
    while IFS=$'\t' read -r name _ _; do
        for dir in /var/lib/flatpak/repo "$HOME/.local/share/flatpak/repo"; do
            [[ -f $dir/$name.trustedkeys.gpg ]] && cp "$dir/$name.trustedkeys.gpg" "$BK/flatpak/keys/" 2>/dev/null
        done
    done <"$BK/flatpak/remotes.tsv"
    [[ -d $HOME/.local/share/flatpak/overrides ]] && cp -r "$HOME/.local/share/flatpak/overrides" "$BK/flatpak/user-overrides"
    if [[ -d /var/lib/flatpak/overrides ]]; then
        sudo cp -r /var/lib/flatpak/overrides "$BK/flatpak/system-overrides" && sudo chown -R "$USER:" "$BK/flatpak/system-overrides"
    fi
    ok "$(wc -l <"$BK/flatpak/apps.tsv") Flatpak apps, $(wc -l <"$BK/flatpak/remotes.tsv") remotes"
}

backup_gnome() {
    section "GNOME settings and extensions"
    have dconf || { warn "dconf not found - GNOME settings not saved"; return; }
    dconf dump / >"$BK/gnome/dconf.ini" && ok "dconf settings dumped ($(grep -c '^\[' "$BK/gnome/dconf.ini") sections)"
    gsettings get org.gnome.shell enabled-extensions >"$BK/gnome/enabled-extensions.txt" 2>/dev/null
    if have gnome-extensions; then
        gnome-extensions list --user >"$BK/gnome/user-extensions.txt" 2>/dev/null
        gnome-extensions list --system >"$BK/gnome/system-extensions.txt" 2>/dev/null
        ok "$(grep -c . "$BK/gnome/user-extensions.txt") user extensions (files are saved with the home configs)"
    fi
    info "Icons, cursors, themes, fonts and extensions in your home are included in the home configs archive."
}

# True if PATH has content and neither it nor a sample of its files belongs to an RPM
is_unpackaged() {
    local d=$1 f n=0
    rpm -qf "$d" &>/dev/null && return 1
    while IFS= read -r f; do
        ((n++))
        rpm -qf "$f" &>/dev/null && return 1
    done < <(find "$d" \( -type f -o -type l \) ! -name 'icon-theme.cache' ! -name 'fonts.*' ! -name '.uuid' 2>/dev/null | head -n 5)
    ((n > 0))
}

backup_system() {
    section "Services, groups and system-wide assets"
    systemctl list-unit-files --state=enabled --no-legend --type=service,socket,timer,path 2>/dev/null \
        | awk '{print $1}' >"$BK/system/enabled-units.txt"
    systemctl --user list-unit-files --state=enabled --no-legend --type=service,socket,timer,path 2>/dev/null \
        | awk '{print $1}' >"$BK/system/enabled-user-units.txt"
    id -nG | tr ' ' '\n' | grep -vx "$USER" >"$BK/system/groups.txt"
    ok "$(wc -l <"$BK/system/enabled-units.txt") enabled system units, groups: $(paste -sd' ' "$BK/system/groups.txt")"

    # Icon/cursor/theme/font/extension folders that were copied in by hand (not owned by any RPM)
    local d items=()
    for d in /usr/share/icons/* /usr/share/themes/* /usr/share/fonts/* /usr/share/backgrounds/* /usr/share/gnome-shell/extensions/*; do
        [[ -e $d ]] && is_unpackaged "$d" && items+=("${d#/}")
    done
    for d in /usr/local/share/icons /usr/local/share/themes /usr/local/share/fonts; do
        [[ -d $d && -n $(ls -A "$d" 2>/dev/null) ]] && items+=("${d#/}")
    done
    if ((${#items[@]})); then
        printf '%s\n' "${items[@]}" >"$BK/system/system-assets.txt"
        sudo tar -C / -I "$ZSTD" -cpf "$BK/system/system-assets.tar.zst" "${items[@]}" &&
            sudo chown "$USER:" "$BK/system/system-assets.tar.zst" &&
            ok "System-wide custom assets: ${items[*]}"
    else
        info "No manually installed system-wide icons/themes/fonts found"
    fi

    if sudo test -f "/var/lib/AccountsService/icons/$USER"; then
        sudo cat "/var/lib/AccountsService/icons/$USER" >"$BK/system/avatar" && ok "User avatar saved"
    fi
}

backup_home() {
    section "Home configs, dotfiles, app data, icons/themes/fonts, GNOME extensions"
    cd "$HOME" || die "cannot cd to $HOME"
    local e
    local skip_re='^\.(cache|Xauthority|ICEauthority|xsession-errors.*|dbus|gvfs|Trash.*|esd_auth)$'
    local -a members=() anchored=() du_ex=()
    for e in .[!.]* ..?*; do
        [[ $e =~ $skip_re ]] || members+=("$e")
    done

    # Unanchored excludes: caches and data that are reinstalled/handled elsewhere
    local -a ex=(
        --exclude='.local/share/Trash' --exclude='.local/share/flatpak' --exclude='.local/share/containers'
        --exclude='.local/share/libvirt/images' --exclude='.local/share/gnome-boxes/images'
        --exclude='.var/app/org.gnome.Boxes/data/gnome-boxes/images' --exclude='.var/app/*/cache'
        --exclude='.config/dconf' --exclude='.vscode/extensions'
        --exclude='.npm/_cacache' --exclude='.npm/_npx' --exclude='.cargo/registry' --exclude='.gradle/caches'
        --exclude='.m2/repository' --exclude='.local/share/pnpm/store'
        --exclude='Cache' --exclude='Code Cache' --exclude='GPUCache' --exclude='CachedData'
        --exclude='CachedExtensionVSIXs' --exclude='ShaderCache' --exclude='GrShaderCache'
        --exclude='DawnCache' --exclude='DawnGraphiteCache' --exclude='GraphiteDawnCache'
        --exclude='Service Worker/CacheStorage'
        --exclude='.local/share/Steam/steamapps/shadercache' --exclude='.local/share/Steam/steamapps/downloading'
        --exclude='.local/share/Steam/steamapps/temp' --exclude='.local/share/Steam/appcache' --exclude='.local/share/Steam/logs'
    )
    du_ex=(--exclude=Cache --exclude='Code Cache' --exclude=CachedData --exclude=GPUCache --exclude=cache
           --exclude=flatpak --exclude=containers --exclude=images --exclude=Trash --exclude=shadercache
           --exclude=_cacache --exclude=_npx --exclude=registry --exclude=caches --exclude=repository)

    # Never include the backup destination itself
    if [[ $DEST == "$HOME"/* ]]; then anchored+=(--exclude="${DEST#"$HOME"/}"); fi

    if [[ -d .ssh || -d .gnupg || -d .local/share/keyrings ]] &&
        ! ask "Include SSH keys, GPG keys and the GNOME keyring (saved passwords)? Keep the backup private if yes." Y; then
        anchored+=(--exclude=.ssh --exclude=.gnupg --exclude=.local/share/keyrings)
    fi

    # Steam game files are huge and can be re-downloaded; saves/Proton prefixes (compatdata) are kept
    if [[ -d .local/share/Steam/steamapps/common ]]; then
        local steam_mb
        steam_mb=$(du -sm .local/share/Steam/steamapps/common 2>/dev/null | cut -f1)
        if ! ask "Include installed Steam games (~$(human $((steam_mb * 1048576)))) - they can be re-downloaded?" N; then
            anchored+=(--exclude=.local/share/Steam/steamapps/common)
        fi
    fi

    info "Scanning for large folders (> $(human $((LARGE_MB * 1048576))))..."
    local size path
    while IFS=$'\t' read -r size path; do
        path=${path#./}
        [[ $path == .local/share/Steam ]] && continue
        [[ $path == .cache* || $path == .local/share/flatpak || $path == .local/share/containers ]] && continue
        if [[ $DEST == "$HOME/$path"* ]]; then continue; fi
        ask "Include large folder ~/$path (~$(human $((size * 1048576))))?" Y || anchored+=(--exclude="$path")
    done < <(
        {
            du -sm "${du_ex[@]}" .config/* .local/share/* .var/app/* 2>/dev/null
            for e in "${members[@]}"; do
                [[ -d $e && ! -L $e && $e != .config && $e != .local && $e != .var ]] && du -sm "${du_ex[@]}" "$e" 2>/dev/null
            done
        } | awk -F'\t' -v m="$LARGE_MB" '$1 >= m'
    )

    printf '%s\n' "${members[@]}" >"$BK/meta/home-members.txt"
    info "Creating home.tar.zst (this can take a while)..."
    tar -C "$HOME" -I "$ZSTD" -cpf "$BK/home.tar.zst" \
        --warning=no-file-changed --warning=no-file-ignored --warning=no-file-removed --ignore-failed-read \
        --anchored "${anchored[@]}" --no-anchored "${ex[@]}" "${members[@]}"
    local rc=$?
    if ((rc == 0)); then
        ok "home.tar.zst: $(human "$(stat -c %s "$BK/home.tar.zst")")"
    elif ((rc == 1)); then
        warn "Some files changed while being archived (apps still running?) - archive created anyway"
    else
        warn "tar reported errors (exit $rc) while archiving home configs - check the log"
    fi
}

# Copy one VM file/dir into the backup; records "kind<TAB>stored<TAB>original" in files.tsv
vm_store() {
    local scope=$1 kind=$2 src=$3 dir=$4 idx=$5 S='' fmt stored
    [[ $scope == system ]] && S=sudo
    stored="${kind}${idx}_$(basename "$src")"
    if [[ $kind == disk ]]; then
        if $S qemu-img info -U "$src" 2>/dev/null | grep -q '^backing file:'; then
            fmt=$($S qemu-img info -U "$src" | awk -F': ' '/^file format/ {print $2}')
            info "  flattening snapshot chain of $(basename "$src") ($fmt)"
            $S qemu-img convert -p -O "$fmt" "$src" "$dir/$stored" || return 1
        else
            $S cp --sparse=always "$src" "$dir/$stored" || return 1
        fi
    else
        $S cp -a "$src" "$dir/$stored" || return 1
    fi
    printf '%s\t%s\t%s\n' "$kind" "$stored" "$src" >>"$dir/files.tsv"
}

backup_vms() {
    section "Virtual machines"
    local found=0 uri scope dom state S dir xml i n src total avail uuid p
    if have virsh; then
        for uri in qemu:///system qemu:///session; do
            scope=${uri##*/}; S=''; [[ $scope == system ]] && S=sudo
            if [[ $scope == system ]]; then
                mkdir -p "$BK/vms/system/networks" "$BK/vms/system/pools"
                for n in $(sudo virsh -c "$uri" net-list --all --name 2>/dev/null); do
                    sudo virsh -c "$uri" net-dumpxml "$n" >"$BK/vms/system/networks/$n.xml"
                done
                for n in $(sudo virsh -c "$uri" pool-list --all --name 2>/dev/null); do
                    sudo virsh -c "$uri" pool-dumpxml "$n" >"$BK/vms/system/pools/$n.xml"
                done
            fi
            while IFS= read -r dom <&3; do
                [[ -z $dom ]] && continue
                found=1
                mapfile -t disks < <($S virsh -c "$uri" domblklist "$dom" --details 2>/dev/null |
                    awk '$1=="file" && $2=="disk" { $1=$2=$3=""; sub(/^ +/, ""); print }')
                total=0
                for src in "${disks[@]}"; do total=$((total + $($S du -sb "$src" 2>/dev/null | cut -f1))); done
                ask "Back up VM '$dom' ($scope, ${#disks[@]} disk(s), $(human "$total"))?" Y || continue

                avail=$(df --output=avail -B1 "$BK" | tail -n1)
                if ((total > avail)); then warn "Not enough space for VM '$dom' ($(human "$total") needed) - skipped"; continue; fi

                state=$($S virsh -c "$uri" domstate "$dom" 2>/dev/null)
                if [[ $state != "shut off" ]]; then
                    if ask "VM '$dom' is '$state'. Shut it down for a consistent copy?" Y; then
                        $S virsh -c "$uri" shutdown "$dom" >/dev/null
                        for ((i = 0; i < 120; i += 5)); do
                            [[ $($S virsh -c "$uri" domstate "$dom") == "shut off" ]] && break
                            sleep 5
                        done
                        [[ $($S virsh -c "$uri" domstate "$dom") == "shut off" ]] ||
                            { warn "VM '$dom' did not shut down - skipped"; continue; }
                    else
                        warn "VM '$dom' is running - skipped"; continue
                    fi
                fi
                if [[ -n $($S virsh -c "$uri" snapshot-list "$dom" --name 2>/dev/null | grep .) ]]; then
                    info "  note: libvirt snapshot metadata of '$dom' is not migrated"
                fi

                dir="$BK/vms/$scope/$dom"; mkdir -p "$dir"; : >"$dir/files.tsv"
                xml="$dir/domain.xml"
                $S virsh -c "$uri" dumpxml --security-info "$dom" >"$xml"
                info "Copying VM '$dom' ($(human "$total"))..."
                i=0
                for src in "${disks[@]}"; do
                    vm_store "$scope" disk "$src" "$dir" "$i" || warn "Failed to copy disk $src of '$dom'"
                    ((i++))
                done
                # UEFI vars
                while IFS= read -r p; do
                    [[ -n $p ]] && $S test -e "$p" && vm_store "$scope" nvram "$p" "$dir" 0
                done < <(grep -oP '<nvram[^>]*>\K[^<]+' "$xml")
                # Software TPM state
                if grep -q '<tpm' "$xml"; then
                    uuid=$(grep -oP '<uuid>\K[^<]+' "$xml")
                    while IFS= read -r p; do vm_store "$scope" tpm "$p" "$dir" 0; done < <(
                        $S find /var/lib/libvirt/swtpm "$HOME/.config/libvirt" "$HOME/.local/share/libvirt" \
                            -maxdepth 3 -type d -name "$uuid" 2>/dev/null)
                fi
                [[ -n $S ]] && sudo chown -R "$USER:" "$dir"
                ok "VM '$dom' saved"
            done 3< <($S virsh -c "$uri" list --all --name 2>/dev/null)
        done
    fi

    # Folder-based VMs (VirtualBox, VMware, GNOME Boxes Flatpak)
    local folder size j=0
    for folder in "$HOME/VirtualBox VMs" "$HOME/vmware" "$HOME/.var/app/org.gnome.Boxes/data/gnome-boxes/images"; do
        [[ -d $folder && -n $(ls -A "$folder" 2>/dev/null) ]] || continue
        found=1
        size=$(du -sb "$folder" | cut -f1)
        ask "Back up VM folder '$folder' ($(human "$size"))?" Y || continue
        mkdir -p "$BK/vms/folders/$j"
        cp -a --sparse=always "$folder/." "$BK/vms/folders/$j/" &&
            printf '%s\t%s\n' "$j" "$folder" >>"$BK/vms/folders.tsv" && ok "Saved $folder"
        ((j++))
    done
    ((found)) || info "No virtual machines found"
}

do_backup() {
    preflight
    DEST=${1:-$DEFAULT_DEST}
    mkdir -p "$DEST" || die "Cannot create $DEST"
    DEST=$(cd "$DEST" && pwd)
    BK="$DEST/fedora_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BK"/{meta,packages,repos/yum.repos.d,repos/rpm-gpg,flatpak,gnome,system,vms}
    chmod 700 "$BK"
    RUN_LOG="$BK/backup.log"
    DNF_LOG="$BK/dnf.log"
    exec > >(tee -a "$BK/backup.log") 2>&1

    section "Fedora backup -> $BK"
    info "Logs: $RUN_LOG (full session), $DNF_LOG (DNF activity)"
    info "Tip: close browsers, IDEs, Steam and running VMs first so their data is copied consistently."
    start_sudo
    backup_meta
    backup_packages
    backup_repos
    backup_flatpak
    backup_gnome
    backup_system
    backup_home
    backup_vms

    local result=$BK
    section "Packing"
    if ask "Pack the backup into a single .tar file for easy copying?" Y; then
        cp "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$BK/fedora-migrate.sh" 2>/dev/null
        info "Creating $BK.tar (contents are already compressed)..."
        if tar -C "$DEST" -cf "$BK.tar" "$(basename "$BK")"; then
            result="$BK.tar"
            ok "Created $result ($(du -h "$result" | cut -f1))"
            if ask "Delete the unpacked folder $BK to free space (the .tar has everything)?" Y; then
                cp "$BK/backup.log" "$BK.log" 2>/dev/null
                cp "$BK/dnf.log" "$BK.dnf.log" 2>/dev/null
                rm -rf "$BK"
                RUN_LOG="$BK.log"
                DNF_LOG="$BK.dnf.log"
                exec > >(tee -a "$RUN_LOG") 2>&1
            fi
        else
            warn "Packing failed - use the folder $BK instead"
            rm -f "$BK.tar"
        fi
    fi

    section "Backup finished"
    ok "Backup: $result"
    info "Copy it together with fedora-migrate.sh to the new system and run:"
    info "  ./fedora-migrate.sh restore $(basename "$result")"
    info "Personal folders (Documents, Pictures, ...) are not included - copy them separately."
    print_warnings
}

# ============================================================================= RESTORE
find_latest_backup() {
    # Searches the current dir, then the script dir, then the default backup dir; first hit wins
    local d loc latest=''
    for loc in "$PWD" "$SCRIPT_DIR" "$DEFAULT_DEST"; do
        for d in "$loc"/fedora_backup_*; do
            [[ -f $d/meta/info.env || ($d == *.tar && -f $d) ]] || continue
            # Prefer an already extracted folder over its archive
            [[ -f $d && -f ${d%.tar}/meta/info.env ]] && continue
            [[ -z $latest || $(basename "$d") > $(basename "$latest") ]] && latest=$d
        done
        [[ -n $latest ]] && break
    done
    printf '%s' "$latest"
}

restore_third_party() {
    section "Third-party repositories (RPM Fusion, Fedora third-party, Flathub)"
    if ! ask_always "Enable third-party repositories (RPM Fusion free + nonfree, Fedora third-party repos, Flathub)?" Y; then
        info "Skipped - packages from RPM Fusion / Chrome / Steam etc. will not be installable."
        return
    fi
    local fv; fv=$(rpm -E %fedora)
    dnf_run "Installing Fedora repository tools..." install -y fedora-workstation-repositories dnf5-plugins
    have fedora-third-party && sudo fedora-third-party enable
    dnf_run "Installing RPM Fusion repository definitions..." install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$fv.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$fv.noarch.rpm" ||
        warn "Could not install RPM Fusion release packages"
    dnf_run "Enabling the Cisco OpenH264 repository..." config-manager setopt fedora-cisco-openh264.enabled=1
    # Re-enable RPM Fusion side repos (nvidia-driver, steam) that were enabled before
    local id
    while IFS= read -r id; do
        [[ $id == rpmfusion-* ]] &&
            dnf_run "Enabling repository $id..." config-manager setopt "$id.enabled=1"
    done <"$BK/repos/enabled.txt"
    if have flatpak; then
        sudo flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        sudo flatpak remote-modify --system --no-filter --enable flathub
    fi
    ok "Third-party repositories enabled"

    if ask "Install full multimedia codecs (swap ffmpeg-free -> ffmpeg, multimedia group)?" Y; then
        dnf_run "Installing multimedia codecs..." swap -y ffmpeg-free ffmpeg --allowerasing || warn "ffmpeg swap failed"
        dnf_run "Updating the multimedia package group..." update -y @multimedia --setopt=install_weak_deps=False --exclude=PackageKit-gstreamer-plugin ||
            warn "multimedia group update failed"
    fi
}

restore_repos() {
    section "Additional repositories (VS Code, Chrome, AnyDesk, COPR, ...)"
    [[ -f $BK/repos/owners.tsv ]] || return
    ask "Restore your additional repositories?" Y || return
    local f owner line spec hub proj
    local -a owner_pkgs=()

    for f in "$BK"/repos/rpm-gpg/*; do sudo cp -n "$f" /etc/pki/rpm-gpg/; done

    dnf copr --help &>/dev/null || dnf_run "Installing DNF COPR support..." install -y dnf5-plugins
    while IFS=$'\t' read -r f owner <&3; do
        [[ $f == fedora*.repo || $f == rpmfusion-* ]] && continue
        if [[ $owner != - ]]; then
            [[ $owner == fedora-repos* || $owner == rpmfusion-* ]] || owner_pkgs+=("$owner")
            continue
        fi
        if [[ $f == _copr:* ]]; then
            # _copr:HUB:OWNER:PROJECT.repo  (group owners are stored as "group_NAME")
            spec=${f#_copr:}; spec=${spec%.repo}
            hub=${spec%%:*}; spec=${spec#*:}
            proj="${spec%%:*}/${spec#*:}"; proj=${proj/#group_/@}
            if dnf_run "Enabling COPR $proj..." -y copr enable "$hub/$proj" </dev/null; then ok "COPR $proj"; continue; fi
            warn "dnf copr enable $proj failed - copying the repo file instead"
        fi
        if [[ -e /etc/yum.repos.d/$f ]]; then
            info "$f already present - kept"
        else
            sudo install -m 644 "$BK/repos/yum.repos.d/$f" "/etc/yum.repos.d/$f" && ok "Restored $f"
        fi
    done 3<"$BK/repos/owners.tsv"

    if ((${#owner_pkgs[@]})); then
        mapfile -t owner_pkgs < <(printf '%s\n' "${owner_pkgs[@]}" | sort -u)
        dnf_run "Installing packages that provide restored repository files..." install -y --skip-unavailable "${owner_pkgs[@]}"
    fi

    # Re-enable repos that were enabled before (e.g. google-chrome, PyCharm from fedora-workstation-repositories)
    local id
    mapfile -t disabled < <(dnf repo list --disabled 2>/dev/null | awk 'NR>1 {print $1}')
    while IFS= read -r id; do
        [[ $id == rpmfusion-* ]] && continue
        if printf '%s\n' "${disabled[@]}" | grep -qxF -- "$id"; then
            dnf_run "Enabling repository $id..." config-manager setopt "$id.enabled=1" && ok "Enabled repo $id"
        fi
    done <"$BK/repos/enabled.txt"
    dnf_run "Refreshing DNF metadata..." makecache -y
}

restore_update() {
    section "System update"
    ask "Update the system now (recommended before installing drivers and packages)?" Y || return
    dnf_run "Updating the system..." upgrade -y --refresh || warn "System update reported errors"
}

restore_nvidia() {
    section "NVIDIA driver"
    local gpu
    gpu=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' | grep -i nvidia)
    if [[ -z $gpu ]]; then info "No NVIDIA GPU detected - skipping"; return; fi
    info "Detected: ${gpu#*: }"
    ask_always "Install the proprietary NVIDIA driver from RPM Fusion?" Y || { info "Skipped (open nouveau driver stays in use)"; return; }

    if ! dnf repo list --enabled 2>/dev/null | grep -q '^rpmfusion-nonfree '; then
        if ask_always "RPM Fusion nonfree is required but not enabled. Enable RPM Fusion now?" Y; then
            local fv; fv=$(rpm -E %fedora)
            dnf_run "Installing RPM Fusion repository definitions..." install -y \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$fv.noarch.rpm" \
                "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$fv.noarch.rpm" ||
                { warn "Could not enable RPM Fusion - NVIDIA driver not installed"; return; }
        else
            warn "NVIDIA driver not installed (RPM Fusion disabled)"; return
        fi
    fi

    if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        warn "Secure Boot is enabled: the NVIDIA module must be signed."
        dnf_run "Installing Secure Boot signing tools..." install -y akmods mokutil openssl
        sudo kmodgenca -a
        info "Choose a one-time password; after reboot pick 'Enroll MOK' in the blue screen and enter it."
        sudo mokutil --import /etc/pki/akmods/certs/public_key.der </dev/tty || warn "MOK key import failed"
    fi

    local -a pkgs=(akmod-nvidia xorg-x11-drv-nvidia-cuda)
    # Extra NVIDIA packages from the old system (e.g. 32-bit libs for Steam, power management)
    mapfile -t -O "${#pkgs[@]}" pkgs < <(grep -i nvidia "$BK/packages/rpm-all.txt" | grep -v '^kmod-' |
        sed -E "s/\.(noarch|$(uname -m))$//")
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
    dnf_run "Installing NVIDIA driver packages..." install -y --skip-unavailable "${pkgs[@]}" ||
        { warn "NVIDIA driver installation failed"; return; }
    if rpm -q xorg-x11-drv-nvidia-power &>/dev/null; then
        sudo systemctl enable nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service 2>/dev/null
    fi
    info "Building the NVIDIA kernel module (can take several minutes)..."
    local k
    k=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)
    sudo akmods --force --kernels "$k" || warn "akmods build reported an error (it will retry at boot)"
    [[ $k != "$(uname -r)" ]] && sudo akmods --force &>/dev/null
    ok "NVIDIA driver installed - a reboot is required"
}

restore_packages() {
    section "DNF packages"
    [[ -s $BK/packages/userinstalled.tsv ]] || return
    local -a pkgs
    local -a local_rpms=("$BK"/packages/local-rpms/*.rpm)
    if ((${#local_rpms[@]})); then
        if ask "Install ${#local_rpms[@]} archived locally installed RPM(s)?" Y; then
            dnf_run "Installing archived local RPMs..." install -y --skip-broken "${local_rpms[@]}" ||
                warn "Some archived local RPMs could not be installed"
        fi
    fi
    mapfile -t pkgs < <(awk -F'\t' -v n="$(uname -m)" '{ print (($2=="noarch" || $2==n) ? $1 : $1"."$2) }' \
        "$BK/packages/userinstalled.tsv" | grep -Ev "$PKG_SKIP_RE" | grep -v nvidia | sort -u)
    ask "Install ${#pkgs[@]} packages from the old system (already installed ones are skipped)?" Y || return
    dnf_run "Installing ${#pkgs[@]} packages; this may take a while..." \
        install -y --skip-unavailable --skip-broken --allowerasing "${pkgs[@]}" ||
        warn "dnf reported problems during the bulk install"

    local missing_file="$HOME/fedora-restore-missing-packages.txt"
    rpm -q "${pkgs[@]}" 2>/dev/null | sed -n 's/^package \(.*\) is not installed$/\1/p' >"$missing_file"
    if [[ -s $missing_file ]]; then
        warn "$(wc -l <"$missing_file") packages could not be installed - see $missing_file"
    else
        rm -f "$missing_file"; ok "All packages installed"
    fi
    [[ -s $BK/packages/local-rpms.txt ]] &&
        info "Originally installed from local .rpm files: $(paste -sd' ' "$BK/packages/local-rpms.txt")"
}

restore_flatpaks() {
    section "Flatpak apps"
    [[ -s $BK/flatpak/apps.tsv ]] || { info "No Flatpaks in backup"; return; }
    ask "Restore $(wc -l <"$BK/flatpak/apps.tsv") Flatpak apps and their remotes?" Y || return
    have flatpak || dnf_run "Installing Flatpak..." install -y flatpak
    local name url opts inst S key app origin
    while IFS=$'\t' read -r name url opts; do
        [[ -z $name ]] && continue
        inst=user; S=''
        [[ $opts == *system* ]] && { inst=system; S=sudo; }
        if ! flatpak remotes "--$inst" --columns=name | grep -qxF "$name"; then
            key="$BK/flatpak/keys/$name.trustedkeys.gpg"
            if [[ $name == flathub ]]; then
                $S flatpak remote-add "--$inst" --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            elif [[ -f $key ]]; then
                $S flatpak remote-add "--$inst" --if-not-exists --gpg-import="$key" "$name" "$url"
            else
                $S flatpak remote-add "--$inst" --if-not-exists "$name" "$url"
            fi || warn "Could not add Flatpak remote $name"
        fi
        [[ $name == flathub ]] && $S flatpak remote-modify "--$inst" --no-filter --enable flathub 2>/dev/null
    done <"$BK/flatpak/remotes.tsv"

    # Install grouped by installation + origin, falling back to one-by-one and to Flathub
    local group
    while IFS= read -r group <&3; do
        inst=${group%%$'\t'*}; origin=${group#*$'\t'}
        S=''; [[ $inst == system ]] && S=sudo
        mapfile -t apps < <(awk -F'\t' -v i="$inst" -v o="$origin" '$3==i && $2==o {print $1}' "$BK/flatpak/apps.tsv")
        info "Installing ${#apps[@]} app(s) from '$origin' ($inst)..."
        if ! $S flatpak install "--$inst" -y --noninteractive "$origin" "${apps[@]}"; then
            for app in "${apps[@]}"; do
                $S flatpak install "--$inst" -y --noninteractive "$origin" "$app" ||
                    { [[ $origin != flathub ]] && $S flatpak install "--$inst" -y --noninteractive flathub "$app"; } ||
                    warn "Flatpak $app could not be installed"
            done
        fi
    done 3< <(awk -F'\t' '{print $3"\t"$2}' "$BK/flatpak/apps.tsv" | sort -u)

    if [[ -d $BK/flatpak/user-overrides ]]; then
        mkdir -p "$HOME/.local/share/flatpak/overrides"
        cp -r "$BK/flatpak/user-overrides/." "$HOME/.local/share/flatpak/overrides/"
    fi
    if [[ -d $BK/flatpak/system-overrides ]]; then
        sudo mkdir -p /var/lib/flatpak/overrides
        sudo cp -r "$BK/flatpak/system-overrides/." /var/lib/flatpak/overrides/
    fi
    ok "Flatpaks processed (app data is restored with the home configs)"
}

restore_vscode() {
    local has_code=0
    grep -qx 'code' "$BK/packages/local-rpms.txt" 2>/dev/null && has_code=1
    awk -F'\t' '$1=="code" {found=1} END {exit !found}' "$BK/packages/userinstalled.tsv" 2>/dev/null && has_code=1
    ((has_code)) || [[ -s $BK/packages/vscode-extensions.txt ]] || return
    section "VS Code"
    if ! have code; then
        if ask "Restore the Visual Studio Code repository and install VS Code?" Y; then
            sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || warn "Could not import the VS Code signing key"
            if [[ ! -e /etc/yum.repos.d/vscode.repo ]]; then
                sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
            fi
            dnf_run "Installing VS Code..." install -y code || warn "VS Code could not be installed"
        fi
    fi
    [[ -s $BK/packages/vscode-extensions.txt ]] || return
    have code || { warn "VS Code is not installed - extensions skipped"; return; }
    section "VS Code extensions"
    ask "Install $(wc -l <"$BK/packages/vscode-extensions.txt") VS Code extensions?" Y || return
    local ext
    while IFS= read -r ext; do
        [[ -z $ext ]] && continue
        info "Installing VS Code extension: $ext"
        code --install-extension "$ext" --force || warn "VS Code extension $ext failed"
    done <"$BK/packages/vscode-extensions.txt"
    ok "VS Code extensions processed"
}

restore_home() {
    section "Home configs, dotfiles, app data, icons/themes/fonts, GNOME extensions"
    [[ -f $BK/home.tar.zst ]] || { warn "home.tar.zst missing in backup"; return; }
    ask "Restore configs/dotfiles into $HOME (existing files with the same name are overwritten)?" Y || return
    local snap
    snap="$HOME/pre-restore-configs-$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -C "$HOME" -czf "$snap" --ignore-failed-read --exclude='.config/dconf' \
        .config .bashrc .bash_profile .local/share/gnome-shell 2>/dev/null &&
        info "Current configs saved to $snap"
    if tar -C "$HOME" -I zstd -xpf "$BK/home.tar.zst" --overwrite; then
        ok "Configs restored"
    else
        warn "Some files failed to extract - check the log"
    fi
    local -a paths=()
    while IFS= read -r p; do [[ -e $HOME/$p ]] && paths+=("$HOME/$p"); done <"$BK/meta/home-members.txt"
    ((${#paths[@]})) && sudo restorecon -R "${paths[@]}" 2>/dev/null
    have fc-cache && fc-cache -f >/dev/null 2>&1
    [[ $(meta_get user) != "$USER" ]] &&
        warn "Username changed ($(meta_get user) -> $USER): some app configs may still reference $(meta_get home)"
}

restore_system_assets() {
    [[ -f $BK/system/system-assets.tar.zst || -f $BK/system/avatar ]] || return
    section "System-wide icons/themes/fonts and user avatar"
    if [[ -f $BK/system/system-assets.tar.zst ]] && ask "Restore system-wide custom assets ($(paste -sd' ' "$BK/system/system-assets.txt"))?" Y; then
        sudo tar -C / -I zstd -xpf "$BK/system/system-assets.tar.zst" --skip-old-files &&
            sudo restorecon -R /usr/share/icons /usr/share/themes /usr/share/fonts /usr/share/backgrounds /usr/local/share 2>/dev/null
        sudo fc-cache -f >/dev/null 2>&1
        ok "System assets restored"
    fi
    if [[ -f $BK/system/avatar ]]; then
        local tmp; tmp=$(mktemp /tmp/avatar.XXXXXX); cp "$BK/system/avatar" "$tmp"; chmod 644 "$tmp"
        busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
            org.freedesktop.Accounts.User SetIconFile s "$tmp" &>/dev/null && ok "User avatar restored"
        rm -f "$tmp"
    fi
}

dconf_load_by_key() {
    local file=$1 section='' line key val okc=0 failc=0
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            section=${BASH_REMATCH[1]}
        elif [[ -n $section && $line =~ ^([^=]+)=(.*)$ ]]; then
            key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
            if [[ $section == / ]]; then key="/$key"; else key="/$section/$key"; fi
            if dconf write "$key" "$val" 2>/dev/null; then ((okc++)); else ((failc++)); fi
        fi
    done <"$file"
    info "dconf key-by-key: $okc applied, $failc failed"
}

restore_gnome() {
    section "GNOME settings and extensions"
    [[ -s $BK/gnome/dconf.ini ]] || return
    if [[ -z $DBUS_SESSION_BUS_ADDRESS ]] || ! have dconf; then
        warn "No graphical session detected - run '$0 restore' again from inside GNOME to apply settings"
        return
    fi
    ask "Apply GNOME settings (wallpaper, keybindings, dock, extensions, app settings)?" Y || return
    local ini old_home
    ini=$(mktemp); old_home=$(meta_get home)
    if [[ -n $old_home && $old_home != "$HOME" ]]; then
        sed "s#${old_home}/#${HOME}/#g; s#'${old_home}'#'${HOME}'#g" "$BK/gnome/dconf.ini" >"$ini"
    else
        cp "$BK/gnome/dconf.ini" "$ini"
    fi
    if dconf load / <"$ini"; then
        ok "dconf settings loaded"
    else
        warn "dconf load failed - applying keys one by one"
        dconf_load_by_key "$ini"
    fi
    rm -f "$ini"

    local ext missing=()
    for ext in $(sed "s/^@as //; s/[][',]/ /g" "$BK/gnome/enabled-extensions.txt" 2>/dev/null); do
        [[ -d $HOME/.local/share/gnome-shell/extensions/$ext || -d /usr/share/gnome-shell/extensions/$ext ]] ||
            missing+=("$ext")
    done
    ((${#missing[@]})) && warn "Enabled extensions not found (install via Extension Manager): ${missing[*]}"
    local old_shell new_shell
    old_shell=$(meta_get gnome); new_shell=$(gnome-shell --version 2>/dev/null)
    [[ -n $old_shell && $old_shell != "$new_shell" ]] &&
        info "GNOME changed ($old_shell -> $new_shell): update extensions in Extension Manager if any are disabled."
    info "Log out and back in (or reboot) to load the restored extensions."
}

restore_services() {
    section "Services and group memberships"
    local u
    local -a units=() uunits=() groups=()
    while IFS= read -r u; do
        [[ -z $u || $u == *@.* ]] && continue
        systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q . || continue
        [[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] || units+=("$u")
    done <"$BK/system/enabled-units.txt"
    while IFS= read -r u; do
        [[ -z $u || $u == *@.* ]] && continue
        systemctl --user list-unit-files "$u" --no-legend 2>/dev/null | grep -q . || continue
        [[ $(systemctl --user is-enabled "$u" 2>/dev/null) == enabled ]] || uunits+=("$u")
    done <"$BK/system/enabled-user-units.txt"
    while IFS= read -r u; do
        [[ -n $u ]] && getent group "$u" >/dev/null && ! id -nG "$USER" | grep -qw -- "$u" && groups+=("$u")
    done <"$BK/system/groups.txt"

    if ((${#units[@]})) && ask "Enable ${#units[@]} system services that were enabled before (${units[*]})?" Y; then
        for u in "${units[@]}"; do sudo systemctl enable "$u" &>/dev/null || warn "Could not enable $u"; done
        ok "System services enabled (they start after reboot)"
    fi
    if ((${#uunits[@]})) && ask "Enable ${#uunits[@]} user services (${uunits[*]})?" Y; then
        for u in "${uunits[@]}"; do systemctl --user enable "$u" &>/dev/null || warn "Could not enable user unit $u"; done
    fi
    if ((${#groups[@]})) && ask "Add $USER to groups: ${groups[*]}?" Y; then
        for u in "${groups[@]}"; do sudo usermod -aG "$u" "$USER"; done
        ok "Group memberships restored (active after re-login)"
    fi
    ((${#units[@]} + ${#uunits[@]} + ${#groups[@]})) || info "Nothing to change"
}

restore_vms() {
    section "Virtual machines"
    local -a doms=()
    local d
    for d in "$BK"/vms/system/*/ "$BK"/vms/session/*/; do
        [[ -f $d/domain.xml ]] && doms+=("${d%/}")
    done
    if ((${#doms[@]} == 0)) && [[ ! -s $BK/vms/folders.tsv ]]; then info "No VMs in backup"; return; fi

    if ((${#doms[@]})); then
        ask "Restore ${#doms[@]} libvirt VM(s): $(for d in "${doms[@]}"; do printf '%s ' "$(basename "$d")"; done)?" Y || doms=()
    fi
    if ((${#doms[@]})); then
        if ! have virsh; then
            ask "Virtualization tools (libvirt/QEMU/virt-manager) are missing. Install them?" Y || return
            dnf_run "Installing the virtualization package group..." group install -y virtualization ||
                { warn "Could not install virtualization group"; return; }
        fi
        sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket &>/dev/null ||
            sudo systemctl enable --now libvirtd &>/dev/null
        sudo usermod -aG libvirt "$USER"

        local x n path
        for x in "$BK"/vms/system/networks/*.xml; do
            n=$(basename "$x" .xml)
            sudo virsh -c qemu:///system net-info "$n" &>/dev/null && continue
            sudo virsh -c qemu:///system net-define "$x" >/dev/null && sudo virsh -c qemu:///system net-autostart "$n" >/dev/null &&
                sudo virsh -c qemu:///system net-start "$n" >/dev/null && ok "Network $n"
        done
        for x in "$BK"/vms/system/pools/*.xml; do
            n=$(basename "$x" .xml)
            sudo virsh -c qemu:///system pool-info "$n" &>/dev/null && continue
            path=$(grep -oP '<path>\K[^<]+' "$x" | head -n1)
            [[ -n $path && ! -e $path ]] && sudo mkdir -p "$path"
            sudo virsh -c qemu:///system pool-define "$x" >/dev/null && sudo virsh -c qemu:///system pool-autostart "$n" >/dev/null
            sudo virsh -c qemu:///system pool-start "$n" &>/dev/null
        done

        local scope uri S dom kind stored orig
        for d in "${doms[@]}"; do
            dom=$(basename "$d"); scope=$(basename "$(dirname "$d")")
            uri="qemu:///$scope"; S=''; [[ $scope == system ]] && S=sudo
            if $S virsh -c "$uri" dominfo "$dom" &>/dev/null; then warn "VM '$dom' already exists - skipped"; continue; fi
            info "Restoring VM '$dom' ($scope)..."
            while IFS=$'\t' read -r kind stored orig; do
                [[ -z $kind ]] && continue
                if $S test -e "$orig"; then warn "$orig already exists - kept"; continue; fi
                $S mkdir -p "$(dirname "$orig")"
                if [[ $kind == disk ]]; then
                    $S cp --sparse=always "$d/$stored" "$orig"
                else
                    $S cp -a "$d/$stored" "$orig"
                fi || warn "Failed to restore $orig"
                if [[ $scope == system ]]; then
                    if [[ $kind == tpm ]]; then sudo chown -R tss:tss "$orig"; else sudo chown -R root:root "$orig"; fi
                    sudo restorecon -R "$orig" 2>/dev/null
                fi
            done <"$d/files.tsv"
            $S virsh -c "$uri" define "$d/domain.xml" >/dev/null && ok "VM '$dom' defined" || warn "Could not define VM '$dom'"
        done
    fi

    if [[ -s $BK/vms/folders.tsv ]] && ask "Restore VM folders (VirtualBox/VMware/GNOME Boxes)?" Y; then
        local idx target
        while IFS=$'\t' read -r idx target; do
            mkdir -p "$target"
            cp -a --sparse=always -n "$BK/vms/folders/$idx/." "$target/" && ok "Restored $target"
        done <"$BK/vms/folders.tsv"
    fi
}

do_restore() {
    preflight
    local src=${1:-}
    [[ -z $src ]] && src=$(find_latest_backup)
    if [[ -z $src ]]; then
        read -r -p "Path to the fedora_backup_* folder or archive: " src </dev/tty
    fi
    [[ -e $src ]] || die "Backup not found: $src"
    if [[ -f $src ]]; then
        local parent need avail
        parent=$(cd "$(dirname "$src")" && pwd)
        need=$(stat -c %s "$src"); avail=$(df --output=avail -B1 "$parent" | tail -n1)
        ((need < avail)) || die "Not enough free space in $parent to extract $(basename "$src") ($(human "$need") needed)"
        info "Extracting $src..."
        tar -C "$parent" -xf "$src" || die "Could not extract $src"
        src="$parent/$(basename "$src" | sed -E 's/\.tar(\.(zst|gz|xz))?$//')"
        info "Extracted to $src (you can delete the .tar after a successful restore)"
    fi
    BK=$(cd "$src" && pwd)
    [[ -f $BK/meta/info.env ]] || die "$BK is not a backup made by this script (meta/info.env missing)"

    local log
    log="$HOME/fedora-restore-$(date +%Y%m%d_%H%M%S).log"
    RUN_LOG=$log
    DNF_LOG="${log%.log}-dnf.log"
    exec > >(tee -a "$RUN_LOG") 2>&1

    section "Fedora restore from $BK"
    info "Backup of $(meta_get user)@$(meta_get hostname), Fedora $(meta_get fedora), made $(meta_get date)"
    info "This system: Fedora $(rpm -E %fedora), logs: $RUN_LOG (full session), $DNF_LOG (DNF activity)"
    (($(rpm -E %fedora) < $(meta_get fedora))) && warn "This system is OLDER than the backup source - some packages may be missing"
    ask "Start the restore? Every step asks before it changes anything." Y || exit 0
    start_sudo

    restore_third_party
    restore_repos
    restore_update
    restore_nvidia
    restore_packages
    restore_flatpaks
    restore_vscode
    restore_home
    restore_system_assets
    restore_gnome
    restore_services
    restore_vms

    section "Restore finished"
    print_warnings
    info "Log: $log"
    if ask "Reboot now (needed for drivers, groups, services and extensions)?" N; then
        sudo systemctl reboot
    else
        info "Please reboot when convenient."
    fi
}

# ============================================================================= main
print_warnings() {
    ((${#WARNINGS[@]})) || { ok "No warnings"; return; }
    printf '\n%sWarnings:%s\n' "$YEL" "$RST"
    printf '  - %s\n' "${WARNINGS[@]}"
}

usage() { sed -n '2,/^$/ {s/^# \{0,1\}//; p}' "$0"; }

main() {
    local cmd='' args=()
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -h | --help) usage; exit 0 ;;
            backup | restore) cmd=$1 ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    if [[ -z $cmd ]]; then
        if [[ -t 0 && -t 1 ]] && have dialog; then
            local choice
            choice=$(dialog --clear --stdout --title "Fedora backup & restore" --menu \
                "Choose an action" 12 60 3 \
                backup "Back up this system" \
                restore "Restore a backup onto this system" \
                quit "Quit") || exit 0
            clear
            case $choice in backup|restore) cmd=$choice ;; *) exit 0 ;; esac
        else
            printf '%sFedora backup & restore%s\n  1) Backup this system\n  2) Restore a backup onto this system\n  3) Quit\n' "$BOLD" "$RST"
            local c; read -r -p "Choice: " c </dev/tty
            case $c in 1) cmd=backup ;; 2) cmd=restore ;; *) exit 0 ;; esac
        fi
    fi
    case $cmd in
        backup) do_backup "${args[@]}" ;;
        restore) do_restore "${args[@]}" ;;
    esac
}

main "$@"
