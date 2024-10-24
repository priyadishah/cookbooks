﻿<#
.SYNOPSIS

Test licenses are installed and working.

IMPORTANT:" To be run in a new instance created from the baked image, NOT while creating the image itself.

.EXAMPLE

#>
Param(
    [Parameter(Mandatory=$true)] [String] $ImgName
)
. "c:\lansa\scripts\dot-CommonTools.ps1"

if ( -not $script:IncludeDir)
{
	$script:IncludeDir = 'c:\lansa\scripts'
}
else
{
	Write-Host "$(Log-Date) Environment already initialised - presumed running through RemotePS"
}

# Verifies the VersionText Registry with the Image SKU
$VersionTextValue = (Get-ItemProperty -Path HKLM:\Software\LANSA  -Name 'VersionText').VersionText
Write-Host "$(Log-Date) Verifying the Registry entry for VersionText $VersionTextValue and the SKU $ImgName"
if ($VersionTextValue -ne $ImgName) {
    Write-Host "$(Log-Date) Registry entry for VersionText $VersionTextValue doesn't match the SKU $ImgName"
    cmd /c exit 1    #Set $LASTEXITCODE
    throw "$(Log-Date) Registry entry for VersionText $VersionTextValue is invalid"
}
Write-GreenOutput "Image SKU tested successfully" | Out-Default | Write-Host

Write-Host ("PSScriptRoot = $PSScriptRoot")
& "$script:IncludeDir\..\tests\CheckAWSSSmAgent.ps1"
