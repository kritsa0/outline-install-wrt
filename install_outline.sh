#!/bin/sh
# Fixed Outline scripted, xjasonlyu/tun2socks based installer for OpenWRT.
# https://github.com/1andrevich/outline-install-wrt
echo 'Starting Outline OpenWRT install script'

# Step 1: Check for kmod-tun
opkg list-installed | grep kmod-tun > /dev/null
if [ $? -ne 0 ]; then
    echo "kmod-tun is not installed. Installing..."
    opkg update
    opkg install kmod-tun
    if [ $? -ne 0 ]; then
        echo "Failed to install kmod-tun. Exiting."
        exit 1
    fi
fi
echo 'kmod-tun installed'

# Load tun module if not loaded
if ! lsmod | grep -q tun; then
    modprobe tun
    if [ $? -ne 0 ]; then
        echo "Failed to load tun module. Exiting."
        exit 1
    fi
fi
echo 'tun module loaded'

# Step 2: Check for ip-full
opkg list-installed | grep ip-full > /dev/null
if [ $? -ne 0 ]; then
    echo "ip-full is not installed. Installing..."
    opkg update
    opkg install ip-full
    if [ $? -ne 0 ]; then
        echo "Failed to install ip-full. Exiting."
        exit 1
    fi
fi
echo 'ip-full installed'

# Step 3: Download tun2socks binary from GitHub
if [ ! -f "/usr/bin/tun2socks" ]; then
    if [ ! -f "/tmp/tun2socks" ]; then
        ARCH=$(grep "OPENWRT_ARCH" /etc/os-release | awk -F '"' '{print $2}')
        echo "Downloading tun2socks for architecture: $ARCH"
        wget https://github.com/1andrevich/outline-install-wrt/releases/latest/download/tun2socks-linux-$ARCH -O /tmp/tun2socks
        # Check wget's exit status
        if [ $? -ne 0 ]; then
            echo "Download failed. No file for your Router's architecture"
            exit 1
        fi
    fi
    
    # Step 4: Move binary to /usr/bin
    mv /tmp/tun2socks /usr/bin/
    echo 'moving tun2socks to /usr/bin'
    chmod +x /usr/bin/tun2socks
fi

# Step 5: Check for existing config in /etc/config/network then add entry
if ! grep -q "config interface 'tunnel'" /etc/config/network; then
    echo "
config interface 'tunnel'
    option device 'tun1'
    option proto 'static'
    option ipaddr '172.16.10.1'
    option netmask '255.255.255.252'
    option ip6addr 'fced:9999::1/64'
" >> /etc/config/network
    echo 'added dual-stack entry into /etc/config/network'
else
    echo 'found entry into /etc/config/network'
fi

# Step 6: Check for existing config /etc/config/firewall then add entry
if ! grep -q "option name 'proxy'" /etc/config/firewall; then 
    echo "
config zone
    option name 'proxy'
    list network 'tunnel'
    option forward 'REJECT'
    option output 'ACCEPT'
    option input 'REJECT'
    option masq '1'
    option mtu_fix '1'
    option device 'tun1'

config forwarding
    option name 'lan-proxy'
    option dest 'proxy'
    option src 'lan'
" >> /etc/config/firewall
    echo 'added dual-stack entry into /etc/config/firewall'
else
    echo 'found entry into /etc/config/firewall'
fi

# Step 7: Restart network
/etc/init.d/network restart
echo 'Restarting Network....'
sleep 3

# Step 8: Read user variable for OUTLINE HOST
read -p "Enter Outline Server Hostname/IP: " OUTLINEHOST
# Read user variable for Outline config
read -p "Enter Outline (Shadowsocks) Config (format ss://base64coded@HOST:PORT/?outline=1): " OUTLINECONF

# Resolve hostname to both IPv4 and IPv6
echo "Resolving hostname: $OUTLINEHOST"
OUTLINEIP4=$(nslookup "$OUTLINEHOST" | grep -A1 "Name:" | grep "Address:" | head -1 | awk '{print $2}' 2>/dev/null || echo "")
OUTLINEIP6=$(nslookup "$OUTLINEHOST" | grep -A10 "Name:" | grep "Address:" | grep ":" | head -1 | awk '{print $2}' 2>/dev/null || echo "")

if [ -z "$OUTLINEIP4" ] && [ -z "$OUTLINEIP6" ]; then
    # If nslookup fails, try direct IP detection
    if echo "$OUTLINEHOST" | grep -q ":"; then
        OUTLINEIP6="$OUTLINEHOST"
        echo "Detected IPv6 address: $OUTLINEIP6"
    elif echo "$OUTLINEHOST" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; then
        OUTLINEIP4="$OUTLINEHOST"
        echo "Detected IPv4 address: $OUTLINEIP4"
    else
        echo "Warning: Could not resolve hostname $OUTLINEHOST"
        OUTLINEIP4="$OUTLINEHOST"
    fi
