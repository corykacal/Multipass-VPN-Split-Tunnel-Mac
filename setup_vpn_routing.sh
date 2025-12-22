#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Dynamic VPN Routing Setup for Multipass + AWS VPN Client
# ============================================================================
# This script dynamically detects network interfaces and VPN routes,
# then configures macOS packet filter (pf) to route traffic intelligently:
# - VPN traffic (172.16.x.x, 10.x.x.x) -> through AWS VPN tunnel
# - All other traffic -> through regular internet connection
# ============================================================================

echo "🔍 Detecting network configuration..."
echo ""

# ============================================================================
# 1. Find the Multipass bridge interface
# ============================================================================
echo "Looking for Multipass bridge interface..."
BRIDGE_IF=$(ifconfig | grep -E "^bridge[0-9]+" -A 20 | grep -B 20 "member: vmenet0" | grep -E "^bridge[0-9]+" | head -1 | cut -d: -f1)

if [[ -z "$BRIDGE_IF" ]]; then
    echo "❌ Error: Cannot find Multipass bridge interface"
    echo "   Expected a bridge* interface with vmenet0 member"
    echo ""
    echo "   Make sure:"
    echo "   1. Multipass is installed"
    echo "   2. At least one VM is running"
    echo "   3. The VM was created with bridge networking"
    echo ""
    echo "   Current bridges:"
    ifconfig | grep -E "^bridge[0-9]+" || echo "   (none found)"
    exit 1
fi

echo "✓ Multipass bridge: $BRIDGE_IF"

# ============================================================================
# 2. Find the WAN egress interface
# ============================================================================
echo "Looking for WAN interface..."
WAN_IF=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}')

if [[ -z "$WAN_IF" ]]; then
    # Fallback: find interface with default route
    WAN_IF=$(netstat -rn -f inet | grep "^default" | grep -v "utun\|bridge" | head -1 | awk '{print $NF}')
fi

if [[ -z "$WAN_IF" ]]; then
    echo "❌ Error: Cannot determine WAN interface"
    echo "   No default route found"
    exit 1
fi

echo "✓ WAN interface: $WAN_IF"

# ============================================================================
# 3. Find the AWS VPN tunnel interface
# ============================================================================
echo "Looking for AWS VPN Client tunnel interface..."
echo "(Checking for utun* interfaces with VPN routes)"
echo ""

VPN_IF=""
declare -a VPN_ROUTES

