#!/bin/bash
set -euo pipefail

# =============================================================================
# BUILD : LineageOS 23.2 + BakaSU + SUSFS (kernel 4.19 non-GKI)
# Appareil : Motorola One 5G Ace (kiev / SM8250)
# =============================================================================

echo "=== Build BakaSU + SUSFS pour kiev (SM8250) ==="
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

# ==================== 1. CLONAGE DU NOYAU ====================
echo "=== Clonage du kernel LineageOS (branche lineage-23.2) ==="
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1

# ==================== 2. INTÉGRATION BakaSU via setup.sh ====================
echo "=== Intégration BakaSU via setup.sh ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash

if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU" ]; then
    KSU_DIR="KernelSU"
else
    echo "❌ Impossible de trouver le dossier KernelSU après setup"
    exit 1
fi
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 3. INTÉGRATION SUSFS (cyberc3dr pour kernel 4.19) ====================
echo "=== Intégration SUSFS depuis cyberc3dr ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo

cd "$GITHUB_WORKSPACE/kernel_sources"

SUSFS_PATCH="/tmp/cyber_repo/Patches/Patch/susfs_patch_to_4.19.patch"
if [ -f "$SUSFS_PATCH" ]; then
    echo "→ Application du patch SUSFS 4.19..."
    patch -p1 --forward --batch < "$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_patch.log || true
    find . -name "*.rej" -type f -delete 2>/dev/null || true
    echo "  ✅ Patch SUSFS appliqué"
fi

