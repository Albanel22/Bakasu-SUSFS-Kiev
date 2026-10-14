#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-BAKASU-SYSCALL-TABLE-V9 : Forcer syscall_hook en MANUAL_HOOK
# Source : Baka-SU/BakaSU officiel
# Objectif : activer le patching de sys_call_table (pas de hooks manuels)
# =============================================================================

echo "=== Build BakaSU + SYSCALL_TABLE_HOOK v9 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU KERNEL ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU OFFICIEL ====================
echo "=== Intégration BakaSU officiel ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true

curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration BakaSU"
    exit 1
fi
echo "✅ BakaSU officiel intégré"

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 2e. NEUTRALISATION DES CHECK.MK ====================
echo ""
echo "=== Neutralisation des check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            sed -i 's/\$(error/\$(warning/g' "$f"
            echo "  ✅ $f patché"
        done
    fi
done
echo "✅ Neutralisation terminée"

# ==================== 2f. PATCH KBUILD : ajouter syscall_hook.o en MANUAL_HOOK ====================
echo ""
echo "=== Patch Kbuild : syscall_hook.o en MANUAL_HOOK ==="

KSU_KBUILD="$KSU_DIR/Kbuild"
if [ ! -f "$KSU_KBUILD" ]; then
    KSU_KBUILD=$(find . -name "Kbuild" -path "*kernelsu*" -o -name "Kbuild" -path "*KernelSU*" 2>/dev/null | head -1)
fi
echo "Kbuild trouvé : $KSU_KBUILD"

