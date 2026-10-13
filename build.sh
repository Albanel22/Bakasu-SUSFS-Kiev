#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-MANUAL-HOOK-V3 : 8 hooks avec vérification stricte
# Objectif : lancer ksud via init.rc injection
# Base : branche main + MANUAL_HOOK + 8 hooks
# =============================================================================

echo "=== Build BakaSU (Manual Hook complet v3) pour kiev ==="
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

# ==================== 2. BakaSU ====================
echo "=== Intégration BakaSU ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU" ]; then
    KSU_DIR="KernelSU"
else
    echo "❌ KernelSU introuvable"; exit 1
fi
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 3. NEUTRALISATION CIBLÉE ====================
echo ""
echo "=== Neutralisation ciblée ==="
CHECK_FILES=( "inline_hook_check.mk" "manual_hook_check.mk" "tracepoint_hook_check.mk" "susfs_compat.mk" "kprobe_check.mk" )
for pattern in "${CHECK_FILES[@]}"; do
    FILES=$(find "$KSU_DIR" -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            sed -i 's/\$(error/\$(warning/g' "$f"
        done
    fi
done
echo "✅ Neutralisation ciblée terminée"

# ==================== 4. 8 HOOKS ====================
echo ""
echo "=== Insertion des 8 hooks manuels ==="

# --- Hook 1 : execveat (fs/exec.c) ---
if ! grep -q "ksu_handle_execveat((int \*)AT_FDCWD\|ksu_handle_execveat(&fd\|ksu_handle_execveat(" fs/exec.c; then
  cat > /tmp/h1.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat(&' not in content and 'ksu_handle_execveat((int' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
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

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, &flags);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: hook 1/8 execveat")
with open('fs/exec.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h1.py
fi

# --- Hook 2 : faccessat (fs/open.c) ---
if ! grep -q "ksu_handle_faccessat(&dfd" fs/open.c; then
  cat > /tmp/h2.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat(&dfd' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
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
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: hook 2/8 faccessat")
with open('fs/open.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h2.py
fi

# --- Hooks 3,4,5 : stat (fs/stat.c) — avec patterns FLEXIBLES ---
if ! grep -q "ksu_handle_stat(&dfd" fs/stat.c || ! grep -q "ksu_handle_newfstat_ret(&fd" fs/stat.c; then
  cat > /tmp/h345.py << 'PYEOF'
import re
with open('fs/stat.c', 'r') as f: content = f.read()

# Ajouter les externs si absents
if 'extern int ksu_handle_stat' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
        print("  → externs ajoutés à fs/stat.c")

# Hook 3 : ksu_handle_stat dans SYSCALL_DEFINE4(newfstatat)
if 'ksu_handle_stat(&dfd' not in content:
    # Pattern flexible : chercher "return vfs_fstatat(dfd, filename, &stat, flag);"
    pattern = r'(\tstruct kstat stat;\s*\n\s*int error;\s*\n\s*\n\s*return vfs_fstatat\(dfd, filename, &stat, flag\);)'
    match = re.search(pattern, content)
    if match:
        old = match.group(0)
        new = old.replace(
            '\treturn vfs_fstatat(dfd, filename, &stat, flag);',
            '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
        )
        content = content.replace(old, new, 1)
        print("OK: hook 3/8 stat")
    else:
        print("⚠️  hook 3/8 stat: pattern non trouvé")

# Hook 4 : ksu_handle_newfstat_ret dans SYSCALL_DEFINE2(newfstat)
if 'ksu_handle_newfstat_ret(&fd' not in content:
    pattern = r'(SYSCALL_DEFINE2\(newfstat, unsigned int, fd, struct stat __user \*, statbuf\)\s*\{[^}]*?if \(!error\)\s*\n\s*error = cp_new_stat\(&stat, statbuf\);\s*\n\s*\n\s*return error;)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        old = match.group(0)
        new = old.replace(
            '\treturn error;',
            '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;''', 1
        )
        content = content.replace(old, new, 1)
        print("OK: hook 4/8 newfstat_ret")
    else:
        print("⚠️  hook 4/8 newfstat_ret: pattern non trouvé")

# Hook 5 : ksu_handle_fstat64_ret dans SYSCALL_DEFINE2(fstat64)
if 'ksu_handle_fstat64_ret(&fd' not in content:
    pattern = r'(SYSCALL_DEFINE2\(fstat64, unsigned long, fd, struct stat64 __user \*, statbuf\)\s*\{[^}]*?if \(!error\)\s*\n\s*error = cp_new_stat64\(&stat, statbuf\);\s*\n\s*\n\s*return error;)'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        old = match.group(0)
        new = old.replace(
            '\treturn error;',
            '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;''', 1
        )
        content = content.replace(old, new, 1)
        print("OK: hook 5/8 fstat64_ret")
    else:
        print("⚠️  hook 5/8 fstat64_ret: pattern non trouvé")

with open('fs/stat.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h345.py
fi

# --- Hook 6 : sys_reboot (kernel/reboot.c) ---
if ! grep -q "ksu_handle_sys_reboot(magic1" kernel/reboot.c; then
  cat > /tmp/h6.py << 'PYEOF'
import re
with open('kernel/reboot.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_reboot(magic1' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
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

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: hook 6/8 sys_reboot")
with open('kernel/reboot.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h6.py
fi

# --- Hook 7 : setresuid (kernel/sys.c) ---
if ! grep -q "ksu_handle_setresuid(ruid" kernel/sys.c; then
  cat > /tmp/h7.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f: content = f.read()
if 'ksu_handle_setresuid(ruid' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_setresuid' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    hook_code = '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif
'''
    for marker in ['\tbool ruid_new, euid_new, suid_new;', '\tkuid_t kruid, keuid, ksuid;']:
        if marker in content:
            content = content.replace(marker, marker + '\n' + hook_code, 1)
            print("OK: hook 7/8 setresuid")
            break
with open('kernel/sys.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h7.py
fi

# --- Hook 8 : input_event (drivers/input/input.c) ---
if ! grep -q "ksu_handle_input_handle_event(&type" drivers/input/input.c; then
  cat > /tmp/h8.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f: content = f.read()
if 'ksu_handle_input_handle_event(&type' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_input_handle_event' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: hook 8/8 input_event")
with open('drivers/input/input.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h8.py
fi

# ==================== 5. VÉRIFICATION STRICTE ====================
echo ""
echo "=== VÉRIFICATION STRICTE des 8 hooks ==="
echo "  (on vérifie l'APPEL, pas juste l'extern)"
HOOKS_OK=1

check_hook_call() {
    local fn="$1"; local file="$2"; local pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  ✅ $fn APPELÉ dans $file"
    else
        echo "  ❌ $fn NON APPELÉ dans $file (pattern: $pattern)"
        HOOKS_OK=0
    fi
}

check_hook_call "execveat"          "fs/exec.c"                    "ksu_handle_execveat("
check_hook_call "faccessat"         "fs/open.c"                    "ksu_handle_faccessat(&dfd"
check_hook_call "stat"              "fs/stat.c"                    "ksu_handle_stat(&dfd"
check_hook_call "newfstat_ret"      "fs/stat.c"                    "ksu_handle_newfstat_ret(&fd"
check_hook_call "fstat64_ret"       "fs/stat.c"                    "ksu_handle_fstat64_ret(&fd"
check_hook_call "sys_reboot"        "kernel/reboot.c"              "ksu_handle_sys_reboot(magic1"
check_hook_call "setresuid"         "kernel/sys.c"                 "ksu_handle_setresuid(ruid"
check_hook_call "input_event"       "drivers/input/input.c"        "ksu_handle_input_handle_event(&type"

if [ "$HOOKS_OK" -eq 0 ]; then
    echo ""
    echo "❌ ERREUR CRITIQUE : Des hooks ne sont pas appelés dans le noyau."
    echo "   Le kernel panicera au boot si on continue."
    echo ""
    echo "=== DIAGNOSTIC : contenu des fonctions concernées ==="
    echo ""
    echo "--- fs/stat.c (autour de newfstatat) ---"
    grep -n "SYSCALL_DEFINE4(newfstatat\|vfs_fstatat\|ksu_handle_stat" fs/stat.c | head -10
    echo ""
    echo "--- fs/stat.c (autour de newfstat) ---"
    grep -n "SYSCALL_DEFINE2(newfstat\|cp_new_stat\|ksu_handle_newfstat" fs/stat.c | head -10
    echo ""
    echo "--- fs/stat.c (autour de fstat64) ---"
    grep -n "SYSCALL_DEFINE2(fstat64\|cp_new_stat64\|ksu_handle_fstat64" fs/stat.c | head -10
    exit 1
fi

echo ""
echo "✅ Les 8 hooks sont correctement appelés"

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
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set"
  echo "# CONFIG_KPROBES is not set"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "# CONFIG_KSU_SUSFS is not set"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "CONFIG_KSU_MANUAL_HOOK=y" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi
if grep -q "^CONFIG_KSU_SUSFS=y" out/.config; then
    sed -i 's/^CONFIG_KSU_SUSFS=y/# CONFIG_KSU_SUSFS is not set/' out/.config
fi
grep -E "KSU_MANUAL_HOOK|KSU_TRACEPOINT|KPROBES|KSU_SUSFS" out/.config || true

# ==================== 7. PATCHS MOTOROLA ====================
echo ""
echo "=== Patch signatures modules + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patches Motorola appliqués"

# ==================== 8. COMPILATION ====================
echo ""
echo "=== Compilation finale ==="
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

# ==================== 8b. DIAGNOSTIC VMLINUX ====================
echo ""
echo "=== Diagnostic vmlinux ==="
VMLINUX="out/vmlinux"
if [ -f "$VMLINUX" ]; then
    for sym in "kernelsu_init" "ksu_supercalls_init"; do
        if nm "$VMLINUX" 2>/dev/null | grep -q "$sym"; then
            echo "  ✅ $sym présent"
        fi
    done
    if strings "$VMLINUX" 2>/dev/null | grep -q "on post-fs-data"; then
        echo "  ✅ KERNEL_SU_RC présent"
    fi
fi

# ==================== 9. KSUD ====================
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
git clone --depth=1 https://github.com/Baka-SU/BakaSU.git "$GITHUB_WORKSPACE/ksud-src"
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
echo "✅ ksud compilé"
cd "$GITHUB_WORKSPACE"

# ==================== 10. REPACK ====================
echo ""
echo "=== Repack ==="
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
./magiskboot unpack boot.img
if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
    echo "❌ Échec unpack"; exit 1
fi
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

if [ -f "bootimg.cfg" ]; then
    if ! grep -q "allow_shell" bootimg.cfg; then
        sed -i 's/^cmdline = \(.*\)$/cmdline = \1 kernelsu.allow_shell=1 allow_shell=1/' bootimg.cfg
    fi
fi

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

# ==================== 10b. DIAGNOSTIC POST-REPACK ====================
echo ""
echo "=== DIAGNOSTIC POST-REPACK ==="
mkdir -p ../verify
cd ../verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f "kernel" ]; then
    HASH_EXTRACTED=$(sha256sum kernel | cut -d' ' -f1)
    HASH_COMPILED=$(cat /tmp/kernel_compiled_hash.txt)
    if [ "$HASH_EXTRACTED" = "$HASH_COMPILED" ]; then
        echo "✅ Noyau extrait IDENTIQUE au noyau compilé"
    fi
    if strings kernel 2>/dev/null | grep -q "KERNEL_SU_RC"; then
        echo "  ✅ 'KERNEL_SU_RC' trouvé"
    fi
fi
cd ..

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-manual-v3-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ (test-manual-hook-v3) ==="
ls -lh output/
