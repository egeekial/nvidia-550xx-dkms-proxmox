#!/bin/bash
# apply-patches-proxmox.sh
#
# Patches NVIDIA 550.163.01 DKMS source to compile on Proxmox VE 9
# with Linux kernel 7.0.0-3-pve.
#
# Applies:
#   - Arch Linux AUR patches (cover kernel 6.15 → 6.19 API changes)
#   - Kernel 7.0-specific fixes (VMA locking, __vm_flags removal)
#
# Prerequisites:
#   - nvidia-kernel-dkms 550.163.01 installed via apt
#   - pve-kernel-7.0 + headers installed
#   - This repo synced to the Proxmox host
#   - Run as root
#
# Usage:
#   bash apply-patches-proxmox.sh              # Full run: patch + build
#   bash apply-patches-proxmox.sh --build-only # Skip patching, just rebuild
#   bash apply-patches-proxmox.sh --patch-only # Patch only, no build

set -euo pipefail

DKMS_SRC="/usr/src/nvidia-current-550.163.01"
DKMS_MODULE="nvidia-current"
DKMS_VERSION="550.163.01"
KERNEL_VERSION="${KERNEL_VERSION:-7.0.0-3-pve}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH_PATCHES="$SCRIPT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

MODE="${1:-full}"

# ------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Must run as root"
[ -d "$DKMS_SRC" ] || die "DKMS source not found at $DKMS_SRC"
[ -d "$ARCH_PATCHES" ] || die "Arch patches not found at $ARCH_PATCHES"

for f in 0002-CFLAGS-Set-std-gnu17-for-all-compilation-flags.patch \
         0003-Workaround-nv_vm_flags_-calling-GPL-only-code.patch \
         0004-kernel-open-nvidia-Use-new-timer-functions-for-6.15.patch \
         0005-kernel-nvidia-Fulfill-6.17-fb_create-contract.patch \
         0006-kernel-nvidia-use-new-helper-macros-and-post-removal-in_irq-for-6.19.patch; do
    [ -f "$ARCH_PATCHES/$f" ] || die "Missing Arch patch: $f"
done

# ==================================================================
# PHASE 1: Patch the DKMS source
# ==================================================================
apply_patches() {
    # --------------------------------------------------------------
    # Backup / Restore
    # --------------------------------------------------------------
    if [ ! -d "$DKMS_SRC.bak" ]; then
        log "Creating backup at $DKMS_SRC.bak"
        cp -a "$DKMS_SRC" "$DKMS_SRC.bak"
    else
        warn "Backup exists — restoring clean source for a fresh patch run"
        rm -rf "$DKMS_SRC"
        cp -a "$DKMS_SRC.bak" "$DKMS_SRC"
    fi

    # --------------------------------------------------------------
    # Arch AUR patches (kernel 6.15 → 6.19 compat)
    # Strip-level notes:
    #   0002, 0003 — paths relative to kernel/, so -p1
    #   0004       — paths start with kernel-open/, so -p2
    #   0005, 0006 — paths start with kernel/, so -p2
    # --------------------------------------------------------------
    log "=== Arch AUR patches (6.15–6.19 compat) ==="

    log "  0002: -std=gnu17 for GCC 15"
    patch -Np1 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0002-CFLAGS-Set-std-gnu17-for-all-compilation-flags.patch"

    log "  sed: EXTRA_CFLAGS → ccflags-y in Kbuild"
    sed -i 's/EXTRA_CFLAGS/ccflags-y/g' "$DKMS_SRC/Kbuild"

    log "  0003: nv_vm_flags_set/clear GPL workaround (.c files)"
    patch -Np1 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0003-Workaround-nv_vm_flags_-calling-GPL-only-code.patch"

    log "  0004: timer functions (del_timer_sync → timer_delete_sync)"
    patch -Np2 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0004-kernel-open-nvidia-Use-new-timer-functions-for-6.15.patch"

    log "  0005: DRM fb_create signature for 6.17+"
    patch -Np2 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0005-kernel-nvidia-Fulfill-6.17-fb_create-contract.patch"

    log "  0006: in_irq→in_hardirq, map_resource→map_phys, DRM helpers"
    patch -Np2 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0006-kernel-nvidia-use-new-helper-macros-and-post-removal-in_irq-for-6.19.patch"

    # --------------------------------------------------------------
    # Kernel 7.0-specific fixes (NOT in any Arch patch)
    # --------------------------------------------------------------
    log ""
    log "=== Kernel 7.0 fixes ==="

    # --- Fix A: common/inc/nv-mm.h ---------------------------------
    # __vm_flags was removed from struct vm_area_struct in kernel 7.0.
    # The functions nv_vm_flags_set/clear use ACCESS_PRIVATE(vma, __vm_flags)
    # which fails. Replace with vm_flags_reset() — a non-GPL inline that
    # directly writes vm_flags without calling vma_start_write().
    # ---------------------------------------------------------------
    log "  Fix A: nv-mm.h — ACCESS_PRIVATE(__vm_flags) → vm_flags_reset()"

    NV_MM_H="$DKMS_SRC/common/inc/nv-mm.h"

    # Add linux/version.h at the top (needed for LINUX_VERSION_CODE check)
    if ! grep -q '<linux/version.h>' "$NV_MM_H"; then
        sed -i '1i\#include <linux/version.h>' "$NV_MM_H"
    fi

    # Replace nv_vm_flags_set body
    perl -i -pe 's/^(\s*)ACCESS_PRIVATE\(vma, __vm_flags\) \|= flags;/${1}#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)\n${1}vm_flags_reset(vma, vma->vm_flags | flags);\n${1}#else\n${1}ACCESS_PRIVATE(vma, __vm_flags) |= flags;\n${1}#endif/' "$NV_MM_H"

    # Replace nv_vm_flags_clear body
    perl -i -pe 's/^(\s*)ACCESS_PRIVATE\(vma, __vm_flags\) &= ~flags;/${1}#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)\n${1}vm_flags_reset(vma, vma->vm_flags \& ~flags);\n${1}#else\n${1}ACCESS_PRIVATE(vma, __vm_flags) \&= ~flags;\n${1}#endif/' "$NV_MM_H"

    # Verify
    if grep -q 'ACCESS_PRIVATE(vma, __vm_flags)' "$NV_MM_H"; then
        warn "nv-mm.h still contains ACCESS_PRIVATE(__vm_flags) — fix may be incomplete"
    else
        log "    nv-mm.h patched successfully"
    fi

    # --- Fix B: nvidia/nv-mmap.c -----------------------------------
    # Kernel 7.0 VMA locking API changes:
    #   VMA_LOCK_OFFSET → VM_REFCNT_EXCLUDE_READERS_FLAG (rename)
    #   __is_vma_write_locked(vma, &seq) → __is_vma_write_locked(vma) (1-arg)
    #   mm_lock_seq now obtained via __vma_raw_mm_seqnum(vma)
    # ---------------------------------------------------------------
    log "  Fix B: nv-mmap.c — VMA locking API (VMA_LOCK_OFFSET, __is_vma_write_locked)"

    NV_MMAP="$DKMS_SRC/nvidia/nv-mmap.c"

    # Step 1: Rename VMA_LOCK_OFFSET → NV_VMA_LOCK_OFFSET in existing code
    sed -i 's/VMA_LOCK_OFFSET/NV_VMA_LOCK_OFFSET/g' "$NV_MMAP"

    # Step 2: Replace __is_vma_write_locked(vma, &mm_lock_seq)
    #         → nv_compat_is_vma_write_locked(vma, &mm_lock_seq)
    sed -i 's/__is_vma_write_locked(vma, &mm_lock_seq)/nv_compat_is_vma_write_locked(vma, \&mm_lock_seq)/g' "$NV_MMAP"

    # Step 3: Insert compat shim after nv_speculation_barrier.h include.
    # The shim defines NV_VMA_LOCK_OFFSET and nv_compat_is_vma_write_locked
    # with version-conditional implementations.
    sed -i '/#include "nv_speculation_barrier.h"/r /dev/stdin' "$NV_MMAP" <<'COMPAT_BLOCK'

/* Kernel 7.0 VMA locking compat --------------------------------- */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)

