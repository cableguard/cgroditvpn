FROM docker.io/hashicorp/vault:latest

# Expose Vault port
EXPOSE 3200

# Set up a volume for persistence
VOLUME /vault/file

# Set the entrypoint to the Vault executable
ENTRYPOINT ["vault"]

# Start Vault in server mode
CMD ["server", "-dev"]
