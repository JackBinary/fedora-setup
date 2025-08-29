#!/usr/bin/env bash

set -euo pipefail

### ---------- Helpers ----------
color_echo() {
  local c="$1"; shift
  local msg="$*"
  local code=""
  case "$c" in
    red) code="31";;
    green) code="32";;
    yellow) code="33";;
    blue) code="34";;
    magenta) code="35";;
    cyan) code="36";;
    *) code="0";;
  esac
  echo -e "\033[${code}m$msg\033[0m"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.bak" ]]; then
    cp -a "$f" "${f}.bak"
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    color_echo yellow "Command '$cmd' is missing. Attempting to install…"
    # Basic map for common utilities → package names
    case "$cmd" in
      git) pkg="git";;
      wget) pkg="wget";;
      curl) pkg="curl";;
      unzip) pkg="unzip";;
      rsync) pkg="rsync";;
      make) pkg="make";;
      gcc) pkg="gcc";;
      kvantummanager|kvantum) pkg="kvantum";;
      lookandfeeltool) pkg="plasma-workspace";;
      gsettings) pkg="glib2";;
      fwupdmgr) pkg="fwupd";;
      *) pkg="$cmd";;
    esac

    if dnf list "$pkg" >/dev/null 2>&1; then
      dnf -y install "$pkg"
    else
      color_echo red "Could not find a package providing '$cmd'. Please install manually."
      exit 1
    fi

    # Re-check
    if ! command -v "$cmd" >/dev/null 2>&1; then
      color_echo red "Failed to install '$cmd'. Aborting."
      exit 1
    fi
  fi
}

run_or_warn() {
  # run command; warn on failure but continue
  set +e
  "$@" || color_echo yellow "Warning: command failed (ignored): $*"
  set -e
}

detect_user() {
  # Best-effort to find the real user (not root) for user-scoped settings
  if [[ -n "${SUDO_USER-}" && "${SUDO_USER}" != "root" ]]; then
    ACTUAL_USER="$SUDO_USER"
  else
    ACTUAL_USER="$(logname 2>/dev/null || true)"
    [[ -z "$ACTUAL_USER" ]] && ACTUAL_USER="$(who | awk 'NR==1{print $1}')"
    [[ -z "$ACTUAL_USER" ]] && ACTUAL_USER="root"
  fi
  ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" | cut -d: -f6)"
  export ACTUAL_USER ACTUAL_HOME
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    color_echo red "Please run as root (sudo -i)."
    exit 1
  fi
}

### ---------- Start ----------
need_root
detect_user

color_echo cyan "Fedora Setup — starting… (user: $ACTUAL_USER; home: $ACTUAL_HOME)"

# Ensure core tools
dnf -y install dnf-plugins-core curl git wget unzip rsync || true

### ---------- System upgrade & DNF tuning ----------
color_echo blue "Upgrading system…"
dnf -y upgrade

color_echo yellow "Optimizing DNF configuration…"
backup_file /etc/dnf/dnf.conf
grep -q '^max_parallel_downloads=' /etc/dnf/dnf.conf || echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf

### ---------- Firmware updates ----------
if command -v fwupdmgr >/dev/null 2>&1; then
  color_echo yellow "Refreshing & applying firmware updates…"
  run_or_warn fwupdmgr refresh --force
  run_or_warn fwupdmgr get-updates
  run_or_warn fwupdmgr update -y
else
  color_echo yellow "fwupdmgr not found; installing…"
  dnf -y install fwupd
  run_or_warn fwupdmgr refresh --force
  run_or_warn fwupdmgr get-updates
  run_or_warn fwupdmgr update -y
fi

### ---------- Flatpak / Flathub ----------
color_echo yellow "Configuring Flatpak Flathub…"
dnf -y install flatpak
run_or_warn flatpak remote-delete fedora --force
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
run_or_warn flatpak repair
run_or_warn flatpak update -y

### ---------- RPM Fusion ----------
color_echo yellow "Enabling RPM Fusion (free + nonfree)…"
dnf -y install "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
dnf -y install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
dnf -y update @core

