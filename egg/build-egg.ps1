# Builds egg-farming-simulator-25.json from egg.template.json + install.sh.
# Usage: powershell -File build-egg.ps1 -Image ghcr.io/<owner>/pelican-fs25:latest -Author you@example.com
#        [-UpdateUrl https://raw.githubusercontent.com/<owner>/<repo>/main/egg/egg-farming-simulator-25.json]
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$Author,
    [string]$UpdateUrl = '',
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = [IO.File]::ReadAllText("$here\install.sh") -replace "`r`n", "`n"
$scriptJson = ConvertTo-Json $script
$updateJson = if ($UpdateUrl) { ConvertTo-Json $UpdateUrl } else { 'null' }
$json = [IO.File]::ReadAllText("$here\egg.template.json")
$json = $json.Replace('__SCRIPT__', $scriptJson).Replace('__IMAGE__', $Image).Replace('__AUTHOR__', $Author).Replace('__UPDATE_URL__', $updateJson)
$null = $json | ConvertFrom-Json   # validate
if (-not $Out) { $Out = "$here\egg-farming-simulator-25.json" }
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding $false))
Write-Output "written $Out with image $Image"
