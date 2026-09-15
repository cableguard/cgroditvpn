# Network configuration for idcp-wallet.sh

## Problem
The script may encounter RPC errors due to:
- Rate limiting on default RPC endpoints (mainnet-fastnear)
- Network connectivity issues
- Pagoda free tier limitations

## Solution
Configure a different network config using the `NEAR_NETWORK_CONFIG` environment variable.

The NEAR CLI has built-in network configurations that you can switch between. Use `mainnet-lava` for better reliability.

## Usage

### Option 1: One-time use
```bash
export NEAR_NETWORK_CONFIG="mainnet-lava"
./idcp-wallet.sh <your-command>
```

### Option 2: Host-local file in infra-app
`./bootstrap-infra-app.sh` copies the example to `~/infra-app/roditwallet.env`.
`idcp-wallet.sh` sources that file automatically. Edit it for this machine; do not commit it.

### Option 3: Permanent configuration
Add to your `~/.bashrc` or `~/.profile`:
```bash
export NEAR_NETWORK_CONFIG="mainnet-lava"
```

## Available Network Configs

### For Mainnet:
- **mainnet-lava** (Lava Network - recommended for reliability)
- **mainnet-fastnear** (FastNEAR - default)

### For Testnet:
- **testnet-lava** (Lava Network testnet)
- **testnet-fastnear** (FastNEAR testnet)

To see all available configs and their RPC endpoints:
```bash
near config show-connections
```

## Testing
To verify the network configuration is working:
```bash
export NEAR_NETWORK_CONFIG="mainnet-lava"
./idcp-wallet.sh <accountId> '<roditId>'
```

You should see: `Using network config: mainnet-lava` at the start of the output.

## Troubleshooting

If you still encounter errors:
1. Try a different network config (e.g., switch between mainnet-lava and mainnet-fastnear)
2. Check your internet connectivity
3. Verify the account and RODiT ID are correct
4. The script has built-in retry logic (3 attempts with 2s delay)
5. Check if the RODiT actually exists for that account (the error might be legitimate)