### ---------- Media codecs & AMD VA-API/VDPAU ----------
color_echo yellow "Installing multimedia groups and switching to full FFmpeg…"
run_or_warn dnf -y group install multimedia
run_or_warn dnf -y swap ffmpeg-free ffmpeg --allowerasing
run_or_warn dnf -y upgrade @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
run_or_warn dnf -y group install sound-and-video

color_echo yellow "Installing AMD hardware-accelerated codecs (freeworld)…"
run_or_warn dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld
run_or_warn dnf -y swap mesa-vdpau-drivers mesa-vdpau-drivers-freeworld

### ---------- AppImage (FUSE) ----------
color_echo yellow "Installing FUSE for AppImage support…"
dnf -y install fuse

### ---------- Terra repo (low priority) ----------
color_echo yellow "Adding Terra repository with low priority…"
cat >/etc/yum.repos.d/terra.repo <<'EOF'
[terra]
name=Terra Linux repo
baseurl=https://repos.fyralabs.com/terra/$releasever
enabled=1
gpgcheck=0
priority=150
EOF

### ---------- COPR: cachyos kernel ----------
color_echo yellow "Configuring COPR: cachyos kernel…"
dnf -y copr enable bieszczaders/kernel-cachyos

# SELinux policy for module loading (if SELinux present)
if command -v getenforce >/dev/null 2>&1; then
  color_echo yellow "Adjusting SELinux boolean for kernel module loading…"
  run_or_warn setsebool -P domain_kernel_load_modules on
fi

# CPU baseline detection (x86-64 psABI)
install_cachyos_kernel() {
  local supported=""
  if [[ -x /lib64/ld-linux-x86-64.so.2 ]]; then
    supported="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -o 'x86_64_v[23]' | sort -u | tr '\n' ' ')"
  fi

  color_echo blue "Detected CPU ISA baselines: ${supported:-unknown}"

  # Default logic: if v3 is supported -> default cachyos; else if only v2 -> LTS
  if echo "$supported" | grep -q 'x86_64_v3'; then
    color_echo green "x86_64_v3 supported — installing kernel-cachyos (default)…"
    dnf -y install kernel-cachyos kernel-cachyos-devel-matched
  elif echo "$supported" | grep -q 'x86_64_v2'; then
    color_echo green "Only x86_64_v2 detected — installing kernel-cachyos-lts…"
    dnf -y install kernel-cachyos-lts kernel-cachyos-lts-devel-matched
  else
    color_echo red "Unable to confirm v2/v3 baseline. Skipping cachyos kernel to avoid breakage."
  fi
}
install_cachyos_kernel

### ---------- COPR: Mesa-git ----------
color_echo yellow "Enabling COPR: Mesa-git and refreshing…"
dnf -y copr enable xxmitsu/mesa-git
dnf -y update --refresh

### ---------- COPR: Webapp Manager (Mint port) ----------
color_echo yellow "Installing webapp-manager from COPR…"
dnf -y copr enable kylegospo/webapp-manager
dnf -y install webapp-manager

### ---------- COPR: hBlock ----------
color_echo yellow "Installing hBlock (ad/tracker/malware hosts)…"
dnf -y copr enable pesader/hblock
dnf -y install hblock

### ---------- COPR: Ghostty ----------
color_echo yellow "Installing Ghostty terminal…"
dnf -y copr enable pgdev/ghostty
dnf -y install ghostty

### ---------- COPR: LACT (AMD GPU control) ----------
color_echo yellow "Installing LACT and enabling daemon…"
dnf -y copr enable ilyaz/LACT
dnf -y install lact
run_or_warn systemctl enable --now lactd

### ---------- Extra apps (from your “webapp” script) ----------
color_echo yellow "Installing essential CLI tools…"
dnf -y install btop htop unrar

color_echo yellow "Installing browsers & comms…"
dnf -y install chromium thunderbird

color_echo yellow "Installing Element & Signal (Flatpak)…"
run_or_warn flatpak install -y flathub im.riot.Riot
run_or_warn flatpak install -y flathub org.signal.Signal

### VS Code repo + install
color_echo yellow "Installing Visual Studio Code…"
rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
cat >/etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
dnf -y check-update || true
dnf -y install code

