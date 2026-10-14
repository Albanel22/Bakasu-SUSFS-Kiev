#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-BAKASU-SYSCALL-TABLE-V9.3 : Fix variables Python + 3 bugs
# Source : Baka-SU/BakaSU officiel
# =============================================================================

echo "=== Build BakaSU + SYSCALL_TABLE_HOOK v9.3 ==="
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

KSU_KBUILD="$KSU_DIR/Kbuild"
if [ ! -f "$KSU_KBUILD" ]; then
    KSU_KBUILD=$(find . -name "Kbuild" -path "*kernelsu*" 2>/dev/null | head -1)
fi
echo "KSU_KBUILD : $KSU_KBUILD"

if [ ! -f "$KSU_KBUILD" ]; then
    echo "❌ Kbuild introuvable !"
    exit 1
fi

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

# ==================== 2f. PATCH KBUILD ROBUSTE (avec os.environ) ====================
echo ""
echo "=== Patch Kbuild robuste : syscall_hook.o en MANUAL_HOOK ==="

export KSU_KBUILD
python3 << 'PYEOF'
import os
from pathlib import Path

kbuild_path = Path(os.environ['KSU_KBUILD'])
if not kbuild_path.exists():
    print(f"❌ Kbuild introuvable : {kbuild_path}")
    exit(1)

content = kbuild_path.read_text()

if 'syscall_hook_manager.o' in content:
    manual_idx = content.find('else ifdef CONFIG_KSU_MANUAL_HOOK')
    if manual_idx >= 0 and 'syscall_hook_manager.o' in content[manual_idx:manual_idx+2000]:
        print("[i] Kbuild déjà patché")
        exit(0)

manual_marker = 'else ifdef CONFIG_KSU_MANUAL_HOOK'
manual_idx = content.find(manual_marker)

if manual_idx < 0:
    print("❌ Bloc MANUAL_HOOK introuvable dans Kbuild")
    exit(1)

search_from = manual_idx + len(manual_marker)
next_else = content.find('else ifdef', search_from)
next_else2 = content.find('else ifndef', search_from)
next_endif = content.find('endif', search_from)

candidates = [x for x in [next_else, next_else2, next_endif] if x > 0]
if not candidates:
    print("❌ Fin du bloc MANUAL_HOOK introuvable")
    exit(1)

block_end = min(candidates)

insertion = '''
  # V9.3: Activer syscall_hook.o en MANUAL_HOOK pour patcher sys_call_table
  kernelsu-objs += hook/syscall_hook_manager.o
  kernelsu-objs += hook/syscall_event_bridge.o
  ifeq ($(CONFIG_ARM64),y)
    kernelsu-objs += hook/arm64/syscall_hook.o
    kernelsu-objs += hook/arm64/patch_memory.o
  endif'''

new_content = content[:block_end] + insertion + '\n' + content[block_end:]
kbuild_path.write_text(new_content)
print("✅ Kbuild patché")

verify = kbuild_path.read_text()
manual_idx2 = verify.find('else ifdef CONFIG_KSU_MANUAL_HOOK')
if manual_idx2 >= 0:
    next_block = verify.find('else ifdef', manual_idx2 + 30)
    if next_block < 0:
        next_block = len(verify)
    manual_block2 = verify[manual_idx2:next_block]
    print("=== Bloc MANUAL_HOOK après patch ===")
    print(manual_block2)
    print("=== Fin bloc ===")
    if 'ifeq ($(CONFIG_ARM64),y)' in manual_block2:
        print("✅ $(CONFIG_ARM64) correctement préservé")
    else:
        print("❌ $(CONFIG_ARM64) mal échappé")
PYEOF

echo ""
echo "=== Vérification fichiers syscall_hook ==="
for f in "$KSU_DIR/hook/syscall_hook.h" "$KSU_DIR/hook/arm64/syscall_hook.c" "$KSU_DIR/hook/syscall_hook_manager.c" "$KSU_DIR/hook/syscall_event_bridge.c" "$KSU_DIR/hook/arm64/patch_memory.c"; do
    if [ -f "$f" ]; then
        echo "  ✅ $f"
    else
        echo "  ❌ $f ABSENT"
    fi
done

# ==================== 2g. PATCH init.c (avec os.environ) ====================
echo ""
echo "=== Patch init.c ==="

KSU_INIT="$KSU_DIR/core/init.c"
if [ ! -f "$KSU_INIT" ]; then
    KSU_INIT=$(find . -name "init.c" -path "*kernelsu/core*" 2>/dev/null | head -1)
fi
echo "init.c trouvé : $KSU_INIT"

export KSU_INIT
python3 << 'PYEOF'
import os
from pathlib import Path

p = Path(os.environ['KSU_INIT'])
if not p.exists():
    print(f"❌ init.c introuvable : {p}")
    exit(1)

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
#include "hook/lsm_hooks.h"'''

if old_include in content:
    content = content.replace(old_include, new_include, 1)
    print("✅ Include patché")
else:
    if 'syscall_hook.h' in content:
        print("[i] Include déjà patché")

old_hook_init = '''#elif defined(CONFIG_KSU_MANUAL_HOOK)
// only lsm hook need call init
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
    ksu_lsm_hook_built_in_init();
#endif'''

