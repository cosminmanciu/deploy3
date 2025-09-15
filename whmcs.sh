#!/bin/bash

# WHMCS Docker Control Script
# This script provides a simple interface to manage WHMCS Docker environments
# and reads from settings.json for configuration without modifying it

set -e

# Default configuration
SETTINGS_FILE="settings.json"
DOCKER_COMPOSE="docker-compose.development.yml"

# Detect Docker Compose command format
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    DOCKER_COMPOSE_CMD="docker compose"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display help information
show_help() {
    echo -e "${BLUE}WHMCS Docker Control Script${NC}"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  start               Start WHMCS container using settings.json"
    echo "  stop                Stop the WHMCS container"
    echo "  restart             Restart the WHMCS container"
    echo "  status              Show status of the WHMCS container"
    echo "  logs                Show container logs"
    echo "  shell               Access shell in the WHMCS container"
    echo "  db-shell            Access MySQL shell"
    echo "  import-scripts      Import scripts/databases from /scripts directory"
    echo "  configure-mailpit   Configure WHMCS to use MailPit (dev only)"
    echo "  help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 start            Start WHMCS using settings.json configuration"
    echo "  $0 import-scripts   Import scripts from scripts directory"
    echo "  $0 shell            Access shell in WHMCS container"
}


# Function to import scripts and databases from /scripts
import_scripts() {

    # Source the .env file to get variables
    source .env

    # Get container name and DB credentials from .env file
    local container_name="${CONTAINER_NAME:-whmcs-$WHMCS_VERSION}"
    local db_name="${DB_NAME:-whmcs}"
    local db_user="${DB_USER:-whmcs}"
    local db_password="${DB_PASSWORD:-whmcs_password}"
    local db_host="${DB_HOST:-db}"

    # Check if container is running - Modified grep check
    if ! $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE ps --services --filter "status=running" | grep -q "^whmcs$"; then
        echo -e "${RED}Error: WHMCS container is not running.${NC}"
        echo -e "${YELLOW}Please start the container first with '$0 start'${NC}"
        return 1
    fi

    echo -e "${BLUE}Checking for scripts in /scripts directory inside container...${NC}"

    # Get a list of files in the /scripts directory inside the container
    # The files will be sorted by name
    local files=$($DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec -T whmcs ls -1 /scripts 2>/dev/null || echo "")

    if [ -z "$files" ]; then
        echo -e "${YELLOW}No files found in /scripts directory inside the container.${NC}"
        echo -e "${YELLOW}Make sure you have mounted the directory correctly in your docker-compose.yml:${NC}"
        echo -e "${YELLOW}    volumes:${NC}"
        echo -e "${YELLOW}      - ./scripts:/scripts${NC}"
        return 1
    fi

    echo -e "${GREEN}Found the following files in /scripts:${NC}"
    echo "$files" | while read -r file; do
        echo -e "  - ${YELLOW}$file${NC}"
    done

    # Process each file in alphabetical order
    echo "$files" | sort | while read -r file; do
        # Skip empty lines
        if [ -z "$file" ]; then
            continue
        fi

        # Get file extension
        local extension="${file##*.}"
        echo -e "${BLUE}Processing file: ${YELLOW}$file${NC}"

        case "$extension" in
            sql)
                echo -e "${GREEN}Executing SQL file: $file${NC}"
                echo -e "${GREEN}Importing to database $db_name...${NC}"
                $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec -T whmcs bash -c "mysql -h$db_host -u$db_user -p$db_password $db_name < /scripts/$file"

                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Successfully imported SQL file: $file${NC}"
                else
                    echo -e "${RED}Failed to import SQL file: $file${NC}"
                fi
                ;;
            sh)
                echo -e "${GREEN}Executing shell script: $file${NC}"
                $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec -T whmcs bash -c "cd /scripts && bash /scripts/$file"

                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Successfully executed shell script: $file${NC}"
                else
                    echo -e "${RED}Failed to execute shell script: $file${NC}"
                fi
                ;;
            php)
                echo -e "${GREEN}Executing PHP script: $file${NC}"
                $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec -T whmcs bash -c "cd /scripts && php /scripts/$file"

                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Successfully executed PHP script: $file${NC}"
                else
                    echo -e "${RED}Failed to execute PHP script: $file${NC}"
                fi
                ;;
            *)
                echo -e "${YELLOW}Skipping file with unknown extension: $file${NC}"
                ;;
        esac
    done

    echo -e "${GREEN}Script import process complete!${NC}"
}

