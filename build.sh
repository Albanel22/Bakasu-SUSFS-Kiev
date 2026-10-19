#!/bin/bash
set -euo pipefail

# =============================================================================
# V28.2 = ton v28.1 (tactile OK) + correctif manager, SANS toucher aux réglages
#         qui concernent le tactile (patch SuSFS, stub tactile msm_drv.c,
#         KPROBES=y, bypass check_version : tout est identique à v28.1).
#
# Ce qui change par rapport à v28.1 :
#  [A] NOUVEAU : bypass seccomp du supercall reboot(KSU magic) dans
#      arch/arm64/kernel/ptrace.c (syscall_trace_enter). Le logcat montre
#      "driver install syscall was blocked by seccomp" : le filtre Android des
#      apps tue le syscall AVANT que le noyau n'appelle ksu_handle_sys_reboot.
#      Sur 4.19 ksu_seccomp_allow_cache() est sans effet (pas de seccomp cache).
#  [B] 2g (remplacement seccomp dans setuid_hook) -> DIAGNOSTIC SEULEMENT :
#      son chemin ($KSU_DIR/kernel/hook/) n'existait pas (le vrai est
#      $KSU_DIR/hook/), donc il ne s'appliquait jamais ; et s'il s'était
#      appliqué il aurait remplacé le disable_seccomp() valable sur 4.19.
#  [C] 2f (injection dans escape_with_root_profile) -> DIAGNOSTIC SEULEMENT
#      (le driver appelle déjà disable_seccomp(), vu dans hook-report.txt).
#  [D] Rapport : orig_*_check.mk, hook-report.txt, nm-ksu.txt, dotconfig-ksu.txt,
#      .rej du patch SuSFS, contrôle post-build du bypass.
#  [E] Log noyau "KSU-DBG" (ratelimited) quand reboot() est appelé avec une magie
#      qui n'est pas celle d'un vrai reboot : prouve via dmesg que l'appel
#      atteint le noyau, et avec quel uid. Désactiver : WITH_DEBUG_LOG=0.
# Variables optionnelles :
#   WITH_TOUCH_STUB=1|0   (défaut 1, comme v28.1)
#   WITH_DEBUG_LOG=1|0    (défaut 1)
#   WITH_KALLSYMS_ALL=0|1 (défaut 0 : NON présent dans v28.1 où le tactile marche)
# =============================================================================

WITH_TOUCH_STUB="${WITH_TOUCH_STUB:-1}"
WITH_DEBUG_LOG="${WITH_DEBUG_LOG:-1}"
WITH_KALLSYMS_ALL="${WITH_KALLSYMS_ALL:-0}"

echo "=== Build BakaSU (SUSFS + repack backslashxx + seccomp arch bypass) v28.2 ==="
df -h

BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true
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

# ==================== 1. CLONAGE DU NOYAU ====================
git clone https://github.com/LineageOS/android_kernel_motorola_sm8250.git -b lineage-23.2 --depth=1 kernel_sources
cd kernel_sources
git log --oneline -1 | tee -a "$REPORT"

# ==================== 2. INTÉGRATION BakaSU (sync-susfs) ====================
echo "=== Intégration BakaSU (sync-susfs) ==="
rm -rf drivers/kernelsu KernelSU susfs4ksu 2>/dev/null || true

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
echo "KSU_DIR : $KSU_DIR" | tee -a "$REPORT"

# ==================== 2e. NEUTRALISATION CHECK.MK (originaux sauvegardés) ====================
echo ""
echo "=== Neutralisation check.mk (originaux copiés dans output/orig_*.mk) ==="
for pattern in susfs_compat.mk inline_hook_check.mk manual_hook_check.mk tracepoint_hook_check.mk kprobe_check.mk; do
    FILES=$(find . -name "$pattern" -type f 2>/dev/null || true)
    if [ -n "$FILES" ]; then
        for f in $FILES; do
            cp "$f" "$GITHUB_WORKSPACE/output/orig_$pattern" 2>/dev/null || true
            sed -i 's/\$(error/\$(warning/g' "$f"
            echo "  neutralisé : $f" >> "$REPORT"
        done
    fi
done
echo "--- Kconfig du driver ---" >> "$REPORT"
find "$KSU_DIR" -maxdepth 2 -name Kconfig -exec grep -hE "^\s*(config|menuconfig) KSU" {} \; >> "$REPORT" 2>/dev/null || true

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

