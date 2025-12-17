# Multipass + AWS VPN Routing Setup

This script automatically configures macOS packet filter (pf) to enable Multipass VMs to access resources through AWS VPN Client while maintaining internet connectivity.

Created as a way to bypass this issue: (Multipass VMs don't route traffic over VPN established on host (MacOS)) https://github.com/canonical/multipass/issues/1336

## What It Does

The script dynamically detects and configures:
- **VPN traffic routing**: Routes traffic to private networks (10.x.x.x, 172.16.x.x) through the AWS VPN tunnel
- **Internet traffic routing**: Routes all other traffic through your regular internet connection
- **NAT configuration**: Sets up proper Network Address Translation for both paths
- **Packet filter rules**: Configures macOS pf to handle traffic intelligently

## Prerequisites

1. **Multipass** installed with at least one running VM
2. **AWS VPN Client** installed and connected
3. **Bridge networking** configured for your Multipass VM
4. **sudo privileges** to modify system network configuration

## Usage

### After Every Reboot

1. Boot your laptop
2. Launch and connect to AWS VPN Client
3. Start your Multipass VM(s)
4. Run the setup script:

```bash
./setup_vpn_routing.sh
```

The script will:
- ✅ Detect your network interfaces automatically
- ✅ Find the AWS VPN tunnel interface (utun*)
- ✅ Discover VPN routes dynamically
- ✅ Generate and install pf rules
- ✅ Enable IP forwarding
- ✅ Load and activate the configuration

### Example Output

```
🔍 Detecting network configuration...

Looking for Multipass bridge interface...
✓ Multipass bridge: bridge100
Looking for WAN interface...
✓ WAN interface: en0
Looking for AWS VPN Client tunnel interface...
(Checking for utun* interfaces with VPN routes)

  Found VPN routes on utun4:
    - 10.110.1/27
    - 172.16

✓ AWS VPN interface: utun4
✓ VPN routes found: 2

📝 Generating pf anchor configuration...
  Normalized routes:
    - 10.110.1.0/27
    - 172.16.0.0/12

📦 Installing pf anchor configuration...
   (requires sudo password)
✓ Anchor file created: /etc/pf.anchors/multipass_vpn

📝 Checking main pf configuration...
   ✓ Anchor already configured in /etc/pf.conf

🔧 Enabling IP forwarding...
✓ IP forwarding enabled

🚀 Loading pf rules...
   ✓ Configuration validated
✓ pf rules loaded and enabled

✅ Configuration complete!
```

## Testing Connectivity

From your Multipass VM, test access to VPN resources:

```bash
multipass exec <vm-name> -- curl https://internal-resource.example.com/...
```

Test internet connectivity:

```bash
multipass exec <vm-name> -- curl https://www.google.com
```

## Troubleshooting

### "Cannot find Multipass bridge interface"

Make sure your Multipass VM is running. Check with:
```bash
multipass list
```

If your VM exists but isn't running:
```bash
multipass start <vm-name>
```

### "Cannot find AWS VPN tunnel interface"

The AWS VPN Client must be connected before running this script. 

1. Open AWS VPN Client
2. Connect to your VPN
3. Wait for connection to establish
4. Run the script again

To verify VPN is connected:
```bash
netstat -rn -f inet | grep utun
```

You should see routes to 10.x or 172.16.x networks.

### "VPN routing not working after reboot"

This is expected! The pf configuration is loaded at boot, but the VPN interface and routes change. Simply run the script again after connecting to VPN.

## How It Works

### Network Architecture Example

```
┌─────────────────────────────────────────────────────┐
│  macOS Host                                         │
│                                                     │
│  ┌─────────────┐         ┌─────────────┐            │
│  │   en0       │         │   utun4     │            │
│  │  (WAN)      │         │  (AWS VPN)  │            │
│  └──────┬──────┘         └──────┬──────┘            │
│         │                       │                   │
│         │    ┌────────────────┐ │                   │
│         └────┤  pf (packet    ├─┘                   │
│              │  filter)       │                     │
│              └────────┬───────┘                     │
│                       │                             │
│              ┌────────┴───────┐                     │
│              │  bridge100     │                     │
│              │  (Multipass)   │                     │
│              └────────┬───────┘                     │
│                       │                             │
│              ┌────────┴───────┐                     │
│              │  VM (Ubuntu)   │                     │
│              │  192.168.2.x   │                     │
│              └────────────────┘                     │
└─────────────────────────────────────────────────────┘
```

### Traffic Flow

1. **VM → VPN Resources (172.16.x.x, 10.x.x.x)**:
   - Packet leaves VM with destination 172.16.x.x
   - Reaches bridge100 (Multipass bridge)
   - pf NAT rule matches → translates source to utun4 address
   - Packet routed out utun4 (AWS VPN tunnel)
   - Response comes back through utun4
   - pf translates destination back to VM address
   - Response delivered to VM

2. **VM → Internet (all other traffic)**:
   - Packet leaves VM with destination (e.g., 8.8.8.8)
   - Reaches bridge100
   - pf NAT rule matches → translates source to en0 address
   - Packet routed out en0 (regular internet)
   - Response comes back through en0
   - pf translates destination back to VM address
   - Response delivered to VM

### Files Modified

- `/etc/pf.conf` - Main packet filter configuration (adds multipass_vpn anchor)
- `/etc/pf.anchors/multipass_vpn` - VPN routing rules (regenerated each run)
- `/etc/pf.conf.backup` - Backup of original pf.conf (created on first run)

## Viewing Active Rules

To see the current NAT rules:
```bash
sudo pfctl -a multipass_vpn -sn
```

To see the current filter rules:
```bash
sudo pfctl -a multipass_vpn -sr
```

To see statistics (packets/bytes processed):
```bash
sudo pfctl -a multipass_vpn -vsr  # Filter rules with stats
sudo pfctl -a multipass_vpn -vsn  # NAT rules with stats
```

## Manual Cleanup

If you need to remove the configuration:

```bash
# Disable pf
sudo pfctl -d

# Remove the anchor file
sudo rm /etc/pf.anchors/multipass_vpn

# Restore original pf.conf
sudo cp /etc/pf.conf.backup /etc/pf.conf

# Reload pf
sudo pfctl -f /etc/pf.conf
sudo pfctl -e
```

## Technical Details

### Why This Is Needed

Multipass VMs run in a bridged network, giving them their own IP addresses on the Mac's network. However:

1. macOS doesn't automatically forward packets between the bridge and VPN tunnel
2. NAT is needed so VPN servers accept packets from VM IPs
3. Routing rules ensure traffic goes to the correct interface

### Why Run After Reboot

- VPN tunnel interface names (utun0, utun1, etc.) change
- VPN routes change based on VPN configuration
- Bridge interface may change
- pf rules reference specific interfaces, so must be regenerated

### Security Considerations

- The script requires sudo to modify system network configuration
- pf rules are stateful (track connections) for security
- Only traffic from the Multipass bridge is affected
- Your Mac's own traffic routing is unchanged
- No permanent system modifications (rules reset on reboot)

## Advanced Usage

### Using with Multiple VMs

The script automatically works with all VMs on the same Multipass bridge. All VMs will have VPN access once configured.

### Custom VPN Routes

The script auto-detects VPN routes. If you need to add custom routes, modify the generated `/etc/pf.anchors/multipass_vpn` file and add additional `vpn_netX` entries.

### Using with Different VPN Clients

This script is designed for AWS VPN Client but may work with other VPNs that:
- Create utun interfaces
- Add routes for 10.x or 172.16-31.x networks
- Use split tunneling

## Support

If you encounter issues:

1. Verify AWS VPN Client is connected
2. Verify Multipass VM is running
3. Check the script output for specific error messages
4. View active pf rules to verify configuration
5. Test connectivity from the Mac itself to verify VPN works

## License

MIT or something idk.
