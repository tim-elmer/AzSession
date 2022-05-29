using namespace System.Management.Automation.Runspaces

<#
    .SYNOPSIS
    Creates a PSSession on an Azure VM.

    .PARAMETER ResourceGroup
    tag::resourceGroup[]
    Specifies the Azure Resource Group in which the target Virtual Machine resides.
    end::resourceGroup[]

    .PARAMETER UserName
    tag::userName[]
    Your Azure AD username. Defaults to executing user if not set.
    end::userName[]

    .PARAMETER VmName
    tag::vmName[]
    Specifies the name of the target Virtual Machine in Azure.
    end::vmName[]

    .EXAMPLE
    # Create a reusable PSSession
    # tag::create[]
    [System.Management.Automation.Runspaces.PSSession] $Session = Get-AzSession -ResourceGroup 'contoso-sql' -UserName 'someone@contoso.com' -VmName 'contoso-sql01'
    # end::create[]

    .EXAMPLE
    # Connect to a created PSSession
    # tag::enter[]
    Enter-PSSession $Session
    # end::enter[]

    .EXAMPLE
    # Copy files to a created PSSession
    # tag::copy-to[]
    Copy-Item -Path '/home/someone/lqs.sql' -ToSession $Session -Destination '/var/tmp/'
    # end::copy-to[]
    
    .EXAMPLE
    # Copy files from a created PSSession
    # tag::copy-from[]
    Copy-Item -FromSession $Session -Path '/var/log/fire.log' -Destination '/home/someone/logs'
    # end::copy-from[]
#>
function Get-AzSession {
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceGroup,
        [string] $UserName = [environment]::UserName,
        [Parameter(Mandatory = $true)]
        [string] $VmName
    )

    # Path to used SSH config
    [string] $sshConfig = (Join-Path -Path $HOME -ChildPath '.ssh/config')

    # Path to store user's original SSH config
    [string] $sshConfigOriginal = (Join-Path -Path $HOME -ChildPath '.ssh/config_orig')

    # Directory to store temporary config, keys
    [psobject] $cred = New-Item -Path "$PSScriptRoot/temp" -ItemType Directory -Force

    # Path to store Az's temp config file
    [string] $sshConfigEphemeral = (Join-Path -Path $cred.FullName -ChildPath 'config')

    # Get VM IP
    [string] $target = (az vm list-ip-addresses --name $VmName --resource-group $ResourceGroup | ConvertFrom-Json).virtualMachine.network.publicIpAddresses[0].ipAddress

    # Store user's original SSH config
    Rename-Item -Path $sshConfig -NewName $sshConfigOriginal

    # Create temporary configuration and keys
    az ssh config --name $VmName --resource-group $ResourceGroup --file $sshConfigEphemeral | Write-Host

    # Enable temporary configuration
    Copy-Item -Path $sshConfigEphemeral -Destination $sshConfig

    # Create session
    [PSSession] $session = New-PSSession -HostName $target -UserName $UserName -KeyFilePath "$($cred.FullName)/az_ssh_config/$ResourceGroup-$($VmName)/id_rsa"

    # Put things back as we found them
    Remove-Item -Path $cred.FullName -Force -Recurse
    Remove-Item $sshConfig
    Rename-Item -Path $sshConfigOriginal $sshConfig

    return $session
} 

Export-ModuleMember -Function 'Get-AzSession'