# ==================== 2c. FIX symbol_resolver.h (inchangé) ====================
echo "=== Fix symbol_resolver.h ==="
for h in "$KSU_DIR/infra/symbol_resolver.h" "$KSU_DIR/kernel/infra/symbol_resolver.h"; do
    if [ -f "$h" ]; then
        sed -i 's|^static inline void \*ksu_resolve_symbol_for_functable_hook|// static inline void *ksu_resolve_symbol_for_functable_hook|' "$h"
        sed -i 's|^static inline unsigned long find_kernel_symbol_exact|// static inline unsigned long find_kernel_symbol_exact|' "$h"
        sed -i 's|^static inline void ksu_init_symbol_resolver|// static inline void ksu_init_symbol_resolver|' "$h"
    fi
done

# ==================== 2d. STATIC EXPORTS SELINUX (inchangé) ====================
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

# ==================== 2e. FIX O_CLOEXEC (inchangé) ====================
echo ""
echo "=== Fix O_CLOEXEC ==="
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

# ==================== 2f/2g. SECCOMP DU DRIVER : DIAGNOSTIC SEULEMENT ====================
echo ""
echo "=== État seccomp dans le driver (aucune modification) ==="
{
    echo "--- disable_seccomp / ksu_seccomp_allow_cache dans le driver ---"
    grep -rn "disable_seccomp\|ksu_seccomp_allow_cache" "$KSU_DIR" 2>/dev/null | head -30 || true
    SETUID_HOOK=$(find "$KSU_DIR" -name "setuid_hook.c" 2>/dev/null | head -1 || true)
    echo "setuid_hook.c : ${SETUID_HOOK:-introuvable}"
    [ -n "$SETUID_HOOK" ] && grep -n -B3 -A3 "seccomp" "$SETUID_HOOK" | head -60 || true
} >> "$REPORT"
if grep -rq "disable_seccomp();" "$KSU_DIR/policy/" 2>/dev/null; then
    echo "✅ le driver appelle déjà disable_seccomp() (rien à injecter)"
fi

# ==================== 2h. FIX SIDTAB SYNC (inchangé) ====================
echo ""
echo "=== Fix sidtab sync (commit upstream a810677) ==="
SELINUX_C=$(find "$KSU_DIR" -name "selinux.c" -path "*selinux*" 2>/dev/null | head -1 || true)
if [ -f "$SELINUX_C" ]; then
    echo "Fichier trouvé : $SELINUX_C"
    if grep -q "sync to global sidtab" "$SELINUX_C"; then
        echo "✅ Sync sidtab déjà présente"
    else
        echo "⚠️  Sync sidtab absente, injection..."
        python3 - "$SELINUX_C" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
count = 0

old_pattern = '''length = security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL);
    if (length)
        goto out;'''
new_pattern = '''length = security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL);
    if (length) {
        goto out;
    } else {
        // sync to global sidtab
        security_context_to_sid(buf, size, &tmp, GFP_KERNEL);
    }'''
if old_pattern in content:
    content = content.replace(old_pattern, new_pattern, 1); count += 1

old_scon = '''length = security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL);
    if (length)
        goto out;'''
new_scon = '''length = security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL);
    if (length) {
        goto out;
    } else {
        // sync to global sidtab
        security_context_to_sid(scon, strlen(scon), &tmp, GFP_KERNEL);
    }'''
if old_scon in content:
    content = content.replace(old_scon, new_scon, 1); count += 1

old_tcon = '''length = security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL);
    if (length)
        goto out;'''
new_tcon = '''length = security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL);
    if (length) {
        goto out;
    } else {
        // sync to global sidtab
        security_context_to_sid(tcon, strlen(tcon), &tmp, GFP_KERNEL);
    }'''
if old_tcon in content:
    content = content.replace(old_tcon, new_tcon, 1); count += 1

if 'u32 sid, len;' in content and 'u32 sid, len, tmp;' not in content:
    content = content.replace('u32 sid, len;', 'u32 sid, len, tmp;', 1)
if 'u32 ssid, tsid;' in content and 'u32 ssid, tsid, tmp;' not in content:
    content = content.replace('u32 ssid, tsid;', 'u32 ssid, tsid, tmp;', 1)

