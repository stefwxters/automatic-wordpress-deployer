#!/usr/bin/env bash

# ==========================================================================
# AUTOMATIC WORDPRESS DEPLOYMENT SCRIPT (Extreme Compatibility Edition)
# Supports: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux
# Webservers: Nginx / Apache (HTTPD)
# ==========================================================================

# Strict error handling, but allow manual fallbacks where needed
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

cleanup() {
    trap - SIGINT SIGTERM ERR EXIT
    # Optional temporary cleanup files can be processed here if needed
}

# --- OUTPUT COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()   { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- CHECK ROOT PRIVILEGES ---
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be executed as root (sudo)."
    exit 1
fi

# --- ENVIRONMENT ANALYSIS (OS & PACKAGE MANAGER) ---
log_info "Analyzing system environment..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
    OS_LIKE=${ID_LIKE:-""}
else
    log_error "Cannot read /etc/os-release. OS not supported."
    exit 1
fi

if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
else
    log_error "No supported package manager found (apt/dnf/yum)."
    exit 1
fi
log_info "Detected OS: $NAME ($PKG_MANAGER)"

# --- INTERACTIVE QUESTIONS ---
echo "=========================================="
echo "      WORDPRESS DEPLOYMENT CONFIG        "
echo "=========================================="

# 1. Webserver choice
while true; do
    read -rp "Which webserver do you want to use? (nginx/apache): " WEBSERVER_CHOICE
    WEBSERVER_CHOICE=$(echo "$WEBSERVER_CHOICE" | tr '[:upper:]' '[:lower:]')
    if [[ "$WEBSERVER_CHOICE" == "nginx" || "$WEBSERVER_CHOICE" == "apache" || "$WEBSERVER_CHOICE" == "httpd" ]]; then
        if [[ "$WEBSERVER_CHOICE" == "httpd" ]]; then WEBSERVER_CHOICE="apache"; fi
        break
    else
        log_warn "Invalid choice. Please choose 'nginx' or 'apache'."
    fi
done

# 2. Domain name / ServerName
read -rp "Enter your domain name or server IP [localhost]: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-localhost}

# 3. Database settings
read -rp "Database Name [wordpress_db]: " DB_NAME
DB_NAME=${DB_NAME:-wordpress_db}
read -rp "Database User [wp_user]: " DB_USER
DB_USER=${DB_USER:-wp_user}
while true; do
    read -s -rp "Database Password: " DB_PASSWORD
    echo
    if [ -n "$DB_PASSWORD" ]; then break; fi
    log_warn "Password cannot be empty."
done

# --- SYSTEM-SPECIFIC VARIABLES ---
if [[ "$PKG_MANAGER" == "apt" ]]; then
    APACHE_PACKAGE="apache2"
    APACHE_SERVICE="apache2"
    NGINX_PACKAGE="nginx"
    PHP_FPM_PACKAGE="php-fpm"
    # Dynamic detection of the most recent PHP version in the apt repos
    PHP_PREFIX="php" 
    WEB_USER="www-data"
    WEB_GROUP="www-data"
else
    # RHEL / Rocky / AlmaLinux
    APACHE_PACKAGE="httpd"
    APACHE_SERVICE="httpd"
    NGINX_PACKAGE="nginx"
    PHP_PREFIX="php"
    WEB_USER="nginx" # Default for Nginx, we adjust this if Apache is selected
    WEB_GROUP="nginx"
    if [[ "$WEBSERVER_CHOICE" == "apache" ]]; then
        WEB_USER="apache"
        WEB_GROUP="apache"
    fi
fi

TARGET_DIR="/var/www/wordpress"

# --- SYSTEM UPDATES & DEPENDENCIES REPOS ---
log_info "Updating system package repositories and installing basic dependencies..."
if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get update -y
    apt-get install -y curl wget tar unzip ghostscript fontconfig webp
else
    $PKG_MANAGER check-update -y || true
    $PKG_MANAGER install -y epel-release -y || true # Required for Nginx on RHEL derivatives
    $PKG_MANAGER install -y curl wget tar unzip wget -y
fi

# --- DATABASE INSTALLATION (MARIADB) ---
log_info "Verifying and installing MariaDB Server..."
if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get install -y mariadb-server mariadb-client
    systemctl enable --now mariadb
else
    $PKG_MANAGER install -y mariadb-server mariadb
    systemctl enable --now mariadb
fi

# Automatic Database & User Creation
log_info "Configuring database..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"

# --- PHP AND EXTENSIONS INSTALLATION ---
log_info "Installing PHP and required WordPress extensions..."
if [[ "$PKG_MANAGER" == "apt" ]]; then
    # Installs the default PHP version for the specific Debian/Ubuntu release
    apt-get install -y php php-fpm php-curl php-gd php-intl php-mbstring php-xml php-zip php-mysql php-imagick php-bcmath
    # Find the active php-fpm service name (e.g., php7.4-fpm, php8.1-fpm, or php8.3-fpm)
    PHP_FPM_SERVICE=$(ls /lib/systemd/system/php*-fpm.service | head -n 1 | xargs basename)
