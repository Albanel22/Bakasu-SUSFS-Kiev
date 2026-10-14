#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-ALBANEL-V6 : 6 hooks seulement (AUTO_* gère les 3 autres)
# Source : Albanel22/ReSukiSU
# Mode : MANUAL_HOOK + AUTO_*_HOOK + KPROBES (sans SUSFS)
# =============================================================================

echo "=== Build ReSukiSU (Albanel22) v6 ==="
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

# ==================== 1. CLONAGE ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION ReSukiSU (Albanel22) ====================
echo "=== Intégration ReSukiSU (Albanel22) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true

git clone --depth=1 https://github.com/Albanel22/ReSukiSU.git KernelSU
if [ ! -d "KernelSU/kernel" ]; then
    echo "❌ KernelSU/kernel introuvable"; exit 1
fi
echo "✅ ReSukiSU (Albanel22) cloné"

DRIVER_DIR="drivers"
ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$(pwd)/KernelSU/kernel")" "$DRIVER_DIR/kernelsu"

if ! grep -q "kernelsu" "$DRIVER_DIR/Makefile"; then
    printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_DIR/Makefile"
fi
if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"; then
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"
fi

KSU_DIR="KernelSU"
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 2b. NETTOYAGE UNICODE ====================
echo ""
echo "=== Nettoyage Unicode ==="

python3 << 'PYEOF'
import os
from pathlib import Path
UNICODE_SPACES = ['\u00A0', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
    '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u200B', '\u202F',
    '\u205F', '\u3000']
count_files = 0
count_fixes = 0
for root, dirs, files in os.walk('KernelSU'):
    for file in files:
        if file.endswith(('.c', '.h')):
            filepath = Path(root) / file
            try:
                content = filepath.read_text(encoding='utf-8', errors='ignore')
                original = content
                for uchar in UNICODE_SPACES:
                    if uchar in content:
                        content = content.replace(uchar, ' ')
                        count_fixes += 1
                if content != original:
                    filepath.write_text(content, encoding='utf-8')
                    count_files += 1
            except Exception as e:
                print(f"  ⚠️  {filepath}: {e}")
print(f"✅ {count_files} fichiers nettoyés, {count_fixes} remplacements")
PYEOF

# ==================== 2c. FIX symbol_resolver.h ====================
echo ""
echo "=== Fix symbol_resolver.h ==="
if [ -f "$KSU_DIR/kernel/infra/symbol_resolver.h" ]; then
    sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$KSU_DIR/kernel/infra/symbol_resolver.h"
    sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$KSU_DIR/kernel/infra/symbol_resolver.h"
    sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$KSU_DIR/kernel/infra/symbol_resolver.h"
    echo "  ✅ 3 static inline commentées"
fi

# ==================== 3. STATIC EXPORTS SELINUX ====================
echo ""
echo "=== Static exports SELinux ==="

if [ -f "security/selinux/selinuxfs.c" ]; then
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
fi
if [ -f "security/selinux/ss/status.c" ]; then
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
fi
if [ -f "security/selinux/ss/services.c" ]; then
    sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
    sed -i 's/^static void security_dump_masked_av/void security_dump_masked_av/' security/selinux/ss/services.c
    sed -i 's/^static void context_struct_compute_av/void context_struct_compute_av/' security/selinux/ss/services.c
fi
if [ -f "security/selinux/hooks.c" ]; then
    sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c
fi
echo "✅ Static exports SELinux terminés"

# ==================== 4. HOOKS MANUELS (6 seulement) ====================
echo ""
echo "=== 6 hooks manuels (AUTO_* gère setresuid/sys_read/input) ==="

# --- Hook 1 : execveat ---
if ! grep -q "ksu_handle_execveat(" fs/exec.c; then
  cat > /tmp/h1.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat(&' not in content and 'ksu_handle_execveat((' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_execveat' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);'''
    new = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &flags);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: 1/6 execveat")
with open('fs/exec.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h1.py
fi

# --- Hook 2 : faccessat ---
if ! grep -q "ksu_handle_faccessat(" fs/open.c; then
  cat > /tmp/h2.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat(&dfd' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_faccessat' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
    new = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: 2/6 faccessat")
with open('fs/open.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h2.py
fi

# --- Hooks 3,4,5 : stat ---
if ! grep -q "ksu_handle_fstat64_ret" fs/stat.c; then
  cat > /tmp/h345.py << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f: content = f.read()
if 'ksu_handle_stat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)

if 'ksu_handle_stat(&dfd' not in content:
    old = '\terror = vfs_fstatat(dfd, filename, &stat, flag);'
    new = '''#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: 3/6 stat")

if 'ksu_handle_newfstat_ret' not in content:
    old = '''	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;'''
    new = '''	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: 4/6 newfstat_ret")

if 'ksu_handle_fstat64_ret' not in content:
    old = '''	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;'''
    new = '''	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: 5/6 fstat64_ret")

with open('fs/stat.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h345.py
fi

# --- Hook 6 : sys_reboot ---
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
  cat > /tmp/h6.py << 'PYEOF'
import re
with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_sys_reboot' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''	char buffer[256];
	int ret = 0;'''
    new = '''	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: 6/6 sys_reboot")
with open('kernel/reboot.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h6.py
fi

# NOTE: PAS de hooks pour setresuid, sys_read, input_event (AUTO_* les gère)

# ==================== 5. CONFIGURATION ====================
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

# ==================== 5b. FORÇAGE ====================
echo "=== Forçage MANUAL_HOOK ==="
if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "^CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi
for opt in KSU_MANUAL_HOOK_AUTO_SETUID_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK; do
    if grep -q "# CONFIG_${opt} is not set" out/.config; then
        sed -i "s/# CONFIG_${opt} is not set/CONFIG_${opt}=y/" out/.config
    fi
    if ! grep -q "^CONFIG_${opt}=y" out/.config; then
        echo "CONFIG_${opt}=y" >> out/.config
    fi
done
if grep -q "# CONFIG_KPROBES is not set" out/.config; then
    sed -i 's/# CONFIG_KPROBES is not set/CONFIG_KPROBES=y/' out/.config
fi
if grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    sed -i 's/^CONFIG_KSU_SUSFS=y/# CONFIG_KSU_SUSFS is not set/' out/.config
fi
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -3

echo "=== Vérification config ==="
for opt in KSU_MANUAL_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK KPROBES; do
    grep -q "^CONFIG_${opt}=y" out/.config && echo "  ✅ CONFIG_${opt}=y" || { echo "  ❌ CONFIG_${opt}"; exit 1; }
done
echo "✅ Config validée"

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs appliqués"

# ==================== 7. COMPILATION ====================
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

# ==================== 8. REPACK ====================
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

# ==================== 9. DIAGNOSTIC ====================
echo "=== DIAGNOSTIC ==="
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ] && echo "✅ Noyau IDENTIQUE"
    strings kernel | grep -q "KERNEL_SU_RC" && echo "  ✅ KERNEL_SU_RC présent"
    strings kernel | grep -q "kernelsu" && echo "  ✅ kernelsu présent"
fi
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/ReSukiSU-Albanel-v6-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
echo ""
echo "=== BUILD TERMINÉ v6 ==="
echo "6 hooks (AUTO_* gère setresuid/sys_read/input)"
ls -lh output/
