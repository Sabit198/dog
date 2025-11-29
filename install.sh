#!/usr/bin/env bash
set -euo pipefail

# Configuration
APP="opencode"
INSTALL_DIR="$HOME/.opencode/bin"
REPO_OWNER="sst"
REPO_NAME="opencode"

# Colors
MUTED='\033[0;2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[38;2;255;140;0m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Error handling
trap 'cleanup' EXIT
trap 'error_handler "Script interrupted" 130' INT

cleanup() {
    if [[ -d "opencodetmp" ]]; then
        rm -rf "opencodetmp"
    fi
    printf "\033[?25h" >&2  # Ensure cursor is restored
}

error_handler() {
    local message="${1:-"An error occurred"}"
    local code="${2:-1}"
    print_message "error" "$message"
    exit $code
}

print_message() {
    local level="$1"
    local message="$2"
    local color=""

    case $level in
        info) color="$NC" ;;
        success) color="$GREEN" ;;
        warning) color="$ORANGE" ;;
        error) color="$RED" ;;
        muted) color="$MUTED" ;;
        *) color="$NC" ;;
    esac

    echo -e "${color}${message}${NC}" >&2
}

check_dependencies() {
    local missing_deps=()

    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi

    if [[ "$os" == "linux" ]] || [[ "$os" == "android" ]]; then
        if ! command -v tar >/dev/null 2>&1; then
            missing_deps+=("tar")
        fi
    else
        if ! command -v unzip >/dev/null 2>&1; then
            missing_deps+=("unzip")
        fi
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_message "error" "Missing required dependencies: ${missing_deps[*]}"
        
        # Termux-specific installation help
        if [[ "$os" == "android" ]]; then
            print_message "info" "Install missing packages in Termux:"
            print_message "info" "  pkg update && pkg install ${missing_deps[*]}"
        else
            print_message "info" "Please install them using your package manager and try again."
        fi
        exit 1
    fi
}

detect_platform() {
    local raw_os=$(uname -s)
    os=$(echo "$raw_os" | tr '[:upper:]' '[:lower:]')
    
    # Termux detection (Android)
    if [[ -d "$PREFIX" && "$PREFIX" == "/data/data/com.termux/files/usr" ]]; then
        os="android"
        print_message "info" "📱 Detected Termux (Android) environment"
    else
        case "$raw_os" in
            Darwin*) os="darwin" ;;
            Linux*) os="linux" ;;
            MINGW*|MSYS*|CYGWIN*) os="windows" ;;
            *) error_handler "Unsupported operating system: $raw_os" ;;
        esac
    fi

    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="x64" ;;
        aarch64) arch="arm64" ;;
        armv7l|armv8l) arch="arm" ;;
        arm64) ;; # Already correct
        i386|i486|i586|i686) arch="x86" ;;
        *) error_handler "Unsupported architecture: $arch" ;;
    esac

    # Handle Rosetta on macOS
    if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
        local rosetta_flag=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
        if [[ "$rosetta_flag" == "1" ]]; then
            arch="arm64"
            print_message "info" "Detected Apple Silicon running via Rosetta, using arm64 binary"
        fi
    fi

    local combo="$os-$arch"
    case "$combo" in
        linux-x64|linux-arm64|linux-arm|darwin-x64|darwin-arm64|windows-x64|android-arm64|android-arm) ;;
        *) 
            print_message "warning" "Untested OS/Arch combination: $combo"
            print_message "info" "Trying generic Linux binary for $arch..."
            # Fall back to Linux binaries for Termux
            if [[ "$os" == "android" ]]; then
                if [[ "$arch" == "arm64" ]]; then
                    arch="arm64"
                elif [[ "$arch" == "arm" ]]; then
                    arch="arm"
                fi
                os="linux"  # Use Linux binaries on Android
            else
                error_handler "Unsupported OS/Arch combination: $combo"
            fi
            ;;
    esac
}

detect_libc() {
    is_musl=false
    if [[ "$os" == "linux" ]] || [[ "$os" == "android" ]]; then
        # Termux uses libc, but we'll check
        if [[ -f /etc/alpine-release ]]; then
            is_musl=true
        elif command -v ldd >/dev/null 2>&1; then
            if ldd --version 2>&1 | grep -qi musl; then
                is_musl=true
            fi
        fi
        
        # Termux specific - usually uses standard libc
        if [[ "$os" == "android" ]]; then
            is_musl=false
            print_message "info" "Using standard libc binary for Termux"
        fi
    fi
}

