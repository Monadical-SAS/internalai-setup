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
    "dailydigest|https://github.com/Monadical-SAS/dailydigest.git|main|42190|Stale relationship tracker for ContactDB and DataIndex|false"
)

# DataIndex ingestors
DATAINDEX_INGESTORS=(
    "calendar|ICS Calendar (Fastmail Calendar, iCal)|DATAINDEX_PERSONAL"
    "zulip|Zulip Chat|DATAINDEX_ZULIP"
    "email|Email (mbsync/notmuch)|DATAINDEX_EMAIL"
    "reflector|Reflector API|DATAINDEX_REFLECTOR"
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
        read -s -p "$(echo -e ${YELLOW}${prompt_text}: ${NC})" value
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
# DataIndex Ingestor Selection
# ============================================================================

SELECTED_INGESTORS=()

select_ingestors() {
    log_header "DataIndex Ingestors"

    # Check cache first - use it automatically if it exists
    local cached_ingestors=$(load_from_cache "SELECTED_INGESTORS")
    if [ -n "$cached_ingestors" ]; then
        if [ "$cached_ingestors" = "none" ]; then
            log_info "Using cached selection: No ingestors"
            return
        fi
        IFS=',' read -ra SELECTED_INGESTORS <<< "$cached_ingestors"
        log_info "Using cached ingestor selection: ${#SELECTED_INGESTORS[@]} ingestors"
        return
    fi

    echo "Available ingestors:"
    echo ""

    local index=1
    for ingestor_def in "${DATAINDEX_INGESTORS[@]}"; do
        IFS='|' read -r id name prefix <<< "$ingestor_def"
        echo -e "  ${CYAN}${index}.${NC} ${name}"
        ((index++))
    done

    echo ""
    prompt INGESTORS_INPUT "Enter ingestor numbers (comma-separated) or 'none'" "none"

    if [ "$INGESTORS_INPUT" = "none" ]; then
        log_info "No ingestors selected"
        save_to_cache "SELECTED_INGESTORS" "none"
        return
    fi

    IFS=',' read -ra INDICES <<< "$INGESTORS_INPUT"
    for idx in "${INDICES[@]}"; do
        idx=$(echo "$idx" | xargs)
        ingestor_def="${DATAINDEX_INGESTORS[$((idx-1))]}"
        IFS='|' read -r id name prefix <<< "$ingestor_def"
        SELECTED_INGESTORS+=("$id|$name|$prefix")
    done

    # Save to cache
    local ingestors_str=$(IFS=','; echo "${SELECTED_INGESTORS[*]}")
    save_to_cache "SELECTED_INGESTORS" "$ingestors_str"

    log_success "Selected ingestors: ${#SELECTED_INGESTORS[@]}"
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
    local password_hash=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$caddy_password" 2>/dev/null)

    if [ -z "$password_hash" ]; then
        log_error "Failed to generate password hash"
        return 1
    fi

    save_to_cache "CADDY_PASSWORD_HASH" "$password_hash"

    # Show password (only once, first time)
    if [ "$show_password" = true ]; then
        echo ""
        log_warning "====================================================================="
        log_warning "  CADDY BASIC AUTH PASSWORD - SAVE THIS NOW!"
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

    # Generate Caddyfile
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

$caddy_address {
$tls_config

    # Basic auth for all routes
    # Regenerate with: $0 caddy new-password
    basicauth {
        admin $password_hash
    }

    # Root path - serve HTML index
    handle / {
        root * /srv
        file_server
    }

    # ContactDB Frontend
    handle /contactdb/* {
        reverse_proxy host.docker.internal:42173 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # ContactDB Backend API
    handle_path /contactdb-api/* {
        reverse_proxy host.docker.internal:42800 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # DataIndex API
    handle_path /dataindex/* {
        reverse_proxy host.docker.internal:42180 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # Babelfish Matrix Synapse (with WebSocket support)
    handle_path /babelfish/* {
        reverse_proxy host.docker.internal:8880 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
            # WebSocket support
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}
        }
    }

    # Babelfish API
    handle_path /babelfish-api/* {
        reverse_proxy host.docker.internal:8000 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # CRM Reply API
    handle_path /crm-reply/* {
        reverse_proxy host.docker.internal:3001 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # Meeting Prep Frontend
    handle /meeting-prep/* {
        reverse_proxy host.docker.internal:42380 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # Meeting Prep Backend API
    handle_path /meeting-prep-api/* {
        reverse_proxy host.docker.internal:42381 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
    }

    # DailyDigest (Frontend and Backend merged)
    handle /dailydigest/* {
        reverse_proxy host.docker.internal:42190 {
            header_up Host {http.reverse_proxy.upstream.hostport}
            header_up X-Real-IP {http.request.remote.host}
            header_up X-Forwarded-For {http.request.remote.host}
            header_up X-Forwarded-Proto {http.request.scheme}
        }
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

    # Generate docker-compose with conditional ports
    cat > "$PLATFORM_ROOT/caddy/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:2-alpine
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
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - monadical-platform
    # Enable access to host services via host.docker.internal
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - CADDY_ADMIN=0.0.0.0:2019
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

cmd_regenerate_password() {
    log_header "Regenerating Caddy Password"

    init_cache

    # Generate new password
    local new_password=$(openssl rand -base64 24)

    # Generate hash
    log_info "Generating password hash..."
    local password_hash=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$new_password" 2>/dev/null)

    if [ -z "$password_hash" ]; then
        log_error "Failed to generate password hash"
        return 1
    fi

    # Save to cache
    save_to_cache "CADDY_PASSWORD" "$new_password"
    save_to_cache "CADDY_PASSWORD_HASH" "$password_hash"

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
            log_error "Usage: $0 caddy {start|stop|restart|status|logs|new-password}"
            exit 1
            ;;
    esac
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

    # Always prompt for ingestors (unless cached)
    select_ingestors

    # Auto-add babelfish ingestor if babelfish service is selected
    local has_babelfish=false
    for service_id in "${SELECTED_SERVICES[@]}"; do
        if [ "$service_id" = "babelfish" ]; then
            # Check if babelfish ingestor is already in the list
            if [ ${#SELECTED_INGESTORS[@]} -gt 0 ]; then
                for ing in "${SELECTED_INGESTORS[@]}"; do
                    if [[ "$ing" == babelfish* ]]; then
                        has_babelfish=true
                        break
                    fi
                done
            fi

            if [ "$has_babelfish" = false ]; then
                SELECTED_INGESTORS+=("babelfish|Babelfish (auto-configured)|DATAINDEX_BABELFISH")
                log_info "Auto-added Babelfish ingestor for DataIndex"
            fi
            break
        fi
    done

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

# Ingestors
EOF

    # Configure each selected ingestor
    if [ ${#SELECTED_INGESTORS[@]} -gt 0 ]; then
        for ingestor_def in "${SELECTED_INGESTORS[@]}"; do
            IFS='|' read -r id name prefix <<< "$ingestor_def"

            case "$id" in
                calendar)
                    echo "" >> "$PLATFORM_ROOT/dataindex/.env"
                    echo "# ICS Calendar Ingestor" >> "$PLATFORM_ROOT/dataindex/.env"
                    prompt_or_cache "DATAINDEX_CALENDAR_URL" "ICS Calendar URL (e.g., Fastmail Calendar iCal)" ""
                    if [ -n "$DATAINDEX_CALENDAR_URL" ]; then
                        echo "${prefix}_TYPE=ics_calendar" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_ICS_URL=$DATAINDEX_CALENDAR_URL" >> "$PLATFORM_ROOT/dataindex/.env"
                    fi
                    ;;

                zulip)
                    echo "" >> "$PLATFORM_ROOT/dataindex/.env"
                    echo "# Zulip Ingestor" >> "$PLATFORM_ROOT/dataindex/.env"
                    prompt_or_cache "DATAINDEX_ZULIP_URL" "Zulip server URL" ""
                    prompt_or_cache "DATAINDEX_ZULIP_EMAIL" "Zulip bot email" ""
                    prompt_or_cache "DATAINDEX_ZULIP_API_KEY" "Zulip API key" "" true

                    if [ -n "$DATAINDEX_ZULIP_URL" ]; then
                        echo "${prefix}_TYPE=zulip" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_ZULIP_URL=$DATAINDEX_ZULIP_URL" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_ZULIP_EMAIL=$DATAINDEX_ZULIP_EMAIL" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_ZULIP_API_KEY=$DATAINDEX_ZULIP_API_KEY" >> "$PLATFORM_ROOT/dataindex/.env"
                    fi
                    ;;

                email)
                    echo "" >> "$PLATFORM_ROOT/dataindex/.env"
                    echo "# Email Ingestor" >> "$PLATFORM_ROOT/dataindex/.env"
                    prompt_or_cache "DATAINDEX_EMAIL_IMAP_HOST" "IMAP host (e.g., imap.fastmail.com)" "imap.fastmail.com"
                    prompt_or_cache "DATAINDEX_EMAIL_IMAP_USER" "IMAP username/email" ""
                    prompt_or_cache "DATAINDEX_EMAIL_IMAP_PASS" "IMAP password" "" true

                    if [ -n "$DATAINDEX_EMAIL_IMAP_HOST" ]; then
                        echo "${prefix}_TYPE=mbsync_email" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_IMAP_HOST=$DATAINDEX_EMAIL_IMAP_HOST" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_IMAP_USER=$DATAINDEX_EMAIL_IMAP_USER" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_IMAP_PASS=$DATAINDEX_EMAIL_IMAP_PASS" >> "$PLATFORM_ROOT/dataindex/.env"
                    fi
                    ;;

                reflector)
                    echo "" >> "$PLATFORM_ROOT/dataindex/.env"
                    echo "# Reflector Ingestor" >> "$PLATFORM_ROOT/dataindex/.env"
                    prompt_or_cache "DATAINDEX_REFLECTOR_API_KEY" "Reflector API key" "" true
                    prompt_or_cache "DATAINDEX_REFLECTOR_API_URL" "Reflector API URL" "https://api-reflector.monadical.com"

                    if [ -n "$DATAINDEX_REFLECTOR_API_KEY" ]; then
                        echo "${prefix}_TYPE=reflector" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_API_KEY=$DATAINDEX_REFLECTOR_API_KEY" >> "$PLATFORM_ROOT/dataindex/.env"
                        echo "${prefix}_API_URL=$DATAINDEX_REFLECTOR_API_URL" >> "$PLATFORM_ROOT/dataindex/.env"
                    fi
                    ;;

                babelfish)
                    echo "" >> "$PLATFORM_ROOT/dataindex/.env"
                    echo "# Babelfish Ingestor (auto-configured)" >> "$PLATFORM_ROOT/dataindex/.env"
                    # Auto-configured, no prompt needed
                    local babelfish_url="http://host.docker.internal:8000"
                    echo "${prefix}_TYPE=babelfish" >> "$PLATFORM_ROOT/dataindex/.env"
                    echo "${prefix}_BASE_URL=$babelfish_url" >> "$PLATFORM_ROOT/dataindex/.env"
                    log_info "Babelfish ingestor configured with URL: $babelfish_url"
                    ;;
            esac
        done
    fi

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
                    git pull 2>&1 | grep -v "password" || {
                        log_warning "Failed to pull latest changes for $id (might be on a different branch or have local changes)"
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

    log_success "Babelfish configured"
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

        # Babelfish's make setup doesn't start services, so start them
        log_info "Starting babelfish services..."
        docker_compose up -d 2>&1 | grep -v "password" || {
            log_error "Failed to start $service_id"
            docker_compose logs --tail=50
            cd "$PLATFORM_ROOT"
            return 1
        }
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
        docker_compose down 2>&1 | grep -v "password" || {
            log_error "Failed to stop $service_id"
            cd "$PLATFORM_ROOT"
            return 1
        }
    else
        log_warning "No docker-compose.yml found for $service_id"
    fi

    cd "$PLATFORM_ROOT"
    log_success "$service_id stopped"
}

update_service() {
    local service_id=$1

    # Caddy doesn't need git updates, but regenerate config files
    if [ "$service_id" = "caddy" ]; then
        log_info "Updating Caddy configuration..."

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

        log_success "Caddy updated with regenerated configuration"
        return $?
    fi

    local service_path="$PLATFORM_ROOT/$service_id"

    # Check if service directory exists
    if [ ! -d "$service_path" ]; then
        log_error "Service $service_id not found at $service_path"
        return 1
    fi

    log_info "Updating $service_id..."

    # Stop service
    stop_service "$service_id" || return 1

    # Pull latest changes
    log_info "Pulling latest changes for $service_id..."
    cd "$service_path"
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
    log_success "$service_id updated"
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

cmd_update() {
    local service_name=$1

    if [ -z "$service_name" ]; then
        log_error "Usage: $0 update <service|all>"
        echo ""
        echo "Configured services:"
        for svc in $(get_configured_services); do
            echo "  - $svc"
        done
        exit 1
    fi

    init_cache

    if [ "$service_name" = "all" ]; then
        log_header "Updating All Services"
        local services=($(get_configured_services))

        # Update contactdb first if it exists
        for svc in "${services[@]}"; do
            if [ "$svc" = "contactdb" ]; then
                update_service "$svc"
            fi
        done

        # Update others
        for svc in "${services[@]}"; do
            if [ "$svc" != "contactdb" ]; then
                update_service "$svc"
            fi
        done
    else
        update_service "$service_name"
    fi
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
    cmd_update "caddy"

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

show_usage() {
    echo "Monadical Platform Setup"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install platform (default)"
    echo "  status               - Show running services and container statuses"
    echo "  start <service|all>  - Start specific service or all services"
    echo "  stop <service|all>   - Stop specific service or all services"
    echo "  update <service|all> - Update service (stop, pull, build, start)"
    echo "  enable <service>     - Enable and configure a new service"
    echo "  disable <service>    - Disable a service (stops it and optionally removes directory)"
    echo "  caddy <action>       - Manage Caddy reverse proxy (start|stop|restart|status|logs|new-password)"
    echo "  help                 - Show this help"
    echo ""
    echo "Options:"
    echo "  --no-cache           - Ignore cached selections and prompt for everything"
    echo ""
    echo "Examples:"
    echo "  $0 start all         # Start all configured services"
    echo "  $0 stop contactdb    # Stop contactdb service"
    echo "  $0 update babelfish  # Update babelfish service"
    echo "  $0 enable crm-reply  # Enable CRM Reply service"
    echo "  $0 disable babelfish # Disable Babelfish service"
    echo "  $0 caddy new-password # Generate new Caddy password"
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
        update)
            cmd_update "$service_arg"
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
