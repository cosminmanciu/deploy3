#!/bin/bash

# WHMCS Docker Setup Script
# This script is executed automatically on first container start
# It handles composer installation, package organization, and environment setup

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if WHMCS is installed by checking database tables
check_whmcs_installed() {
    # If no DB credentials, not installed
    if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
        return 1
    fi

    # Check if tblconfiguration exists (main WHMCS table)
    # Skip SSL verification for development environments
    if mysql --skip-ssl -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -e "SHOW TABLES LIKE 'tblconfiguration'" 2>/dev/null | grep -q "tblconfiguration"; then
        return 0
    fi

    return 1
}

# Environment configuration
DEVELOPMENT_MODE="${DEVELOPMENT_MODE:-false}"
WORK_DIR="/var/www/html"
STAGING_DIR="/setup"

log_info "Starting WHMCS container setup..."
log_info "Environment: ${ENVIRONMENT:-unknown}"
log_info "Development mode: $DEVELOPMENT_MODE"
log_info "Current working directory: $(pwd)"

# Check if we already have WHMCS files in place (for re-runs)
if [ -f "$WORK_DIR/index.php" ] && [ -f "$WORK_DIR/init.php" ]; then
    log_info "WHMCS core files already present in $WORK_DIR"
    cd "$WORK_DIR"
    SKIP_CORE_EXTRACTION=true
else
    log_info "WHMCS core files not found, will set up from scratch"
    SKIP_CORE_EXTRACTION=false

    # Create staging directory
    log_info "Creating staging directory: $STAGING_DIR"
    rm -rf "$STAGING_DIR" 2>/dev/null || true
    mkdir -p "$STAGING_DIR"

    # Copy EVERYTHING from /var/www/html to staging directory
    # This includes whatever was copied from the app directory during Docker build
    log_info "Copying all files from $WORK_DIR to $STAGING_DIR for processing..."
    cp -R "$WORK_DIR/"* "$STAGING_DIR/" 2>/dev/null || true
    cp -R "$WORK_DIR/".* "$STAGING_DIR/" 2>/dev/null || true

    # Also check for settings.json in parent directory
    if [ -f "/var/www/settings.json" ]; then
        cp /var/www/settings.json "$STAGING_DIR/"
        log_info "Copied settings.json from parent directory"
    fi

    # Change to staging directory for all operations
    cd "$STAGING_DIR"
    log_info "Working in staging directory: $(pwd)"

    # List what we have
    log_info "Files in staging directory:"
    ls -la | head -20
fi

