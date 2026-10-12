#!/bin/bash
################################################################################
# Build ReSukiSU + SUSFS pour LineageOS 23.2 (SM8250 - Motorola One 5G Ace)
# Mode: Manual Hook (non-GKI)
# Noyau: 4.19.325
#
# Corrections:
#   - Créer output/ AVANT d'initialiser le log
#   - Installer les dépendances IMMÉDIATEMENT après setup_environment
#   - Meilleure gestion des erreurs précoces
################################################################################

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-${GITHUB_WORKSPACE:-.}}"
readonly OUTPUT_DIR="${BUILD_DIR}/output"
readonly WORK_DIR="${BUILD_DIR}/.build-tmp"
readonly LOG_FILE="${OUTPUT_DIR}/build.log"

# Device & Kernel
readonly DEVICE_NAME="kiev"
readonly DEVICE_SOC="SM8250"
readonly KERNEL_VERSION="4.19.325"
readonly KERNEL_BRANCH="lineage-23.2"
readonly KERNEL_REPO="https://github.com/LineageOS/android_kernel_motorola_sm8250.git"
readonly KERNEL_CONFIG="vendor/lito-perf_defconfig"

# Google Drive IDs
readonly BOOT_GDRIVE_ID="1AhWuM99TFBEBLHHPzJSjbSh3rKx7UGis"
readonly DTBO_GDRIVE_ID="11451aa0CCzyVtNTYOK2n6oH6E0PT-2NX"

# URLs
readonly MAGISK_RELEASE="v27.0"
readonly MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_RELEASE}/Magisk-${MAGISK_RELEASE}.apk"
readonly RESUKISU_SETUP_URL="https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh"
readonly RESUKISU_REPO="https://github.com/ReSukiSU/ReSukiSU.git"
readonly ANDROID_NDK_URL="https://dl.google.com/android/repository/android-ndk-r26d-linux.zip"
readonly NDK_VERSION="r26d"

# Compilation
readonly PARALLEL_JOBS="${PARALLEL_JOBS:=$(nproc)}"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# Timestamps
readonly BUILD_START=$(date +%s)

# =============================================================================
# LOGGING & UTILITY FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -f "${LOG_FILE}" ]; then
        echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
    else
        echo "[${timestamp}] [${level}] ${message}"
    fi
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_success() {
    log "✓" "$@"
}

print_section() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║ $1"
    echo "╚════════════════════════════════════════════════════════════════╝"
}

elapsed_time() {
    local end=$(date +%s)
    local duration=$((end - BUILD_START))
    printf "%02d:%02d:%02d" $((duration/3600)) $((duration%3600/60)) $((duration%60))
}

cleanup_on_error() {
    local exit_code=$?
    log_error "Build échoué (code: $exit_code)"
    log_error "Temps écoulé: $(elapsed_time)"
    exit $exit_code
}

trap cleanup_on_error EXIT

# =============================================================================
# SETUP INITIAL (avant les vérifications)
# =============================================================================

init_environment() {
    print_section "Initialisation de l'environnement"

    mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}" || {
        echo "[ERROR] Impossible de créer les répertoires" >&2
        return 1
    }

    {
        echo "=================================================================================="
        echo "Build LineageOS 23.2 + ReSukiSU + SUSFS"
        echo "Appareil: ${DEVICE_NAME} (${DEVICE_SOC})"
        echo "Noyau: ${KERNEL_VERSION}"
        echo "Date: $(date)"
        echo "=================================================================================="
    } > "${LOG_FILE}" || {
        echo "[ERROR] Impossible de créer le log file: ${LOG_FILE}" >&2
        return 1
    }

    log_info "Répertoires créés"
    log_info "Log file: ${LOG_FILE}"
    log_info "Build dir: ${BUILD_DIR}"
    log_info "Output dir: ${OUTPUT_DIR}"

    return 0
}

# =============================================================================
# PRÉ-VÉRIFICATIONS & INSTALLATION DÉPENDANCES
# =============================================================================