# Check each utun interface for VPN-like routes
for utun in $(ifconfig | grep -E "^utun[0-9]+" | cut -d: -f1); do
    # Look for routes to private networks (10.x, 172.16.x) but exclude host routes
    routes=$(netstat -rn -f inet | awk -v iface="$utun" '
        $NF ~ iface && $3 !~ /UH/ && ($1 ~ /^10[\.\/]/ || $1 ~ /^172\.16/) {print $1}
    ' | sort -u)
    
    if [[ -n "$routes" ]]; then
        echo "  Found VPN routes on $utun:"
        while IFS= read -r route; do
            echo "    - $route"
            VPN_ROUTES+=("$route")
        done <<< "$routes"
        VPN_IF="$utun"
        break
    fi
done

if [[ -z "$VPN_IF" ]]; then
    echo ""
    echo "❌ Error: Cannot find AWS VPN tunnel interface"
    echo "   AWS VPN Client must be connected before running this script"
    echo ""
    echo "   Please:"
    echo "   1. Open AWS VPN Client"
    echo "   2. Connect to your VPN"
    echo "   3. Run this script again"
    echo ""
    echo "   Available utun interfaces:"
    ifconfig | grep -E "^utun[0-9]+" | cut -d: -f1 | while read -r iface; do
        echo "     - $iface (no VPN routes found)"
    done
    exit 1
fi

echo ""
echo "✓ AWS VPN interface: $VPN_IF"
echo "✓ VPN routes found: ${#VPN_ROUTES[@]}"

# ============================================================================
# 4. Validate we have necessary routes
# ============================================================================
if [[ ${#VPN_ROUTES[@]} -eq 0 ]]; then
    echo "❌ Error: No VPN routes found on $VPN_IF"
    echo "   VPN may not be properly connected or configured for split tunneling"
    exit 1
fi

# ============================================================================
# 5. Normalize VPN routes to CIDR notation
# ============================================================================
declare -a NORMALIZED_ROUTES
for route in "${VPN_ROUTES[@]}"; do
    # Convert shorthand routes to full CIDR
    if [[ "$route" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]]; then
        # Already in full CIDR format
        NORMALIZED_ROUTES+=("$route")
    elif [[ "$route" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]]; then
        # Missing last octet: e.g., "10.110.1/27"
        NORMALIZED_ROUTES+=("${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.0/${BASH_REMATCH[4]}")
    elif [[ "$route" =~ ^([0-9]+)\.([0-9]+)/([0-9]+)$ ]]; then
        # Missing two octets: e.g., "10.9/16"
        NORMALIZED_ROUTES+=("${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.0.0/${BASH_REMATCH[3]}")
    elif [[ "$route" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        # Missing three octets: e.g., "10/8"
        NORMALIZED_ROUTES+=("${BASH_REMATCH[1]}.0.0.0/${BASH_REMATCH[2]}")
    elif [[ "$route" == "172.16" ]]; then
        # 172.16 without mask -> /12 (covers 172.16-31.x.x)
        NORMALIZED_ROUTES+=("172.16.0.0/12")
    elif [[ "$route" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        # Single IP, make it /32
        NORMALIZED_ROUTES+=("$route/32")
    elif [[ "$route" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        # Three octets without mask: e.g., "10.110.1" -> /24
        NORMALIZED_ROUTES+=("$route.0/24")
    elif [[ "$route" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        # Two octets without mask: e.g., "10.9" -> /16
        NORMALIZED_ROUTES+=("$route.0.0/16")
    else
        # Keep as-is and hope for the best
        NORMALIZED_ROUTES+=("$route")
    fi
done

# Remove duplicates
NORMALIZED_ROUTES=($(printf '%s\n' "${NORMALIZED_ROUTES[@]}" | sort -u))

echo ""
echo "📝 Generating pf anchor configuration..."
echo "  Normalized routes:"
for route in "${NORMALIZED_ROUTES[@]}"; do
    echo "    - $route"
done

# ============================================================================
# 6. Generate pf anchor configuration
# ============================================================================
ANCHOR_FILE="/etc/pf.anchors/multipass_vpn"
ANCHOR_TMP="/tmp/multipass_vpn.tmp"

cat > "$ANCHOR_TMP" <<EOF
# /etc/pf.anchors/multipass_vpn
# Generated dynamically by setup_vpn_routing.sh on $(date)

# Interfaces (auto-detected)
bridge_if = "$BRIDGE_IF"    # Multipass bridge
vpn_if    = "$VPN_IF"       # AWS VPN tunnel
wan_if    = "$WAN_IF"       # Internet egress

# Split-tunnel prefixes (auto-detected from VPN routes)
EOF

# Add each VPN route as a variable
idx=1
for route in "${NORMALIZED_ROUTES[@]}"; do
    echo "vpn_net$idx  = \"$route\"" >> "$ANCHOR_TMP"
    idx=$((idx + 1))
done

cat >> "$ANCHOR_TMP" <<'EOF'

##### TRANSLATION (NAT) – must come before filtering #####
# Traffic to VPN networks -> go out the VPN interface with NAT
EOF

# Generate NAT rules for each VPN route
idx=1
for route in "${NORMALIZED_ROUTES[@]}"; do
    echo "nat on \$vpn_if from \$bridge_if:network to \$vpn_net$idx -> (\$vpn_if)" >> "$ANCHOR_TMP"
    idx=$((idx + 1))
done

cat >> "$ANCHOR_TMP" <<'EOF'

# Everything else (public internet) -> go out WAN interface with NAT
nat on $wan_if from $bridge_if:network to any -> ($wan_if)

##### FILTERING (pass/block) – after NAT #####
# Allow bidirectional traffic on the bridge (Mac <-> VM)
pass in  on $bridge_if inet keep state
pass out on $bridge_if inet keep state

# Allow egress to VPN networks
EOF

# Generate pass rules for each VPN route
idx=1
for route in "${NORMALIZED_ROUTES[@]}"; do
    echo "pass out on \$vpn_if inet from \$bridge_if:network to \$vpn_net$idx keep state" >> "$ANCHOR_TMP"
    idx=$((idx + 1))
done

cat >> "$ANCHOR_TMP" <<'EOF'

# Allow egress to public internet
pass out on $wan_if inet from $bridge_if:network to any keep state
EOF

# ============================================================================
# 7. Install the configuration
# ============================================================================
echo ""
echo "📦 Installing pf anchor configuration..."
echo "   (requires sudo password)"

sudo cp "$ANCHOR_TMP" "$ANCHOR_FILE"
sudo chmod 644 "$ANCHOR_FILE"
rm "$ANCHOR_TMP"

echo "✓ Anchor file created: $ANCHOR_FILE"

# ============================================================================
# 8. Update main pf.conf if needed
# ============================================================================
echo ""
echo "📝 Checking main pf configuration..."

# Check if our anchor is already configured
if ! sudo grep -q 'nat-anchor "multipass_vpn"' /etc/pf.conf || ! sudo grep -q 'anchor "multipass_vpn"' /etc/pf.conf; then
    echo "   Adding multipass_vpn anchor to /etc/pf.conf..."
    
    # Backup original if not already backed up
    if [[ ! -f /etc/pf.conf.backup ]]; then
        sudo cp /etc/pf.conf /etc/pf.conf.backup
        echo "   ✓ Backed up original pf.conf"
    fi
    
    # Create new pf.conf with proper anchor order
    sudo bash -c 'cat > /etc/pf.conf.new << "PFEOF"
#
# Default PF configuration file.
#
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
nat-anchor "multipass_vpn"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
anchor "multipass_vpn"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
load anchor "multipass_vpn" from "/etc/pf.anchors/multipass_vpn"
PFEOF
    '
    
    sudo mv /etc/pf.conf.new /etc/pf.conf
    echo "   ✓ Updated /etc/pf.conf"
else
    echo "   ✓ Anchor already configured in /etc/pf.conf"
fi

# ============================================================================
# 9. Enable IP forwarding
# ============================================================================
echo ""
echo "🔧 Enabling IP forwarding..."
sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null
echo "✓ IP forwarding enabled"

# ============================================================================
# 10. Load and enable the pf rules
# ============================================================================
echo ""
echo "🚀 Loading pf rules..."

# Validate syntax first
if sudo pfctl -nf /etc/pf.conf 2>&1 | grep -qi "error"; then
    echo "❌ Error: pf.conf has syntax errors"
    sudo pfctl -nf /etc/pf.conf
    exit 1
fi

echo "   ✓ Configuration validated"

# Disable, reload, and re-enable pf for clean state
sudo pfctl -d 2>/dev/null || true
sudo pfctl -f /etc/pf.conf 2>/dev/null
sudo pfctl -e 2>/dev/null

echo "✓ pf rules loaded and enabled"

# ============================================================================
# 11. Verify the configuration
# ============================================================================
echo ""
echo "✅ Configuration complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Network Configuration Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Multipass Bridge:  $BRIDGE_IF"
echo "  AWS VPN Tunnel:    $VPN_IF"
echo "  WAN Interface:     $WAN_IF"
echo ""
echo "  VPN Routes:"
for route in "${NORMALIZED_ROUTES[@]}"; do
    echo "    - $route → $VPN_IF"
done
echo ""
echo "  All other traffic  → $WAN_IF (internet)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your Multipass VM can now access:"
echo "  ✓ AWS VPN networks (via $VPN_IF)"
echo "  ✓ Public internet (via $WAN_IF)"
echo ""
echo "To view active rules:"
echo "  sudo pfctl -a multipass_vpn -sr  # Show routing rules"
echo "  sudo pfctl -a multipass_vpn -sn  # Show NAT rules"
echo ""
echo "To test connectivity from your VM:"
echo "  multipass exec <vm-name> -- curl https://artifactory.redoak.com/..."
echo ""
echo "Note: Run this script again if you disconnect/reconnect VPN"
echo "      or after reboot to restore routing."