else
    [ -n "$OUTLINEIP4" ] && echo "Resolved IPv4: $OUTLINEIP4"
    [ -n "$OUTLINEIP6" ] && echo "Resolved IPv6: $OUTLINEIP6"
fi

# Step 9: Check for default gateway and save it into DEFGW
DEFGW=$(ip route | grep default | awk '{print $3}')
echo "Default gateway: $DEFGW"

# Step 10: Check for default interface and save it into DEFIF
DEFIF=$(ip route | grep default | awk '{print $5}')
echo "Default interface: $DEFIF"

# Step 11: Create script /etc/init.d/tun2socks
if [ -f "/etc/init.d/tun2socks" ]; then
    echo "Removing existing tun2socks service..."
    /etc/init.d/tun2socks stop 2>/dev/null
    rm -f /etc/init.d/tun2socks
    rm -f /etc/rc.d/S99tun2socks
fi

cat <<EOL > /etc/init.d/tun2socks
#!/bin/sh /etc/rc.common
USE_PROCD=1

# starts after network starts
START=99
# stops before networking stops
STOP=89

start_service() {
    # Create tun1 interface if it doesn't exist
    if ! ip link show tun1 >/dev/null 2>&1; then
        echo "Creating tun1 interface..."
        ip tuntap add dev tun1 mode tun
        if [ \$? -ne 0 ]; then
            echo "Failed to create tun1 interface"
            return 1
        fi
        ip link set tun1 up
        ip addr add 172.16.10.1/30 dev tun1
        ip -6 addr add fced:9999::1/64 dev tun1 2>/dev/null
    fi
    
    # Verify interface is up
    if ! ip link show tun1 | grep -q "UP"; then
        echo "tun1 interface is not up, bringing it up..."
        ip link set tun1 up
        ip addr add 172.16.10.1/30 dev tun1 2>/dev/null
        ip -6 addr add fced:9999::1/64 dev tun1 2>/dev/null
    fi
    
    procd_open_instance
    procd_set_param user root
    procd_set_param command /usr/bin/tun2socks -device tun1 -tcp-rcvbuf 64kb -tcp-sndbuf 64kb -proxy "$OUTLINECONF" -loglevel "warn"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn "\${respawn_threshold:-3600}" "\${respawn_timeout:-5}" "\${respawn_retry:-5}"
    procd_close_instance
    
    # Add routes to Outline Server (IPv4 and IPv6)
    if [ -n "$OUTLINEIP4" ] && ! ip route | grep -q "$OUTLINEIP4 via $DEFGW"; then
        ip route add "$OUTLINEIP4" via "$DEFGW" dev "$DEFIF"
        echo "IPv4 route to Outline Server added: $OUTLINEIP4"
    fi
    
    if [ -n "$OUTLINEIP6" ]; then
        DEFGW6=\$(ip -6 route | grep default | awk '{print \$3}' | head -1)
        DEFIF6=\$(ip -6 route | grep default | awk '{print \$5}' | head -1)
        if [ -n "$DEFGW6" ] && ! ip -6 route | grep -q "$OUTLINEIP6 via $DEFGW6"; then
            ip -6 route add "$OUTLINEIP6" via "$DEFGW6" dev "$DEFIF6" 2>/dev/null
            echo "IPv6 route to Outline Server added: $OUTLINEIP6"
        fi
    fi
    
    # Save existing default route
    ip route save default > /tmp/defroute.save
    echo "tun2socks is working!"
}

boot() {
    # This gets run at boot-time.
    start
}

shutdown() {
    # This gets run at shutdown/reboot.
    stop
}

stop_service() {
    service_stop /usr/bin/tun2socks
    
    # Restore saved default route if it exists
    if [ -f /tmp/defroute.save ]; then
        ip route restore default < /tmp/defroute.save
    fi
    
    # Remove routes to OUTLINE Server (IPv4 and IPv6)
    if [ -n "$OUTLINEIP4" ] && ip route | grep -q "$OUTLINEIP4 via $DEFGW"; then
        ip route del "$OUTLINEIP4" via "$DEFGW" 2>/dev/null
        echo "IPv4 route to Outline Server removed"
    fi
    
    if [ -n "$OUTLINEIP6" ]; then
        DEFGW6=\$(ip -6 route | grep default | awk '{print \$3}' | head -1)
        if [ -n "$DEFGW6" ] && ip -6 route | grep -q "$OUTLINEIP6 via $DEFGW6"; then
            ip -6 route del "$OUTLINEIP6" via "$DEFGW6" 2>/dev/null
            echo "IPv6 route to Outline Server removed"
        fi
    fi
    
    # Remove tun1 interface
    if ip link show tun1 >/dev/null 2>&1; then
        ip link set tun1 down
        ip tuntap del dev tun1 mode tun
    fi
    
    echo "tun2socks has stopped!"
}

