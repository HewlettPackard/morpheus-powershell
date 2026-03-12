[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [Parameter()]
    [string]$OutputDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'dist'),

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$CertificateThumbprint = '',

    [Parameter()]
    [string]$CertificateStore = 'Cert:\CurrentUser\My',

    [Parameter()]
    [string]$PfxPath = '',

    [Parameter()]
    [securestring]$PfxPassword,

    [Parameter()]
    [string]$TimestampServer = 'http://timestamp.digicert.com',

    [Parameter()]
    [switch]$SkipTimestamp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint) -and -not [string]::IsNullOrWhiteSpace($PfxPath)) {
    throw 'Specify either -CertificateThumbprint or -PfxPath, not both.'
}

$manifestPath = Join-Path -Path $SourceRoot -ChildPath 'Morpheus.OpenApi.psd1'
if (-not (Test-Path -Path $manifestPath)) {
    throw "Manifest not found at [$manifestPath]."
}

$manifest = Import-PowerShellDataFile -Path $manifestPath
$moduleVersion = [string]$manifest.ModuleVersion
if ([string]::IsNullOrWhiteSpace($moduleVersion)) {
    throw 'ModuleVersion was not found in manifest.'
}

$moduleName = [System.IO.Path]::GetFileNameWithoutExtension([string]$manifest.RootModule)
if ([string]::IsNullOrWhiteSpace($moduleName)) {
    $moduleName = 'Morpheus.OpenApi'
}

$installerFileName = "$moduleName-$moduleVersion-Setup.exe"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$installerPath = Join-Path -Path $OutputDir -ChildPath $installerFileName

if ((Test-Path -Path $installerPath) -and -not $Force) {
    throw "Installer already exists at [$installerPath]. Use -Force to overwrite."
}

function Get-SigningCertificate {
    param(
        [Parameter()][string]$Thumbprint,
        [Parameter()][string]$StorePath,
        [Parameter()][string]$PfxFilePath,
        [Parameter()][securestring]$PfxSecurePassword
    )

    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        if (-not (Test-Path -Path $StorePath)) {
            throw "Certificate store path not found: [$StorePath]"
        }

        $cert = @(Get-ChildItem -Path $StorePath | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1)
        if ($cert.Count -eq 0) {
            throw "Certificate with thumbprint [$Thumbprint] not found in [$StorePath]."
        }
        if (-not $cert[0].HasPrivateKey) {
            throw "Certificate [$Thumbprint] does not have an accessible private key."
        }
        return [pscustomobject]@{ Certificate = $cert[0]; Imported = $false; ImportedThumbprint = $null }
    }

    if (-not [string]::IsNullOrWhiteSpace($PfxFilePath)) {
        if (-not (Test-Path -Path $PfxFilePath)) {
            throw "PFX file not found: [$PfxFilePath]"
        }

        $importParams = @{
            FilePath = $PfxFilePath
            CertStoreLocation = 'Cert:\CurrentUser\My'
            Exportable = $false
        }
        if ($null -ne $PfxSecurePassword) {
            $importParams.Password = $PfxSecurePassword
        }

        $imported = Import-PfxCertificate @importParams
        if ($null -eq $imported) {
            throw "Unable to import PFX certificate from [$PfxFilePath]."
        }

        $importedCert = @($imported | Select-Object -First 1)[0]
        if (-not $importedCert.HasPrivateKey) {
            throw "Imported certificate from [$PfxFilePath] does not have a private key."
        }

        return [pscustomobject]@{ Certificate = $importedCert; Imported = $true; ImportedThumbprint = $importedCert.Thumbprint }
    }

    return $null
}

$iexpress = Join-Path $env:WINDIR 'System32\iexpress.exe'
if (-not (Test-Path -Path $iexpress)) {
    throw 'IExpress is not available on this system (expected at %WINDIR%\System32\iexpress.exe).'
}

$stagingRoot = Join-Path -Path $OutputDir -ChildPath ("_staging_{0}" -f [guid]::NewGuid().ToString('N'))
$installCmdPath = Join-Path -Path $stagingRoot -ChildPath 'install.cmd'
$installUiPath = Join-Path -Path $stagingRoot -ChildPath 'install-ui.ps1'
$sedPath = Join-Path -Path $stagingRoot -ChildPath 'installer.sed'

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$moduleFiles = @(
    'Morpheus.OpenApi.psd1',
    'Morpheus.OpenApi.psm1',
    'Morpheus.OpenApi.ColumnProfiles.psd1',
    'README.md'
)

foreach ($fileName in $moduleFiles) {
    $sourceFile = Join-Path -Path $SourceRoot -ChildPath $fileName
    if (-not (Test-Path -Path $sourceFile)) {
        throw "Required file missing: [$sourceFile]"
    }
    Copy-Item -Path $sourceFile -Destination (Join-Path -Path $stagingRoot -ChildPath $fileName) -Force
}

$installCmd = @"
@echo off
setlocal
set "QUIET=0"
set "SCOPE=current"

for %%A in (%*) do (
    if /I "%%~A"=="/quiet" set "QUIET=1"
    if /I "%%~A"=="/allusers" set "SCOPE=all"
    if /I "%%~A"=="/currentuser" set "SCOPE=current"
)

set "MODULE_NAME=$moduleName"
set "MODULE_VERSION=$moduleVersion"
set "SRC=%~dp0"
set "PSHOST_UI=powershell.exe"
set "PSHOST_QUIET=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PSHOST_QUIET=pwsh.exe"
set "BOOTSTRAP_LOG=%TEMP%\Morpheus.OpenApi-Installer-bootstrap.log"

echo [%DATE% %TIME%] Launching installer. QUIET=%QUIET% SCOPE=%SCOPE% > "%BOOTSTRAP_LOG%"

if "%QUIET%"=="1" (
    echo [%DATE% %TIME%] Quiet host: %PSHOST_QUIET% >> "%BOOTSTRAP_LOG%"
        "%PSHOST_QUIET%" -NoProfile -ExecutionPolicy Bypass -File "%SRC%install-ui.ps1" -ModuleName "%MODULE_NAME%" -ModuleVersion "%MODULE_VERSION%" -Scope "%SCOPE%" -Quiet
    echo [%DATE% %TIME%] Quiet exit code: %ERRORLEVEL% >> "%BOOTSTRAP_LOG%"
  exit /b %ERRORLEVEL%
)

