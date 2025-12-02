#!/bin/bash
set -euo pipefail

# Monadical Platform Setup Script
# Usage: bash <(curl -fsSL https://example.com/setup.sh)

# ============================================================================
# Configuration
# ============================================================================

PLATFORM_NAME="Monadical Platform"

# Determine platform root - avoid double nesting
if [[ "$(basename $(pwd))" == "platform-workspace" ]]; then
    PLATFORM_ROOT="$(pwd)"
else
    PLATFORM_ROOT="$(pwd)/platform-workspace"
fi

CACHE_FILE="$PLATFORM_ROOT/.credentials.cache"
DOCKER_NETWORK="monadical-platform"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# Service Registry (Hardcoded)
# ============================================================================

# Format: "service_id|repo_url|branch|port|description|mandatory"
AVAILABLE_SERVICES=(
    "contactdb|https://github.com/Monadical-SAS/contactdb.git|main|42173|Unified contact management|true"
    "dataindex|https://github.com/Monadical-SAS/dataindex.git|main|42180|Data aggregation from multiple sources|true"
    "babelfish|https://github.com/Monadical-SAS/babelfish.git|authless-ux|8880|Universal communications bridge (Matrix homeserver)|false"
    # "crm-reply|https://github.com/Monadical-SAS/crm-reply.git|main|3001|AI-powered CRM reply assistant|false"
    "meeting-prep|https://github.com/Monadical-SAS/meeting-prep.git|dataindex-contactdb-integration|42380|Meeting preparation assistant|false"
    "dailydigest|https://github.com/Monadical-SAS/dailydigest.git|main|42190|Stale relationship and missing reply digest|false"
    "librechat|https://github.com/danny-avila/LibreChat.git|main|3080|AI chat interface with multiple model support|false"
)

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
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# Utility Functions
# ============================================================================

prompt() {
    local varname=$1
    local prompt_text=$2
    local default_value=$3
    local is_secret=${4:-false}

    if [ -n "$default_value" ]; then
        prompt_text="$prompt_text [${default_value}]"
    fi

    if [ "$is_secret" = true ]; then
        echo -ne "${YELLOW}${prompt_text}: ${NC}"
        value=""
        while IFS= read -r -s -n1 char; do
            # Enter key pressed
            if [[ $char == $'\0' ]]; then
                break
            fi
            # Backspace pressed
            if [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
                if [ ${#value} -gt 0 ]; then
                    value="${value%?}"
                    echo -ne "\b \b"
                fi
            else
                value+="$char"
                echo -n "*"
            fi
        done
        echo ""
    else
        read -p "$(echo -e ${YELLOW}${prompt_text}: ${NC})" value
    fi

    if [ -z "$value" ] && [ -n "$default_value" ]; then
        value="$default_value"
    fi

    eval "$varname='$value'"
}

generate_password() {
    openssl rand -hex 32
}

# ============================================================================
# Credential Cache (Optional Encryption)
# ============================================================================

CACHE_PASSWORD=""
USE_ENCRYPTION=false
IGNORE_CACHE=false

init_cache() {
    mkdir -p "$(dirname "$CACHE_FILE")"

    # If --no-cache flag is set, clear the cache
    if [ "$IGNORE_CACHE" = true ]; then
        log_warning "Ignoring cache (--no-cache flag set)"
        rm -f "$CACHE_FILE"
        touch "$CACHE_FILE"
        return
    fi

    if [ -f "$CACHE_FILE" ]; then
        # Check if encrypted
        if head -n1 "$CACHE_FILE" | grep -q "^Salted__"; then
            USE_ENCRYPTION=true
            prompt CACHE_PASSWORD "Enter cache password" "" true
        fi
    else
        prompt USE_ENCRYPTION_INPUT "Encrypt credential cache? (recommended)" "yes"
        if [ "$USE_ENCRYPTION_INPUT" = "yes" ] || [ "$USE_ENCRYPTION_INPUT" = "y" ]; then
            USE_ENCRYPTION=true
            prompt CACHE_PASSWORD "Create cache password" "" true
        fi
        touch "$CACHE_FILE"
    fi
}

save_to_cache() {
    local key=$1
    local value=$2

    if [ "$USE_ENCRYPTION" = true ]; then
        # Decrypt, append, re-encrypt
        local temp_file=$(mktemp)
        if [ -s "$CACHE_FILE" ]; then
            openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$CACHE_PASSWORD" -in "$CACHE_FILE" 2>/dev/null > "$temp_file" || true
        fi
        grep -v "^$key=" "$temp_file" > "${temp_file}.tmp" 2>/dev/null || true
        echo "$key=$value" >> "${temp_file}.tmp"
        openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$CACHE_PASSWORD" -in "${temp_file}.tmp" -out "$CACHE_FILE"
        rm -f "$temp_file" "${temp_file}.tmp"
    else
        # Plain text
        grep -v "^$key=" "$CACHE_FILE" > "${CACHE_FILE}.tmp" 2>/dev/null || true
        echo "$key=$value" >> "${CACHE_FILE}.tmp"
        mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    fi
}

load_from_cache() {
    local key=$1

    if [ ! -f "$CACHE_FILE" ]; then
        echo ""
        return
    fi

    if [ "$USE_ENCRYPTION" = true ]; then
        openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$CACHE_PASSWORD" -in "$CACHE_FILE" 2>/dev/null | grep "^$key=" | cut -d= -f2- | tail -1 || echo ""
    else
        grep "^$key=" "$CACHE_FILE" | cut -d= -f2- | tail -1 || echo ""
    fi
}

# Try to retrieve existing password from .env file
get_existing_password_from_env() {
    local env_file=$1
    local var_name=$2

    if [ ! -f "$env_file" ]; then
        echo ""
        return
    fi

    # Extract value from .env file
    grep "^${var_name}=" "$env_file" | cut -d= -f2- | tail -1 || echo ""
}

prompt_or_cache() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    local is_secret=${4:-false}
    local env_file=${5:-}

    # Check cache first
    local cached_value=$(load_from_cache "$var_name")
    if [ -n "$cached_value" ]; then
        log_info "Using cached value for $var_name"
        eval "$var_name='$cached_value'"
        return
    fi

    # If cache is empty but an .env file exists, try to get password from there
    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
        local existing_value=$(get_existing_password_from_env "$env_file" "$var_name")
        if [ -n "$existing_value" ]; then
            log_info "Using existing password from $env_file for $var_name"
            eval "$var_name='$existing_value'"
            save_to_cache "$var_name" "$existing_value"
            return
        fi
    fi

    # Handle auto-generation
    if [ "$default_value" = "auto" ]; then
        local generated=$(generate_password)
        log_info "Auto-generated $var_name"
        eval "$var_name='$generated'"
        save_to_cache "$var_name" "$generated"
        return
    fi

    # Prompt user
    prompt "$var_name" "$prompt_text" "$default_value" "$is_secret"
    local value="${!var_name}"

    if [ -n "$value" ]; then
        save_to_cache "$var_name" "$value"
    fi
}

# ============================================================================
# Docker Compose Wrapper
# ============================================================================

# Wrapper function to use either docker-compose (v1) or docker compose (v2)
docker_compose() {
    if command -v docker-compose &> /dev/null; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

# ============================================================================
# Dependency Management
# ============================================================================

check_dependencies() {
    log_header "Checking Dependencies"

    # Detect OS
    local OS_TYPE=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS_TYPE="linux"
    else
        OS_TYPE="unknown"
    fi

    # Check/Install Git
    if ! command -v git &> /dev/null; then
        log_info "Git not found, installing..."
        case "$OS_TYPE" in
            macos)
                if command -v brew &> /dev/null; then
                    brew install git
                else
                    log_error "Homebrew not found. Please install Homebrew first: https://brew.sh"
                    exit 1
                fi
                ;;
            linux)
                if command -v apt-get &> /dev/null; then
                    sudo apt-get update && sudo apt-get install -y git
                elif command -v yum &> /dev/null; then
                    sudo yum install -y git
                elif command -v dnf &> /dev/null; then
                    sudo dnf install -y git
                else
                    log_error "Package manager not found. Please install git manually."
                    exit 1
                fi
                ;;
            *)
                log_error "Unsupported OS. Please install git manually."
                exit 1
                ;;
        esac
        log_success "Git installed: $(git --version)"
    else
        log_success "Git installed: $(git --version)"
    fi

    # Check/Install Docker
    if ! command -v docker &> /dev/null; then
        log_info "Docker not found, installing..."
        case "$OS_TYPE" in
            macos)
                if command -v brew &> /dev/null; then
                    log_info "Installing Docker Desktop via Homebrew..."
                    brew install --cask docker
                    log_warning "Docker Desktop installed. Please start Docker Desktop from Applications and then re-run this script."
                    exit 0
                else
                    log_error "Homebrew not found. Please install Docker Desktop manually: https://www.docker.com/products/docker-desktop"
                    exit 1
                fi
                ;;
            linux)
                log_info "Installing Docker Engine..."
                if command -v apt-get &> /dev/null; then
                    # Ubuntu/Debian
                    sudo apt-get update
                    sudo apt-get install -y ca-certificates curl gnupg lsb-release
                    sudo mkdir -p /etc/apt/keyrings
                    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                    sudo apt-get update
                    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                    sudo systemctl start docker
                    sudo systemctl enable docker
                    # Add user to docker group
                    sudo usermod -aG docker $USER
                    log_warning "Docker installed. Please log out and back in for group changes to take effect, then re-run this script."
                    exit 0
                elif command -v yum &> /dev/null; then
                    # CentOS/RHEL
                    sudo yum install -y yum-utils
                    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                    sudo systemctl start docker
                    sudo systemctl enable docker
                    sudo usermod -aG docker $USER
                    log_warning "Docker installed. Please log out and back in for group changes to take effect, then re-run this script."
                    exit 0
                else
                    log_error "Package manager not found. Please install Docker manually: https://docs.docker.com/engine/install/"
                    exit 1
                fi
                ;;
            *)
                log_error "Unsupported OS. Please install Docker manually: https://docs.docker.com/get-docker/"
                exit 1
                ;;
        esac
    else
        log_success "Docker installed: $(docker --version)"

        # Check if Docker daemon is running
        if ! docker ps &> /dev/null; then
            log_error "Docker is installed but not running. Please start Docker and try again."
            if [[ "$OS_TYPE" == "macos" ]]; then
                log_info "Start Docker Desktop from Applications"
            elif [[ "$OS_TYPE" == "linux" ]]; then
                log_info "Run: sudo systemctl start docker"
            fi
            exit 1
        fi
    fi

    # Check/Install Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null 2>&1; then
        log_info "Docker Compose not found, installing..."
        case "$OS_TYPE" in
            macos)
                if command -v brew &> /dev/null; then
                    brew install docker-compose
                else
                    log_error "Homebrew not found. Docker Compose should come with Docker Desktop."
                    exit 1
                fi
                ;;
            linux)
                # Install docker-compose standalone
                log_info "Installing Docker Compose standalone..."
                sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                sudo chmod +x /usr/local/bin/docker-compose
                ;;
            *)
                log_error "Unsupported OS. Please install Docker Compose manually."
                exit 1
                ;;
        esac
        log_success "Docker Compose installed"
    else
        log_success "Docker Compose installed"
    fi

    # Check/Install make
    if ! command -v make &> /dev/null; then
        log_info "Installing make..."
        case "$OS_TYPE" in
            macos)
                # make comes with Xcode Command Line Tools
                if ! xcode-select -p &> /dev/null; then
                    log_info "Installing Xcode Command Line Tools (includes make)..."
                    xcode-select --install
                    log_warning "Please complete Xcode Command Line Tools installation and re-run this script"
                    exit 0
                fi
                ;;
            linux)
                if command -v apt-get &> /dev/null; then
                    sudo apt-get update && sudo apt-get install -y build-essential
                elif command -v yum &> /dev/null; then
                    sudo yum groupinstall -y "Development Tools"
                elif command -v dnf &> /dev/null; then
                    sudo dnf groupinstall -y "Development Tools"
                else
                    log_error "Package manager not found. Please install make manually."
                    exit 1
                fi
                ;;
            *)
                log_error "Unsupported OS. Please install make manually."
                exit 1
                ;;
        esac
        log_success "make installed"
    else
        log_success "make installed: $(make --version | head -n1)"
    fi

    log_success "All dependencies installed"
}

# ============================================================================
# GitHub Authentication
# ============================================================================

