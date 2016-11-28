﻿#
# Deploy_ReferenceArchitecture.ps1
#
[cmdletbinding(DefaultParameterSetName='DEV-PASSWORD')]
param(
  [Parameter(Mandatory=$true)]
  $SubscriptionId,
  [Parameter(Mandatory=$false)]
  $Location = "West US 2",
  [Parameter(Mandatory=$true, ParameterSetName="DEV-PASSWORD")]
  [Security.SecureString]$AdminPassword,
  [Parameter(Mandatory=$true, ParameterSetName="DEV-SSH")]
  [Security.SecureString]$SshPublicKey,
  [Parameter(Mandatory=$true, ParameterSetName="PROD")]
  $KeyVaultName,
  [Parameter(Mandatory=$false, ParameterSetName="PROD")]
  [ValidateScript({($_ -ceq "adminPassword") -or ($_ -ceq "sshPublicKey")})]
  $KeyVaultSecretName = "adminPassword",

  [Parameter(Mandatory=$true, ParameterSetName="DEV-PASSWORD")]
  [Parameter(Mandatory=$true, ParameterSetName="DEV-SSH")]
  [Security.SecureString]$SharedKey,

  [Parameter(Mandatory=$true, ParameterSetName="PROD")]
  $SharedKeySecretName
)

$ErrorActionPreference = "Stop"

$buildingBlocksRootUriString = $env:TEMPLATE_ROOT_URI
if ($buildingBlocksRootUriString -eq $null) {
  $buildingBlocksRootUriString = "https://raw.githubusercontent.com/mspnp/template-building-blocks/master/"
}

if (![System.Uri]::IsWellFormedUriString($buildingBlocksRootUriString, [System.UriKind]::Absolute)) {
  throw "Invalid value for TEMPLATE_ROOT_URI: $env:TEMPLATE_ROOT_URI"
}

Write-Host
Write-Host "Using $buildingBlocksRootUriString to locate templates"
Write-Host

$templateRootUri = New-Object System.Uri -ArgumentList @($buildingBlocksRootUriString)
$virtualNetworkTemplate = New-Object System.Uri -ArgumentList @($templateRootUri, "templates/buildingBlocks/vnet-n-subnet/azuredeploy.json")
$loadBalancerTemplate = New-Object System.Uri -ArgumentList @($templateRootUri, "templates/buildingBlocks/loadBalancer-backend-n-vm/azuredeploy.json")
$multiVMsTemplate = New-Object System.Uri -ArgumentList @($templateRootUri, "templates/buildingBlocks/multi-vm-n-nic-m-storage/azuredeploy.json")
$dmzTemplate = New-Object System.Uri -ArgumentList @($templateRootUri, "templates/buildingBlocks/dmz/azuredeploy.json")
$vpnTemplate = New-Object System.Uri -ArgumentList @($templateRootUri, "templates/buildingBlocks/vpn-gateway-vpn-connection/azuredeploy.json")
$networkSecurityGroupsTemplate = New-Object System.Uri -ArgumentList @($templateRootUri, "templates/buildingBlocks/networkSecurityGroups/azuredeploy.json")

$virtualNetworkParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "virtualNetwork.parameters.json")
$webSubnetLoadBalancerAndVMsParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "loadBalancer-web-subnet.parameters.json")
$bizSubnetLoadBalancerAndVMsParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "loadBalancer-biz-subnet.parameters.json")
$dataSubnetLoadBalancerAndVMsParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "loadBalancer-data-subnet.parameters.json")
$mgmtSubnetVMsParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "virtualMachines-mgmt-subnet.parameters.json")
$dmzParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "dmz.parameters.json")
$internetDmzParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "internet-dmz.parameters.json")
$vpnParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "vpn.parameters.json")
$networkSecurityGroupsParametersFile = [System.IO.Path]::Combine($PSScriptRoot, "parameters", "networkSecurityGroups.parameters.json")

$networkResourceGroupName = "ra-public-dmz-network-rg"
$workloadResourceGroupName = "ra-public-dmz-wl-rg"

# Login to Azure and select your subscription
Login-AzureRmAccount -SubscriptionId $SubscriptionId | Out-Null