echo [%DATE% %TIME%] UI host: %PSHOST_UI% >> "%BOOTSTRAP_LOG%"
"%PSHOST_UI%" -NoProfile -ExecutionPolicy Bypass -STA -File "%SRC%install-ui.ps1" -ModuleName "%MODULE_NAME%" -ModuleVersion "%MODULE_VERSION%"
echo [%DATE% %TIME%] UI exit code: %ERRORLEVEL% >> "%BOOTSTRAP_LOG%"
if not "%ERRORLEVEL%"=="0" (
    "%PSHOST_UI%" -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Installer failed to launch or exited unexpectedly. Exit code: %ERRORLEVEL%`nBootstrap log: %BOOTSTRAP_LOG%','Morpheus Installer Error',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null"
)
exit /b %ERRORLEVEL%
"@
Set-Content -Path $installCmdPath -Value $installCmd -Encoding ASCII

$installUi = @"
param(
    [Parameter(Mandatory = `$true)]
    [string]`$ModuleName,

    [Parameter(Mandatory = `$true)]
    [string]`$ModuleVersion,

    [Parameter()]
    [ValidateSet('current','all')]
    [string]`$Scope = 'current',

    [Parameter()]
    [switch]`$Quiet
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$script:InstallerLogPath = `$null
`$script:InstallerMutex = `$null

function Initialize-InstallerLog {
    `$logRoot = Join-Path `$env:LOCALAPPDATA 'Morpheus\InstallerLogs'
    New-Item -Path `$logRoot -ItemType Directory -Force | Out-Null
    `$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    `$script:InstallerLogPath = Join-Path `$logRoot ("`$ModuleName-`$ModuleVersion-`$stamp.log")
    "[$((Get-Date).ToString('u'))] Installer started. Module=`$ModuleName Version=`$ModuleVersion Quiet=`$Quiet" | Out-File -FilePath `$script:InstallerLogPath -Encoding UTF8 -Force
}

function Write-InstallerLog {
    param([string]`$Message)
    if ([string]::IsNullOrWhiteSpace(`$script:InstallerLogPath)) { return }
    "[$((Get-Date).ToString('u'))] `$Message" | Out-File -FilePath `$script:InstallerLogPath -Append -Encoding UTF8
}

function Initialize-InstallerMutex {
    `$createdNew = `$false
    `$script:InstallerMutex = New-Object System.Threading.Mutex(`$true, 'Global\Morpheus.OpenApi.Setup', [ref]`$createdNew)
    if (-not `$createdNew) {
        throw 'Another Morpheus installer instance is currently running. Close it and retry.'
    }
}

function Dispose-InstallerMutex {
    if (`$null -ne `$script:InstallerMutex) {
        try { `$script:InstallerMutex.ReleaseMutex() } catch {}
        `$script:InstallerMutex.Dispose()
        `$script:InstallerMutex = `$null
    }
}

function Test-InstallerPrerequisites {
    param([string]`$InstallScope)

    `$issues = New-Object System.Collections.Generic.List[string]

    if (`$InstallScope -eq 'all' -and -not (Test-IsAdministrator)) {
        `$issues.Add('All-users install requires running the installer as Administrator.')
    }

    return [pscustomobject]@{
        CanContinue = (`$issues.Count -eq 0)
        Issues = @(`$issues)
        Warnings = @()
    }
}

function Test-IsAdministrator {
    `$current = [Security.Principal.WindowsIdentity]::GetCurrent()
    `$principal = New-Object Security.Principal.WindowsPrincipal(`$current)
    return `$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-TargetRoot {
    param([string]`$InstallScope)
    if (`$InstallScope -eq 'all') {
        `$programFilesModules = Join-Path `$env:ProgramFiles 'PowerShell\Modules'
        if (Test-Path -Path `$programFilesModules) { return `$programFilesModules }
        return Join-Path `$env:ProgramFiles 'WindowsPowerShell\Modules'
    }

    return Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
}

function Get-UninstallKeyName {
    param(
        [Parameter(Mandatory = `$true)][string]`$Name
    )

    return ("`${Name}" -replace '[^a-zA-Z0-9_.-]', '_')
}

function Get-UninstallRegistryRoot {
    param([Parameter(Mandatory = `$true)][string]`$InstallScope)

    if (`$InstallScope -eq 'all') {
        return 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    }

    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
}

function Get-InstalledModuleVersions {
    param(
        [Parameter(Mandatory = `$true)][string]`$Name,
        [Parameter(Mandatory = `$true)][string]`$InstallScope
    )

    `$targetRoot = Resolve-TargetRoot -InstallScope `$InstallScope
    `$moduleRoot = Join-Path `$targetRoot `$Name
    if (-not (Test-Path -Path `$moduleRoot)) {
        return @()
    }

    `$result = New-Object System.Collections.Generic.List[object]
    foreach (`$dir in @(Get-ChildItem -Path `$moduleRoot -Directory -ErrorAction SilentlyContinue)) {
        try {
            `$parsed = [version]::Parse([string]`$dir.Name)
            `$result.Add([pscustomobject]@{
                    VersionText = [string]`$dir.Name
                    Version = `$parsed
                    Path = `$dir.FullName
                })
        }
        catch {
        }
    }

    return @(`$result | Sort-Object -Property Version)
}

function Get-InstallEvaluation {
    param(
        [Parameter(Mandatory = `$true)][string]`$Name,
        [Parameter(Mandatory = `$true)][string]`$Version,
        [Parameter(Mandatory = `$true)][string]`$InstallScope
    )

    `$desiredVersion = [version]::Parse(`$Version)
    `$existing = @(Get-InstalledModuleVersions -Name `$Name -InstallScope `$InstallScope)
    `$otherScope = if (`$InstallScope -eq 'all') { 'current' } else { 'all' }
    `$existingOtherScope = @(Get-InstalledModuleVersions -Name `$Name -InstallScope `$otherScope)
    `$otherScopeSame = @(`$existingOtherScope | Where-Object { `$_.Version -eq `$desiredVersion } | Select-Object -First 1)
    `$scopeHint = if (`$otherScopeSame.Count -gt 0) { "`r`nNote: v`$Version is installed for the other scope (`$otherScope)." } else { '' }

    `$globalHigher = @((@(`$existing) + @(`$existingOtherScope)) | Where-Object { `$_.Version -gt `$desiredVersion } | Sort-Object -Property Version -Descending | Select-Object -First 1)
    if (`$globalHigher.Count -gt 0) {
        return [pscustomobject]@{
            Status = 'DowngradeBlocked'
            CanInstall = `$false
            Message = "Downgrade blocked.`r`nInstalled version: `$(`$globalHigher[0].VersionText)`r`nUninstall version `$(`$globalHigher[0].VersionText) first, then run this installer again."
        }
    }

    `$sameVersion = @(`$existing | Where-Object { `$_.Version -eq `$desiredVersion } | Select-Object -First 1)
    if (`$sameVersion.Count -gt 0) {
        return [pscustomobject]@{
            Status = 'Reinstall'
            CanInstall = `$true
            Message = "`$Name v`$Version is already installed for this scope.`r`nInstaller will perform a reinstall when you click Install.`$scopeHint"
        }
    }

    if (`$otherScopeSame.Count -gt 0) {
        if (`$otherScope -eq 'all' -and -not (Test-IsAdministrator)) {
            return [pscustomobject]@{
                Status = 'ModifyScopeRequiresAdmin'
                CanInstall = `$false
                Message = "Modify scope blocked.`r`nExisting install is All Users.`r`nRun installer as Administrator to migrate to Current User and keep a single unified app entry."
            }
        }

        return [pscustomobject]@{
            Status = 'ModifyScope'
            CanInstall = `$true
            Message = "Modify install scope: move v`$Version from `$otherScope to `$InstallScope.`r`nClick Install to continue."
        }
    }

    `$lower = @(`$existing | Where-Object { `$_.Version -lt `$desiredVersion })
    if (`$lower.Count -gt 0) {
        return [pscustomobject]@{
            Status = 'Upgrade'
            CanInstall = `$true
            Message = ("Upgrade available. Click Install to continue.`$scopeHint")
        }
    }

    return [pscustomobject]@{
        Status = 'NewInstall'
        CanInstall = `$true
        Message = ("Ready to install.`$scopeHint")
    }
}

