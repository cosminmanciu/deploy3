#!/bin/bash

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

# Function to organize packages based on their composer.json location field
organize_packages() {
    log_info "Organizing packages based on composer.json location fields..."
    
    local package_count=0
    local moved_count=0
    
    # Process each vendor directory (both teamblue and teamblue-whmcs)
    for vendor_dir in /var/www/html/vendor/teamblue /var/www/html/vendor/teamblue-whmcs; do
        if [ ! -d "$vendor_dir" ]; then
            continue
        fi
        
        log_info "Processing vendor directory: $vendor_dir"
        
        # Find all composer.json files in this vendor directory
        find "$vendor_dir" -maxdepth 2 -name "composer.json" -type f | while read composer_file; do
            package_count=$((package_count + 1))
            local package_dir=$(dirname "$composer_file")
            local package_name=$(basename "$vendor_dir")/$(basename "$package_dir")
            
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
                    # Check if package has actual content to copy
                    if [ "$(ls -A $package_dir 2>/dev/null | grep -v composer | wc -l)" -gt 0 ]; then
                        rsync -rltD --exclude='composer.json' --exclude='composer.lock' --exclude='.git' "$package_dir/" /var/www/html/
                        moved_count=$((moved_count + 1))
                        log_success "  ✓ Brand package copied to root"
                    else
                        log_info "  Brand package has no content to copy (only composer files)"
                    fi
                fi
                
            # Handle standard packages with specific locations
            elif [ "$package_type" = "standard" ] && [ -n "$package_location" ] && [ "$package_location" != "null" ]; then
                
                # Determine target directory based on location field
                local target_dir=""
                
                case "$package_location" in
                    /modules/addons|/modules/addons/*)
                        target_dir="/var/www/html/modules/addons"
                        ;;
                    /modules/servers|/modules/servers/*)
                        target_dir="/var/www/html/modules/servers"
                        ;;
                    /modules/gateways|/modules/gateways/*)
                        target_dir="/var/www/html/modules/gateways"
                        ;;
                    /modules/registrars|/modules/registrars/*)
                        target_dir="/var/www/html/modules/registrars"
                        ;;
                    /modules/support|/modules/support/*)
                        target_dir="/var/www/html/modules/support"
                        ;;
                    /vendor|/vendor/*)
                        log_info "  Package should stay in vendor location"
                        continue
                        ;;
                    /*)
                        # Direct path under document root
                        target_dir="/var/www/html${package_location}"
                        ;;
                    *)
                        # Custom location
                        target_dir="/var/www/html${package_location}"
                        ;;
                esac
                
                if [ -n "$target_dir" ]; then
                    log_info "  Moving package to: $target_dir"
                    
                    # Create target directory if it doesn't exist
                    mkdir -p "$target_dir"
                    
                    # Get the package folder name (last part of the path)
                    local package_folder_name=$(basename "$package_dir")
                    
                    # Copy entire package directory to target location
                    if [ -d "$package_dir" ] && [ "$(ls -A $package_dir 2>/dev/null | wc -l)" -gt 0 ]; then
                        cp -R "$package_dir" "$target_dir/" 2>/dev/null || {
                            log_warning "  Failed to copy $package_folder_name to $target_dir"
                            continue
                        }
                        moved_count=$((moved_count + 1))
                        log_success "  ✓ Package $package_folder_name moved to $target_dir"
                    else
                        log_warning "  Package directory is empty or doesn't exist"
                    fi
                fi
            else
                log_info "  Standard package without specific location, keeping in vendor"
            fi
        done
    done
    
    log_success "Package organization complete. Moved: $moved_count packages"
}

# Run the organization
organize_packages