check_cpu_features() {
    needs_baseline=false
    if [[ "$arch" == "x64" ]]; then
        case "$os" in
            linux|android)
                if [[ -f /proc/cpuinfo ]] && ! grep -qi avx2 /proc/cpuinfo 2>/dev/null; then
                    needs_baseline=true
                fi
                ;;
            darwin)
                local avx2=$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)
                if [[ "$avx2" != "1" ]]; then
                    needs_baseline=true
                fi
                ;;
        esac
    fi
    
    # Android/ARM devices typically don't need baseline flags
    if [[ "$os" == "android" ]]; then
        needs_baseline=false
    fi
}

build_filename() {
    local archive_ext=".zip"
    if [[ "$os" == "linux" ]] || [[ "$os" == "android" ]]; then
        archive_ext=".tar.gz"
    fi

    local target="$os-$arch"
    if [[ "$needs_baseline" == "true" ]]; then
        target="$target-baseline"
        print_message "info" "Using baseline binary (AVX2 not available)"
    fi
    if [[ "$is_musl" == "true" ]]; then
        target="$target-musl"
        print_message "info" "Using musl binary"
    fi
    
    # Special handling for Android/Termux
    if [[ "$os" == "android" ]]; then
        # Try Linux ARM binaries for Android
        if [[ "$arch" == "arm64" ]]; then
            target="linux-arm64"
        elif [[ "$arch" == "arm" ]]; then
            target="linux-arm"
        fi
        print_message "info" "Using Linux binary for Android/Termux ($arch)"
    fi

    filename="$APP-$target$archive_ext"
}

