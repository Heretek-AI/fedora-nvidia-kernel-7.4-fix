#!/usr/bin/env bash
# ==============================================================================
# fedora-nvidia-kernel-7.4-fix: fix-nvidia-sddm.sh
#
# Diagnoses and fixes missing SDDM login screen & KDE Plasma Wayland desktop
# failure on Fedora Rawhide / Linux 7.4+ caused by upstream moving
# <drm/drm_fb_helper.h> to <drm/clients/drm_fbdev_helper.h>, which breaks
# akmod-nvidia compilation and triggers a broken nouveau fallback under Wayland.
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

MODE="fix"
TARGET_KVER="$(uname -r)"
INSTALL_HOOK=1
FIX_SDDM_THEME=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Diagnose and repair missing SDDM login screen and KDE Plasma Wayland desktop
after upgrading to Linux kernel 7.4+ with NVIDIA (akmod-nvidia / rpmfusion).

Options:
  --diagnose          Run read-only diagnostics without modifying the system
  --kernel <kver>     Target kernel version (default: running kernel: ${TARGET_KVER})
  --no-hook           Do not install /etc/kernel/postinst.d/ compatibility hook
  --no-sddm-theme     Skip checking/installing sddm-breeze
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --diagnose|--check)
            MODE="diagnose"
            shift
            ;;
        --kernel|-k)
            TARGET_KVER="$2"
            shift 2
            ;;
        --no-hook)
            INSTALL_HOOK=0
            shift
            ;;
        --no-sddm-theme)
            FIX_SDDM_THEME=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