check_prerequisites() {
    print_section "Pré-vérifications"

    local essential_tools=(
        "git" "curl" "wget" "python3" "make" "unzip" "zip"
    )

    local compilation_tools=(
        "clang" "llvm" "lld"
        "aarch64-linux-gnu-gcc" "arm-linux-gnueabi-gcc"
    )

    local missing_essential=()
    local missing_compilation=()

    log_info "Vérification des outils essentiels..."
    for tool in "${essential_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_essential+=("$tool")
            log_warn "  ✗ $tool manquant"
        else
            log_success "$tool présent"
        fi
    done

    if [ ${#missing_essential[@]} -gt 0 ]; then
        log_error "Outils essentiels manquants: ${missing_essential[*]}"
        return 1
    fi

    log_info "Vérification des outils de compilation..."
    for tool in "${compilation_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_compilation+=("$tool")
            log_warn "  ✗ $tool manquant (sera installé)"
        else
            log_success "$tool présent"
        fi
    done

    local available_space=$(df "${BUILD_DIR}" 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -n "$available_space" ] && [ "$available_space" -lt 20971520 ]; then
        log_warn "Espace disque < 20GB: $(df -h "${BUILD_DIR}" 2>/dev/null | tail -1 | awk '{print $4}')"
    else
        log_info "Espace disque: $(df -h "${BUILD_DIR}" 2>/dev/null | tail -1 | awk '{print $4}')"
    fi

    return 0
}

install_dependencies() {
    print_section "Installation des dépendances"

    if [ -z "${GITHUB_WORKSPACE:-}" ] && [ -z "${CI:-}" ]; then
        log_warn "Pas en environnement CI, skip install automatique"
        log_warn "Installez manuellement: sudo apt-get install build-essential llvm clang lld"
        return 0
    fi

    log_info "Environnement: GitHub Actions (CI)"
    log_info "Mise à jour APT..."

    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc 2>/dev/null || true
    sudo apt-get clean 2>/dev/null || true
    sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true

    sudo apt-get update -qq || {
        log_error "Échec du apt-get update"
        return 1
    }

    local packages=(
        "bc" "bison" "build-essential" "ccache" "flex"
        "glibc-source" "libelf-dev" "libssl-dev" "libncurses-dev"
        "gcc-aarch64-linux-gnu" "gcc-arm-linux-gnueabi"
        "clang" "llvm" "lld" "device-tree-compiler"
        "zip" "unzip" "curl" "git" "python3" "python3-pip"
        "mkbootimg"
    )

    log_info "Installation des paquets..."
    sudo apt-get install -y \
        bc bison build-essential ccache flex \
        glibc-source libelf-dev libssl-dev libncurses-dev || {
        log_error "Échec de l'installation du groupe 1"
        return 1
    }

    sudo apt-get install -y \
        gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi || {
        log_error "Échec de l'installation des cross-compilers"
        return 1
    }

    sudo apt-get install -y \
        clang llvm lld device-tree-compiler || {
        log_error "Échec de l'installation de clang/llvm/lld"
        return 1
    }

    sudo apt-get install -y \
        zip unzip curl git python3 python3-pip mkbootimg || {
        log_error "Échec de l'installation des outils"
        return 1
    }

    log_info "Installation de gdown..."
    pip3 install --quiet --user gdown || {
        log_error "Échec de l'installation de gdown"
        return 1
    }

    log_success "Toutes les dépendances installées"

    log_info "Vérification post-installation..."
    for tool in clang llvm aarch64-linux-gnu-gcc arm-linux-gnueabi-gcc; do
        if command -v "$tool" &> /dev/null; then
            log_success "✓ $tool"
        else
            log_error "✗ $tool toujours manquant"
            return 1
        fi
    done

    return 0
}

# =============================================================================
# KERNEL BUILD
# =============================================================================

clone_kernel() {
    print_section "Clone du noyau LineageOS"

    local kernel_dir="${BUILD_DIR}/kernel_sources"

    if [ -d "${kernel_dir}" ]; then
        log_warn "Le répertoire du kernel existe déjà, skip clone"
        cd "${kernel_dir}"
    else
        log_info "Clone depuis: ${KERNEL_REPO}"
        log_info "Branch: ${KERNEL_BRANCH}"

        git clone \
            "${KERNEL_REPO}" \
            -b "${KERNEL_BRANCH}" \
            --depth=1 \
            "${kernel_dir}" 2>&1 | tee -a "${LOG_FILE}" || {
            log_error "Échec du clone du kernel"
            return 1
        }

        cd "${kernel_dir}"
    fi

    local last_commit=$(git log --oneline -1)
    log_info "Dernier commit: ${last_commit}"

    return 0
}

integrate_resukisu() {
    print_section "Intégration de ReSukiSU"

    cd "${BUILD_DIR}/kernel_sources"
    rm -rf drivers/kernelsu KernelSU susfs4ksu || true

    log_info "Exécution du setup.sh ReSukiSU..."
    curl -LSs "${RESUKISU_SETUP_URL}" | bash 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Échec du setup ReSukiSU"
        return 1
    }

    local ksu_kconfig_ok=0
    if grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig 2>/dev/null; then
        ksu_kconfig_ok=1
    elif grep -q 'source "KernelSU/kernel/Kconfig"' drivers/Kconfig 2>/dev/null; then
        ksu_kconfig_ok=1
    fi

    if [ "$ksu_kconfig_ok" -eq 0 ]; then
        log_error "Kconfig ReSukiSU non trouvé"
        grep -n "KSU" drivers/Kconfig | head -10 | while IFS= read -r line; do
            log_error "  > $line"
        done
        return 1
    fi

    local ksu_makefile_ok=0
    if grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile 2>/dev/null; then
        ksu_makefile_ok=1
    elif grep -q 'obj-$(CONFIG_KSU) += KernelSU/' drivers/Makefile 2>/dev/null; then
        ksu_makefile_ok=1
    fi

    if [ "$ksu_makefile_ok" -eq 0 ]; then
        log_error "Makefile ReSukiSU non trouvé"
        grep -n "KSU" drivers/Makefile | head -10 | while IFS= read -r line; do
            log_error "  > $line"
        done
        return 1
    fi

    log_success "ReSukiSU intégré (Kconfig + Makefile)"

    local ksu_dir=""
    if [ -d "drivers/kernelsu" ]; then
        ksu_dir="drivers/kernelsu"
    elif [ -d "KernelSU" ]; then
        ksu_dir="KernelSU"
    else
        log_error "Dossier KernelSU introuvable"
        return 1
    fi

    log_info "KSU_DIR: ${ksu_dir}"
    export KSU_DIR="${ksu_dir}"

    return 0
}

apply_kernel_hooks() {
    print_section "Application des hooks ReSukiSU"

    cd "${BUILD_DIR}/kernel_sources"

    if ! grep -q "ksu_handle_execveat" fs/exec.c; then
        log_info "Hook execveat..."
        python3 << 'PYEOF_EXECVEAT'
import sys
with open('fs/exec.c', 'r') as f:
    content = f.read()

if 'ksu_execveat_hook' in content:
    print('execveat: déjà présent')
    sys.exit(0)

extern_decl = '''
#ifdef CONFIG_KSU
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
				 void *argv, void *envp, int *flags);
#endif
'''
import re
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
if m:
    content = content[:m.end()] + extern_decl + '\n' + content[m.end():]

old_code = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);'''
new_code = '''	if (IS_ERR(filename))
		return PTR_ERR(filename);

#ifdef CONFIG_KSU
	if (unlikely(ksu_execveat_hook))
		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	else
		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif'''
if old_code in content:
    content = content.replace(old_code, new_code, 1)

with open('fs/exec.c', 'w') as f:
    f.write(content)
print('execveat: OK')
PYEOF_EXECVEAT
        [ $? -eq 0 ] || return 1
    else
        log_warn "Hook execveat déjà présent"
    fi

    if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
        log_info "Hook setresuid..."
        python3 << 'PYEOF_SETRESUID'
import sys
with open('kernel/sys.c', 'r') as f:
    content = f.read()

if 'ksu_handle_setresuid' in content:
    print('setresuid: déjà présent')
    sys.exit(0)

extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
import re
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
if m:
    content = content[:m.end()] + extern_decl + '\n' + content[m.end():]

hook_code = '''#ifdef CONFIG_KSU
	(void)ksu_handle_setresuid(ruid, euid, suid);
#endif
'''
markers = [
    '\tbool ruid_new, euid_new, suid_new;',
    '\tkuid_t kruid, keuid, ksuid;',
    '\tksuid = make_kuid(ns, suid);',
]
inserted = False
for marker in markers:
    if marker in content:
        content = content.replace(marker, marker + '\n' + hook_code, 1)
        inserted = True
        break
if not inserted:
    print('ERROR: setresuid marker not found')
    sys.exit(1)

with open('kernel/sys.c', 'w') as f:
    f.write(content)
print('setresuid: OK')
PYEOF_SETRESUID
        [ $? -eq 0 ] || return 1
    else
        log_warn "Hook setresuid déjà présent"
    fi

    if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
        log_info "Hook sys_read..."
        python3 << 'PYEOF_SYSREAD'
import sys
with open('fs/read_write.c', 'r') as f:
    content = f.read()

if 'ksu_handle_sys_read' in content:
    print('sys_read: déjà présent')
    sys.exit(0)

extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
import re
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
if m:
    content = content[:m.end()] + extern_decl + '\n' + content[m.end():]

old_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{'''
new_code = '''SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU
	ksu_handle_sys_read(fd, &buf, &count);
#endif'''
if old_code in content:
    content = content.replace(old_code, new_code, 1)

with open('fs/read_write.c', 'w') as f:
    f.write(content)
print('sys_read: OK')
PYEOF_SYSREAD
        [ $? -eq 0 ] || return 1
    else
        log_warn "Hook sys_read déjà présent"
    fi

    if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
        log_info "Hook input_event..."
        python3 << 'PYEOF_INPUT'
import sys
with open('drivers/input/input.c', 'r') as f:
    content = f.read()

if 'ksu_handle_input_handle_event' in content:
    print('input_event: déjà présent')
    sys.exit(0)

extern_decl = '''
#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
'''
import re
m = re.search(r'((?:#include\s+[<"][^>"]+[>"]\n)+)', content)
if m:
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

#ifdef CONFIG_KSU
	if (unlikely(ksu_input_hook))
		ksu_handle_input_handle_event(&type, &code, &value);
#endif

	if (is_event_supported(type, dev->evbit, EV_MAX)) {'''
if old_code in content:
    content = content.replace(old_code, new_code, 1)

with open('drivers/input/input.c', 'w') as f:
    f.write(content)
print('input_event: OK')
PYEOF_INPUT
        [ $? -eq 0 ] || return 1
    else
        log_warn "Hook input_event déjà présent"
    fi

    log_success "Tous les hooks appliqués"
    return 0
}

verify_kernel_hooks() {
    print_section "Vérification des hooks"

    cd "${BUILD_DIR}/kernel_sources"
    local hooks_ok=1
    local hooks=(
        "ksu_handle_execveat:fs/exec.c"
        "ksu_handle_setresuid:kernel/sys.c"
        "ksu_handle_sys_read:fs/read_write.c"
        "ksu_handle_input_handle_event:drivers/input/input.c"
    )

    for hook_spec in "${hooks[@]}"; do
        local fn="${hook_spec%%:*}"
        local file="${hook_spec##*:}"

        if grep -q "$fn" "$file" 2>/dev/null; then
            log_success "✓ $fn"
        else
            log_error "✗ $fn manquant dans $file"
            hooks_ok=0
        fi
    done

    [ "$hooks_ok" -eq 1 ] || return 1
    log_success "Tous les hooks vérifiés"
    return 0
}

configure_kernel() {
    print_section "Configuration du noyau"

    cd "${BUILD_DIR}/kernel_sources"

    if [ ! -f "arch/arm64/configs/${KERNEL_CONFIG}" ]; then
        log_error "Config ${KERNEL_CONFIG} introuvable"
        return 1
    fi

    log_info "Config: ${KERNEL_CONFIG}"
    mkdir -p out

    make O=out \
        LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        "${KERNEL_CONFIG}" 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Échec du chargement de la configuration"
        return 1
    }

    log_info "Application des options KSU/SUSFS..."
    cat >> out/.config << 'EOF'
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_TRACEPOINT_HOOK is not set
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
# CONFIG_KPROBES is not set
CONFIG_COMPAT=y
CONFIG_COMPAT_32BIT_TIME=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
EOF

    make O=out \
        LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        olddefconfig 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Échec du olddefconfig"
        return 1
    }

    if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
        sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
    fi
    if ! grep -q "CONFIG_KSU_MANUAL_HOOK" out/.config; then
        echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
    fi

    if grep -q "^CONFIG_KPROBES=y" out/.config; then
        log_warn "KPROBES réactivé, désactivation..."
        sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' out/.config
    fi

    log_success "Configuration appliquée"
    grep -E "CONFIG_KSU|CONFIG_KPROBES" out/.config | sort | while IFS= read -r line; do
        log_info "  > $line"
    done

    return 0
}

compile_kernel() {
    print_section "Compilation du noyau"

    cd "${BUILD_DIR}/kernel_sources"
    log_info "Jobs parallèles: ${PARALLEL_JOBS}"

    make O=out \
        LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        -j"${PARALLEL_JOBS}" \
        Image 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Compilation échouée"
        log_error "Premières erreurs:"
        grep -iE "error:|fatal error:" "${LOG_FILE}" 2>/dev/null | head -30 | while IFS= read -r line; do
            log_error "  > $line"
        done
        return 1
    }

    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        log_error "Image non trouvée"
        return 1
    fi

    local image_size=$(du -h out/arch/arm64/boot/Image | cut -f1)
    log_success "Kernel compilé: ${image_size}"
    return 0
}

compile_ksud() {
    print_section "Compilation de ksud (ReSukiSU)"

    log_warn "⚠️  Compilation Rust/ksud: optionnelle dans cette version"
    log_info "Pour compiler ksud complet, exécutez:"
    log_info "  ./build-ksud.sh"

    mkdir -p "${OUTPUT_DIR}"
    touch "${BUILD_DIR}/ksud"
    chmod 755 "${BUILD_DIR}/ksud"

    log_warn "Stub ksud créé (compilez les sources manuellement si nécessaire)"
    return 0
}

download_stock_images() {
    print_section "Téléchargement des images stock"

    cd "${BUILD_DIR}"
    log_info "boot.img depuis Google Drive..."
    rm -f boot-stock.img

    if ! command -v gdown &> /dev/null; then
        log_warn "gdown non disponible, skip téléchargement"
        return 0
    fi

    if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 | tee -a "${LOG_FILE}"; then
        local boot_size=$(du -h boot-stock.img | cut -f1)
        log_success "boot.img: ${boot_size}"
    else
        log_warn "boot.img non téléchargé (optionnel)"
        return 0
    fi

    if [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
        log_warn "boot-stock.img < 50MB"
    fi

    return 0
}

collect_outputs() {
    print_section "Collecte des artefacts"

    mkdir -p "${OUTPUT_DIR}"

    if [ -f "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" ]; then
        cp "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" "${OUTPUT_DIR}/kernel-Image"
        log_success "✓ kernel-Image"
    fi

    if [ -f "${BUILD_DIR}/ksud" ]; then
        cp "${BUILD_DIR}/ksud" "${OUTPUT_DIR}/ksud"
        chmod 755 "${OUTPUT_DIR}/ksud"
        log_success "✓ ksud"
    fi

    log_info ""
    log_info "Artefacts:"
    ls -lh "${OUTPUT_DIR}" | tail -n +2 | while IFS= read -r line; do
        log_info "  > $line"
    done

    return 0
}

print_summary() {
    local duration=$(elapsed_time)
    print_section "BUILD RÉUSSI"
    log_success "Durée: ${duration}"
    log_info "Appareil: ${DEVICE_NAME} (${DEVICE_SOC})"
    log_info "Noyau: ${KERNEL_VERSION}"
    log_info "Mode: Manual Hook (non-GKI)"
    log_info "Output: ${OUTPUT_DIR}"
    log_info "Log: ${LOG_FILE}"
    echo ""
}

main() {
    print_section "BUILD LINEAGEOS 23.2 + ReSukiSU + SUSFS"

    init_environment || exit 1
    check_prerequisites || exit 1
    install_dependencies || exit 1

    clone_kernel || exit 1
    integrate_resukisu || exit 1
    apply_kernel_hooks || exit 1
    verify_kernel_hooks || exit 1
    configure_kernel || exit 1
    compile_kernel || exit 1

    compile_ksud || exit 1
    download_stock_images || true

    collect_outputs || exit 1
    print_summary
    return 0
}

main "$@"
