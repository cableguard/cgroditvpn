#!/bin/bash
# List secrets in HashiCorp Vault under a signing policy.
# Usage: ./list-vault-secrets.sh [discernible|discernible-io]
#        VAULT_PROFILE=discernible ./list-vault-secrets.sh

declare -A VAULT_PROFILE_ADDR=(
  [discernible]="https://dev-vault.discernible.net:8200"
  [discernible-io]="https://dev-vault.discernible-io.net:8200"
)

PROFILE="${VAULT_PROFILE:-discernible}"
if [[ $# -gt 0 && "$1" != -* ]]; then
  PROFILE="$1"
  shift
fi

if [[ -z "${VAULT_PROFILE_ADDR[$PROFILE]+x}" ]]; then
  echo "Unknown profile: $PROFILE (use discernible or discernible-io)" >&2
  exit 1
fi

POLICY_NAME="signing-policy"
AUTH_METHOD="approle"  # Options: token, approle, userpass, etc.
DEBUG=true             # Set to false to disable detailed debug output
SHOW_CONTENT=false     # Set to true to show the actual secret content (WARNING: sensitive!)

export VAULT_ADDR="${VAULT_PROFILE_ADDR[$PROFILE]}"
echo "Vault profile: $PROFILE ($VAULT_ADDR)"

# Debug function
debug() {
  if [ "$DEBUG" = true ]; then
    echo "[DEBUG] $1" >&2
  fi
}

# Function to recursively list secrets at a path
list_secrets() {
  local path=$1
  local found_secrets=false
  
  debug "Attempting to list: $path"
  
  # Handle special case for root paths with wildcards
  if [[ "$path" == *"*" ]]; then
    base_path=$(echo "$path" | sed 's/\*$//')
    debug "Wildcard path detected. Using base path: $base_path"
    path=$base_path
  fi
  
  # Special handling for KV paths
  local mount_path=""
  local secret_path=""
  
  # Extract mount and secret paths
  if [[ "$path" == /secret/* ]]; then
    mount_path="secret"
    # Remove /secret/ prefix and any /data/ or /metadata/ part
    secret_path=$(echo "$path" | sed 's/^\/secret\///;s/^data\///;s/^metadata\///')
    debug "KV path detected. Mount: $mount_path, Secret path: $secret_path"
  fi
  
  # First try to list using KV command for KV paths
  if [[ -n "$mount_path" ]]; then
    debug "Running KV list command: vault kv list -mount=$mount_path $secret_path"
    local kv_items=$(vault kv list -mount=$mount_path "$secret_path" 2>/dev/null)
    local kv_list_status=$?
    
    if [ $kv_list_status -eq 0 ]; then
      debug "Successfully listed KV path using 'kv list'"
      
      # Process each item from KV list
      echo "$kv_items" | tail -n +3 | while read item; do
        # Skip headers and empty lines
        if [[ -z "$item" || "$item" == =* ]]; then
          continue
        fi
        
        debug "Processing KV item: $item"
        
        # Remove any trailing whitespace
        item=$(echo "$item" | xargs)
        
        local new_secret_path
        if [[ "$secret_path" == */ ]]; then
          new_secret_path="${secret_path}${item}"
        else
          new_secret_path="${secret_path}/${item}"
        fi
        
        # Check if item ends with / (it's a directory)
        if [[ "$item" == */ ]]; then
          debug "KV item is a directory. Recursing into: $mount_path/$new_secret_path"
          if list_secrets "/secret/$new_secret_path"; then
            found_secrets=true
          fi
        else
          # Try to get the secret
          debug "Trying to get KV secret: vault kv get -mount=$mount_path $new_secret_path"
          
          if [ "$SHOW_CONTENT" = true ]; then
            # Display the entire secret content
            echo "SECRET (KV): $mount_path/$new_secret_path"
            vault kv get -mount=$mount_path "$new_secret_path"
            echo "----------------------------------------"
          else
            # Just check if the secret exists
            vault kv get -mount=$mount_path "$new_secret_path" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
              echo "SECRET (KV): $mount_path/$new_secret_path"
              found_secrets=true
              
              # Write to a temporary file to communicate that secrets were found
              echo "true" > /tmp/vault_secrets_found
            fi
          fi
        fi
      done
      
      return
    else
      debug "KV list failed, trying to get secret directly"
      
      # Try to get the secret directly
      debug "Trying: vault kv get -mount=$mount_path $secret_path"
      
      if [ "$SHOW_CONTENT" = true ]; then
        # Display the entire secret content if it exists
        vault kv get -mount=$mount_path "$secret_path" 2>/dev/null
        if [ $? -eq 0 ]; then
          echo "SECRET (KV): $mount_path/$secret_path"
          echo "----------------------------------------"
          found_secrets=true
          echo "true" > /tmp/vault_secrets_found
        fi
      else
        # Just check if the secret exists
        vault kv get -mount=$mount_path "$secret_path" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "SECRET (KV): $mount_path/$secret_path"
          found_secrets=true
          echo "true" > /tmp/vault_secrets_found
        fi
      fi
    fi
  fi
  
  # Fall back to standard listing
  debug "Running: vault list -format=json $path"
  local items=$(vault list -format=json "$path" 2>/dev/null)
  local list_status=$?
  
  # Check if list command was successful
  if [ $list_status -ne 0 ]; then
    debug "Couldn't list path: $path (status: $list_status)"
    
    # If we can't list, try to read (might be a secret, not a path)
    debug "Trying to read: $path"
    
    if [ "$SHOW_CONTENT" = true ]; then
      # Try to read and show content
      vault read "$path" 2>/dev/null
      if [ $? -eq 0 ]; then
        echo "SECRET: $path"
        echo "----------------------------------------"
        found_secrets=true
        echo "true" > /tmp/vault_secrets_found
      fi
    else
      # Just check if readable
      vault read "$path" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo "SECRET: $path"
        found_secrets=true
        echo "true" > /tmp/vault_secrets_found
      fi
    fi
    
    # Special case handling for KV v2 secrets
    if [[ "$path" == /secret/* && "$path" != /secret/data/* ]]; then
      local data_path="${path/\/secret\//\/secret\/data\/}"
      debug "Trying KV v2 data path: $data_path"
      
      if [ "$SHOW_CONTENT" = true ]; then
        vault read "$data_path" 2>/dev/null
        if [ $? -eq 0 ]; then
          echo "SECRET (KV v2): $data_path"
          echo "----------------------------------------"
          found_secrets=true
          echo "true" > /tmp/vault_secrets_found
        fi
      else
        vault read "$data_path" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "SECRET (KV v2): $data_path"
          found_secrets=true
          echo "true" > /tmp/vault_secrets_found
        fi
      fi
    fi
    
    return
  fi
  
  # Process each item from the list
  debug "Successfully listed path: $path"
  echo "$items" | jq -r '.[]' 2>/dev/null | while read item; do
    local new_path
    
    # Skip empty items
    if [ -z "$item" ]; then
      continue
    fi
    
    debug "Processing item: $item"
    
    # Check if path ends with /, add if not
    if [[ "$path" == */ ]]; then
      new_path="${path}${item}"
    else
      new_path="${path}/${item}"
    fi
    
    # If item ends with /, it's a path, recurse into it
    if [[ "$item" == */ ]]; then
      debug "Item ends with /. Recursing into: $new_path"
      if list_secrets "$new_path"; then
        found_secrets=true
      fi
    else
      # Check if it's a folder by trying to list it
      debug "Checking if item is a folder: $new_path"
      vault list "$new_path" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        debug "Item is a folder. Recursing into: $new_path/"
        if list_secrets "$new_path/"; then
          found_secrets=true
        fi
      else
        # It's likely a secret
        debug "Found secret: $new_path"
        
        # For KV v2 store, try KV specific commands
        if [[ "$new_path" == /secret/* ]]; then
          local kv_secret_path=$(echo "$new_path" | sed 's/^\/secret\///;s/^data\///;s/^metadata\///')
          debug "Trying KV get command: vault kv get -mount=secret $kv_secret_path"
          
          if [ "$SHOW_CONTENT" = true ]; then
            vault kv get -mount=secret "$kv_secret_path" 2>/dev/null
            if [ $? -eq 0 ]; then
              echo "SECRET (KV): secret/$kv_secret_path"
              echo "----------------------------------------"
              found_secrets=true
              echo "true" > /tmp/vault_secrets_found
            fi
          else
            vault kv get -mount=secret "$kv_secret_path" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
              echo "SECRET (KV): secret/$kv_secret_path"
              found_secrets=true
              echo "true" > /tmp/vault_secrets_found
            fi
          fi
        else
          # Standard path handling for non-KV
          if [ "$SHOW_CONTENT" = true ]; then
            vault read "$new_path" 2>/dev/null
            if [ $? -eq 0 ]; then
              echo "SECRET: $new_path"
              echo "----------------------------------------"
              found_secrets=true
              echo "true" > /tmp/vault_secrets_found
            fi
          else
            vault read "$new_path" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
              echo "SECRET: $new_path"
              found_secrets=true
              echo "true" > /tmp/vault_secrets_found
            fi
          fi
        fi
      fi
    fi
  done
  
  return $found_secrets
}

# First, get the policy details to find the paths it has access to
echo "Retrieving policy details for: $POLICY_NAME"
POLICY_DETAILS=$(vault policy read "$POLICY_NAME")

if [ $? -ne 0 ]; then
  echo "Error: Failed to read policy '$POLICY_NAME'. Make sure the policy exists and you have permission to read it."
  exit 1
fi

echo "Extracting paths from policy..."
# Extract paths from policy
PATHS=$(echo "$POLICY_DETAILS" | grep -o 'path\s*"[^"]*"' | sed 's/path\s*"\(.*\)"/\1/')

if [ -z "$PATHS" ]; then
  # Try alternative format (path "secret/foo" {)
  PATHS=$(echo "$POLICY_DETAILS" | grep -oP 'path\s*"[^"]*"' | sed 's/path\s*"\(.*\)".*/\1/')
fi

if [ -z "$PATHS" ]; then
  echo "No paths found in policy or unable to parse policy format."
  echo "Raw policy content:"
  echo "$POLICY_DETAILS"
  exit 1
fi

echo "Found the following paths in policy:"
echo "$PATHS"
echo ""
echo "Listing secrets under these paths:"

# Remove any old results file
rm -f /tmp/vault_secrets_found

# For each path in the policy, list secrets
echo "$PATHS" | while read path; do
  # Skip empty lines
  if [ -z "$path" ]; then
    continue
  fi
  
  echo "Checking path: $path"
  
  # Clean the path
  # Remove trailing '+' wildcard if present and add leading slash if missing
  clean_path=$(echo "$path" | sed 's/\*$//;s/\+$//;s/^\([^/]\)/\/\1/')
  
  # List secrets at this path
  list_secrets "$clean_path"
done

# Check if secrets were found (read from temp file to handle subshell variables)
if [ -f /tmp/vault_secrets_found ] && [ "$(cat /tmp/vault_secrets_found)" == "true" ]; then
  echo "✅ Secrets found! See the SECRET entries above."
  rm -f /tmp/vault_secrets_found
else
  echo "❌ No secrets found. This could be because:"
  echo "1. The policy doesn't grant access to any secrets"
  echo "2. No secrets exist under the paths in the policy"
  echo "3. The paths in the policy use a different format than expected"
  echo ""
  echo "Try these troubleshooting steps:"
  echo "- Run 'vault secrets list' to see available secret engines"
  echo "- For KV v2 stores, try manually checking a path like 'vault kv list secret/'"
  echo "- Check if you need to authenticate with different credentials"
fi

echo "Secret listing complete!"
