#!/bin/bash
################################################################################
# Build ReSukiSU + SUSFS pour LineageOS 23.2 (SM8250 - Motorola One 5G Ace)
# Mode: Manual Hook (non-GKI)
# Noyau: 4.19.325
#
# Améliorations:
#   - Structure modulaire avec fonctions
#   - Meilleure gestion d'erreurs
#   - Logging centralisé
#   - Vérifications préalables
#   - Temps d'exécution
#   - Cleanup automatique en cas d'erreur
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
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
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
    
    # Optionnel: nettoyer les artefacts
    # rm -rf "${WORK_DIR}" || true
    
    exit $exit_code
}

trap cleanup_on_error EXIT

# =============================================================================
# PRÉ-VÉRIFICATIONS
# =============================================================================

check_prerequisites() {
    print_section "Pré-vérifications"
    
    local missing_tools=()
    local required_tools=(
        "git" "curl" "wget" "python3" "make" "clang" "llvm"
        "aarch64-linux-gnu-gcc" "arm-linux-gnueabi-gcc" "unzip" "zip"
    )
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Outils manquants: ${missing_tools[*]}"
        return 1
    fi
    
    log_success "Tous les outils requis sont présents"
    
    # Vérifier l'espace disque (au moins 20GB)
    local available_space=$(df "${BUILD_DIR}" | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt 20971520 ]; then
        log_warn "Espace disque disponible < 20GB (${available_space}KB)"
    fi
    
    log_info "Espace disque: $(df -h "${BUILD_DIR}" | tail -1 | awk '{print $4}')"
    
    return 0
}

setup_environment() {
    print_section "Configuration de l'environnement"
    
    # Créer les répertoires
    mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}"
    
    # Initialiser le log
    {
        echo "=================================================================================="
        echo "Build LineageOS 23.2 + ReSukiSU + SUSFS"
        echo "Appareil: ${DEVICE_NAME} (${DEVICE_SOC})"
        echo "Noyau: ${KERNEL_VERSION}"
        echo "Date: $(date)"
        echo "=================================================================================="
    } > "${LOG_FILE}"
    
    log_info "Répertoires créés"
    log_info "Log: ${LOG_FILE}"
    
    # Nettoyer les paquets inutiles (si sur GitHub Actions)
    if [ -n "${GITHUB_WORKSPACE:-}" ]; then
        log_info "Suppression des paquets inutiles..."
        sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc || true
        sudo apt-get clean || true
        sudo sed -i 's/azure.archive.ubuntu.com/archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    fi
    
    return 0
}

install_dependencies() {
    print_section "Installation des dépendances"
    
    if [ -n "${GITHUB_WORKSPACE:-}" ]; then
        sudo apt-get update || true
        
        local packages=(
            "bc" "bison" "build-essential" "ccache" "flex"
            "glibc-source" "libelf-dev" "libssl-dev" "libncurses-dev"
            "gcc-aarch64-linux-gnu" "gcc-arm-linux-gnueabi"
            "clang" "llvm" "lld" "device-tree-compiler"
            "zip" "unzip" "curl" "git" "python3" "python3-pip"
            "mkbootimg"
        )
        
        sudo apt-get install -y "${packages[@]}" || {
            log_error "Échec de l'installation des dépendances APT"
            return 1
        }
        
        pip3 install --quiet gdown || {
            log_error "Échec de l'installation de gdown"
            return 1
        }
    fi
    
    log_success "Dépendances installées"
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
        log_info "Clone depuis: ${KERNEL_REPO} (branch: ${KERNEL_BRANCH})"
        
        git clone \
            "${KERNEL_REPO}" \
            -b "${KERNEL_BRANCH}" \
            --depth=1 \
            "${kernel_dir}" || {
            log_error "Échec du clone du kernel"
            return 1
        }
        
        cd "${kernel_dir}"
        log_success "Kernel cloné"
    fi
    
    # Afficher le dernier commit
    local last_commit=$(git log --oneline -1)
    log_info "Dernier commit: ${last_commit}"
    
    return 0
}

