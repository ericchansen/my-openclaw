using './main.bicep'

param location = 'centralus'
param adminUsername = 'azureuser'
param vmSize = 'Standard_B2ps_v2'
param ubuntuImageVersion = '24.04.202607140'

// Required: paste your SSH public key (contents of ~/.ssh/id_ed25519.pub)
param sshPublicKey = ''
