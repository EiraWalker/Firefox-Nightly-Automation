[CmdletBinding()]
param(
    [string]$ExecutablePath = 'C:\Program Files\Firefox Nightly\firefox.exe',
    [string]$Arguments = '',
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$resolvedExecutable = (Get-Item -LiteralPath $ExecutablePath -ErrorAction Stop).FullName
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $resolvedExecutable
$startInfo.WorkingDirectory = Split-Path -Parent $resolvedExecutable
$startInfo.Arguments = $Arguments
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.EnvironmentVariables['MOZ_REMOTE_ALLOW_SYSTEM_ACCESS'] = '1'

$browserProcess = [System.Diagnostics.Process]::Start($startInfo)
try {
    if ($PassThru) {
        [pscustomobject]@{
            processId = $browserProcess.Id
            executablePath = $resolvedExecutable
            requestedSystemAccess = $true
        } | ConvertTo-Json -Compress
    }
} finally {
    $browserProcess.Dispose()
}
