#!/bin/bash

# fail2ban installation and configuration script for Debian 12

# Function to display section headers
print_section() {
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or log in as root."
    exit 1
fi

print_section "FAIL2BAN INSTALLATION AND CONFIGURATION"
echo "This script will install and configure fail2ban on Debian 12."
echo "You will be prompted to configure various security settings."
echo

# Update package lists
print_section "UPDATING SYSTEM"
echo "Updating package lists..."
apt update

# Check and install firewall
print_section "CHECKING FIREWALL STATUS"
echo "Checking if a firewall is installed and active..."
FIREWALL_INSTALLED=false

if command -v ufw &> /dev/null; then
    echo "UFW detected."
    FIREWALL_INSTALLED=true
    if ! ufw status | grep -q "Status: active"; then
        echo "UFW is installed but not active. Enabling UFW..."
        ufw allow ssh
        ufw --force enable
    fi
elif command -v firewalld &> /dev/null; then
    echo "FirewallD detected."
    FIREWALL_INSTALLED=true
    if ! systemctl is-active --quiet firewalld; then
        echo "FirewallD is installed but not active. Enabling FirewallD..."
        systemctl enable --now firewalld
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --reload
    fi
else
    echo "No firewall detected. A firewall is required for fail2ban to block connections effectively."
    read -p "Install UFW (Uncomplicated Firewall)? (y/n): " install_firewall
    if [[ "$install_firewall" =~ ^[Yy]$ ]]; then
        echo "Installing UFW..."
        apt install -y ufw
        echo "Configuring UFW to allow SSH..."
        ufw allow ssh
        echo "Enabling UFW..."
        ufw --force enable
        FIREWALL_INSTALLED=true
    else
        echo "WARNING: Without a firewall, fail2ban cannot block connections!"
        echo "fail2ban will create iptables rules, but they may not be effective."
        read -p "Continue anyway? (y/n): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            echo "Installation aborted."
            exit 1
        fi
    fi
fi

# Install fail2ban
print_section "INSTALLING FAIL2BAN"
echo "Installing fail2ban..."
apt install -y fail2ban

# Create a backup of the original configuration
echo "Creating backup of original configuration..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.conf.backup
if [ -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup
fi

# Create local configuration file
echo "Creating local configuration file..."
echo > /etc/fail2ban/jail.local

# Configure trusted IPs
print_section "CONFIGURING TRUSTED IPs"
read -p "Do you want to specify trusted IPs that fail2ban should ignore? (y/n): " configure_trusted
if [[ "$configure_trusted" =~ ^[Yy]$ ]]; then
    read -p "Enter trusted IPs separated by spaces (e.g. 127.0.0.1/8 192.168.1.0/24): " trusted_ips
    ignoreip="ignoreip = 127.0.0.1/8"
    if [ ! -z "$trusted_ips" ]; then
        ignoreip="ignoreip = 127.0.0.1/8 $trusted_ips"
    fi
else
    ignoreip="ignoreip = 127.0.0.1/8"
fi

# Basic configuration with default values
print_section "BASIC CONFIGURATION"
cat > /etc/fail2ban/jail.local << EOL
[DEFAULT]
$ignoreip
bantime = 10m
findtime = 10m
maxretry = 5
# Select appropriate action based on firewall detection
banaction = $(if $FIREWALL_INSTALLED; then echo "iptables-multiport"; else echo "iptables-multiport"; fi)
# Using systemd backend explicitly for Debian 12
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
# Use both potential log paths to ensure coverage
logpath = /var/log/auth.log
         /var/log/secure
# No maxretry here - will use the default value
findtime = 5m
EOL

# Ask for enhanced security
print_section "ENHANCED SECURITY SETTINGS"
read -p "Do you want to configure enhanced security settings? (y/n): " enhance_security
if [[ "$enhance_security" =~ ^[Yy]$ ]]; then
    # Increase ban time
    read -p "Enter ban time (default: 1h, recommended for security: 24h): " ban_time
    ban_time=${ban_time:-1h}
    
    # Reduce retry attempts
    read -p "Enter maximum retry attempts (default: 5, recommended for security: 3): " max_retry
    max_retry=${max_retry:-3}
    
    # Set find time
    read -p "Enter find time (default: 10m, recommended for security: 30m): " find_time
    find_time=${find_time:-10m}
    
    # Use more aggressive banning action
    read -p "Use more aggressive ban action? This will ban all ports, not just the one being attacked. (y/n): " aggressive_ban
    ban_action="iptables-multiport"
    if [[ "$aggressive_ban" =~ ^[Yy]$ ]]; then
        ban_action="iptables-allports"
    fi
    
    # Configure email notifications
    read -p "Do you want to enable email notifications? (y/n): " email_notify
    if [[ "$email_notify" =~ ^[Yy]$ ]]; then
        read -p "Enter destination email address: " dest_email
        read -p "Enter sender email address: " sender_email
        
        # Add email configuration
        cat >> /etc/fail2ban/jail.local << EOL
destemail = $dest_email
sender = $sender_email
mta = sendmail
action = %(action_mwl)s
EOL
    fi
    
    # Update configuration with enhanced settings
    sed -i "s/bantime = .*/bantime = $ban_time/" /etc/fail2ban/jail.local
    sed -i "s/findtime = .*/findtime = $find_time/" /etc/fail2ban/jail.local
    sed -i "s/maxretry = 5/maxretry = $max_retry/" /etc/fail2ban/jail.local
    sed -i "s/banaction = .*/banaction = $ban_action/" /etc/fail2ban/jail.local
    
    # Always set SSH to stricter settings with max 1 retry
    echo "Setting SSH to stricter security (max 1 retry)..."
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/sshd-strict.conf << EOL
# SSH stricter settings - will override jail.local
[sshd]
maxretry = 1
findtime = 1m
EOL
    
    # Persistent bans option
    read -p "Enable persistent bans that survive restarts? (y/n): " persistent_bans
    if [[ "$persistent_bans" =~ ^[Yy]$ ]]; then
        apt install -y sqlite3
        sed -i '/backend = auto/a dbfile = /var/lib/fail2ban/fail2ban.sqlite3' /etc/fail2ban/jail.local
        sed -i 's/backend = auto/backend = systemd/' /etc/fail2ban/jail.local
    fi
fi

# Configure additional services to protect
print_section "ADDITIONAL SERVICES PROTECTION"
echo "Would you like to enable fail2ban protection for additional services?"

# Check if Apache is installed
if dpkg -l | grep -q apache2; then
    read -p "Apache detected. Enable protection for Apache? (y/n): " protect_apache
else
    read -p "Enable protection for Apache (if installed)? (y/n): " protect_apache
fi

if [[ "$protect_apache" =~ ^[Yy]$ ]]; then
    cat >> /etc/fail2ban/jail.local << EOL

[apache-auth]
enabled = true
port = http,https
filter = apache-auth
logpath = /var/log/apache2/error.log
maxretry = 3

[apache-badbots]
enabled = true
port = http,https
filter = apache-badbots
logpath = /var/log/apache2/access.log
maxretry = 2
EOL
fi

# Check if Nginx is installed
if dpkg -l | grep -q nginx; then
    read -p "Nginx detected. Enable protection for Nginx? (y/n): " protect_nginx
else
    read -p "Enable protection for Nginx (if installed)? (y/n): " protect_nginx
fi

if [[ "$protect_nginx" =~ ^[Yy]$ ]]; then
    cat >> /etc/fail2ban/jail.local << EOL

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3
EOL
fi

# Check if FTP servers are installed
if dpkg -l | grep -q vsftpd; then
    read -p "vsftpd detected. Enable protection for FTP? (y/n): " protect_ftp
else
    read -p "Enable protection for FTP (if installed)? (y/n): " protect_ftp
fi

if [[ "$protect_ftp" =~ ^[Yy]$ ]]; then
    cat >> /etc/fail2ban/jail.local << EOL

[vsftpd]
enabled = true
port = ftp,ftp-data,ftps,ftps-data
filter = vsftpd
logpath = /var/log/vsftpd.log
maxretry = 3
EOL
fi

# Configure custom blocklist
print_section "CUSTOM IP BLOCKLIST"
read -p "Do you want to configure a custom IP blocklist? (y/n): " custom_blocklist
if [[ "$custom_blocklist" =~ ^[Yy]$ ]]; then
    read -p "Enter comma-separated IP addresses to always ban: " blocklist_ips
    if [ ! -z "$blocklist_ips" ]; then
        # Convert comma-separated list to newline separated
        blocklist=$(echo $blocklist_ips | sed 's/,/\n/g')
        
        mkdir -p /etc/fail2ban/ip.blocklist.d
        echo "$blocklist" > /etc/fail2ban/ip.blocklist.d/custom.conf
        
        cat >> /etc/fail2ban/jail.local << EOL

[custom-blocklist]
enabled = true
filter = custom-blocklist
logpath = /var/log/auth.log
banaction = iptables-allports
bantime = -1
maxretry = 1
EOL

        # Create custom filter
        cat > /etc/fail2ban/filter.d/custom-blocklist.conf << EOL
[Definition]
failregex = .* from <HOST>
ignoreregex =
EOL
    fi
fi

# Enable and start fail2ban
print_section "ACTIVATING FAIL2BAN"
echo "Enabling and starting fail2ban service..."
systemctl enable fail2ban
systemctl restart fail2ban

# Add a verification step before completion
print_section "VERIFYING CONFIGURATION"
echo "Checking if fail2ban is properly configured and running..."
sleep 2

# Reload the service to ensure changes take effect
echo "Reloading fail2ban configuration..."
fail2ban-client reload
sleep 1

# Display the status of the sshd jail specifically
echo "Current SSH jail status:"
fail2ban-client status sshd

# Check if firewall is correctly receiving fail2ban rules
if $FIREWALL_INSTALLED; then
    echo "Checking firewall rules created by fail2ban..."
    if command -v ufw &> /dev/null; then
        echo "UFW rules:"
        ufw status verbose
    elif command -v firewall-cmd &> /dev/null; then
        echo "FirewallD rules:"
        firewall-cmd --list-all
    fi
    echo "Checking direct iptables rules:"
    iptables -L -n | grep -i fail2ban
fi

# Add troubleshooting information
print_section "TROUBLESHOOTING INFORMATION"
echo "If fail2ban is not working as expected, try these steps:"
echo "1. Check fail2ban logs: journalctl -u fail2ban"
echo "2. Verify SSH log paths: grep sshd /var/log/auth.log or /var/log/secure"
echo "3. Verify your IP is not in the ignoreip list"
echo "4. Ensure fail2ban is running: systemctl status fail2ban"
echo "5. Check active bans: fail2ban-client status sshd"
echo "6. Increase verbosity: fail2ban-client set loglevel DEBUG"
echo "7. Verify firewall is installed and active: ufw status or firewall-cmd --state"
echo "8. Check if iptables rules are created: iptables -L -n | grep fail2ban"
echo "9. For persistent rules, install a firewall manager: apt install -y ufw"
echo "10. To quickly set SSH to 1 retry: echo 'maxretry = 1' >> /etc/fail2ban/jail.d/sshd-strict.local && systemctl restart fail2ban"

print_section "INSTALLATION COMPLETE"
echo "fail2ban installation and configuration completed."
echo "You can check the status with: sudo systemctl status fail2ban"
echo "You can view all jails with: sudo fail2ban-client status"
echo "You can view a specific jail with: sudo fail2ban-client status <jail_name>"
echo "To manually ban an IP: sudo fail2ban-client set <jail_name> banip <ip>"
echo "To manually unban an IP: sudo fail2ban-client set <jail_name> unbanip <ip>"

exit 0
