# Key Vault Integration

OpenClaw on Azure uses Key Vault for secure secret management. Secrets are fetched at runtime via the VM's managed identity — no secrets in config files.

## Architecture

```
Azure Key Vault
    ↓ (RBAC: Key Vault Secrets User)
VM Managed Identity
    ↓ (az keyvault secret show)
Environment Variables
    ↓
OpenClaw Gateway
```

## Secrets Stored

| Secret Name | Purpose |
|-------------|---------|
| `OPENCLAW-GATEWAY-TOKEN` | Gateway authentication token |
| `GITHUB-TOKEN` | GitHub PAT for repo operations |
| `BRAVE-API-KEY` | Brave Search API key (optional) |
| `TELEGRAM-BOT-TOKEN` | Telegram bot token (optional) |
| `DISCORD-BOT-TOKEN` | Discord bot token (optional) |

## Fetching Secrets

### Using the Helper Script

The `openclaw-fetch-secrets` script is installed by cloud-init:

```bash
# Load secrets into environment
source openclaw-fetch-secrets kv-your-vault-name

# Verify
echo $OPENCLAW_GATEWAY_TOKEN
echo $GITHUB_TOKEN
```

### Manual Fetch

```bash
# Login with managed identity
az login --identity --allow-no-subscriptions

# Fetch individual secret
GITHUB_TOKEN=$(az keyvault secret show \
  --vault-name kv-your-vault-name \
  --name GITHUB-TOKEN \
  --query value -o tsv)
```

## Setting Secrets

### Azure CLI

```bash
az keyvault secret set \
  --vault-name kv-your-vault-name \
  --name GITHUB-TOKEN \
  --value "ghp_xxxxxxxxxxxx"
```

### Azure Portal

1. Navigate to Key Vault → Secrets
2. Click "+ Generate/Import"
3. Enter name (use UPPERCASE-WITH-DASHES)
4. Enter value
5. Click Create

## Deployment Setup

The Bicep template configures:

1. **Key Vault** with RBAC authorization
2. **VM Managed Identity** assigned automatically
3. **Role Assignment** granting "Key Vault Secrets User" to VM

```bicep
// Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${uniqueString(resourceGroup().id)}'
  properties: {
    enableRbacAuthorization: true
    // ...
  }
}

// Role assignment for VM
resource secretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, 'secrets-user')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
    )
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
```

## Using Secrets in Config

**Never put actual secrets in config files.** Use environment variables or fetch at runtime.

### Gateway Token

Set in Key Vault as `OPENCLAW-GATEWAY-TOKEN`. The gateway reads from:
1. `--token` CLI flag
2. `OPENCLAW_GATEWAY_TOKEN` environment variable
3. Config file (not recommended)

### GitHub Operations

Fetch token before git operations:

```bash
GITHUB_TOKEN=$(az keyvault secret show \
  --vault-name kv-your-vault-name \
  --name GITHUB-TOKEN \
  --query value -o tsv)

git push https://x-access-token:$GITHUB_TOKEN@github.com/owner/repo.git branch
```

### In Workspace Files

Reference Key Vault in AGENTS.md for agent instructions:

```markdown
## Credentials

Fetch from Key Vault (`kv-your-vault-name`) when needed:
- GITHUB-TOKEN for git push/PR
- API keys for integrations
```

## Security Best Practices

1. **Never commit secrets** — Use `.gitignore` for sensitive files
2. **Rotate regularly** — Update tokens periodically
3. **Least privilege** — Only grant necessary permissions
4. **Audit access** — Review Key Vault logs
5. **Use managed identity** — No service principal secrets to manage

## Troubleshooting

### "Access denied" Error

Check role assignment:
```bash
az role assignment list --scope /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/kv-xxx
```

Verify managed identity:
```bash
az vm identity show --resource-group rg-openclaw --name vm-openclaw
```

### Secret Not Found

List available secrets:
```bash
az keyvault secret list --vault-name kv-your-vault-name --query "[].name" -o tsv
```

### Login Issues

Ensure managed identity is enabled:
```bash
az login --identity --debug
```

## Adding New Secrets

When you need a new secret:

1. Add to Key Vault:
```bash
az keyvault secret set --vault-name kv-xxx --name NEW-SECRET --value "xxx"
```

2. Update fetch script (if needed):
```bash
export NEW_SECRET=$(az keyvault secret show --vault-name "$VAULT_NAME" --name NEW-SECRET --query value -o tsv)
```

3. Reference in code/config via environment variable

## Backup

Key Vault supports soft delete by default. Deleted secrets can be recovered for 90 days.

For critical secrets, consider:
- Backup via `az keyvault secret backup`
- Cross-region replication
- Documentation of secret purposes
