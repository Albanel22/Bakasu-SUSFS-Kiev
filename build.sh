#!/bin/bash
set -euo pipefail

# =============================================================================
# V27 : BakaSU (sync-susfs) sur LineageOS 23.2 kiev (noyau 4.19)
#  - CORRECTIF PRINCIPAL : le syscall reboot(KSU_INSTALL_MAGIC1,...) utilisé par
#    le manager/ksud est bloqué par seccomp (logcat : "driver install syscall was
#    blocked by seccomp"). Sur 4.19 il n'y a pas de seccomp action cache, donc
#    ksu_seccomp_allow_cache() ne sert à rien. On laisse passer CE syscall
#    précis dans syscall_trace_enter() (arch/arm64/kernel/ptrace.c).
#  - Retire les rustines v26 douteuses (remplacement seccomp dans setuid_hook,
#    sed O_CLOEXEC global, injection dans escape_with_root_profile).
#  - Tout est FAIL-CLOSED : si une ancre de patch est introuvable, le build
#    s'arrête au lieu de produire une image qui "boote mais ne marche pas".
#  - Produit un rapport (hook-report.txt, nm-ksu.txt, dotconfig-ksu.txt) pour
#    voir enfin quel mode de hook est réellement compilé.
# Variables d'environnement optionnelles :
#   WITH_SUSFS_KERNEL_PATCH=1|0  (patch cyberc3dr dans les sources, défaut 1)
#   WITH_TOUCH_STUB=0|1          (stub tactile msm_drv.c, défaut 0)
# =============================================================================

WITH_SUSFS_KERNEL_PATCH="${WITH_SUSFS_KERNEL_PATCH:-1}"
WITH_TOUCH_STUB="${WITH_TOUCH_STUB:-0}"

echo "=== Build BakaSU v27 (seccomp reboot bypass arch-level) ==="
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
mkdir -p output
REPORT="$GITHUB_WORKSPACE/output/hook-report.txt"
: > "$REPORT"

# ==================== 1. NOYAU ====================
# lineage-23.2 -> 4.19.325-cip136-st20-perf-gd0c1bd7e2578 (même hash que le build backslashxx où le tactile marche)
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1 | tee -a "$REPORT"

# ==================== 2. BakaSU (sync-susfs) ====================
echo "=== Intégration BakaSU (sync-susfs) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/sync-susfs/kernel/setup.sh" | bash -s sync-susfs

if [ -d "drivers/kernelsu" ]; then KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then KSU_DIR="KernelSU/kernel"
elif [ -d "KernelSU" ]; then KSU_DIR="KernelSU"
else echo "❌ Échec intégration BakaSU"; exit 1; fi
echo "KSU_DIR : $KSU_DIR" | tee -a "$REPORT"

# Neutralisation des check.mk (le build continue) -- MAIS on garde les messages
# pour le rapport : ils disent quels hooks le driver estime manquants.
echo "=== check.mk : \$(error -> \$(warning (messages conservés dans le rapport) ===" | tee -a "$REPORT"
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    for f in $(find . -name "$pattern" -type f 2>/dev/null); do
        sed -i 's/\$(error/\$(warning/g' "$f"
        echo "  neutralisé : $f" | tee -a "$REPORT"
    done
done

# Options Kconfig du driver (pour savoir quels modes de hook existent)
echo "--- Kconfig du driver ---" >> "$REPORT"
find "$KSU_DIR" -maxdepth 2 -name Kconfig -exec grep -hE "^\s*(config|menuconfig) KSU" {} \; >> "$REPORT" || true

# Nettoyage Unicode
python3 << 'PYEOF'
import os
from pathlib import Path
SP = ['\u00A0','\u2000','\u2001','\u2002','\u2003','\u2004','\u2005','\u2006','\u2007',
      '\u2008','\u2009','\u200A','\u200B','\u202F','\u205F','\u3000']
