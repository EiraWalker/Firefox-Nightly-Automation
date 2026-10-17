param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference='Stop'
function Write-Archive([string]$Name,[string[]]$Manifests) {
    $archive=[System.IO.Compression.ZipFile]::Open((Join-Path $Directory $Name),[System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($manifest in $Manifests) {
            $entry=$archive.CreateEntry('manifest.json')
            $writer=[System.IO.StreamWriter]::new($entry.Open(),[System.Text.UTF8Encoding]::new($false))
            try { $writer.Write($manifest) } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
}
$valid='{"manifest_version":2,"name":"Fixture","version":"2.0","browser_specific_settings":{"gecko":{"id":"example@local.test"}}}'
Write-Archive 'valid.xpi' @($valid)
Write-Archive 'duplicate.xpi' @($valid,$valid)
Write-Archive 'missing-id.xpi' @('{"version":"2.0"}')
Write-Archive 'invalid-json.xpi' @('{malformed')
