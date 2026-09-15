# For regular secret operations
path "secret/data/signing-keys/*" {
  capabilities = ["create", "read", "update"]
  allowed_parameters = {
    "account_server" = []
    "account_client" = []
  }
}
path "secret/metadata/signing-keys/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/signing-keys" {
  capabilities = ["read", "list"]
}

# Read-only access for application
path "secret/data/signing-keys" {
  capabilities = ["read"]
}

# Audit capabilities
path "sys/audit/*" {
  capabilities = ["read"]
}

# Health check capabilities
path "sys/health" {
  capabilities = ["read"]
}