$protectedSettings = @{"adminPassword" = $null; "sshPublicKey" = $null}
switch ($PSCmdlet.ParameterSetName) {
  "DEV-PASSWORD" { 
	$protectedSettings["adminPassword"] = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))
	$protectedSettings.Add("sharedKey", [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($SharedKey)))
  }
  "DEV-SSH" { 
	$protectedSettings["sshPublicKey"] = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($SshPublicKey))
	$protectedSettings.Add("sharedKey", [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($SharedKey)))
  }
  "PROD" { 
	$protectedSettings[$KeyVaultSecretName] = (Get-AzureKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultSecretName).SecretValueText
	$protectedSettings.Add("sharedKey", (Get-AzureKeyVaultSecret -VaultName $KeyVaultName -Name $SharedKeySecretName).SecretValueText)
  }
  default { throw "Invalid parameters specified." }
}

# Create the resource group
$networkResourceGroup = New-AzureRmResourceGroup -Name $networkResourceGroupName -Location $Location
$workloadResourceGroup = New-AzureRmResourceGroup -Name $workloadResourceGroupName -Location $Location

Write-Host "Deploying virtual network..."
New-AzureRmResourceGroupDeployment -Name "ra-vnet-deployment" -ResourceGroupName $networkResourceGroup.ResourceGroupName `
    -TemplateUri $virtualNetworkTemplate.AbsoluteUri -TemplateParameterFile $virtualNetworkParametersFile

Write-Host "Deploying load balancer and virtual machines in web subnet..."
New-AzureRmResourceGroupDeployment -Name "ra-web-lb-vms-deployment" -ResourceGroupName $workloadResourceGroup.ResourceGroupName `
    -TemplateUri $loadBalancerTemplate.AbsoluteUri -TemplateParameterFile $webSubnetLoadBalancerAndVMsParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying load balancer and virtual machines in biz subnet..."
New-AzureRmResourceGroupDeployment -Name "ra-biz-lb-vms-deployment" -ResourceGroupName $workloadResourceGroup.ResourceGroupName `
    -TemplateUri $loadBalancerTemplate.AbsoluteUri -TemplateParameterFile $bizSubnetLoadBalancerAndVMsParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying load balancer and virtual machines in data subnet..."
New-AzureRmResourceGroupDeployment -Name "ra-data-lb-vms-deployment" -ResourceGroupName $workloadResourceGroup.ResourceGroupName `
    -TemplateUri $loadBalancerTemplate.AbsoluteUri -TemplateParameterFile $dataSubnetLoadBalancerAndVMsParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying jumpbox in mgmt subnet..."
New-AzureRmResourceGroupDeployment -Name "ra-mgmt-vms-deployment" -ResourceGroupName $networkResourceGroup.ResourceGroupName `
    -TemplateUri $multiVMsTemplate.AbsoluteUri -TemplateParameterFile $mgmtSubnetVMsParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying private dmz..."
New-AzureRmResourceGroupDeployment -Name "ra-private-dmz-deployment" -ResourceGroupName $networkResourceGroup.ResourceGroupName `
    -TemplateUri $dmzTemplate.AbsoluteUri -TemplateParameterFile $dmzParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying public dmz..."
New-AzureRmResourceGroupDeployment -Name "ra-public-dmz-deployment" -ResourceGroupName $networkResourceGroup.ResourceGroupName `
    -TemplateUri $dmzTemplate.AbsoluteUri -TemplateParameterFile $internetDmzParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying vpn..."
New-AzureRmResourceGroupDeployment -Name "ra-vpn-deployment" -ResourceGroupName $networkResourceGroup.ResourceGroupName `
    -TemplateUri $vpnTemplate.AbsoluteUri -TemplateParameterFile $vpnParametersFile -protectedSettings $protectedSettings

Write-Host "Deploying nsgs..."
New-AzureRmResourceGroupDeployment -Name "ra-nsg-deployment" -ResourceGroupName $networkResourceGroup.ResourceGroupName `
    -TemplateUri $networkSecurityGroupsTemplate.AbsoluteUri -TemplateParameterFile $networkSecurityGroupsParametersFile