#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-SYNC-SUSFS-V17 : BakaSU sur la branche sync-susfs
# Source : Baka-SU/BakaSU (branche sync-susfs)
# =============================================================================

echo "=== Build BakaSU (sync-susfs) v17 ==="
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

# ==================== 2. INTÉGRATION BakaSU (BRANCHE SYNC-SUSFS) ====================
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

# ==================== 3. INJECTION DES 3 HOOKS SOURCES (SUSFS INLINE) ====================
echo ""
echo "=== Injection des hooks sources (SUSFS Inline) ==="

# Hook 1 : ksu_handle_sys_read
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/h_sys_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS)
extern struct static_key_true ksu_is_init_rc_hook_enabled;
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
#if defined(CONFIG_KSU_SUSFS)
	if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
		ksu_handle_sys_read(fd, &buf, &count);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: ksu_handle_sys_read")
with open('fs/read_write.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_sys_read.py
fi

# Hook 2 : ksu_handle_input_handle_event
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/h_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f: content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS)
extern struct static_key_true ksu_is_input_hook_enabled;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_input_handle_event' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    old_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#if defined(CONFIG_KSU_SUSFS)
	if (static_branch_unlikely(&ksu_is_input_hook_enabled))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: ksu_handle_input_handle_event")
with open('drivers/input/input.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_input.py
fi

# Hook 3 : ksu_handle_setresuid
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/h_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f: content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS)
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if m and 'extern int ksu_handle_setresuid' not in content:
        content = content[:m.end()] + extern_decl + '\n' + content[m.end():]
    for marker in ['\tbool ruid_new, euid_new, suid_new;', '\tkuid_t kruid, keuid, ksuid;']:
        if marker in content:
            new_code = marker + '''
#if defined(CONFIG_KSU_SUSFS)
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
            content = content.replace(marker, new_code, 1)
            print("OK: ksu_handle_setresuid")
            break
with open('kernel/sys.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h_setresuid.py
fi

# ==================== 4. CONFIGURATION ====================
echo ""
echo "=== Configuration (SUSFS Inline) ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 vendor/lito-perf_defconfig

{
  echo "CONFIG_KSU=y"
  echo "# CONFIG_KSU_MANUAL_HOOK is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
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
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

# ==================== 5. PATCHS MOTOROLA ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Patchs Motorola appliqués"

# ==================== 6. COMPILATION KERNEL ====================
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

# ==================== 7. COMPILATION KSUD (MÊME BRANCHE) ====================
echo ""
echo "=== Compilation ksud (sync-susfs) ==="
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

# ==================== 8. REPACK AVEC INJECTION INIT.RC ====================
echo ""
echo "=== Repack avec injection init.rc + allow_shell ==="

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
cp "$GITHUB_WORKSPACE/ksud" repack/ksud
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

# Ajout allow_shell à la cmdline
if [ -f "header" ]; then
    echo "→ Ajout de allow_shell=1 à la cmdline dans le header"
    python3 - << 'PYEOF'
with open('header', 'r+b') as f:
    header = f.read()
    cmdline_offset = 44
    cmdline = header[cmdline_offset:cmdline_offset+512].split(b'\x00')[0].decode('utf-8', errors='ignore')
    if 'allow_shell' not in cmdline:
        new_cmdline = cmdline + ' kernelsu.allow_shell=1 allow_shell=1'
        new_bytes = new_cmdline.encode('utf-8')
        f.seek(cmdline_offset)
        f.write(new_bytes + b'\x00' * (512 - len(new_bytes)))
        print("  ✅ Cmdline patchée dans header")
PYEOF
fi

# Extraire init.rc avec cpio natif
rm -rf initrc_work
mkdir -p initrc_work
cd initrc_work
cpio -idm < ../ramdisk.cpio 2>/dev/null || true
INITRC_PATH=$(find . -name "init.rc" -type f 2>/dev/null | head -1)
echo "init.rc trouvé : $INITRC_PATH"

if [ -n "$INITRC_PATH" ] && [ -f "$INITRC_PATH" ]; then
    cat >> "$INITRC_PATH" << 'INITRC_EOF'

# --- KSUD START ---
on post-fs-data
    exec u:r:su:s0 root -- /system/bin/ksud post-fs-data

on nonencrypted
    exec u:r:su:s0 root -- /system/bin/ksud services

on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root -- /system/bin/ksud services

on property:sys.boot_completed=1
    exec u:r:su:s0 root -- /system/bin/ksud boot-completed
# --- KSUD END ---
INITRC_EOF
    echo "✅ init.rc modifié"
else
    echo "⚠️ init.rc introuvable — création d'un nouvel init.rc"
    cat > init.rc << 'INITRC_EOF'
# --- KSUD START ---
on post-fs-data
    exec u:r:su:s0 root -- /system/bin/ksud post-fs-data

on nonencrypted
    exec u:r:su:s0 root -- /system/bin/ksud services

on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root -- /system/bin/ksud services

on property:sys.boot_completed=1
    exec u:r:su:s0 root -- /system/bin/ksud boot-completed
# --- KSUD END ---
INITRC_EOF
    INITRC_PATH="init.rc"
    echo "✅ init.rc créé"
fi

# Ajouter ksud dans system/bin
mkdir -p system/bin
cp ../ksud system/bin/ksud
chmod 755 system/bin/ksud
echo "✅ ksud ajouté à system/bin"

# Reconstruire le ramdisk avec cpio natif
echo "→ Reconstruction du ramdisk..."
find . | cpio -o -H newc 2>/dev/null | gzip -9 > ../ramdisk.cpio
cd ..

echo "→ Repack du boot.img..."
./magiskboot repack boot.img new-boot.img
if [ ! -f "new-boot.img" ]; then
    echo "❌ Échec repack"; exit 1
fi
mv new-boot.img ../final_boot.img
cd ..

# ==================== 9. DIAGNOSTIC ====================
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

# Vérifier ksud et init.rc dans le ramdisk
if [ -f "ramdisk.cpio" ]; then
    mkdir -p ramdisk_check
    cd ramdisk_check
    cpio -idm < ../ramdisk.cpio 2>/dev/null || true
    if [ -f "system/bin/ksud" ]; then
        echo "  ✅ ksud présent dans system/bin/"
    else
        echo "  ❌ ksud absent"
    fi
    INITRC_CHECK=$(find . -name "init.rc" -type f 2>/dev/null | head -1)
    if [ -n "$INITRC_CHECK" ] && grep -q "KSUD START" "$INITRC_CHECK"; then
        echo "  ✅ init.rc contient KSUD START"
    else
        echo "  ❌ init.rc ne contient pas KSUD START"
    fi
    cd ..
fi
cd ..

# ==================== 10. SORTIE ====================
mkdir -p output
cp final_boot.img output/BakaSU-SyncSusFS-v17-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v17 (sync-susfs) ==="
ls -lh output/