### Containers / virtualization meta
color_echo yellow "Installing Podman & virtualization group…"
dnf -y install podman
dnf -y group install @virtualization || true

### Media/graphics
color_echo yellow "Installing media & graphics apps…"
dnf -y install vlc krita blender obs-studio kdenlive

### Gaming
color_echo yellow "Installing Steam & Lutris…"
dnf -y install steam lutris
run_or_warn flatpak install -y flathub org.DolphinEmu.dolphin-emu

### Tailscale
color_echo yellow "Installing Tailscale…"
dnf -y config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
dnf -y install tailscale
run_or_warn systemctl enable --now tailscaled

### Flatpak helpers
color_echo yellow "Installing Bottles, Proton tools, Flatseal, Video Downloader…"
run_or_warn flatpak install -y flathub com.usebottles.bottles
run_or_warn flatpak install -y flathub com.github.Matoking.protontricks
run_or_warn flatpak install -y flathub net.davidotek.pupgui2
run_or_warn flatpak install -y flathub com.github.tchx84.Flatseal
run_or_warn flatpak install -y flathub com.github.unrud.VideoDownloader

### ---------- Fonts ----------
color_echo yellow "Installing Microsoft core fonts…"
dnf -y install cabextract xorg-x11-font-utils fontconfig || true
run_or_warn rpm -i https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm

color_echo yellow "Installing Google fonts (latest)…"
mkdir -p "$ACTUAL_HOME/.local/share/fonts/google"
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/fonts"
run_or_warn sudo -u "$ACTUAL_USER" bash -lc '
  set -e
  tmp=$(mktemp -d)
  wget -O "$tmp/google-fonts.zip" https://github.com/google/fonts/archive/main.zip
  unzip -q "$tmp/google-fonts.zip" -d "$HOME/.local/share/fonts/google"
  fc-cache -fv
'

color_echo yellow "Installing Adobe Source fonts…"
mkdir -p "$ACTUAL_HOME/.local/share/fonts/adobe-fonts"
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/fonts"
run_or_warn sudo -u "$ACTUAL_USER" bash -lc '
  set -e
  git clone --depth 1 https://github.com/adobe-fonts/source-sans.git "$HOME/.local/share/fonts/adobe-fonts/source-sans" || true
  git clone --depth 1 https://github.com/adobe-fonts/source-serif.git "$HOME/.local/share/fonts/adobe-fonts/source-serif" || true
  git clone --depth 1 https://github.com/adobe-fonts/source-code-pro.git "$HOME/.local/share/fonts/adobe-fonts/source-code-pro" || true
  fc-cache -f
'

### ---------- Icon theme (Qogir) ----------
color_echo yellow "Installing Qogir icon theme…"
run_or_warn bash -lc '
  set -e
  tmp=$(mktemp -d)
  git clone https://github.com/vinceliuice/Qogir-icon-theme.git "$tmp/Qogir-icon-theme"
  cd "$tmp/Qogir-icon-theme" && ./install.sh -c all -t all
'
# Apply to GNOME for the actual (non-root) user if possible
if command -v gsettings >/dev/null 2>&1; then
  run_or_warn sudo -u "$ACTUAL_USER" dbus-launch gsettings set org.gnome.desktop.interface icon-theme "Qogir"
fi

### ---------- DNS over TLS via systemd-resolved ----------
color_echo yellow "Configuring systemd-resolved for DNS-over-TLS (Cloudflare security)…"
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/99-dns-over-tls.conf <<'EOF'
[Resolve]
DNS=1.1.1.2#security.cloudflare-dns.com 1.0.0.2#security.cloudflare-dns.com 2606:4700:4700::1112#security.cloudflare-dns.com 2606:4700:4700::1002#security.cloudflare-dns.com
DNSOverTLS=yes
EOF
run_or_warn systemctl restart systemd-resolved

### ---------- Speed up boot ----------
color_echo yellow "Disabling NetworkManager-wait-online.service to speed up boot…"
run_or_warn systemctl disable NetworkManager-wait-online.service