get_version_info() {
    local requested_version="${VERSION:-}"
    
    if [[ -z "$requested_version" ]]; then
        print_message "info" "Fetching latest version..."
        local latest_info
        latest_info=$(curl -s --fail "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest") || {
            error_handler "Failed to fetch version information from GitHub"
        }
        
        specific_version=$(echo "$latest_info" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
        
        if [[ -z "$specific_version" ]]; then
            error_handler "Could not determine latest version"
        fi
    else
        specific_version="$requested_version"
    fi

    url="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/v${specific_version}/$filename"
}

check_existing_installation() {
    if command -v opencode >/dev/null 2>&1; then
        local opencode_path=$(command -v opencode)
        
        # Try to get installed version (commented out until command is available)
        # local installed_version
        # if installed_version=$(opencode version 2>/dev/null); then
        #     installed_version=$(echo "$installed_version" | awk '{print $2}')
        #     if [[ "$installed_version" == "$specific_version" ]]; then
        #         print_message "success" "Version $specific_version is already installed at $opencode_path"
        #         exit 0
        #     else
        #         print_message "info" "Updating from version $installed_version to $specific_version"
        #     fi
        # else
        #     print_message "warning" "Found existing opencode installation, but could not determine version"
        # fi
        print_message "info" "Found existing opencode installation at $opencode_path"
    fi
}

print_progress() {
    local bytes="$1"
    local length="$2"
    [[ "$length" -gt 0 ]] || return 0

    local width=50
    local percent=$(( bytes * 100 / length ))
    [[ "$percent" -gt 100 ]] && percent=100
    local on=$(( percent * width / 100 ))
    local off=$(( width - on ))

    local filled=$(printf "%*s" "$on" "")
    filled=${filled// /■}
    local empty=$(printf "%*s" "$off" "")
    empty=${empty// /･}

    printf "\r${ORANGE}%s%s %3d%%${NC}" "$filled" "$empty" "$percent" >&2
}

unbuffered_sed() {
    # Use unbuffered sed if available, otherwise use standard sed
    if sed -u -e '' </dev/null >/dev/null 2>&1; then
        sed -u "$@"
    else
        sed "$@"
    fi
}

download_with_progress() {
    local url="$1"
    local output="$2"

    # Simple download for Termux (progress often doesn't work well)
    if [[ "$os" == "android" ]]; then
        print_message "info" "Downloading..."
        curl --fail -L -o "$output" "$url" || {
            rm -f "$output"
            error_handler "Download failed"
        }
        return $?
    fi

    local tracefile
    tracefile=$(mktemp)
    
    # Hide cursor
    printf "\033[?25l" >&2

    # Start download in background
    curl --fail --trace-ascii "$tracefile" -s -L -o "$output" "$url" &
    local curl_pid=$!

    # Parse progress
    {
        local length=0 bytes=0
        unbuffered_sed \
            -e 'y/ACDEGHLNORTV/acdeghlnortv/' \
            -e '/^0000: content-length:/p' \
            -e '/^<= recv data/p' \
            "$tracefile" | \
        while IFS=" " read -r -a line; do
            [[ ${#line[@]} -lt 2 ]] && continue
            local tag="${line[0]} ${line[1]}"
            
            if [[ "$tag" == "0000: content-length:" ]]; then
                length="${line[2]//[^0-9]/}"
                bytes=0
            elif [[ "$tag" == "<= recv" ]]; then
                local size="${line[3]//[^0-9]/}"
                if [[ -n "$size" ]]; then
                    bytes=$(( bytes + size ))
                    print_progress "$bytes" "$length"
                fi
            fi
        done
    }

    wait "$curl_pid" || {
        rm -f "$tracefile" "$output"
        printf "\033[?25h" >&2
        error_handler "Download failed"
    }
    
    rm -f "$tracefile"
    printf "\033[?25h" >&2
}

download_and_install() {
    print_message "info" "Installing ${BLUE}opencode${NC} version: ${BLUE}$specific_version"
    print_message "muted" "Downloading from: $url"
    
    mkdir -p "opencodetmp" && cd "opencodetmp" || error_handler "Failed to create temporary directory"

    # Download with progress bar, fallback to simple curl if progress fails
    if ! download_with_progress "$url" "$filename"; then
        print_message "warning" "Progress display failed, using simple download"
        curl --fail -L -o "$filename" "$url" || error_handler "Download failed"
    fi

    # Extract
    print_message "info" "Installing to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    
    case "$filename" in
        *.tar.gz) tar -xzf "$filename" ;;
        *.zip) unzip -q "$filename" ;;
        *) error_handler "Unsupported archive format: $filename" ;;
    esac

    # Install
    if [[ -f "opencode" ]]; then
        mv "opencode" "$INSTALL_DIR/"
        chmod 755 "${INSTALL_DIR}/opencode"
    else
        error_handler "Downloaded archive doesn't contain 'opencode' binary"
    fi

    cd .. && rm -rf "opencodetmp"
    print_message "success" "Successfully installed opencode $specific_version"
}

detect_shell_config() {
    local current_shell=$(basename "${SHELL:-}")
    local config_files=()

    # Termux usually uses bash
    if [[ "$os" == "android" ]]; then
        current_shell="bash"
    fi

    case $current_shell in
        fish)
            config_files=(
                "$XDG_CONFIG_HOME/fish/config.fish"
                "$HOME/.config/fish/config.fish"
            )
            ;;
        zsh)
            config_files=(
                "$ZDOTDIR/.zshrc"
                "$HOME/.zshrc"
                "$HOME/.zshenv"
                "$XDG_CONFIG_HOME/zsh/.zshrc"
                "$XDG_CONFIG_HOME/zsh/.zshenv"
            )
            ;;
        bash)
            config_files=(
                "$HOME/.bashrc"
                "$HOME/.bash_profile"
                "$HOME/.profile"
                "$PREFIX/etc/bash.bashrc"  # Termux
                "$PREFIX/etc/profile"      # Termux
            )
            ;;
        ash|sh|dash)
            config_files=(
                "$HOME/.ashrc"
                "$HOME/.profile"
                "/etc/profile"
            )
            ;;
        *)
            config_files=(
                "$HOME/.bashrc"
                "$HOME/.bash_profile"
                "$HOME/.profile"
            )
            print_message "warning" "Unknown shell '$current_shell', trying common config files"
            ;;
    esac

    for file in "${config_files[@]}"; do
        if [[ -f "$file" && -w "$file" ]]; then
            echo "$file"
            return 0
        fi
    done

    # If no existing writable file found, return the first one that should exist
    if [[ "$os" == "android" ]]; then
        echo "$HOME/.bashrc"
    else
        echo "${config_files[0]}"
    fi
    return 1
}

