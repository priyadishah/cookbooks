﻿<#
.SYNOPSIS

Wait for an EC2 instance to reach a desired state.

.EXAMPLE

#>

function Create-EC2Instance
{
Param (
[parameter(Mandatory=$true)]    [string]$imageid,
[parameter(Mandatory=$true)]    [string]$keypair,
[parameter(Mandatory=$true)]    [string]$securityGroup,
[parameter(Mandatory=$false)]   [string]$region,
[parameter(Mandatory=$false)]   [string]$instanceType = "t2.medium",
[parameter(Mandatory=$false)]   [string]$VersionText
)
try
{
    # More to open for Remote PS?
    # COM+ Remote Administration (DCOM-In)
    # COM+ Network Access (DCOM-In)
    # Win Updates Remote Access (New-NetFirewallRule -Name "Win Updates Remote Access" -LocalPort 135 -Program %windir%\system32\svchost.exe -Protocol 6 -RemotePort ALL -RemoteUser Administrator -Service rpcss)
    # Windows Management Instrumentation (x3)
    # Remote Service Management (x3)
    # Routing and Remote Access (x3)

    # By default, Windows Firewall restricts PS remoting to local subnet only.
    # Set-NetFirewallRule is executed via userdata section to open this up to the script-runner's external IP Address.
    $userdata = "<powershell>Enable-NetFirewallRule WINRM-HTTP-In-TCP-PUBLIC; Set-NetFirewallRule -Name WINRM-HTTP-In-TCP-PUBLIC -RemoteAddress Any</powershell>"

    #Userdata has to be base64 encoded
    $userdataBase64Encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userdata))

    # use a 100 GB EBS Volume
    $volume = New-Object Amazon.EC2.Model.EbsBlockDevice
    $volume.VolumeSize = 100
    $volume.VolumeType = 'gp2'
    $volume.DeleteOnTermination = $true

    #Define how the volume is going to be attached to the instance and assign the volume properties
    $DeviceMapping = New-Object Amazon.EC2.Model.BlockDeviceMapping
    $DeviceMapping.DeviceName = '/dev/sda1'
    $DeviceMapping.Ebs = $volume

    Write-Host( "$(Log-Date) Security Group = $securityGroup")

    # Use at least a 2 CPU instance so that multiple processes may run concurrently.
    $a = New-EC2Instance -ImageId $imageid -MinCount 1 -MaxCount 1 -InstanceType $instanceType -KeyName $keypair `
            -SecurityGroups $securityGroup -UserData $userdataBase64Encoded -Monitoring_Enabled $true `
            -BlockDeviceMapping $DeviceMapping `
            -InstanceProfile_Arn $Script:InstanceProfileArn

    $instanceid = $a.Instances[0].InstanceId

    #Wait for the running state
    Wait-EC2State $instanceid "Running"

    # Name our instance
    $Tag = [Amazon.EC2.Model.Tag]::new('Name', "Bake $Script:instancename")
    New-EC2Tag -ResourceID $instanceID -Tag $tag | Out-Default | Write-Host

    # Tag it so its easily deleted
    $Tag = [Amazon.EC2.Model.Tag]::new('BakeVersion', $VersionText)
    New-EC2Tag -ResourceID $instanceID -Tag $tag | Out-Default | Write-Host

    Write-Host "$(Log-Date) $instanceid is Running"

    $a = Get-EC2Instance -Filter @{Name = "instance-id"; Values = $instanceid}
    $Script:publicDNS = $a.Instances[0].PublicDnsName

    #Wait for ping to succeed
    while ($true)
    {
        Write-Host "$(Log-Date) Waiting for instance status to pass status checks"
        # Windows Server 2016 disables ping by default, so we can't use ping anymore to see if the network is up.
        $status = Get-EC2InstanceStatus -InstanceId $instanceid
        if ($($status.Status.Status) -eq 'ok' -and $($status.SystemStatus.Status) -eq 'ok')
        {
            break
        }
        Write-Host "$(Log-Date) Status = $($status.Status.Status), System Status = $($status.SystemStatus.Status)"
        Sleep -Seconds 10
    }

    Write-Host "$(Log-Date) $instanceid network is alive - $Script:publicDNS"

    # RobG: altering TrustedHost does not seem to be necessary
    #Since the EC2 instance that we are going to create is not a domain joined machine,
    # it has to be added to the trusted hosts. The computers in the TrustedHosts list are
    #  not authenticated. (i.e.) There is no way for the client to know if it is talking to
    # the right machine. The client may send credential information to these computers.
    # Either add the specific DNSName or “*” to trust any machine. Since it is for the testing purpose, I chose to add “*”
    # TODO: add the DNS name of the EC2 instance to the trusted hosts (and remove it at the end)
    # Set-Item WSMan:\localhost\Client\TrustedHosts "$Script:publicDNS" -Force

    # Get-EC2PasswordData is used to extract the password by passing the private key file created earlier. This is tried in a loop until the password is ready.

    $Script:password = $null
    # Wait until the password is available
    # blindly eats all the exceptions, bad idea for production code.
    $Retry = 10     # retry every 10 seconds. Typically takes about 2 minutes in this loop
    $Timeout = 300   # 5 minute timeout in seconds
    $RetryCount = $Timeout / $Retry
    while ( $null -eq $Script:password -and ($RetryCount -gt 0) )
    {
        $RetryCount -= 1
        Write-Host "$(Log-Date) Waiting 5 minutes for Password Data to be available"
        try
        {
            Start-Sleep -Seconds 10
            $Script:password = Get-EC2PasswordData -InstanceId $instanceid -PemFile $script:keypairfile -Decrypt
        }
        catch
        {
            # The exception is [System.InvalidOperationException] when the instance is not ready,
            # which is a very generic erorr so we cannot be specific and just ignore the expected state
            $_ | Out-Default | Write-Host
        }
    }

    if ( $RetryCount -le 0 ) {
        Write-Host( "$(Log-Date) Timeout $Timeout seconds expired getting password" )
        throw
    }
    Write-Host "$(Log-Date) $instanceid password successfully obtained - '$Script:password'"

    $script:instanceId = $instanceId
}
catch
{
    Write-Host ($_ | format-list | out-string)
    throw # to the caller's catch block
}
}