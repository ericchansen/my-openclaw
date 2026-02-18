using './main.bicep'

param location = 'centralus'
param adminUsername = 'azureuser'
param vmSize = 'Standard_B2pls_v2'

// Required: paste your SSH public key (contents of ~/.ssh/id_ed25519.pub)
param sshPublicKey = ''

// Optional: secrets to seed into Key Vault (leave empty to set later)
param openclawGatewayToken = ''
param githubToken = ''
