path "sys/auth/*" {
  capabilities = ["create", "update", "delete", "sudo"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "auth/approle/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
