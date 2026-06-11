# Automatic WordPress Deployment Script (Extreme Compatibility Edition)

An automated, cross-distribution Bash script designed to provision a complete WordPress environment on Linux servers. It handles the dynamic installation and configuration of the web server, PHP, MariaDB, and WordPress core files with zero manual file editing required.

## 🚀 Features

* **Multi-OS Support:** Native compatibility with Debian, Ubuntu, RHEL, Rocky Linux, and AlmaLinux.
* **Web Server Choice:** Seamless deployment using either **Nginx** or **Apache (HTTPD)**.
* **Smart PHP Detection:** Automatically detects and provisions the optimal `php-fpm` version and standard extensions (`curl`, `gd`, `intl`, `mbstring`, `xml`, `zip`, `mysql`, etc.) for your specific distribution.
* **Automated Database Setup:** Configures a secure MariaDB database, dedicated user, and strong privileges out-of-the-box.
* **Security Built-in:** Fetches unique, real-time security salts from the official WordPress API (`api.wordpress.org`) and injects them directly into `wp-config.php`.
* **Environment Aware:** * Automatically manages `SELinux` contexts on RHEL-based systems.
    * Configures firewall rules (`UFW` or `firewalld`) based on what is active on the host.
    * Prevents conflicts by disabling competing web servers if one is already running on port 80.

---

## 📋 Requirements

* A clean installation of a supported Linux OS (Debian, Ubuntu, RHEL, Rocky, or AlmaLinux).
* **Root (sudo)** access to the target machine.
* An active internet connection (to download packages, WordPress, and security salts).

---

## 🛠️ Usage

### 1. Clone or Download the Script
Get the script onto your server. You can clone your repository or create the file manually:
```bash
wget https://raw.githubusercontent.com/stefwxters/automatic-wordpress-deployer/refs/heads/main/deploy-wordpress.sh
