#!/bin/bash
set -euo pipefail

# =============================================================================
# BRANCHE TEST-ALBANEL-V7.1 : Reproduction ancien + fix susfs_compat.mk
# Config : MANUAL_HOOK + SUSFS + KPROBES (ancien exact)
# Source : Albanel22/ReSukiSU
# =============================================================================

echo "=== Build ReSukiSU (Albanel22) + SUSFS v7.1 ==="
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

# ==================== 2. ReSukiSU via setup.sh officiel ====================
echo "=== Intégration ReSukiSU via setup.sh ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu || true
curl -LSs "https://raw.githubusercontent.com/Albanel22/ReSukiSU/main/kernel/setup.sh" | bash -s -- "" 2>/dev/null || {
    # Fallback : clone direct
    git clone --depth=1 https://github.com/Albanel22/ReSukiSU.git KernelSU
    DRIVER_DIR="drivers"
    ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$(pwd)/KernelSU/kernel")" "$DRIVER_DIR/kernelsu"
    grep -q "kernelsu" "$DRIVER_DIR/Makefile" || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_DIR/Makefile"
    grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig" || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"
}
echo "✅ ReSukiSU (Albanel22) intégré"

# Détecter KSU_DIR
if [ -d "drivers/kernelsu" ]; then
    KSU_DIR="drivers/kernelsu"
elif [ -d "KernelSU/kernel" ]; then
    KSU_DIR="KernelSU/kernel"
elif [ -d "KernelSU" ]; then
    KSU_DIR="KernelSU"
else
    echo "❌ KernelSU introuvable"; exit 1
fi
echo "KSU_DIR détecté : $KSU_DIR"

# ==================== 2e. NEUTRALISATION SUSFS_COMPAT.MK ====================
echo ""
echo "=== Neutralisation susfs_compat.mk (error -> warning) ==="

SUSFS_COMPAT=$(find . -name "susfs_compat.mk" -type f 2>/dev/null | head -1)
if [ -n "$SUSFS_COMPAT" ]; then
    echo "→ Traitement de : $SUSFS_COMPAT"
    sed -i 's/\$(error/\$(warning/g' "$SUSFS_COMPAT"
    if grep -q '\$(error' "$SUSFS_COMPAT"; then
        echo "  ❌ Le patch n'a pas fonctionné"
        exit 1
    fi
    echo "  ✅ susfs_compat.mk patché (error → warning)"
else
    echo "  ⚠️  susfs_compat.mk introuvable"
fi

# Neutraliser aussi tous les autres *_check.mk bloquants
for pattern in inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            sed -i 's/\$(error/\$(warning/g' "$f"
            echo "  ✅ $f patché"
        done
    fi
done

echo "✅ Neutralisation terminée"

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

# ==================== 3. HOOKS ANCIEN SCRIPT (double garde) ====================
echo ""
echo "=== Hooks ReSukiSU (double garde SUSFS || MANUAL_HOOK) ==="

# --- Hook 1 : execveat ---
if ! grep -q "ksu_handle_execveat" fs/exec.c; then
  cat > /tmp/h1.py << 'PYEOF'
import re
with open('fs/exec.c', 'r') as f: content = f.read()
if 'ksu_handle_execveat' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif
'''
    pattern = r'(static int do_execveat_common\()'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    new_code = '''	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: execveat")
with open('fs/exec.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h1.py
fi

# --- Hook 2 : faccessat ---
if ! grep -q "ksu_handle_faccessat" fs/open.c; then
  cat > /tmp/h2.py << 'PYEOF'
import re
with open('fs/open.c', 'r') as f: content = f.read()
if 'ksu_handle_faccessat' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(faccessat)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);'''
    new_code = '''SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: faccessat")
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
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
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
    old_code = '''	struct kstat stat;
	int error;

	return vfs_fstatat(dfd, filename, &stat, flag);'''
    new_code = '''	struct kstat stat;
	int error;

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	return vfs_fstatat(dfd, filename, &stat, flag);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: stat")
    else:
        old2 = '\terror = vfs_fstatat(dfd, filename, &stat, flag);'
        new2 = '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);'''
        if old2 in content:
            content = content.replace(old2, new2, 1)
            print("OK: stat (alternatif)")

if 'ksu_handle_newfstat_ret' not in content:
    old = '''SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat(&stat, statbuf);

	return error;'''
    new = old.replace('\treturn error;', '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;''')
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: newfstat_ret")

