# Checks the built helper: an x64 exe of the GUI subsystem that needs no C runtime DLL on the host
# Usage: pwsh helper-win/scripts/check-exe.ps1 <path to vibe-seam-helper.exe>
# Runs on Windows with the Visual Studio C++ build tools, which provide dumpbin
param(
    [Parameter(Mandatory)]
    [string]$Exe
)
$ErrorActionPreference = 'Stop'

$bytes = [IO.File]::ReadAllBytes($Exe)
$pe = [BitConverter]::ToInt32($bytes, 0x3C)
if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) {
    throw "$Exe is not a PE image"
}

$machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
if ($machine -ne 0x8664) {
    throw ("{0} is not x64: machine 0x{1:X4}" -f $Exe, $machine)
}

# The optional header follows the 4-byte signature and the 20-byte file header; Subsystem sits 68 bytes into it
$subsystem = [BitConverter]::ToUInt16($bytes, $pe + 24 + 68)
if ($subsystem -ne 2) {
    throw "$Exe uses subsystem $subsystem, not the GUI one (2): a console window would open at every logon"
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin) {
    throw 'dumpbin not found: install the Visual Studio C++ build tools'
}

$dependents = & $dumpbin /nologo /dependents $Exe |
    Where-Object { $_ -match '^\s+\S+\.dll\s*$' } |
    ForEach-Object { $_.Trim() }
if (-not $dependents) {
    throw "dumpbin listed no DLLs for $Exe: the check cannot tell what it needs"
}

# A statically linked C runtime leaves none of these: the helper installs by copying one file
$runtime = $dependents | Where-Object { $_ -match '^(vcruntime|msvcp|ucrtbase|api-ms-win-crt-)' }
if ($runtime) {
    throw "$Exe needs the C runtime DLLs $($runtime -join ', '): +crt-static did not apply"
}

Write-Host "OK: $Exe is x64, GUI subsystem, depends on $($dependents -join ', ')"