# Function to start WHMCS container
start_whmcs() {

    # Check if settings.json exists
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo -e "${RED}Error: $SETTINGS_FILE not found!${NC}"
        echo -e "${YELLOW}Please create a settings.json file with your WHMCS configuration.${NC}"
        return 1
    fi

    # Source .env to get variables
    source .env

    echo -e "${GREEN}Starting WHMCS ${WHMCS_VERSION} containers...${NC}"

    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE up -d --build

    echo -e "${GREEN}WHMCS is starting. Access it at http://localhost:${HOST_PORT}${NC}"

    # Show MailPit info for development builds
    if [ "$ENVIRONMENT" = "development" ]; then
        echo -e "${GREEN}MailPit email testing UI available at http://localhost:${MAILPIT_HTTP_PORT:-21025}${NC}"
        echo -e "${YELLOW}All emails will be captured by MailPit (SMTP: mailpit:1025)${NC}"
    fi
}

# Function to stop WHMCS container
stop_whmcs() {
    echo -e "${YELLOW}Stopping WHMCS containers...${NC}"
    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE down
    echo -e "${GREEN}WHMCS containers stopped.${NC}"
}

# Function to restart WHMCS container
restart_whmcs() {
    echo -e "${YELLOW}Restarting WHMCS containers...${NC}"
    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE restart
    echo -e "${GREEN}WHMCS containers restarted.${NC}"
}

# Function to show status of WHMCS container
show_status() {
    echo -e "${BLUE}WHMCS Container Status:${NC}"
    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE ps
}

# Function to show container logs
show_logs() {
    echo -e "${BLUE}WHMCS Container Logs:${NC}"
    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE logs --tail=100 -f
}

# Function to access shell in WHMCS container
shell_access() {
    echo -e "${BLUE}Accessing shell in WHMCS container...${NC}"
    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec whmcs bash
}

# Function to access MySQL shell
db_shell() {

    # Source .env to get variables
    source .env

    echo -e "${BLUE}Accessing MySQL shell for database ${DB_NAME:-whmcs}...${NC}"
    $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec db mysql -u"${DB_USER:-whmcs}" -p"${DB_PASSWORD:-whmcs_password}" "${DB_NAME:-whmcs}"
}

# Function to configure MailPit for WHMCS
configure_mailpit() {
    # Source .env to get variables
    source .env

    # Check if environment is development
    if [ "$ENVIRONMENT" != "development" ]; then
        echo -e "${YELLOW}MailPit configuration is only available for development environment.${NC}"
        echo -e "${YELLOW}Current environment: ${ENVIRONMENT}${NC}"
        return 1
    fi

    echo -e "${BLUE}Configuring WHMCS to use MailPit for email testing...${NC}"

    # Check if container is running
    if ! $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE ps --services --filter "status=running" | grep -q "^whmcs$"; then
        echo -e "${RED}Error: WHMCS container is not running.${NC}"
        echo -e "${YELLOW}Please start the container first with '$0 start'${NC}"
        return 1
    fi

    # Check if MailPit container is running
    if ! $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE ps --services --filter "status=running" | grep -q "^mailpit$"; then
        echo -e "${RED}Error: MailPit container is not running.${NC}"
        echo -e "${YELLOW}Please ensure MailPit is started with the WHMCS container${NC}"
        return 1
    fi

    # Execute the configuration script
    if [ -f "./scripts/configure_mailpit.php" ]; then
        echo -e "${GREEN}Running MailPit configuration script...${NC}"
        $DOCKER_COMPOSE_CMD -f $DOCKER_COMPOSE exec -T whmcs php /scripts/configure_mailpit.php

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ MailPit configuration completed successfully!${NC}"
            echo -e "${BLUE}📧 MailPit Web UI: http://localhost:${MAILPIT_HTTP_PORT:-21025}${NC}"
            echo -e "${YELLOW}All emails from WHMCS will now be captured by MailPit${NC}"
        else
            echo -e "${RED}Failed to configure MailPit${NC}"
            return 1
        fi
    else
        echo -e "${RED}Error: configure_mailpit.php script not found in ./scripts directory${NC}"
        echo -e "${YELLOW}Please ensure the script exists at: ./scripts/configure_mailpit.php${NC}"
        return 1
    fi
}

# Main script logic
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

command=$1
shift

case "$command" in
    start)
        start_whmcs
        ;;
    stop)
        stop_whmcs
        ;;
    restart)
        restart_whmcs
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    shell)
        shell_access
        ;;
    db-shell)
        db_shell
        ;;
    import-scripts)
        import_scripts
        ;;
    configure-mailpit)
        configure_mailpit
        ;;
    help)
        show_help
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$command'${NC}"
        show_help
        exit 1
        ;;
esac