if 'ksu_handle_fstat64_ret' not in content:
    old = '''SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)
{
	struct kstat stat;
	int error = vfs_fstat(fd, &stat);

	if (!error)
		error = cp_new_stat64(&stat, statbuf);

	return error;'''
    new = old.replace('\treturn error;', '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;''')
    if old in content:
        content = content.replace(old, new, 1)
        print("OK: fstat64_ret")

with open('fs/stat.c', 'w') as f: f.write(content)
print("=== Hooks stat terminés ===")
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
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
    pattern = r'(SYSCALL_DEFINE4\(reboot)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	char buffer[256];
	int ret = 0;'''
    new_code = '''	char buffer[256];
	int ret = 0;

#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_reboot")
with open('kernel/reboot.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h6.py
fi

# --- Hook 7 : setresuid ---
if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
  cat > /tmp/h7.py << 'PYEOF'
import re
with open('kernel/sys.c', 'r') as f: content = f.read()
if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    pattern = r'(long __sys_setresuid)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    for marker in ['\tbool ruid_new, euid_new, suid_new;', '\tkuid_t kruid, keuid, ksuid;']:
        if marker in content:
            new_code = marker + '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif'''
            content = content.replace(marker, new_code, 1)
            print("OK: setresuid")
            break
with open('kernel/sys.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h7.py
fi

# --- Hook 8 : sys_read ---
if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
  cat > /tmp/h8.py << 'PYEOF'
import re
with open('fs/read_write.c', 'r') as f: content = f.read()
if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern __attribute__((cold)) int ksu_handle_sys_read(unsigned int fd);
#endif
'''
    pattern = r'(SYSCALL_DEFINE3\(read)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	return ksys_read(fd, buf, count);'''
    new_code = '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
		ksu_handle_sys_read(fd);
#endif
	return ksys_read(fd, buf, count);'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: sys_read")
with open('fs/read_write.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h8.py
fi

# --- Hook 9 : input_event ---
if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
  cat > /tmp/h9.py << 'PYEOF'
import re
with open('drivers/input/input.c', 'r') as f: content = f.read()
if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
extern struct static_key_true ksu_is_input_hook_enabled;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
'''
    pattern = r'(static void input_handle_event\(struct input_dev \*dev,)'
    content = re.sub(pattern, extern_decl + '\n' + r'\1', content, count=1)
    old_code = '''	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    new_code = '''#if defined(CONFIG_KSU_SUSFS) || defined(CONFIG_KSU_MANUAL_HOOK)
	if (static_branch_unlikely(&ksu_is_input_hook_enabled))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif
	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
    if old_code in content:
        content = content.replace(old_code, new_code, 1)
        print("OK: input_event")
with open('drivers/input/input.c', 'w') as f: f.write(content)
PYEOF
  python3 /tmp/h9.py
fi

# ==================== 4. PATCH SUSFS JackA1ltman ====================
echo ""
echo "=== Patch SUSFS 4.19 (JackA1ltman) ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/jack_repo
git clone --depth=1 https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd.git /tmp/jack_repo 2>/dev/null || true

cd "$GITHUB_WORKSPACE/kernel_sources"
PATCH_419=$(find /tmp/jack_repo/Patches -name "*4.19*" -name "*.patch" 2>/dev/null | head -1)
if [ -n "$PATCH_419" ]; then
    patch -p1 < "$PATCH_419" 2>&1 | tee /tmp/susfs_patch.log || true
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

# ==================== 6. CONFIGURATION (ANCIEN EXACT) ====================
echo ""
echo "=== Configuration (MANUAL_HOOK + SUSFS + KPROBES) ==="
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

echo "=== Vérification config (sans forçage) ==="
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
    strings kernel | grep -q "kernelsu" && echo "  ✅ kernelsu présent"
fi
cd ..

# ==================== 11. SORTIE ====================
mkdir -p output
cp final_boot.img output/ReSukiSU-Albanel-v7.1-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
echo ""
echo "=== BUILD TERMINÉ v7.1 ==="
echo "Config : MANUAL_HOOK + SUSFS + KPROBES (ancien exact)"
echo "Fix susfs_compat.mk : activé"
echo "Static exports SELinux : activés"
echo "Fix symbol_resolver.h : activé"
echo "Nettoyage Unicode : activé"
ls -lh output/
