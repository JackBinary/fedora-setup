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

run_or_prompt() {
  local attempt=1
  while true; do
    set +e
    "$@" || {
      color_echo yellow "Warning: command failed: $*"
      read -p "Do you want to try again, skip, or quit? (t/s/q): " choice
      case "$choice" in
        [Tt]* ) attempt=$((attempt + 1)); continue ;;
        [Ss]* ) return 0 ;;
        [Qq]* ) exit 1 ;;
        * ) echo "Invalid choice. Please enter t, s, or q." ;;
      esac
    }
    set -e
    break
  done
}

detect_user() {
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

### ---------- DNS over TLS via systemd-resolved ----------
color_echo yellow "Configuring systemd-resolved for DNS-over-TLS (Cloudflare security)…"
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/99-dns-over-tls.conf <<'EOF'
[Resolve]
DNS=1.1.1.2#security.cloudflare-dns.com 1.0.0.2#security.cloudflare-dns.com 2606:4700:4700::1112#security.cloudflare-dns.com 2606:4700:4700::1002#security.cloudflare-dns.com
DNSOverTLS=yes
EOF
run_or_prompt systemctl restart systemd-resolved

# Minimal bootstrap so we can enable repos/COPRs in bulk
dnf -y install dnf-plugins-core

### ---------- System upgrade & DNF tuning ----------
color_echo blue "Upgrading system…"
dnf -y upgrade

color_echo yellow "Optimizing DNF configuration…"
backup_file /etc/dnf/dnf.conf
grep -q '^max_parallel_downloads=' /etc/dnf/dnf.conf || echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf

### ---------- Firmware updates ----------
if command -v fwupdmgr >/dev/null 2>&1; then
  color_echo yellow "Refreshing & applying firmware updates…"
  run_or_prompt fwupdmgr refresh --force
  run_or_prompt fwupdmgr get-updates
  run_or_prompt fwupdmgr update -y
else
  color_echo yellow "fwupdmgr not found; will be installed in bulk later."
fi

### ---------- Flatpak / Flathub ----------
color_echo yellow "Configuring Flatpak Flathub…"
dnf -y install flatpak
run_or_prompt flatpak remote-delete fedora --force
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
run_or_prompt flatpak repair

### ---------- RPM Fusion (free + nonfree) ----------
color_echo yellow "Enabling RPM Fusion (free + nonfree)…"
dnf -y install \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

### ---------- Terra repo (low priority) ----------
color_echo yellow "Adding Terra repository with low priority…"
cat >/etc/yum.repos.d/terra.repo <<'EOF'
[terra]
name=Terra Linux repo
baseurl=https://repos.fyralabs.com/terra$releasever
enabled=1
gpgcheck=0
priority=150
EOF

### ---------- VS Code repo ----------
color_echo yellow "Adding Visual Studio Code repo…"
rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
cat >/etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

### ---------- Tailscale repo ----------
color_echo yellow "Adding Tailscale repo…"
dnf -y config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo

### ---------- COPRs (enable first, then refresh once) ----------
color_echo yellow "Enabling COPRs…"
COPRS=(
  bieszczaders/kernel-cachyos
  xxmitsu/mesa-git
  kylegospo/webapp-manager
  pesader/hblock
  pgdev/ghostty
  ilyaz/LACT
)
for c in "${COPRS[@]}"; do
  run_or_prompt dnf -y copr enable "$c"
done

### ---------- One refresh after repos/COPRs ----------
color_echo yellow "Refreshing metadata…"
dnf -y update --refresh

### ---------- Bulk package install ----------
PKGS=(
  # Core tools
  curl git wget unzip rsync fuse

  # Firmware/FWUPD (if not already)
  fwupd

  # Browsers & comms
  chromium thunderbird

  # Terminals & utilities
  ghostty btop htop unrar

  # Webapp Manager, hBlock, LACT
  webapp-manager hblock lact

  # Media/graphics
  vlc krita blender obs-studio kdenlive

  # Gaming
  steam lutris

  # Containers / virtualization (podman as pkg; @virtualization as group later)
  podman

  # Fonts helpers
  cabextract xorg-x11-font-utils fontconfig

  # KDE theming dependency
  kvantum

  # Editors
  code

)

color_echo yellow "Installing baseline packages in one transaction…"
dnf -y install "${PKGS[@]}" "https://vencord.dev/download/vesktop/amd64/rpm"

### ---------- Group installs in one go ----------
color_echo yellow "Installing DNF groups…"
# 'multimedia' and 'sound-and-video' from RPM Fusion; '@virtualization' for KVM tools
run_or_prompt dnf -y group install multimedia sound-and-video @virtualization

### ---------- Codec and driver swaps (must be separate ops) ----------
color_echo yellow "Switching to full FFmpeg and freeworld Mesa VA/VDPAU…"
run_or_prompt dnf -y swap ffmpeg-free ffmpeg --allowerasing
run_or_prompt dnf -y upgrade @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
run_or_prompt dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld
run_or_prompt dnf -y swap mesa-vdpau-drivers mesa-vdpau-drivers-freeworld

### ---------- Kernel (CachyOS) selection (separate due to conditional choice) ----------
color_echo yellow "Configuring CachyOS kernel based on CPU baseline…"
install_cachyos_kernel() {
  local supported=""
  if [[ -x /lib64/ld-linux-x86-64.so.2 ]]; then
    supported="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -o 'x86_64_v[23]' | sort -u | tr '\n' ' ')"
  fi
  color_echo blue "Detected CPU ISA baselines: ${supported:-unknown}"
  if echo "$supported" | grep -q 'x86_64_v3'; then
    color_echo green "x86_64_v3 supported — installing kernel-cachyos…"
    dnf -y install kernel-cachyos kernel-cachyos-devel-matched
  elif echo "$supported" | grep -q 'x86_64_v2'; then
    color_echo green "Only x86_64_v2 detected — installing kernel-cachyos-lts…"
    dnf -y install kernel-cachyos-lts kernel-cachyos-lts-devel-matched
  else
    color_echo red "Unable to confirm v2/v3 baseline. Skipping cachyos kernel to avoid breakage."
  fi
}
install_cachyos_kernel

### ---------- Flatpak bulk updates & installs ----------
color_echo yellow "Updating Flatpaks…"
run_or_prompt flatpak update -y

color_echo yellow "Installing Flatpaks in one go…"
# Element (Riot), Signal, Dolphin, Bottles, Proton tools, ProtonUp, Flatseal, Video Downloader
run_or_prompt flatpak install -y flathub \
  im.riot.Riot \
  org.signal.Signal \
  org.DolphinEmu.dolphin-emu \
  com.usebottles.bottles \
  com.github.Matoking.protontricks \
  net.davidotek.pupgui2 \
  com.github.tchx84.Flatseal \
  com.github.unrud.VideoDownloader

### ---------- LACT daemon ----------
run_or_prompt systemctl enable --now lactd

### ---------- Fonts ----------
color_echo yellow "Installing Microsoft core fonts…"
run_or_prompt rpm -i https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm

color_echo yellow "Installing Google fonts (latest)…"
mkdir -p "$ACTUAL_HOME/.local/share/fonts/google"
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/fonts"
run_or_prompt sudo -u "$ACTUAL_USER" bash -lc '
  set -e
  tmp=$(mktemp -d)
  wget -O "$tmp/google-fonts.zip" https://github.com/google/fonts/archive/main.zip
  unzip -q "$tmp/google-fonts.zip" -d "$HOME/.local/share/fonts/google"
  fc-cache -fv
'

color_echo yellow "Installing Adobe Source fonts…"
mkdir -p "$ACTUAL_HOME/.local/share/fonts/adobe-fonts"
chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/fonts"
run_or_prompt sudo -u "$ACTUAL_USER" bash -lc '
  set -e
  git clone --depth 1 https://github.com/adobe-fonts/source-sans.git "$HOME/.local/share/fonts/adobe-fonts/source-sans" || true
  git clone --depth 1 https://github.com/adobe-fonts/source-serif.git "$HOME/.local/share/fonts/adobe-fonts/source-serif" || true
  git clone --depth 1 https://github.com/adobe-fonts/source-code-pro.git "$HOME/.local/share/fonts/adobe-fonts/source-code-pro" || true
  fc-cache -f
'

### ---------- Icon theme (Qogir) ----------
color_echo yellow "Installing Qogir icon theme…"
run_or_prompt bash -lc '
  set -e
  tmp=$(mktemp -d)
  git clone https://github.com/vinceliuice/Qogir-icon-theme.git "$tmp/Qogir-icon-theme"
  cd "$tmp/Qogir-icon-theme" && ./install.sh -c all -t all
'
if command -v gsettings >/dev/null 2>&1; then
  run_or_prompt sudo -u "$ACTUAL_USER" dbus-launch gsettings set org.gnome.desktop.interface icon-theme "Qogir"
fi

### ---------- Speed up boot ----------
color_echo yellow "Disabling NetworkManager-wait-online.service to speed up boot…"
run_or_prompt systemctl disable NetworkManager-wait-online.service

### ---------- Nordic Theme (KDE) ----------
install_nordic_kde_theme() {
  color_echo yellow "Installing Nordic (KDE) theme…"

  tmp_dir="$(mktemp -d)"
  git clone --depth=1 https://github.com/EliverLara/Nordic.git "$tmp_dir/Nordic"
  src_kde="$tmp_dir/Nordic/kde"

  install -d -m 0755 \
    "$ACTUAL_HOME/.local/share/color-schemes" \
    "$ACTUAL_HOME/.local/share/plasma/look-and-feel" \
    "$ACTUAL_HOME/.local/share/konsole" \
    "$ACTUAL_HOME/.local/share/aurorae/themes" \
    "$ACTUAL_HOME/.config/Kvantum"
  chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local" "$ACTUAL_HOME/.config"

  if [[ -d "$src_kde/colorschemes" ]]; then
    cp -rTf "$src_kde/colorschemes" "$ACTUAL_HOME/.local/share/color-schemes"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/color-schemes"
  fi

  if [[ -d "$src_kde/aurorae/Nordic" ]]; then
    install -d -m 0755 "$ACTUAL_HOME/.local/share/aurorae/themes/Nordic"
    cp -rT "$src_kde/aurorae/Nordic" "$ACTUAL_HOME/.local/share/aurorae/themes/Nordic"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/aurorae"
  fi

  if [[ -d "$src_kde/kvantum" ]]; then
    cp -r "$src_kde/kvantum/"* "$ACTUAL_HOME/.config/Kvantum/" 2>/dev/null || true
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.config/Kvantum"
    sudo -u "$ACTUAL_USER" bash -lc 'printf "[General]\ntheme=Nordic-Darker\n" > "$HOME/.config/Kvantum/kvantum.kvconfig"'
  fi

  if [[ -d "$src_kde/plasma/look-and-feel" ]]; then
    cp -r "$src_kde/plasma/look-and-feel/"* "$ACTUAL_HOME/.local/share/plasma/look-and-feel/"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/plasma/look-and-feel"
    run_or_prompt sudo -u "$ACTUAL_USER" dbus-launch lookandfeeltool -a com.github.eliverlara.nordic
  fi

  if [[ -d "$src_kde/konsole" ]]; then
    cp -rTf "$src_kde/konsole" "$ACTUAL_HOME/.local/share/konsole"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/konsole"
  fi

  if [[ -d "$src_kde/cursors" ]]; then
    rm -rf /usr/share/icons/Nordic 2>/dev/null || true
    cp -rT "$src_kde/cursors" /usr/share/icons/Nordic
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f /usr/share/icons/Nordic || true
  fi

  if [[ -d "$src_kde/folders" ]]; then
    install -d -m 0755 "$ACTUAL_HOME/.local/share/icons/Nordic-folders"
    cp -rT "$src_kde/folders" "$ACTUAL_HOME/.local/share/icons/Nordic-folders"
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$ACTUAL_HOME/.local/share/icons"
  fi

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

  run_or_prompt sudo -u "$ACTUAL_USER" bash -lc "fc-cache -fv >/dev/null"

  color_echo green "Nordic (KDE) theme installed & Kvantum enabled (Nordic-Darker)."
}
install_nordic_kde_theme

### ---------- Final touches ----------
color_echo green "All done. Consider rebooting to use the new kernel if installed."
echo "Created with ❤️ for Open Source"
