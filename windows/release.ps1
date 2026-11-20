param([Parameter(Mandatory)][version]$Version,
      [Parameter(Mandatory)][string]$SigningKey,
      [Parameter(Mandatory)][string]$Output,
      [Parameter(Mandatory)][string]$Notes)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$true
$destination=[IO.Path]::GetFullPath($Output)
if(Test-Path $destination){throw '选择一个新的输出目录。'}
$stage=Join-Path ([IO.Path]::GetTempPath()) ("swapdeck-build-"+[guid]::NewGuid())
$publish=Join-Path $stage 'publish'
$app=Join-Path $PSScriptRoot 'Swapdeck'
dotnet publish $app -c Release -r win-x64 --self-contained true -o $publish "-p:Version=$Version"
$packed=Join-Path $stage 'releases'
vpk pack -u Swapdeck.Windows -v $Version -r win-x64 -c win-x64 -p $publish -o $packed -e Swapdeck.exe --packTitle Swapdeck --packAuthors lazymicezhu --delta None --releaseNotes $Notes --icon (Join-Path $app 'Swapdeck.ico')
& (Join-Path $PSScriptRoot 'verify-release.ps1') $packed
$rsa=[Security.Cryptography.RSA]::Create()
$raw=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Resolve-Path $SigningKey)),$null,'CurrentUser')
try {
  $rsa.ImportPkcs8PrivateKey($raw,[ref]$null)
  $expected=(Get-Content (Join-Path $app 'update-public.pem') -Raw).Trim()
  if ($rsa.ExportSubjectPublicKeyInfoPem().Trim() -ne $expected){throw '签名私钥与客户端公钥不匹配。'}
  $manifest=Join-Path $packed 'releases.win-x64.json'
  $sig=$rsa.SignData([IO.File]::ReadAllBytes($manifest),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $metadata=[IO.File]::ReadAllBytes($manifest)

  $asset=([Text.Encoding]::UTF8.GetString($metadata) | ConvertFrom-Json).Assets[0]
  $setup=Join-Path $packed 'Swapdeck.Windows-win-x64-Setup.exe'
  $stream=[IO.File]::Open($setup,'Open','ReadWrite','None')
  try {
    $stream.Position=$stream.Length-$asset.Size
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) -ne $asset.SHA256){throw '安装包未包含预期的完整更新包。'}
    $writer=[IO.BinaryWriter]::new($stream,[Text.Encoding]::UTF8,$true)
    try{
      $writer.Write($metadata);$writer.Write($sig)
      $writer.Write([int]$metadata.Length);$writer.Write([int]$sig.Length)
      $writer.Write([Text.Encoding]::ASCII.GetBytes('SWPDK001'))
    }finally{$writer.Dispose()}
  }finally{$stream.Dispose()}
  [IO.Directory]::CreateDirectory($destination) | Out-Null
  Copy-Item -LiteralPath $setup -Destination (Join-Path $destination "Swapdeck-$Version-win-x64-Setup.exe")
} finally {[Array]::Clear($raw);$rsa.Dispose()}

