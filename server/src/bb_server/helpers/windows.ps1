param([Parameter(Mandatory=$true)][string]$RequestFile,[switch]$ValidateOnly)
# Install this script in the protected Program Files\BB directory. It accepts
# only a small JSON request, never executable input or a target file/command.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InstallRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'BB'
$StateRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BB-Public'
$Version = '2026.11.0'
$ExpectedHash = 'd5c1d82031da6253dcdcff64c944cd0fe063016edeb2e4fd088075fc9bd52d0a'
function Protect-Directory([string]$Path,[bool]$PublicReceipt=$false) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'unsafe' }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $sddl = 'O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;LS)'
    if ($PublicReceipt) { $sddl += '(A;OICI;0x1200a9;;;BU)' }
    $acl.SetSecurityDescriptorSddlForm($sddl)
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Write-Once([string]$Path,[string]$Text) {
    if (Test-Path -LiteralPath $Path) {
        if (((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) -or [IO.File]::ReadAllText($Path) -cne $Text) { throw 'conflict' }
    } else { [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false))) }
}
try {
    $file = Get-Item -LiteralPath $RequestFile
    if ($file.Length -gt 8192 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'request' }
    $request = [IO.File]::ReadAllText($RequestFile) | ConvertFrom-Json
    foreach ($key in $request.PSObject.Properties.Name) { if ($key -notin @('action','task_id','instance_id','token')) { throw 'request' } }
    if ($request.action -notin @('install','connect')) { throw 'request' }
    foreach ($key in @('task_id','instance_id')) { if ([guid]::Parse($request.$key).ToString() -cne $request.$key) { throw 'request' } }
    if ($request.action -eq 'connect') {
        if ($request.token -isnot [string] -or $request.token.Length -lt 1 -or $request.token.Length -gt 4096) { throw 'token' }
        $tokenData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($request.token)) | ConvertFrom-Json
        [guid]::Parse($tokenData.t) | Out-Null
        if ([Convert]::FromBase64String($tokenData.s).Length -lt 32) { throw 'token' }
    } elseif ($request.PSObject.Properties.Name -contains 'token') { throw 'request' }
    if ($ValidateOnly) { @{action=$request.action;task_id=$request.task_id;instance_id=$request.instance_id} | ConvertTo-Json -Compress; exit 0 }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'permission' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'platform' }
    Protect-Directory $StateRoot $true
    $lock = [IO.File]::Open((Join-Path $StateRoot 'lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Protect-Directory $InstallRoot $true
        $exe = Join-Path $InstallRoot 'cloudflared.exe'
        if ($request.action -eq 'install') {
            if (-not (Test-Path -LiteralPath $exe)) {
                $download = Join-Path $InstallRoot 'cloudflared.download'
                if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/cloudflare/cloudflared/releases/download/$Version/cloudflared-windows-amd64.exe" -OutFile $download
                if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash) { Remove-Item -LiteralPath $download; throw 'checksum' }
                Move-Item -LiteralPath $download -Destination $exe
            }
            if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash) { throw 'existing_binary_conflict' }
        } else {
            if (-not (Test-Path -LiteralPath $exe) -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash) { throw 'binary' }
            $dir = Join-Path $StateRoot $request.instance_id
            Protect-Directory $dir
            $tokenPath = Join-Path $dir 'token'
            $binPath = '"' + $exe + '" tunnel --no-autoupdate run --token-file "' + $tokenPath + '"'
            $owner = Join-Path $StateRoot 'owner.txt'
            $service = Get-Service -Name Cloudflared -ErrorAction SilentlyContinue
            if ($service -and (-not (Test-Path -LiteralPath $owner) -or [IO.File]::ReadAllText($owner) -cne $request.instance_id)) { throw 'third_party_service' }
            if ($service) {
                $service = Get-CimInstance Win32_Service -Filter "Name='Cloudflared'"
                if ($service.PathName -cne $binPath -or $service.StartName -ne 'NT AUTHORITY\LocalService') { throw 'service_changed' }
            }
            Write-Once $owner $request.instance_id
            Write-Once $tokenPath $request.token
            if (-not $service) {
                if (-not [Diagnostics.EventLog]::SourceExists('Cloudflared')) { New-EventLog -LogName Application -Source Cloudflared }
                $result = Invoke-CimMethod -ClassName Win32_Service -MethodName Create -Arguments @{Name='Cloudflared';DisplayName='BB cloudflared';PathName=$binPath;ServiceType=[uint32]16;StartMode='Automatic';StartName='NT AUTHORITY\LocalService'}
                if ($result.ReturnValue -ne 0) { throw 'service_create' }
            }
            Start-Service -Name Cloudflared
            (Get-Service -Name Cloudflared).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
        }
    } finally { $lock.Dispose() }
    exit 0
} catch {
    # Never print errors containing request data, access tokens, paths or output.
    exit 1
}