reload_service() {
    stop
    sleep 3s
    echo "tun2socks restarted!"
    start
}
EOL

# Ask user to use Outline as default gateway
DEFAULT_GATEWAY=""
while [ "$DEFAULT_GATEWAY" != "y" ] && [ "$DEFAULT_GATEWAY" != "n" ]; do
    echo "Use Outline as default gateway? [y/n]: "
    read DEFAULT_GATEWAY
done

if [ "$DEFAULT_GATEWAY" = "y" ]; then
    cat <<EOL >> /etc/init.d/tun2socks

# Replaces default route for Outline
service_started() {
    # This function checks if the default gateway is Outline, if no changes it
    echo 'Replacing default gateway for Outline...'
    sleep 3s
    if ip link show tun1 | grep -q "UP"; then
        # Delete existing default route
        ip route del default 2>/dev/null
        # Create default routes through the proxy (IPv4 and IPv6)
        ip route add default via 172.16.10.2 dev tun1
        ip -6 route add default via fced:9999::2 dev tun1 2>/dev/null
        echo "Default routes set through Outline (IPv4 and IPv6)"
    else
        echo "tun1 interface is not up, cannot set default route"
    fi
}

start() {
    start_service
    service_started
}
EOL

    # Check rc.local and adds script to rc.local to check default route on startup
    if ! grep -q "sleep 10" /etc/rc.local; then
        # Backup original rc.local
        cp /etc/rc.local /etc/rc.local.backup
        
        sed '/exit 0/i\
sleep 10\
# Check if default routes are through Outline and change if not\
if ! ip route | grep -q '\''^default via 172.16.10.2 dev tun1'\''; then\
    /etc/init.d/tun2socks start\
fi\
if ! ip -6 route | grep -q '\''^default via fced:9999::2 dev tun1'\''; then\
    ip -6 route add default via fced:9999::2 dev tun1 2>/dev/null\
fi\
' /etc/rc.local > /tmp/rc.local.tmp && mv /tmp/rc.local.tmp /etc/rc.local
        echo "All traffic will be routed through Outline"
    fi
else
    cat <<EOL >> /etc/init.d/tun2socks

start() {
    start_service
}
EOL
    echo "No changes to default gateway"
fi

echo 'script /etc/init.d/tun2socks created'
chmod +x /etc/init.d/tun2socks

# Step 12: Create symbolic link
if [ ! -f "/etc/rc.d/S99tun2socks" ]; then
    ln -s /etc/init.d/tun2socks /etc/rc.d/S99tun2socks
    echo '/etc/init.d/tun2socks /etc/rc.d/S99tun2socks symlink created'
fi

# Step 13: Start service
echo "Starting tun2socks service..."
/etc/init.d/tun2socks start

# Verify everything is working
sleep 5
echo ""
echo "=== Verification ==="
if ip link show tun1 >/dev/null 2>&1; then
    echo "✓ tun1 interface created successfully"
    ip link show tun1 | head -1
else
    echo "✗ tun1 interface creation failed"
fi

if ps | grep -q "[t]un2socks"; then
    echo "✓ tun2socks process is running"
else
    echo "✗ tun2socks process is not running"
fi

if [ -n "$OUTLINEIP4" ] && ip route | grep -q "$OUTLINEIP4"; then
    echo "✓ IPv4 route to Outline server added"
elif [ -n "$OUTLINEIP6" ] && ip -6 route | grep -q "$OUTLINEIP6"; then
    echo "✓ IPv6 route to Outline server added"
else
    echo "✗ Route to Outline server not found"
fi

echo ""
echo "Current routes:"
ip route show
echo ""

if [ "$DEFAULT_GATEWAY" = "y" ]; then
    IPV4_DEFAULT=$(ip route | grep -q "^default via 172.16.10.2 dev tun1" && echo "yes" || echo "no")
    IPV6_DEFAULT=$(ip -6 route | grep -q "^default via fced:9999::2 dev tun1" && echo "yes" || echo "no")
    
    if [ "$IPV4_DEFAULT" = "yes" ] || [ "$IPV6_DEFAULT" = "yes" ]; then
        echo "✓ Default route(s) set through Outline"
        [ "$IPV4_DEFAULT" = "yes" ] && echo "  - IPv4 default route active"
        [ "$IPV6_DEFAULT" = "yes" ] && echo "  - IPv6 default route active"
    else
        echo "⚠ Default routes not set through Outline (this may take a moment)"
    fi
fi

echo ""
echo "To check status: /etc/init.d/tun2socks status"
echo "To stop service: /etc/init.d/tun2socks stop"
echo "To restart service: /etc/init.d/tun2socks restart"
echo "To view logs: logread | grep tun2socks"
echo ""
echo 'Script finished successfully!'