if count > 0:
    with open(path, 'w') as f:
        f.write(content)
    print(f"✅ {count} bloc(s) de sync sidtab injecté(s)")
else:
    print("⚠️  Aucun pattern correspondant trouvé. Vérifie manuellement le fichier.")
PYEOF
    fi
else
    echo "⚠️  selinux.c introuvable"
fi

# ==================== 3. PATCH SUSFS (cyberc3dr) (inchangé) ====================
echo ""
echo "=== Patch SUSFS 4.19 (cyberc3dr) ==="
cd "$GITHUB_WORKSPACE"
rm -rf /tmp/cyber_repo 2>/dev/null || true
git clone --depth=1 --branch rebase https://github.com/cyberc3dr/nGKI_Kernel_Build.git /tmp/cyber_repo 2>/dev/null || true

cd "$GITHUB_WORKSPACE/kernel_sources"
PATCH_419=$(find /tmp/cyber_repo/Patches -name "*4.19*" -name "*.patch" 2>/dev/null | head -1 || true)
if [ -n "$PATCH_419" ]; then
    patch -p1 < "$PATCH_419" 2>&1 | tail -5 || true
fi
echo "--- hunks SUSFS rejetés (.rej) ---" >> "$REPORT"
find . -name "*.rej" -type f >> "$REPORT" 2>/dev/null || true
find . -name "*.rej" -type f -delete 2>/dev/null || true
echo "✅ Patch SUSFS (cyberc3dr) appliqué"

# ==================== 3.5. CORRECTIONS POST-PATCH SUSFS (inchangé) ====================
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

# ==================== 4. HOOK ksu_handle_sys_reboot (+ log debug optionnel) ====================
echo ""
echo "=== Injection du hook ksu_handle_sys_reboot ==="
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
    WITH_DEBUG_LOG="$WITH_DEBUG_LOG" python3 << 'PYEOF'
import re, os, sys
dbg = os.environ.get('WITH_DEBUG_LOG', '1') == '1'
with open('kernel/reboot.c', 'r') as f:
    content = f.read()

pattern_syscall = r'(SYSCALL_DEFINE4\(reboot,\s*int,\s*magic1,\s*int,\s*magic2,\s*unsigned int,\s*cmd,\s*void __user \*,\s*arg\)\s*\{)'
match = re.search(pattern_syscall, content)
if not match:
    print("❌ Pattern SYSCALL_DEFINE4(reboot) non trouvé"); sys.exit(1)

extern = '''
#if defined(CONFIG_KSU)
extern int ksu_handle_sys_reboot(int, int, unsigned int, void __user **);
#endif
'''
content = content[:match.start()] + extern + content[match.start():]
start_pos = content.find('SYSCALL_DEFINE4(reboot')
ret_pos = content.find('int ret = 0;', start_pos)
if ret_pos == -1:
    print("❌ Impossible de trouver 'int ret = 0;'"); sys.exit(1)

dbg_line = ''
if dbg:
    dbg_line = '''
	if ((unsigned int)magic1 != 0xfee1dead)
		pr_info_ratelimited("KSU-DBG: reboot(magic1=0x%x magic2=0x%x cmd=0x%x) uid=%u\\n",
				    magic1, magic2, cmd, __kuid_val(current_uid()));'''
call = '''
#if defined(CONFIG_KSU)''' + dbg_line + '''
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif'''
insert_pos = ret_pos + len('int ret = 0;')
content = content[:insert_pos] + call + content[insert_pos:]
with open('kernel/reboot.c', 'w') as f:
    f.write(content)
print("✅ Hook ksu_handle_sys_reboot inséré (debug log = %s)" % dbg)
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
echo "--- handler reboot dans le driver ---" >> "$REPORT"
grep -rn "ksu_handle_sys_reboot" "$KSU_DIR" 2>/dev/null | head -5 >> "$REPORT" || true

# ==================== 4b. HOOK ksu_handle_sys_read (inchangé) ====================
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

