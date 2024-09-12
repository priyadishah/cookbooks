﻿<#
.SYNOPSIS

Bake a LANSA AMI

.DESCRIPTION

.EXAMPLE


#>

function bake-IdeMsi {
param (
    [Parameter(Mandatory=$true)]
    [string]
    $VersionText,

    [Parameter(Mandatory=$true)]
    [int]
    $VersionMajor,

    [Parameter(Mandatory=$true)]
    [int]
    $VersionMinor,

    [Parameter(Mandatory=$true)]
    [string]
    $LocalDVDImageDirectory,

    [Parameter(Mandatory=$true)]
    [string]
    $S3DVDImageDirectory,

    [Parameter(Mandatory=$true)]
    [string]
    $S3VisualLANSAUpdateDirectory,

    [Parameter(Mandatory=$true)]
    [string]
    $S3IntegratorUpdateDirectory,

    [Parameter(Mandatory=$true)]
    [string]
    $AmazonAMIName,

    [Parameter(Mandatory=$true)]
    [string]
    $GitBranch,

    [Parameter(Mandatory=$false)]
    [string]
    $AdminUserName='Administrator',

    [Parameter(Mandatory=$false)]
    [string]
    $Language='JPN',

    [Parameter(Mandatory=$false)]
    [boolean]
    $InstallSQLServer=$false,

    [Parameter(Mandatory=$false)]
    [boolean]
    $InstallIDE=$true,

    [Parameter(Mandatory=$false)]
    [boolean]
    $InstallScalable=$false,

    [Parameter(Mandatory=$false)]
    [boolean]
    $InstallBaseSoftware=$true,

    [Parameter(Mandatory=$false)]
    [string]
    $Cloud='AWS',

    [Parameter(Mandatory=$false)]
    [boolean]
    $Win2012=$true,

    [Parameter(Mandatory=$false)]
    [boolean]
    $SkipSlowStuff=$false,          # Don't use. Here for backward compatibility with old scripts

    [Parameter(Mandatory=$false)]
    [boolean]
    $RunWindowsUpdates=$false,          # Generally, not required to run Windows Updates because we are using the latest VM Image

    [Parameter(Mandatory=$false)]
    [boolean]
    $ManualWinUpd=$false,

    [Parameter(Mandatory=$false)]
    [boolean]
    $UploadInstallationImageChanges=$true,

    [Parameter(Mandatory=$false)]
    [boolean]
    $Upgrade=$false,

    [Parameter(Mandatory=$false)]
    [boolean]
    $OnlySaveImage=$false,

    $CreateVM=$false,    # Used for speeding up script when debugging, provided the VM already exists!

    [Parameter(Mandatory=$false)]
    [switch]
    $Pipeline,

    [Parameter(Mandatory=$false)]
    [switch]
    $AtomicBuild,

    [Parameter(Mandatory=$true)]
    [string]
    $KeyPairName,

    [Parameter(Mandatory=$true)]
    [string]
    $KeyPairPath,

    [Parameter(Mandatory=$true)]
    [string]
    $GitUserName
    )

#Requires -RunAsAdministrator

# Output the Pipeline Switch Status
Write-Host "Pipeline Switch"
$Pipeline | Out-Default | Write-Host

# Output the AtomicBuild Switch Status
Write-Host "AtomicBuild Switch"
$AtomicBuild | Out-Default | Write-Host

# Backward compatibility
if ( $SkipSlowStuff ) {
    $UploadInstallationImageChanges = $false
}

# set up environment if not yet setup
if ( (Test-Path variable:IncludeDir))
{
    # Log-Date can't be used yet as Framework has not been loaded

    Write-Host "Initialising environment - presumed not running through RemotePS"

    # $MyInvocation.MyCommand.Path
	# $script:IncludeDir = Split-Path -Parent $MyInvocation.MyCommand.Path

	. "$script:IncludeDir\Init-Baking-Vars.ps1"
	. "$script:IncludeDir\Init-Baking-Includes.ps1"
}
else
{
	throw '$IncludeDir must be set up by the caller'
}

###############################################################################
# Main program logic
###############################################################################

Set-StrictMode -Version Latest

if ($InstallIDE -eq $true) {
    $Script:DialogTitle = "LANSA IDE"
    $script:instancename = "LANSA IDE $VersionText installed on $(Log-Date)"
}


if ($InstallScalable -eq $true) {
    $Script:DialogTitle = "LANSA Scalable License "
    $script:instancename = "LANSA Scalable License $VersionText installed on $(Log-Date)"
}

try
{
    # Clear out the msgbox object in case its been run already
    $Script:msgbox = $null

    $dummy = MessageBox "Running Japanese image build. Click OK to continue"

    Write-Host ("$(Log-Date) Allow Remote Powershell session to any host. If it fails you are not running as Administrator!")
    $VerbosePreferenceSaved = $VerbosePreference
    $VerbosePreference = "SilentlyContinue"
    enable-psremoting -SkipNetworkProfileCheck -force
    set-item wsman:\localhost\Client\TrustedHosts -value * -force
    $VerbosePreference = $VerbosePreferenceSaved
    $externalip = Get-ExternalIP

    if ( $VersionText -like "w12*" ) {
        $Platform = 'Win2012'
        $Win2012 = $true
    } elseif ($VersionText -like "w16*") {
        $Platform = 'Win2016'
        $Win2012 = $false
    } elseif ($VersionText -like "w19*"){
        $Platform= 'Win2019'
        $Win2012 = $false
    }

    Write-Host( "Platform = $platform")

    if ( $Cloud -eq 'AWS' ) {
        Write-Host( "$(Log-Date) Removing existing instance that would be using the security group")
        $TaggedInstances = @(Get-EC2Tag -Filter @{Name="tag:BakeVersion";Value=$VersionText} | Where-Object ResourceType -eq "instance")
        foreach ($TaggedInstance in $TaggedInstances) {
            $TaggedInstance.ResourceId | Out-Default | Write-Host
            Remove-EC2Instance -InstanceId $TaggedInstance.ResourceId -Force
            Wait-EC2State $TaggedInstance.ResourceId "Terminated"
        }
        Write-Host( "Security group = $($script:SG)")
        Create-Ec2SecurityGroup
    }

    # First image found is presumed to be the latest image.
    # Force it into a list so that if one image is returned the variable may be used identically.

    Write-Host ("Locate image Name $AmazonAMIName")

    if ( $Cloud -eq 'AWS' ) {
        $AdminUserName = "Administrator"
        $AmazonImage = @(Get-EC2Image -Filters @{Name = "name"; Values = $AmazonAMIName} | Sort-Object -Descending CreationDate)
        $ImageName = $AmazonImage[0].Name
        $Script:Imageid = $AmazonImage[0].ImageId
        Write-Host "$(Log-Date) Using Base Image $ImageName $Script:ImageId"

        Create-EC2Instance $Script:Imageid $script:keypair $script:SG -InstanceType 't3.large' -VersionText $VersionText

        $Script:vmname="Bake $Script:instancename"

    } elseif ($Cloud -eq 'Azure' ) {
        #Import-Module Az
        $imageObj = @()
        $Location = "Australia East"
        $Publisher = "MicrosoftWindowsServer"
        $Offer = "windowsserver"
        $ImageObj = Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -SKU $AmazonAMIName | Sort-Object -Descending Version

        if ( $imageObj ) {
            $imageObj[0]  | Out-Default | Write-Host
        } else {
            throw "Image not found"  | Out-Default | Write-Host
        }

        $subscription = "Visual Studio Enterprise with MSDN"

        # used for KeyVault and the images
        $KeyVaultResourceGroup = "BakingDP"
        $ImageResourceGroup = $KeyVaultResourceGroup
        $StorageAccountName = 'stagingdpauseast'
        $StorageAccountResourceGroup = $ImageResourceGroup
        $StorageContainer = "vhds"

        # use a separate resource group for easier deletion
        $VmResourceGroup = "BakingDP-$VersionText"

        # Create or update the resource group using the specified parameter
        New-AzResourceGroup -Name $VmResourceGroup -Location $Location -Verbose -Force -ErrorAction Stop | Out-Default | Write-Host

        # Create and use the Storage Account in the VM Resource Group
        if ($AtomicBuild) {
            # Storage account name must be between 3 and 24 characters in length and use numbers and lower-case letters only.
            $StorageAccountName = ("stagingdp$VersionText" -replace "\W").ToLower()

            # Sets the storage account to use the updated resource group
            $StorageAccountResourceGroup = $VmResourceGroup

            # Sets the image resource group
            $ImageResourceGroup = $VmResourceGroup

            # Create or update the storage account using the specified parameter
            $templateUri = "$(Split-Path -Parent $script:IncludeDir)\ARM\storage-account\stagingdp.json"
            New-AzResourceGroupDeployment -ResourceGroupName $StorageAccountResourceGroup -TemplateFile $templateUri -TemplateParameterObject @{name = $StorageAccountName} | Out-Default | Write-Host
        }

        $vmsize="Standard_B4ms"
        $Script:password = "Pcxuser@122"
        $AdminUserName = "lansa"
        $Script:vmname = $VersionText
        $publicDNSName = "bakingpublicdnsDP-$($Script:vmname)"

        if ( $CreateVM -and -not $OnlySaveImage) {
            Write-Host "$(Log-Date) Delete VM if it already exists"

            . "$script:IncludeDir\Remove-AzrVirtualMachine.ps1"
            Remove-AzrVirtualMachine -Name $Script:vmname -ResourceGroupName $VmResourceGroup -Wait

            # Add code to remove the .VHD Blob if exists from the Storage Container
            $StorageAccountObject = Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -Name $StorageAccountName
            Write-Host "Remove Blob if exists: $Script:vmname.vhd from the Container $StorageContainer in $StorageAccountResourceGroup/$StorageAccountName" | Out-Default
            if ($StorageAccountObject | Get-AzStorageBlob -Container $StorageContainer | where-object {$_.Name -eq "$Script:vmname.vhd"}) {
                Write-Host "Deleting the Blob $Script:vmname.vhd" | Out-Default
                $StorageAccountObject | Remove-AzStorageBlob -Blob "$Script:vmname.vhd" -Container $StorageContainer | Out-Default | Write-Host
                Write-Host "Deleted the Blob $Script:vmname.vhd successfully" | Out-Default
            } else {
                Write-Host "The Blob $Script:vmname.vhd doesn't exists" | Out-Default
            }
        }

        Write-Host "$(Log-Date) Create VM"
        $SecurePassword = ConvertTo-SecureString $Script:password -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential ($AdminUserName, $SecurePassword);

        $NicName = "bakingNic-$($Script:vmname)"
        $nic = Get-AzNetworkInterface -Name $NicName -ResourceGroupName $VmResourceGroup -ErrorAction SilentlyContinue
        if ( $null -eq $nic ) {
            Write-Host "$(Log-Date) Create NIC"

            $AzVirtualNetworkSubnetConfigName = "bakingSubnet-$($Script:vmname)"
            $AzVirtualNetworkName = "bakingvNET-$($Script:vmname)"
            $AzNetworkSecurityGroupRuleRDPName = "RDPRule-$($Script:vmname)"
            $AzNetworkSecurityGroupRuleWinRMHttpName = "WinRMHttpRule-$($Script:vmname)"
            $AzNetworkSecurityGroupRuleWinRMHttpsName = "WinRMHttpsRule-$($Script:vmname)"
            $AzNetworkSecurityGroupName = "bakingNSG-$($Script:vmname)"

            # Create a subnet configuration
            Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
            $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $AzVirtualNetworkSubnetConfigName -AddressPrefix 192.168.1.0/24

            # Create a virtual network
            $vnet = New-AzVirtualNetwork -ResourceGroupName $VmResourceGroup -Location $location -Name $AzVirtualNetworkName -AddressPrefix 192.168.0.0/16 -Subnet $subnetConfig -Force

            # Create a public IP address and specify a DNS name
            $pip = New-AzPublicIpAddress -ResourceGroupName $VmResourceGroup -Location $location -Name $publicDNSName -AllocationMethod Static -IdleTimeoutInMinutes 4 -Force

            # Create an inbound network security group rule for port 3389
            $nsgRuleRDP = New-AzNetworkSecurityRuleConfig -Name $AzNetworkSecurityGroupRuleRDPName  -Protocol Tcp `
            -Direction Inbound -Priority 1000 -SourceAddressPrefix $externalip -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 3389 -Access Allow

            # Create an inbound network security group rule for port 5985
            $nsgRuleWinRMHttp = New-AzNetworkSecurityRuleConfig -Name $AzNetworkSecurityGroupRuleWinRMHttpName  -Protocol Tcp `
            -Direction Inbound -Priority 1010 -SourceAddressPrefix $externalip -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 5985 -Access Allow

            # Create an inbound network security group rule for port 5986
            $nsgRuleWinRMHttps = New-AzNetworkSecurityRuleConfig -Name $AzNetworkSecurityGroupRuleWinRMHttpsName  -Protocol Tcp `
            -Direction Inbound -Priority 1020 -SourceAddressPrefix $externalip -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 5986 -Access Allow

            # Create a network security group
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $VmResourceGroup -Location $location `
            -Name $AzNetworkSecurityGroupName -SecurityRules $nsgRuleRDP, $nsgRuleWinRMHttp, $nsgRuleWinRMHttps -Force

            # Create a virtual network card and associate with public IP address and NSG
            $nic = New-AzNetworkInterface -Name $NicName -ResourceGroupName $VmResourceGroup -Location $location `
            -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id
        }

        $KeyVault = "bakingVaultDP"
        $certificateName = "bakingWinRMCertificate"
        $secret = Get-AzKeyVaultSecret -VaultName $KeyVault -Name $certificateName
        if ( $secret ) {
            $SecretURL = $secret.id
        } else {
            Write-Host "$(Log-Date) Create WinRM Certificate"

            $thumbprint = (New-SelfSignedCertificate -DnsName $certificateName -CertStoreLocation Cert:\CurrentUser\My -KeySpec KeyExchange).Thumbprint

            $cert = (Get-ChildItem -Path cert:\CurrentUser\My\$thumbprint)

            $fileName = ".\$certificateName.pfx"
            Export-PfxCertificate -Cert $cert -FilePath $fileName -Password $SecurePassword

            $fileContentBytes = Get-Content $fileName -Encoding Byte
            $fileContentEncoded = [System.Convert]::ToBase64String($fileContentBytes)

$jsonObject = @"
{
"data" : "$filecontentencoded",
"dataType" :"pfx",
"password": "$Script:password"
}
"@

            $jsonObjectBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonObject)
            $jsonEncoded = [System.Convert]::ToBase64String($jsonObjectBytes)

            $secret = ConvertTo-SecureString -String $jsonEncoded -AsPlainText –Force
            $secretURL = (Set-AzKeyVaultSecret -VaultName $KeyVault -Name $certificateName -SecretValue $secret).Id
        }

        # 163204: Gets the secrets (IntegratorLicensePrivateKey, ScalableLicensePrivateKey) from Azure Vault
        $vmSecrets = @("IntegratorLicensePrivateKey", "ScalableLicensePrivateKey");
        $vmSecretUrls = @();
        foreach ($vmCertificateName in $vmSecrets) {
            $secret = Get-AzKeyVaultSecret -VaultName $KeyVault -Name $vmCertificateName
            if ( $secret ) {
                # Write to a file
                Write-Host "$(Log-Date) Found the secret for $vmCertificateName Certificate"
                $vmSecretUrls += $secret.id;
            } else {
                throw 'Certificate $vmCertificateName not found in the Key Vault $KeyVault'
            }
        }

        if ( $CreateVM -and -not $OnlySaveImage) {
            $sourceVaultId = (Get-AzKeyVault -ResourceGroupName $KeyVaultResourceGroup -VaultName $KeyVault).ResourceId

            $vm1 = New-AzVMConfig -VMName $Script:vmname -VMSize $vmsize
            $vm1 = Set-AzVMOperatingSystem -VM $vm1 -Windows -ComputerName $vmName -Credential $credential -WinRMHttp -WinRMHttps -WinRMCertificateUrl $SecretURL -ProvisionVMAgent
            $vm1 = Set-AzVMSourceImage -VM $vm1 -PublisherName $Publisher -Offer $Offer -SKU $AmazonAMIName -Version latest
            $vm1 = Add-AzVMNetworkInterface -VM $vm1 -Id $nic.Id
            $vm1 = Add-AzVMSecret -VM $vm1 -SourceVaultId $sourceVaultId -CertificateStore 'My' -CertificateUrl $secretURL

            # 163204: Adds the secrets (IntegratorLicensePrivateKey, ScalableLicensePrivateKey) to VM
            foreach ($vmSecret in $vmSecretUrls) {
                $vm1 = Add-AzVMSecret -VM $vm1 -SourceVaultId $sourceVaultId -CertificateStore 'My' -CertificateUrl $vmSecret
            }

            $vm1 = Set-AzVMOSDisk -VM $vm1 -Name "$Script:vmname" -VhdUri "https://$($StorageAccountName).blob.core.windows.net/$StorageContainer/$($Script:vmname).vhd" -CreateOption FromImage

            try {
                New-AZVM -ResourceGroupName $VmResourceGroup -VM $vm1 -Verbose -Location $Location -ErrorAction Stop
            } catch {
                Write-YellowOutput $_ | Out-Default | Write-Host
                if ($_.Exception.Message -contains "OS Provisioning") {
                    Write-Host "Retrying the New-AZVM command for OSProvisioningTimedOut"
                    # Retry the New-AZVM operation
                    New-AZVM -ResourceGroupName $VmResourceGroup -VM $vm1 -Verbose -Location $Location -ErrorAction Stop
                } else {
                    throw $_.Exception
                }
            }
        }

        $ipAddress = Get-AzPublicIpAddress -Name $publicDNSName
        # $uri = $ipAddress.IpAddress
        $Script:publicDNS =  $ipAddress.IpAddress
    }

    if ( -not $OnlySaveImage ) {
        # Remote PowerShell
        Write-Host( "$(Log-Date) User Id:$AdminUserName Password: $Script:password")
        $securepassword = ConvertTo-SecureString $Script:password -AsPlainText -Force
        $creds = New-Object System.Management.Automation.PSCredential ($AdminUserName, $securepassword)
        Connect-RemoteSession

        # Simple test of session:
        # Invoke-Command -Session $Script:session {(Invoke-WebRequest http://169.254.169.254/latest/user-data).RawContent}

        Invoke-Command -Session $Script:session {Set-ExecutionPolicy Unrestricted -Scope CurrentUser}
        $remotelastexitcode = invoke-command  -Session $Script:session -ScriptBlock { $lastexitcode}
        if ( $remotelastexitcode -and $remotelastexitcode -ne 0 ) {
            Write-Error "LastExitCode: $remotelastexitcode"
            throw 1
        }

        # Setup fundamental variables in remote session

        Execute-RemoteInit

        Write-Host( "Platform = $platform")
        Execute-RemoteBlock $Script:session {
            try {
                Write-Host ("Save S3 DVD image url and other global variables in registry")
                $lansaKey = 'HKLM:\Software\LANSA\'
                if (!(Test-Path -Path $lansaKey)) {
                    New-Item -Path $lansaKey | Out-Default | Write-Host
                }

                New-ItemProperty -Path $lansaKey  -Name 'GitBranch' -PropertyType String -Value $using:GitBranch -Force | Out-Default | Write-Host
                New-ItemProperty -Path $lansaKey  -Name 'VersionText' -PropertyType String -Value $using:VersionText -Force | Out-Default | Write-Host
                New-ItemProperty -Path $lansaKey  -Name 'VersionMajor' -PropertyType DWord -Value $using:VersionMajor -Force | Out-Default | Write-Host
                New-ItemProperty -Path $lansaKey  -Name 'VersionMinor' -PropertyType DWord -Value $using:VersionMinor -Force | Out-Default | Write-Host
                New-ItemProperty -Path $lansaKey  -Name 'Language' -PropertyType String -Value $using:Language -Force | Out-Default | Write-Host
                New-ItemProperty -Path $lansaKey  -Name 'Platform' -PropertyType String -Value $using:Platform -Force | Out-Default | Write-Host

            } catch {
                Write-RedOutput $_ | Out-Default | Write-Host
                Write-RedOutput $PSItem.ScriptStackTrace | Out-Default | Write-Host
                throw 'Script Block 10'
            }
            # Ensure last exit code is 0. (exit by itself will terminate the remote session)
            cmd /c exit 0
        }

        # Load up some required tools into remote environment

        # Load basic utils before running anything
        Execute-RemoteScript -Session $Script:session -FilePath "$script:IncludeDir\dot-CommonTools.ps1"

        if ( $InstallBaseSoftware ) {

            # Install Chocolatey

            Execute-RemoteScript -Session $Script:session -FilePath "$script:IncludeDir\getchoco.ps1"

            # Then we install git using chocolatey and pull down the rest of the files from git

            Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\installGit.ps1 -ArgumentList  @($Script:GitRepo, $Script:GitRepoPath, $GitBranch, $GitUserName, $true)

            Execute-RemoteBlock $Script:session { "Path = $([Environment]::GetEnvironmentVariable('PATH', 'Machine'))" | Out-Default | Write-Host }

            # Load utilities into Remote Session.
            # Requires the git repo to be pulled down so the scripts are present and the script variables initialised with Init-Baking-Vars.ps1.
            # Reflect local variables into remote session
            Execute-RemoteInitPostGit

            # Upload files that are not in Git. Should be limited to secure files that must not be in Git.
            # Git is a far faster mechansim for transferring files than using RemotePS.
            # From now on we may execute scripts which rely on other scripts to be present from the LANSA Cookbooks git repo

            #####################################################################################

            if ( $Cloud -eq 'AWS' ) {
                # Run-SSMCommand -InstanceId @($instanceid) -DocumentName AWS-RunPowerShellScript -Comment 'Explicitly updating SSM Agent'
                Run-SSMCommand -InstanceId @($instanceid) -DocumentName AWS-RunPowerShellScript -Comment 'Installing workarounds' -Parameter @{'commands'=@("c:\lansa\scripts\install-base-sql-server.ps1")}
            } else {
                Write-Host "$(Log-Date) workaround which must be done before Chef is installed. Has to be run through RDP too!"
                Write-Host "$(Log-Date) also, workaround for x_err.log 'Code=800703fa. Code meaning=Illegal operation attempted on a registry key that has been marked for deletion.' Application Event Log warning 1530 "
                # Cmdlet to remotely execute the script install-base-sql-server.ps1
                Invoke-AzVMRunCommand -ResourceGroupName $VmResourceGroup -Name $Script:vmname -CommandId 'RunPowerShellScript' -ScriptPath "$script:IncludeDir\install-base-sql-server.ps1" | Out-Default | Write-Host
            }

            #####################################################################################
            Write-Host "$(Log-Date) Installing base software"
            #####################################################################################

            if ( $Cloud -eq 'AWS' ) {
                $ChefRecipe = "VLWebServer::IDEBase"
            } elseif ($Cloud -eq 'Azure' ) {
                $ChefRecipe = "VLWebServer::IDEBaseAzure"
            }

            # Make sure the session is initialised correctly
            ReConnect-Session

            Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-base.ps1 -ArgumentList  @($Script:GitRepoPath, $Script:LicenseKeyPath, $script:licensekeypassword, $ChefRecipe )

        if ( $InstallScalable ) {

            if ( -not $Win2012 ) {
                Write-Host( "$(Log-Date) Exclude LANSA directories from Windows Defender. Up to 25% CPU usage on t2.medium AWS instance" )
                Write-Host( "$(Log-Date) Only Windows 2016 because the api requires powershell 5.x" )
                Execute-RemoteBlock $Script:session {
                    Add-MpPreference -ExclusionPath ("${ENV:ProgramFiles(x86)}\Lansa","${ENV:ProgramFiles(x86)}\webserver","${ENV:ProgramFiles(x86)}\app1","${ENV:ProgramFiles(x86)}\app2","${ENV:ProgramFiles(x86)}\app3","${ENV:ProgramFiles(x86)}\app4","${ENV:ProgramFiles(x86)}\app5","${ENV:ProgramFiles(x86)}\app6","${ENV:ProgramFiles(x86)}\app7","${ENV:ProgramFiles(x86)}\app8","${ENV:ProgramFiles(x86)}\app9","${ENV:ProgramFiles(x86)}\app10")
                }
            }
        }

        } else {
            Execute-RemoteInitPostGit

            Execute-RemoteBlock $Script:session {
                Write-Host "$(Log-Date) Refreshing git tools repo"
                # Ensure we cope with an existing repo, not just a new clone...
                cd $using:GitRepoPath
                # Throw away any working directory changes
                cmd /c git reset --hard HEAD '2>&1'
                # Ensure we have all changes
                cmd /c git fetch --all '2>&1'
                # Check out a potentially different branch
                Write-Host "Branch: $using:GitBranch"
                # Check out ORIGINs correct branch so we can then FORCE checkout of potentially an existing, but rebased branch
                cmd /c git checkout "origin/$using:GitBranch"  '2>&1'
                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 128)
                {
                    throw 'Git checkout failed'
                }
                # Overwrite the origin's current tree onto the branch we really want - the local branch
                cmd /c git checkout -B $using:GitBranch  '2>&1'
                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 128)
                {
                    throw 'Git checkout failed'
                }
            }
        }

        ReConnect-Session

        Execute-RemoteBlock $Script:session {
            SyncRegistryPathToCurentProcess

            # Ensure last exit code is 0. (exit by itself will terminate the remote session)
            cmd /c exit 0
        }

        if ( $InstallSQLServer ) {
            #####################################################################################
            Write-Host "$(Log-Date) Install SQL Server. (Remote execution does not work)"
            #####################################################################################
            $dummy = MessageBox "Run install-sql-server.ps1. Please RDP into $Script:vmname $Script:publicDNS as $AdminUserName using password '$Script:password'. When complete, click OK on this message box" -Pipeline:$Pipeline

            #####################################################################################
            Write-Host "$(Log-Date) Rebooting to ensure the newly installed DesktopExperience feature is ready to have Windows Updates run"
            #####################################################################################
            Execute-RemoteBlock $Script:session {
                Write-Host "$(Log-Date) Restart Required - Restarting..."
                Restart-Computer -Force

                # Ensure last exit code is 0. (exit by itself will terminate the remote session)
                cmd /c exit 0
            }

            # Session has been lost due to a Windows reboot
            if ( -not $Script:session -or ($Script:session.State -ne 'Opened') )
            {
                Write-Host "$(Log-Date) Session lost or not open. Reconnecting..."
                if ( $Script:session ) { Remove-PSSession $Script:session }

                Connect-RemoteSession
                Execute-RemoteInit
                Execute-RemoteInitPostGit
            }
        }

        ReConnect-Session

        $dummy = MessageBox "Configure JPN VM. Please RDP into $Script:vmname $Script:publicDNS as $AdminUserName using password '$Script:password'. When complete, click OK on this message box"

        # ****************** Put JPN configuration code here **************
        # E.g. Windows language pack & locale
        # https://dev.classmethod.jp/articles/windowsserver2019_to_japanese/
        # *****************************************************************

        # No harm installing this again if its already installed
        if ( $InstallIDE -eq $true) {
            if ( $Win2012 ) {
                Write-Host "$(Log-Date) Run choco install jdk8 -y. No idea why it fails to run remotely!"
                Write-Host "$(Log-Date) Maybe due to jre8 404? Give it a go when next build IDE"

                if ( $Cloud -eq 'AWS' ) {
                    Run-SSMCommand -InstanceId @($instanceid) -DocumentName AWS-RunPowerShellScript -Comment 'Installing JDK' -Parameter @{'commands'=@("choco install jdk8 -y")}
                } else {
                    $dummy = MessageBox "Try changing this to automatically running Windows Updates in Azure? (now that we re-create the session for each script)" -Pipeline:$Pipeline
                    $dummy = MessageBox "Run choco install jdk8 -y manually. Please RDP into $Script:vmname $Script:publicDNS as $AdminUserName using password '$Script:password'. When complete, click OK on this message box" -Pipeline:$Pipeline
                }
            } else {
                Execute-RemoteBlock $Script:session {
                    Run-ExitCode 'choco' @('install', 'jdk8', '-y', '--no-progress')
                }
            }
        }

        if ( !$SkipSlowStuff -and $RunWindowsUpdates ) {
            if ( $Cloud -eq 'AWS' ) {
                # Windows Updates can take quite a while to run if there are multiple re-boots, so set timeout to 1 hour
                Run-SSMCommand -InstanceId $instanceid -DocumentName AWS-InstallWindowsUpdates -TimeoutSecond 3600 -Sleep 10 -Comment 'Run Windows Updates' -Parameter @{'Action'='Install'}
                Write-Host "$(Log-Date) Windows Updates complete"
            }
        }

        if ( $ManualWinUpd ) {
            $dummy = MessageBox "Manually install Windows updates e.g. http://www.catalog.update.microsoft.com/Search.aspx?q=KB4346877" -Pipeline:$Pipeline
        }

        ReConnect-Session

        if ( $InstallIDE -eq $true ) {

            if ($Cloud -eq 'AWS') {
                #####################################################################################
                Write-Host "$(Log-Date) Installing License"
                #####################################################################################

                Send-RemotingFile $Script:session "$Script:LicenseKeyPath\LANSADevelopmentLicense.pfx" "$Script:LicenseKeyPath\LANSADevelopmentLicense.pfx" | Write-Host
                Send-RemotingFile $Script:session "$Script:LicenseKeyPath\LANSAIntegratorLicense.pfx" "$Script:LicenseKeyPath\LANSAIntegratorLicense.pfx" | Write-Host
            }
            Execute-RemoteBlock $Script:session {
                CreateLicence "$Script:LicenseKeyPath\LANSADevelopmentLicense.pfx" $Using:LicenseKeyPassword "LANSA Development License" "DevelopmentLicensePrivateKey"
                CreateLicence "$Script:LicenseKeyPath\LANSAIntegratorLicense.pfx" $Using:LicenseKeyPassword "LANSA Integrator License" "IntegratorLicensePrivateKey"
                # Errors are thrown out of CreateLicense so no need to catch a throw here.
                # Let the local script catch it
            }

            Execute-RemoteBlock $Script:session {
                try {
                    Test-RegKeyValueIsNotNull 'DevelopmentLicensePrivateKey'
                    Test-RegKeyValueIsNotNull 'IntegratorLicensePrivateKey'
                } catch {
                    Write-RedOutput "Test-RegKeyValueIsNotNull script block in bake-ide-ami.ps1 is the <No file> in the stack dump below" | Out-Default | Write-Host
                    Write-RedOutput $_ | Out-Default | Write-Host
                    Write-RedOutput $PSItem.ScriptStackTrace | Out-Default | Write-Host
                    cmd /c exit 1
                    throw
                }
            }

            Write-Host "$(Log-Date) Installing IDE"
            PlaySound


            if ( $Upgrade -eq $false ) {
                Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-ide.ps1
            } else {
                # Need to pass a single parameter (UPGD) which seems to be extremely complicated when you have the script in a file like we have here.
                # So the simple solution is to use a script block which means the path to the script provided here is relative to the REMOTE system
                Invoke-Command -Session $Script:session {
                    $lastexitcode = 0

                    c:\lansa\scripts\install-lansa-ide.ps1 -UPGD 'true' -Wait 'false'
                } -ArgumentList 'true'

                $remotelastexitcode = invoke-command  -Session $session -ScriptBlock { $lastexitcode}
                if ( $remotelastexitcode -and $remotelastexitcode -ne 0 ) {
                    Write-Error "LastExitCode: $remotelastexitcode"
                    throw 1
                }
            }
        }

        # if ( $InstallScalable -eq $true ) {

        #     # Must run install-lansa-scalable.ps1 after Windows Updates as it sets RunOnce after which you must not reboot.
        #     Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-scalable.ps1 -ArgumentList  @($Script:GitRepoPath, $Script:LicenseKeyPath)

        #     Write-Host "Test that keys are configured"

        #     Execute-RemoteBlock $Script:session {
        #         try {
        #             Test-RegKeyValueIsNotNull 'ScalableLicensePrivateKey'
        #             Test-RegKeyValueIsNotNull 'IntegratorLicensePrivateKey'
        #         } catch {
        #             Write-RedOutput "Test-RegKeyValueIsNotNull script block in bake-ide-ami.ps1 is the <No file> in the stack dump below" | Out-Default | Write-Host
        #             Write-RedOutput $_ | Out-Default | Write-Host
        #             Write-RedOutput $PSItem.ScriptStackTrace | Out-Default | Write-Host
        #             cmd /c exit 1
        #             throw
        #         }
        #     }
        # }

        # Re-create Session which may have been lost due to a Windows reboot, and do it anyway so its a clean session with output working
        ReConnect-Session

        if ( $false ) {
            Write-Host "$(Log-Date) Completing installation steps, except for sysprep"
            Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-post-winupdates.ps1 -ArgumentList  @($Script:GitRepoPath, $Script:LicenseKeyPath )

            if ( $InstallIDE -or ($InstallSQLServer -eq -$false) ) {
                Invoke-Command -Session $Script:session {
                    Write-Host "$(Log-Date) Switch Internet download security warning back on"
                    [Environment]::SetEnvironmentVariable('SEE_MASK_NOZONECHECKS', '0', 'Machine') | Out-Default | Write-Host
                    # Set-ExecutionPolicy restricted -Scope CurrentUser
                }
            }
        }

        if ( $InstallIDE -eq $true ) {
            Write-Host "Test that license keys are still configured"
            Execute-RemoteBlock $Script:session {
                try {
                    Test-RegKeyValueIsNotNull 'DevelopmentLicensePrivateKey'
                    Test-RegKeyValueIsNotNull 'IntegratorLicensePrivateKey'
                } catch {
                    Write-RedOutput "Test-RegKeyValueIsNotNull script block in bake-ide-ami.ps1 is the <No file> in the stack dump below" | Out-Default | Write-Host
                    Write-RedOutput $_ | Out-Default | Write-Host
                    Write-RedOutput $PSItem.ScriptStackTrace | Out-Default | Write-Host
                    cmd /c exit 1
                    throw
                }
            }
        }

        ReConnect-Session

        Write-Host "$(Log-Date) Sysprep"
        Write-Host "Use Invoke-Command as the Sysprep will terminate the instance and thus Execute-RemoteBlock will return a fatal error"

        try {
            if ( $Cloud -eq 'AWS' ) {
                if ( $Win2012 ) {
                    Write-Host "$(Log-Date) AWS sysprep for Win2012"
                    Invoke-Command -Session $Script:session {cmd /c "$ENV:ProgramFiles\Amazon\Ec2ConfigService\ec2config.exe" -sysprep  | Out-Default | Write-Host}
                } else {
                    Write-Host "$(Log-Date) AWS sysprep for Win2016+"
                    # See here for doco - http://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2launch.html
                    Invoke-Command -Session $Script:session {
                        Set-Location "$env:SystemRoot\panther"  | Out-Default | Write-Host;
                        $filename = "unattend.xml"
                        if (Test-Path $filename)
                        {
                            Write-Host( "$(Log-Date) Deleting $filename")
                            Remove-Item $filename | Out-Default | Write-Host;
                        }
                        $filename = "WaSetup.xml"
                        if (Test-Path $filename )
                        {
                            Write-Host( "$(Log-Date) Deleting $filename")
                            Remove-Item $filename | Out-Default | Write-Host;
                        }
                    }
                    Invoke-Command -Session $Script:session {cd $ENV:ProgramData\Amazon\EC2-Windows\Launch\Scripts | Out-Default | Write-Host}
                    Invoke-Command -Session $Script:session {./InitializeInstance.ps1 -Schedule | Out-Default | Write-Host}
                    Invoke-Command -Session $Script:session {./SysprepInstance.ps1 | Out-Default | Write-Host}
                }
            } elseif ($Cloud -eq 'Azure' ) {
                Write-Host( "$(Log-Date) Running sysprep automatically")

                Invoke-Command -Session $Script:session {
                    Set-Location "$env:SystemRoot\panther"  | Out-Default | Write-Host;
                    $filename = "unattend.xml"
                    if (Test-Path $filename)
                    {
                        Write-Host( "$(Log-Date) Deleting $filename")
                        Remove-Item $filename | Out-Default | Write-Host;
                    }
                    $filename = "WaSetup.xml"
                    if (Test-Path $filename )
                    {
                        Write-Host( "$(Log-Date) Deleting $filename")
                        Remove-Item $filename | Out-Default | Write-Host;
                    }
                    Set-Location "$env:SystemRoot\system32\sysprep"  | Out-Default | Write-Host;
                    cmd /c sysprep /oobe /generalize /shutdown | Out-Default | Write-Host;
                }
            }
        } catch {
            Write-RedOutput $_ | Out-Default | Write-Host
            $Response = MessageBox "Do you want to continue building the image?" 0x3 -Pipeline:$Pipeline
            $Response
            if ( $response -ne 0x6 ) {
                throw "Sysprep script failure"
            }
        }

    } # if -not $OnlySaveImage

    # Sysprep will stop the Instance

    Write-Host( "$(Log-Date) Wait for the instance state to be stopped...")

    if ( $Cloud -eq 'Azure' ) {
        Wait-AzureVMState $VmResourceGroup $Script:vmname "not running"

        # There was a defect whereby the registry state of the image ended up as IMAGE_STATE_COMPLETE.
        # It should be IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE.
        # And this value should be in the registry HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State).ImageState
        # and in the file state.ini
        # This was presumed to be caused by terminating the VM too soon. The fact Azure reports it is not running is not sufficient.
        # Must wait until its not possible to invoke a command on the VM
        try {
            while ($true) {
                Write-Host "$(Log-Date) (from Host) Waiting for VM to be fully stopped..."
                Start-Sleep -Seconds 5
                Invoke-Command -Session $Script:session {
                    Write-Host "$(Log-Date) (from VM) VM is still running..."
                }
            }
        } catch {
            # A failure to execute the log message on the VM is presumed to indicate that the VM is fully stopped and the image may be taken.
            Write-Host "$(Log-Date) VM has fully stopped"
        }
        Remove-PSSession $Script:session | Out-Default | Write-Host

        Write-Host "$(Log-Date) Starting Azure Image Creation"

        Write-Host "$(Log-Date) Delete image if it already exists"
        $ImageName = "$($VersionText)image"
        Get-AzImage -ResourceGroupName $ImageResourceGroup -ImageName $ImageName -ErrorAction SilentlyContinue | Remove-AzImage -Force -ErrorAction SilentlyContinue | Out-Default | Write-Host

        Write-Host "$(Log-Date) Terminating VM..."
        Stop-AzVM -ResourceGroupName $VmResourceGroup -Name $Script:vmname -Force | Out-Default | Write-Host

        Write-Host "$(Log-Date) Creating Actual Image..."
        Set-AzVM -ResourceGroupName $VmResourceGroup -Name $Script:vmname -Generalized | Out-Default | Write-Host
        $vm = Get-AzVM -ResourceGroupName $VmResourceGroup -Name $Script:vmname
        $image = New-AzImageConfig -Location $location -SourceVirtualMachineId $vm.Id

        New-AzImage -ResourceGroupName $ImageResourceGroup -Image $image -ImageName $ImageName | Out-Default | Write-Host

        Write-Host "$(Log-Date) Obtaining signed url for submission to Azure Marketplace"
        .$script:IncludeDir\get-azure-sas-token.ps1 -ResourceGroupName $ImageResourceGroup -ImageName $ImageName -StorageAccountName $StorageAccountName -StorageAccountResourceGroup $StorageAccountResourceGroup | Out-Default | Write-Host

    } elseif ($Cloud -eq 'AWS') {
        # Wait for the instance state to be stopped.

        Wait-EC2State $instanceid "Stopped" -timeout 180 | Out-Default | Write-Host     # Should take 40 seconds or less to stop

        # Refer to Azure code above as to why this is necessary for Azure. It may make a difference for the failures we see in AWS too.
        try {
            while ($true) {
                Write-Host "$(Log-Date) (from Host) Waiting for VM to be fully stopped..."
                Start-Sleep -Seconds 5
                Invoke-Command -Session $Script:session {
                    Write-Host "$(Log-Date) (from VM) VM is still running..."
                }
            }
        } catch {
            # A failure to execute the log message on the VM is presumed to indicate that the VM is fully stopped and the image may be taken.
            Write-Host "$(Log-Date) VM has fully stopped"
        }
        Remove-PSSession $Script:session | Out-Default | Write-Host

        Write-Host "$(Log-Date) Creating AMI"

        # Updates already have LANSA-appended text so strip it off if its there
        $SimpleDesc = $($AmazonImage[0].Description)
        $Index = $SimpleDesc.IndexOf( "created on" )
        if ( $index -eq -1 ) {
            $FinalDescription = $SimpleDesc
        } else {
            $FinalDescription = $SimpleDesc.substring( 0, $index - 1 )
        }

        $TagDesc = "$FinalDescription created on $($AmazonImage[0].CreationDate) with LANSA $VersionText installed on $(Log-Date)"
        $AmiName = "$Script:DialogTitle $VersionText $(Get-Date -format "yyyy-MM-ddTHH-mm-ss") $Platform"     # AMI ID must not contain colons
        $amiID = New-EC2Image -InstanceId $Script:instanceid -Name $amiName -Description $TagDesc

        $tagName = $amiName # String for use with the name TAG -- as opposed to the AMI name, which is something else and set in New-EC2Image

        New-EC2Tag -Resources $amiID -Tags @{ Key = "Name" ; Value = $amiName} # Add tags to new AMI | Out-Default | Write-Host

        while ( $true )
        {
            Write-Host "$(Log-Date) Waiting for AMI to become available"
            $amiProperties = Get-EC2Image -ImageIds $amiID

            if ( $amiProperties.ImageState -eq "available" )
            {
                break
            }
            Sleep -Seconds 10
        }
        Write-Host "$(Log-Date) AMI $amiID is available"
        if($Pipeline) {
            Write-Host "##vso[task.setvariable variable=instanceID;isOutput=true]$instanceid"
            Write-Host "##vso[task.setvariable variable=amiID;isOutput=true]$amiID"
        }

        # Add tags to snapshots associated with the AMI using Amazon.EC2.Model.EbsBlockDevice

        $amiBlockDeviceMapping = $amiProperties.BlockDeviceMapping # Get Amazon.Ec2.Model.BlockDeviceMapping
        $amiBlockDeviceMapping.ebs | `
        ForEach-Object -Process {
            if ( $_ -and $_.SnapshotID )
            {
                New-EC2Tag -Resources $_.SnapshotID -Tags @( @{ Key = "Name" ; Value = $tagName}, @{ Key = "Description"; Value = $tagDesc } )
            }
        }

        Write-Host( "$(Log-Date) Terminating VM")
        Remove-EC2Instance -InstanceId $instanceid -Force | Out-Default | Write-Host
        Wait-EC2State $instanceid "Terminated"
    }

    # $dummy = MessageBox "Image bake successful" 0 -Pipeline:$Pipeline
    return "Success"
}
catch
{
    . "$Script:IncludeDir\dot-catch-block.ps1"

    Write-Host 'Tidying up'
    if ( Test-Path variable:Script:session ) {
        Remove-PSSession $Script:session | Out-Default | Write-Host
    }

    $dummy = MessageBox "Image bake failed. Fatal error has occurred. Click OK and look at the console log" 0 -Pipeline:$Pipeline

    # Fail the build on exception
    if ($Pipeline) {
        #In AWS, if image bake fails , retry functionality is implemented. So failed instance need  to be removed
        if($Cloud -eq 'AWS'){
            Remove-EC2Instance -InstanceId $instanceid -Force
            Start-Sleep -Seconds 150
        }
        throw $_.Exception
    }
    return "Failure"# 'Return' not 'throw' so any output thats still in the pipeline is piped to the console
}

}

# Setup default account details
# This code is rarely required and is more for documentation.
function SetUpAccount {
    # Subscription Name was rejected by Select-AzureSubscription so Subscription Id was used instead.
    $subscription = "edff5157-5735-4ceb-af94-526e2c235e80"
    $Storage = "lansalpcmsdn"
    Select-AzureSubscription -SubscriptionId $subscription
    set-AzureSubscription -SubscriptionId $subscription -CurrentStorageAccount $Storage
}