function Remove-UninstallEntry {
    param(
        [Parameter(Mandatory = `$true)][string]`$Name
    )

    `$roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    `$keyName = Get-UninstallKeyName -Name `$Name
    foreach (`$root in `$roots) {
        `$path = Join-Path `$root `$keyName
        if (Test-Path -Path `$path) {
            Remove-Item -Path `$path -Recurse -Force -ErrorAction SilentlyContinue
        }

        foreach (`$legacy in @(Get-ChildItem -Path `$root -ErrorAction SilentlyContinue | Where-Object { `$_.PSChildName -like "`$Name_*" })) {
            Remove-Item -Path `$legacy.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-UninstallEntry {
    param(
        [Parameter(Mandatory = `$true)][string]`$Name,
        [Parameter(Mandatory = `$true)][string]`$Version,
        [Parameter(Mandatory = `$true)][string]`$InstallScope,
        [Parameter(Mandatory = `$true)][string]`$InstallPath,
        [Parameter(Mandatory = `$true)][string]`$UninstallScriptPath
    )

    `$root = Get-UninstallRegistryRoot -InstallScope `$InstallScope
    New-Item -Path `$root -Force | Out-Null

    Remove-UninstallEntry -Name `$Name

    `$keyName = Get-UninstallKeyName -Name `$Name
    `$entryPath = Join-Path `$root `$keyName
    New-Item -Path `$entryPath -Force | Out-Null

    `$displayName = 'Morpheus PowerShell Module'
    `$estimatedSizeKb = [int]([Math]::Ceiling(((Get-ChildItem -Path `$InstallPath -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB))
    if (`$estimatedSizeKb -lt 1) { `$estimatedSizeKb = 1 }

    `$uninstallCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File "{0}" -ModuleName "{1}" -ModuleVersion "{2}" -Scope "{3}"' -f `$UninstallScriptPath, `$Name, `$Version, `$InstallScope

    New-ItemProperty -Path `$entryPath -Name 'DisplayName' -Value `$displayName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'DisplayVersion' -Value `$Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'Publisher' -Value 'Morpheus' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'Comments' -Value 'Morpheus OpenAPI PowerShell Module' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'InstallDate' -Value (Get-Date -Format 'yyyyMMdd') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'InstallSource' -Value `$PSScriptRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'URLInfoAbout' -Value 'https://github.com/gomorpheus' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'HelpLink' -Value 'https://github.com/gomorpheus/morpheus-openapi' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'InstallLocation' -Value `$InstallPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'UninstallString' -Value `$uninstallCmd -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'QuietUninstallString' -Value (`$uninstallCmd + ' -Quiet') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'EstimatedSize' -Value `$estimatedSizeKb -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path `$entryPath -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null
}

