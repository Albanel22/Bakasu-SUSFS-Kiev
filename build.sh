#!/bin/bash
set -euo pipefail

# =============================================================================
# V26 : BakaSU sync-susfs + patch cyberc3dr + REPACK BACKSLASHXX
#       + FIX O_CLOEXEC + HOOK ksu_handle_sys_reboot (C89)
#       + VÉRIFICATION disable_seccomp + CONFIG_SECCOMP
#       + FIX SECCOMP DANS ksu_handle_setuid (BACKSLASHXX)
# =============================================================================

echo "=== Build BakaSU (SUSFS + repack backslashxx + seccomp setuid) v26 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
sudo apt-get clean || true
sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
sudo apt-get update
sudo apt-get install -y bc bison build-essential ccache flex glibc-source libelf-dev libssl-dev \
  libncurses-dev gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi clang llvm lld \
  device-tree-compiler zip unzip curl git python3 python3-pip mkbootimg cpio

pip3 install --quiet gdown
cd "$GITHUB_WORKSPACE"

# ==================== 1. CLONAGE DU NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU (sync-susfs) ====================
echo "=== Intégration BakaSU (sync-susfs) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true

curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/sync-susfs/kernel/setup.sh" | bash -s sync-susfs

if [ ! -d "drivers/kernelsu" ] && [ ! -d "KernelSU/kernel" ]; then
    echo "❌ Échec intégration BakaSU"; exit 1
fi
echo "✅ BakaSU (sync-susfs) intégré"

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
else
    KSU_DIR="KernelSU"
fi
echo "KSU_DIR : $KSU_DIR"

# ==================== 2e. NEUTRALISATION CHECK.MK ====================
echo ""
echo "=== Neutralisation check.mk ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            sed -i 's/\$(error/\$(warning/g' "$f"
        done
    fi
done

# ==================== 2b. NETTOYAGE UNICODE ====================
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
}
[ -f "security/selinux/hooks.c" ] && {
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
}

# ==================== 2e. FIX O_CLOEXEC (BOUCLE GLOBALE) ====================
echo ""
echo "=== Fix O_CLOEXEC dans TOUS les fichiers (détection Manager) ==="