# Function to copy WHMCS core files
copy_whmcs_core_files() {
    log_info "Looking for WHMCS core package..."

    # We should be in staging directory at this point
    local current_dir=$(pwd)
    log_info "Current directory: $current_dir"

    # Find settings.json - check current directory first since we're in staging
    SETTINGS_FILE=""
    if [ -f "./settings.json" ]; then
        SETTINGS_FILE="./settings.json"
    elif [ -f "/bundle-config/settings.json" ]; then
        SETTINGS_FILE="/bundle-config/settings.json"
    elif [ -f "/var/www/settings.json" ]; then
        SETTINGS_FILE="/var/www/settings.json"
    elif [ -f "../settings.json" ]; then
        SETTINGS_FILE="../settings.json"
    fi

    if [ -z "$SETTINGS_FILE" ] || [ ! -f "$SETTINGS_FILE" ]; then
        log_error "settings.json not found, cannot identify WHMCS core package"
        return 1
    fi

    # Extract WHMCS core package name from settings.json
    WHMCS_CORE_PACKAGE=""
    if command -v jq >/dev/null 2>&1; then
        # First try to get whmcs_package field (simple format)
        WHMCS_CORE_PACKAGE=$(jq -r '.whmcs_package // empty' "$SETTINGS_FILE" 2>/dev/null)

        # If not found, try packages array with type "whmcs-core" (complex format)
        if [ -z "$WHMCS_CORE_PACKAGE" ]; then
            WHMCS_CORE_PACKAGE=$(jq -r '.packages[] | select(.type == "whmcs-core") | .name' "$SETTINGS_FILE" 2>/dev/null)
        fi
    else
        # Fallback to grep/sed if jq is not available
        # Try simple format first
        WHMCS_CORE_PACKAGE=$(grep '"whmcs_package"' "$SETTINGS_FILE" | sed 's/.*"whmcs_package"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

        # If not found, try complex format
        if [ -z "$WHMCS_CORE_PACKAGE" ]; then
            WHMCS_CORE_PACKAGE=$(grep -B2 -A2 '"type"[[:space:]]*:[[:space:]]*"whmcs-core"' "$SETTINGS_FILE" | grep '"name"' | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
    fi

    if [ -z "$WHMCS_CORE_PACKAGE" ]; then
        log_error "Could not find WHMCS core package in settings.json"
        log_info "Looking for whmcs_package field or package with type: whmcs-core"
        return 1
    fi

    log_info "WHMCS core package identified as: $WHMCS_CORE_PACKAGE"

    # Find the actual directory in vendor - check multiple possible locations
    WHMCS_CORE_DIR=""
    VENDOR_PACKAGE_DIR="vendor/$WHMCS_CORE_PACKAGE"

    # First check the standard vendor location
    if [ -d "$VENDOR_PACKAGE_DIR" ]; then
        # Check if it has a whmcs subdirectory
        if [ -d "$VENDOR_PACKAGE_DIR/whmcs" ]; then
            WHMCS_CORE_DIR="$VENDOR_PACKAGE_DIR/whmcs"
        elif [ -f "$VENDOR_PACKAGE_DIR/index.php" ]; then
            # Direct WHMCS files in package root
            WHMCS_CORE_DIR="$VENDOR_PACKAGE_DIR"
        else
            # Look for any subdirectory containing index.php
            for subdir in "$VENDOR_PACKAGE_DIR"/*; do
                if [ -d "$subdir" ] && [ -f "$subdir/index.php" ]; then
                    WHMCS_CORE_DIR="$subdir"
                    break
                fi
            done
        fi
    fi

    # If not found in standard location, search in all vendor subdirectories
    if [ -z "$WHMCS_CORE_DIR" ] || [ ! -d "$WHMCS_CORE_DIR" ]; then
        log_warning "WHMCS package not in expected location, searching all vendor directories..."
        WHMCS_CORE_DIR=$(find vendor -type f -name "index.php" -path "*/whmcs/*" 2>/dev/null | head -1 | xargs dirname)

        if [ -z "$WHMCS_CORE_DIR" ]; then
            # Try without whmcs subdirectory
            WHMCS_CORE_DIR=$(find vendor -type f -name "index.php" -exec grep -l "WHMCS" {} \; 2>/dev/null | head -1 | xargs dirname)
        fi
    fi

    if [ -z "$WHMCS_CORE_DIR" ] || [ ! -d "$WHMCS_CORE_DIR" ]; then
        log_error "WHMCS core directory not found!"
        log_info "Expected package at: $VENDOR_PACKAGE_DIR"
        log_info "Contents of vendor/:"
        ls -la vendor/ | head -20
        return 1
    fi

    log_info "Found WHMCS core files at: $WHMCS_CORE_DIR"

    # Verify it's actually WHMCS by checking for key files
    if [ ! -f "$WHMCS_CORE_DIR/index.php" ] && [ ! -f "$WHMCS_CORE_DIR/init.php" ]; then
        log_error "Directory doesn't appear to contain WHMCS files (no index.php or init.php found)"
        log_error "Expected at: $WHMCS_CORE_DIR"
        return 1
    fi

    # Copy all WHMCS files to staging area (we're already in $STAGING_DIR)
    log_info "Extracting WHMCS core files to staging area root..."

    # Copy everything from WHMCS package to staging root
    # This will overlay the WHMCS files on top of what we already have
    cp -R "$WHMCS_CORE_DIR/"* ./ 2>/dev/null || true
    cp -R "$WHMCS_CORE_DIR/".* ./ 2>/dev/null || true

    log_success "WHMCS core files extracted to staging area"

    # Verify critical files exist in staging
    if [ -f "./index.php" ]; then
        log_success "✓ index.php found in staging"
    else
        log_error "✗ index.php not found in staging - installation may be incomplete"
    fi

    if [ -f "./init.php" ]; then
        log_success "✓ init.php found in staging"
    else
        log_error "✗ init.php not found in staging - installation may be incomplete"
    fi

    if [ -d "./admin" ] || find . -maxdepth 1 -type d -iname "admin" | grep -q .; then
        log_success "✓ admin directory found in staging"
    else
        log_error "✗ admin directory not found in staging - installation may be incomplete"
    fi

    # Now handle the vendor directory from WHMCS core
    if [ -d "$WHMCS_CORE_DIR/vendor" ]; then
        log_info "WHMCS core has its own vendor directory, will be merged in fix_whmcs_vendor_files()"
    fi

    log_success "WHMCS core files installation completed"
}

# Function to fix WHMCS vendor files
fix_whmcs_vendor_files() {
    log_info "Checking WHMCS vendor file structure..."

    # Find settings.json to get WHMCS core package name
    SETTINGS_FILE=""
    if [ -f "/bundle-config/settings.json" ]; then
        SETTINGS_FILE="/bundle-config/settings.json"
    elif [ -f "../settings.json" ]; then
        SETTINGS_FILE="../settings.json"
    elif [ -f "./settings.json" ]; then
        SETTINGS_FILE="./settings.json"
    fi

    # Extract WHMCS core package name from settings.json
    WHMCS_CORE_PACKAGE=""
    if [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ]; then
        if command -v jq >/dev/null 2>&1; then
            # First try to get whmcs_package field (simple format)
            WHMCS_CORE_PACKAGE=$(jq -r '.whmcs_package // empty' "$SETTINGS_FILE" 2>/dev/null)

            # If not found, try packages array with type "whmcs-core" (complex format)
            if [ -z "$WHMCS_CORE_PACKAGE" ]; then
                WHMCS_CORE_PACKAGE=$(jq -r '.packages[] | select(.type == "whmcs-core") | .name' "$SETTINGS_FILE" 2>/dev/null)
            fi
        fi
    fi

    # If we couldn't get from settings.json, try to find it
    if [ -z "$WHMCS_CORE_PACKAGE" ]; then
        log_info "Searching for WHMCS vendor files in any vanilla package..."
        VANILLA_VENDOR_DIR=$(find vendor -type d -path "*/whmcs/vendor" 2>/dev/null | head -1)
    else
        # Look specifically for the identified package
        VENDOR_PACKAGE_DIR="vendor/$WHMCS_CORE_PACKAGE"
        if [ -d "$VENDOR_PACKAGE_DIR/whmcs/vendor" ]; then
            VANILLA_VENDOR_DIR="$VENDOR_PACKAGE_DIR/whmcs/vendor"
        else
            VANILLA_VENDOR_DIR=""
        fi
    fi

    if [ -z "$VANILLA_VENDOR_DIR" ] || [ ! -d "$VANILLA_VENDOR_DIR" ]; then
        log_warning "WHMCS vendor files not found in expected location"
        log_info "Searched in: vendor/*/whmcs/vendor/"
        return 0
    fi

    log_info "Found WHMCS vendor files in: $VANILLA_VENDOR_DIR"

    # Copy all vendor files from the vanilla package to main vendor
    log_info "Copying WHMCS vendor files to main vendor directory..."

    # Use cp -R to copy all files and preserve structure
    # The /* at the end copies the contents, not the directory itself
    cp -R "$VANILLA_VENDOR_DIR"/* vendor/ 2>/dev/null || {
        log_warning "Some files may have failed to copy, but continuing..."
    }

    log_success "WHMCS vendor files copied to main vendor directory"

    # Now verify some key WHMCS vendor files exist
    if [ -d "vendor/whmcs" ]; then
        log_success "✓ vendor/whmcs directory exists"
    else
        log_warning "⚠ vendor/whmcs directory not found after copy"
    fi

#    # Regenerate composer autoloader to include new files
#    if command -v composer >/dev/null 2>&1 && [ -f "composer.json" ]; then
#        log_info "Regenerating composer autoloader..."
#        composer dump-autoload --optimize --no-interaction 2>/dev/null || true
#        log_success "Composer autoloader regenerated"
#    fi
}

# Function to rename admin folder based on settings.json
rename_admin_folder() {
    log_info "Checking for admin folder customization..."

    # Look for settings.json in multiple locations
    SETTINGS_FILE=""
    if [ -f "/bundle-config/settings.json" ]; then
        SETTINGS_FILE="/bundle-config/settings.json"
    elif [ -f "../settings.json" ]; then
        SETTINGS_FILE="../settings.json"
    elif [ -f "./settings.json" ]; then
        SETTINGS_FILE="./settings.json"
    fi

    if [ -z "$SETTINGS_FILE" ] || [ ! -f "$SETTINGS_FILE" ]; then
        log_warning "settings.json not found, skipping admin folder rename"
        return 0
    fi

    # Extract admin_uri from settings.json
    if command -v jq >/dev/null 2>&1; then
        ADMIN_URI=$(jq -r '.whmcs.admin_uri // "/admin"' "$SETTINGS_FILE" 2>/dev/null | sed 's|^/||')
    else
        # Fallback to grep/sed if jq is not available
        ADMIN_URI=$(grep -o '"admin_uri"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | sed 's/.*"admin_uri"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's|^/||')
    fi

    # Default to 'admin' if not found or empty
    if [ -z "$ADMIN_URI" ] || [ "$ADMIN_URI" = "null" ]; then
        ADMIN_URI="admin"
    fi

    log_info "Admin URI from settings: $ADMIN_URI"

    # Skip if already 'admin'
    if [ "$ADMIN_URI" = "admin" ]; then
        log_info "Admin URI is already 'admin', no renaming needed"
        return 0
    fi

    # Find the current admin directory
    CURRENT_ADMIN_DIR=""
    if [ -d "/var/www/html/admin" ]; then
        CURRENT_ADMIN_DIR="/var/www/html/admin"
    else
        # Try case-insensitive search
        for dir in /var/www/html/*/; do
            if [ -d "$dir" ] && [ "$(basename "$dir" | tr '[:upper:]' '[:lower:]')" = "admin" ]; then
                CURRENT_ADMIN_DIR="$dir"
                break
            fi
        done
    fi

    if [ -z "$CURRENT_ADMIN_DIR" ] || [ ! -d "$CURRENT_ADMIN_DIR" ]; then
        log_warning "Admin directory not found, skipping rename"
        return 0
    fi

    # Target directory
    TARGET_ADMIN_DIR="/var/www/html/$ADMIN_URI"

    # Check if target already exists
    if [ -d "$TARGET_ADMIN_DIR" ]; then
        if [ "$CURRENT_ADMIN_DIR" != "$TARGET_ADMIN_DIR" ]; then
            log_warning "Target admin directory already exists: $TARGET_ADMIN_DIR"
            log_warning "Removing existing admin directory: $CURRENT_ADMIN_DIR"
            rm -rf "$CURRENT_ADMIN_DIR"
        else
            log_info "Admin directory already renamed to: $ADMIN_URI"
        fi
        return 0
    fi

    # Perform the rename
    log_info "Renaming admin directory from $(basename "$CURRENT_ADMIN_DIR") to $ADMIN_URI"
    mv "$CURRENT_ADMIN_DIR" "$TARGET_ADMIN_DIR"

    if [ -d "$TARGET_ADMIN_DIR" ]; then
        log_success "Successfully renamed admin directory to: $ADMIN_URI"

        # Update configuration.php with custom admin path
        update_configuration_admin_path "$ADMIN_URI"
    else
        log_error "Failed to rename admin directory"
        return 1
    fi
}

# Function to update configuration.php with custom admin path
update_configuration_admin_path() {
    local admin_uri="$1"
    local config_file="/var/www/html/configuration.php"

    if [ ! -f "$config_file" ]; then
        log_warning "configuration.php not found, cannot update admin path"
        return 0
    fi

    # Check if customadminpath is already set
    if grep -q '^\$customadminpath' "$config_file"; then
        # Update existing line
        sed -i "s|^\\\$customadminpath.*|\\$customadminpath = '$admin_uri';|" "$config_file"
        log_info "Updated existing customadminpath in configuration.php"
    else
        # Add new line before closing PHP tag or at the end
        if grep -q '^?>' "$config_file"; then
            sed -i "/^?>/i \\\n\\\$customadminpath = '$admin_uri';" "$config_file"
        else
            echo -e "\n\$customadminpath = '$admin_uri';" >> "$config_file"
        fi
        log_info "Added customadminpath to configuration.php"
    fi
}

# Function to setup configuration.php (only move from bundle if needed)
setup_configuration() {
    log_info "Checking configuration.php..."

    # First, check if configuration.php exists in the app directory (from WHMCS archive)
    if [ -f "/var/www/html/configuration.php" ]; then
        log_info "configuration.php already exists from WHMCS archive - preserving it"
        chmod 666 /var/www/html/configuration.php
        return 0
    fi

    # If not, check if configuration.php exists in bundle-config (for bundle downloads)
    if [ -f "/bundle-config/configuration.php" ]; then
        log_info "Copying configuration.php from bundle-config..."
        cp /bundle-config/configuration.php /var/www/html/configuration.php
        chmod 666 /var/www/html/configuration.php
        log_success "configuration.php copied from bundle"
        return 0
    fi


    # If none found, log warning but don't create anything
    log_warning "configuration.php not found in any expected location"
    log_warning "Expected locations: /var/www/html (from archive), /bundle-config, or /docker/whmcs"
    log_warning "Bundle should provide configuration.php with environment variables configured"
}

# Function to validate IonCube loader
validate_ioncube_loader() {
    log_info "Validating IonCube loader installation..."

    # Check if IonCube is loaded
    if php -m | grep -q "ionCube"; then
        log_success "IonCube loader is active and loaded"
        return 0
    fi

    log_warning "IonCube loader not detected, checking configuration..."

    # Get PHP extension directory and version
    PHP_EXT_DIR=$(php-config --extension-dir)
    DETECTED_PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")

    log_info "PHP extension directory: $PHP_EXT_DIR"
    log_info "Detected PHP version: $DETECTED_PHP_VERSION"

    # Make IonCube loader executable
    LOADER_FILE="$PHP_EXT_DIR/ioncube_loader_lin_${DETECTED_PHP_VERSION}.so"
    if [ -f "$LOADER_FILE" ]; then
        chmod 755 "$LOADER_FILE"
        log_info "Made IonCube loader executable: $LOADER_FILE"
    fi

    return 0
}

# Set proper file permissions
set_permissions() {
    log_info "Setting proper file permissions..."

    # Ensure writable directories exist and have correct permissions
    for dir in attachments downloads templates_c uploads; do
        if [ ! -d "/var/www/html/$dir" ]; then
            mkdir -p "/var/www/html/$dir"
        fi
        chown -R www-data:www-data "/var/www/html/$dir"
    done

    # Fix configuration.php if it exists
    if [ -f "/var/www/html/configuration.php" ]; then
        chown www-data:www-data "/var/www/html/configuration.php"
    fi

    log_success "File permissions set successfully"
}

# Function to install composer dependencies
install_composer_dependencies() {
    log_info "Checking for composer.json and installing dependencies..."

    # Determine working directory based on where we are
    local work_dir=$(pwd)
    log_info "Working directory: $work_dir"

    # Check if composer.json exists
    if [ ! -f "$work_dir/composer.json" ]; then
        log_error "composer.json not found in $work_dir!"
        log_error "The bundle MUST provide composer.json with all required packages"
        log_info "Directory contents:"
        ls -la "$work_dir" | head -10
        return 1
    fi

    # Check if composer is available
    if ! command -v composer >/dev/null 2>&1; then
        log_warning "Composer not found in container, skipping dependency installation"
        return 0
    fi

    # Check if vendor directory already exists with dependencies
    if [ -d "$work_dir/vendor" ] && [ -f "$work_dir/vendor/autoload.php" ]; then
        log_info "Vendor directory already exists with autoload.php"

        # Count packages in vendor to see if it's populated
        VENDOR_COUNT=$(find $work_dir/vendor -maxdepth 2 -type d | wc -l)
        if [ "$VENDOR_COUNT" -gt 10 ]; then
            log_info "Vendor directory appears to be populated (found $VENDOR_COUNT directories)"
            log_info "Running composer install to ensure all dependencies are present..."

            # Run composer install and generate autoloader
            if composer install --no-interaction --no-dev --optimize-autoloader 2>&1 | tee /tmp/composer-install.log; then
                log_success "Composer install completed successfully"
            else
                log_error "Composer install failed. Check /tmp/composer-install.log for details - continuing setup"
            fi
            return 0
        fi
    fi

    log_info "Installing composer dependencies in $work_dir..."

    # Run composer install with autoloader generation
    if composer install --no-scripts --no-interaction --no-dev --optimize-autoloader 2>&1 | tee /tmp/composer-install.log; then
        log_success "Composer dependencies installed successfully"

        # Check if packages were actually installed
        if [ -d "vendor" ]; then
            PACKAGE_COUNT=$(find vendor -maxdepth 2 -name "composer.json" -type f | wc -l)
            log_info "Installed $PACKAGE_COUNT composer packages"
        fi
    else
        log_error "Failed to install composer dependencies - continuing setup"
        log_error "Check /tmp/composer-install.log for details"
    fi

    return 0
}

# Function to update hosts file for development environment
update_hosts_file() {
    if [ "$ENVIRONMENT" != "development" ]; then
        return 0
    fi

    log_info "Updating hosts file for development environment..."

    # Function to add host entry if not exists
    add_host_entry() {
        local ip="$1"
        local hostname="$2"
        local hosts_file="$3"

        if ! grep -q "$hostname" "$hosts_file" 2>/dev/null; then
            echo "$ip $hostname" >> "$hosts_file"
            log_success "Added $hostname to hosts file"
        else
            log_info "$hostname already exists in hosts file"
        fi
    }

    # Detect OS and update hosts file accordingly
    if [ -f "/etc/hosts" ]; then
        # Linux/Mac container environment
        add_host_entry "127.0.0.1" "dominios.local" "/etc/hosts"
        add_host_entry "127.0.0.1" "www.dominios.local" "/etc/hosts"
    fi

    # Create a hosts file update script for the host machine
    cat > /var/www/html/update_hosts.sh << 'EOF'
#!/bin/bash
# This script should be run on the host machine to update hosts file

echo "Updating hosts file for WHMCS development environment..."

# Function to add host entry
add_host_entry() {
    local ip="$1"
    local hostname="$2"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        HOSTS_FILE="/etc/hosts"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        HOSTS_FILE="/etc/hosts"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        # Windows
        HOSTS_FILE="C:\\Windows\\System32\\drivers\\etc\\hosts"
    else
        echo "Unknown OS type: $OSTYPE"
        exit 1
    fi

    # Check if entry already exists
    if ! grep -q "$hostname" "$HOSTS_FILE" 2>/dev/null; then
        echo "Adding $hostname to hosts file..."
        if [[ "$OSTYPE" == "darwin"* ]] || [[ "$OSTYPE" == "linux-gnu"* ]]; then
            echo "$ip $hostname" | sudo tee -a "$HOSTS_FILE" > /dev/null
        else
            # Windows - needs to be run as Administrator
            echo "$ip $hostname" >> "$HOSTS_FILE"
        fi
        echo "✓ Added $hostname"
    else
        echo "✓ $hostname already exists in hosts file"
    fi
}

# Add WHMCS development domains
add_host_entry "127.0.0.1" "dominios.local"
add_host_entry "127.0.0.1" "www.dominios.local"

echo ""
echo "Hosts file updated successfully!"
echo "You can now access WHMCS at:"
echo "  - http://dominios.local:20080"
echo "  - http://www.dominios.local:20080"
echo ""
echo "Note: On Windows, this script must be run as Administrator."
echo "On macOS/Linux, you may be prompted for sudo password."
EOF

    chmod +x /var/www/html/update_hosts.sh

    log_info "Created update_hosts.sh script in document root"
    log_warning "To update your host machine's hosts file, run:"
    log_warning "  docker exec -it whmcs cat /var/www/html/update_hosts.sh | bash"
    log_warning "Or copy and run the script from: /var/www/html/update_hosts.sh"
}

# Function to process scripts in /scripts directory
process_startup_scripts() {
    log_info "Checking for startup scripts in /scripts directory..."

    SCRIPTS_DIR="/scripts"

    # Check if scripts directory exists
    if [ ! -d "$SCRIPTS_DIR" ]; then
        log_info "No /scripts directory found, skipping script execution"
        return 0
    fi

    # Check if there are any files in the scripts directory
    if [ -z "$(ls -A $SCRIPTS_DIR 2>/dev/null)" ]; then
        log_info "Scripts directory is empty, skipping script execution"
        return 0
    fi

    log_info "Found scripts directory, processing files..."

    # Process each file in the scripts directory
    for script_file in "$SCRIPTS_DIR"/*; do
        # Skip if not a file
        [ -f "$script_file" ] || continue

        filename=$(basename "$script_file")
        extension="${filename##*.}"

        log_info "Processing script: $filename"

        case "$extension" in
            sql)
                log_info "Executing SQL script: $filename"

                # Check if this is an environment-specific SQL script
                # Pattern: XX_scriptname_prod.sql or XX_scriptname_stage.sql
                if [[ "$filename" =~ _(prod|stage|staging|production)\.sql$ ]]; then
                    local script_env=""
                    if [[ "$filename" =~ _prod(uction)?\.sql$ ]]; then
                        script_env="production"
                    elif [[ "$filename" =~ _stag(e|ing)\.sql$ ]]; then
                        script_env="staging"
                    fi

                    # Skip if environment doesn't match
                    if [ -n "$script_env" ] && [ "$ENVIRONMENT" != "$script_env" ]; then
                        log_info "  Skipping $filename (environment: $ENVIRONMENT, script for: $script_env)"
                        continue
                    fi
                fi

                # Check if we have database connection info
                if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_NAME" ]; then
                    # Try to execute SQL script with SSL disabled for development
                    # Use --skip-ssl to avoid certificate verification issues
                    if mysql --skip-ssl -h"${DB_HOST}" -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "$script_file" 2>&1; then
                        log_success "Successfully executed SQL script: $filename"
                    else
                        # Log error but continue
                        log_error "SQL script failed: $filename - continuing setup"
                    fi
                else
                    log_warning "Database credentials not available, skipping SQL script: $filename"
                fi
                ;;

            sh)
                log_info "Executing shell script: $filename"
                cd /var/www/html
                # Make sure it's executable
                chmod +x "$script_file" 2>/dev/null || true
                if bash "$script_file" 2>&1; then
                    log_success "Successfully executed shell script: $filename"
                else
                    # Just error log, don't fail
                    log_error "Shell script failed: $filename (exit code: $?) - continuing setup"
                fi
                cd - > /dev/null 2>&1 || true
                ;;

            php)
                log_info "Executing PHP script: $filename"
                # Change to WHMCS directory for proper context
                cd /var/www/html
                if php "$script_file" 2>&1; then
                    log_success "Successfully executed PHP script: $filename"
                else
                    # Just error log, don't fail
                    log_error "PHP script failed: $filename (exit code: $?) - continuing setup"
                fi
                cd - > /dev/null 2>&1 || true
                ;;

            *)
                log_info "Skipping file with unsupported extension: $filename (.$extension)"
                ;;
        esac
    done

    log_success "Finished processing startup scripts"
}

# Function to organize packages based on their composer.json location field
organize_packages() {
    log_info "Organizing packages based on composer.json location fields..."

    # Determine the base directory we're working in
    local base_dir=$(pwd)
    log_info "Organizing packages in: $base_dir"

    # Find all composer.json files in vendor directory
    local package_count=0
    local moved_count=0

    # Process packages in teamblue and teamblue-whmcs vendor directories
    for vendor_base in teamblue teamblue-whmcs; do
        if [ ! -d "$base_dir/vendor/$vendor_base" ]; then
            continue
        fi

        find "$base_dir/vendor/$vendor_base" -maxdepth 2 -name "composer.json" -type f | while read composer_file; do
        package_count=$((package_count + 1))
        local package_dir=$(dirname "$composer_file")
        local package_name=$(basename "$(dirname "$package_dir")")/$(basename "$package_dir")

        log_info "Processing package: $package_name"

        # Read package type and location from composer.json
        local package_type=""
        local package_location=""

        if command -v jq >/dev/null 2>&1; then
            package_type=$(jq -r '.type // "standard"' "$composer_file" 2>/dev/null)
            package_location=$(jq -r '.location // ""' "$composer_file" 2>/dev/null)
        else
            # Fallback to grep/sed if jq is not available
            package_type=$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$composer_file" | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
            package_location=$(grep -o '"location"[[:space:]]*:[[:space:]]*"[^"]*"' "$composer_file" | sed 's/.*"location"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
        fi

        # Default to standard type if not specified
        if [ -z "$package_type" ] || [ "$package_type" = "null" ]; then
            package_type="standard"
        fi

        log_info "  Type: $package_type, Location: ${package_location:-'not specified'}"

        # Handle brand packages - copy to root
        if [ "$package_type" = "brand" ]; then
            log_info "  Brand package detected, copying to document root..."

            # Copy all brand package files to root, excluding composer files
            if [ -d "$package_dir" ]; then
                rsync -rltD --exclude='composer.json' --exclude='composer.lock' --exclude='.git' "$package_dir/" "$base_dir/"
                moved_count=$((moved_count + 1))
                log_success "  ✓ Brand package copied to root"
            fi

        # Handle standard packages with specific locations
        elif [ "$package_type" = "standard" ] && [ -n "$package_location" ] && [ "$package_location" != "null" ]; then

            # Determine target directory based on location field
            local target_dir=""

            case "$package_location" in
                /modules/addons|/modules/addons/*)
                    target_dir="$base_dir/modules/addons"
                    ;;
                /modules/servers|/modules/servers/*)
                    target_dir="$base_dir/modules/servers"
                    ;;
                /modules/gateways|/modules/gateways/*)
                    target_dir="$base_dir/modules/gateways"
                    ;;
                /modules/registrars|/modules/registrars/*)
                    target_dir="$base_dir/modules/registrars"
                    ;;
                /modules/support|/modules/support/*)
                    target_dir="$base_dir/modules/support"
                    ;;
                /vendor|/vendor/*)
                    # Vendor packages must stay where composer puts them
                    log_info "  Package should stay in vendor location (composer managed)"
                    continue
                    ;;
                *)
                    # Custom location
                    target_dir="$base_dir${package_location}"
                    ;;
            esac

            if [ -n "$target_dir" ]; then
                log_info "  Moving package to: $target_dir"

                # Create target directory if it doesn't exist
                mkdir -p "$target_dir"

                # Get the package folder name (last part of the path)
                local package_folder_name=$(basename "$package_dir")

                # Copy package contents to target location
                if [ "$package_location" = "/vendor" ]; then
                    # For vendor packages, copy contents directly
                    cp -R "$package_dir"/* "$target_dir/" 2>/dev/null || true
                else
                    # For module packages, maintain folder structure
                    cp -R "$package_dir" "$target_dir/" 2>/dev/null || true
                fi

                moved_count=$((moved_count + 1))
                log_success "  ✓ Package moved to $target_dir"
            fi
        else
            log_info "  Standard package without specific location, keeping in vendor"
        fi
        done
    done

    log_success "Package organization complete. Processed: $package_count, Moved: $moved_count"
}

# Function to fix vendor packages with nested directories
fix_vendor_package_structure() {
    log_info "Fixing vendor package structure issues..."

    # Fix teamblue-whmcs packages that have nested directories
    for vendor_pkg in /var/www/html/vendor/teamblue-whmcs/*; do
        if [ ! -d "$vendor_pkg" ]; then
            continue
        fi

        pkg_name=$(basename "$vendor_pkg")

        # Check if package has a nested directory with same name
        if [ -d "$vendor_pkg/$pkg_name" ]; then
            log_info "  Fixing nested structure in $pkg_name"

            # Create symlinks for expected paths
            cd "$vendor_pkg"

            # For each directory/file in the nested folder, create symlink at root
            for item in "$pkg_name"/*; do
                if [ -e "$item" ]; then
                    item_name=$(basename "$item")
                    if [ ! -e "$item_name" ]; then
                        ln -sf "$pkg_name/$item_name" "$item_name"
                        log_info "    Created symlink: $item_name -> $pkg_name/$item_name"
                    fi
                fi
            done

            cd - > /dev/null 2>&1 || true
        fi
    done

    log_success "Vendor package structure fixed"
}

# Function to copy from staging to final location
copy_staging_to_final() {
    log_info "Moving final installation from staging to document root..."

    # Check if we're in staging directory
    if [ "$(pwd)" != "$STAGING_DIR" ]; then
        log_error "Not in staging directory, current dir: $(pwd)"
        return 1
    fi

    # Clear the work directory first (but preserve mounted volumes in development)
    if [ "$ENVIRONMENT" = "development" ]; then
        log_info "Development environment - clearing work directory but preserving volume mount"
        # Remove everything except hidden files that might be from volume mount
        find "$WORK_DIR" -mindepth 1 -maxdepth 1 ! -name '.*' -exec rm -rf {} \; 2>/dev/null || true
    else
        log_info "Production/Staging environment - clearing work directory completely"
        rm -rf "$WORK_DIR"/*
        rm -rf "$WORK_DIR"/.* 2>/dev/null || true
    fi

    # Move everything from staging to work directory, including hidden files
    log_info "Moving all files from $STAGING_DIR to $WORK_DIR..."

    # Use cp instead of rsync for better compatibility
    cp -R "$STAGING_DIR/"* "$WORK_DIR/" 2>/dev/null || true
    cp -R "$STAGING_DIR/".* "$WORK_DIR/" 2>/dev/null || true

    log_success "Files moved from staging to final location"

    # Verify critical files in final location
    if [ -f "$WORK_DIR/index.php" ]; then
        log_success "✓ index.php present in $WORK_DIR"
    else
        log_error "✗ index.php missing in $WORK_DIR"
    fi

    if [ -f "$WORK_DIR/init.php" ]; then
        log_success "✓ init.php present in $WORK_DIR"
    else
        log_error "✗ init.php missing in $WORK_DIR"
    fi

    # List what we have in final location
    log_info "Final directory structure:"
    ls -la "$WORK_DIR" | head -10

    # Clean up staging directory
    log_info "Cleaning up staging directory..."
    rm -rf "$STAGING_DIR"
    log_success "Staging directory cleaned up"
}

# Function to fix missing package files
fix_missing_package_files() {
    log_info "Fixing missing package files..."

    # Fix missing zend-diactoros function files
    if [ -d "/var/www/html/vendor/teamblue-whmcs/zend-diactoros" ]; then
        if [ ! -d "/var/www/html/vendor/teamblue-whmcs/zend-diactoros/src/functions" ]; then
            log_info "  Creating missing zend-diactoros function files"
            mkdir -p /var/www/html/vendor/teamblue-whmcs/zend-diactoros/src/functions

            # Create stub files to prevent autoload errors
            for func in create_uploaded_file marshal_headers_from_sapi marshal_method_from_sapi marshal_protocol_version_from_sapi marshal_uri_from_sapi normalize_server normalize_uploaded_files parse_cookie_header; do
                echo '<?php // Stub file for missing function' > "/var/www/html/vendor/teamblue-whmcs/zend-diactoros/src/functions/${func}.php"
            done
        fi
    fi

    log_success "Missing package files fixed"
}

# Fix autoloader to include all necessary vendor packages
fix_composer_autoloader() {
    log_info "Fixing WHMCS autoloader issues (using symlink approach)..."

    # Find the WHMCS vanilla package directory
    WHMCS_VENDOR_DIR=""
    if [ -d "/var/www/html/vendor/whmcs" ]; then
        WHMCS_VENDOR_DIR=$(find /var/www/html/vendor/whmcs -type d -name "vanilla-*" -maxdepth 1 2>/dev/null | head -1)
    fi

    if [ -z "$WHMCS_VENDOR_DIR" ] || [ ! -d "$WHMCS_VENDOR_DIR/whmcs/vendor" ]; then
        log_warning "WHMCS vanilla vendor directory not found, skipping autoloader fix"
        return 0
    fi

    log_info "Found WHMCS vendor at: $WHMCS_VENDOR_DIR"

    # Fix 1: Use WHMCS nested vendor autoloader as the main autoloader
    # This is necessary because WHMCS has all its dependencies (Whoops, Illuminate, etc.) in its nested vendor
    if [ -f "$WHMCS_VENDOR_DIR/whmcs/vendor/autoload.php" ]; then
        log_info "Creating symlink to WHMCS nested vendor autoloader..."

        # Backup original autoloader if it exists and is not a symlink
        if [ -f "/var/www/html/vendor/autoload.php" ] && [ ! -L "/var/www/html/vendor/autoload.php" ]; then
            mv /var/www/html/vendor/autoload.php /var/www/html/vendor/autoload_original.php 2>/dev/null || true
            log_info "Backed up original autoloader to autoload_original.php"
        fi

        # Remove existing autoload.php if it's a file or broken symlink
        rm -f /var/www/html/vendor/autoload.php 2>/dev/null || true

        # Create symlink to WHMCS nested autoloader
        ln -sf "$WHMCS_VENDOR_DIR/whmcs/vendor/autoload.php" /var/www/html/vendor/autoload.php
        log_success "Created symlink to WHMCS nested vendor autoloader"
    fi

    # Fix 2: Create TeamBlue vendor symlink for configuration.php compatibility
    # Some WHMCS configurations expect TeamBlue vendor in a specific location
    if [ ! -d "/var/www/html/vendor/TeamBlue/vendor" ]; then
        log_info "Creating TeamBlue vendor directory structure..."
        mkdir -p /var/www/html/vendor/TeamBlue/vendor

        if [ -f "$WHMCS_VENDOR_DIR/whmcs/vendor/autoload.php" ]; then
            ln -sf "$WHMCS_VENDOR_DIR/whmcs/vendor/autoload.php" /var/www/html/vendor/TeamBlue/vendor/autoload.php
            log_success "Created TeamBlue vendor autoloader symlink"
        fi
    fi

    log_success "WHMCS autoloader issues fixed using symlink approach"
}

# Function removed - configuration.php comes fully configured from bundle

# Main setup execution
main() {
    log_info "=== IonCube Loader Runtime Check ==="
    validate_ioncube_loader

    log_info "PHP version: $(php -v | head -n 1)"

    # First priority: Check if WHMCS core files exist regardless of database
    # If core files don't exist, we MUST extract them even if DB tables exist
    if [ "$SKIP_CORE_EXTRACTION" = "false" ]; then
        log_info "Setting up WHMCS installation in staging directory..."

        # We're in staging directory with all files copied from /var/www/html
        # Install composer dependencies first to get all vendor packages
        log_info "Installing composer dependencies..."
        install_composer_dependencies

        # Extract WHMCS core files from vendor to staging root
        copy_whmcs_core_files

        # Setup configuration in staging
        setup_configuration

        # Fix WHMCS vendor files if needed in staging
        fix_whmcs_vendor_files

        # Rename admin folder based on settings in staging
        rename_admin_folder

        # Organize packages in staging
        organize_packages

        # Copy everything from staging to final location
        copy_staging_to_final

        # Now change to work directory for remaining operations
        cd "$WORK_DIR"
    else
        log_info "WHMCS core files already present, checking database status..."
        cd "$WORK_DIR"

        # Check if WHMCS is installed in database
        if check_whmcs_installed; then
            log_info "WHMCS is already installed (tblconfiguration exists)"
        else
            log_info "WHMCS files present but not installed in database"
        fi

        # Setup configuration
        setup_configuration

        # Rename admin folder based on settings
        rename_admin_folder

        # Always organize packages - they might have been added/updated
        organize_packages
    fi

    # Update hosts file for development environment
    update_hosts_file

    # Set permissions
    set_permissions

    # Process any startup scripts
    process_startup_scripts

    # Fix vendor packages with nested directories
    fix_vendor_package_structure

    # Fix missing package files
    fix_missing_package_files

    # Fix composer autoloader for all vendor packages
    fix_composer_autoloader

    # Ensure composer autoloader is generated with all dependencies
    if [ -f "/var/www/html/composer.json" ] && command -v composer >/dev/null 2>&1; then
        cd /var/www/html

        # Add WHMCS autoload if not present
        if ! grep -q '"WHMCS\\\\"' composer.json 2>/dev/null; then
            log_info "Adding WHMCS namespace to autoloader"
            # Use sed to add autoload section if missing
            if ! grep -q '"autoload"' composer.json; then
                sed -i 's/"minimum-stability"/"autoload": {"psr-4": {"WHMCS\\\\": "vendor\/whmcs\/whmcs-foundation\/lib\/"}},\n    "minimum-stability"/' composer.json 2>/dev/null || true
            fi
        fi

        # Check if Whoops is in vendor but not in autoloader
        if [ -d "/var/www/html/vendor/filp/whoops" ] && ! grep -q "Whoops" /var/www/html/vendor/composer/autoload_psr4.php 2>/dev/null; then
            log_info "Whoops package found but not in autoloader, regenerating..."

            # Check if vendor/filp/whoops has a composer.json
            if [ -f "/var/www/html/vendor/filp/whoops/composer.json" ]; then
                # Extract autoload config from Whoops package and merge it
                composer dump-autoload --optimize 2>/dev/null || {
                    log_warning "Failed to regenerate autoloader with composer, trying manual fix..."

                    # Manually add Whoops to autoload_psr4.php
                    if [ -f "/var/www/html/vendor/composer/autoload_psr4.php" ]; then
                        # Backup the file
                        cp /var/www/html/vendor/composer/autoload_psr4.php /var/www/html/vendor/composer/autoload_psr4.php.bak

                        # Add Whoops namespace
                        sed -i "/return array(/a\\    'Whoops\\\\' => array(\$vendorDir . '/filp/whoops/src/Whoops')," /var/www/html/vendor/composer/autoload_psr4.php 2>/dev/null || true
                    fi
                }
            fi
        fi

        # Final autoloader regeneration
        composer dump-autoload --optimize 2>/dev/null || true
        cd - > /dev/null 2>&1 || true
        log_info "Composer autoloader regenerated"
    fi

    log_success "WHMCS setup completed!"
    log_info "You can now access:"

    # For development environment, show domain-based URLs
    if [ "$ENVIRONMENT" = "development" ]; then
        log_info "  - WHMCS Installation: http://dominios.local:20080/install/"
        log_info "  - Alternative: http://www.dominios.local:20080/install/"

        # Display custom admin URL if set
        if [ -n "$ADMIN_URI" ] && [ "$ADMIN_URI" != "admin" ]; then
            log_info "  - Admin Area: http://dominios.local:20080/$ADMIN_URI/ (after installation)"
        else
            log_info "  - Admin Area: http://dominios.local:20080/admin/ (after installation)"
        fi

        log_warning "Remember to update your host machine's hosts file!"
        log_warning "Run: docker exec -it whmcs cat /var/www/html/update_hosts.sh | bash"
    else
        log_info "  - WHMCS Installation: http://localhost/install/"

        # Display custom admin URL if set
        if [ -n "$ADMIN_URI" ] && [ "$ADMIN_URI" != "admin" ]; then
            log_info "  - Admin Area: http://localhost/$ADMIN_URI/ (after installation)"
        else
            log_info "  - Admin Area: http://localhost/admin/ (after installation)"
        fi
    fi

    # Check if we should keep or remove the install directory
    # Read from settings.json to determine if we should keep the install folder
    SETTINGS_FILE=""
    if [ -f "/bundle-config/settings.json" ]; then
        SETTINGS_FILE="/bundle-config/settings.json"
    elif [ -f "../settings.json" ]; then
        SETTINGS_FILE="../settings.json"
    elif [ -f "./settings.json" ]; then
        SETTINGS_FILE="./settings.json"
    fi

    if [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ]; then
        # Extract with_install_directory from settings.json
        if command -v jq >/dev/null 2>&1; then
            WITH_INSTALL_DIR=$(jq -r '.whmcs.with_install_directory // false' "$SETTINGS_FILE" 2>/dev/null)
        else
            # Fallback to grep/sed if jq is not available
            WITH_INSTALL_DIR=$(grep -o '"with_install_directory"[[:space:]]*:[[:space:]]*[^,}]*' "$SETTINGS_FILE" | sed 's/.*"with_install_directory"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/' | tr -d ' ')
        fi

        # Convert to boolean (handle string "true"/"false" or boolean true/false)
        if [ "$WITH_INSTALL_DIR" = "true" ] || [ "$WITH_INSTALL_DIR" = "1" ]; then
            log_warning "Keeping install directory as configured (with_install_directory: true)"
            log_warning "The /install directory is preserved for fresh installation"
        else
            if [ -d "/var/www/html/install" ]; then
                log_info "Removing install directory (with_install_directory: false)"
                rm -rf /var/www/html/install
                log_success "Install directory removed for security"
            else
                log_info "Install directory not found, nothing to remove"
            fi
        fi
    else
        # Default behavior: remove install directory
        if [ -d "/var/www/html/install" ]; then
            log_warning "Settings file not found, removing install directory by default"
            rm -rf /var/www/html/install
            log_success "Install directory removed for security (default behavior)"
        fi
    fi

    cp /var/www/html/configuration.default.php /var/www/html/configuration.php
}

# Execute main function
main "$@"