function New-UninstallScript {
    param(
        [Parameter(Mandatory = `$true)][string]`$InstallPath,
        [Parameter(Mandatory = `$true)][string]`$Name,
        [Parameter(Mandatory = `$true)][string]`$Version,
        [Parameter(Mandatory = `$true)][string]`$InstallScope
    )

    `$scriptPath = Join-Path `$InstallPath 'uninstall.ps1'
    `$content = @'
param(
    [Parameter()][string]`$ModuleName = '{NAME}',
    [Parameter()][string]`$ModuleVersion = '{VERSION}',
    [Parameter()][ValidateSet('current','all')][string]`$Scope = '{SCOPE}',
    [Parameter()][switch]`$Quiet
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

function Resolve-TargetRoot {
    param([string]`$InstallScope)
    if (`$InstallScope -eq 'all') {
        `$programFilesModules = Join-Path `$env:ProgramFiles 'PowerShell\\Modules'
        if (Test-Path -Path `$programFilesModules) { return `$programFilesModules }
        return Join-Path `$env:ProgramFiles 'WindowsPowerShell\\Modules'
    }
    return Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\\Modules'
}

function Get-UninstallKeyName {
    param([string]`$Name)
    return ("`${Name}" -replace '[^a-zA-Z0-9_.-]', '_')
}

function Get-UninstallRegistryRoot {
    param([string]`$InstallScope)
    if (`$InstallScope -eq 'all') { return 'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall' }
    return 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
}

function Remove-DirectoryRobust {
    param([Parameter(Mandatory = `$true)][string]`$Path)

    if (-not (Test-Path -Path `$Path)) { return `$true }

    try {
        Remove-Item -Path `$Path -Recurse -Force -ErrorAction Stop
        return `$true
    }
    catch {
        `$cleanupCmd = Join-Path `$env:TEMP ("morpheus-cleanup-" + [guid]::NewGuid().ToString('N') + '.cmd')
        `$moduleRoot = Split-Path -Parent `$Path
        `$cmdBody = @(
            '@echo off',
            'setlocal',
            'set RETRY=0',
            ':retry',
            ('if not exist "' + `$Path + '" goto afterdelete'),
            ('rmdir /s /q "' + `$Path + '" 2>nul'),
            ('if exist "' + `$Path + '" ('),
            '  set /a RETRY+=1',
            '  if %RETRY% GEQ 10 goto afterdelete',
            '  ping 127.0.0.1 -n 2 >nul',
            '  goto retry',
            ')',
            ':afterdelete',
            ('for %%I in ("' + `$moduleRoot + '") do rd "%%~fI" 2>nul'),
            'del "%~f0"'
        ) -join "`r`n"

        Set-Content -Path `$cleanupCmd -Value `$cmdBody -Encoding ASCII -Force
        Start-Process -FilePath `$env:ComSpec -ArgumentList ('/c "' + `$cleanupCmd + '"') -WindowStyle Hidden
        return `$false
    }
}

`$targetRoot = Resolve-TargetRoot -InstallScope `$Scope
`$defaultTarget = Join-Path `$targetRoot "`$ModuleName\`$ModuleVersion"
`$target = '{INSTALLPATH}'
if ([string]::IsNullOrWhiteSpace(`$target)) { `$target = `$defaultTarget }

if (-not `$Quiet) {
    Add-Type -AssemblyName System.Windows.Forms
    `$prompt = "Uninstall Morpheus PowerShell Module v`$ModuleVersion (`$Scope)?`r`n`r`nLocation:`r`n`$target"
    `$choice = [System.Windows.Forms.MessageBox]::Show(`$prompt, 'Confirm Uninstall', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if (`$choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        exit 1
    }
}

foreach (`$root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
    `$entryPath = Join-Path `$root (Get-UninstallKeyName -Name `$ModuleName)
    if (Test-Path -Path `$entryPath) {
        Remove-Item -Path `$entryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach (`$legacy in @(Get-ChildItem -Path `$root -ErrorAction SilentlyContinue | Where-Object { `$_.PSChildName -like "`$ModuleName_*" })) {
        Remove-Item -Path `$legacy.PSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

`$removedImmediately = Remove-DirectoryRobust -Path `$target

if (-not `$Quiet) {
    Add-Type -AssemblyName System.Windows.Forms
    if (`$removedImmediately) {
        [System.Windows.Forms.MessageBox]::Show("Uninstalled `$ModuleName v`$ModuleVersion (`$Scope).`r`n`r`nFiles were removed.", 'Uninstall Complete', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Uninstalled `$ModuleName v`$ModuleVersion (`$Scope).`r`n`r`nSome files were in use and are scheduled for cleanup.", 'Uninstall Complete', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}
'@

    `$content = `$content.Replace('{NAME}', `$Name).Replace('{VERSION}', `$Version).Replace('{SCOPE}', `$InstallScope).Replace('{INSTALLPATH}', `$InstallPath)

    Set-Content -Path `$scriptPath -Value `$content -Encoding UTF8
    return `$scriptPath
}

function Install-ModuleFiles {
    param(
        [Parameter(Mandatory = `$true)][string]`$BaseDir,
        [Parameter(Mandatory = `$true)][string]`$Name,
        [Parameter(Mandatory = `$true)][string]`$Version,
        [Parameter(Mandatory = `$true)][string]`$InstallScope
    )

    if (`$InstallScope -eq 'all' -and -not (Test-IsAdministrator)) {
        throw 'All-users install requires an elevated Administrator session.'
    }

    `$desiredVersion = [version]::Parse(`$Version)
    `$existing = @(Get-InstalledModuleVersions -Name `$Name -InstallScope `$InstallScope)
    `$otherScope = if (`$InstallScope -eq 'all') { 'current' } else { 'all' }
    `$existingOtherScope = @(Get-InstalledModuleVersions -Name `$Name -InstallScope `$otherScope)

    `$globalHigher = @((@(`$existing) + @(`$existingOtherScope)) | Where-Object { `$_.Version -gt `$desiredVersion } | Sort-Object -Property Version -Descending | Select-Object -First 1)
    if (`$globalHigher.Count -gt 0) {
        throw "Downgrade blocked. Version `$(`$globalHigher[0].VersionText) is already installed. Uninstall version `$(`$globalHigher[0].VersionText) first."
    }

    `$otherScopeSame = @(`$existingOtherScope | Where-Object { `$_.Version -eq `$desiredVersion } | Select-Object -First 1)
    if (`$otherScopeSame.Count -gt 0 -and `$otherScope -eq 'all' -and -not (Test-IsAdministrator)) {
        throw 'Scope migration from All Users to Current User requires running installer as Administrator to preserve a single unified app entry.'
    }
    `$sameVersion = @(`$existing | Where-Object { `$_.Version -eq `$desiredVersion } | Select-Object -First 1)
    `$isReinstall = (`$sameVersion.Count -gt 0)

    `$preservedProfileTempPath = `$null
    `$profileSourcePath = `$null

    if (`$sameVersion.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]`$sameVersion[0].Path)) {
        `$candidateProfile = Join-Path `$sameVersion[0].Path 'Morpheus.OpenApi.ColumnProfiles.psd1'
        if (Test-Path -Path `$candidateProfile) {
            `$profileSourcePath = `$candidateProfile
        }
    }

    if (-not `$profileSourcePath) {
        foreach (`$candidate in @(`$existing | Sort-Object -Property Version -Descending)) {
            if (`$null -eq `$candidate -or [string]::IsNullOrWhiteSpace([string]`$candidate.Path)) { continue }
            `$candidateProfile = Join-Path `$candidate.Path 'Morpheus.OpenApi.ColumnProfiles.psd1'
            if (Test-Path -Path `$candidateProfile) {
                `$profileSourcePath = `$candidateProfile
                break
            }
        }
    }

    if (-not `$profileSourcePath) {
        foreach (`$candidate in @(`$existingOtherScope | Sort-Object -Property Version -Descending)) {
            if (`$null -eq `$candidate -or [string]::IsNullOrWhiteSpace([string]`$candidate.Path)) { continue }
            `$candidateProfile = Join-Path `$candidate.Path 'Morpheus.OpenApi.ColumnProfiles.psd1'
            if (Test-Path -Path `$candidateProfile) {
                `$profileSourcePath = `$candidateProfile
                break
            }
        }
    }

    if (`$profileSourcePath -and (Test-Path -Path `$profileSourcePath)) {
        try {
            `$tempRoot = if ([string]::IsNullOrWhiteSpace(`$env:TEMP)) { [System.IO.Path]::GetTempPath() } else { `$env:TEMP }
            `$preservedProfileTempPath = Join-Path `$tempRoot ("Morpheus.OpenApi.ColumnProfiles.`$([guid]::NewGuid().ToString('N')).psd1")
            Copy-Item -Path `$profileSourcePath -Destination `$preservedProfileTempPath -Force -ErrorAction Stop
        }
        catch {
            `$preservedProfileTempPath = `$null
        }
    }

    if (`$sameVersion.Count -gt 0) {
        if (`$isReinstall) {
            if (Test-Path -Path `$sameVersion[0].Path) {
                Remove-Item -Path `$sameVersion[0].Path -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-UninstallEntry -Name `$Name
        }
        else {
        `$existingPath = `$sameVersion[0].Path
        `$uninstallScriptPath = Join-Path `$existingPath 'uninstall.ps1'
        if (-not (Test-Path -Path `$uninstallScriptPath)) {
            `$uninstallScriptPath = New-UninstallScript -InstallPath `$existingPath -Name `$Name -Version `$Version -InstallScope `$InstallScope
        }
        Set-UninstallEntry -Name `$Name -Version `$Version -InstallScope `$InstallScope -InstallPath `$existingPath -UninstallScriptPath `$uninstallScriptPath

        foreach (`$legacyOther in @(`$existingOtherScope)) {
            if (Test-Path -Path `$legacyOther.Path) {
                Remove-Item -Path `$legacyOther.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-UninstallEntry -Name `$Name
        Set-UninstallEntry -Name `$Name -Version `$Version -InstallScope `$InstallScope -InstallPath `$existingPath -UninstallScriptPath `$uninstallScriptPath

        return [pscustomobject]@{
            Status = 'AlreadyInstalled'
            InstalledPath = `$existingPath
            ExistingVersion = `$sameVersion[0].VersionText
            Message = "`$Name v`$Version is already installed for this scope. Uninstall entry is up to date."
        }
        }
    }

    `$targetRoot = Resolve-TargetRoot -InstallScope `$InstallScope
    `$target = Join-Path `$targetRoot "`$Name\`$Version"

    `$lower = @(`$existing | Where-Object { `$_.Version -lt `$desiredVersion })
    foreach (`$old in `$lower) {
        if (Test-Path -Path `$old.Path) {
            Remove-Item -Path `$old.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-UninstallEntry -Name `$Name
    }

    foreach (`$oldOther in @(`$existingOtherScope)) {
        if (Test-Path -Path `$oldOther.Path) {
            Remove-Item -Path `$oldOther.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-UninstallEntry -Name `$Name
    }

    New-Item -ItemType Directory -Path `$targetRoot -Force | Out-Null
    if (Test-Path -Path `$target) { Remove-Item -Path `$target -Recurse -Force }
    New-Item -ItemType Directory -Path `$target -Force | Out-Null

    `$files = @(
        'Morpheus.OpenApi.psd1',
        'Morpheus.OpenApi.psm1',
        'Morpheus.OpenApi.ColumnProfiles.psd1',
        'README.md'
    )

    foreach (`$file in `$files) {
        `$source = Join-Path `$BaseDir `$file
        if (-not (Test-Path -Path `$source)) {
            throw "Required installer file not found: [`$source]"
        }
        Copy-Item -Path `$source -Destination (Join-Path `$target `$file) -Force
    }

    if (`$preservedProfileTempPath -and (Test-Path -Path `$preservedProfileTempPath)) {
        Copy-Item -Path `$preservedProfileTempPath -Destination (Join-Path `$target 'Morpheus.OpenApi.ColumnProfiles.psd1') -Force -ErrorAction SilentlyContinue
        Remove-Item -Path `$preservedProfileTempPath -Force -ErrorAction SilentlyContinue
    }

    `$manifestInstalled = Join-Path `$target 'Morpheus.OpenApi.psd1'
    if (-not (Test-Path -Path `$manifestInstalled)) {
        throw 'Installation verification failed. Manifest file was not found after copy.'
    }

    `$uninstallScriptPath = New-UninstallScript -InstallPath `$target -Name `$Name -Version `$Version -InstallScope `$InstallScope
    Set-UninstallEntry -Name `$Name -Version `$Version -InstallScope `$InstallScope -InstallPath `$target -UninstallScriptPath `$uninstallScriptPath

    `$status = if (`$isReinstall) { 'Reinstalled' } elseif (`$otherScopeSame.Count -gt 0) { 'Modified' } elseif (`$lower.Count -gt 0) { 'Upgraded' } else { 'Installed' }
    `$message = if (`$status -eq 'Upgraded') {
        "Upgraded to `$Name v`$Version."
    }
    elseif (`$status -eq 'Reinstalled') {
        "Reinstalled `$Name v`$Version."
    }
    elseif (`$status -eq 'Modified') {
        "Modified install scope to `$InstallScope for `$Name v`$Version."
    }
    else {
        "Installed `$Name v`$Version."
    }

    return [pscustomobject]@{
        Status = `$status
        InstalledPath = `$target
        ExistingVersion = `$null
        Message = `$message
    }
}

if (`$Quiet) {
    try {
        Initialize-InstallerLog
        Initialize-InstallerMutex
        Write-InstallerLog ("Quiet install requested. Scope=`$Scope")
        `$pre = Test-InstallerPrerequisites -InstallScope `$Scope
        if (-not `$pre.CanContinue) {
            `$msg = (`$pre.Issues -join '; ')
            Write-InstallerLog ("Prerequisite failure: `$msg")
            throw `$msg
        }
        `$result = Install-ModuleFiles -BaseDir `$PSScriptRoot -Name `$ModuleName -Version `$ModuleVersion -InstallScope `$Scope
        Write-InstallerLog ("Install result: Status=`$(`$result.Status) Path=`$(`$result.InstalledPath)")
        Write-Host `$result.Message
        Write-Host "Path: `$(`$result.InstalledPath)"
        Write-Host "Log: `$script:InstallerLogPath"
        exit 0
    }
    catch {
        Write-InstallerLog ("ERROR: `$(`$_.Exception.Message)")
        Write-Error `$_.Exception.Message
        exit 1
    }
    finally {
        Dispose-InstallerMutex
    }
}

try {
    Initialize-InstallerLog
    Initialize-InstallerMutex
}
catch {
    try {
        if (-not [string]::IsNullOrWhiteSpace(`$script:InstallerLogPath)) {
            Write-InstallerLog ("Startup failure: `$(`$_.Exception.Message)")
        }
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(("Installer failed to initialize.`r`n`r`n" + `$_.Exception.Message + "`r`n`r`nLog: " + `$script:InstallerLogPath), 'Morpheus Installer Error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    finally {
        Dispose-InstallerMutex
    }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

`$form = New-Object System.Windows.Forms.Form
`$form.Text = "`$ModuleName Installer"
`$form.StartPosition = 'CenterScreen'
`$form.Size = New-Object System.Drawing.Size(640, 430)
`$form.FormBorderStyle = 'FixedDialog'
`$form.MaximizeBox = `$false
`$form.MinimizeBox = `$false
`$form.TopMost = `$true

`$header = New-Object System.Windows.Forms.Label
`$header.AutoSize = `$false
`$header.Location = New-Object System.Drawing.Point(20, 15)
`$header.Size = New-Object System.Drawing.Size(590, 24)
`$header.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
`$form.Controls.Add(`$header)

`$panel = New-Object System.Windows.Forms.Panel
`$panel.Location = New-Object System.Drawing.Point(20, 50)
`$panel.Size = New-Object System.Drawing.Size(590, 270)
`$form.Controls.Add(`$panel)

`$btnBack = New-Object System.Windows.Forms.Button
`$btnBack.Text = 'Back'
`$btnBack.Location = New-Object System.Drawing.Point(340, 335)
`$btnBack.Size = New-Object System.Drawing.Size(80, 28)
`$btnBack.TabIndex = 100
`$form.Controls.Add(`$btnBack)

`$btnNext = New-Object System.Windows.Forms.Button
`$btnNext.Text = 'Next >'
`$btnNext.Location = New-Object System.Drawing.Point(430, 335)
`$btnNext.Size = New-Object System.Drawing.Size(80, 28)
`$btnNext.TabIndex = 101
`$form.Controls.Add(`$btnNext)

`$btnCancel = New-Object System.Windows.Forms.Button
`$btnCancel.Text = 'Cancel'
`$btnCancel.Location = New-Object System.Drawing.Point(520, 335)
`$btnCancel.Size = New-Object System.Drawing.Size(80, 28)
`$btnCancel.TabIndex = 102
`$form.Controls.Add(`$btnCancel)

`$btnBack.BringToFront()
`$btnNext.BringToFront()
`$btnCancel.BringToFront()

`$script:Page = 1
`$selectedScope = 'current'
`$installedPath = ''
`$installResult = `$null

`$lblInfo = New-Object System.Windows.Forms.Label
`$lblInfo.AutoSize = `$false
`$lblInfo.Location = New-Object System.Drawing.Point(0, 0)
`$lblInfo.Size = New-Object System.Drawing.Size(590, 260)
`$lblInfo.Font = New-Object System.Drawing.Font('Segoe UI', 10)
`$lblInfo.Text = "This installer will install:`r`n`r`n- Morpheus PowerShell Module`r`n- Version: v`$ModuleVersion`r`n- Requirement: PowerShell 7.0 or newer`r`n- Installer log: `$script:InstallerLogPath"

`$lblScope = New-Object System.Windows.Forms.Label
`$lblScope.AutoSize = `$false
`$lblScope.Location = New-Object System.Drawing.Point(0, 0)
`$lblScope.Size = New-Object System.Drawing.Size(590, 36)
`$lblScope.Font = New-Object System.Drawing.Font('Segoe UI', 10)
`$lblScope.Text = 'Choose installation scope:'

`$rbCurrent = New-Object System.Windows.Forms.RadioButton
`$rbCurrent.Location = New-Object System.Drawing.Point(20, 50)
`$rbCurrent.Size = New-Object System.Drawing.Size(520, 30)
`$rbCurrent.Text = 'Current user (no Administrator privileges required)'
`$rbCurrent.Checked = `$true

`$rbAll = New-Object System.Windows.Forms.RadioButton
`$rbAll.Location = New-Object System.Drawing.Point(20, 90)
`$rbAll.Size = New-Object System.Drawing.Size(560, 30)
`$rbAll.Text = 'All users (requires running installer as Administrator)'

`$lblScopePath = New-Object System.Windows.Forms.Label
`$lblScopePath.AutoSize = `$false
`$lblScopePath.Location = New-Object System.Drawing.Point(20, 140)
`$lblScopePath.Size = New-Object System.Drawing.Size(560, 70)
`$lblScopePath.Font = New-Object System.Drawing.Font('Segoe UI', 9)

`$lblScopeWarning = New-Object System.Windows.Forms.Label
`$lblScopeWarning.AutoSize = `$false
`$lblScopeWarning.Location = New-Object System.Drawing.Point(20, 215)
`$lblScopeWarning.Size = New-Object System.Drawing.Size(560, 50)
`$lblScopeWarning.Font = New-Object System.Drawing.Font('Segoe UI', 9)
`$lblScopeWarning.ForeColor = [System.Drawing.Color]::DarkRed
`$lblScopeWarning.Text = ''

`$lblProgress = New-Object System.Windows.Forms.Label
`$lblProgress.AutoSize = `$false
`$lblProgress.Location = New-Object System.Drawing.Point(0, 0)
`$lblProgress.Size = New-Object System.Drawing.Size(590, 36)
`$lblProgress.Font = New-Object System.Drawing.Font('Segoe UI', 10)
`$lblProgress.Text = 'Installing files...'

`$progressBar = New-Object System.Windows.Forms.ProgressBar
`$progressBar.Location = New-Object System.Drawing.Point(0, 50)
`$progressBar.Size = New-Object System.Drawing.Size(560, 24)
`$progressBar.Style = 'Continuous'
`$progressBar.Minimum = 0
`$progressBar.Maximum = 100

`$lblComplete = New-Object System.Windows.Forms.Label
`$lblComplete.AutoSize = `$false
`$lblComplete.Location = New-Object System.Drawing.Point(0, 0)
`$lblComplete.Size = New-Object System.Drawing.Size(590, 220)
`$lblComplete.Font = New-Object System.Drawing.Font('Segoe UI', 10)

function Update-ScopePath {
    `$scopeNow = if (`$rbAll.Checked) { 'all' } elseif (`$rbCurrent.Checked) { 'current' } else { '' }
    if ([string]::IsNullOrWhiteSpace(`$scopeNow)) {
        `$lblScopePath.Text = 'Install path:`r`n(choose Current user or All users to continue)'
        return
    }
    `$root = Resolve-TargetRoot -InstallScope `$scopeNow
    `$targetPreview = Join-Path `$root "`$ModuleName\`$ModuleVersion"
    `$lblScopePath.Text = "Install path:`r`n`$targetPreview"
}

function Update-Step2State {
    if (`$script:Page -ne 2) { return }

    `$scopeNow = if (`$rbAll.Checked) { 'all' } elseif (`$rbCurrent.Checked) { 'current' } else { '' }
    if ([string]::IsNullOrWhiteSpace(`$scopeNow)) {
        `$btnNext.Enabled = `$false
        `$btnNext.Text = 'Install'
        `$btnCancel.Text = 'Cancel'
        `$lblScopeWarning.Text = 'Select an install scope to continue.'
        return
    }

    `$selectedScope = `$scopeNow
    `$pre = Test-InstallerPrerequisites -InstallScope `$selectedScope
    if (-not `$pre.CanContinue) {
        `$btnNext.Enabled = `$false
        `$btnNext.Text = 'Install'
        `$btnCancel.Text = 'Close'
        `$lblScopeWarning.ForeColor = [System.Drawing.Color]::DarkRed
        `$lblScopeWarning.Text = (`$pre.Issues -join "`r`n")
        return
    }

    `$evaluation = Get-InstallEvaluation -Name `$ModuleName -Version `$ModuleVersion -InstallScope `$selectedScope
    if (`$evaluation.CanInstall) {
        `$btnNext.Enabled = `$true
        `$btnNext.Text = 'Install'
        `$btnCancel.Text = 'Cancel'
        if (`$evaluation.Status -eq 'Upgrade') {
            `$lblScopeWarning.ForeColor = [System.Drawing.Color]::DarkOrange
            `$lblScopeWarning.Text = `$evaluation.Message
        }
        else {
            `$lblScopeWarning.ForeColor = [System.Drawing.Color]::DarkGreen
            `$lblScopeWarning.Text = `$evaluation.Message
        }
    }
    else {
        `$btnNext.Enabled = `$false
        `$btnNext.Text = 'Install'
        `$btnCancel.Text = 'Close'
        `$lblScopeWarning.ForeColor = [System.Drawing.Color]::DarkRed
        `$lblScopeWarning.Text = `$evaluation.Message
    }
}

`$rbCurrent.Add_CheckedChanged({
    if (`$rbCurrent.Checked) {
        `$selectedScope = 'current'
    }
    Update-ScopePath
    Update-Step2State
})

`$rbAll.Add_CheckedChanged({
    if (`$rbAll.Checked) {
        `$selectedScope = 'all'
    }
    Update-ScopePath
    Update-Step2State
})

function Show-Page {
    param([int]`$number)

    `$panel.Controls.Clear()
    `$script:Page = `$number

    switch (`$script:Page) {
        1 {
            `$header.Text = 'Step 1 of 4: Installer Information'
            `$panel.Controls.Add(`$lblInfo)
            `$btnBack.Enabled = `$false
            `$btnNext.Enabled = `$true
            `$btnNext.Text = 'Next >'
        }
        2 {
            `$header.Text = 'Step 2 of 4: Installation Scope'
            `$panel.Controls.Add(`$lblScope)
            `$panel.Controls.Add(`$rbCurrent)
            `$panel.Controls.Add(`$rbAll)
            `$panel.Controls.Add(`$lblScopePath)
            `$panel.Controls.Add(`$lblScopeWarning)

            if (`$selectedScope -eq 'all') {
                `$rbAll.Checked = `$true
                `$rbCurrent.Checked = `$false
            }
            else {
                `$rbCurrent.Checked = `$true
                `$rbAll.Checked = `$false
            }

            Update-ScopePath
            `$btnBack.Enabled = `$true
            `$btnNext.Text = 'Install'
            `$btnCancel.Enabled = `$true
            `$btnCancel.Text = 'Cancel'
            Update-Step2State
        }
        3 {
            `$header.Text = 'Step 3 of 4: Installation Progress'
            `$panel.Controls.Add(`$lblProgress)
            `$panel.Controls.Add(`$progressBar)
            `$btnBack.Enabled = `$false
            `$btnNext.Enabled = `$false
            `$btnCancel.Enabled = `$false
            `$form.Refresh()

            try {
                `$selectedScope = if (`$rbAll.Checked) { 'all' } else { 'current' }
                Write-InstallerLog ("Starting interactive install. Scope=`$selectedScope")
                `$progressBar.Value = 20
                `$form.Refresh()

                `$installResult = Install-ModuleFiles -BaseDir `$PSScriptRoot -Name `$ModuleName -Version `$ModuleVersion -InstallScope `$selectedScope
                `$installedPath = [string]`$installResult.InstalledPath
                Write-InstallerLog ("Install completed. Status=`$(`$installResult.Status) Path=`$installedPath")

                `$progressBar.Value = 100
                `$form.Refresh()
                Show-Page -number 4
            }
            catch {
                Write-InstallerLog ("Install failed: `$(`$_.Exception.Message)")
                [System.Windows.Forms.MessageBox]::Show(`$_.Exception.Message, 'Installation Failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                `$btnCancel.Enabled = `$true
                Show-Page -number 2
            }
        }
        4 {
            `$header.Text = 'Step 4 of 4: Completed'
            if (`$installResult -and `$installResult.Status -eq 'AlreadyInstalled') {
                `$lblComplete.Text = "No changes made.`r`n`r`n`$(`$installResult.Message)`r`n`r`nInstalled path:`r`n`$installedPath`r`n`r`nLog:`r`n`$script:InstallerLogPath`r`n`r`nClick Done to acknowledge and close."
            }
            elseif (`$installResult -and `$installResult.Status -eq 'Modified') {
                `$lblComplete.Text = "Install scope modified successfully.`r`n`r`n`$(`$installResult.Message)`r`n`r`nInstalled to:`r`n`$installedPath`r`n`r`nLog:`r`n`$script:InstallerLogPath`r`n`r`nClick Done to acknowledge and close."
            }
            elseif (`$installResult -and `$installResult.Status -eq 'Reinstalled') {
                `$lblComplete.Text = "Reinstall completed successfully.`r`n`r`n`$(`$installResult.Message)`r`n`r`nInstalled to:`r`n`$installedPath`r`n`r`nLog:`r`n`$script:InstallerLogPath`r`n`r`nClick Done to acknowledge and close."
            }
            elseif (`$installResult -and `$installResult.Status -eq 'Upgraded') {
                `$lblComplete.Text = "Upgrade completed successfully.`r`n`r`n`$(`$installResult.Message)`r`n`r`nInstalled to:`r`n`$installedPath`r`n`r`nLog:`r`n`$script:InstallerLogPath`r`n`r`nClick Done to acknowledge and close."
            }
            else {
                `$lblComplete.Text = "Installation completed successfully.`r`n`r`nInstalled to:`r`n`$installedPath`r`n`r`nLog:`r`n`$script:InstallerLogPath`r`n`r`nClick Done to acknowledge and close."
            }
            `$panel.Controls.Add(`$lblComplete)
            `$btnBack.Enabled = `$false
            `$btnCancel.Enabled = `$false
            `$btnNext.Enabled = `$true
            `$btnNext.Text = 'Done'
        }
    }
}

`$btnBack.Add_Click({
    switch (`$script:Page) {
        2 { Show-Page -number 1 }
    }
})

`$btnNext.Add_Click({
    switch (`$script:Page) {
        1 { Show-Page -number 2 }
        2 { Show-Page -number 3 }
        4 { `$form.DialogResult = [System.Windows.Forms.DialogResult]::OK; `$form.Close() }
    }
})

`$btnCancel.Add_Click({ `$form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; `$form.Close() })

Show-Page -number 1
[void]`$form.ShowDialog()

if (`$form.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
    Dispose-InstallerMutex
    exit 0
}

Dispose-InstallerMutex
exit 1
"@
Set-Content -Path $installUiPath -Value $installUi -Encoding UTF8

$safeOutputDir = $OutputDir
$safeInstallerName = $installerFileName
$safeStagingRoot = $stagingRoot

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=This installer will install $moduleName $moduleVersion. You can choose Current user or All users.
DisplayLicense=
FinishMessage=
TargetName=$safeOutputDir\\$safeInstallerName
FriendlyName=$moduleName $moduleVersion Installer
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=install.cmd /quiet /allusers
UserQuietInstCmd=install.cmd /quiet
SourceFiles=SourceFiles
[SourceFiles]
SourceFiles0=$safeStagingRoot
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
%FILE4%=
%FILE5%=
[Strings]
FILE0=install.cmd
FILE1=install-ui.ps1
FILE2=Morpheus.OpenApi.psd1
FILE3=Morpheus.OpenApi.psm1
FILE4=Morpheus.OpenApi.ColumnProfiles.psd1
FILE5=README.md
"@
Set-Content -Path $sedPath -Value $sed -Encoding ASCII

if (Test-Path -Path $installerPath) {
    Remove-Item -Path $installerPath -Force
}

try {
    $iexpressOutLog = Join-Path -Path $stagingRoot -ChildPath 'iexpress.out.log'
    $iexpressErrLog = Join-Path -Path $stagingRoot -ChildPath 'iexpress.err.log'
    $proc = Start-Process -FilePath $iexpress -ArgumentList @('/N', '/Q', $sedPath) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $iexpressOutLog -RedirectStandardError $iexpressErrLog
    $outText = if (Test-Path -Path $iexpressOutLog) { Get-Content -Raw -Path $iexpressOutLog } else { '' }
    $errText = if (Test-Path -Path $iexpressErrLog) { Get-Content -Raw -Path $iexpressErrLog } else { '' }
    $iexpressOutput = ($outText + "`n" + $errText).Trim()
    if ($proc.ExitCode -ne 0) {
        throw "IExpress failed with exit code [$($proc.ExitCode)]. Output: $iexpressOutput"
    }
    if (-not (Test-Path -Path $installerPath)) {
        throw "IExpress did not produce installer at [$installerPath]. Output: $iexpressOutput"
    }

    $signingInfo = Get-SigningCertificate -Thumbprint $CertificateThumbprint -StorePath $CertificateStore -PfxFilePath $PfxPath -PfxSecurePassword $PfxPassword
    if ($null -ne $signingInfo) {
        try {
            $sigParams = @{
                FilePath = $installerPath
                Certificate = $signingInfo.Certificate
            }
            if (-not $SkipTimestamp -and -not [string]::IsNullOrWhiteSpace($TimestampServer)) {
                $sigParams.TimestampServer = $TimestampServer
            }

            $signResult = Set-AuthenticodeSignature @sigParams
            $verifyResult = Get-AuthenticodeSignature -FilePath $installerPath
            if ($null -eq $verifyResult.SignerCertificate) {
                throw 'Signature was not applied to installer executable.'
            }

            Write-Host "Signed installer with certificate thumbprint: $($verifyResult.SignerCertificate.Thumbprint)"
            if ($verifyResult.Status -ne 'Valid') {
                Write-Warning "Installer signature status is [$($verifyResult.Status)] on this machine."
            }
        }
        finally {
            if ($signingInfo.Imported -and $signingInfo.ImportedThumbprint) {
                $importedPath = "Cert:\CurrentUser\My\$($signingInfo.ImportedThumbprint)"
                if (Test-Path -Path $importedPath) {
                    Remove-Item -Path $importedPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
finally {
    Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Created installer executable: $installerPath"
Write-Host "Version: $moduleVersion"