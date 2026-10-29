#!/usr/bin/env bash
# ==============================================================================
# fedora-nvidia-kernel-7.4-fix: fix-nvidia-sddm.sh
#
# Diagnoses and fixes missing SDDM login screen & KDE Plasma Wayland desktop
# failure on Fedora Rawhide / Linux 7.4+ caused by:
#  1. Upstream moving <drm/drm_fb_helper.h> -> <drm/clients/drm_fbdev_helper.h>
#  2. Upstream removing VM_SPECIAL & is_vm_hugetlb_page in 7.4.0-0.rc0.261028+
#
# These break akmod-nvidia compilation and trigger a broken nouveau fallback
# under Wayland.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Diagnose and repair missing SDDM login screen and KDE Plasma Wayland desktop
after upgrading to Linux kernel 7.4+ with NVIDIA (akmod-nvidia / rpmfusion).

Options:
  --diagnose          Run read-only diagnostics without modifying the system
  --kernel <kver>     Target kernel version (default: running kernel: ${TARGET_KVER})
  --no-hook           Do not install kernel compatibility hooks
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

    if [[ -d /sys/module/nouveau ]]; then
        warn "Active GPU driver is 'nouveau' (nvidia fallback active)!"
        issues=$((issues + 1))
    elif [[ -d /sys/module/nvidia_drm || -d /sys/module/nvidia ]]; then
        ok "Active GPU driver is 'nvidia' / 'nvidia_drm'."
    else
        warn "Neither 'nvidia' nor 'nouveau' is currently loaded."
    fi

    # 2. Check kernel headers for 7.4+ breaking changes
    local kdir="/usr/src/kernels/${TARGET_KVER}"
    if [[ -d "$kdir" ]]; then
        if [[ -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
            warn "Kernel ${TARGET_KVER} moved <drm/drm_fb_helper.h> -> <drm/clients/drm_fbdev_helper.h>."
            issues=$((issues + 1))
        elif [[ -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
            ok "Header <drm/drm_fb_helper.h> is present in ${kdir}."
        fi

        if [[ -f "$kdir/include/linux/mm.h" ]]; then
            if ! grep -q "\bVM_SPECIAL\b" "$kdir/include/linux/mm.h"; then
                warn "Kernel ${TARGET_KVER} removed VM_SPECIAL from <linux/mm.h>."
                issues=$((issues + 1))
            fi
            if grep -q "\bvma_is_hugetlb\b" "$kdir/include/linux/mm.h" && [[ ! -f "$kdir/include/linux/hugetlb_inline.h" ]]; then
                warn "Kernel ${TARGET_KVER} removed is_vm_hugetlb_page() in favor of vma_is_hugetlb()."
                issues=$((issues + 1))
            fi
        fi
    else
        warn "Kernel devel directory ${kdir} not found (is kernel-devel-${TARGET_KVER} installed?)."
        issues=$((issues + 1))
    fi

    # 3. Check akmods source RPM status
    local srpm
    srpm="$(readlink -f /usr/src/akmods/nvidia-kmod.latest 2>/dev/null || true)"
    if [[ ! -f "$srpm" ]]; then
        srpm="$(ls -1 /usr/src/akmods/nvidia-kmod-*.src.rpm 2>/dev/null | tail -n 1 || true)"
    fi
    if [[ -f "$srpm" ]]; then
        if rpm2cpio "$srpm" 2>/dev/null | cpio -it 2>/dev/null | grep -q "nvidia-uvm-linux-7.4-vm-special-hugetlb.patch"; then
            ok "akmods source RPM ($(basename "$srpm")) has Linux 7.4 compatibility patches."
        else
            warn "akmods source RPM ($(basename "$srpm")) lacks Linux 7.4 compatibility patches."
            issues=$((issues + 1))
        fi
    fi

    # 4. Check akmods failure logs
    if compgen -G "/var/cache/akmods/nvidia/*for-${TARGET_KVER}.failed.log" >/dev/null 2>&1; then
        warn "Found failed akmods build log for ${TARGET_KVER}:"
        grep -E "fatal error:|error:" /var/cache/akmods/nvidia/*for-"${TARGET_KVER}".failed.log 2>/dev/null | head -n 5 | sed 's/^/    /' || true
        issues=$((issues + 1))
    fi

    # 5. Check journal for kwin_wayland_drm ERANGE
    if journalctl -b 2>/dev/null | grep -q "kwin_wayland_drm: Failed to create framebuffer: Numerical result out of range"; then
        warn "Journal shows 'kwin_wayland_drm: Failed to create framebuffer: Numerical result out of range' (ERANGE)."
        warn "KWin Wayland is running on a headless placeholder screen with no physical outputs."
        issues=$((issues + 1))
    fi

    # 6. Check SDDM theme
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

patch_akmods_srpm() {
    local srpm
    srpm="$(readlink -f /usr/src/akmods/nvidia-kmod.latest 2>/dev/null || true)"
    if [[ ! -f "$srpm" ]]; then
        srpm="$(ls -1 /usr/src/akmods/nvidia-kmod-*.src.rpm 2>/dev/null | tail -n 1 || true)"
    fi
    [[ -n "$srpm" && -f "$srpm" ]] || return 0

    if rpm2cpio "$srpm" 2>/dev/null | cpio -it 2>/dev/null | grep -q "nvidia-uvm-linux-7.4-vm-special-hugetlb.patch"; then
        ok "akmods source RPM ($(basename "$srpm")) already contains Linux 7.4 compatibility patches."
        return 0
    fi

    info "Patching $(basename "$srpm") with Linux 7.4 compatibility patches..."
    local tmpdir
    tmpdir="$(mktemp -d /tmp/akmod-patch.XXXXXX)"
    pushd "$tmpdir" >/dev/null

    rpm2cpio "$srpm" | cpio -idmv >/dev/null 2>&1

    cp "$SCRIPT_DIR/patches/nvidia-drm-linux-7.4-fbdev-helper.patch" "$tmpdir/"
    cp "$SCRIPT_DIR/patches/nvidia-uvm-linux-7.4-vm-special-hugetlb.patch" "$tmpdir/"

    sed -i '/^Patch0:/a Patch1:        nvidia-drm-linux-7.4-fbdev-helper.patch\nPatch2:        nvidia-uvm-linux-7.4-vm-special-hugetlb.patch' nvidia-kmod.spec
    sed -i '/%patch -P0 -p1/a %patch -P1 -p1\n%patch -P2 -p1' nvidia-kmod.spec
    sed -i '/sed -i.*drm_fb_helper\.h/d' nvidia-kmod.spec

    mkdir -p "$tmpdir/SRPMS"
    rpmbuild --define "%_topdir $tmpdir" --define "%_sourcedir $tmpdir" -bs nvidia-kmod.spec >/dev/null

    local newsrpm
    newsrpm="$(ls -1 "$tmpdir/SRPMS"/nvidia-kmod-*.src.rpm 2>/dev/null | head -n 1)"
    if [[ -f "$newsrpm" ]]; then
        cp -b "$newsrpm" "$srpm"
        ok "Successfully updated $srpm with Linux 7.4 compatibility patches."
    fi

    popd >/dev/null
    rm -rf "$tmpdir"
}

if [[ "$MODE" == "diagnose" ]]; then
    diagnose_system
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    info "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

info "Step 1/6: Ensuring <drm/drm_fb_helper.h> compatibility across installed 7.4+ kernel-devel trees..."
for kdir in /usr/src/kernels/*; do
    [[ -d "$kdir/include/drm" ]] || continue
    if [[ -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
        ln -sf clients/drm_fbdev_helper.h "$kdir/include/drm/drm_fb_helper.h"
        ok "Linked $kdir/include/drm/drm_fb_helper.h -> clients/drm_fbdev_helper.h"
    fi
done

if [[ $INSTALL_HOOK -eq 1 ]]; then
    info "Step 2/6: Installing persistent kernel compatibility hooks..."
    
    # 1. Fedora kernel-install hook (systemd-boot / kernel-install)
    mkdir -p /etc/kernel/install.d
    cat <<'HOOK' > /etc/kernel/install.d/90-nvidia-drm-fb-helper-compat.install
#!/usr/bin/bash
# Automatically links <drm/drm_fb_helper.h> to <drm/clients/drm_fbdev_helper.h>
# on Linux 7.4+ kernels before akmods (95-akmodsposttrans.install) runs.
KVER="${2:-}"
for kdir in "/usr/src/kernels/${KVER}" "/usr/src/kernels/${KVER}+debug" /usr/src/kernels/*; do
    if [[ -d "$kdir/include/drm" && -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
        ln -sf clients/drm_fbdev_helper.h "$kdir/include/drm/drm_fb_helper.h"
    fi
done
exit 0
HOOK
    chmod 0755 /etc/kernel/install.d/90-nvidia-drm-fb-helper-compat.install
    ok "Installed /etc/kernel/install.d/90-nvidia-drm-fb-helper-compat.install"

    # 2. postinst.d fallback hook
    mkdir -p /etc/kernel/postinst.d
    cat <<'HOOK' > /etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat
#!/usr/bin/env bash
KVER="${1:-}"
for kdir in "/usr/src/kernels/${KVER}" "/usr/src/kernels/${KVER}+debug" /usr/src/kernels/*; do
    if [[ -d "$kdir/include/drm" && -f "$kdir/include/drm/clients/drm_fbdev_helper.h" && ! -e "$kdir/include/drm/drm_fb_helper.h" ]]; then
        ln -sf clients/drm_fbdev_helper.h "$kdir/include/drm/drm_fb_helper.h"
    fi
done
exit 0
HOOK
    chmod 0755 /etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat
    ok "Installed /etc/kernel/postinst.d/99-nvidia-drm-fb-helper-compat"
else
    info "Step 2/6: Skipping kernel hooks installation (--no-hook)."
fi

info "Step 3/6: Patching akmods source package with Linux 7.4 compatibility patches..."
patch_akmods_srpm

info "Step 4/6: Building and installing kmod-nvidia for kernel ${TARGET_KVER}..."
if rpm -q "kmod-nvidia-${TARGET_KVER}" >/dev/null 2>&1; then
    ok "kmod-nvidia-${TARGET_KVER} is already installed."
else
    # Check if a prebuilt matching RPM exists
    local prebuilt_rpm
    prebuilt_rpm="$(find "$SCRIPT_DIR" /home/john/.gemini/antigravity-cli/brain/*/scratch/rpmbuild/RPMS/x86_64 -name "kmod-nvidia-${TARGET_KVER}-*.rpm" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$prebuilt_rpm" && -f "$prebuilt_rpm" ]]; then
        info "Found prebuilt RPM: $(basename "$prebuilt_rpm"). Installing..."
        rpm -Uvh --replacepkgs "$prebuilt_rpm"
        depmod -a "${TARGET_KVER}"
        ok "Installed $(basename "$prebuilt_rpm")."
    else
        rm -f /var/cache/akmods/nvidia/*for-"${TARGET_KVER}".failed.log
        akmods --force --kernels "${TARGET_KVER}"
        depmod -a "${TARGET_KVER}"
        ok "Built and installed kmod-nvidia for ${TARGET_KVER}."
    fi
fi

if [[ $FIX_SDDM_THEME -eq 1 ]] && systemctl is-enabled sddm.service >/dev/null 2>&1; then
    info "Step 5/6: Checking SDDM theme (01-breeze-fedora)..."
    if ! rpm -q sddm-breeze >/dev/null 2>&1; then
        info "Installing sddm-breeze..."
        dnf install -y sddm-breeze
        ok "Installed sddm-breeze."
    else
        ok "SDDM Breeze theme (01-breeze-fedora) is installed."
    fi
else
    info "Step 5/6: Skipping SDDM theme check."
fi

info "Step 6/6: Activating nvidia-drm driver..."
if [[ "${TARGET_KVER}" == "$(uname -r)" ]] && [[ -d /sys/module/nouveau ]]; then
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