#define NV_VMA_LOCK_OFFSET VM_REFCNT_EXCLUDE_READERS_FLAG

static inline bool nv_compat_is_vma_write_locked(
    struct vm_area_struct *vma, unsigned int *mm_lock_seq)
{
    *mm_lock_seq = __vma_raw_mm_seqnum(vma);
    return __is_vma_write_locked(vma);
}

#else /* < 7.0 */

#define NV_VMA_LOCK_OFFSET VMA_LOCK_OFFSET

static inline bool nv_compat_is_vma_write_locked(
    struct vm_area_struct *vma, unsigned int *mm_lock_seq)
{
    return __is_vma_write_locked(vma, mm_lock_seq);
}

#endif /* KERNEL_VERSION check */
/* --------------------------------------------------------------- */
COMPAT_BLOCK

    # Verify: check that no raw __is_vma_write_locked(vma, &...) calls remain
    # (the compat block's own usage is fine — it's inside an #if/#else)
    if grep -q '__is_vma_write_locked(vma, &' "$NV_MMAP"; then
        warn "nv-mmap.c may still have unpatched __is_vma_write_locked calls"
    else
        log "    nv-mmap.c patched successfully"
    fi

    log ""
    log "=== All patches applied ==="
}

# ==================================================================
# PHASE 2: DKMS rebuild
# ==================================================================
dkms_rebuild() {
    log ""
    log "=== DKMS rebuild for kernel $KERNEL_VERSION ==="

    # Clean old failed state
    log "  Removing old DKMS build state..."
    dkms remove "$DKMS_MODULE/$DKMS_VERSION" -k "$KERNEL_VERSION" 2>/dev/null || true

    # Build
    log "  Building (this may take a minute)..."
    if dkms build "$DKMS_MODULE/$DKMS_VERSION" -k "$KERNEL_VERSION" 2>&1; then
        log "  Build SUCCEEDED"
    else
        local make_log="/var/lib/dkms/$DKMS_MODULE/$DKMS_VERSION/build/make.log"
        echo ""
        die "Build FAILED. Inspect: $make_log
    Hint: Run with --patch-only, inspect the log, fix issues, then --build-only"
    fi

    # Install
    log "  Installing module..."
    dkms install "$DKMS_MODULE/$DKMS_VERSION" -k "$KERNEL_VERSION"

    # Fix dpkg
    log "  Fixing dpkg state..."
    dpkg --configure -a

    # Initramfs
    log "  Updating initramfs..."
    update-initramfs -u -k "$KERNEL_VERSION"

    log ""
    log "=== Done! ==="
    echo ""
    echo "Verify:"
    echo "  dkms status"
    echo ""
    echo "After rebooting into kernel $KERNEL_VERSION:"
    echo "  modprobe nvidia"
    echo "  nvidia-smi"
}

# ==================================================================
# Main
# ==================================================================
case "$MODE" in
    --build-only)
        dkms_rebuild
        ;;
    --patch-only)
        apply_patches
        ;;
    full|"")
        apply_patches
        dkms_rebuild
        ;;
    *)
        echo "Usage: $0 [--patch-only|--build-only]"
        exit 1
        ;;
esac
