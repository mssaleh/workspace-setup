param([switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'

$module = Get-Module -ListAvailable Microsoft.Graph | Select-Object -First 1
if ($module) {
    try {
        Test-ModuleManifest $module.Path | Out-Null
        Get-Command Connect-MgGraph, Invoke-MgGraphRequest, Get-MgUser -ErrorAction Stop | Out-Null
        Write-Output "Microsoft.Graph $($module.Version) is usable"
        exit 0
    } catch {
        if ($VerifyOnly) { throw }
        Write-Warning "Repairing Microsoft.Graph $($module.Version): $($_.Exception.Message)"
    }
}
if ($VerifyOnly) { throw 'Microsoft.Graph is not installed' }
$options = @{
    Name = 'Microsoft.Graph'
    Scope = 'CurrentUser'
    Repository = 'PSGallery'
    TrustRepository = $true
    AcceptLicense = $true
    Quiet = $true
}
if ($module) {
    $options.Version = $module.Version.ToString()
    $options.Reinstall = $true
}
Install-PSResource @options
$module = Get-Module -ListAvailable Microsoft.Graph | Select-Object -First 1
Test-ModuleManifest $module.Path | Out-Null
Get-Command Connect-MgGraph, Invoke-MgGraphRequest, Get-MgUser -ErrorAction Stop | Out-Null
Write-Output "Microsoft.Graph $($module.Version) is usable"