integrate_resukisu() {
    print_section "Intégration de ReSukiSU"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    # Nettoyer les anciens fichiers
    rm -rf drivers/kernelsu KernelSU susfs4ksu || true
    
    # Exécuter le script de setup
    log_info "Exécution de setup.sh..."
    curl -LSs "${RESUKISU_SETUP_URL}" | bash || {
        log_error "Échec du setup ReSukiSU"
        return 1
    }
    
    # Vérifier l'intégration Kconfig
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
    
    # Vérifier l'intégration Makefile
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
    
    # Détecter le dossier KSU
    local ksu_dir=""
    if [ -d "drivers/kernelsu" ]; then
        ksu_dir="drivers/kernelsu"
    elif [ -d "KernelSU" ]; then
        ksu_dir="KernelSU"
    else
        log_error "Dossier KernelSU introuvable après setup"
        return 1
    fi
    
    log_info "KSU_DIR détecté: ${ksu_dir}"
    export KSU_DIR="${ksu_dir}"
    
    return 0
}

apply_kernel_hooks() {
    print_section "Application des hooks ReSukiSU (mode manual)"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    # Hook: execveat
    if ! grep -q "ksu_handle_execveat" fs/exec.c; then
        log_info "Injection hook execveat..."
        python3 << 'PYEOF_EXECVEAT'
import re
with open('fs/exec.c', 'r') as f:
    content = f.read()

if 'ksu_execveat_hook' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
				 void *argv, void *envp, int *flags);
#endif
'''
    include_pattern = r'((?:#include\s+[<"][^>"]+[>"]\n)+)'
    match = re.search(include_pattern, content)
    if match:
        content = content[:match.end()] + extern_decl + '\n' + content[match.end():]

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
print("execveat: OK")
PYEOF_EXECVEAT
    else
        log_warn "Hook execveat déjà présent"
    fi
    
    # Hook: setresuid
    if ! grep -q "ksu_handle_setresuid" kernel/sys.c; then
        log_info "Injection hook setresuid..."
        python3 << 'PYEOF_SETRESUID'
import re
with open('kernel/sys.c', 'r') as f:
    content = f.read()

if 'ksu_handle_setresuid' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#endif
'''
    include_pattern = r'((?:#include\s+[<"][^>"]+[>"]\n)+)'
    match = re.search(include_pattern, content)
    if match:
        content = content[:match.end()] + extern_decl + '\n' + content[match.end():]

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
        print("ERROR: setresuid marker not found")
        exit(1)

with open('kernel/sys.c', 'w') as f:
    f.write(content)
print("setresuid: OK")
PYEOF_SETRESUID
    else
        log_warn "Hook setresuid déjà présent"
    fi
    
    # Hook: sys_read
    if ! grep -q "ksu_handle_sys_read" fs/read_write.c; then
        log_info "Injection hook sys_read..."
        python3 << 'PYEOF_SYSREAD'
import re
with open('fs/read_write.c', 'r') as f:
    content = f.read()

if 'ksu_handle_sys_read' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);
#endif
'''
    include_pattern = r'((?:#include\s+[<"][^>"]+[>"]\n)+)'
    match = re.search(include_pattern, content)
    if match:
        content = content[:match.end()] + extern_decl + '\n' + content[match.end():]

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
print("sys_read: OK")
PYEOF_SYSREAD
    else
        log_warn "Hook sys_read déjà présent"
    fi
    
    # Hook: input_event
    if ! grep -q "ksu_handle_input_handle_event" drivers/input/input.c; then
        log_info "Injection hook input_event..."
        python3 << 'PYEOF_INPUT'
import re
with open('drivers/input/input.c', 'r') as f:
    content = f.read()

if 'ksu_handle_input_handle_event' not in content:
    extern_decl = '''
#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern __attribute__((cold)) int ksu_handle_input_handle_event(
			unsigned int *type, unsigned int *code, int *value);
