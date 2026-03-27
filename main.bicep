targetScope = 'resourceGroup'

param location string = resourceGroup().location

param vnetName string = 'vnet-egress'
param workloadSubnetName string = 'subnet-app-workload'
param nvaSubnetName string = 'subnet-nva-egress'

param workloadVmName string = 'vm-app'
param nvaVmName string = 'vm-nva'

param natGatewayName string = 'nat-gw'
param publicIpName string = 'nat-pip'
param routeTableName string = 'rt-workload'

param adminUsername string = 'azureuser'
@secure()
param adminPublicKey string

var cloudInit = loadTextContent('cloud-init-nva.yaml')
var vnetAddressPrefix = '10.0.0.0/16'
var workloadSubnetPrefix = '10.0.1.0/24'
var nvaSubnetPrefix = '10.0.2.0/24'
var bastionPrefix = '10.0.0.0/26'

var nvaInsideIP = '10.0.1.5'
var nvaOutsideIP = '10.0.2.4'
var appVmIP = '10.0.1.4'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource workloadSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  name: workloadSubnetName
  parent: vnet
  properties: {
    addressPrefix: workloadSubnetPrefix
    routeTable: {
      id: routeTable.id
    }
  }
}

resource nvaSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  name: nvaSubnetName
  parent: vnet
  properties: {
    addressPrefix: nvaSubnetPrefix
    natGateway: {
      id: natGateway.id
    }
  }
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'AzureBastionSubnet'
  parent: vnet
  properties: {
    addressPrefix: bastionPrefix
  }
}

resource bastionPublicIP 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'bastion-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastionHost 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'bastion-host'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: bastionPublicIP.id
          }
        }
      }
    ]
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = {
  name: natGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: routeTableName
  location: location
}

resource defaultRoute 'Microsoft.Network/routeTables/routes@2023-09-01' = {
  name: 'default-to-nva'
  parent: routeTable
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: nvaInsideIP
  }
}

resource nvaNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${nvaVmName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowVnetInBound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nvaNicInside 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${nvaVmName}-nic-inside'
  location: location
  properties: {
    enableIPForwarding: true

    networkSecurityGroup: {
      id: nvaNsg.id
    }

    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: workloadSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: nvaInsideIP
        }
      }
    ]
  }
}

resource nvaNicOutside 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${nvaVmName}-nic-outside'
  location: location
  properties: {
    enableIPForwarding: true

    networkSecurityGroup: {
      id: nvaNsg.id
    }

    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: nvaSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: nvaOutsideIP
        }
      }
    ]
  }
}

resource appNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${workloadVmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: workloadSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: appVmIP
        }
      }
    ]
  }
}

resource nvaVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: nvaVmName
  location: location
  properties: {

    hardwareProfile: {
      vmSize: 'Standard_B2s_v2'
    }

    osProfile: {
      computerName: 'vm-nva'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
      
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      
      }
      customData: base64(cloudInit)
    }

    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }

    networkProfile: {
      networkInterfaces: [
        {
          id: nvaNicOutside.id
          properties: {
          primary: true
          }
        }
        {
          id: nvaNicInside.id
          properties: {
          primary: false
          }
        }
      ]
    }

  }
}

resource appVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: workloadVmName
  location: location
  properties: {

    hardwareProfile: {
      vmSize: 'Standard_B2s_v2'
    }

    osProfile: {
      computerName: workloadVmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }

    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }

    networkProfile: {
      networkInterfaces: [
        {
          id: appNic.id
        }
      ]
    }
  }
}