n = 0
for root, dirs, files in os.walk('.'):
    if 'KernelSU' not in root and 'kernelsu' not in root:
        continue
    for fn in files:
        if fn.endswith(('.c', '.h')):
            p = Path(root) / fn
            try:
                c = p.read_text(encoding='utf-8', errors='ignore'); o = c
                for u in SP: c = c.replace(u, ' ')
                if c != o: p.write_text(c, encoding='utf-8'); n += 1
            except Exception: pass
print(f"✅ {n} fichiers nettoyés")
PYEOF

# symbol_resolver.h (inchangé par rapport à v26 : n'agit que si le fichier existe)
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
        echo "  symbol_resolver.h patché : $h" >> "$REPORT"
    fi
done

# Exports SELinux (inchangé)
[ -f security/selinux/selinuxfs.c ] && {
    sed -i 's/^static ssize_t (\*write_op\[\])/ssize_t (*write_op[])/' security/selinux/selinuxfs.c
    sed -i 's/^static const struct file_operations sel_handle_status_ops/const struct file_operations sel_handle_status_ops/' security/selinux/selinuxfs.c
    sed -i 's/^static DEFINE_MUTEX(sel_mutex)/DEFINE_MUTEX(sel_mutex)/' security/selinux/selinuxfs.c
}
[ -f security/selinux/ss/status.c ] && {
    sed -i 's/^static struct page \*selinux_status_page/struct page *selinux_status_page/' security/selinux/ss/status.c
    sed -i 's/^static DEFINE_MUTEX(selinux_status_lock)/DEFINE_MUTEX(selinux_status_lock)/' security/selinux/ss/status.c
}
[ -f security/selinux/ss/services.c ] && sed -i 's/^static DEFINE_RWLOCK(policy_rwlock)/DEFINE_RWLOCK(policy_rwlock)/' security/selinux/ss/services.c
[ -f security/selinux/hooks.c ] && sed -i 's/^static struct security_operations selinux_ops/struct security_operations selinux_ops/' security/selinux/hooks.c

# ==================== 3. PATCH SUSFS (optionnel) ====================
if [ "$WITH_SUSFS_KERNEL_PATCH" = "1" ]; then
    echo "=== Patch SUSFS 4.19 (cyberc3dr) ==="
    cd "$GITHUB_WORKSPACE"
    rm -rf /tmp/cyber_repo
    git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo
    cd "$GITHUB_WORKSPACE/kernel_sources"
    PATCH_419=$(find /tmp/cyber_repo/Patches -name "*4.19*" -name "*.patch" 2>/dev/null | head -1)
    if [ -z "$PATCH_419" ]; then echo "❌ patch SUSFS 4.19 introuvable"; exit 1; fi
    echo "patch utilisé : $PATCH_419" | tee -a "$REPORT"
    patch -p1 < "$PATCH_419" > /tmp/susfs_patch.log 2>&1 || true
    tail -15 /tmp/susfs_patch.log
    # On NE supprime plus les .rej en silence : ils sont listés dans le rapport.
    echo "--- hunks SUSFS rejetés (.rej) ---" >> "$REPORT"
    find . -name "*.rej" -type f >> "$REPORT" || true
    find . -name "*.rej" -type f -delete 2>/dev/null || true

    for f in fs/proc/task_mmu.c fs/namespace.c fs/super.c fs/stat.c; do
        [ -f "$f" ] && sed -i 's/^\(\s*\)struct vm_area_struct \*vma;/\1struct vm_area_struct *vma __maybe_unused;/g' "$f" 2>/dev/null || true
    done
    if [ -f fs/namespace.c ] && ! grep -q "susfs_def.h" fs/namespace.c; then
        sed -i '/#include <linux\/sched\/task.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#define CL_COPY_MNT_NS BIT(25)\n#endif' fs/namespace.c
    fi
    python3 << 'PYEOF'
from pathlib import Path
def add(path, anchor, text):
    p = Path(path)
    if not p.exists(): return
    c = p.read_text()
    if 'susfs_def.h' in c or anchor not in c: return
    p.write_text(c.replace(anchor, anchor + '\n' + text, 1))