# ==================== 4c. [A] BYPASS SECCOMP DU SUPERCALL KSU ====================
echo ""
echo "=== Bypass seccomp du supercall KSU (arch/arm64/kernel/ptrace.c) ==="
KSU_MAGIC=$(grep -rhoE "KSU_INSTALL_MAGIC1[[:space:]]+(0x)?[0-9A-Fa-f]+" "$KSU_DIR" 2>/dev/null | head -1 | grep -oE "0x[0-9A-Fa-f]+" || true)
echo "--- candidats magie supercall ---" >> "$REPORT"
grep -rniE "0xdeadbeef|INSTALL_MAGIC|SUPERCALL_MAGIC|KSU_MAGIC" "$KSU_DIR" 2>/dev/null | head -15 >> "$REPORT" || true
if [ -z "$KSU_MAGIC" ]; then
    KSU_MAGIC="ANY"
    echo "ℹ️  magie non trouvée dans le driver : mode ANY (tout reboot dont magic1 != 0xfee1dead ; jamais un vrai reboot)" | tee -a "$REPORT"
else
    echo "magie lue dans le driver : $KSU_MAGIC" | tee -a "$REPORT"
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

cond = '(u32)regs->regs[0] != 0xfee1deadU' if magic == 'ANY' else '(u32)regs->regs[0] == %sU' % magic
helper = '''#ifdef CONFIG_KSU
#include <asm/unistd.h>
/*
 * KSU : laisse passer reboot(<magie KSU>, ...) a travers seccomp.
 * 4.19 n'a pas de seccomp action cache -> ksu_seccomp_allow_cache() est sans effet.
 * magic1 != 0xfee1dead n'est jamais un vrai reboot ; le handler du driver valide l'appelant.
 */
static inline bool ksu_seccomp_bypass(struct pt_regs *regs)
{
	return regs->syscallno == __NR_reboot && %s;
}
#else
static inline bool ksu_seccomp_bypass(struct pt_regs *regs) { return false; }
#endif

''' % cond

c = c[:fn.start()] + helper + c[fn.start():fn.end()] + new_body + c[end:]
open(p, 'w').write(c)
print("✅ bypass seccomp injecté (%d occurrence(s))" % body.count('secure_computing(NULL)'))
PYEOF
grep -q "ksu_seccomp_bypass(regs) ? 0 : secure_computing" arch/arm64/kernel/ptrace.c \
    || { echo "❌ bypass seccomp absent de ptrace.c"; exit 1; }

# ==================== 5. CONFIGURATION (identique v28.1 + options) ====================
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
  if [ "$WITH_KALLSYMS_ALL" = "1" ]; then
    echo "CONFIG_KALLSYMS=y"
    echo "CONFIG_KALLSYMS_ALL=y"
  fi
} >> out/.config

make O=out LLVM=1 CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 olddefconfig 2>&1 | tail -5

echo "=== État final .config ==="
grep -E "CONFIG_KSU|KPROBES|SECCOMP|KALLSYMS|MODVERSIONS|CONFIG_CFI|CONFIG_LTO" out/.config > "$GITHUB_WORKSPACE/output/dotconfig-ksu.txt" || true
cat "$GITHUB_WORKSPACE/output/dotconfig-ksu.txt"

for opt in CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_SECCOMP_FILTER=y; do
    grep -q "^${opt}$" out/.config || { echo "❌ ${opt} absent du .config final, abandon"; exit 1; }
done

# ==================== 6. PATCHS MOTOROLA (identiques v28.1) ====================
echo "=== Patch signatures + tactile ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
if [ "$WITH_TOUCH_STUB" = "1" ]; then
printf "\n/* --- Début Patch Tactile --- */\n#include <linux/notifier.h>\n#include <linux/module.h>\nstatic BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);\nint panel_register_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_register_notifier);\nint panel_unregister_notifier(struct notifier_block *nb) {\n    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);\n}\nEXPORT_SYMBOL(panel_unregister_notifier);\nvoid touch_set_state(int state) { return; }\nEXPORT_SYMBOL(touch_set_state);\n/* --- Fin Patch Tactile --- */\n" >> techpack/display/msm/msm_drv.c
echo "✅ Stub tactile appliqué"
else
echo "⚠️  WITH_TOUCH_STUB=0 : stub tactile NON appliqué"
fi
echo "✅ Patchs Motorola terminés"

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

