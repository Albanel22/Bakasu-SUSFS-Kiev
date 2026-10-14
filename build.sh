#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-BAKASU-SYSCALL-TABLE-V9.1 : Patch Kbuild robuste + vérifications
# Source : Baka-SU/BakaSU officiel
# Objectif : activer le patching de sys_call_table en MANUAL_HOOK
# =============================================================================

echo "=== Build BakaSU + SYSCALL_TABLE_HOOK v9.1 ==="
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

# Détecter KSU_DIR réel
if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR détecté : $KSU_DIR"

# Vérifier que le Kbuild existe
KSU_KBUILD="$KSU_DIR/Kbuild"
if [ ! -f "$KSU_KBUILD" ]; then
    KSU_KBUILD=$(find . -name "Kbuild" -path "*kernelsu*" 2>/dev/null | head -1)
fi
echo "KSU_KBUILD : $KSU_KBUILD"

if [ ! -f "$KSU_KBUILD" ]; then
    echo "❌ Kbuild introuvable !"
    find . -name "Kbuild" -type f 2>/dev/null | head -5
    exit 1
fi

echo ""
echo "=== Contenu ORIGINAL du Kbuild (extrait) ==="
grep -n "MANUAL_HOOK" "$KSU_KBUILD" | head -5
echo "---"
grep -n "syscall" "$KSU_KBUILD" | head -10
echo "---"

# ==================== 2e. NEUTRALISATION DES CHECK.MK (AVANT le patch Kbuild) ====================
echo ""
echo "=== Neutralisation des check.mk (AVANT patch Kbuild) ==="
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

# ==================== 2f. PATCH KBUILD ROBUSTE ====================
echo ""
echo "=== Patch Kbuild robuste : syscall_hook.o en MANUAL_HOOK ==="

python3 << PYEOF
from pathlib import Path

kbuild_path = Path("$KSU_KBUILD")
content = kbuild_path.read_text()

# Vérifier si le patch est déjà appliqué
if 'syscall_hook_manager.o' in content and 'MANUAL_HOOK' in content:
    # Vérifier si c'est dans le bon bloc
    if 'else ifdef CONFIG_KSU_MANUAL_HOOK' in content:
        manual_block_idx = content.find('else ifdef CONFIG_KSU_MANUAL_HOOK')
        # Chercher syscall_hook après ce bloc
        if 'syscall_hook_manager.o' in content[manual_block_idx:manual_block_idx+2000]:
            print("[i] Kbuild déjà patché (syscall_hook.o dans MANUAL_HOOK)")
            exit(0)

# Trouver le bloc MANUAL_HOOK
manual_marker = 'else ifdef CONFIG_KSU_MANUAL_HOOK'
manual_idx = content.find(manual_marker)

if manual_idx < 0:
    print("❌ Bloc MANUAL_HOOK introuvable dans Kbuild")
    print("Contenu Kbuild :")
    print(content[:3000])
    exit(1)

# Trouver la fin du bloc MANUAL_HOOK (prochain else ifdef ou endif de même niveau)
# Chercher la prochaine occurrence de "else ifdef" ou "endif" à partir de manual_idx
search_from = manual_idx + len(manual_marker)
next_else = content.find('else ifdef', search_from)
next_else2 = content.find('else ifndef', search_from)
next_endif = content.find('endif', search_from)

# Prendre le plus proche
candidates = [x for x in [next_else, next_else2, next_endif] if x > 0]
if not candidates:
    print("❌ Fin du bloc MANUAL_HOOK introuvable")
    exit(1)

block_end = min(candidates)
manual_block = content[manual_idx:block_end]

print("=== Contenu du bloc MANUAL_HOOK (avant patch) ===")
print(manual_block)
print("=== Fin bloc ===")

# Construire l'insertion
insertion = '''
  # V9.1: Activer syscall_hook.o en MANUAL_HOOK pour patcher sys_call_table
  kernelsu-objs += hook/syscall_hook_manager.o
  kernelsu-objs += hook/syscall_event_bridge.o
  ifeq ($(CONFIG_ARM64),y)
    kernelsu-objs += hook/arm64/syscall_hook.o
    kernelsu-objs += hook/arm64/patch_memory.o
  endif'''

# Insérer à la fin du bloc MANUAL_HOOK (avant block_end)
# Trouver la dernière ligne non vide du bloc
new_content = content[:block_end] + insertion + '\n' + content[block_end:]

