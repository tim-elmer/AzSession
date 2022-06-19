using namespace System.Management.Automation.Runspaces

<#
    .SYNOPSIS
    Creates a PSSession on an Azure VM.

    .PARAMETER ResourceGroup
    Specifies the Azure Resource Group in which the target Virtual Machine resides.

    .PARAMETER UserName
    Your Azure AD username. Defaults to executing user if not set.

    .PARAMETER VmName
    Specifies the name of the target Virtual Machine in Azure.

    .EXAMPLE
    # Create a reusable PSSession
    [System.Management.Automation.Runspaces.PSSession] $Session = Get-AzSession -ResourceGroup 'contoso-sql' -UserName 'someone@contoso.com' -VmName 'contoso-sql01'

    .EXAMPLE
    # Connect to a created PSSession
    Enter-PSSession $Session

    .EXAMPLE
    # Copy files to a created PSSession
    Copy-Item -Path '/home/someone/lqs.sql' -ToSession $Session -Destination '/var/tmp/'
    
    .EXAMPLE
    # Copy files from a created PSSession
    Copy-Item -FromSession $Session -Path '/var/log/fire.log' -Destination '/home/someone/logs'
#>
function Get-AzSession {
    param (
        [Parameter(Mandatory = $true)]
        [string] $ResourceGroup,
        [string] $UserName = [environment]::UserName,
        [Parameter(Mandatory = $true)]
        [string] $VmName,
        [switch] $Force
    )

    # Base path for SSH
    [string] $sshRoot = (Join-Path -Path $HOME -ChildPath '.ssh')

    # Path to used SSH config
    [string] $sshConfig = (Join-Path -Path $sshRoot -ChildPath 'config')

    # Path to store user's original SSH config
    [string] $sshConfigOriginal = (Join-Path -Path $sshRoot -ChildPath 'config_orig')

    # Directory to store temporary config, keys
    [psobject] $tempDirectory = New-Item -Path (Join-Path -Path (Get-Item 'Temp:') -ChildPath 'AzSession') -ItemType Directory -Force

    # Path to store Az's temp config file
    [string] $sshConfigEphemeral = (Join-Path -Path $tempDirectory.FullName -ChildPath 'config')

    if ((Get-ChildItem -Path $tempDirectory) -and -not $Force) {
        throw "The path '$tempDirectory' is not empty. Halting to prevent data loss. Run with the '-Force' option to bypass this check."
    }

    if (Test-Path -Path $sshConfigOriginal) {
        if ($Force) {
            Move-Item -Path $sshConfigOriginal -Destination "$($sshConfigOriginal).$([datetime]::Now.ToString('yyMMddHHmmss'))"
        }
        else {
            throw "The path '$sshConfigOriginal' is not empty. Halting to prevent data loss. Run with the '-Force' option to bypass this check."
        }
    }

    # Check for az
    try {
        # Check for SSH extension
        if ((az extension list --query "length([?contains(name, 'ssh')])") -ne 1) {
            # Add SSH extension
            az extension add --upgrade --name ssh
        }
    }
    catch {
        throw 'The Azure CLI was not found. Please install the Azure CLI (https://docs.microsoft.com/en-us/cli/azure/install-azure-cli).'
    }

    [bool] $wasLoggedIn = $false
    [string] $target = ''
    [bool] $loggedIn = $false

    do {
        # Get VM IP and consequent login status
        $target = az vm list-ip-addresses --name $VmName --resource-group $ResourceGroup --query [].virtualMachine.network.publicIpAddresses[0].ipAddress --output tsv
        $loggedIn = $?
        if ($loggedIn) {
            $wasLoggedIn = $true
            break
        }
        else {
            az login
        }
    } until (
        $loggedIn
    )

    if ([string]::IsNullOrWhiteSpace($target)) {
        throw 'Could not retrieve Virtual Machine''s IP.'
    }

    # Check if config exists
    [bool] $userHasConfig = Test-Path -Path $sshConfig

    if ($userHasConfig) {
        # Store user's original SSH config
        Rename-Item -Path $sshConfig -NewName $sshConfigOriginal
    }
    # Create ssh directory if not present
    elseif (-not (Test-Path -Path $sshRoot)) {
        New-Item -Path $sshRoot -ItemType 'Directory'
    }

    # Create temporary configuration and keys.
    az ssh config --name $VmName --resource-group $ResourceGroup --file $sshConfigEphemeral *>&1 | ForEach-Object {
        if ($PSItem -is [System.Management.Automation.ErrorRecord] -and -not ([System.Management.Automation.ErrorRecord]$PSItem).TargetObject -clike 'WARNING: *contains sensitive information*') {
            Write-Error $PSItem
            throw
        }
    }
    # if (-not $?) {
    #     throw
    # }

    # Enable temporary configuration
    Copy-Item -Path $sshConfigEphemeral -Destination $sshConfig
    
    try {
        # Create session
        [PSSession] $session = New-PSSession -HostName $target -UserName $UserName -KeyFilePath (Join-Path -Path $tempDirectory.FullName -ChildPath 'az_ssh_config' -AdditionalChildPath @("$($ResourceGroup)-$($VmName)", 'id_rsa'))
    }
    catch {
        Write-Error -Message 'Failed to create session:'
        Write-Error $PSItem
    }
    
    # Put things back as we found them
    Remove-Item -Path $tempDirectory.FullName -Force -Recurse
    Remove-Item $sshConfig
    if ($userHasConfig) {
        Rename-Item -Path $sshConfigOriginal $sshConfig
    }

    if (-not $wasLoggedIn) {
        az logout
    }

    return $session
} 

Export-ModuleMember -Function 'Get-AzSession'