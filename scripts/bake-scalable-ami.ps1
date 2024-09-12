﻿<#
.SYNOPSIS

Bake a LANSA AMI

.DESCRIPTION

.EXAMPLE


#>

function bake-ScalableMsi {
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
    $AmazonAMIName,

    [Parameter(Mandatory=$true)]
    [string]
    $GitBranch,

    [Parameter(Mandatory=$false)]
    [string]
    $Cloud='AWS'
    )

# set up environment if not yet setup
if ( -not $script:IncludeDir)
{
    # Log-Date can't be used yet as Framework has not been loaded

	Write-Output "Initialising environment - presumed not running through RemotePS"
	$MyInvocation.MyCommand.Path
	$script:IncludeDir = Split-Path -Parent $MyInvocation.MyCommand.Path

	. "$script:IncludeDir\Init-Baking-Vars.ps1"
	. "$script:IncludeDir\Init-Baking-Includes.ps1"
}
else
{
	Write-Output "$(Log-Date) Environment already initialised"
}

###############################################################################
# Main program logic
###############################################################################

Set-StrictMode -Version Latest

$script:instancename = "LANSA Scalable License $VersionText installed on $(Log-Date)"
$Script:DialogTitle = "LANSA Scalable License "

try
{
    # Use Forms for a MessageBox
    [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | out-null

    Create-Ec2SecurityGroup

    # First image found is presumed to be the latest image.
    # Force it into a list so that if one image is returned the variable may be used identically.

    $AmazonImage = @(Get-EC2ImageByName $AmazonAMIName | Sort-Object CreationDate -Descending)
    $ImageName = $AmazonImage[0].Name
    $Script:Imageid = $AmazonImage[0].ImageId
    Write-Output "$(Log-Date) Using Base Image $ImageName $Script:ImageId"

    Create-EC2Instance $Script:Imageid $script:keypair $script:SG

    # Remote PowerShell

    $securepassword = ConvertTo-SecureString $Script:password -AsPlainText -Force
    $creds = New-Object System.Management.Automation.PSCredential ("Administrator", $securepassword)

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

    Execute-RemoteBlock $Script:session {  

        Write-Verbose ("Save S3 DVD image url and other global variables in registry")
        $lansaKey = 'HKLM:\Software\LANSA\'
        if (!(Test-Path -Path $lansaKey)) {
            New-Item -Path $lansaKey
        }
        New-ItemProperty -Path $lansaKey  -Name 'Cloud' -PropertyType String -Value $using:Cloud -Force
        New-ItemProperty -Path $lansaKey  -Name 'GitBranch' -PropertyType String -Value $using:GitBranch -Force
        New-ItemProperty -Path $lansaKey  -Name 'VersionText' -PropertyType String -Value $using:VersionText -Force
        New-ItemProperty -Path $lansaKey  -Name 'VersionMajor' -PropertyType DWord -Value $using:VersionMajor -Force
        New-ItemProperty -Path $lansaKey  -Name 'VersionMinor' -PropertyType DWord -Value $using:VersionMinor -Force

        # Ensure last exit code is 0. (exit by itself will terminate the remote session)
        cmd /c exit 0
    }

    # Load up some required tools into remote environment

    Execute-RemoteScript -Session $Script:session -FilePath "$script:IncludeDir\dot-CommonTools.ps1"

    # Install Chocolatey

    Execute-RemoteScript -Session $Script:session -FilePath "$script:IncludeDir\getchoco.ps1"
    
    # Then we install git using chocolatey and pull down the rest of the files from git

    Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\installGit.ps1 -ArgumentList  @($Script:GitRepo, $Script:GitRepoPath, $GitBranch, $true)

    Execute-RemoteBlock $Script:session {    "Path = $([Environment]::GetEnvironmentVariable('PATH', 'Machine'))" }

    # Load utilities into Remote Session.
    # Requires the git repo to be pulled down so the scripts are present and the script variables initialised with Init-Baking-Vars.ps1.
    # Reflect local variables into remote session
    Execute-RemoteInitPostGit

    # Upload files that are not in Git. Should be limited to secure files that must not be in Git.
    # Git is a far faster mechansim for transferring files than using RemotePS.

    Send-RemotingFile $Script:session "$Script:LicenseKeyPath\LANSAScalableLicense.pfx" "$Script:LicenseKeyPath\LANSAScalableLicense.pfx"
    Send-RemotingFile $Script:session "$Script:LicenseKeyPath\LANSAIntegratorLicense.pfx" "$Script:LicenseKeyPath\LANSAIntegratorLicense.pfx"

    # From now on we may execute scripts which rely on other scripts to be present from the LANSA Cookboks git repo
    Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-base.ps1 -ArgumentList  @($Script:GitRepoPath, $Script:LicenseKeyPath, $script:licensekeypassword, "VLWebServer::IDEBase")

    MessageBox "Please RDP into $Script:publicDNS as Administrator using password '$Script:password' and run Windows Updates. Keep running Windows Updates until it displays the message 'Done Installing Windows Updates. Restart not required'. Now click OK on this message box"

    # Session has probably been lost due to a Windows Updates reboot
    if ( -not $Script:session -or ($Script:session.State -ne 'Opened') )
    {
        Write-Output "$(Log-Date) Session lost or not open. Reconnecting..."
        if ( $Script:session ) { Remove-PSSession $Script:session }

        Connect-RemoteSession
        Execute-RemoteInit
        Execute-RemoteInitPostGit
    }

    Write-Output "$(Log-Date) Completing installation steps, except for sysprep"

    # Must run install-lansa-scalable.ps1 after Windows Updates as it sets RunOnce after which you must not reboot.
    Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-scalable.ps1 -ArgumentList  @($Script:GitRepoPath, $Script:LicenseKeyPath, $script:licensekeypassword)
        
    Execute-RemoteScript -Session $Script:session -FilePath $script:IncludeDir\install-lansa-post-winupdates.ps1 -ArgumentList  @($Script:GitRepoPath, $Script:LicenseKeyPath )

    Invoke-Command -Session $Script:session {Set-ExecutionPolicy restricted -Scope CurrentUser}

    Write-Output "$(Log-Date) Sysprep"
    Invoke-Command -Session $Script:session {cmd /c "$ENV:ProgramFiles\Amazon\Ec2ConfigService\ec2config.exe" -sysprep}

    Remove-PSSession $Script:session

    # Sysprep will stop the Instance

    # Wait for the instance state to be stopped.

    Wait-EC2State $instanceid "Stopped"

    Write-Output "$(Log-Date) Creating AMI"

    $TagDesc = "$($AmazonImage[0].Description) created on $($AmazonImage[0].CreationDate) with $script:instancename"
    $AmiName = "$Script:DialogTitle $VersionText $(Get-Date -format "yyyy-MM-ddTHH-mm-ss")"     # AMI ID must not contain colons
    $amiID = New-EC2Image -InstanceId $Script:instanceid -Name $amiName -Description $TagDesc
 
    $tagName = $amiName # String for use with the name TAG -- as opposed to the AMI name, which is something else and set in New-EC2Image
 
    New-EC2Tag -Resources $amiID -Tags @{ Key = "Name" ; Value = $amiName} # Add tags to new AMI
    
    while ( $true )
    {
        Write-Output "$(Log-Date) Waiting for AMI to become available"
        $amiProperties = Get-EC2Image -ImageIds $amiID

        if ( $amiProperties.ImageState -eq "available" )
        {
            break
        }
        Sleep -Seconds 10
    }
    Write-Output "$(Log-Date) AMI is available"
  
    # Add tags to snapshots associated with the AMI using Amazon.EC2.Model.EbsBlockDevice

    $amiBlockDeviceMapping = $amiProperties.BlockDeviceMapping # Get Amazon.Ec2.Model.BlockDeviceMapping
    $amiBlockDeviceMapping.ebs | `
    ForEach-Object -Process {
        if ( $_ -and $_.SnapshotID )
        {
            New-EC2Tag -Resources $_.SnapshotID -Tags @( @{ Key = "Name" ; Value = $tagName}, @{ Key = "Description"; Value = $tagDesc } )
        }
    } 
    
    [console]::beep(500,1000)

    #####################################################################################
    Write-Output ("Delete Security Group. Should work first time, provided its not being used by an EC2 instance, but just in case, try it in a loop")
    #####################################################################################

    $err = $true
    while ($err)
    {
        $err = $false
        try
        {
            Remove-EC2SecurityGroup -GroupName $script:SG -Force
        }
        catch
        {
            $_
            $err = $true
            Write-Output "$(Log-Date) Waiting for Security Group to be deleted"
            Sleep -Seconds 10
        }
    }
}
catch
{
    Write-Error ($_ | format-list | out-string)
}

}