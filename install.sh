#!/bin/bash
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

INSTALL_URL="https://github.com/Monadical-SAS/internalai-setup/raw/main/setup.sh"
INSTALL_DIR="/usr/local/bin"
COMMAND_NAME="internalai"
INSTALL_PATH="$INSTALL_DIR/$COMMAND_NAME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# Logging Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# Installation Functions
# ============================================================================

check_requirements() {
    # Check if curl is available
    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed. Please install curl and try again."
        exit 1
    fi
}

detect_install_method() {
    # Check if we need sudo
    if [ -w "$INSTALL_DIR" ]; then
        SUDO=""
    else
        if command -v sudo &> /dev/null; then
            SUDO="sudo"
            log_info "Will use sudo for installation (requires admin privileges)"
        else
            log_error "No write permission to $INSTALL_DIR and sudo not available"
            log_info "Try running as root or installing to a user-writable location"
            exit 1
        fi
    fi
}

download_and_install() {
    log_info "Downloading InternalAI setup script..."

    # Create temporary file
    TMP_FILE=$(mktemp)
    trap "rm -f $TMP_FILE" EXIT

    # Download the script
    if ! curl -fsSL "$INSTALL_URL" -o "$TMP_FILE"; then
        log_error "Failed to download setup script from $INSTALL_URL"
        exit 1
    fi

    # Verify it's a valid bash script
    if ! head -n 1 "$TMP_FILE" | grep -q "^#!/bin/bash"; then
        log_error "Downloaded file does not appear to be a valid bash script"
        exit 1
    fi

    log_success "Downloaded setup script"

    # Install the script
    log_info "Installing to $INSTALL_PATH..."

    if [ -n "$SUDO" ]; then
        $SUDO mkdir -p "$INSTALL_DIR"
        $SUDO cp "$TMP_FILE" "$INSTALL_PATH"
        $SUDO chmod +x "$INSTALL_PATH"
    else
        mkdir -p "$INSTALL_DIR"
        cp "$TMP_FILE" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
    fi

    log_success "Installed to $INSTALL_PATH"
}

verify_installation() {
    log_info "Verifying installation..."

    # Check if the command is available
    if command -v $COMMAND_NAME &> /dev/null; then
        log_success "$COMMAND_NAME command is now available!"
        return 0
    fi

    # If not in PATH, provide instructions
    if [ -f "$INSTALL_PATH" ]; then
        log_warning "$COMMAND_NAME installed but not found in PATH"
        log_info "You may need to:"
        log_info "  1. Open a new terminal, or"
        log_info "  2. Run: export PATH=\"$INSTALL_DIR:\$PATH\""
        return 0
    fi

    log_error "Installation verification failed"
    return 1
}

show_next_steps() {
    log_header "Installation Complete!"

    echo "The 'internalai' command is now available."
    echo ""
    echo "Next steps:"
    echo "  1. Run 'internalai install' to set up the platform"
    echo "  2. Run 'internalai help' to see all available commands"
    echo "  3. Run 'internalai update' to update the CLI in the future"
    echo ""
}

# ============================================================================
# Main Installation Flow
# ============================================================================

main() {
    log_header "InternalAI Platform Installer"

    check_requirements
    detect_install_method
    download_and_install
    verify_installation
    show_next_steps

    log_success "Installation completed successfully!"
}

main "$@"
