# Allow managing auth methods
path "sys/auth/*" {
  capabilities = ["create", "update", "delete", "sudo"]
}

# Allow listing auth methods
path "sys/auth" {
  capabilities = ["read"]
}

# Allow managing roles
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Existing podman-keys permissions
path "secret/data/signing-keys/*" {
  capabilities = ["create", "read", "update", "delete"]
}

# Allow listing secrets
path "secret/metadata/*" {
  capabilities = ["list"]
}

# Allow managing AppRole auth configuration
path "auth/approle/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
