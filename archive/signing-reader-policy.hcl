path "secret/data/signing-keys/*" {
  capabilities = ["read"]
}
path "secret/metadata/signing-keys/*" {
  capabilities = ["read", "list"]
}

# Add token self-lookup capability
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
