#!/bin/bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Discernible-IO

# minor version is odd for testnet, even for mainnet
VERSION="0.95.57"

# Function to restore network settings
shutdown_vpn() {
    if [ -f ~/network_settings_backup ]; then
        echo "Restoring original network settings..."
        interface_name=$(sudo wg show | awk '/^interface:/ {print $2}')
        server_ip=$(sudo wg show $interface_name | grep "endpoint:" | awk '{print $2}' | cut -d ':' -f 1)
        default_gateway=$(ip route | awk '/default/ {print $3}')
        physical_device_name=$(ip -4 route show default | awk '/default via/ {print $5}')
        sudo ip route delete 128.0.0.0/1 dev "$interface_name"
        sudo ip route delete 0.0.0.0/1 dev "$interface_name"
        sudo ip route delete $server_ip via $default_gateway dev $physical_device_name
        echo "Network settings restored."
    else
        echo "No backup found. Cannot restore network settings."
    fi
}

# Check for shutdown option
if [ "$1" == "shutdown" ]; then
    shutdown_vpn
    exit 0
fi

# Print script information
echo "Version" $VERSION "running on " $BLOCKCHAIN_ENV "at Smart Contract" $RODITCONTRACTID " Get help with: "$0" help"

# Check if there are no entry parameters
if [ $# -eq 0 ]; then
    echo "Error: No entry parameter provided. Usage:" $0 "<json_file_name> (without extension)"
    exit 1
fi

if [ "$1" == "help" ]; then
    echo "Usage: "$0" [account_id] [Options]"
    echo "Warning: This script is not designed to work with multihomed computers"
    echo ""
    echo "Options:"
    echo "  "$0" <json_file_name> (without extension)"
    echo "  "$0" shutdown - Shutdown VPN and original network settings"
    exit 0
fi

# Check if the JSON file exists
json_file=~/.near-credentials/$BLOCKCHAIN_ENV/$1.json
if [ ! -f "$json_file" ]; then
    echo "Error: JSON file $json_file does not exist."
    exit 1
fi

# Get the file permissions in numeric form
PERMISSIONS=$(stat -c "%a" "$json_file")
# Check if the permissions are not 600
if [ "$PERMISSIONS" -ne 600 ]; then
    echo "IMPORTANT Warning: The file '$json_file' has permissions $PERMISSIONS, which is not 600 (secure)."
else
    echo "The file '$json_file' has secure permissions."
fi

# Run discernible-io and start the tunnel
echo "sudo discernible-io-cli -v trace $json_file"
if sudo discernible-io-cli --disable-drop-privileges -v trace $json_file; then
    echo "discernible-io-cli: Started and created the tunnel."
else
    echo "Error: discernible-io-cli failed to start."
    exit 1
fi

# Run `sudo wg show` and capture the interface name
echo "sudo wg show"
interface_name=$(sudo wg show | awk '/^interface:/ {print $2}')

echo "sudo nmcli connection modify" $interface_name "ipv4.ignore-auto-dns yes"
sudo nmcli connection modify $interface_name ipv4.ignore-auto-dns yes

# Extract the DNS resolver from the wg show command output
dns_resolver=$(sudo wg show | grep "DNS Resolver" | awk '{print $NF}')

# Check if the DNS resolver was found
if [ -z "$dns_resolver" ]; then
    echo "DNS Resolver not found in wg show output"
    exit 1
fi

# Modify the nmcli connection with the extracted DNS resolver
echo "sudo nmcli connection modify $interface_name ipv4.dns $dns_resolver"
sudo nmcli connection modify $interface_name ipv4.dns "$dns_resolver"

# Check if the interface name is not empty
if [ -n "$interface_name" ]; then
    # Update bring the interface up
    echo "sudo ip link set "$interface_name" up"
    if sudo ip link set "$interface_name" up; then
        echo "Bringing up interface: '$interface_name'."
    else
        echo "Error: Could not bring interface up"
        exit 1
    fi

    # Fetching the default gateway IP address
    default_gateway=$(ip route | awk '/default/ {print $3}')

    # Fetching the physical device IP address
    physical_device_name=$(ip -4 route show default | awk '/default via/ {print $5}')

    # Fetching the server IP address, This is read from the A entry of the vpn server of the RODiT
    # or read again when running wg subdomain-peer to change server
    server_ip=$(sudo wg show $interface_name | grep "endpoint:" | awk '{print $2}' | cut -d ':' -f 1)

    # Adding route using obtained values
    echo "sudo ip route add $server_ip via $default_gateway dev $physical_device_name"
    sudo ip route add $server_ip via $default_gateway dev $physical_device_name

    # Update iptables rules
    echo "sudo ip route add 0.0.0.0/1 dev "$interface_name""
    if sudo ip route add 0.0.0.0/1 dev "$interface_name"; then
        echo "Default Gateway 0.0.0.0/1 rule: Added for interface '$interface_name'."
    else
        echo "Error: Failed to add iptables routing rule."
        exit 1
    fi

    echo "sudo ip route add 128.0.0.0/1 dev "$interface_name""
    if sudo ip route add 128.0.0.0/1 dev "$interface_name"; then
        echo "Default Gateway 128.0.0.0/1 rule: Added for interface '$interface_name'."
    else
        echo "Error: Failed to add iptables routing rule."
        exit 1
    fi

    echo "Script completed successfully."
else
    echo "Error: Interface name not found in 'sudo wg show' output."
    exit 1
fi