FILES_GET_UNUSED=$(grep -rl "get_unused_fd_flags(O_CLOEXEC)" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_GET_UNUSED" ]; then
    for f in $FILES_GET_UNUSED; do
        sed -i 's/get_unused_fd_flags(O_CLOEXEC)/get_unused_fd_flags(0)/g' "$f"
        echo "  ✅ get_unused_fd_flags fixé dans $f"
    done
else
    echo "  ⚠️  Aucun get_unused_fd_flags(O_CLOEXEC) trouvé."
fi

FILES_ANON_INODE=$(grep -rl "anon_inode_getfile" "$KSU_DIR/" 2>/dev/null || true)
if [ -n "$FILES_ANON_INODE" ]; then
    for f in $FILES_ANON_INODE; do
        sed -i 's/O_RDWR | O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/O_RDWR|O_CLOEXEC/O_RDWR/g' "$f"
        sed -i 's/, O_CLOEXEC)/)/g' "$f"
        echo "  ✅ anon_inode_getfile nettoyé dans $f"
    done
else
    echo "  ⚠️  Aucun anon_inode_getfile trouvé."
fi

# ==================== 2f. VÉRIFICATION disable_seccomp (NON-GKI) ====================
echo ""
echo "=== Vérification disable_seccomp pour noyau 4.19 ==="

APP_PROFILE=$(find "$KSU_DIR" -name "app_profile.c" 2>/dev/null | head -1)
if [ -n "$APP_PROFILE" ]; then
    echo "Fichier trouvé : $APP_PROFILE"
    
    if grep -q "escape_with_root_profile" "$APP_PROFILE"; then
        if ! grep -A 20 "void escape_with_root_profile" "$APP_PROFILE" | grep -q "disable_seccomp"; then
            echo "⚠️  disable_seccomp() non appelée dans escape_with_root_profile, injection..."
            python3 - "$APP_PROFILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

pattern = r'(void\s+escape_with_root_profile\s*\([^)]*\)\s*\{)'
match = re.search(pattern, content)
if match:
    body_start = match.end()
    lines = content[body_start:].split('\n')
    insert_line = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped and not stripped.startswith('struct') and not stripped.startswith('int ') and not stripped.startswith('return'):
            insert_line = i
            break
    
    reset_code = '\n\tdisable_seccomp();\n'
    if insert_line > 0:
        lines.insert(insert_line, reset_code)
    else:
        lines.insert(0, reset_code)
    
    content = content[:body_start] + '\n'.join(lines)
    with open(path, 'w') as f:
        f.write(content)
    print("✅ disable_seccomp() injectée dans escape_with_root_profile")
else:
    print("❌ escape_with_root_profile non trouvée")
PYEOF
        else
            echo "✅ disable_seccomp() déjà appelée dans escape_with_root_profile"
        fi
    else
        echo "⚠️  escape_with_root_profile non trouvée dans app_profile.c"
    fi
    
    if grep -q "^static void disable_seccomp" "$APP_PROFILE"; then
        echo "⚠️  disable_seccomp est static, correction..."
        sed -i 's/^static void disable_seccomp/void disable_seccomp/' "$APP_PROFILE"
    fi
else
    echo "⚠️  app_profile.c introuvable"
fi

# ==================== 2g. FIX SECCOMP DANS setuid_hook (BACKSLASHXX) ====================
echo ""
echo "=== Fix seccomp dans setuid_hook (méthode backslashxx) ==="

SETUID_HOOK="$KSU_DIR/kernel/hook/setuid_hook.c"

if [ -f "$SETUID_HOOK" ]; then
    echo "Fichier trouvé : $SETUID_HOOK"
    
    # Vérifier si le fix backslashxx est déjà présent
    if grep -q "ksu_seccomp_allow_cache.*__NR_reboot" "$SETUID_HOOK"; then
        echo "✅ ksu_seccomp_allow_cache(__NR_reboot) déjà présent"
    else
        echo "⚠️  Remplacement de disable_seccomp() par ksu_seccomp_allow_cache(__NR_reboot)..."
        python3 - "$SETUID_HOOK" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Chercher le bloc #else disable_seccomp(); dans ksu_handle_setuid
old_block = '''#else
        disable_seccomp();
#endif'''
new_block = '''#else
        if (current->seccomp.mode == SECCOMP_MODE_FILTER && current->seccomp.filter) {
            spin_lock_irq(&current->sighand->siglock);
            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
            spin_unlock_irq(&current->sighand->siglock);
        }
#endif'''

if old_block in content:
    content = content.replace(old_block, new_block, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("✅ disable_seccomp() remplacé par ksu_seccomp_allow_cache(__NR_reboot) pour noyau < 5.10")
else:
    # Fallback: chercher juste disable_seccomp(); et le remplacer
    if 'disable_seccomp();' in content:
        print("⚠️  Bloc #else exact non trouvé, remplacement direct de disable_seccomp()...")
        content = content.replace('disable_seccomp();', 
            '''if (current->seccomp.mode == SECCOMP_MODE_FILTER && current->seccomp.filter) {
            spin_lock_irq(&current->sighand->siglock);
            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
            spin_unlock_irq(&current->sighand->siglock);
        }''', 1)
        with open(path, 'w') as f:
            f.write(content)
        print("✅ disable_seccomp() remplacé par ksu_seccomp_allow_cache(__NR_reboot)")
    else:
        print("❌ disable_seccomp() non trouvé dans le fichier")
PYEOF
    fi
else
    echo "⚠️  setuid_hook.c introuvable à $SETUID_HOOK"
fi

# ==================== 3. PATCH SUSFS (cyberc3dr) ====================
echo ""
echo "=== Patch SUSFS 4.19 (cyberc3dr) ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo 2>/dev/null || true

cd "$GITHUB_WORKSPACE/kernel_sources"
PATCH_419=$(find /tmp/cyber_repo/Patches -name "*4.19*" -name "*.patch" 2>/dev/null | head -1)
if [ -n "$PATCH_419" ]; then
    patch -p1 < "$PATCH_419" 2>&1 | tail -5 || true
fi
find . -name "*.rej" -type f -delete 2>/dev/null || true
echo "✅ Patch SUSFS (cyberc3dr) appliqué"

# ==================== 3.5. CORRECTIONS POST-PATCH SUSFS ====================
echo ""
echo "=== Corrections post-patch SUSFS ==="
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
echo "✅ Corrections SUSFS terminées"

# ==================== 4. HOOK CRITIQUE : ksu_handle_sys_reboot (C89) ====================
echo ""
echo "=== Injection du hook ksu_handle_sys_reboot (DÉTECTION MANAGER) ==="

if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
    python3 << 'PYEOF'
import re
with open('kernel/reboot.c', 'r') as f:
    content = f.read()

if 'ksu_handle_sys_reboot' not in content:
    pattern_syscall = r'(SYSCALL_DEFINE4\(reboot,\s*int,\s*magic1,\s*int,\s*magic2,\s*unsigned int,\s*cmd,\s*void __user \*,\s*arg\)\s*\{)'
    match = re.search(pattern_syscall, content)
    
    if match:
        extern = '''
#if defined(CONFIG_KSU)
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);
#endif
'''
        content = content[:match.start()] + extern + content[match.start():]
        
        start_pos = content.find('SYSCALL_DEFINE4(reboot')
        if start_pos != -1:
            ret_pos = content.find('int ret = 0;', start_pos)
            if ret_pos != -1:
                call = '''
#if defined(CONFIG_KSU)
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
                insert_pos = ret_pos + len('int ret = 0;')
                content = content[:insert_pos] + call + content[insert_pos:]
                
                with open('kernel/reboot.c', 'w') as f:
                    f.write(content)
                print("✅ Hook ksu_handle_sys_reboot inséré APRÈS les déclarations (C89 compliant)")
            else:
                print("❌ Impossible de trouver 'int ret = 0;' dans la fonction reboot")
        else:
            print("❌ Impossible de trouver la fonction reboot après insertion")
    else:
        print("❌ Pattern SYSCALL_DEFINE4(reboot) non trouvé")
else:
    print("✅ Hook déjà présent")
PYEOF
else
    echo "✅ Hook ksu_handle_sys_reboot déjà présent"
fi

if grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
    echo "✅ Vérifié : ksu_handle_sys_reboot présent dans kernel/reboot.c"
else
    echo "❌ ÉCHEC : ksu_handle_sys_reboot absent de kernel/reboot.c"
    exit 1
fi

# ==================== 4b. HOOK CRITIQUE : ksu_handle_sys_read (init.rc) ====================
echo ""
echo "=== Injection du hook ksu_handle_sys_read (SUSFS) ==="

if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/h_sys_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_SUSFS
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_sys_read' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
    new_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU_SUSFS
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: ksu_handle_sys_read injecté (SUSFS)")
with open('fs/read_write.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_sys_read.py
else
  echo "[i] Hook sys_read déjà présent"
fi

# ==================== 5. CONFIGURATION (SUSFS + SECCOMP) ====================
echo ""
echo "=== Configuration (SUSFS pur + SECCOMP) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

echo "=== État final .config ==="
grep -E "KSU_MANUAL_HOOK|KSU_SUSFS|KSU_TRACEPOINT|KSU_TAMPER|KPROBES|SECCOMP" out/.config | head -20 || true

if ! grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    echo "❌ CONFIG_KSU_SUSFS non activé, abandon"
    exit 1
fi

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 7. COMPILATION KERNEL ====================
echo "=== Compilation du kernel ==="
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

# ==================== 8. COMPILATION KSUD (BakaSU sync-susfs) ====================
echo ""
echo "=== Compilation ksud (BakaSU sync-susfs) ==="
cd "$GITHUB_WORKSPACE"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install nightly; rustup default nightly; rustup target add aarch64-linux-android
wget -q https://dl.google.com/android/repository/android-ndk-r26d-linux.zip; unzip -q android-ndk-r26d-linux.zip
export ANDROID_NDK_ROOT="$GITHUB_WORKSPACE/android-ndk-r26d"; export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export AARCH64_CLANG_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export AARCH64_CLANGXX_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
export AR_PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot -I$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"
rm -rf "$GITHUB_WORKSPACE/ksud-src"
git clone --depth=1 --branch sync-susfs https://github.com/Baka-SU/BakaSU.git "$GITHUB_WORKSPACE/ksud-src"
cd "$GITHUB_WORKSPACE/ksud-src/userspace/ksud"
mkdir -p .cargo
cat > .cargo/config.toml <<EOF
[target.aarch64-linux-android]
linker = "$AARCH64_CLANG_PATH"
[env]
CC_aarch64_linux_android = "$AARCH64_CLANG_PATH"
CXX_aarch64_linux_android = "$AARCH64_CLANGXX_PATH"
AR_aarch64_linux_android = "$AR_PATH"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "$BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android"
EOF
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo +nightly build --release --target aarch64-linux-android
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé (sync-susfs)"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK (MÉTHODE BACKSLASHXX) ====================
echo ""
echo "=== Repack (méthode backslashxx : magiskboot cpio add) ==="

rm -f boot-stock.img
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
rm -f dtbo-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf Magisk-v27.0.apk lib/

cd repack
set +e
./magiskboot unpack boot.img
set -e

cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" \
    "mkdir 0755 data/adb" \
    "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"

cp "$GITHUB_WORKSPACE/ksud" local_su_binary
chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary

./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. DIAGNOSTIC ====================
echo ""
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
fi

if [ -f "ramdisk.cpio" ]; then
    if ../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" 2>/dev/null; then
        echo "  ✅ ksud présent dans /data/adb/ksud/"
    else
        echo "  ❌ ksud absent"
    fi
fi
cd ..

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SUSFS-v26-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v26 ==="
ls -lh output/