add_to_path() {
    local config_file="$1"
    local install_dir="$2"

    if [[ ":$PATH:" == *":$install_dir:"* ]]; then
        print_message "info" "$install_dir is already in PATH"
        return 0
    fi

    local current_shell=$(basename "${SHELL:-}")
    
    # Termux override
    if [[ "$os" == "android" ]]; then
        current_shell="bash"
    fi

    local path_command=""

    case $current_shell in
        fish)
            path_command="fish_add_path $install_dir"
            ;;
        zsh|bash|ash|sh|dash|*)
            path_command="export PATH=\"$install_dir:\$PATH\""
            ;;
    esac

    if [[ ! -f "$config_file" ]]; then
        mkdir -p "$(dirname "$config_file")"
        touch "$config_file"
    fi

    if grep -q "$install_dir" "$config_file" 2>/dev/null; then
        print_message "info" "PATH already configured in $config_file"
    elif [[ -w "$config_file" ]]; then
        {
            echo ""
            echo "# opencode"
            echo "$path_command"
        } >> "$config_file"
        print_message "success" "Added opencode to PATH in $config_file"
        print_message "info" "Run 'source $config_file' or restart your terminal to use opencode"
    else
        print_message "warning" "Could not automatically add to PATH (no write permission)"
        print_message "info" "Manually add this to your shell configuration:"
        print_message "info" "  $path_command"
    fi

    # Also update current session PATH
    export PATH="$install_dir:$PATH"
}

show_success_message() {
    echo
    print_message "muted" "                    ${NC}             ▄     "
    print_message "muted" "█▀▀█ █▀▀█ █▀▀█ █▀▀▄ ${NC}█▀▀▀ █▀▀█ █▀▀█ █▀▀█"
    print_message "muted" "█░░█ █░░█ █▀▀▀ █░░█ ${NC}█░░░ █░░█ █░░█ █▀▀▀"
    print_message "muted" "▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀  ▀ ${NC}▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀"
    echo
    print_message "success" "🎉 opencode installed successfully!"
    
    # Termux-specific tips
    if [[ "$os" == "android" ]]; then
        echo
        print_message "info" "📱 Termux Tips:"
        print_message "muted" "  • Run 'source ~/.bashrc' to refresh PATH"
        print_message "muted" "  • Restart Termux if commands aren't recognized"
        print_message "muted" "  • Use opencode for mobile development on the go!"
    fi
    
    echo
    print_message "info" "To get started:"
    echo
    print_message "muted" "  opencode                   ${NC}Use free models"
    print_message "muted" "  opencode auth login        ${NC}Add paid provider API keys"
    print_message "muted" "  opencode help              ${NC}List commands and options"
    echo
    print_message "muted" "For more information visit ${BLUE}https://opencode.ai/docs${NC}"
    echo
}

check_termux_environment() {
    if [[ "$os" == "android" ]]; then
        print_message "info" "🔍 Checking Termux environment..."
        
        # Check storage permission
        if [[ ! -w "$HOME" ]]; then
            print_message "warning" "Storage permission might be needed for installation"
            print_message "info" "If you see permission errors, run:"
            print_message "info" "  termux-setup-storage"
        fi
        
        # Check if we're in a proper Termux environment
        if [[ -z "$PREFIX" ]]; then
            print_message "warning" "This doesn't appear to be a standard Termux installation"
        fi
    fi
}

main() {
    print_message "info" "Installing opencode..."
    
    detect_platform
    check_termux_environment
    check_dependencies
    detect_libc
    check_cpu_features
    build_filename
    get_version_info
    check_existing_installation
    download_and_install
    
    local config_file
    config_file=$(detect_shell_config)
    add_to_path "$config_file" "$INSTALL_DIR"
    
    # Update GitHub Actions PATH if running in CI
    if [[ -n "${GITHUB_ACTIONS-}" && "${GITHUB_ACTIONS}" == "true" ]]; then
        echo "$INSTALL_DIR" >> "$GITHUB_PATH"
        print_message "info" "Added $INSTALL_DIR to GitHub Actions PATH"
    fi
    
    show_success_message
}

main "$@"