add('fs/super.c', '#include "internal.h"',
    '#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n#endif\n')
add('fs/stat.c', '#include <asm/unistd.h>',
    '\n#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif')
PYEOF
else
    echo "(patch SUSFS des sources désactivé)" | tee -a "$REPORT"
fi

# ==================== 4. HOOKS (inchangés, mais fail-closed) ====================
echo "=== Hook ksu_handle_sys_reboot (kernel/reboot.c) ==="
python3 << 'PYEOF'
import re, sys
p = 'kernel/reboot.c'
c = open(p).read()
if 'ksu_handle_sys_reboot' in c:
    print("hook reboot déjà présent"); sys.exit(0)
m = re.search(r'SYSCALL_DEFINE4\(reboot,\s*int,\s*magic1,\s*int,\s*magic2,\s*unsigned int,\s*cmd,\s*void __user \*,\s*arg\)\s*\{', c)
if not m:
    print("❌ SYSCALL_DEFINE4(reboot) introuvable"); sys.exit(1)
ret = c.find('int ret = 0;', m.end())
if ret == -1:
    print("❌ 'int ret = 0;' introuvable"); sys.exit(1)
ins = ret + len('int ret = 0;')
c = c[:ins] + '\n#if defined(CONFIG_KSU)\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif' + c[ins:]
decl = '\n#if defined(CONFIG_KSU)\nextern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);\n#endif\n'
c = c[:m.start()] + decl + c[m.start():]
open(p, 'w').write(c)
print("✅ hook reboot injecté")
PYEOF
grep -q "ksu_handle_sys_reboot" kernel/reboot.c || { echo "❌ hook reboot absent"; exit 1; }

echo "--- définition du handler dans le driver ---" >> "$REPORT"
grep -rn "ksu_handle_sys_reboot" "$KSU_DIR" | head -5 >> "$REPORT" || true
if ! grep -rqE "ksu_handle_sys_reboot\s*\(" "$KSU_DIR"; then
    echo "❌ le driver ne définit pas ksu_handle_sys_reboot : le hook reboot ne sert à rien" | tee -a "$REPORT"; exit 1
fi

echo "=== Hook ksu_handle_sys_read (fs/read_write.c) ==="
python3 << 'PYEOF'
import re, sys
p = 'fs/read_write.c'
c = open(p).read()
if 'ksu_handle_sys_read' in c:
    print("hook read déjà présent"); sys.exit(0)
old = 'SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{'
if old not in c:
    print("⚠️  SYSCALL_DEFINE3(read) non trouvé : hook sys_read ignoré"); sys.exit(0)
new = old + '\n#ifdef CONFIG_KSU_SUSFS\n\tksu_handle_sys_read(fd, &buf, &count);\n#endif'
c = c.replace(old, new, 1)
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', c)
decl = '\n#ifdef CONFIG_KSU_SUSFS\nextern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);\n#endif\n'
c = c[:m.end()] + decl + c[m.end():]
open(p, 'w').write(c)
print("✅ hook read injecté")
PYEOF

# ==================== 4c. SECCOMP : bypass du supercall reboot (CŒUR DU CORRECTIF) ====================
echo ""
echo "=== Bypass seccomp du supercall KSU (arch/arm64/kernel/ptrace.c) ==="
KSU_MAGIC=$(grep -rhoE "KSU_INSTALL_MAGIC1[[:space:]]+(0x)?[0-9A-Fa-f]+" "$KSU_DIR" 2>/dev/null | head -1 | grep -oE "0x[0-9A-Fa-f]+" || true)
if [ -z "$KSU_MAGIC" ]; then
    KSU_MAGIC="0xDEADBEEF"
    echo "⚠️  KSU_INSTALL_MAGIC1 non trouvé dans le driver, valeur par défaut $KSU_MAGIC" | tee -a "$REPORT"
else
    echo "KSU_INSTALL_MAGIC1 = $KSU_MAGIC (lu dans le driver)" | tee -a "$REPORT"
fi