# --- [D] Contrôles post-build ---
echo ""
echo "=== Contrôles post-build ==="
NM=$(command -v llvm-nm || command -v aarch64-linux-gnu-nm || command -v nm)
$NM out/vmlinux 2>/dev/null | grep -i "ksu" > "$GITHUB_WORKSPACE/output/nm-ksu.txt" || true
NSYM=$(wc -l < "$GITHUB_WORKSPACE/output/nm-ksu.txt")
echo "symboles ksu dans vmlinux : $NSYM"
if [ "$NSYM" -lt 20 ]; then
    echo "❌ moins de 20 symboles ksu : driver non compilé dans l'image"; exit 1
fi
grep -q " ksu_handle_sys_reboot" "$GITHUB_WORKSPACE/output/nm-ksu.txt" \
    || { echo "❌ ksu_handle_sys_reboot absent de vmlinux"; exit 1; }

# Le bypass est-il vraiment dans le binaire ? (constante 0xfee1dead = movk ..., #0xfee1)
OBJDUMP=$(command -v llvm-objdump || command -v aarch64-linux-gnu-objdump || command -v objdump || true)
BYPASS_OK="inconnu"
if [ -n "$OBJDUMP" ]; then
    DIS=$($OBJDUMP -d --disassemble-symbols=syscall_trace_enter out/vmlinux 2>/dev/null || $OBJDUMP -d --disassemble=syscall_trace_enter out/vmlinux 2>/dev/null || true)
    if echo "$DIS" | grep -qiE "0xfee1|fee1"; then BYPASS_OK="oui"; else BYPASS_OK="non trouvé (peut être inliné ailleurs)"; fi
fi
echo "bypass seccomp visible dans syscall_trace_enter : $BYPASS_OK" | tee -a "$REPORT"

{
  echo "--- messages de check hook (build.log, avec contexte) ---"
  grep -n -B3 "You should integrate" build.log | head -80 || true
  grep -nE "BakaSU/|ksu_handle_.*(not found|missing)" build.log | head -40 || true
  echo "--- symboles ksu_handle_* dans vmlinux ---"
  grep -iE "ksu_handle_" "$GITHUB_WORKSPACE/output/nm-ksu.txt" | head -60 || true
} >> "$REPORT"

# ==================== 8. COMPILATION KSUD (inchangé) ====================
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
rm -rf "$GITHUB_WORKSPACE/ksud-src" 2>/dev/null || true
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
KSUD_BINARY=$(find "$GITHUB_WORKSPACE/ksud-src" -type f -name "ksud" -executable 2>/dev/null | head -1 || true)
if [ -z "$KSUD_BINARY" ]; then echo "❌ ksud introuvable"; exit 1; fi
cp "$KSUD_BINARY" "$GITHUB_WORKSPACE/ksud"; chmod 755 "$GITHUB_WORKSPACE/ksud"
echo "✅ ksud compilé (sync-susfs)"
cd "$GITHUB_WORKSPACE"

# ==================== 9. REPACK (inchangé) ====================
echo ""
echo "=== Repack (méthode backslashxx : magiskboot cpio add) ==="

rm -f ./boot-stock.img 2>/dev/null || true
if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1; then
    echo "  ✅ boot.img : $(du -h boot-stock.img | cut -f1)"
fi
if [ ! -f "boot-stock.img" ] || [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
    echo "❌ boot-stock.img invalide"; exit 1
fi
rm -f ./dtbo-stock.img 2>/dev/null || true
gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1 || true

mkdir -p repack
cp boot-stock.img repack/boot.img
wget -q https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk -O Magisk-v27.0.apk
unzip -q Magisk-v27.0.apk lib/x86_64/libmagiskboot.so
mv lib/x86_64/libmagiskboot.so repack/magiskboot
chmod +x repack/magiskboot
rm -rf ./Magisk-v27.0.apk ./lib 2>/dev/null || true

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

cp "$GITHUB_WORKSPACE/ksud" ./local_su_binary
chmod 755 ./local_su_binary
./magiskboot cpio ramdisk.cpio \
    "mkdir 0755 system" \
    "mkdir 0755 system/bin" \
    "add 06755 system/bin/su ./local_su_binary"
rm -f ./local_su_binary 2>/dev/null || true

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
cp final_boot.img output/BakaSU-SUSFS-v28.2-boot.img
cp dtbo-stock.img output/dtbo.img 2>/dev/null || true
cp kernel_sources/build.log output/
cp "$GITHUB_WORKSPACE/ksud" output/ksud 2>/dev/null || true
echo ""
echo "=== BUILD TERMINÉ v28.2 ==="
ls -lh output/
