﻿<#
.SYNOPSIS

AWS and Internet tools

.EXAMPLE

#>

# N.B. Get-ExternalIP must not be run very often otherwise url may throttle the access
function Get-ExternalIP {
    if ( -not $script:externalip )
    {
        $Ip = (Invoke-WebRequest "https://myexternalip.com/raw")

        # strip CR or LF from string and return Ip Address
        $script:externalip = $Ip.content -replace "`t|`n|`r",""
    }
    $script:externalip # Return value of function
}

function Create-Ec2SecurityGroup
{
<#  .Synopsis      Creates a security group named $script.SG.  .Description Adds firewall exceptions for PowerShell Remoting, Remote Desktop and ICMP. Allowing ICMP enables “ping” to function, helps with debugging. The example below opens up to any IpRange, which means that the EC2 instance can be contacted from anywhere in the world. This is due to Azure DevOps sometimes using a different external ip and allowing a developer to access EC2 instances created by AzureDevOps  #>
    param([string[]]$ExternalIPAddresses)
    $groupExists = $true

    try
    {
        $Groups = Get-EC2SecurityGroup -GroupNames $script:SG -ea SilentlyContinue
    }
    catch
    {
        $groupExists = $false
    }

    if ( $groupExists ) {
        Write-Host( "GroupId = $Groups.GroupId")
        Remove-EC2SecurityGroup -GroupId $Groups.GroupId -Force | Out-Default | Write-Host
    }

    $GroupId = New-EC2SecurityGroup $script:SG  -Description "Temporary security to bake an ami"
    Get-EC2SecurityGroup -GroupId $GroupId | Out-Default | Write-Host

    if ( $ExternalIPAddresses -And $ExternalIPAddresses.count -gt 0 ) {
        $ipsplit = $ExternalIPAddresses.split(",")
        Write-Host "ipsplit: $ipsplit"
        foreach ( $iprange in $ipsplit ) {
            $iprange = $iprange.replace(' ','')
            Write-Host "Enabling SG for IP $iprange"
            Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "icmp"; FromPort = -1;   ToPort = -1;   IpRanges = $iprange} -ErrorAction SilentlyContinue | Out-Default | Write-Host
            Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "tcp";  FromPort = 3389; ToPort = 3389; IpRanges = $iprange} -ErrorAction SilentlyContinue | Out-Default | Write-Host
            Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "udp";  FromPort = 3389; ToPort = 3389; IpRanges = $iprange} -ErrorAction SilentlyContinue | Out-Default | Write-Host
            Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "tcp";  FromPort = 5985; ToPort = 5986; IpRanges = $iprange} -ErrorAction SilentlyContinue | Out-Default | Write-Host
        }
    }
    $externalip = Get-ExternalIP
    $externalipcidr = "$externalip/32"

    Write-Host "Enabling SG for Default IP $externalipcidr"

    Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "icmp"; FromPort = -1;   ToPort = -1;   IpRanges = $externalipcidr} -ErrorAction SilentlyContinue | Out-Default | Write-Host
    Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "tcp";  FromPort = 3389; ToPort = 3389; IpRanges = $externalipcidr} -ErrorAction SilentlyContinue | Out-Default | Write-Host
    Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "udp";  FromPort = 3389; ToPort = 3389; IpRanges = $externalipcidr} -ErrorAction SilentlyContinue | Out-Default | Write-Host
    Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "tcp";  FromPort = 5985; ToPort = 5986; IpRanges = $externalipcidr} -ErrorAction SilentlyContinue | Out-Default | Write-Host

    Grant-EC2SecurityGroupIngress -GroupName $script:SG -IpPermissions @{IpProtocol = "tcp";  FromPort = 80;   ToPort = 80;   IpRanges = @("0.0.0.0/0")} -ErrorAction SilentlyContinue | Out-Default | Write-Host

}
