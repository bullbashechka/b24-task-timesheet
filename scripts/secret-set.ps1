# Stores a secret for the scripts in scripts/ on Windows (the macOS counterpart is the Keychain).
# Run it yourself in your own PowerShell window; the value is typed or pasted with hidden input:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\secret-set.ps1 b24-dev-webhook
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\secret-set.ps1 openai-dev-key
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\secret-set.ps1 openai-dev-key -Delete
# The value is encrypted with DPAPI for the current Windows user and written to
# %LOCALAPPDATA%\b24-task-timesheet\secrets\<name>.dpapi. Only this user on this computer can decrypt it.
# scripts/common.sh (secret_get) reads it. The file never goes into git: it is outside the repository.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Name,
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'b24-task-timesheet\secrets'
$file = Join-Path $dir "$Name.dpapi"

if ($Delete) {
    if (Test-Path -LiteralPath $file) {
        Remove-Item -LiteralPath $file -Force
        Write-Host "Deleted: $Name"
    } else {
        Write-Host "Not stored: $Name"
    }
    exit 0
}

$value = Read-Host -AsSecureString "Value of $Name (input is hidden, paste and press Enter)"
if ($value.Length -eq 0) {
    Write-Host 'Empty value: nothing was written.'
    exit 2
}
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$value | ConvertFrom-SecureString | Set-Content -LiteralPath $file -Encoding Ascii
Write-Host "Stored: $Name ($($value.Length) characters)"
