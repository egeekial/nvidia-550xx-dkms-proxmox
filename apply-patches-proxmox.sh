#!/bin/bash
# apply-patches-proxmox.sh
#
# Patches NVIDIA 550.163.01 DKMS source to compile on Proxmox VE 9
# with Linux kernel 7.0.2-2-pve.
#
# This Proxmox helper script was created with Claude Code. Review it before
# running it on a production host.
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
KERNEL_VERSION="${KERNEL_VERSION:-7.0.2-2-pve}"

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

for f in 0003-Workaround-nv_vm_flags_-calling-GPL-only-code.patch; do
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

    # 0002 as sed: The Arch patch doesn't apply cleanly to the Proxmox
    # Kbuild (different context). Do the same changes via sed instead.
    log "  0002 (sed): -std=gnu17 in Kbuild + conftest.sh"
    # Kbuild: add -std=gnu17 before first EXTRA_CFLAGS include line
    sed -i '/^EXTRA_CFLAGS += -I\$(src)\/common\/inc/i EXTRA_CFLAGS += -std=gnu17' "$DKMS_SRC/Kbuild"
    # conftest.sh: add -std=gnu17 to test and build cflags
    sed -i 's/TEST_CFLAGS="-E -M/TEST_CFLAGS="-std=gnu17 -E -M/' "$DKMS_SRC/conftest.sh"
    sed -i 's/BASE_CFLAGS="-O2 -D__KERNEL__/BASE_CFLAGS="-std=gnu17 -O2 -D__KERNEL__/' "$DKMS_SRC/conftest.sh"

    log "  sed: EXTRA_CFLAGS → ccflags-y in Kbuild"
    sed -i 's/EXTRA_CFLAGS/ccflags-y/g' "$DKMS_SRC/Kbuild"

    log "  0003: nv_vm_flags_set/clear GPL workaround (.c files)"
    patch -Np1 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0003-Workaround-nv_vm_flags_-calling-GPL-only-code.patch"

    # 0004 as sed: The Arch patch targets kernel-open/ which differs from
    # the closed-source kernel/ tree in Proxmox. Apply the same API changes
    # via sed. Both 6.17 and 7.0 are >= 6.15 so unconditional replacement
    # is safe (timer_delete_sync exists since 6.2, hrtimer_setup since 6.12).
    log "  0004 (sed): timer functions (del_timer_sync → timer_delete_sync)"

    # Ensure linux/version.h is included in affected files
    for f in nvidia-drm/nvidia-drm-os-interface.c \
             nvidia-modeset/nvidia-modeset-linux.c \
             nvidia/nv-nano-timer.c \
             nvidia/nv.c; do
        [ -f "$DKMS_SRC/$f" ] || continue
        if ! grep -q '<linux/version.h>' "$DKMS_SRC/$f"; then
            sed -i '1,/#include/{ /#include/a #include <linux/version.h>
            }' "$DKMS_SRC/$f"
        fi
    done

    # del_timer_sync → timer_delete_sync (same signature, direct rename)
    find "$DKMS_SRC" -name '*.c' -exec grep -l 'del_timer_sync' {} + 2>/dev/null \
        | while read -r f; do
            sed -i 's/del_timer_sync/timer_delete_sync/g' "$f"
            log "    replaced del_timer_sync in $(basename "$f")"
        done

    # hrtimer_init → hrtimer_setup (API changed: callback moved into init call)
    # Old: hrtimer_init(&timer, clock, mode); timer.function = callback;
    # New: hrtimer_setup(&timer, callback, clock, mode);
    if [ -f "$DKMS_SRC/nvidia/nv-nano-timer.c" ]; then
        perl -i -0777 -pe '
            s/hrtimer_init\((&[^,]+),\s*([^,]+),\s*([^)]+)\);\s*\n\s*\S+\.function\s*=\s*([^;]+);/hrtimer_setup($1, $4,\n                  $2, $3);/g
        ' "$DKMS_SRC/nvidia/nv-nano-timer.c"
        if ! grep -q 'hrtimer_init' "$DKMS_SRC/nvidia/nv-nano-timer.c"; then
            log "    replaced hrtimer_init in nv-nano-timer.c"
        else
            warn "    hrtimer_init may still exist in nv-nano-timer.c (check if it's behind a conftest guard)"
        fi
    fi

    # 0005 (skip): DRM fb_create changes already applied by Debian/Proxmox
    log "  0005 (skip): fb_create already patched by Debian"

    # 0006 (sed): targeted fixes from the Arch 0006 patch
    log "  0006 (sed): in_irq→in_hardirq, map_resource→map_phys, NV_MEMDBG, drm_print, conftest"

    # nv-time.h: add version.h, compat define, in_irq → in_hardirq
    if ! grep -q '<linux/version.h>' "$DKMS_SRC/common/inc/nv-time.h"; then
        sed -i '/#include <linux\/ktime.h>/a #include <linux/version.h>' \
            "$DKMS_SRC/common/inc/nv-time.h"
    fi
    sed -i '/#define NV_MAX_ISR_DELAY_US/i\
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0)\
#define in_hardirq in_irq\
#endif' "$DKMS_SRC/common/inc/nv-time.h"
    sed -i 's/in_irq()/in_hardirq()/g' "$DKMS_SRC/common/inc/nv-time.h"
    log "    nv-time.h patched"

    # os-interface.c: in_irq → in_hardirq
    sed -i 's/in_irq()/in_hardirq()/g' "$DKMS_SRC/nvidia/os-interface.c"
    log "    os-interface.c patched"

    # nv-dma.c: map_resource → map_phys (>= 6.19)
    if ! grep -q '<linux/version.h>' "$DKMS_SRC/nvidia/nv-dma.c"; then
        sed -i '/#include "nv-reg.h"/a #include <linux/version.h>' \
            "$DKMS_SRC/nvidia/nv-dma.c"
    fi
    sed -i 's/return (ops->map_resource != NULL);/#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 19, 0)\n    return (ops->map_phys != NULL);\n#else\n    return (ops->map_resource != NULL);\n#endif/' \
        "$DKMS_SRC/nvidia/nv-dma.c"
    log "    nv-dma.c patched"

    # nv-memdbg.h: empty macros → while(0) to avoid -Wempty-body
    sed -i 's/^#define NV_MEMDBG_ADD(ptr, size) *$/#define NV_MEMDBG_ADD(ptr, size) while(0)/' \
        "$DKMS_SRC/common/inc/nv-memdbg.h"
    sed -i 's/^#define NV_MEMDBG_REMOVE(ptr, size) *$/#define NV_MEMDBG_REMOVE(ptr, size) while(0)/' \
        "$DKMS_SRC/common/inc/nv-memdbg.h"
    log "    nv-memdbg.h patched"

    # nvidia-drm-priv.h: add drm_print.h (removed from drm_mm.h in 6.19+)
    if ! grep -q 'drm/drm_print.h' "$DKMS_SRC/nvidia-drm/nvidia-drm-priv.h"; then
        sed -i '/#include "nvidia-drm-os-interface.h"/i #include <drm/drm_print.h>' \
            "$DKMS_SRC/nvidia-drm/nvidia-drm-priv.h"
    fi
    log "    nvidia-drm-priv.h patched"

    # conftest.sh: -fms-extensions (kernel 6.19+ uses MS extensions in headers)
    sed -i 's/BASE_CFLAGS="-std=gnu17 -O2/BASE_CFLAGS="-std=gnu17 -fms-extensions -O2/' \
        "$DKMS_SRC/conftest.sh"
    # conftest.sh: _Generic vm_flags check (replaces offsetof __vm_flags)
    if grep -q 'offsetof(struct vm_area_struct, __vm_flags)' "$DKMS_SRC/conftest.sh"; then
        perl -i -pe 's/return offsetof\(struct vm_area_struct, __vm_flags\);/struct vm_area_struct vma;\n                return _Generic(\&vma.vm_flags, const typeof(vma.vm_flags) *: 1);/' \
            "$DKMS_SRC/conftest.sh"
    fi
    log "    conftest.sh patched"

    # nvidia-dma-fence-helper.h: kernel 7.0+ made dma_fence_signal(_locked)
    # return void. The old sed-based fix ("return 0;") always returned success
    # regardless of fence state, silently dropping error propagation. Replace
    # with a proper patch that preserves signal-state semantics via
    # READ_ONCE(seqno)==signaled.
    log "  0007 (patch): fix dma_fence_signal/signal_locked return semantics"
    patch -Np1 --no-backup-if-mismatch -d "$DKMS_SRC" \
        < "$ARCH_PATCHES/0007-kernel-7.0-fix-dma-fence-signal-semantics.patch"
    log "    nvidia-dma-fence-helper.h patched"

    # nvidia-drm-helper.h: .state → .new_state in DRM atomic macros
    # Kernel 7.0 removed .state from __drm_crtcs_state / __drm_connnectors_state /
    # __drm_planes_state; .new_state exists since kernel 4.12
    sed -i 's/__i\]\.state, 1/__i].new_state, 1/g' \
        "$DKMS_SRC/nvidia-drm/nvidia-drm-helper.h"
    log "    nvidia-drm-helper.h patched"

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

    # Replace nv_vm_flags_set body — idempotent: check for vm_flags_reset already present
    if ! grep -q 'vm_flags_reset.*vm_flags | flags' "$NV_MM_H"; then
        perl -i -pe 's/^(\s*)ACCESS_PRIVATE\(vma, __vm_flags\) \|= flags;/${1}#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)\n${1}vm_flags_reset(vma, vma->vm_flags | flags);\n${1}#else\n${1}ACCESS_PRIVATE(vma, __vm_flags) |= flags;\n${1}#endif/' "$NV_MM_H"
    else
        log "    nv_vm_flags_set already patched — skipping"
    fi

    # Replace nv_vm_flags_clear body — idempotent: check for vm_flags_reset already present
    if ! grep -q 'vm_flags_reset.*vm_flags & ~flags' "$NV_MM_H"; then
        perl -i -pe 's/^(\s*)ACCESS_PRIVATE\(vma, __vm_flags\) &= ~flags;/${1}#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)\n${1}vm_flags_reset(vma, vma->vm_flags \& ~flags);\n${1}#else\n${1}ACCESS_PRIVATE(vma, __vm_flags) \&= ~flags;\n${1}#endif/' "$NV_MM_H"
    else
        log "    nv_vm_flags_clear already patched — skipping"
    fi

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