setup_github_auth() {
    log_header "GitHub Authentication"

    # Check cache for auth type
    local cached_auth_type=$(load_from_cache "AUTH_TYPE")
    if [ -n "$cached_auth_type" ]; then
        AUTH_TYPE="$cached_auth_type"
        log_info "Using cached authentication method: $AUTH_TYPE"
    else
        prompt AUTH_TYPE "Authentication method (ssh/token/none)" "ssh"
        save_to_cache "AUTH_TYPE" "$AUTH_TYPE"
    fi

    case "$AUTH_TYPE" in
        token)
            prompt_or_cache "GITHUB_TOKEN" "GitHub Personal Access Token" "" true
            if [ -z "$GITHUB_TOKEN" ]; then
                log_error "GitHub token is required"
                log_info "Create token at: https://github.com/settings/tokens"
                exit 1
            fi
            log_success "GitHub token configured"
            ;;
        ssh)
            log_info "Using SSH authentication (ensure keys are configured)"
            GITHUB_TOKEN=""
            ;;
        none)
            log_info "No authentication (public repos only)"
            GITHUB_TOKEN=""
            ;;
        *)
            log_error "Invalid auth type: $AUTH_TYPE"
            exit 1
            ;;
    esac
}

prepare_git_url() {
    local git_repo=$1

    if [ "$AUTH_TYPE" = "token" ] && [ -n "$GITHUB_TOKEN" ]; then
        if [[ "$git_repo" =~ ^https://github.com/ ]]; then
            echo "$git_repo" | sed "s|https://github.com/|https://${GITHUB_TOKEN}@github.com/|"
            return
        fi
    fi

    echo "$git_repo"
}

# ============================================================================
# Service Selection
# ============================================================================

SELECTED_SERVICES=()

select_services() {
    log_header "Service Selection"

    # Always add mandatory services first
    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
        if [ "$mandatory" = "true" ]; then
            SELECTED_SERVICES+=("$id")
        fi
    done

    # Check cache for optional services
    local cached_services=$(load_from_cache "SELECTED_OPTIONAL_SERVICES")
    if [ -n "$cached_services" ]; then
        if [ "$cached_services" != "none" ]; then
            IFS=',' read -ra optional_services <<< "$cached_services"
            SELECTED_SERVICES+=("${optional_services[@]}")
        fi
        log_info "Using cached service selection: ${SELECTED_SERVICES[*]}"
        return
    fi

    echo "Mandatory services: contactdb, dataindex"
    echo ""
    echo "Optional services:"
    echo ""

    local index=1
    local optional_services=()
    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
        if [ "$mandatory" = "false" ]; then
            echo -e "  ${CYAN}${index}.${NC} ${desc} (${id})"
            optional_services+=("$service_def")
            ((index++))
        fi
    done

    echo ""
    prompt SERVICES_INPUT "Enter optional service numbers (comma-separated) or 'none'" "none"

    local selected_optional=()
    if [ "$SERVICES_INPUT" != "none" ]; then
        IFS=',' read -ra INDICES <<< "$SERVICES_INPUT"
        for idx in "${INDICES[@]}"; do
            idx=$(echo "$idx" | xargs) # trim
            service_def="${optional_services[$((idx-1))]}"
            IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
            SELECTED_SERVICES+=("$id")
            selected_optional+=("$id")
        done
    fi

    # Save optional services to cache
    if [ ${#selected_optional[@]} -gt 0 ]; then
        local optional_str=$(IFS=','; echo "${selected_optional[*]}")
        save_to_cache "SELECTED_OPTIONAL_SERVICES" "$optional_str"
    else
        save_to_cache "SELECTED_OPTIONAL_SERVICES" "none"
    fi

    log_success "Selected: ${SELECTED_SERVICES[*]}"
}

# ============================================================================
# Enrichment API Configuration (Global)
# ============================================================================

setup_enrichment_apis() {
    log_header "Contact Enrichment APIs (Optional)"

    log_info "These API keys will be used across ContactDB, CRM Reply, and Meeting Prep"
    log_info "Press Enter to skip if you don't have these keys"
    echo ""

    prompt_or_cache "APOLLO_API_KEY" "Apollo API key (optional)" "" true
    prompt_or_cache "HUNTER_API_KEY" "Hunter API key (optional)" "" true

    if [ -n "$APOLLO_API_KEY" ] || [ -n "$HUNTER_API_KEY" ]; then
        log_success "Enrichment API keys configured"
    else
        log_info "Skipping enrichment API keys - services will work without them"
    fi
}

# ============================================================================
# Caddy Reverse Proxy Configuration
# ============================================================================

setup_caddy() {
    log_header "Caddy Reverse Proxy Setup"

    # Check if Caddy is already configured and running
    local caddy_configured=$(load_from_cache "CADDY_CONFIGURED")
    if [ "$caddy_configured" = "true" ] && [ "$IGNORE_CACHE" != "true" ]; then
        log_info "Caddy already configured"
        return
    fi

    log_info "Caddy reverse proxy is required for the platform"

    # Generate or retrieve password
    local caddy_password=$(load_from_cache "CADDY_PASSWORD")
    local show_password=false

    if [ -z "$caddy_password" ]; then
        # Generate new password
        caddy_password=$(openssl rand -base64 24)
        save_to_cache "CADDY_PASSWORD" "$caddy_password"
        show_password=true
    fi

    # Generate password hash using Docker (since we may not have caddy installed yet)
    log_info "Generating password hash..."
    local password_hash=$(docker run --rm thekevjames/caddy-security:latest caddy hash-password --plaintext "$caddy_password" 2>/dev/null)

    if [ -z "$password_hash" ]; then
        log_error "Failed to generate password hash"
        return 1
    fi

    save_to_cache "CADDY_PASSWORD_HASH" "$password_hash"

    # Show password (only once, first time)
    if [ "$show_password" = true ]; then
        echo ""
        log_warning "====================================================================="
        log_warning "  INTERNALAI PORTAL PASSWORD - SAVE THIS NOW!"
        log_warning "====================================================================="
        log_warning ""
        log_warning "  Username: admin"
        log_warning "  Password: $caddy_password"
        log_warning ""
        log_warning "  This password will NOT be shown again!"
        log_warning "  Use '$0 caddy new-password' to create a new one"
        log_warning "====================================================================="
        echo ""
        read -p "Press Enter after you have saved the password..."
    fi

    # Ask for domain
    local cached_domain=$(load_from_cache "CADDY_DOMAIN")
    if [ -n "$cached_domain" ]; then
        log_info "Using cached domain: $cached_domain"
        CADDY_DOMAIN="$cached_domain"
    else
        echo ""
        log_info "Enter the full URL or domain where services will be accessed:"
        log_info ""
        log_info "Examples:"
        log_info "  • For local access:        http://localhost:8080"
        log_info "  • For HTTPS domain:        example.com (auto https)"
        log_info "  • For explicit HTTPS:      https://mydomain.example.com (auto https)"
        log_info "  • For explicit HTTP:       http://example.com:8080"
        log_info ""
        log_info "Note: Domains without http:// or https:// will use HTTPS by default"
        echo ""

        prompt CADDY_DOMAIN "Full URL or domain (leave empty for http://localhost)" ""

        if [ -n "$CADDY_DOMAIN" ]; then
            # Extract domain for DNS verification (remove protocol and port)
            local domain_for_dns=$(echo "$CADDY_DOMAIN" | sed -E 's#^https?://##' | sed 's/:.*//')

            # Only verify DNS if it's not localhost
            if [[ ! "$domain_for_dns" =~ localhost ]]; then
                verify_domain_dns "$domain_for_dns"
            fi
        fi

        save_to_cache "CADDY_DOMAIN" "$CADDY_DOMAIN"
    fi

    # Create Caddy directory
    mkdir -p "$PLATFORM_ROOT/caddy"

    # Generate JWT signing key for caddy-security (if not exists)
    generate_jwt_signing_key

    # Generate users.json with password hash
    generate_users_json

    # Generate Caddyfile with caddy-security configuration
    generate_caddyfile "$CADDY_DOMAIN" "$password_hash"

    # Generate docker-compose for Caddy
    generate_caddy_compose

    # Mark as configured
    save_to_cache "CADDY_CONFIGURED" "true"

    # Derive and save public base URL
    derive_public_base_url "$CADDY_DOMAIN"

    log_success "Caddy configured successfully!"
}

derive_public_base_url() {
    local domain=$1
    local public_base_url

    if [ -z "$domain" ]; then
        # No domain, use localhost
        public_base_url="http://localhost"
    elif [[ "$domain" =~ ^https?:// ]]; then
        # Already has protocol (http:// or https://), use as-is
        public_base_url="$domain"
    else
        # No protocol specified, default to HTTPS
        public_base_url="https://${domain}"
    fi

    save_to_cache "PUBLIC_BASE_URL" "$public_base_url"
    log_info "Public base URL: $public_base_url"
}

verify_domain_dns() {
    local domain=$1

    log_info "Verifying DNS for $domain..."

    # Get server's public IP
    local server_ip=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://icanhazip.com 2>/dev/null)

    if [ -z "$server_ip" ]; then
        log_warning "Could not determine server's public IP"
        prompt IGNORE_DNS "Continue without DNS verification?" "yes"
        if [ "$IGNORE_DNS" != "yes" ] && [ "$IGNORE_DNS" != "y" ]; then
            return 1
        fi
        return 0
    fi

    log_info "Server IP: $server_ip"

    # Resolve domain
    local domain_ip=$(dig +short "$domain" @8.8.8.8 | tail -n1)

    if [ -z "$domain_ip" ]; then
        log_warning "Could not resolve domain: $domain"
        prompt IGNORE_DNS "Continue anyway?" "yes"
        if [ "$IGNORE_DNS" != "yes" ] && [ "$IGNORE_DNS" != "y" ]; then
            return 1
        fi
        return 0
    fi

    log_info "Domain resolves to: $domain_ip"

    if [ "$domain_ip" != "$server_ip" ]; then
        log_warning "DNS mismatch!"
        log_warning "  Domain $domain resolves to: $domain_ip"
        log_warning "  Server IP is: $server_ip"
        log_warning ""
        log_warning "Caddy will not be able to obtain Let's Encrypt certificates automatically."
        log_warning "You may need to update your DNS records or use manual certificates."
        echo ""
        prompt IGNORE_DNS_MISMATCH "Continue with this domain anyway?" "yes"
        if [ "$IGNORE_DNS_MISMATCH" != "yes" ] && [ "$IGNORE_DNS_MISMATCH" != "y" ]; then
            return 1
        fi
    else
        log_success "DNS verification passed!"
    fi

    return 0
}

generate_index_html() {
    log_info "Generating HTML index..."

    mkdir -p "$PLATFORM_ROOT/caddy/www"

    # Determine which services are configured
    local services_html=""
    local has_services=false

    # Check each service
    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"

        # Check if service directory exists (service was configured)
        if [ -d "$PLATFORM_ROOT/$id" ]; then
            has_services=true

            # Build service card HTML based on service type
            case "$id" in
                contactdb)
                    services_html+="
                <div class=\"service-card\">
                    <h3>📇 ContactDB</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/contactdb/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                        <a href=\"/contactdb-api/\" target=\"_blank\" class=\"btn btn-secondary\">API</a>
                    </div>
                </div>"
                    ;;
                dataindex)
                    services_html+="
                <div class=\"service-card\">
                    <h3>📊 DataIndex</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/dataindex/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                    </div>
                </div>"
                    ;;
                babelfish)
                    services_html+="
                <div class=\"service-card\">
                    <h3>🐠 Babelfish</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/babelfish/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                        <a href=\"/babelfish/chat\" target=\"_blank\" class=\"btn btn-secondary\">Chat</a>
                    </div>
                </div>"
                    ;;
                crm-reply)
                    services_html+="
                <div class=\"service-card\">
                    <h3>💬 CRM Reply</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/crm-reply/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                    </div>
                </div>"
                    ;;
                meeting-prep)
                    services_html+="
                <div class=\"service-card\">
                    <h3>📅 Meeting Prep</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/meeting-prep/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                    </div>
                </div>"
                    ;;
                dailydigest)
                    services_html+="
                <div class=\"service-card\">
                    <h3>📧 DailyDigest</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/dailydigest/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                    </div>
                </div>"
                    ;;
                librechat)
                    services_html+="
                <div class=\"service-card\">
                    <h3>💬 LibreChat</h3>
                    <p>$desc</p>
                    <div class=\"links\">
                        <a href=\"/librechat/\" target=\"_blank\" class=\"btn btn-primary\">Open</a>
                        <a href=\"/librechat/register\" target=\"_blank\" class=\"btn btn-secondary\">Register</a>
                    </div>
                </div>"
                    ;;
            esac
        fi
    done

    # If no services configured, show message
    if [ "$has_services" = false ]; then
        services_html="
            <div class=\"service-card\">
                <h3>No Services Configured</h3>
                <p>Run the setup script to configure and start services.</p>
            </div>"
    fi

    cat > "$PLATFORM_ROOT/caddy/www/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Monadical Platform</title>
    <style>
        /* Monadical Design System - Inlined for self-contained use */
        :root {
            /* Typography */
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.5;
            font-weight: 400;

            /* Border Radius */
            --radius: 0.625rem;

            /* Colors (RGB format) */
            --background: 245 245 240;
            --foreground: 37 37 37;
            --card: 255 255 255;
            --card-foreground: 37 37 37;
            --primary: 45 125 94;
            --primary-foreground: 255 255 255;
            --secondary: 245 241 233;
            --secondary-foreground: 80 70 60;
            --muted: 230 230 225;
            --muted-foreground: 115 115 115;
            --accent: 232 150 78;
            --accent-foreground: 37 37 37;
            --border: 220 220 215;
            --ring: 45 125 94;
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            border-color: rgb(var(--border));
        }

        body {
            margin: 0;
            min-height: 100vh;
            background-color: rgb(var(--background));
            color: rgb(var(--foreground));
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 2rem 1.5rem;
        }

        header {
            text-align: center;
            margin-bottom: 3rem;
            padding: 2rem 0;
        }

        header h1 {
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 0.5rem;
            color: rgb(var(--foreground));
        }

        header p {
            font-size: 1.125rem;
            color: rgb(var(--muted-foreground));
        }

        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 1.5rem;
            margin-bottom: 3rem;
        }

        .service-card {
            background: rgb(var(--card));
            border: 1px solid rgb(var(--border));
            border-radius: calc(var(--radius) + 4px);
            padding: 1.5rem;
            box-shadow: 0 1px 3px 0 rgba(0, 0, 0, 0.1), 0 1px 2px -1px rgba(0, 0, 0, 0.1);
            transition: all 0.2s ease;
        }

        .service-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -2px rgba(0, 0, 0, 0.1);
        }

        .service-card h3 {
            font-size: 1.25rem;
            font-weight: 600;
            margin-bottom: 0.5rem;
            color: rgb(var(--card-foreground));
        }

        .service-card p {
            font-size: 0.875rem;
            margin-bottom: 1rem;
            color: rgb(var(--muted-foreground));
            line-height: 1.5;
        }

        .links {
            display: flex;
            gap: 0.75rem;
            flex-wrap: wrap;
        }

        .btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            white-space: nowrap;
            font-size: 0.875rem;
            font-weight: 500;
            height: 2.25rem;
            padding: 0 1rem;
            border-radius: var(--radius);
            text-decoration: none;
            transition: all 0.2s ease;
            border: none;
            cursor: pointer;
        }

        .btn-primary {
            background-color: rgb(var(--primary));
            color: rgb(var(--primary-foreground));
            box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05);
        }

        .btn-primary:hover {
            background-color: rgba(45, 125, 94, 0.9);
        }

        .btn-secondary {
            background-color: rgb(var(--secondary));
            color: rgb(var(--secondary-foreground));
            border: 1px solid rgba(80, 70, 60, 0.2);
            box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05);
        }

        .btn-secondary:hover {
            background-color: rgba(245, 241, 233, 0.8);
        }

        footer {
            text-align: center;
            padding: 2rem 0;
            border-top: 1px solid rgb(var(--border));
            margin-top: 3rem;
        }

        footer p {
            font-size: 0.875rem;
            color: rgb(var(--muted-foreground));
            margin: 0.25rem 0;
        }

        footer a {
            color: rgb(var(--primary));
            text-decoration: underline;
            text-underline-offset: 4px;
        }

        footer a:hover {
            color: rgba(45, 125, 94, 0.9);
        }

        @media (max-width: 768px) {
            .container {
                padding: 1rem;
            }

            header h1 {
                font-size: 2rem;
            }

            header p {
                font-size: 1rem;
            }

            .services-grid {
                grid-template-columns: 1fr;
                gap: 1rem;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>InternalAI Platform</h1>
        </header>

        <div class="services-grid">
HTMLEOF

    # Insert services HTML dynamically
    echo "$services_html" >> "$PLATFORM_ROOT/caddy/www/index.html"

    # Close the HTML
    cat >> "$PLATFORM_ROOT/caddy/www/index.html" <<'HTMLEOF'
        </div>

        <footer>
HTMLEOF
    echo "            <p>Generated on $(date)</p>" >> "$PLATFORM_ROOT/caddy/www/index.html"
    cat >> "$PLATFORM_ROOT/caddy/www/index.html" <<'HTMLEOF'
            <p><a href="https://github.com/Monadical-SAS" target="_blank">Monadical SAS</a></p>
        </footer>
    </div>
</body>
</html>
HTMLEOF

    log_success "HTML index generated at $PLATFORM_ROOT/caddy/www/index.html"
}

generate_jwt_signing_key() {
    log_info "Generating JWT signing key for caddy-security..."

    # Check if key already exists in cache
    local jwt_key=$(load_from_cache "JWT_SHARED_KEY")

    if [ -n "$jwt_key" ]; then
        log_info "Using existing JWT key from cache"
        return 0
    fi

    # Generate new JWT signing key
    jwt_key=$(openssl rand -base64 32)

    if [ -z "$jwt_key" ]; then
        log_error "Failed to generate JWT signing key"
        return 1
    fi

    # Save to cache
    save_to_cache "JWT_SHARED_KEY" "$jwt_key"

    log_success "JWT signing key generated and cached"
}

generate_users_json() {
    log_info "Generating users.json for caddy-security..."

    # Get cached password hash
    local password_hash=$(load_from_cache "CADDY_PASSWORD_HASH")

    if [ -z "$password_hash" ]; then
        log_error "No password hash found in cache"
        return 1
    fi

    # Generate UUID for user ID (or use cached one)
    local user_id=$(load_from_cache "CADDY_USER_ID")
    if [ -z "$user_id" ]; then
        # Generate new UUID
        user_id=$(cat /proc/sys/kernel/random/uuid)
        save_to_cache "CADDY_USER_ID" "$user_id"
    fi

    # Get current timestamp
    local created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Create users.json file with correct format
    cat > "$PLATFORM_ROOT/caddy/users.json" <<EOF
{
  "users": [
    {
      "id": "$user_id",
      "username": "admin",
      "passwords": [
        {
          "purpose": "generic",
          "algorithm": "bcrypt",
          "hash": "$password_hash",
          "cost": 10,
          "expired_at": "0001-01-01T00:00:00Z",
          "created_at": "$created_at",
          "disabled_at": "0001-01-01T00:00:00Z"
        }
      ],
      "created": "$created_at",
      "last_modified": "0001-01-01T00:00:00Z",
      "roles": [
        {
          "name": "authp/admin"
        }
      ]
    }
  ]
}
EOF

    log_success "users.json generated at $PLATFORM_ROOT/caddy/users.json"
}

generate_service_routes() {
    # Generate Caddy routes for configured services only
    local configured_services=($(get_configured_services))
    local routes=""

    for service in "${configured_services[@]}"; do
        case "$service" in
            contactdb)
                routes+="
    # ContactDB Frontend
    handle /contactdb/* {
        reverse_proxy host.docker.internal:42173 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }

    # ContactDB Backend API
    handle_path /contactdb-api/* {
        reverse_proxy host.docker.internal:42800 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }
"
                ;;
            dataindex)
                routes+="
    # DataIndex API
    handle /dataindex/* {
        reverse_proxy host.docker.internal:42180 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }
"
                ;;
            babelfish)
                routes+="
    # Element Web - Auto-login landing page (exact match, no trailing slash)
    # This serves the auto-login page that sets up credentials and redirects to Element
    handle /babelfish/chat {
        rewrite * /element-autologin
        reverse_proxy host.docker.internal:3000 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }

    # Element Web (Matrix Web Client) - with trailing slash or subpaths
    # MUST come before general /babelfish/* handler to match first
    handle_path /babelfish/chat/* {
        reverse_proxy host.docker.internal:8880 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }

    # Babelfish Bridge UI (Management Interface and API)
    # Using handle_path strips /babelfish prefix when proxying
    # So /babelfish/api/bridges/status -> port 3000 as /api/bridges/status
    handle_path /babelfish/* {
        reverse_proxy host.docker.internal:3000 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }
"
                ;;
            crm-reply)
                routes+="
    # CRM Reply API
    handle_path /crm-reply/* {
        reverse_proxy host.docker.internal:3001 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }
"
                ;;
            meeting-prep)
                routes+="
    # Meeting Prep Frontend
    handle /meeting-prep/* {
        reverse_proxy host.docker.internal:42380 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }

    # Meeting Prep Backend API
    handle_path /meeting-prep-api/* {
        reverse_proxy host.docker.internal:42381 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }
"
                ;;
            dailydigest)
                routes+="
    # DailyDigest (Frontend and Backend merged)
    handle /dailydigest/* {
        reverse_proxy host.docker.internal:42190 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }
"
                ;;
            librechat)
                routes+="
    # LibreChat Frontend (requires auth, handled by general authorization above)
    handle_path /librechat/* {
        reverse_proxy host.docker.internal:3080 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_down >Set-Cookie (.*) \"\$1; Path=/librechat\"
        }
    }
"
                ;;
        esac
    done

    echo "$routes"
}

generate_caddyfile() {
    local domain=$1
    local password_hash=$2

    log_info "Generating Caddyfile..."

    # Extract domain without protocol for Caddy address
    local caddy_address
    local tls_config=""

    if [ -z "$domain" ]; then
        # No domain provided, use port 80
        caddy_address=":80"
    elif [[ "$domain" =~ ^http:// ]]; then
        # Explicit HTTP, strip protocol
        caddy_address="${domain#http://}"
    elif [[ "$domain" =~ ^https:// ]]; then
        # Explicit HTTPS, strip protocol and enable auto TLS
        caddy_address="${domain#https://}"
        tls_config="    # Automatic HTTPS via Let's Encrypt"
    else
        # No protocol, assume HTTPS
        caddy_address="$domain"
        tls_config="    # Automatic HTTPS via Let's Encrypt"
    fi

    # Generate HTML index file
    generate_index_html

    cat > "$PLATFORM_ROOT/caddy/Caddyfile" <<EOF
# Caddy reverse proxy configuration for Monadical Platform
# Generated on $(date)
{
    # Critical: Set order for security directives
    order authenticate before respond
    order authorize before reverse_proxy

    security {
        # Local identity store for user database
        local identity store localdb {
            realm local
            path /data/users.json
        }

        # Authentication portal configuration
        authentication portal internalai_portal {
            # CRITICAL: Use persistent crypto key to survive restarts
            crypto key sign-verify {env.JWT_SHARED_KEY}

            # JWT token lifetime - 30 days for long sessions
            crypto default token lifetime 2592000
            crypto default token name internalai-token

            # Enable the local user database
            enable identity store localdb

            # Cookie configuration
            cookie domain $caddy_address
            cookie lifetime 2592000

            # UI customization
            ui {
                links {
                    "Platform Home" "/" icon "las la-home"
                    "My Identity" "/auth/whoami" icon "las la-user"
                }
            }

            # Assign admin role to local users
            transform user {
                match origin local
                action add role authp/admin
            }
        }

        # Authorization policy
        authorization policy internalai_policy {
            # CRITICAL: Must use same key for token verification
            crypto key verify {env.JWT_SHARED_KEY}
            crypto default token name internalai-token

            set auth url /auth
            allow roles authp/admin

            acl rule {
                comment "Allow authenticated admins"
                match role authp/admin
                allow stop log info
            }
        }
    }
}

$caddy_address {
$tls_config

    # Authentication portal routes - NO authorization on these!
    # Must come FIRST
    handle /auth* {
        authenticate with internalai_portal
    }

    # Matrix Synapse API endpoints (NO authorization - Matrix has its own auth)
    # Must come BEFORE the authorization route block
    handle /_matrix/* {
        reverse_proxy host.docker.internal:8448 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            # WebSocket support for Matrix sync
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}
        }
    }

    # Matrix Synapse admin API
    handle /_synapse/* {
        reverse_proxy host.docker.internal:8448 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }

    # Matrix well-known delegation
    handle /.well-known/matrix/* {
        reverse_proxy host.docker.internal:8090 {
            header_up Host {http.reverse_proxy.upstream.hostport}
        }
    }

    # Element Web service worker - NO authorization (required for SW registration)
    # Service workers cannot handle 302 redirects, must get direct 200 response
    handle /babelfish/chat/sw.js {
        rewrite * /sw.js
        reverse_proxy host.docker.internal:8880 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
        }
    }

    # Apply authorization to all OTHER routes (services + root)
    # This checks for valid JWT cookie and contains all protected routes
    route /* {
        authorize with internalai_policy

        # Root path - serve HTML index
        handle / {
            root * /srv
            file_server
        }
EOF

    # Generate and append service routes dynamically (inside the route block)
    generate_service_routes >> "$PLATFORM_ROOT/caddy/Caddyfile"

    # Append closing section (closes route block and site block)
    cat >> "$PLATFORM_ROOT/caddy/Caddyfile" <<'EOF'
    }

    # Logging
    log {
        output stdout
        format console
        level INFO
    }
}
EOF

    log_success "Caddyfile generated at $PLATFORM_ROOT/caddy/Caddyfile"
}

generate_caddy_compose() {
    log_info "Generating Caddy docker-compose..."

    local caddy_domain=$(load_from_cache "CADDY_DOMAIN")

    # Determine which ports to bind based on the domain/URL
    local bind_80=false
    local bind_443=false
    local custom_port=""

    if [ -z "$caddy_domain" ]; then
        # No domain - localhost only, bind port 80
        bind_80=true
    elif [[ "$caddy_domain" =~ ^https:// ]]; then
        # Explicit HTTPS - bind both 80 (for redirect) and 443
        bind_80=true
        bind_443=true
    elif [[ "$caddy_domain" =~ ^http://([^:]+):([0-9]+)$ ]]; then
        # HTTP with custom port - bind only that port
        custom_port="${BASH_REMATCH[2]}"
    elif [[ "$caddy_domain" =~ ^http:// ]]; then
        # HTTP without port - bind only port 80
        bind_80=true
    else
        # No protocol specified - assume HTTPS, bind both 80 and 443
        bind_80=true
        bind_443=true
    fi

    # Generate .env file with JWT key
    generate_jwt_signing_key
    local jwt_key=$(load_from_cache "JWT_SHARED_KEY")
    if [ -n "$jwt_key" ]; then
        cat > "$PLATFORM_ROOT/caddy/.env" <<EOF
JWT_SHARED_KEY=$jwt_key
EOF
        log_info ".env file created with JWT_SHARED_KEY"
    else
        log_warning "JWT_SHARED_KEY not found in cache, .env file not created"
    fi

    # Generate docker-compose with conditional ports
    cat > "$PLATFORM_ROOT/caddy/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: thekevjames/caddy-security:latest
    container_name: monadical-caddy
    restart: unless-stopped
    ports:
EOF

    # Add ports based on what we determined
    if [ -n "$custom_port" ]; then
        echo "      - ${custom_port}:${custom_port}" >> "$PLATFORM_ROOT/caddy/docker-compose.yml"
    else
        if [ "$bind_80" = true ]; then
            echo "      - 80:80" >> "$PLATFORM_ROOT/caddy/docker-compose.yml"
        fi
        if [ "$bind_443" = true ]; then
            echo "      - 443:443" >> "$PLATFORM_ROOT/caddy/docker-compose.yml"
        fi
    fi

    # Continue with rest of the compose file
    cat >> "$PLATFORM_ROOT/caddy/docker-compose.yml" <<'EOF'
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./www:/srv:ro
      - ./users.json:/data/users.json:rw
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - monadical-platform
    # Enable access to host services via host.docker.internal
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - CADDY_ADMIN=0.0.0.0:2019
      - JWT_SHARED_KEY=${JWT_SHARED_KEY}
    env_file:
      - .env
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  caddy_data:
    name: monadical_caddy_data
  caddy_config:
    name: monadical_caddy_config

networks:
  monadical-platform:
    external: true
    name: monadical-platform
EOF

    log_success "Caddy docker-compose generated at $PLATFORM_ROOT/caddy/docker-compose.yml"
}

start_caddy() {
    log_header "Starting Caddy"

    cd "$PLATFORM_ROOT/caddy"

    if [ ! -f "docker-compose.yml" ]; then
        log_error "Caddy not configured. Run install first."
        return 1
    fi

    docker_compose up -d

    log_success "Caddy started"

    # Show access info
    local domain=$(load_from_cache "CADDY_DOMAIN")
    local url="http://${domain:-localhost}"

    echo ""
    log_info "Caddy is now running!"
    log_info "Access your services at: $url"
    log_info "Username: admin"
    log_info "Password: (saved in cache)"
    echo ""
}

stop_caddy() {
    log_header "Stopping Caddy"

    cd "$PLATFORM_ROOT/caddy"

    if [ ! -f "docker-compose.yml" ]; then
        log_warning "Caddy docker-compose not found"
        return 0
    fi

    docker_compose down

    log_success "Caddy stopped"
}

reload_caddy() {
    log_info "Reloading Caddy configuration..."

    if [ ! -f "$PLATFORM_ROOT/caddy/docker-compose.yml" ]; then
        log_warning "Caddy not configured, skipping reload"
        return 0
    fi

    # Check if Caddy is running
    cd "$PLATFORM_ROOT/caddy"
    if ! docker_compose ps | grep -q "Up"; then
        log_warning "Caddy is not running, skipping reload"
        return 0
    fi

    # Regenerate Caddyfile with current services
    local domain=$(load_from_cache "CADDY_DOMAIN")
    local password_hash=$(load_from_cache "CADDY_PASSWORD_HASH")

    if [ -z "$password_hash" ]; then
        log_error "Cannot regenerate Caddyfile: password hash not found in cache"
        return 1
    fi

    generate_caddyfile "$domain" "$password_hash"

    # Reload Caddy configuration (caddy reload inside container)
    docker exec monadical-caddy caddy reload --config /etc/caddy/Caddyfile 2>&1 | grep -v "password" || {
        log_warning "Direct reload failed, restarting Caddy container instead..."
        docker_compose restart
    }

    log_success "Caddy configuration reloaded"
}

cmd_regenerate_password() {
    log_header "Regenerating Caddy Password"

    init_cache

    # Generate new password
    local new_password=$(openssl rand -base64 24)

    # Generate hash
    log_info "Generating password hash..."
    local password_hash=$(docker run --rm thekevjames/caddy-security:latest caddy hash-password --plaintext "$new_password" 2>/dev/null)

    if [ -z "$password_hash" ]; then
        log_error "Failed to generate password hash"
        return 1
    fi

    # Save to cache
    save_to_cache "CADDY_PASSWORD" "$new_password"
    save_to_cache "CADDY_PASSWORD_HASH" "$password_hash"

    # Regenerate users.json with new password hash
    generate_users_json

    # Regenerate Caddyfile
    local domain=$(load_from_cache "CADDY_DOMAIN")
    generate_caddyfile "$domain" "$password_hash"

    # Show new password
    echo ""
    log_warning "====================================================================="
    log_warning "  NEW CADDY PASSWORD - SAVE THIS NOW!"
    log_warning "====================================================================="
    log_warning ""
    log_warning "  Username: admin"
    log_warning "  Password: $new_password"
    log_warning ""
    log_warning "  This password will NOT be shown again!"
    log_warning "====================================================================="
    echo ""

    # Ask to restart Caddy
    prompt RESTART_CADDY "Restart Caddy to apply new password?" "yes"
    if [ "$RESTART_CADDY" = "yes" ] || [ "$RESTART_CADDY" = "y" ]; then
        stop_caddy
        start_caddy
    else
        log_info "Please restart Caddy manually: $0 caddy restart"
    fi

    log_success "Password regenerated successfully!"
}

cmd_caddy() {
    local action=$1

    case "$action" in
        start)
            start_caddy
            ;;
        stop)
            stop_caddy
            ;;
        restart)
            stop_caddy
            start_caddy
            ;;
        reload)
            reload_caddy
            ;;
        status)
            cd "$PLATFORM_ROOT/caddy" && docker_compose ps
            ;;
        logs)
            cd "$PLATFORM_ROOT/caddy" && docker_compose logs -f
            ;;
        new-password)
            cmd_regenerate_password
            ;;
        *)
            log_error "Usage: $0 caddy {start|stop|restart|reload|status|logs|new-password}"
            exit 1
            ;;
    esac
}

cmd_cache() {
    local action="${1:-show}"
    local var_name="${2:-}"

    # For show command, check if cache exists first
    if [ "$action" = "show" ] || [ "$action" = "" ]; then
        if [ ! -f "$CACHE_FILE" ]; then
            log_warning "Cache file not found at: $CACHE_FILE"
            log_info "The cache will be created automatically when you run the install command"
            return
        fi
    fi

    # Initialize cache to ensure CACHE_PASSWORD is set if needed
    init_cache

    case "$action" in
        show|"")
            cmd_cache_show
            ;;
        edit)
            if [ -z "$var_name" ]; then
                log_error "Usage: $0 cache edit <VAR_NAME>"
                exit 1
            fi
            cmd_cache_edit "$var_name"
            ;;
        *)
            log_error "Usage: $0 cache {show|edit <VAR_NAME>}"
            exit 1
            ;;
    esac
}

cmd_cache_show() {
    log_header "Credential Cache Contents"

    if [ ! -f "$CACHE_FILE" ]; then
        log_warning "Cache file not found at: $CACHE_FILE"
        return
    fi

    if [ ! -s "$CACHE_FILE" ]; then
        log_warning "Cache file is empty"
        return
    fi

    local temp_file=$(mktemp)

    # Check if cache is encrypted
    if head -n1 "$CACHE_FILE" | grep -q "^Salted__"; then
        log_info "Cache is encrypted, decrypting..."
        if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$CACHE_PASSWORD" -in "$CACHE_FILE" > "$temp_file" 2>/dev/null; then
            log_error "Failed to decrypt cache. Wrong password?"
            rm -f "$temp_file"
            exit 1
        fi
    else
        cp "$CACHE_FILE" "$temp_file"
    fi

    echo ""
    echo "Variable Name                          | Value"
    echo "---------------------------------------+---------------------------------------"

    # Read and display cache contents, masking sensitive values
    while IFS='=' read -r key value; do
        if [ -n "$key" ]; then
            # Mask sensitive values (passwords, tokens, keys)
            if echo "$key" | grep -qiE "PASSWORD|TOKEN|KEY|SECRET"; then
                if [ -n "$value" ]; then
                    masked_value="********"
                else
                    masked_value="(empty)"
                fi
            else
                masked_value="$value"
            fi
            printf "%-38s | %s\n" "$key" "$masked_value"
        fi
    done < "$temp_file"

    rm -f "$temp_file"
    echo ""
    log_info "To view or edit a specific value: $0 cache edit <VAR_NAME>"
}

cmd_cache_edit() {
    local var_name=$1

    log_header "Edit Cache Variable: $var_name"

    # Load current value
    local current_value=$(load_from_cache "$var_name")

    if [ -n "$current_value" ]; then
        # Mask sensitive values in display
        if echo "$var_name" | grep -qiE "PASSWORD|TOKEN|KEY|SECRET"; then
            log_info "Current value: ********"
        else
            log_info "Current value: $current_value"
        fi
    else
        log_info "Variable not found in cache (will be created)"
    fi

    echo ""

    # Determine if this should be a hidden input
    local is_sensitive=false
    if echo "$var_name" | grep -qiE "PASSWORD|TOKEN|KEY|SECRET"; then
        is_sensitive=true
    fi

    # Prompt for new value
    if [ "$is_sensitive" = true ]; then
        prompt NEW_VALUE "Enter new value for $var_name (leave empty to delete)" "" true
    else
        prompt NEW_VALUE "Enter new value for $var_name (leave empty to delete)" ""
    fi

    if [ -z "$NEW_VALUE" ]; then
        # Delete the variable from cache
        log_info "Deleting $var_name from cache..."

        local temp_file=$(mktemp)

        # Decrypt if needed
        if head -n1 "$CACHE_FILE" 2>/dev/null | grep -q "^Salted__"; then
            openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$CACHE_PASSWORD" -in "$CACHE_FILE" 2>/dev/null > "$temp_file" || true
        else
            cp "$CACHE_FILE" "$temp_file" 2>/dev/null || touch "$temp_file"
        fi

        # Remove the variable
        grep -v "^$var_name=" "$temp_file" > "${temp_file}.tmp" 2>/dev/null || true

        # Re-encrypt if needed
        if [ -n "$CACHE_PASSWORD" ]; then
            openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$CACHE_PASSWORD" -in "${temp_file}.tmp" -out "$CACHE_FILE"
        else
            mv "${temp_file}.tmp" "$CACHE_FILE"
        fi

        rm -f "$temp_file" "${temp_file}.tmp"
        log_success "Variable $var_name deleted from cache"
    else
        # Save new value
        save_to_cache "$var_name" "$NEW_VALUE"
        log_success "Variable $var_name updated successfully"
    fi
}

# ============================================================================
# Service Configuration
# ============================================================================

configure_contactdb() {
    log_header "Configuring ContactDB"

    # Ensure enrichment APIs are loaded
    setup_enrichment_apis

    # Use hardcoded password from docker-compose.yml
    local db_user="contactdb"
    local db_password="contactdb"
    local db_name="contactdb"
    local db_host="postgres"  # Docker service name
    local db_port="5432"
    local db_test_host="postgres_test"

    # Prompt for user email
    prompt_or_cache "SELF_EMAIL" "Your email address (for identifying you in ContactDB)" "" false "$PLATFORM_ROOT/contactdb/.env"

    # Derive API_PUBLIC_URL from public base URL
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")
    local api_public_url
    if [ -z "$public_base_url" ] || [ "$public_base_url" = "http://localhost" ]; then
        api_public_url="http://localhost:42800"
    else
        api_public_url="${public_base_url}/contactdb-api/"
    fi
    log_info "Using ContactDB API Public URL: $api_public_url"

    # Generate .env at root directory for application settings (matches docker-compose.yml)
    mkdir -p "$PLATFORM_ROOT/contactdb"
    cat > "$PLATFORM_ROOT/contactdb/.env" <<EOF
# ContactDB Application Configuration
# Database connection (matches docker-compose.yml hardcoded values)
DATABASE_URL=postgresql://${db_user}:${db_password}@${db_host}:${db_port}/${db_name}
DATABASE_URL_TEST=postgresql://${db_user}:${db_password}@${db_test_host}:${db_port}/${db_name}_test

# User Configuration
SELF_EMAIL=$SELF_EMAIL

# API Configuration
API_PUBLIC_URL=$api_public_url
BASE_PATH=/contactdb/

# Optional: Override defaults
# APP_NAME=ContactDB
# DEBUG=false
# LOG_SQL=false

# Contact enrichment APIs (optional)
EOF

    # Add Apollo API key if provided
    if [ -n "$APOLLO_API_KEY" ]; then
        echo "APOLLO_API_KEY=$APOLLO_API_KEY" >> "$PLATFORM_ROOT/contactdb/.env"
    else
        echo "# APOLLO_API_KEY=" >> "$PLATFORM_ROOT/contactdb/.env"
    fi

    # Add Hunter API key if provided
    if [ -n "$HUNTER_API_KEY" ]; then
        echo "HUNTER_API_KEY=$HUNTER_API_KEY" >> "$PLATFORM_ROOT/contactdb/.env"
    else
        echo "# HUNTER_API_KEY=" >> "$PLATFORM_ROOT/contactdb/.env"
    fi

    log_success "ContactDB configured"
}

configure_dataindex() {
    log_header "Configuring DataIndex"

    # Required variables - check existing .env file if cache is empty
    prompt_or_cache "DATAINDEX_POSTGRES_PASSWORD" "PostgreSQL password for DataIndex" "auto" true "$PLATFORM_ROOT/dataindex/.env"

    # Derive ContactDB frontend URL from public base URL
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")
    local contactdb_url_frontend="${public_base_url:-http://localhost}/contactdb"
    local contactdb_url_backend="${public_base_url:-http://localhost}/contactdb-api"
    log_info "Using ContactDB Frontend URL: $contactdb_url_frontend"

    # Generate base .env
    cat > "$PLATFORM_ROOT/dataindex/.env" <<EOF
# DataIndex Configuration
CONTACTDB_URL=http://host.docker.internal:42800
CONTACTDB_URL_FRONTEND=$contactdb_url_frontend
CONTACTDB_URL_API_PUBLIC=$contactdb_url_backend
REDIS_URL=redis://localhost:42170
DATABASE_URL=postgresql://dataindex:$DATAINDEX_POSTGRES_PASSWORD@localhost:42434/dataindex
BASE_PATH=/dataindex/
EOF

    log_success "DataIndex configured"
}

# ============================================================================
# Repository Management
# ============================================================================

clone_services() {
    log_header "Cloning Repositories"

    mkdir -p "$PLATFORM_ROOT"

    for service_id in "${SELECTED_SERVICES[@]}"; do
        # Find service definition
        for service_def in "${AVAILABLE_SERVICES[@]}"; do
            IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"

            if [ "$id" = "$service_id" ]; then
                if [ -d "$PLATFORM_ROOT/$id/.git" ]; then
                    log_info "$id already cloned, pulling latest changes..."
                    cd "$PLATFORM_ROOT/$id"

                    # Discard any local changes before pulling
                    log_info "Discarding local changes..."
                    git reset --hard HEAD 2>&1 | grep -v "password" || true
                    git clean -fd 2>&1 | grep -v "password" || true

                    git pull 2>&1 | grep -v "password" || {
                        log_warning "Failed to pull latest changes for $id (might be on a different branch)"
                    }
                    cd "$PLATFORM_ROOT"
                    log_success "Updated $id"
                else
                    log_info "Cloning $id from $repo..."
                    local auth_url=$(prepare_git_url "$repo")
                    git clone -b "$branch" "$auth_url" "$PLATFORM_ROOT/$id" 2>&1 | grep -v "password" || {
                        log_error "Failed to clone $id"
                        exit 1
                    }
                    log_success "Cloned $id"
                fi
                break
            fi
        done
    done
}

configure_babelfish() {
    log_header "Configuring Babelfish"

    # Generate passwords - check existing .env file if cache is empty
    prompt_or_cache "BABELFISH_POSTGRES_PASSWORD" "PostgreSQL password for Babelfish" "auto" true "$PLATFORM_ROOT/babelfish/.env"
    prompt_or_cache "BABELFISH_BACKUP_KEY" "Backup encryption key for Babelfish" "auto" true "$PLATFORM_ROOT/babelfish/.env"

    # Matrix server name (use localhost for local development)
    local MATRIX_SERVER_NAME="localhost"

    # Generate .env
    cat > "$PLATFORM_ROOT/babelfish/.env" <<EOF
# Babelfish Configuration
MATRIX_SERVER_NAME=$MATRIX_SERVER_NAME
MATRIX_ADMIN_USER=admin
POSTGRES_HOST=postgres
POSTGRES_PORT=5433
POSTGRES_PASSWORD=$BABELFISH_POSTGRES_PASSWORD
CENTRAL_DB_HOST=babelfish-central-db
CENTRAL_DB_PORT=5432
CENTRAL_DB_NAME=babelfish_central
CENTRAL_DB_PASSWORD=$BABELFISH_POSTGRES_PASSWORD
MATRIX_DB_HOST=postgres
MATRIX_DB_PORT=5432
MATRIX_DB_NAME=synapse
MATRIX_DB_PASSWORD=$BABELFISH_POSTGRES_PASSWORD
SYNC_INTERVAL=300
SYNC_BATCH_SIZE=1000
PARALLEL_BRIDGES=true
ENABLE_EMBEDDINGS=true
FULL_SYNC_ON_STARTUP=true
ENABLE_DATABASE_DISCOVERY=true
WHATSAPP_ENABLED=true
DISCORD_ENABLED=true
SLACK_ENABLED=true
TELEGRAM_ENABLED=false
META_ENABLED=true
SIGNAL_ENABLED=false
LINKEDIN_ENABLED=false
TELEGRAM_API_ID=
TELEGRAM_API_HASH=
API_PORT=8000
LOG_LEVEL=INFO
API_CORS_ORIGINS=http://localhost:8880,http://localhost:8448,http://localhost:3000,http://localhost:3001
API_MAX_RESULTS=1000
FASTAPI_RELOAD=true
BACKUP_ENCRYPTION_KEY=$BABELFISH_BACKUP_KEY
BACKUP_DESTINATION=./backups
EOF

    # Configure Element Web with proper domain
    local caddy_domain=$(load_from_cache "CADDY_DOMAIN")
    local matrix_base_url="https://$caddy_domain"

    # If no domain or using localhost, use http://localhost:8448
    if [ -z "$caddy_domain" ] || [[ "$caddy_domain" == "localhost"* ]] || [[ "$caddy_domain" == *":80"* ]]; then
        matrix_base_url="http://localhost:8448"
    fi

    log_info "Generating Element config with Matrix server at: $matrix_base_url"

    # Create config directory if it doesn't exist
    mkdir -p "$PLATFORM_ROOT/babelfish/config/element"

    # Write to config directory (gitignored), not example-config (tracked in git)
    cat > "$PLATFORM_ROOT/babelfish/config/element/config.json" <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "$matrix_base_url",
            "server_name": "localhost"
        }
    },
    "disable_custom_urls": false,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": true,
    "brand": "Universal Conversations Manager",
    "integrations_ui_url": "",
    "integrations_rest_url": "",
    "integrations_widgets_urls": [],
    "bug_report_endpoint_url": "",
    "features": {
        "feature_thread": true,
        "feature_pinning": true,
        "feature_state_counters": true
    },
    "default_federate": false,
    "default_theme": "light",
    "room_directory": {
        "servers": ["localhost"]
    },
    "enable_presence_by_hs_url": {
        "$matrix_base_url": true
    },
    "setting_defaults": {
        "breadcrumbs": true
    },
    "jitsi": {
        "preferred_domain": ""
    },
    "element_call": {
        "url": "",
        "use_exclusively": false
    },
    "map_style_url": ""
}
EOF

    log_success "Babelfish configured with Element pointing to $matrix_base_url"
}

configure_crm_reply() {
    log_header "Configuring CRM Reply"

    # Ensure enrichment APIs are loaded
    setup_enrichment_apis

    # Generate passwords - check existing .env file if cache is empty
    prompt_or_cache "CRM_POSTGRES_PASSWORD" "PostgreSQL password for CRM Reply" "auto" true "$PLATFORM_ROOT/crm-reply/.env"

    # LLM Provider selection
    prompt_or_cache "CRM_LLM_PROVIDER" "LLM provider (anthropic/litellm)" "litellm"

    if [ "$CRM_LLM_PROVIDER" = "litellm" ]; then
        prompt_or_cache "LITELLM_API_KEY" "LiteLLM API key" "" true
        prompt_or_cache "LITELLM_BASE_URL" "LiteLLM base URL" "https://litellm.app.monadical.io/v1"
        prompt_or_cache "LITELLM_MODEL" "LiteLLM model" "GLM-4.5-Air-FP8-dev"
    elif [ "$CRM_LLM_PROVIDER" = "anthropic" ]; then
        prompt_or_cache "ANTHROPIC_API_KEY" "Anthropic API key" "" true
    fi

    # Generate .env
    cat > "$PLATFORM_ROOT/crm-reply/.env" <<EOF
# CRM Reply Configuration
POSTGRES_PASSWORD=$CRM_POSTGRES_PASSWORD
CENTRAL_DB_URL=postgresql+asyncpg://postgres:$CRM_POSTGRES_PASSWORD@crm-reply-postgres:5432/babelfish_core
QDRANT_URL=http://crm-reply-qdrant:6333
REDIS_URL=redis://crm-reply-redis:6379/0
CELERY_BROKER_URL=redis://crm-reply-redis:6379/0
CELERY_RESULT_BACKEND=redis://crm-reply-redis:6379/0
LOG_LEVEL=INFO
ENABLE_EMBEDDINGS=true
ENABLE_LLM_URGENCY=true
ENABLE_AUTO_RESPONSES=true
AUTO_SEND_RESPONSES=false
AUTO_SEND_CONFIDENCE_THRESHOLD=80
API_CORS_ORIGINS=http://localhost:3000,http://localhost:3001
LLM_PROVIDER=$CRM_LLM_PROVIDER
POPULATE_DEMO_DATA=false
EOF

    # Add LLM-specific config
    if [ "$CRM_LLM_PROVIDER" = "litellm" ]; then
        cat >> "$PLATFORM_ROOT/crm-reply/.env" <<EOF
LITELLM_API_KEY=$LITELLM_API_KEY
LITELLM_BASE_URL=$LITELLM_BASE_URL
LITELLM_MODEL=$LITELLM_MODEL
EOF
    elif [ "$CRM_LLM_PROVIDER" = "anthropic" ]; then
        cat >> "$PLATFORM_ROOT/crm-reply/.env" <<EOF
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
EOF
    fi

    # Add enrichment API keys
    cat >> "$PLATFORM_ROOT/crm-reply/.env" <<EOF

# Contact enrichment APIs (optional)
EOF

    if [ -n "$APOLLO_API_KEY" ]; then
        echo "APOLLO_API_KEY=$APOLLO_API_KEY" >> "$PLATFORM_ROOT/crm-reply/.env"
    else
        echo "# APOLLO_API_KEY=" >> "$PLATFORM_ROOT/crm-reply/.env"
    fi

    if [ -n "$HUNTER_API_KEY" ]; then
        echo "HUNTER_API_KEY=$HUNTER_API_KEY" >> "$PLATFORM_ROOT/crm-reply/.env"
    else
        echo "# HUNTER_API_KEY=" >> "$PLATFORM_ROOT/crm-reply/.env"
    fi

    log_success "CRM Reply configured"
}

configure_meeting_prep() {
    log_header "Configuring Meeting Prep"

    # Ensure enrichment APIs are loaded
    setup_enrichment_apis

    # Derive URLs from public base URL
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")
    local MEETING_FRONTEND_URL="${public_base_url:-http://localhost}/meeting-prep"
    local MEETING_BACKEND_URL="${public_base_url:-http://localhost}/meeting-prep-api"
    local DATAINDEX_PUBLIC_URL="${public_base_url:-http://localhost}/dataindex"

    log_info "Using Meeting Prep Frontend URL: $MEETING_FRONTEND_URL"
    log_info "Using Meeting Prep Backend URL: $MEETING_BACKEND_URL"
    log_info "Using DataIndex Public URL: $DATAINDEX_PUBLIC_URL"

    # Prompt for LiteLLM configuration
    prompt_or_cache "LITELLM_API_KEY" "LiteLLM API key" "" true "$PLATFORM_ROOT/meeting-prep/.env"
    prompt_or_cache "LITELLM_BASE_URL" "LiteLLM base URL" "https://litellm-notrack.app.monadical.io/v1/" false "$PLATFORM_ROOT/meeting-prep/.env"
    prompt_or_cache "DEFAULT_LLM_MODEL" "Default LLM model" "GLM-4.5-Air-FP8-dev" false "$PLATFORM_ROOT/meeting-prep/.env"
    prompt_or_cache "APOLLO_API_KEY" "Apollo API key (optional)" "" true

    # Generate .env
    cat > "$PLATFORM_ROOT/meeting-prep/.env" <<EOF
BASE_PATH=/meeting-prep/
VITE_API_URL=${MEETING_BACKEND_URL}
CORS_ORIGINS=${MEETING_FRONTEND_URL}
LITELLM_API_KEY=${LITELLM_API_KEY}
LITELLM_BASE_URL=${LITELLM_BASE_URL}
DEFAULT_LLM_MODEL=${DEFAULT_LLM_MODEL}
APOLLO_API_KEY=${APOLLO_API_KEY}
DATAINDEX_PUBLIC_URL=${DATAINDEX_PUBLIC_URL}
EOF

    log_success "Meeting Prep configured"
}

configure_dailydigest() {
    log_header "Configuring DailyDigest"

    # Derive URLs from public base URL
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")
    local CONTACTDB_URL="${public_base_url:-http://localhost}/contactdb-api"
    local CONTACTDB_FRONTEND_URL="${public_base_url:-http://localhost}/contactdb"
    local DATAINDEX_URL="${public_base_url:-http://localhost}/dataindex"

    log_info "Using ContactDB Backend URL: $CONTACTDB_URL"
    log_info "Using ContactDB Frontend URL: $CONTACTDB_FRONTEND_URL"
    log_info "Using DataIndex URL: $DATAINDEX_URL"

    # Prompt for LiteLLM configuration
    prompt_or_cache "LITELLM_API_KEY" "LiteLLM API key" "" true "$PLATFORM_ROOT/dailydigest/.env"
    prompt_or_cache "LITELLM_BASE_URL" "LiteLLM base URL" "https://litellm-notrack.app.monadical.io" false "$PLATFORM_ROOT/dailydigest/.env"
    prompt_or_cache "DEFAULT_LLM_MODEL" "Default LLM model" "GLM-4.5-Air-FP8-dev" false "$PLATFORM_ROOT/dailydigest/.env"

    # Timezone for cron scheduling
    prompt_or_cache "DAILYDIGEST_TZ" "Timezone for cron scheduling" "America/Montreal" false "$PLATFORM_ROOT/dailydigest/.env"

    # Generate .env
    cat > "$PLATFORM_ROOT/dailydigest/.env" <<EOF
TZ=${DAILYDIGEST_TZ}
DAILYDIGEST_BASE_PATH=/dailydigest/
DAILYDIGEST_LLM_API_URL=${LITELLM_BASE_URL}
DAILYDIGEST_LLM_API_KEY=${LITELLM_API_KEY}
DAILYDIGEST_LLM_MODEL=${DEFAULT_LLM_MODEL}
DAILYDIGEST_CONTACTDB_URL=http://host.docker.internal:42800
DAILYDIGEST_DATAINDEX_URL=http://host.docker.internal:42180
DAILYDIGEST_CONTACTDB_FRONTEND_URL=${CONTACTDB_FRONTEND_URL}
DAILYDIGEST_DATAINDEX_FRONTEND_URL=${DATAINDEX_URL}
EOF

    log_success "DailyDigest configured"
}

configure_librechat() {
    log_header "Configuring LibreChat"

    # Derive URLs from public base URL
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")
    local LIBRECHAT_URL="${public_base_url:-http://localhost}/librechat/"

    log_info "Using LibreChat URL: $LIBRECHAT_URL"

    # Get LiteLLM configuration (reuse existing values if already cached)
    prompt_or_cache "LITELLM_API_KEY" "LiteLLM API key" "" true "$PLATFORM_ROOT/librechat/.env"
    prompt_or_cache "LITELLM_BASE_URL" "LiteLLM base URL" "https://litellm-notrack.app.monadical.io" false "$PLATFORM_ROOT/librechat/.env"
    prompt_or_cache "LITELLM_MODEL" "Default LiteLLM model" "GLM-4.5-Air-FP8-dev" false "$PLATFORM_ROOT/librechat/.env"

    # Enable web search with local SearXng (always enabled)
    SEARXNG_INSTANCE_URL="http://searxng:8080"
    log_info "Web search will be enabled with local SearXng container"

    # Get Firecrawl API key for web scraping
    prompt_or_cache "FIRECRAWL_API_URL" "Firecrawl API URL" "https://api.firecrawl.dev" false "$PLATFORM_ROOT/librechat/.env"
    prompt_or_cache "FIRECRAWL_API_KEY" "Firecrawl API key (for web scraping)" "" true "$PLATFORM_ROOT/librechat/.env"

    # Get Cohere API key for reranking
    prompt_or_cache "COHERE_API_KEY" "Cohere API key (for result reranking)" "" true "$PLATFORM_ROOT/librechat/.env"

    # Copy .env.example to .env
    if [ -f "$PLATFORM_ROOT/librechat/.env.example" ]; then
        log_info "Copying .env.example to .env..."
        cp "$PLATFORM_ROOT/librechat/.env.example" "$PLATFORM_ROOT/librechat/.env"
    else
        log_warning ".env.example not found, creating basic .env file"
        touch "$PLATFORM_ROOT/librechat/.env"
    fi

    # Update DOMAIN_CLIENT and DOMAIN_SERVER in .env
    if grep -q "^DOMAIN_CLIENT=" "$PLATFORM_ROOT/librechat/.env"; then
        sed -i "s|^DOMAIN_CLIENT=.*|DOMAIN_CLIENT=${LIBRECHAT_URL}|" "$PLATFORM_ROOT/librechat/.env"
    else
        echo "DOMAIN_CLIENT=${LIBRECHAT_URL}" >> "$PLATFORM_ROOT/librechat/.env"
    fi

    if grep -q "^DOMAIN_SERVER=" "$PLATFORM_ROOT/librechat/.env"; then
        sed -i "s|^DOMAIN_SERVER=.*|DOMAIN_SERVER=${LIBRECHAT_URL}|" "$PLATFORM_ROOT/librechat/.env"
    else
        echo "DOMAIN_SERVER=${LIBRECHAT_URL}" >> "$PLATFORM_ROOT/librechat/.env"
    fi

    # Add SearXng environment variables if configured
    if [ -n "$SEARXNG_INSTANCE_URL" ]; then
        if grep -q "^SEARXNG_INSTANCE_URL=" "$PLATFORM_ROOT/librechat/.env"; then
            sed -i "s|^SEARXNG_INSTANCE_URL=.*|SEARXNG_INSTANCE_URL=${SEARXNG_INSTANCE_URL}|" "$PLATFORM_ROOT/librechat/.env"
        else
            echo "SEARXNG_INSTANCE_URL=${SEARXNG_INSTANCE_URL}" >> "$PLATFORM_ROOT/librechat/.env"
        fi
    fi

    # Create docker-compose.override.yml
    cat > "$PLATFORM_ROOT/librechat/docker-compose.override.yml" <<EOF
services:
  api:
    volumes:
      - ./librechat.yaml:/app/librechat.yaml
    env_file:
      - .env
EOF

    # Add SearXng service if web search is enabled
    if [ -n "$SEARXNG_INSTANCE_URL" ]; then
        cat >> "$PLATFORM_ROOT/librechat/docker-compose.override.yml" <<EOF
    environment:
      - SEARXNG_INSTANCE_URL=http://searxng:8080
      - FIRECRAWL_API_KEY=${FIRECRAWL_API_KEY}
      - FIRECRAWL_API_URL=${FIRECRAWL_API_URL}
      - COHERE_API_KEY=${COHERE_API_KEY}
    depends_on:
      - searxng
EOF
        cat >> "$PLATFORM_ROOT/librechat/docker-compose.override.yml" <<'EOF'
  searxng:
    container_name: librechat-searxng
    image: searxng/searxng:latest
    restart: unless-stopped
    environment:
      - SEARXNG_BASE_URL=http://searxng:8080/
      - UWSGI_WORKERS=4
      - UWSGI_THREADS=2
    volumes:
      - ./searxng:/etc/searxng:rw
    networks:
      - default
EOF

        # Create SearXng settings directory and configuration
        mkdir -p "$PLATFORM_ROOT/librechat/searxng"
        cat > "$PLATFORM_ROOT/librechat/searxng/settings.yml" <<'EOF'
use_default_settings: true

general:
  instance_name: "LibreChat SearXng"
  privacypolicy_url: false
  donation_url: false
  contact_url: false
  enable_metrics: false

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json

server:
  secret_key: "changeme-searxng-secret-key"
  limiter: false
  image_proxy: true
  method: "GET"

ui:
  static_use_hash: true
  default_theme: simple
  theme_args:
    simple_style: auto

enabled_plugins:
  - 'Hash plugin'
  - 'Self Information'
  - 'Tracker URL remover'
  - 'Ahmia blacklist'

engines:
  - name: google
    disabled: false
  - name: duckduckgo
    disabled: false
  - name: wikipedia
    disabled: false
  - name: bing
    disabled: false
EOF
        log_success "SearXng service configured"
    fi

    # Create librechat.yaml with LiteLLM configuration
    cat > "$PLATFORM_ROOT/librechat/librechat.yaml" <<EOF
version: 1.2.6
cache: true

endpoints:
  custom:
    - name: "Monadical LiteLLM"
      apiKey: "${LITELLM_API_KEY}"
      baseURL: "${LITELLM_BASE_URL}"
      models:
        default: ["${LITELLM_MODEL}"]
      titleConvo: true
      titleModel: "current_model"
      titleMessageRole: "user"
      summarize: false
      summaryModel: "current_model"
      forcePrompt: false
EOF

    # Add agents configuration if web search is enabled
    if [ -n "$SEARXNG_INSTANCE_URL" ]; then
        cat >> "$PLATFORM_ROOT/librechat/librechat.yaml" <<'EOF'
  agents:
    disableBuilder: false
    capabilities:
      - "web_search"
      - "tools"
EOF
    fi

    # Add webSearch configuration if web search is enabled
    if [ -n "$SEARXNG_INSTANCE_URL" ]; then
        cat >> "$PLATFORM_ROOT/librechat/librechat.yaml" <<'EOF'
webSearch:
  searchProvider: "searxng"
  searxngInstanceUrl: "${SEARXNG_INSTANCE_URL}"
  scraperProvider: "firecrawl"
  firecrawlApiKey: "${FIRECRAWL_API_KEY}"
  firecrawlApiUrl: "${FIRECRAWL_API_URL}"
  rerankerType: "cohere"
  cohereApiKey: "${COHERE_API_KEY}"
EOF
    fi

    # Add MCP servers configuration
    cat >> "$PLATFORM_ROOT/librechat/librechat.yaml" <<EOF
mcpServers:
  contactdb:
    type: streamable-http
    url: http://host.docker.internal:42800/mcp/
  dataindex:
    type: streamable-http
    url: http://host.docker.internal:42180/dataindex/mcp/
EOF

    log_success "LibreChat configured"
}

# Generic function to configure a service by ID
configure_service() {
    local service_id=$1

    case "$service_id" in
        contactdb)
            configure_contactdb
            ;;
        dataindex)
            configure_dataindex
            ;;
        babelfish)
            configure_babelfish
            ;;
        crm-reply)
            configure_crm_reply
            ;;
        meeting-prep)
            configure_meeting_prep
            ;;
        dailydigest)
            configure_dailydigest
            ;;
        librechat)
            configure_librechat
            ;;
        *)
            log_warning "No configuration function for $service_id"
            return 1
            ;;
    esac
}

configure_all_services() {
    for service_id in "${SELECTED_SERVICES[@]}"; do
        configure_service "$service_id"
    done
}

# ============================================================================
# Docker Network
# ============================================================================

setup_docker_network() {
    log_header "Setting Up Docker Network"

    if docker network inspect "$DOCKER_NETWORK" &> /dev/null; then
        log_info "Network $DOCKER_NETWORK already exists"
    else
        docker network create "$DOCKER_NETWORK"
        log_success "Created network $DOCKER_NETWORK"
    fi
}

# ============================================================================
# Service Startup
# ============================================================================

# Global variable to track if services were started
SERVICES_STARTED=false

start_services() {
    log_header "Starting Services"

    # Always prompt - don't cache this preference
    prompt START_NOW "Start services now?" "yes"

    if [ "$START_NOW" != "yes" ] && [ "$START_NOW" != "y" ]; then
        log_info "Skipping service startup"
        SERVICES_STARTED=false
        return
    fi

    SERVICES_STARTED=true

    # Start Caddy first if configured
    if [ -f "$PLATFORM_ROOT/caddy/docker-compose.yml" ]; then
        start_caddy
    fi

    # Use initial_service_setup for first-time install (runs make setup where needed)
    # Start in dependency order: contactdb first, then others
    for service_id in "${SELECTED_SERVICES[@]}"; do
        if [ "$service_id" = "contactdb" ]; then
            initial_service_setup "$service_id"
        fi
    done

    for service_id in "${SELECTED_SERVICES[@]}"; do
        if [ "$service_id" != "contactdb" ]; then
            initial_service_setup "$service_id"
        fi
    done
}

start_service() {
    local service_id=$1

    # Handle Caddy specially
    if [ "$service_id" = "caddy" ]; then
        start_caddy
        return $?
    fi

    local service_path="$PLATFORM_ROOT/$service_id"

    # Check if service directory exists
    if [ ! -d "$service_path" ]; then
        log_error "Service $service_id not found at $service_path"
        return 1
    fi

    log_info "Starting $service_id..."

    cd "$service_path"

    if [ -f "docker-compose.yml" ]; then
        # Just start services without rebuilding
        docker_compose up -d 2>&1 | grep -v "password" || {
            log_error "Failed to start $service_id"
            docker_compose logs --tail=50
            cd "$PLATFORM_ROOT"
            return 1
        }
    else
        log_warning "No docker-compose.yml found for $service_id"
    fi

    cd "$PLATFORM_ROOT"
    log_success "$service_id started"

    # Reload Caddy configuration to include the new service
    reload_caddy
}

# Initial setup for a service (builds and starts on first run)
initial_service_setup() {
    local service_id=$1
    local service_path="$PLATFORM_ROOT/$service_id"

    if [ ! -d "$service_path" ]; then
        log_error "Service $service_id not found at $service_path"
        return 1
    fi

    cd "$service_path"

    # Babelfish needs make setup for bridge configuration
    if [ "$service_id" = "babelfish" ]; then
        log_info "Running initial setup for babelfish..."
        if ! make setup 2>&1; then
            log_error "make setup failed for babelfish"
            log_info "Check that .env file exists and contains required variables"
            cd "$PLATFORM_ROOT"
            return 1
        fi
        log_success "Babelfish setup completed"

        # Use make up to start services with proper permissions and token setup
        log_info "Starting babelfish services with 'make up'..."
        if ! make up 2>&1 | grep -v "password"; then
            log_error "make up failed for babelfish"
            log_info "Check logs for details"
            make logs
            cd "$PLATFORM_ROOT"
            return 1
        fi
    else
        # All other services: just build and start directly
        log_info "Building and starting $service_id..."
        if [ -f "docker-compose.yml" ]; then
            docker_compose up -d --build 2>&1 | grep -v "password" || {
                log_error "Failed to build and start $service_id"
                docker_compose logs --tail=50
                cd "$PLATFORM_ROOT"
                return 1
            }
        else
            log_warning "No docker-compose.yml found for $service_id"
            cd "$PLATFORM_ROOT"
            return 1
        fi
    fi

    cd "$PLATFORM_ROOT"
    log_success "$service_id built and started"
}

stop_service() {
    local service_id=$1

    # Handle Caddy specially
    if [ "$service_id" = "caddy" ]; then
        stop_caddy
        return $?
    fi

    local service_path="$PLATFORM_ROOT/$service_id"

    # Check if service directory exists
    if [ ! -d "$service_path" ]; then
        log_error "Service $service_id not found at $service_path"
        return 1
    fi

    log_info "Stopping $service_id..."

    cd "$service_path"

    if [ -f "docker-compose.yml" ]; then
        docker_compose down 2>&1 | grep -v "password" || true
        # Verify containers are actually stopped
        if [ -n "$(docker_compose ps -q)" ]; then
            log_error "Failed to stop $service_id - containers still running"
            cd "$PLATFORM_ROOT"
            return 1
        fi
    else
        log_warning "No docker-compose.yml found for $service_id"
    fi

    cd "$PLATFORM_ROOT"
    log_success "$service_id stopped"

    # Reload Caddy configuration to remove the stopped service
    reload_caddy
}

update_service() {
    local service_id=$1

    # Caddy doesn't need git updates, but regenerate config files
    if [ "$service_id" = "caddy" ]; then
        log_info "Upgrading Caddy configuration..."

        # Load cached credentials
        local caddy_domain=$(load_from_cache "CADDY_DOMAIN")
        local password_hash=$(load_from_cache "CADDY_PASSWORD_HASH")

        if [ -z "$password_hash" ]; then
            log_error "No Caddy password found in cache. Cannot regenerate configuration."
            return 1
        fi

        # Regenerate configuration files
        generate_caddyfile "$caddy_domain" "$password_hash"
        generate_caddy_compose

        # Restart Caddy to apply changes
        stop_caddy
        start_caddy

        log_success "Caddy upgraded with regenerated configuration"
        return $?
    fi

    local service_path="$PLATFORM_ROOT/$service_id"

    # Check if service directory exists
    if [ ! -d "$service_path" ]; then
        log_error "Service $service_id not found at $service_path"
        return 1
    fi

    log_info "Upgrading $service_id..."

    # Stop service
    stop_service "$service_id" || return 1

    # Pull latest changes
    log_info "Pulling latest changes for $service_id..."
    cd "$service_path"

    # Discard any local changes before pulling
    log_info "Discarding local changes..."
    git reset --hard HEAD 2>&1 | grep -v "password" || true
    git clean -fd 2>&1 | grep -v "password" || true

    git pull 2>&1 | grep -v "password" || {
        log_warning "Failed to pull latest changes for $service_id"
    }

    # Regenerate configuration
    log_info "Regenerating configuration for $service_id..."
    cd "$PLATFORM_ROOT"

    # Use the generic configure_service function
    configure_service "$service_id" || log_info "No configuration regeneration needed for $service_id"

    # Rebuild and start
    log_info "Rebuilding and starting $service_id..."
    cd "$service_path"

    if [ -f "docker-compose.yml" ]; then
        docker_compose up -d --build 2>&1 | grep -v "password" || {
            log_error "Failed to build and start $service_id"
            docker_compose logs --tail=50
            cd "$PLATFORM_ROOT"
            return 1
        }
    else
        log_warning "No docker-compose.yml found for $service_id"
    fi

    cd "$PLATFORM_ROOT"
    log_success "$service_id upgraded"
}

# ============================================================================
# Service Management Commands
# ============================================================================

get_configured_services() {
    # Get list of configured services (directories that exist in platform root)
    local configured=()

    # Add Caddy if configured
    if [ -f "$PLATFORM_ROOT/caddy/docker-compose.yml" ]; then
        configured+=("caddy")
    fi

    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
        if [ -d "$PLATFORM_ROOT/$id" ]; then
            configured+=("$id")
        fi
    done
    echo "${configured[@]}"
}

cmd_start() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 start <service|all>"
        echo ""
        echo "Configured services:"
        for svc in $(get_configured_services); do
            echo "  - $svc"
        done
        exit 1
    fi

    if [ "$service_name" = "all" ]; then
        log_header "Starting All Services"
        local services=($(get_configured_services))

        # Start caddy first if it exists
        for svc in "${services[@]}"; do
            if [ "$svc" = "caddy" ]; then
                start_service "$svc"
            fi
        done

        # Start contactdb second if it exists
        for svc in "${services[@]}"; do
            if [ "$svc" = "contactdb" ]; then
                start_service "$svc"
            fi
        done

        # Start others
        for svc in "${services[@]}"; do
            if [ "$svc" != "contactdb" ] && [ "$svc" != "caddy" ]; then
                start_service "$svc"
            fi
        done
    else
        start_service "$service_name"
    fi
}

cmd_stop() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 stop <service|all>"
        echo ""
        echo "Configured services:"
        for svc in $(get_configured_services); do
            echo "  - $svc"
        done
        exit 1
    fi

    if [ "$service_name" = "all" ]; then
        log_header "Stopping All Services"
        for svc in $(get_configured_services); do
            stop_service "$svc"
        done
    else
        stop_service "$service_name"
    fi
}

cmd_restart() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 restart <service|all>"
        echo ""
        echo "Configured services:"
        for svc in $(get_configured_services); do
            echo "  - $svc"
        done
        exit 1
    fi

    log_header "Restarting $([ "$service_name" = "all" ] && echo "All Services" || echo "$service_name")"
    cmd_stop "$service_name"
    cmd_start "$service_name"
}

cmd_upgrade() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 upgrade <service|all>"
        echo ""
        echo "Configured services:"
        for svc in $(get_configured_services); do
            echo "  - $svc"
        done
        exit 1
    fi

    init_cache

    if [ "$service_name" = "all" ]; then
        log_header "Upgrading All Services"
        local services=($(get_configured_services))

        # Upgrade contactdb first if it exists
        for svc in "${services[@]}"; do
            if [ "$svc" = "contactdb" ]; then
                update_service "$svc"
            fi
        done

        # Upgrade others
        for svc in "${services[@]}"; do
            if [ "$svc" != "contactdb" ]; then
                update_service "$svc"
            fi
        done
    else
        update_service "$service_name"
    fi

    # Reload Caddy configuration to remove the service
    reload_caddy
}

cmd_enable() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 enable <service>"
        echo ""
        echo "Available services to enable:"
        for service_def in "${AVAILABLE_SERVICES[@]}"; do
            IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
            if [ "$mandatory" = "false" ] && [ ! -d "$PLATFORM_ROOT/$id" ]; then
                echo "  - $id: $desc"
            fi
        done
        exit 1
    fi

    # Check if service is valid
    local service_found=false
    local service_info=""
    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
        if [ "$id" = "$service_name" ]; then
            service_found=true
            service_info="$service_def"
            break
        fi
    done

    if [ "$service_found" = false ]; then
        log_error "Unknown service: $service_name"
        exit 1
    fi

    # Check if already enabled
    if [ -d "$PLATFORM_ROOT/$service_name" ]; then
        log_warning "Service $service_name is already enabled"
        echo ""
        echo "To start it, use: $0 start $service_name"
        echo ""
        exit 0
    fi

    log_header "Enabling Service: $service_name"

    # Initialize cache if needed
    init_cache
    setup_github_auth
    setup_enrichment_apis

    # Add to selected services
    SELECTED_SERVICES=("$service_name")

    # Clone the service
    clone_services

    # Configure the service using the generic function
    configure_service "$service_name"

    # Reload Caddy configuration to include the new service
    reload_caddy

    # Update cache to include this service in optional services
    local cached_services=$(load_from_cache "SELECTED_OPTIONAL_SERVICES")
    if [ -z "$cached_services" ] || [ "$cached_services" = "none" ]; then
        save_to_cache "SELECTED_OPTIONAL_SERVICES" "$service_name"
    else
        # Check if not already in cache
        if [[ ",$cached_services," != *",$service_name,"* ]]; then
            save_to_cache "SELECTED_OPTIONAL_SERVICES" "$cached_services,$service_name"
        fi
    fi

    # Ask if user wants to start the service
    prompt START_NOW "Start $service_name now?" "yes"
    if [ "$START_NOW" = "yes" ] || [ "$START_NOW" = "y" ]; then
        initial_service_setup "$service_name"
    fi

    log_success "Service $service_name enabled successfully!"
}

cmd_disable() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 disable <service>"
        echo ""
        echo "Configured services:"
        for svc in $(get_configured_services); do
            echo "  - $svc"
        done
        exit 1
    fi

    # Check if service is configured
    if [ ! -d "$PLATFORM_ROOT/$service_name" ]; then
        log_error "Service $service_name is not enabled"
        exit 1
    fi

    # Check if it's a mandatory service
    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"
        if [ "$id" = "$service_name" ] && [ "$mandatory" = "true" ]; then
            log_error "Cannot disable mandatory service: $service_name"
            exit 1
        fi
    done

    log_header "Disabling Service: $service_name"

    # Stop the service if it's running
    stop_service "$service_name"

    # Ask if user wants to remove the directory
    prompt REMOVE_DIR "Remove $service_name directory?" "no"
    if [ "$REMOVE_DIR" = "yes" ] || [ "$REMOVE_DIR" = "y" ]; then
        log_info "Removing $PLATFORM_ROOT/$service_name..."
        rm -rf "$PLATFORM_ROOT/$service_name"
        log_success "Directory removed"
    else
        log_info "Service stopped but directory preserved at $PLATFORM_ROOT/$service_name"
    fi

    # Update cache to remove this service from optional services
    init_cache
    local cached_services=$(load_from_cache "SELECTED_OPTIONAL_SERVICES")
    if [ -n "$cached_services" ] && [ "$cached_services" != "none" ]; then
        # Remove service from comma-separated list
        local new_services=$(echo "$cached_services" | tr ',' '\n' | grep -v "^$service_name$" | tr '\n' ',' | sed 's/,$//')
        if [ -z "$new_services" ]; then
            save_to_cache "SELECTED_OPTIONAL_SERVICES" "none"
        else
            save_to_cache "SELECTED_OPTIONAL_SERVICES" "$new_services"
        fi
    fi

    # Reload Caddy configuration to remove the service
    reload_caddy

    log_success "Service $service_name disabled"
}

# ============================================================================
# Status Display
# ============================================================================

show_status() {
    log_header "Platform Status"

    echo -e "${CYAN}Services:${NC}"

    # Get public base URL from cache
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")

    # Show Caddy status first if it's configured
    if [ -f "$PLATFORM_ROOT/caddy/docker-compose.yml" ]; then
        if [ "$SERVICES_STARTED" = true ]; then
            echo -e "  ${GREEN}✓${NC} Caddy Reverse Proxy (Welcome Page)"
            if [ -n "$public_base_url" ] && [ "$public_base_url" != "http://localhost" ]; then
                echo -e "    ${BLUE}${public_base_url}${NC}"
            else
                echo -e "    ${BLUE}http://localhost${NC}"
            fi
        else
            echo -e "  ${BLUE}ℹ${NC} Caddy Reverse Proxy (configured, not started)"
        fi
    fi

    # Services to display URLs for (only if running)
    local url_services=("contactdb" "babelfish" "crm-reply" "meeting-prep" "dailydigest")

    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"

        # Check if selected
        local selected=false
        for selected_id in "${SELECTED_SERVICES[@]}"; do
            if [ "$selected_id" = "$id" ]; then
                selected=true
                break
            fi
        done

        if [ "$selected" = true ]; then
            if [ "$SERVICES_STARTED" = true ]; then
                # Services are running - show checkmark and URLs
                echo -e "  ${GREEN}✓${NC} $desc"

                # Only display URL for specific services
                local show_url=false
                for url_service in "${url_services[@]}"; do
                    if [ "$url_service" = "$id" ]; then
                        show_url=true
                        break
                    fi
                done

                if [ "$show_url" = true ]; then
                    # Use public base URL if available, otherwise fall back to localhost
                    if [ -n "$public_base_url" ] && [ "$public_base_url" != "http://localhost" ]; then
                        echo -e "    ${BLUE}${public_base_url}/${id}${NC}"
                    else
                        echo -e "    ${BLUE}http://localhost:$port${NC}"
                    fi
                fi
            else
                # Services are configured but not started
                echo -e "  ${BLUE}ℹ${NC} $desc (configured, not started)"
            fi
        fi
    done

    echo ""
    log_info "Workspace: $PLATFORM_ROOT"
    log_info "Docker network: $DOCKER_NETWORK"
    echo ""

    if [ "$SERVICES_STARTED" = false ]; then
        echo "To manage services:"
        echo "  $0 start <service|all>    # Start services"
        echo "  $0 stop <service|all>     # Stop services"
        echo "  $0 update <service|all>   # Update services (pull, rebuild, restart)"
        echo "  $0 enable <service>       # Enable a new service"
        echo "  $0 disable <service>      # Disable a service"
        echo "  $0 status                 # Show service status"
        echo ""
    fi
}

show_running_status() {
    log_header "Platform Status - Running Services"

    # Get public base URL from cache
    local public_base_url=$(load_from_cache "PUBLIC_BASE_URL")

    # Check Caddy status first
    if [ -f "$PLATFORM_ROOT/caddy/docker-compose.yml" ]; then
        local caddy_running=$(docker ps --filter "name=monadical-caddy" --format "{{.Names}}" 2>/dev/null | wc -l | xargs)

        if [ "$caddy_running" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} Caddy Reverse Proxy (Welcome Page)"
            echo -e "    Containers: ${GREEN}1${NC}/1 running"
            if [ -n "$public_base_url" ]; then
                echo -e "    URL: ${BLUE}${public_base_url}${NC}"
            else
                echo -e "    URL: ${BLUE}http://localhost${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠${NC} Caddy Reverse Proxy (stopped)"
            echo -e "    Containers: ${YELLOW}0${NC}/1 running"
        fi
    fi

    # Services to display URLs for
    local url_services=("contactdb" "babelfish" "crm-reply" "meeting-prep")

    for service_def in "${AVAILABLE_SERVICES[@]}"; do
        IFS='|' read -r id repo branch port desc mandatory <<< "$service_def"

        # Check if service directory exists (service was configured)
        if [ ! -d "$PLATFORM_ROOT/$id" ]; then
            continue
        fi

        # Use service id as container name pattern
        local container_pattern="$id"
        local running_containers=$(docker ps --filter "name=${container_pattern}" --format "{{.Names}}" 2>/dev/null | wc -l | xargs)
        local total_containers=$(docker ps -a --filter "name=${container_pattern}" --format "{{.Names}}" 2>/dev/null | wc -l | xargs)

        # Skip if service has no containers at all (not deployed)
        if [ "$total_containers" -eq 0 ]; then
            continue
        fi

        if [ "$running_containers" -gt 0 ]; then
            # Service has running containers
            echo -e "  ${GREEN}✓${NC} $desc"

            # Show container status summary
            echo -e "    Containers: ${GREEN}${running_containers}${NC}/${total_containers} running"

            # Only display URL for specific services
            local show_url=false
            for url_service in "${url_services[@]}"; do
                if [ "$url_service" = "$id" ]; then
                    show_url=true
                    break
                fi
            done

            if [ "$show_url" = true ]; then
                # Use public base URL if available, otherwise fall back to localhost
                if [ -n "$public_base_url" ] && [ "$public_base_url" != "http://localhost" ]; then
                    echo -e "    URL: ${BLUE}${public_base_url}/${id}${NC}"
                else
                    echo -e "    URL: ${BLUE}http://localhost:$port${NC}"
                fi
            fi
        else
            # Service configured but not running
            echo -e "  ${YELLOW}⚠${NC} $desc (stopped)"
            echo -e "    Containers: ${YELLOW}0${NC}/${total_containers} running"
        fi
    done

    echo ""
    log_info "Workspace: $PLATFORM_ROOT"
    log_info "Docker network: $DOCKER_NETWORK"
    echo ""
    echo "To manage services:"
    echo "  $0 start <service|all>    # Start services"
    echo "  $0 stop <service|all>     # Stop services"
    echo "  $0 update <service|all>   # Update services (pull, rebuild, restart)"
    echo "  $0 enable <service>       # Enable a new service"
    echo "  $0 disable <service>      # Disable a service"
    echo "  $0 status                 # Show service status"
    echo ""
}

# ============================================================================
# Main Installation Flow
# ============================================================================

install() {
    log_header "Installing $PLATFORM_NAME"

    check_dependencies
    init_cache
    setup_github_auth
    setup_caddy
    setup_enrichment_apis
    select_services
    clone_services
    configure_all_services
    setup_docker_network
    start_services
    show_status

    log_success "Installation complete!"
    echo ""
    log_info "To manage your platform:"
    echo "  cd $PLATFORM_ROOT"
    echo "  docker compose -f <service>/docker-compose.yml logs"
    echo "  # Or use docker-compose if you have v1 installed"
    echo ""
}

# ============================================================================
# Command Handling
# ============================================================================

cmd_self_update() {
    log_header "Self-Update InternalAI CLI"

    local REPO="Monadical-SAS/internalai-setup"
    local SCRIPT_PATH="$(realpath "$0")"

    log_info "Current installation: $SCRIPT_PATH"
    log_info "Fetching latest version from GitHub..."

    # Get the latest commit SHA to bypass CDN cache
    local LATEST_SHA=$(curl -fsSL "https://api.github.com/repos/$REPO/commits/main" | grep -o '"sha": "[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$LATEST_SHA" ]; then
        log_error "Failed to fetch latest commit SHA from GitHub API"
        exit 1
    fi

    log_info "Latest commit: ${LATEST_SHA:0:7}"

    local INSTALL_URL="https://raw.githubusercontent.com/$REPO/$LATEST_SHA/setup.sh"

    # Create temporary file
    TMP_FILE=$(mktemp)
    trap "rm -f $TMP_FILE" EXIT

    # Download the latest version
    if ! curl -fsSL "$INSTALL_URL" -o "$TMP_FILE"; then
        log_error "Failed to download latest version from $INSTALL_URL"
        exit 1
    fi

    # Verify it's a valid bash script
    if ! head -n 1 "$TMP_FILE" | grep -q "^#!/bin/bash"; then
        log_error "Downloaded file does not appear to be a valid bash script"
        exit 1
    fi

    log_success "Downloaded latest version"

    # Check if we need sudo
    if [ -w "$SCRIPT_PATH" ]; then
        SUDO=""
    else
        if command -v sudo &> /dev/null; then
            SUDO="sudo"
            log_info "Requesting admin privileges to update..."
        else
            log_error "No write permission to $SCRIPT_PATH and sudo not available"
            exit 1
        fi
    fi

    # Replace the current script with the new version
    log_info "Installing update..."
    if [ -n "$SUDO" ]; then
        $SUDO cp "$TMP_FILE" "$SCRIPT_PATH"
        $SUDO chmod +x "$SCRIPT_PATH"
    else
        cp "$TMP_FILE" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi

    log_success "InternalAI CLI updated successfully!"
    log_info "Run 'internalai help' to see any new features"

    # Exit immediately to prevent bash from reading the modified script
    # Bash has a file position pointer that becomes invalid after we replace the script
    exit 0
}

show_usage() {
    echo "InternalAI Platform CLI - by Monadical"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install                - Install platform (default)"
    echo "  status                 - Show running services and container statuses"
    echo "  start <service|all>    - Start specific service or all services"
    echo "  stop <service|all>     - Stop specific service or all services"
    echo "  restart <service|all>  - Restart specific service or all services"
    echo "  update                 - Update the internalai CLI to the latest version"
    echo "  upgrade <service|all>  - Upgrade service (stop, pull, build, start)"
    echo "  enable <service>       - Enable and configure a new service"
    echo "  disable <service>      - Disable a service (stops it and optionally removes directory)"
    echo "  caddy <action>         - Manage Caddy reverse proxy (start|stop|restart|status|logs|new-password)"
    echo "  cache [show|edit]      - Manage credential cache (show all or edit specific variable)"
    echo "  help                   - Show this help"
    echo ""
    echo "Options:"
    echo "  --no-cache           - Ignore cached selections and prompt for everything"
    echo ""
    echo "Examples:"
    echo "  $0 update              # Update internalai CLI"
    echo "  $0 start all           # Start all configured services"
    echo "  $0 stop contactdb      # Stop contactdb service"
    echo "  $0 restart babelfish   # Restart babelfish service"
    echo "  $0 upgrade babelfish   # Upgrade babelfish service"
    echo "  $0 upgrade all         # Upgrade all services"
    echo "  $0 enable crm-reply    # Enable CRM Reply service"
    echo "  $0 disable babelfish   # Disable Babelfish service"
    echo "  $0 caddy new-password  # Generate new Caddy password"
    echo "  $0 cache               # Show all cached credentials (masked)"
    echo "  $0 cache edit AUTH_TYPE    # Edit specific cache variable"
    echo ""
}

main() {
    local command="${1:-install}"
    local service_arg="${2:-}"

    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --no-cache)
                IGNORE_CACHE=true
                ;;
        esac
    done

    case "$command" in
        install)
            install
            ;;
        status)
            show_running_status
            ;;
        start)
            cmd_start "$service_arg"
            ;;
        stop)
            cmd_stop "$service_arg"
            ;;
        restart)
            cmd_restart "$service_arg"
            ;;
        update)
            cmd_self_update
            ;;
        upgrade)
            cmd_upgrade "$service_arg"
            ;;
        enable)
            cmd_enable "$service_arg"
            ;;
        disable)
            cmd_disable "$service_arg"
            ;;
        caddy)
            cmd_caddy "$service_arg"
            ;;
        cache)
            shift  # Remove 'cache' from args
            cmd_cache "$@"
            ;;
        help|--help|-h)
            show_usage
            ;;
        --no-cache)
            # Already handled above, treat as install
            install
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# ============================================================================
# Entry Point
# ============================================================================

main "$@"