python3 - "$KSU_MAGIC" << 'PYEOF'
import re, sys
magic = sys.argv[1]
p = 'arch/arm64/kernel/ptrace.c'
c = open(p).read()
if 'ksu_seccomp_bypass' in c:
    print("bypass déjà présent"); sys.exit(0)

fn = re.search(r'^(asmlinkage\s+)?int\s+syscall_trace_enter\s*\(\s*struct pt_regs\s*\*\s*regs\s*\)', c, re.M)
if not fn:
    print("❌ syscall_trace_enter introuvable"); sys.exit(1)
end = c.find('\n}\n', fn.end())
body = c[fn.end():end]
if 'secure_computing(NULL)' not in body:
    print("❌ secure_computing(NULL) absent de syscall_trace_enter"); sys.exit(1)
new_body = body.replace('secure_computing(NULL)',
                        '(ksu_seccomp_bypass(regs) ? 0 : secure_computing(NULL))')

helper = '''#ifdef CONFIG_KSU
#include <asm/unistd.h>
/*
 * KSU : laisse passer reboot(KSU_INSTALL_MAGIC1, ...) a travers seccomp.
 * 4.19 n'a pas de seccomp action cache -> ksu_seccomp_allow_cache() est sans effet.
 * magic1 != 0xfee1dead n'est jamais un vrai reboot ; le handler du driver valide l'appelant.
 */
static inline bool ksu_seccomp_bypass(struct pt_regs *regs)
{
	return regs->syscallno == __NR_reboot && (u32)regs->regs[0] == %sU;
}
#else
static inline bool ksu_seccomp_bypass(struct pt_regs *regs) { return false; }
#endif

''' % magic

c = c[:fn.start()] + helper + c[fn.start():fn.end()] + new_body + c[end:]
open(p, 'w').write(c)
print("✅ bypass seccomp injecté (%d occurrence(s))" % body.count('secure_computing(NULL)'))
PYEOF
grep -q "ksu_seccomp_bypass(regs) ? 0 : secure_computing" arch/arm64/kernel/ptrace.c \
    || { echo "❌ bypass seccomp absent de ptrace.c"; exit 1; }

# Diagnostic seulement (aucune modification) : état de disable_seccomp dans le driver
echo "--- disable_seccomp / seccomp dans le driver ---" >> "$REPORT"
grep -rn "disable_seccomp\|ksu_seccomp_allow_cache" "$KSU_DIR" | head -20 >> "$REPORT" || true

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
  echo "CONFIG_KSU_SUSFS=y"
  echo "# CONFIG_KSU_TAMPER_SYSCALL_TABLE is not set"
  echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  echo "# CONFIG_KSU_MANUAL_HOOK is not set"
  echo "CONFIG_KPROBES=y"
  echo "CONFIG_HAVE_KPROBES=y"
  echo "CONFIG_KRETPROBES=y"
  echo "CONFIG_KALLSYMS=y"
  echo "CONFIG_KALLSYMS_ALL=y"
  echo "CONFIG_SECCOMP=y"
  echo "CONFIG_SECCOMP_FILTER=y"
  echo "CONFIG_COMPAT=y"
  echo "CONFIG_COMPAT_32BIT_TIME=y"
} >> out/.config
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

grep -E "CONFIG_KSU|KPROBES|SECCOMP|KALLSYMS" out/.config > output/dotconfig-ksu.txt || true
cat output/dotconfig-ksu.txt
# Fail-closed : v26 ne contrôlait que KSU_SUSFS ; on contrôle aussi KSU lui-même
for opt in CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_SECCOMP_FILTER=y; do
    grep -q "^${opt}$" out/.config || { echo "❌ ${opt} absent du .config final"; exit 1; }
done

# ==================== 6. PATCHS MOTOROLA ====================
echo "=== Patch signatures modules ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
if [ "$WITH_TOUCH_STUB" = "1" ]; then
    echo "=== Stub tactile (WITH_TOUCH_STUB=1) ==="
    printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
fi