else
    # RHEL-based systems often require the AppStream module for PHP
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf module enable php:8.1 -y || true # Force a modern stable version if available
    fi
    $PKG_MANAGER install -y php php-fpm php-cli php-mysqlnd php-gd php-intl php-mbstring php-xml php-zip php-json php-bcmath php-opcache
    PHP_FPM_SERVICE="php-fpm"
fi

systemctl enable --now "$PHP_FPM_SERVICE"

# --- WEBSERVER INSTALLATION ---
if [[ "$WEBSERVER_CHOICE" == "nginx" ]]; then
    log_info "Installing and configuring Nginx..."
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get install -y nginx
    else
        $PKG_MANAGER install -y nginx
    fi
    
    # Stop Apache if it is running and blocking port 80
    if systemctl is-active --quiet "$APACHE_SERVICE"; then
        log_warn "Apache is active and may conflict with Nginx. Disabling Apache..."
        systemctl disable --now "$APACHE_SERVICE"
    fi
    
    systemctl enable --now nginx

elif [[ "$WEBSERVER_CHOICE" == "apache" ]]; then
    log_info "Installing and configuring Apache..."
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt-get install -y "$APACHE_PACKAGE"
        # Enable required modules for Apache (Debian/Ubuntu specific)
        a2enmod rewrite expires headers proxy_fcgi setenvif
    else
        $PKG_MANAGER install -y "$APACHE_PACKAGE"
    fi

    # Stop Nginx if it is running and blocking port 80
    if systemctl is-active --quiet nginx; then
        log_warn "Nginx is active and may conflict with Apache. Disabling Nginx..."
        systemctl disable --now nginx
    fi
    
    systemctl enable --now "$APACHE_SERVICE"
fi

# --- DOWNLOAD AND INSTALL WORDPRESS ---
log_info "Downloading WordPress from the official source..."
mkdir -p /var/www
if [ -d "$TARGET_DIR" ]; then
    log_warn "Target directory $TARGET_DIR already exists. Files will be overwritten."
fi