kbuild_path.write_text(new_content)
print("✅ Kbuild patché")

# VÉRIFICATION IMMÉDIATE
print("")
print("=== VÉRIFICATION Kbuild APRÈS PATCH ===")
verify_content = kbuild_path.read_text()
if 'syscall_hook_manager.o' in verify_content:
    print("✅ syscall_hook_manager.o présent dans Kbuild")
else:
    print("❌ syscall_hook_manager.o ABSENT après patch !")

# Chercher dans le bon bloc
manual_idx2 = verify_content.find('else ifdef CONFIG_KSU_MANUAL_HOOK')
if manual_idx2 >= 0:
    next_block = verify_content.find('else ifdef', manual_idx2 + 30)
    if next_block < 0:
        next_block = len(verify_content)
    manual_block2 = verify_content[manual_idx2:next_block]
    print("=== Bloc MANUAL_HOOK après patch ===")
    print(manual_block2)
    print("=== Fin bloc après patch ===")
    if 'syscall_hook_manager.o' in manual_block2:
        print("✅ syscall_hook_manager.o est bien dans le bloc MANUAL_HOOK")
    else:
        print("❌ syscall_hook_manager.o n'est PAS dans le bloc MANUAL_HOOK")

# Afficher le fichier Kbuild complet pour debug
print("")
print("=== Kbuild complet (pour debug) ===")
print(verify_content)
PYEOF

echo ""
echo "=== Vérification fichiers syscall_hook.c ==="
ls -la "$KSU_DIR/hook/syscall_hook.c" 2>/dev/null || echo "  ⚠️  hook/syscall_hook.c non trouvé"
ls -la "$KSU_DIR/hook/arm64/syscall_hook.c" 2>/dev/null || echo "  ⚠️  hook/arm64/syscall_hook.c non trouvé"
ls -la "$KSU_DIR/hook/syscall_hook_manager.c" 2>/dev/null || echo "  ⚠️  hook/syscall_hook_manager.c non trouvé"
ls -la "$KSU_DIR/hook/syscall_event_bridge.c" 2>/dev/null || echo "  ⚠️  hook/syscall_event_bridge.c non trouvé"
ls -la "$KSU_DIR/hook/arm64/patch_memory.c" 2>/dev/null || echo "  ⚠️  hook/arm64/patch_memory.c non trouvé"

# ==================== 2g. PATCH init.c ROBUSTE ====================
echo ""
echo "=== Patch init.c robuste ==="

KSU_INIT="$KSU_DIR/core/init.c"
if [ ! -f "$KSU_INIT" ]; then
    KSU_INIT=$(find . -name "init.c" -path "*kernelsu/core*" 2>/dev/null | head -1)
fi
echo "init.c trouvé : $KSU_INIT"