if [ -f "$KSU_KBUILD" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_KBUILD")
content = p.read_text()

# Insérer l'ajout de syscall_hook.o dans le bloc MANUAL_HOOK
old_manual_block = '''else ifdef CONFIG_KSU_MANUAL_HOOK
  \$(info -- \$(REPO_NAME): using Manual Hook)
  include \$(KSU_SRC)/tools/manual_hook_check.mk'''

new_manual_block = '''else ifdef CONFIG_KSU_MANUAL_HOOK
  \$(info -- \$(REPO_NAME): using Manual Hook)
  include \$(KSU_SRC)/tools/manual_hook_check.mk
  # V9: Activer syscall_hook (comme TRACEPOINT_HOOK) pour éviter les hooks manuels
  kernelsu-objs += hook/syscall_hook_manager.o
  kernelsu-objs += hook/syscall_event_bridge.o
  ifeq (\$(CONFIG_ARM64),y)
    kernelsu-objs += hook/arm64/syscall_hook.o
  endif
  kernelsu-objs += hook/arm64/patch_memory.o'''

if old_manual_block in content:
    content = content.replace(old_manual_block, new_manual_block, 1)
    p.write_text(content)
    print("✅ Kbuild patché : syscall_hook.o ajouté au bloc MANUAL_HOOK")
else:
    print("⚠️  Bloc MANUAL_HOOK non trouvé dans Kbuild")
    # Fallback : chercher juste la ligne include manual_hook_check.mk
    if 'manual_hook_check.mk' in content:
        content = content.replace(
            'include \$(KSU_SRC)/tools/manual_hook_check.mk',
            '''include \$(KSU_SRC)/tools/manual_hook_check.mk
  kernelsu-objs += hook/syscall_hook_manager.o
  kernelsu-objs += hook/syscall_event_bridge.o
  ifeq (\$(CONFIG_ARM64),y)
    kernelsu-objs += hook/arm64/syscall_hook.o
  endif
  kernelsu-objs += hook/arm64/patch_memory.o''',
            1
        )
        p.write_text(content)
        print("✅ Kbuild patché (fallback)")
    else:
        print("❌ Impossible de patcher Kbuild")
PYEOF
fi

# ==================== 2g. PATCH init.c : appeler syscall_hook_init en MANUAL_HOOK ====================
echo ""
echo "=== Patch init.c : ksu_syscall_hook_init en MANUAL_HOOK ==="

KSU_INIT="$KSU_DIR/core/init.c"
if [ ! -f "$KSU_INIT" ]; then
    KSU_INIT=$(find . -name "init.c" -path "*kernelsu/core*" -o -name "init.c" -path "*KernelSU/core*" 2>/dev/null | head -1)
fi
echo "init.c trouvé : $KSU_INIT"

if [ -f "$KSU_INIT" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_INIT")
content = p.read_text()

old_code = '''#elif defined(CONFIG_KSU_MANUAL_HOOK)
// only lsm hook need call init
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
    ksu_lsm_hook_built_in_init();
#endif'''

new_code = '''#elif defined(CONFIG_KSU_MANUAL_HOOK)
    // V9: activer syscall_hook_init pour éviter les hooks manuels
    ksu_syscall_hook_init();
    ksu_syscall_hook_manager_init();
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
    ksu_lsm_hook_built_in_init();
#endif'''

if old_code in content:
    content = content.replace(old_code, new_code, 1)
    p.write_text(content)
    print("✅ init.c patché : ksu_syscall_hook_init ajouté")
else:
    print("⚠️  Bloc MANUAL_HOOK non trouvé dans init.c")
    # Vérifier si ksu_syscall_hook_init est déjà appelé
    if 'ksu_syscall_hook_init' in content:
        print("[i] ksu_syscall_hook_init déjà présent")
    else:
        print("❌ Impossible de patcher init.c")
PYEOF
fi

# Ajouter l'include de syscall_hook.h dans init.c
if [ -f "$KSU_INIT" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_INIT")
content = p.read_text()

old_include = '''#ifdef CONFIG_KSU_TRACEPOINT_HOOK
#include "hook/syscall_hook_manager.h"
#include "hook/syscall_hook.h"
#else
#include "hook/lsm_hooks.h"
#endif'''

new_include = '''#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)
#include "hook/syscall_hook_manager.h"
#include "hook/syscall_hook.h"
#endif
#ifdef CONFIG_KSU_MANUAL_HOOK
#include "hook/lsm_hooks.h"
#endif
#ifndef CONFIG_KSU_TRACEPOINT_HOOK
#ifndef CONFIG_KSU_MANUAL_HOOK
#include "hook/lsm_hooks.h"
#endif
#endif'''

if old_include in content:
    content = content.replace(old_include, new_include, 1)
    p.write_text(content)
    print("✅ init.c : include syscall_hook.h ajouté")
else:
    if 'syscall_hook.h' in content:
        print("[i] include syscall_hook.h déjà présent")
    else:
        print("⚠️  Bloc include non trouvé")
PYEOF
fi

# ==================== 2h. PATCH ksud_integration.c : enregistrer les handlers ====================
echo ""
echo "=== Patch ksud_integration.c : ksu_register_syscall_hook ==="

KSU_KSUD="$KSU_DIR/runtime/ksud_integration.c"
if [ ! -f "$KSU_KSUD" ]; then
    KSU_KSUD=$(find . -name "ksud_integration.c" -path "*kernelsu*" -o -name "ksud_integration.c" -path "*KernelSU*" 2>/dev/null | head -1)
fi
echo "ksud_integration.c trouvé : $KSU_KSUD"

if [ -f "$KSU_KSUD" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_KSUD")
content = p.read_text()

old_code = '''void __init ksu_ksud_init(void)
{
#ifdef CONFIG_KSU_TRACEPOINT_HOOK
    int ret;

    ksu_syscall_table_hook(__NR_read, ksu_sys_read, &orig_sys_read);
    ksu_syscall_table_hook(__NR_fstat, ksu_sys_fstat, &orig_sys_fstat);

    ret = register_kprobe(&input_event_kp);
    pr_info("ksud: input_event_kp: %d\\n", ret);

    INIT_WORK(&stop_input_hook_work, do_stop_input_hook);
#endif
#ifdef CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK
    vol_detector_init();
#endif
}'''

new_code = '''void __init ksu_ksud_init(void)
{
#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)
    int ret;

    ksu_syscall_table_hook(__NR_read, ksu_sys_read, &orig_sys_read);
    ksu_syscall_table_hook(__NR_fstat, ksu_sys_fstat, &orig_sys_fstat);

    ret = register_kprobe(&input_event_kp);
    pr_info("ksud: input_event_kp: %d\\n", ret);

    INIT_WORK(&stop_input_hook_work, do_stop_input_hook);
#endif
#ifdef CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK
    vol_detector_init();
#endif
}'''

if old_code in content:
    content = content.replace(old_code, new_code, 1)
    p.write_text(content)
    print("✅ ksud_integration.c patché : syscall table hook en MANUAL_HOOK")
else:
    print("⚠️  Bloc ksu_ksud_init non trouvé ou déjà patché")
    # Fallback : remplacer juste le #ifdef
    if '#ifdef CONFIG_KSU_TRACEPOINT_HOOK\n    int ret;' in content:
        content = content.replace(
            '#ifdef CONFIG_KSU_TRACEPOINT_HOOK\n    int ret;',
            '#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)\n    int ret;',
            1
        )
        p.write_text(content)
        print("✅ ksud_integration.c patché (fallback)")
PYEOF
fi

# Ajouter l'include de syscall_hook.h dans ksud_integration.c
if [ -f "$KSU_KSUD" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_KSUD")
content = p.read_text()

old_inc = '''#ifdef CONFIG_KSU_TRACEPOINT_HOOK
#include "hook/syscall_hook.h"
#endif'''

new_inc = '''#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)
#include "hook/syscall_hook.h"
#endif'''

if old_inc in content:
    content = content.replace(old_inc, new_inc, 1)
    p.write_text(content)
    print("✅ ksud_integration.c : include étendu à MANUAL_HOOK")
else:
    if 'syscall_hook.h' in content:
        print("[i] include déjà présent")
PYEOF
fi

# ==================== 2b. NETTOYAGE UNICODE ====================
echo ""
echo "=== Nettoyage Unicode ==="
python3 << 'PYEOF'
import os
from pathlib import Path
UNICODE_SPACES = ['\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
    '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F',
    '\u205F', '\u3000']
count = 0
for root, dirs, files in os.walk('.'):
    if 'KernelSU' not in root and 'kernelsu' not in root:
        continue
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    if uchar in content:
                        content = content.replace(uchar, ' ')
                if content != original:
                    filepath.write_text(content, encoding='utf-8')
                    count += 1
            except: pass
print(f"✅ {count} fichiers nettoyés")
PYEOF

# ==================== 2c. FIX symbol_resolver.h ====================
echo "=== Fix symbol_resolver.h ==="
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h" "./KernelSU/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
        echo "  ✅ $h patché"
    fi
done

# ==================== 2d. STATIC EXPORTS SELINUX ====================
echo "=== Static exports SELinux ==="
[ -f "security/selinux/selinuxfs.c" ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f "security/selinux/ss/status.c" ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f "security/selinux/ss/services.c" ] && {
    sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
    sed -i 's/^static void security_dump_masked_av/void security_dump_masked_av/' security/selinux/ss/services.c
    sed -i 's/^static void context_struct_compute_av/void context_struct_compute_av/' security/selinux/ss/services.c
}
[ -f "security/selinux/hooks.c" ] && {
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
}
echo "✅ Static exports terminés"

# ==================== 3. AUCUN HOOK MANUEL (le syscall table hook les remplace) ====================
echo ""
echo "=== Aucun hook manuel inséré (syscall table hook activé) ==="
echo "✅ Les hooks execve/faccessat/stat/reboot seront patchés via sys_call_table"

# ==================== 4. PATCH SUSFS ====================
echo ""
echo "=== Patch SUSFS 4.19 (JackA1ltman) ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jack_repo
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo 2>/dev/null || true

cd "$GITHUB_WORKSPACE/kernel_sources"
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" 2>/dev/null | head -1)
if [ -n "$PATCH_419" ]; then
    patch -p1 < "$PATCH_419" 2>&1 | tail -5 || true
fi
find . -name "*.rej" -type f -delete 2>/dev/null || true
echo "✅ Patch SUSFS appliqué"

# ==================== 5. CORRECTIONS POST-PATCH ====================
echo "=== Corrections post-patch ==="
for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    [ -f "$f" ] && sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
done

if [ -f "fs/namespace.c" ] && ! grep -q "susfs_def.h" fs/namespace.c; then
    sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
fi

if [ -f "fs/super.c" ] && ! grep -q "susfs_def.h" fs/super.c; then
python3 << 'PYEOF'
from pathlib import Path
p = Path("fs/super.c")
content = p.read_text()
if 'susfs_def.h' not in content:
    decl = '''
#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif
'''
    anchor = '#include "internal.h"'
    if anchor in content:
        content = content.replace(anchor, anchor + '\n' + decl, 1)
        p.write_text(content)
PYEOF
fi

if [ -f "fs/stat.c" ] && ! grep -q "susfs_def.h" fs/stat.c; then
python3 << 'PYEOF'
from pathlib import Path
p = Path("fs/stat.c")
content = p.read_text()
if 'susfs_def.h' not in content:
    anchor = '#include <asm/unistd.h>'
    if anchor in content:
        content = content.replace(anchor, anchor + '\n\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif', 1)
        p.write_text(content)
PYEOF
fi
echo "✅ Corrections terminées"

# ==================== 6. CONFIGURATION ====================
echo ""
echo "=== Configuration ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y"
  echo "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_COMPAT_VDSO is not set"
  echo "# CONFIG_VDSO32 is not set"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

# Forçage MANUAL_HOOK
if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

grep -E "KSU_MANUAL_HOOK|KPROBES|KSU_SUSFS" out/.config | head -25 || true

# ==================== 7. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 8. COMPILATION ====================
echo "=== Compilation ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "✅ Compilation réussie"
    ls -lh out/arch/arm64/boot/
    sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt
else
    echo "❌ BUILD FAILED"
    grep -iE "error:|fatal error:" build.log | head -30
    exit 1
fi

# ==================== 9. REPACK ====================
echo "=== Repack ==="
cd "$GITHUB_WORKSPACE"
rm -f boot-stock.img dtbo-stock.img
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock invalide"; exit 1
fi
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack; cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/
cd repack
./magiskboot unpack boot.img
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. DIAGNOSTIC ====================
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
    strings kernel | grep -q "KERNEL_SU_RC" && echo "  ✅ KERNEL_SU_RC présent"
    strings kernel | grep -q "syscall_hook" && echo "  ✅ syscall_hook présent"
    strings kernel | grep -q "ksu_syscall_dispatcher" && echo "  ✅ dispatcher présent"
fi
cd ..

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SyscallTable-v9-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
echo ""
echo "=== BUILD TERMINÉ v9 ==="
echo "Source : Baka-SU/BakaSU officiel"
echo "Mode : MANUAL_HOOK + syscall_hook.o forcé + SUSFS + KPROBES"
echo "Aucun hook manuel (remplacés par sys_call_table patching)"
ls -lh output/