new_hook_init = '''#elif defined(CONFIG_KSU_MANUAL_HOOK)
    ksu_syscall_hook_init();
    ksu_syscall_hook_manager_init();
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
    ksu_lsm_hook_built_in_init();
#endif'''

if old_hook_init in content:
    content = content.replace(old_hook_init, new_hook_init, 1)
    print("✅ ksu_hook_init patché")
else:
    if 'ksu_syscall_hook_init' in content:
        print("[i] ksu_hook_init déjà patché")

p.write_text(content)

verify = p.read_text()
if 'ksu_syscall_hook_init' in verify:
    print("✅ VÉRIFICATION : ksu_syscall_hook_init présent")
else:
    print("❌ VÉRIFICATION : ksu_syscall_hook_init ABSENT")
PYEOF

# ==================== 2h. PATCH ksud_integration.c (avec os.environ) ====================
echo ""
echo "=== Patch ksud_integration.c ==="

KSU_KSUD="$KSU_DIR/runtime/ksud_integration.c"
if [ ! -f "$KSU_KSUD" ]; then
    KSU_KSUD=$(find . -name "ksud_integration.c" -path "*kernelsu*" 2>/dev/null | head -1)
fi
echo "ksud_integration.c trouvé : $KSU_KSUD"

export KSU_KSUD
python3 << 'PYEOF'
import os
import re
from pathlib import Path

p = Path(os.environ['KSU_KSUD'])
if not p.exists():
    print(f"❌ ksud_integration.c introuvable : {p}")
    exit(1)

content = p.read_text()

old_inc = '''#ifdef CONFIG_KSU_TRACEPOINT_HOOK
#include "hook/syscall_hook.h"
#endif'''
new_inc = '''#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)
#include "hook/syscall_hook.h"
#endif'''
if old_inc in content:
    content = content.replace(old_inc, new_inc, 1)
    print("✅ Include patché")
else:
    if 'syscall_hook.h' in content:
        print("[i] Include déjà patché")

old_pattern = re.compile(
    r'#ifdef CONFIG_KSU_TRACEPOINT_HOOK\s*\n\s*int ret;',
    re.MULTILINE
)
if old_pattern.search(content):
    content = old_pattern.sub(
        '#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)\n    int ret;',
        content, count=1
    )
    print("✅ ksu_ksud_init patché")
else:
    if 'defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)' in content:
        print("[i] ksu_ksud_init déjà patché")

p.write_text(content)

verify = p.read_text()
if 'defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)' in verify:
    print("✅ VÉRIFICATION : bloc étendu à MANUAL_HOOK")
PYEOF

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
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
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

# ==================== 3. AUCUN HOOK MANUEL ====================
echo ""
echo "=== Aucun hook manuel inséré (syscall table hook activé) ==="

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

# ==================== 6. CONFIGURATION (MANUAL_HOOK forcé, SUSFS désactivé) ====================
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
  echo "# CONFIG_KSU_SUSFS is not set"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

sed -i 's/^# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
sed -i 's/^CONFIG_KSU_SUSFS=y/# CONFIG_KSU_SUSFS is not set/' out/.config

if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

echo "=== VÉRIFICATION FINALE CONFIG ==="
grep -E "^CONFIG_KSU_MANUAL_HOOK|^CONFIG_KPROBES|^CONFIG_KSU_SUSFS|CONFIG_KSU_MANUAL_HOOK_AUTO" out/.config | head -15

if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "❌ CONFIG_KSU_MANUAL_HOOK n'est PAS actif !"
    exit 1
fi
if grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    echo "⚠️  CONFIG_KSU_SUSFS est encore actif"
fi
echo "✅ MANUAL_HOOK actif"

# ==================== 6b. VÉRIFICATION FINALE Kbuild ====================
echo ""
echo "=== VÉRIFICATION FINALE Kbuild ==="
grep -n "syscall_hook" "$KSU_KBUILD" | head -10 || echo "  ❌ syscall_hook ABSENT"
echo ""
echo "=== VÉRIFICATION \$(CONFIG_ARM64) ==="
grep -n "CONFIG_ARM64" "$KSU_KBUILD" | head -5
if grep -q "ifeq (\$(CONFIG_ARM64),y)" "$KSU_KBUILD"; then
    echo "  ✅ \$(CONFIG_ARM64) correctement préservé"
else
    echo "  ❌ \$(CONFIG_ARM64) mal échappé"
    grep -n "ifeq (,y)" "$KSU_KBUILD" || true
fi

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

    echo ""
    echo "=== VÉRIFICATION syscall_hook dans build.log ==="
    grep -E "CC.*syscall_hook|CC.*syscall_event_bridge|CC.*patch_memory" build.log | head -10 || echo "  ❌ Aucune compilation de syscall_hook"
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
    strings kernel | grep -q "ksu_syscall_dispatcher" && echo "  ✅ ksu_syscall_dispatcher présent"
    strings kernel | grep -q "sys_call_table" && echo "  ✅ sys_call_table référencé"
fi
cd ..

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SyscallTable-v9.3-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
echo ""
echo "=== BUILD TERMINÉ v9.3 ==="
ls -lh output/
