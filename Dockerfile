ARG PHP_VERSION=8.1
ARG WHMCS_VERSION=8.11.2
ARG ADMIN_URI=admin
ARG ENVIRONMENT=development

# Stage 1: Base dependencies
FROM php:${PHP_VERSION}-apache AS base-deps

# Set environment variables for build compatibility (Colima support)
ENV CC=gcc
ENV CXX=g++

# Install build tools and system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    binutils \
    make \
    autoconf \
    libtool \
    pkg-config \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libzip-dev \
    libonig-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libsodium-dev \
    libicu-dev \
    zlib1g-dev \
    libkrb5-dev \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions including SOAP
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        gd \
        pdo_mysql \
        mysqli \
        mbstring \
        zip \
        xml \
        curl \
        sodium \
        bcmath \
        intl \
        calendar \
        exif \
        gettext \
        soap

# Install IMAP extension
# First attempt with standard packages, fallback to Sury if needed
RUN apt-get update && \
    (apt-get install -y --no-install-recommends libc-client-dev libkrb5-dev || \
    (apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release wget && \
     wget -qO - https://packages.sury.org/php/README.txt | bash -x && \
     apt-get update && \
     apt-get install -y --no-install-recommends libc-client-dev libkrb5-dev)) && \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl && \
    docker-php-ext-install -j$(nproc) imap && \
    rm -rf /var/lib/apt/lists/*

# Stage 2: Additional tools
FROM base-deps AS tools

# Install additional tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    zip \
    unzip \
    cron \
    supervisor \
    default-mysql-client \
    jq \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# Stage 3: Composer
FROM tools AS composer-stage

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Stage 4: IonCube setup
FROM composer-stage AS ioncube-stage

# Copy ionCube loaders from bundle
COPY ioncube/ /tmp/ioncube/

# Install ionCube Loader (required for WHMCS)
RUN set -ex && \
    echo "=== IonCube Loader Installation ===" && \
    export PHP_EXT_DIR=$(php-config --extension-dir) && \
    export DETECTED_PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;") && \
    echo "Detected PHP version: ${DETECTED_PHP_VERSION}" && \
    echo "PHP extension directory: ${PHP_EXT_DIR}" && \
    # Detect architecture \
    export ARCH=$(uname -m) && \
    echo "Detected architecture: ${ARCH}" && \
    # Map architecture to ionCube directory \
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        export IONCUBE_ARCH="aarch64"; \
    else \
        export IONCUBE_ARCH="amd64"; \
    fi && \
    echo "Using ionCube architecture: ${IONCUBE_ARCH}" && \
    # Ensure extension directory exists \
    mkdir -p "$PHP_EXT_DIR" && \
    # Copy the appropriate loader \
    export LOADER_FILE="ioncube_loader_lin_${DETECTED_PHP_VERSION}.so" && \
    echo "Looking for loader: /tmp/ioncube/${IONCUBE_ARCH}/$LOADER_FILE" && \
    if [ -f "/tmp/ioncube/${IONCUBE_ARCH}/$LOADER_FILE" ]; then \
        echo "Copying $LOADER_FILE to $PHP_EXT_DIR/" && \
        cp "/tmp/ioncube/${IONCUBE_ARCH}/$LOADER_FILE" "$PHP_EXT_DIR/" && \
        chmod 644 "$PHP_EXT_DIR/$LOADER_FILE" && \
        echo "Successfully copied IonCube loader"; \
    else \
        echo "ERROR: IonCube loader $LOADER_FILE not found for architecture ${IONCUBE_ARCH}!" && \
        echo "Available loaders in /tmp/ioncube/${IONCUBE_ARCH}/:" && \
        ls -la /tmp/ioncube/${IONCUBE_ARCH}/ 2>/dev/null || echo "Directory not found" && \
        echo "All available ionCube files:" && \
        find /tmp/ioncube -name "*.so" -type f && \
        exit 1; \
    fi && \
    # Create the configuration file \
    echo "Creating IonCube configuration..." && \
    echo "[Zend]" > /usr/local/etc/php/conf.d/00-ioncube.ini && \
    echo "; IonCube Loader for PHP ${DETECTED_PHP_VERSION} on ${IONCUBE_ARCH}" >> /usr/local/etc/php/conf.d/00-ioncube.ini && \
    echo "; Installed from bundle during Docker build" >> /usr/local/etc/php/conf.d/00-ioncube.ini && \
    echo "zend_extension=${PHP_EXT_DIR}/${LOADER_FILE}" >> /usr/local/etc/php/conf.d/00-ioncube.ini && \
    # Final verification \
    echo "=== Final Verification ===" && \
    ls -la "$PHP_EXT_DIR/$LOADER_FILE" && \
    cat /usr/local/etc/php/conf.d/00-ioncube.ini && \
    echo "Testing PHP with IonCube..." && \
    php -v | head -3 && \
    echo "Checking if IonCube is actually loaded..." && \
    (php -m | grep -i ioncube && echo "✓ IonCube is loaded in PHP modules") || echo "⚠ IonCube not detected in PHP modules (may load at runtime)" && \
    echo "IonCube loader installation completed successfully" && \
    # Cleanup \
    rm -rf /tmp/ioncube

# Stage 5: Configuration
FROM ioncube-stage AS config-stage

# Copy configuration files
COPY config/php/php.ini /usr/local/etc/php/
COPY config/php/whmcs-settings.ini /usr/local/etc/php/conf.d/
COPY config/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Configure Apache
RUN echo "ServerName localhost" >> /etc/apache2/apache2.conf \
    && a2enmod rewrite ssl

# Stage 6: Scripts and setup
FROM config-stage AS scripts-stage

# Copy setup script and make it executable
COPY setup.sh /usr/local/bin/setup.sh
RUN chmod +x /usr/local/bin/setup.sh

# Copy healthcheck.php to web directory
COPY config/docker/healthcheck.php /var/www/html/healthcheck.php

# Create directories for optional files
RUN mkdir -p /scripts /app /bundle-config

# Copy scripts directory
COPY scripts/ /scripts/

# Stage 7: Entrypoint setup
FROM scripts-stage AS entrypoint-stage

# Create entrypoint script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
echo "Starting WHMCS container..."\n\
\n\
# Handle configuration files for Kubernetes deployment (if they exist in the image)\n\
if [ -f "/bundle-config/settings.json" ] && [ ! -f "/var/www/html/../settings.json" ]; then\n\
    ln -sf /bundle-config/settings.json /var/www/html/../settings.json\n\
    echo "Created symlink for settings.json"\n\
fi\n\
\n\
# Copy configuration.php if it exists in bundle-config\n\
if [ -f "/bundle-config/configuration.php" ] && [ ! -f "/var/www/html/configuration.php" ]; then\n\
    cp /bundle-config/configuration.php /var/www/html/configuration.php\n\
    echo "Copied configuration.php from bundle-config"\n\
fi\n\
\n\
# Copy app configuration files to working directory if they exist\n\
if [ -f "/bundle-config/.env" ] && [ ! -f "/var/www/html/.env" ]; then\n\
    cp /bundle-config/.env /var/www/html/.env\n\
    echo "Copied .env file"\n\
fi\n\
\n\
# Handle composer.json - bundle MUST provide this\n\
if [ ! -f "/var/www/html/composer.json" ]; then\n\
    if [ -f "/bundle-config/composer.json" ]; then\n\
        cp /bundle-config/composer.json /var/www/html/composer.json\n\
        echo "Copied composer.json from bundle-config"\n\
    else\n\
        echo "ERROR: No composer.json found - bundle MUST provide this file!"\n\
        echo "The bundle creation process should include composer.json in /bundle-config/"\n\
        # Don't exit here - let setup.sh handle the error\n\
    fi\n\
fi\n\
\n\
if [ -f "/bundle-config/auth.json" ] && [ ! -f "/var/www/html/auth.json" ]; then\n\
    cp /bundle-config/auth.json /var/www/html/auth.json\n\
    echo "Copied auth.json"\n\
fi\n\
\n\
# Setup cron for www-data user if cron file exists\n\
if [ -f "/cron/whmcs-cron" ]; then\n\
    echo "Setting up cron for www-data user..."\n\
    # Create log directory if it doesn't exist\n\
    mkdir -p /var/log\n\
    touch /var/log/whmcs-cron.log /var/log/whmcs-cron-daily.log /var/log/whmcs-cron-weekly.log /var/log/whmcs-cron-monthly.log\n\
    chown www-data:www-data /var/log/whmcs-cron*.log\n\
    \n\
    # Install crontab for www-data user\n\
    crontab -u www-data /cron/whmcs-cron\n\
    echo "Cron setup complete"\n\
    \n\
    # Show installed crontab for verification\n\
    echo "Installed crontab:"\n\
    crontab -u www-data -l\n\
fi\n\
\n\
# Run setup script\n\
if [ -f "/usr/local/bin/setup.sh" ]; then\n\
    echo "Running setup script..."\n\
    /usr/local/bin/setup.sh\n\
else\n\
    echo "Setup script not found, skipping setup"\n\
fi\n\
\n\
echo "Starting supervisor..."\n\
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf\n\
' > /usr/local/bin/docker-entrypoint.sh && \
chmod +x /usr/local/bin/docker-entrypoint.sh

# Stage 8: Final image
FROM entrypoint-stage AS final

# Set working directory
WORKDIR /var/www/html

# Create a placeholder file for development builds
RUN mkdir -p app && touch app/.placeholder || true

# Copy application files
COPY app/ /var/www/html/

# Copy cron configuration
COPY cron/ /cron/

# Set build arguments as environment variables
ARG PHP_VERSION
ARG WHMCS_VERSION
ARG ADMIN_URI
ARG ENVIRONMENT

ENV PHP_VERSION=${PHP_VERSION}
ENV WHMCS_VERSION=${WHMCS_VERSION}
ENV ADMIN_URI=${ADMIN_URI}
ENV ENVIRONMENT=${ENVIRONMENT}

RUN mkdir /var/www/html/templates_c

RUN chmod -R 0777 /var/www/html/templates_c

# Set proper ownership
RUN chown -R www-data:www-data /var/www/html

# Expose port 80
EXPOSE 80

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

FROM final AS staging

COPY settings.json /var/www/settings.json
COPY scripts/ /scripts/
# Don't install cron here - let entrypoint handle it