diagnose_system() {
    local issues=0
    echo "======================================================================"
    echo " Fedora / Linux 7.4+ NVIDIA + SDDM / KWin Wayland Diagnostic Report"
    echo "======================================================================"
    info "Running kernel : $(uname -r)"
    info "Target kernel  : ${TARGET_KVER}"

    # 1. Check GPU & active driver
    if command -v lspci >/dev/null 2>&1; then
        local gpu_info
        gpu_info="$(lspci -nnk | grep -A3 -E "VGA|3D|Display" || true)"
        echo "$gpu_info" | sed 's/^/  /'
    fi

    if lsmod | grep -q "^nouveau "; then
        warn "Active GPU driver is 'nouveau' (nvidia fallback active)!"
        issues=$((issues + 1))
    elif lsmod | grep -qE "^nvidia(_drm)? "; then
        ok "Active GPU driver is 'nvidia' / 'nvidia_drm'."
    else
        warn "Neither 'nvidia' nor 'nouveau' is currently loaded."
    fi

    # 2. Check kernel DRM headers for drm_fb_helper.h removal
    local kdir="/usr/src/kernels/${TARGET_KVER}"
    if [[ -d "$kdir" ]]; then
        if [[ -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
            warn "Kernel ${TARGET_KVER} moved <drm/drm_fb_helper.h> -> <drm/clients/drm_fbdev_helper.h> (compatibility symlink missing)."
            issues=$((issues + 1))
        elif [[ -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
            ok "Header <drm/drm_fb_helper.h> is present in ${kdir}."
        fi
    else
        warn "Kernel devel directory ${kdir} not found (is kernel-devel-${TARGET_KVER} installed?)."
        issues=$((issues + 1))
    fi

    # 3. Check akmods failure logs
    if compgen -G "/var/cache/akmods/nvidia/*for-${TARGET_KVER}.failed.log" >/dev/null 2>&1; then
        warn "Found failed akmods build log for ${TARGET_KVER}:"
        grep -E "fatal error:|error:" /var/cache/akmods/nvidia/*for-"${TARGET_KVER}".failed.log 2>/dev/null | head -n 5 | sed 's/^/    /' || true
        issues=$((issues + 1))
    fi

    # 4. Check journal for kwin_wayland_drm ERANGE
    if journalctl -b 2>/dev/null | grep -q "kwin_wayland_drm: Failed to create framebuffer: Numerical result out of range"; then
        warn "Journal shows 'kwin_wayland_drm: Failed to create framebuffer: Numerical result out of range' (ERANGE)."
        warn "KWin Wayland is running on a headless placeholder screen with no physical outputs."
        issues=$((issues + 1))
    fi

    # 5. Check SDDM theme
    if systemctl is-enabled sddm.service >/dev/null 2>&1; then
        if [[ ! -d /usr/share/sddm/themes/01-breeze-fedora ]] && ! rpm -q sddm-breeze >/dev/null 2>&1; then
            warn "sddm.service is enabled, but 'sddm-breeze' (01-breeze-fedora theme) is missing."
            issues=$((issues + 1))
        else
            ok "SDDM Breeze theme (01-breeze-fedora) is installed."
        fi
    fi

    echo "======================================================================"
    if [[ $issues -eq 0 ]]; then
        ok "No issues detected for kernel ${TARGET_KVER}."
    else
        warn "Detected ${issues} issue(s). Run 'sudo $0' to repair."
    fi
    return 0
}

if [[ "$MODE" == "diagnose" ]]; then
    diagnose_system
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    info "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

info "Step 1/5: Ensuring <drm/drm_fb_helper.h> compatibility across installed 7.4+ kernel-devel trees..."
for kdir in /usr/src/kernels/*; do
    [[ -d "$kdir/include/drm" ]] || continue
    if [[ -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
        ln -sf clients/drm_fbdev_helper.h "$kdir/include/drm/drm_fb_helper.h"
        ok "Linked $kdir/include/drm/drm_fb_helper.h -> clients/drm_fbdev_helper.h"
    fi
done

if [[ $INSTALL_HOOK -eq 1 ]]; then
    info "Step 2/5: Installing persistent kernel postinst hook (/etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat)..."
    mkdir -p /etc/kernel/postinst.d
    cat <<'HOOK' > /etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat
#!/usr/bin/env bash
# Automatically links <drm/drm_fb_helper.h> to <drm/clients/drm_fbdev_helper.h>
# on Linux 7.4+ kernels before akmods compiles nvidia-kmod.
KVER="${1:-}"
for kdir in "/usr/src/kernels/${KVER}" "/usr/src/kernels/${KVER}+debug" /usr/src/kernels/*; do
    if [[ -d "$kdir/include/drm" && -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
        ln -sf clients/drm_fbdev_helper.h "$kdir/include/drm/drm_fb_helper.h"
    fi
done
HOOK
    chmod 0755 /etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat
    ok "Installed /etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat"
else
    info "Step 2/5: Skipping kernel postinst hook installation (--no-hook)."
fi

info "Step 3/5: Building and installing kmod-nvidia for kernel ${TARGET_KVER} via akmods..."
if rpm -q "kmod-nvidia-${TARGET_KVER}" >/dev/null 2>&1; then
    ok "kmod-nvidia-${TARGET_KVER} is already installed."
else
    rm -f /var/cache/akmods/nvidia/*for-"${TARGET_KVER}".failed.log
    akmods --force --kernels "${TARGET_KVER}"
    depmod -a "${TARGET_KVER}"
    ok "Built and installed kmod-nvidia for ${TARGET_KVER}."
fi

if [[ $FIX_SDDM_THEME -eq 1 ]] && systemctl is-enabled sddm.service >/dev/null 2>&1; then
    info "Step 4/5: Checking SDDM theme (01-breeze-fedora)..."
    if ! rpm -q sddm-breeze >/dev/null 2>&1; then
        info "Installing sddm-breeze..."
        dnf install -y sddm-breeze
        ok "Installed sddm-breeze."
    else
        ok "sddm-breeze is already installed."
    fi
else
    info "Step 4/5: Skipping SDDM theme check."
fi

info "Step 5/5: Activating nvidia-drm driver..."
if [[ "${TARGET_KVER}" == "$(uname -r)" ]] && lsmod | grep -q "^nouveau "; then
    info "Attempting to unload fallback 'nouveau' module and load 'nvidia_drm'..."
    systemctl stop sddm.service 2>/dev/null || true
    for vt in /sys/class/vtconsole/vtcon*; do
        if grep -q "frame buffer" "$vt/name" 2>/dev/null; then
            echo 0 > "$vt/bind" 2>/dev/null || true
        fi
    done
    modprobe -r snd_hda_intel 2>/dev/null || true

    if modprobe -r nouveau 2>/dev/null; then
        modprobe snd_hda_intel 2>/dev/null || true
        modprobe nvidia_drm modeset=1
        systemctl start sddm.service
        ok "Switched from nouveau to nvidia_drm and restarted SDDM!"
    else
        for vt in /sys/class/vtconsole/vtcon*; do
            if grep -q "frame buffer" "$vt/name" 2>/dev/null; then
                echo 1 > "$vt/bind" 2>/dev/null || true
            fi
        done
        modprobe snd_hda_intel 2>/dev/null || true
        echo ""
        echo "======================================================================"
        ok "Repair complete! kmod-nvidia (${TARGET_KVER}) is installed."
        warn "Because 'nouveau' is bound to the active kernel framebuffer (fb0),"
        warn "please reboot to load the NVIDIA driver and restore your login screen:"
        echo ""
        echo "    sudo systemctl reboot"
        echo "======================================================================"
    fi
else
    ok "Repair complete for kernel ${TARGET_KVER}."
fi