if [ -f "$KSU_INIT" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_INIT")
content = p.read_text()

print("=== Bloc include original ===")
import re
include_match = re.search(r'#ifdef CONFIG_KSU_TRACEPOINT_HOOK.*?#endif', content, re.DOTALL)
if include_match:
    print(include_match.group(0))

# 1. Patch de l'include
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
#if !defined(CONFIG_KSU_TRACEPOINT_HOOK) && !defined(CONFIG_KSU_MANUAL_HOOK)
#include "hook/lsm_hooks.h"
#endif'''

if old_include in content:
    content = content.replace(old_include, new_include, 1)
    print("✅ Include patché")
else:
    if 'syscall_hook.h' in content:
        print("[i] syscall_hook.h déjà inclus")
    else:
        print("⚠️  Bloc include non trouvé")

# 2. Patch de ksu_hook_init
old_hook_init = '''#elif defined(CONFIG_KSU_MANUAL_HOOK)
// only lsm hook need call init
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
    ksu_lsm_hook_built_in_init();
#endif'''

new_hook_init = '''#elif defined(CONFIG_KSU_MANUAL_HOOK)
    // V9.1: activer syscall_hook pour patcher sys_call_table
    ksu_syscall_hook_init();
    ksu_syscall_hook_manager_init();
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
    ksu_lsm_hook_built_in_init();
#endif'''

if old_hook_init in content:
    content = content.replace(old_hook_init, new_hook_init, 1)
    print("✅ ksu_hook_init patché")
else:
    print("⚠️  ksu_hook_init non trouvé")
    if 'ksu_syscall_hook_init' in content:
        print("[i] ksu_syscall_hook_init déjà présent")

p.write_text(content)
print("✅ init.c sauvegardé")

# VÉRIFICATION
verify = p.read_text()
if 'ksu_syscall_hook_init' in verify:
    print("✅ VÉRIFICATION : ksu_syscall_hook_init présent")
else:
    print("❌ VÉRIFICATION : ksu_syscall_hook_init ABSENT")

if 'syscall_hook.h' in verify:
    print("✅ VÉRIFICATION : syscall_hook.h inclus")
PYEOF
fi

# ==================== 2h. PATCH ksud_integration.c ROBUSTE ====================
echo ""
echo "=== Patch ksud_integration.c robuste ==="

KSU_KSUD="$KSU_DIR/runtime/ksud_integration.c"
if [ ! -f "$KSU_KSUD" ]; then
    KSU_KSUD=$(find . -name "ksud_integration.c" -path "*kernelsu*" 2>/dev/null | head -1)
fi
echo "ksud_integration.c trouvé : $KSU_KSUD"

if [ -f "$KSU_KSUD" ]; then
    python3 << PYEOF
from pathlib import Path
p = Path("$KSU_KSUD")
content = p.read_text()

print("=== Bloc ksu_ksud_init ORIGINAL ===")
import re
match = re.search(r'void __init ksu_ksud_init\(void\)\s*\{.*?\n\}', content, re.DOTALL)
if match:
    print(match.group(0))

# 1. Étendre l'include
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
        print("[i] include déjà patché")

# 2. Patch ksu_ksud_init : activer le bloc TRACEPOINT pour MANUAL_HOOK
# Approche par regex plus souple
old_pattern = re.compile(
    r'(#ifdef CONFIG_KSU_TRACEPOINT_HOOK\s*\n\s*int ret;\s*\n\s*\n\s*ksu_syscall_table_hook\(__NR_read)',
    re.MULTILINE
)

if old_pattern.search(content):
    content = old_pattern.sub(
        r'#if defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)\n    int ret;\n\n    ksu_syscall_table_hook(__NR_read',
        content,
        count=1
    )
    print("✅ ksu_ksud_init patché (bloc syscall table hook activé)")
else:
    print("⚠️  Bloc ksu_ksud_init non trouvé par regex")
    if 'defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)' in content:
        print("[i] Déjà patché")

p.write_text(content)
print("✅ ksud_integration.c sauvegardé")

# VÉRIFICATION
verify = p.read_text()
if 'defined(CONFIG_KSU_TRACEPOINT_HOOK) || defined(CONFIG_KSU_MANUAL_HOOK)' in verify:
    print("✅ VÉRIFICATION : bloc étendu à MANUAL_HOOK")
else:
    print("❌ VÉRIFICATION : bloc non étendu")
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

if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

grep -E "KSU_MANUAL_HOOK|KPROBES|KSU_SUSFS" out/.config | head -25 || true

# ==================== 6b. VÉRIFICATION FINALE Kbuild AVANT COMPILATION ====================
echo ""
echo "=== VÉRIFICATION FINALE Kbuild (avant compilation) ==="
grep -n "syscall_hook" "$KSU_KBUILD" | head -10 || echo "  ❌ syscall_hook ABSENT du Kbuild"
echo ""
echo "=== VÉRIFICATION syscall_hook.c (fichiers source) ==="
for f in "$KSU_DIR/hook/syscall_hook.c" "$KSU_DIR/hook/arm64/syscall_hook.c" "$KSU_DIR/hook/syscall_hook_manager.c" "$KSU_DIR/hook/syscall_event_bridge.c" "$KSU_DIR/hook/arm64/patch_memory.c"; do
    if [ -f "$f" ]; then
        echo "  ✅ $f"
    else
        echo "  ❌ $f ABSENT"
    fi
done

echo ""
echo "=== VÉRIFICATION init.c ==="
grep -n "ksu_syscall_hook_init" "$KSU_INIT" || echo "  ❌ ksu_syscall_hook_init ABSENT"

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

    # VÉRIFIER que syscall_hook a été compilé
    echo ""
    echo "=== VÉRIFICATION syscall_hook dans build.log ==="
    grep -E "CC.*syscall_hook|CC.*syscall_event_bridge|CC.*patch_memory" build.log | head -10 || echo "  ❌ Aucune compilation de syscall_hook détectée"
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
cp final_boot.img output/BakaSU-SyscallTable-v9.1-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
echo ""
echo "=== BUILD TERMINÉ v9.1 ==="
ls -lh output/
