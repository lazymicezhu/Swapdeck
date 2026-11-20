param([Parameter(Mandatory)][string]$ReleaseDir)
$ErrorActionPreference='Stop'
# Check unpacked payloads, including UTF-16 strings in managed assemblies.
Add-Type -AssemblyName System.IO.Compression
$index=Get-Content (Join-Path $ReleaseDir 'releases.win-x64.json') -Raw | ConvertFrom-Json
foreach($asset in $index.Assets){
  $pkg=Join-Path $ReleaseDir $asset.FileName
  if((Get-FileHash $pkg -Algorithm SHA256).Hash -ne $asset.SHA256){throw '发布包哈希不一致。'}
  $zip=[IO.Compression.ZipFile]::OpenRead($pkg)
  try {
    foreach($entry in $zip.Entries){
      if($entry.Name -match '(?i)^(auth\.json|settings\.json|profiles\.bin|.*\.dpapi|credentials\.json|codex-clipboard-.*|.*\.pfx)$'){throw ("检测到私人文件 "+$entry.Name)}
      $buffer=[IO.MemoryStream]::new()
      $stream=$entry.Open()
      try{$stream.CopyTo($buffer)}finally{$stream.Dispose()}
      $bytes=$buffer.ToArray();$buffer.Dispose()
      foreach($enc in [Text.Encoding]::Latin1,[Text.Encoding]::Unicode){
        if($enc.GetString($bytes) -cmatch 'sk-[A-Fa-f0-9]{48,}|(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{32,}|-----BEGIN (RSA |EC )?PRIVATE KEY-----[\r\n]+[A-Za-z0-9+/]{48}'){throw ("检测到疑似凭据 "+$entry.FullName)}
      }
    }
  } finally {$zip.Dispose()}
}
Write-Output '发布包扫描通过'