#endif
'''
    include_pattern = r'((?:#include\s+[<"][^>"]+[>"]\n)+)'
    match = re.search(include_pattern, content)
    if match:
        content = content[:match.end()] + extern_decl + '\n' + content[match.end():]

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
print("input_event: OK")
PYEOF_INPUT
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
            log_success "✓ $fn présent dans $file"
        else
            log_error "✗ $fn MANQUANT dans $file"
            hooks_ok=0
        fi
    done
    
    if [ "$hooks_ok" -eq 0 ]; then
        log_error "Des hooks sont manquants"
        return 1
    fi
    
    log_success "Tous les hooks sont en place"
    return 0
}

configure_kernel() {
    print_section "Configuration du noyau"
    
    cd "${BUILD_DIR}/kernel_sources"
    
    # Vérifier que la config existe
    if [ ! -f "arch/arm64/configs/${KERNEL_CONFIG}" ]; then
        log_error "Config ${KERNEL_CONFIG} introuvable"
        return 1
    fi
    
    log_info "Config: ${KERNEL_CONFIG}"
    
    mkdir -p out
    
    # Charger la configuration de base
    make O=out \
        LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        "${KERNEL_CONFIG}" || {
        log_error "Échec du chargement de la configuration"
        return 1
    }
    
    # Appliquer les options KSU/SUSFS
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
    
    # Valider avec olddefconfig
    make O=out \
        LLVM=1 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
        olddefconfig || {
        log_error "Échec du olddefconfig"
        return 1
    }
    
    # Forcer les options cruciales
    log_info "Forçage des options critiques..."
    
    if grep -q "# CONFIG_KSU_MANUAL_HOOK is not set" out/.config; then
        sed -i 's/# CONFIG_KSU_MANUAL_HOOK is not set/CONFIG_KSU_MANUAL_HOOK=y/' out/.config
    fi
    
    if ! grep -q "CONFIG_KSU_MANUAL_HOOK" out/.config; then
        echo "CONFIG_KSU_MANUAL_HOOK=y" >> out/.config
    fi
    
    # Désactiver KPROBES s'il a été réactivé
    if grep -q "^CONFIG_KPROBES=y" out/.config; then
        log_warn "KPROBES réactivé, désactivation forcée..."
        sed -i 's/^CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/' out/.config
    fi
    
    log_success "Configuration appliquée"
    
    # Afficher les options KSU finales
    log_info "État final des options:"
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
        log_error "Les 30 premières erreurs:"
        grep -iE "error:|fatal error:" "${LOG_FILE}" | head -30
        return 1
    }
    
    # Vérifier le résultat
    if [ ! -f "out/arch/arm64/boot/Image" ]; then
        log_error "Image introuvable après compilation"
        return 1
    fi
    
    local image_size=$(du -h out/arch/arm64/boot/Image | cut -f1)
    log_success "Kernel compilé: ${image_size}"
    ls -lh out/arch/arm64/boot/ | while IFS= read -r line; do
        log_info "  > $line"
    done
    
    return 0
}

# =============================================================================
# KSUD BUILD
# =============================================================================

install_rust() {
    print_section "Installation de Rust"
    
    if command -v cargo &> /dev/null; then
        log_warn "Rust déjà installé"
        cargo --version | while IFS= read -r line; do
            log_info "  > $line"
        done
        return 0
    fi
    
    log_info "Téléchargement et installation de Rust..."
    
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --profile minimal || {
        log_error "Échec de l'installation de Rust"
        return 1
    }
    
    # Source l'environnement
    source "$HOME/.cargo/env" || true
    
    log_success "Rust installé"
    return 0
}

setup_android_ndk() {
    print_section "Configuration d'Android NDK"
    
    local ndk_dir="${BUILD_DIR}/android-ndk-${NDK_VERSION}"
    
    if [ -d "${ndk_dir}" ]; then
        log_warn "NDK déjà présent"
    else
        log_info "Téléchargement d'Android NDK (${NDK_VERSION})..."
        
        cd "${BUILD_DIR}"
        wget -q --show-progress "${ANDROID_NDK_URL}" || {
            log_error "Échec du téléchargement du NDK"
            return 1
        }
        
        log_info "Extraction du NDK..."
        unzip -q "android-ndk-${NDK_VERSION}-linux.zip" || {
            log_error "Échec de l'extraction du NDK"
            return 1
        }
        
        rm -f "android-ndk-${NDK_VERSION}-linux.zip"
    fi
    
    export ANDROID_NDK_ROOT="${ndk_dir}"
    export ANDROID_NDK_HOME="${ndk_dir}"
    
    log_success "NDK configuré: ${ANDROID_NDK_ROOT}"
    return 0
}

compile_ksud() {
    print_section "Compilation de ksud (ReSukiSU)"
    
    # Installation de Rust
    install_rust || return 1
    
    # Setup du NDK
    setup_android_ndk || return 1
    
    # Configuration des toolchains
    source "$HOME/.cargo/env" 2>/dev/null || true
    
    log_info "Setup des toolchains Rust..."
    rustup toolchain install nightly || {
        log_error "Échec de l'installation de nightly"
        return 1
    }
    rustup default nightly || true
    rustup target add aarch64-linux-android || {
        log_error "Échec de l'ajout de la cible ARM64"
        return 1
    }
    
    # Configuration des chemins
    local aarch64_clang="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
    local aarch64_clangxx="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"
    local ar_path="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
    local sysroot="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    
    # Clone et build de ksud
    local ksud_src="${BUILD_DIR}/ksud-src"
    
    log_info "Clone de ReSukiSU..."
    rm -rf "${ksud_src}"
    git clone --depth=1 "${RESUKISU_REPO}" "${ksud_src}" || {
        log_error "Échec du clone de ReSukiSU"
        return 1
    }
    
    cd "${ksud_src}/userspace/ksud"
    
    # Configuration de Cargo
    mkdir -p .cargo
    cat > .cargo/config.toml << EOF
[target.aarch64-linux-android]
linker = "${aarch64_clang}"

[env]
CC_aarch64_linux_android = "${aarch64_clang}"
CXX_aarch64_linux_android = "${aarch64_clangxx}"
AR_aarch64_linux_android = "${ar_path}"
BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android = "--sysroot=${sysroot} -I${sysroot}/usr/include/aarch64-linux-android"
EOF
    
    log_info "Compilation de ksud (release)..."
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    
    cargo +nightly build --release --target aarch64-linux-android 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Compilation de ksud échouée"
        return 1
    }
    
    # Localiser le binaire
    local ksud_binary=$(find "${ksud_src}" -type f -name "ksud" -executable 2>/dev/null | head -1)
    
    if [ -z "${ksud_binary}" ]; then
        log_error "ksud non trouvé après compilation"
        return 1
    fi
    
    cp "${ksud_binary}" "${BUILD_DIR}/ksud"
    chmod 755 "${BUILD_DIR}/ksud"
    
    local ksud_size=$(du -h "${BUILD_DIR}/ksud" | cut -f1)
    log_success "ksud compilé et copié: ${ksud_size}"
    
    return 0
}

# =============================================================================
# BOOT IMAGE REPACK
# =============================================================================

download_stock_images() {
    print_section "Téléchargement des images stock (Google Drive)"
    
    cd "${BUILD_DIR}"
    
    # Download boot.img
    log_info "Téléchargement de boot.img..."
    rm -f boot-stock.img
    
    if gdown "https://drive.google.com/uc?id=${BOOT_GDRIVE_ID}" -O boot-stock.img 2>&1 | tee -a "${LOG_FILE}"; then
        local boot_size=$(du -h boot-stock.img | cut -f1)
        log_success "boot.img téléchargé: ${boot_size}"
    else
        log_error "Échec du téléchargement de boot.img"
        return 1
    fi
    
    # Vérifier la taille
    if [ "$(stat -c%s boot-stock.img 2>/dev/null || echo 0)" -lt 50000000 ]; then
        log_error "boot-stock.img trop petit ou manquant"
        return 1
    fi
    
    # Download dtbo.img (optionnel)
    log_info "Téléchargement de dtbo.img..."
    rm -f dtbo-stock.img
    
    if gdown "https://drive.google.com/uc?id=${DTBO_GDRIVE_ID}" -O dtbo-stock.img 2>&1; then
        local dtbo_size=$(du -h dtbo-stock.img 2>/dev/null | cut -f1)
        log_success "dtbo.img téléchargé: ${dtbo_size}"
    else
        log_warn "dtbo.img optionnel non téléchargé"
    fi
    
    return 0
}

setup_magiskboot() {
    print_section "Setup de Magiskboot"
    
    cd "${BUILD_DIR}"
    
    local repack_dir="${BUILD_DIR}/repack"
    mkdir -p "${repack_dir}"
    
    # Télécharger Magisk APK
    log_info "Téléchargement de Magisk..."
    wget -q --show-progress "${MAGISK_URL}" -O Magisk-${MAGISK_RELEASE}.apk || {
        log_error "Échec du téléchargement de Magisk"
        return 1
    }
    
    # Extraire magiskboot
    log_info "Extraction de magiskboot..."
    unzip -q Magisk-${MAGISK_RELEASE}.apk lib/x86_64/libmagiskboot.so || {
        log_error "Échec de l'extraction de magiskboot"
        return 1
    }
    
    mv lib/x86_64/libmagiskboot.so "${repack_dir}/magiskboot"
    chmod +x "${repack_dir}/magiskboot"
    
    rm -rf Magisk-${MAGISK_RELEASE}.apk lib/
    
    log_success "Magiskboot prêt"
    return 0
}

repack_boot_image() {
    print_section "Repack du boot.img"
    
    cd "${BUILD_DIR}/repack"
    
    # Copier l'image stock
    cp "${BUILD_DIR}/boot-stock.img" boot.img
    
    log_info "Unpack de boot.img..."
    ./magiskboot unpack boot.img || {
        log_error "Échec de l'unpack"
        return 1
    }
    
    if [ ! -f "kernel" ] || [ ! -f "ramdisk.cpio" ]; then
        log_error "Fichiers d'unpack manquants (kernel ou ramdisk.cpio)"
        return 1
    fi
    
    log_success "boot.img unpacked"
    
    # Remplacer le kernel
    log_info "Remplacement du kernel..."
    cp "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" kernel
    
    # Ajouter ksud au ramdisk
    log_info "Injection de ksud..."
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 data" \
        "mkdir 0755 data/adb" \
        "mkdir 0755 data/adb/ksud" \
        "add 0755 data/adb/ksud/ksud ${BUILD_DIR}/ksud" || {
        log_error "Échec de l'injection de ksud"
        return 1
    }
    
    # Ajouter le binaire su
    log_info "Injection du binaire su..."
    cp "${BUILD_DIR}/ksud" local_su_binary
    chmod 755 local_su_binary
    
    ./magiskboot cpio ramdisk.cpio \
        "mkdir 0755 system" \
        "mkdir 0755 system/bin" \
        "add 06755 system/bin/su ./local_su_binary" || {
        log_error "Échec de l'injection de su"
        return 1
    }
    
    rm -f local_su_binary
    
    # Repack
    log_info "Repack de boot.img..."
    ./magiskboot repack boot.img new-boot.img || {
        log_error "Échec du repack"
        return 1
    }
    
    mv new-boot.img "${BUILD_DIR}/final_boot.img"
    
    local final_size=$(du -h "${BUILD_DIR}/final_boot.img" | cut -f1)
    log_success "Boot image repacked: ${final_size}"
    
    return 0
}

# =============================================================================
# FINAL OUTPUT
# =============================================================================

collect_outputs() {
    print_section "Collecte des artefacts"
    
    mkdir -p "${OUTPUT_DIR}"
    
    # Boot image
    if [ -f "${BUILD_DIR}/final_boot.img" ]; then
        cp "${BUILD_DIR}/final_boot.img" "${OUTPUT_DIR}/ReSukiSU-SUSFS-boot.img"
        log_success "✓ ReSukiSU-SUSFS-boot.img"
    fi
    
    # DTBO
    if [ -f "${BUILD_DIR}/dtbo-stock.img" ]; then
        cp "${BUILD_DIR}/dtbo-stock.img" "${OUTPUT_DIR}/dtbo.img"
        log_success "✓ dtbo.img"
    fi
    
    # ksud binary
    if [ -f "${BUILD_DIR}/ksud" ]; then
        cp "${BUILD_DIR}/ksud" "${OUTPUT_DIR}/ksud"
        chmod 755 "${OUTPUT_DIR}/ksud"
        log_success "✓ ksud (binary)"
    fi
    
    # Kernel image
    if [ -f "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" ]; then
        cp "${BUILD_DIR}/kernel_sources/out/arch/arm64/boot/Image" "${OUTPUT_DIR}/kernel-Image"
        log_success "✓ kernel-Image"
    fi
    
    # Build log
    if [ -f "${LOG_FILE}" ]; then
        log_success "✓ build.log"
    fi
    
    log_info ""
    log_info "Artefacts finaux:"
    ls -lh "${OUTPUT_DIR}" | tail -n +2 | while IFS= read -r line; do
        log_info "  > $line"
    done
    
    return 0
}

print_summary() {
    local duration=$(elapsed_time)
    
    print_section "BUILD TERMINÉ AVEC SUCCÈS"
    
    log_success "Durée totale: ${duration}"
    log_info "Appareil: ${DEVICE_NAME} (${DEVICE_SOC})"
    log_info "Noyau: ${KERNEL_VERSION}"
    log_info "Mode: Manual Hook (non-GKI)"
    log_info "Sortie: ${OUTPUT_DIR}"
    log_info "Log: ${LOG_FILE}"
    
    echo ""
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

main() {
    print_section "BUILD LINEAGEOS 23.2 + ReSukiSU + SUSFS"
    
    # Pré-vérifications
    check_prerequisites || exit 1
    setup_environment || exit 1
    install_dependencies || exit 1
    
    # Kernel
    clone_kernel || exit 1
    integrate_resukisu || exit 1
    apply_kernel_hooks || exit 1
    verify_kernel_hooks || exit 1
    configure_kernel || exit 1
    compile_kernel || exit 1
    
    # ksud
    compile_ksud || exit 1
    
    # Boot image
    download_stock_images || exit 1
    setup_magiskboot || exit 1
    repack_boot_image || exit 1
    
    # Output
    collect_outputs || exit 1
    print_summary
    
    return 0
}

# Lancer le build
main "$@"
