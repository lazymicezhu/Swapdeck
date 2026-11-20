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
vpk pack -u Swapdeck.Windows -v $Version -r win-x64 -c win-x64 -p $publish -o $destination -e Swapdeck.exe --packTitle Swapdeck --packAuthors lazymicezhu --delta None --releaseNotes $Notes --icon (Join-Path $app 'Swapdeck.ico')
& (Join-Path $PSScriptRoot 'verify-release.ps1') $destination
$rsa=[Security.Cryptography.RSA]::Create()
$raw=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Resolve-Path $SigningKey)),$null,'CurrentUser')
try {
  $rsa.ImportPkcs8PrivateKey($raw,[ref]$null)
  $expected=(Get-Content (Join-Path $app 'update-public.pem') -Raw).Trim()
  if ($rsa.ExportSubjectPublicKeyInfoPem().Trim() -ne $expected){throw '签名私钥与客户端公钥不匹配。'}
  $manifest=Join-Path $destination 'releases.win-x64.json'
  $sig=$rsa.SignData([IO.File]::ReadAllBytes($manifest),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
  [IO.File]::WriteAllBytes("$manifest.sig",$sig)
} finally {[Array]::Clear($raw);$rsa.Dispose()}