### ---------- Nordic Theme (KDE) ----------
install_nordic_kde_theme() {
  color_echo yellow "Installing Nordic (KDE) theme…"

  # Install Kvantum (needed for Kvantum themes)
  dnf -y install kvantum

  tmp_dir="$(mktemp -d)"
  git clone --depth=1 https://github.com/EliverLara/Nordic.git "$tmp_dir/Nordic"
  src_kde="$tmp_dir/Nordic/kde"

  # User-scope directories
  install -d -m 0755 \
    "$ACTUAL_HOME/.local/share/color-schemes" \
    "$ACTUAL_HOME/.local/share/plasma/look-and-feel" \
    "$ACTUAL_HOME/.local/share/konsole" \
    "$ACTUAL_HOME/.local/share/aurorae/themes" \
    "$ACTUAL_HOME/.config/Kvantum"
  chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local" "$ACTUAL_HOME/.config"

  # 1) KDE Color Schemes
  if [[ -d "$src_kde/colorschemes" ]]; then
    cp -rTf "$src_kde/colorschemes" "$ACTUAL_HOME/.local/share/color-schemes"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/color-schemes"
  fi

  # 2) Aurorae (Window Decorations)
  if [[ -d "$src_kde/aurorae/Nordic" ]]; then
    install -d -m 0755 "$ACTUAL_HOME/.local/share/aurorae/themes/Nordic"
    cp -rT "$src_kde/aurorae/Nordic" "$ACTUAL_HOME/.local/share/aurorae/themes/Nordic"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/aurorae"
  fi

  # 3) Kvantum
  if [[ -d "$src_kde/kvantum" ]]; then
    cp -r "$src_kde/kvantum/"* "$ACTUAL_HOME/.config/Kvantum/" 2>/dev/null || true
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.config/Kvantum"
    # Set default Kvantum theme
    sudo -u "$ACTUAL_USER" bash -lc 'printf "[General]\ntheme=Nordic-Darker\n" > "$HOME/.config/Kvantum/kvantum.kvconfig"'
  fi

  # 4) Plasma Look-and-Feel
  if [[ -d "$src_kde/plasma/look-and-feel" ]]; then
    cp -r "$src_kde/plasma/look-and-feel/"* "$ACTUAL_HOME/.local/share/plasma/look-and-feel/"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/plasma/look-and-feel"
    # Apply immediately (optional)
    sudo -u "$ACTUAL_USER" dbus-launch lookandfeeltool -a com.github.eliverlara.nordic
  fi

  # 5) Konsole profiles
  if [[ -d "$src_kde/konsole" ]]; then
    cp -rTf "$src_kde/konsole" "$ACTUAL_HOME/.local/share/konsole"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/konsole"
  fi

  # 6) Cursors (system-wide)
  if [[ -d "$src_kde/cursors" ]]; then
    rm -rf /usr/share/icons/Nordic 2>/dev/null || true
    cp -rT "$src_kde/cursors" /usr/share/icons/Nordic
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f /usr/share/icons/Nordic || true
  fi

  # 7) Folder icons (optional, user-scope)
  if [[ -d "$src_kde/folders" ]]; then
    install -d -m 0755 "$ACTUAL_HOME/.local/share/icons/Nordic-folders"
    cp -rT "$src_kde/folders" "$ACTUAL_HOME/.local/share/icons/Nordic-folders"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/icons"
  fi

  # 8) SDDM theme (already installed on Plasma, just copy + enable)
  if [[ -d "$src_kde/sddm" ]]; then
    target="/usr/share/sddm/themes/Nordic"
    rm -rf "$target" 2>/dev/null || true
    cp -rT "$src_kde/sddm" "$target"
    mkdir -p /etc/sddm.conf.d
    cat >/etc/sddm.conf.d/10-theme.conf <<EOF
[Theme]
Current=Nordic
EOF
  fi

  # Rebuild font/icon caches for user
  run_or_warn sudo -u "$ACTUAL_USER" bash -lc "fc-cache -fv >/dev/null"

  color_echo green "Nordic (KDE) theme installed & Kvantum enabled (Nordic-Darker)."
}
install_nordic_kde_theme


### ---------- Final touches ----------
color_echo green "All done. Consider rebooting to use the new kernel if installed."
echo "Created with ❤️ for Open Source"
