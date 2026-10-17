param([Parameter(Mandatory)][string]$ArchivePath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$archive=$null
$reader=$null
try {
    $archive=[System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $entries=@($archive.Entries | Where-Object { $_.FullName -ceq 'manifest.json' })
    if($entries.Count -ne 1 -or $entries[0].Length -gt 1048576) { throw 'F_XPI_INVALID' }
    $reader=[System.IO.StreamReader]::new($entries[0].Open(),[System.Text.Encoding]::UTF8,$true)
    $manifest=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
    $id=$manifest.browser_specific_settings.gecko.id
    if(-not $id) { $id=$manifest.applications.gecko.id }
    if($id -isnot [string] -or -not $id.Trim()) { throw 'F_XPI_ID_REQUIRED' }
    if($manifest.version -isnot [string] -or -not $manifest.version.Trim()) { throw 'F_XPI_INVALID' }
    @{ok=$true;id=$id;version=$manifest.version} | ConvertTo-Json -Compress
} catch {
    $code=if($_.Exception.Message -eq 'F_XPI_ID_REQUIRED'){'F_XPI_ID_REQUIRED'}else{'F_XPI_INVALID'}
    @{ok=$false;error=$code} | ConvertTo-Json -Compress
    exit 1
} finally {
    if($reader) { $reader.Dispose() }
    if($archive) { $archive.Dispose() }
}