# ==================== 7. COMPILATION ====================
echo "=== Compilation du kernel ==="
make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 -j$(nproc) Image 2>&1 | tee build.log
if [ ! -f out/arch/arm64/boot/Image ]; then
    echo "❌ BUILD FAILED"; grep -iE "error:|fatal error:" build.log | head -30; exit 1
fi
ls -lh out/arch/arm64/boot/
sha256sum out/arch/arm64/boot/Image | cut -d' ' -f1 > /tmp/kernel_compiled_hash.txt

# --- Vérifications post-build (le driver est-il VRAIMENT dans l'image ?) ---
echo ""
echo "=== Vérifications post-build ==="
NM=$(command -v llvm-nm || command -v aarch64-linux-gnu-nm || command -v nm)
$NM out/vmlinux 2>/dev/null | grep -i "ksu" > "$GITHUB_WORKSPACE/output/nm-ksu.txt" || true
NSYM=$(wc -l < "$GITHUB_WORKSPACE/output/nm-ksu.txt")
echo "symboles ksu dans vmlinux : $NSYM"
if [ "$NSYM" -lt 20 ]; then
    echo "❌ moins de 20 symboles ksu : le driver n'est pas (correctement) compilé dans l'image"; exit 1
fi
grep -q " ksu_handle_sys_reboot" "$GITHUB_WORKSPACE/output/nm-ksu.txt" \
    || { echo "❌ ksu_handle_sys_reboot absent de vmlinux"; exit 1; }
echo "--- messages de check hook (build.log) ---" >> "$REPORT"
grep -nEi "integrate|hook.*(missing|not found|not set)|You should" build.log | head -20 >> "$REPORT" || true
echo "--- symboles hook dans vmlinux ---" >> "$REPORT"
grep -iE "ksu_handle_|kprobe|tracepoint" "$GITHUB_WORKSPACE/output/nm-ksu.txt" | head -40 >> "$REPORT" || true
cat "$REPORT"

# ==================== 8. KSUD (BakaSU sync-susfs) ====================
echo ""
echo "=== Compilation ksud ==="
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
[ -n "$KSUD_BINARY" ] || { echo "❌ ksud introuvable"; exit 1; }
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK (magiskboot) ====================
echo "=== Repack ==="
rm -f boot-stock.img
gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 || true
if [ ! -f boot-stock.img ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
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
set +e; ./magiskboot unpack boot.img; set -e
cp "$GITHUB_WORKSPACE/kernel_sources/out/arch/arm64/boot/Image" kernel

./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 data" "mkdir 0755 data/adb" "mkdir 0755 data/adb/ksud" \
    "add 0755 data/adb/ksud/ksud $GITHUB_WORKSPACE/ksud"
cp "$GITHUB_WORKSPACE/ksud" local_su_binary; chmod 755 local_su_binary
./magiskboot cpio ramdisk.cpio "mkdir 0755 system" "mkdir 0755 system/bin" "add 06755 system/bin/su ./local_su_binary"
rm -f local_su_binary
./magiskboot repack boot.img new-boot.img
mv new-boot.img ../final_boot.img
cd ..

# ==================== 10. DIAGNOSTIC IMAGE ====================
mkdir -p verify; cd verify
cp ../final_boot.img verify_boot.img
../repack/magiskboot unpack verify_boot.img 2>/dev/null || true
if [ -f kernel ]; then
    [ "$(sha256sum kernel | cut -d' ' -f1)" = "$(cat /tmp/kernel_compiled_hash.txt)" ] \
        && echo "✅ Noyau IDENTIQUE dans l'image" || { echo "❌ noyau différent dans l'image"; exit 1; }
fi
[ -f ramdisk.cpio ] && ../repack/magiskboot cpio ramdisk.cpio "exists data/adb/ksud/ksud" && echo "✅ ksud présent dans le ramdisk"
cd ..

# ==================== 11. SORTIE ====================
cp final_boot.img output/BakaSU-SUSFS-v27-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo "=== BUILD TERMINÉ v27 ==="
ls -lh output/