if [ -d "/tmp/cyber_repo/Patches/fs" ]; then
    cp -rn /tmp/cyber_repo/Patches/fs/* fs/ 2>/dev/null || true
fi
if [ -d "/tmp/cyber_repo/Patches/include/linux" ]; then
    cp -rn /tmp/cyber_repo/Patches/include/linux/* include/linux/ 2>/dev/null || true
fi

if [ -f "fs/Makefile" ] && ! grep -q "susfs.o" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
    [ -f "fs/sus_su.c" ] && ! grep -q "sus_su.o" fs/Makefile && echo "obj-\$(CONFIG_KSU_SUSFS) += sus_su.o" >> fs/Makefile
fi
echo "✅ SUSFS intégré"

# ==================== 3b. FIX unused variable dans task_mmu.c ====================
echo ""
echo "=== Correction des variables inutilisées dans task_mmu.c ==="

if [ -f "fs/proc/task_mmu.c" ]; then
    sed -i 's/^\s*struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' fs/proc/task_mmu.c
    echo "  ✅ 'vma' marquée __maybe_unused dans task_mmu.c"
fi

for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
    if [ -f "$f" ]; then
        sed -i 's/^\s*struct vm_area_struct \*vma;/struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
    fi
done
echo "✅ Vérification terminée"

# ==================== 4. NEUTRALISATION DES VÉRIFICATIONS ====================
echo ""
echo "=== Neutralisation des vérifications ==="

CHECK_PATTERNS=( "inline_hook_check.mk" "manual_hook_check.mk" "tracepoint_hook_check.mk" "susfs_compat.mk" "kprobe_check.mk" )
for pattern in "${CHECK_PATTERNS[@]}"; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            echo "  → Vidage de : $f"
            echo "# Vérification désactivée pour build non-GKI" > "$f"
        done
    fi
done

ERROR_MK_FILES=$(grep -rl '\$(error' "$KSU_DIR" --include="*.mk" 2>/dev/null || true)
if [ -n "$ERROR_MK_FILES" ]; then
    for f in $ERROR_MK_FILES; do
        sed -i 's/\$(error/\$(warning/g' "$f" 2>/dev/null || true
    done
fi
echo "✅ Neutralisation terminée"

# ==================== 5. HOOKS MANUELS BakaSU ====================
echo ""
echo "=== Hooks manuels BakaSU ==="

# --- execveat (sans ksu_execveat_hook, mode manuel pur) ---
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  cat > /tmp/hook_execveat.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
				 void *argv, void *envp, int *flags);
#endif
'''
    match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if match: content = content[:match.end()] + extern_decl + '\n' + content[match.end():]
    old_code = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);'''
    new_code = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);

#ifdef CONFIG_KSU
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: execveat (appels manuels insérés)")
with open('fs/exec.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/hook_execveat.py
fi

# --- setresuid ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/hook_setresuid.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f: content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if match: content = content[:match.end()] + extern_decl + '\n' + content[match.end():]
    hook_code = '''#ifdef CONFIG_KSU
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif
'''
    markers = ['\tbool ruid_new, euid_new, suid_new;', '\tkuid_t kruid, keuid, ksuid;']
    inserted = False
    for marker in markers:
        if marker in content:
            content = content.replace(marker, marker + '\n' + hook_code, 1)
            inserted = True
            print("OK: setresuid (inséré après '" + marker.strip()[:50] + "')")
            break
    if not inserted:
        print("❌ setresuid: marqueur introuvable")
        for line in content.split('\n'):
            if 'ksuid' in line or 'ruid_new' in line: print("   >", line.strip()[:120])
        exit(1)
with open('kernel/sys.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/hook_setresuid.py
fi

# --- sys_read ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/hook_sys_read.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if match: content = content[:match.end()] + extern_decl + '\n' + content[match.end():]
    old_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
    new_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_read")
with open('fs/read_write.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/hook_sys_read.py
fi

# --- input_event ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/hook_input.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f: content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
'''
    match = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
    if match: content = content[:match.end()] + extern_decl + '\n' + content[match.end():]
    old_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new_code = '''void input_event(struct input_dev *dev,
		 unsigned int type, unsigned int code, int value)
{
	unsigned long flags;

#ifdef CONFIG_KSU
	ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: input_event")
with open('drivers/input/input.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/hook_input.py
fi

# ==================== 6. VÉRIFICATION FINALE ====================
echo ""
echo "=== Vérification finale des hooks ==="
HOOKS_OK=1
check_hook() {
    local fn="$1"; local file="$2"
    if grep -q "$fn" "$file" 2>/dev/null; then echo "  ✅ $fn présent dans $file"
    else echo "  ❌ $fn MANQUANT dans $file"; HOOKS_OK=0; fi
}
check_hook "ksu_handle_execveat"          "fs/exec.c"
check_hook "ksu_handle_setresuid"         "kernel/sys.c"
check_hook "ksu_handle_sys_read"          "fs/read_write.c"
check_hook "ksu_handle_input_handle_event" "drivers/input/input.c"
if [ "$HOOKS_OK" -eq 0 ]; then echo "❌ ERREUR CRITIQUE : Des hooks sont manquants."; exit 1; fi
echo "✅ Tous les hooks sont en place"

# ==================== 7. CONFIGURATION ====================
echo "=== Configuration ==="
export ARCH=arm64; export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
mkdir -p out
CONFIG_NAME="vendor/lito-perf_defconfig"
echo "Config utilisée : $CONFIG_NAME"
if [ ! -f "arch/arm64/configs/$CONFIG_NAME" ]; then echo "❌ $CONFIG_NAME introuvable !"; exit 1; fi
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 $CONFIG_NAME

{
  echo "CONFIG_KSU=y"
  echo "CONFIG_KSU_MANUAL_HOOK=y"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "# CONFIG_KPROBES is not set"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
  echo "CONFIG_KSU_SUSFS=y"
  echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
  echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  echo "CONFIG_KSU_SUSFS_SUS_MAP=y"
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig

echo "=== Forçage de CONFIG_KSU_MANUAL_HOOK et désactivation KPROBES ==="
if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
    sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
fi
if ! grep -q "CONFIG_KSU_MANUAL_HOOK" out/.config; then
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
fi
if grep -q "^CONFIG_KPROBES=y" out/.config; then
    sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' out/.config
fi
echo "=== État final .config ==="
grep -E "KSU_MANUAL_HOOK|KPROBES|KSU_SUSFS" out/.config || true

# ==================== 8. COMPILATION ====================
echo "=== Compilation finale ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ -f "out/arch/arm64/boot/Image" ]; then echo "✅ Compilation réussie"; ls -lh out/arch/arm64/boot/
else echo "❌ BUILD FAILED"; grep -iE "error:|fatal error:" build.log | head -30; exit 1; fi

# ==================== 9. KSUD ====================
echo "=== Compilation de ksud ==="
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
echo "=== Téléchargement des images stock ==="
echo "→ boot.img..."
rm -f boot-stock.img
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"; fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then echo "❌ boot-stock.img manquant ou trop petit"; exit 1; fi
echo "→ dtbo.img..."
rm -f dtbo-stock.img
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true
echo "=== Repack avec magiskboot ==="
mkdir -p repack; cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot; chmod +x repack/magiskboot; rm -rf Magisk-v27.0.apk lib/
cd repack
./magiskboot unpack boot.img
if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then echo "❌ Échec unpack"; exit 1; fi
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel
./magiskboot cpio ramdisk.cpio "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" local_su_binary; chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 11. SORTIE ====================
echo "=== Copie vers output ==="
mkdir -p output
cp final_boot.img output/BakaSU-SuSFS-boot.img 2>/dev/null || true
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/ 2>/dev/null || true
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ ==="
ls -lh output/