# Download the latest tarball
wget -qO /tmp/wordpress.tar.gz https://wordpress.org/latest.tar.gz
tar -xzf /tmp/wordpress.tar.gz -C /tmp/
mkdir -p "$TARGET_DIR"
cp -r /tmp/wordpress/* "$TARGET_DIR/"
rm -rf /tmp/wordpress /tmp/wordpress.tar.gz

# --- WP-CONFIG.PHP CONFIGURATION ---
log_info "Generating wp-config.php..."
WP_CONFIG="$TARGET_DIR/wp-config.php"
cp "$TARGET_DIR/wp-config-sample.php" "$WP_CONFIG"

# Inject database credentials via sed (compatible with both GNU and BSD sed)
sed -i "s/database_name_here/$DB_NAME/g" "$WP_CONFIG"
sed -i "s/username_here/$DB_USER/g" "$WP_CONFIG"
sed -i "s/password_here/$DB_PASSWORD/g" "$WP_CONFIG"

# Fetch secure Salts via the official WordPress API
log_info "Fetching unique security salts..."
SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
# Remove the old placeholder salts and append the new ones
sed -i '/AUTH_KEY/,/NONCE_SALT/d' "$WP_CONFIG"
echo "$SALTS" >> "$WP_CONFIG"

# Force FS_METHOD direct to prevent FTP prompt issues during updates
echo "define('FS_METHOD', 'direct');" >> "$WP_CONFIG"

# --- WEBSERVER CONFIGURATION FILES ---

if [[ "$WEBSERVER_CHOICE" == "nginx" ]]; then
    log_info "Creating Nginx Server Block..."
    
    # Locate the PHP-FPM socket path to ensure extreme compatibility
    if [ -S /run/php/php-fpm.sock ]; then
        PHP_SOCK="unix:/run/php/php-fpm.sock"
    elif [ -S "/run/php/$(ls /run/php/ | grep fpm.sock | head -n 1)" ]; then
        PHP_SOCK="unix:/run/php/$(ls /run/php/ | grep fpm.sock | head -n 1)"
    elif [ -S /run/php-fpm/www.sock ]; then
        PHP_SOCK="unix:/run/php-fpm/www.sock"
    else
        # Fallback to network socket if no unix socket is found
        PHP_SOCK="127.0.0.1:9000"
    fi

    NGINX_CONF=""
    if [ -d /etc/nginx/sites-available ]; then
        NGINX_CONF="/etc/nginx/sites-available/wordpress.conf"
        NGINX_LINK="/etc/nginx/sites-enabled/wordpress.conf"
    else
        NGINX_CONF="/etc/nginx/conf.d/wordpress.conf"
        NGINX_LINK=""
    fi

    cat <<EOF > "$NGINX_CONF"
server {
    listen 80;
    server_name $SERVER_NAME;
    root $TARGET_DIR;
    index index.php index.html index.htm;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_intercept_errors on;
        fastcgi_pass $PHP_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires max;
        log_not_found off;
    }
}
EOF

    if [ -n "$NGINX_LINK" ] && [ ! -L "$NGINX_LINK" ]; then
        ln -s "$NGINX_CONF" "$NGINX_LINK"
        # Remove default config to prevent port conflicts on Debian/Ubuntu
        rm -f /etc/nginx/sites-enabled/default || true
    fi
    
    systemctl restart nginx

elif [[ "$WEBSERVER_CHOICE" == "apache" ]]; then
    log_info "Creating Apache VirtualHost..."
    
    if [ -d /etc/apache2/sites-available ]; then
        APACHE_CONF="/etc/apache2/sites-available/wordpress.conf"
        APACHE_LINK="/etc/apache2/sites-enabled/wordpress.conf"
    else
        APACHE_CONF="/etc/apache/conf.d/wordpress.conf"
        if [ ! -d /etc/apache/conf.d ]; then
            APACHE_CONF="/etc/httpd/conf.d/wordpress.conf"
        fi
        APACHE_LINK=""
    fi

    cat <<EOF > "$APACHE_CONF"
<VirtualHost *:80>
    ServerName $SERVER_NAME
    DocumentRoot $TARGET_DIR
    
    <Directory $TARGET_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/wordpress_error.log
    CustomLog \${APACHE_LOG_DIR}/wordpress_access.log combined
</VirtualHost>
EOF

    # Fix for RHEL systems where Apache log environment variables are defined differently
    if [[ "$PKG_MANAGER" != "apt" ]]; then
        sed -i 's/\${APACHE_LOG_DIR}/logs/g' "$APACHE_CONF"
    fi

    if [ -n "$APACHE_LINK" ] && [ ! -L "$APACHE_LINK" ]; then
        ln -s "$APACHE_CONF" "$APACHE_LINK"
        rm -f /etc/apache2/sites-enabled/000-default.conf || true
    fi
    
    # Generate .htaccess for better permalinks compatibility
    cat <<EOF > "$TARGET_DIR/.htaccess"
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF

    systemctl restart "$APACHE_SERVICE"
fi

# --- FIX PERMISSIONS AND OWNERSHIP ---
log_info "Configuring file permissions and ownership for user: $WEB_USER..."
chown -R "$WEB_USER":"$WEB_GROUP" "$TARGET_DIR"
find "$TARGET_DIR" -type d -exec chmod 755 {} \;
find "$TARGET_DIR" -type f -exec chmod 644 {} \;

# Ensure PHP-FPM shares correct user/group configuration on RHEL systems
if [[ "$PKG_MANAGER" != "apt" ]] && [ -f /etc/php-fpm.d/www.conf ]; then
    sed -i "s/user = apache/user = $WEB_USER/g" /etc/php-fpm.d/www.conf
    sed -i "s/group = apache/group = $WEB_GROUP/g" /etc/php-fpm.d/www.conf
    systemctl restart "$PHP_FPM_SERVICE"
fi

# --- SELINUX COMPATIBILITY ---
if command -v getenforce &>/dev/null; then
    if [ "$(getenforce)" = "Enforcing" ]; then
        log_warn "SELinux is set to Enforcing. Adjusting contexts for $TARGET_DIR..."
        semanage fcontext -a -t httpd_sys_content_t "$TARGET_DIR(/.*)?" 2>/dev/null || true
        semanage fcontext -a -t httpd_sys_rw_content_t "$TARGET_DIR/wp-content(/.*)?" 2>/dev/null || true
        restorecon -R -v "$TARGET_DIR" || true
        # Allow network connections (e.g., for plugins/updates verification)
        setsebool -P httpd_can_network_connect 1 || true
    fi
fi

# --- FIREWALL CONFIGURATION ---
log_info "Checking firewall settings..."
if command -v ufw &>/dev/null && systemctl is-active --quiet ufw; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
fi

# --- FINAL STATUS ---
echo "========================================================================="
log_info "WordPress has been successfully installed and configured!"
echo -e "Location:               ${YELLOW}$TARGET_DIR${NC}"
echo -e "Selected Webserver:     ${YELLOW}$WEBSERVER_CHOICE${NC}"
echo -e "Access via:             ${GREEN}http://$SERVER_NAME/${NC}"
echo "========================================================================="
log_info "Complete the installation via your browser interface."
