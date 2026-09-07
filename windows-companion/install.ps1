param(
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $projectRoot 'src\PaperGIF.Windows.Host\PaperGIF.Windows.Host.csproj'
$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\paperGIF'
$executable = Join-Path $installDirectory 'PaperGIF.Windows.Host.exe'
$shortcutName = 'paperGIF Windows Companion.lnk'

Get-Process 'PaperGIF.Windows.Host' -ErrorAction SilentlyContinue |
    Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" |
    Where-Object { $_.CommandLine -like '*PaperGIF.Windows.Host.dll*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

$stagingDirectory = Join-Path $env:TEMP 'paperGIF-publish'
Remove-Item $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
dotnet publish $project `
    --configuration Release `
    --framework net8.0-windows10.0.22621.0 `
    --output $stagingDirectory `
    --no-restore
if ($LASTEXITCODE -ne 0) {
    throw "paperGIF publish failed with exit code $LASTEXITCODE."
}

New-Item $installDirectory -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $stagingDirectory '*') $installDirectory -Recurse -Force
Remove-Item $stagingDirectory -Recurse -Force

$shell = New-Object -ComObject WScript.Shell
$shortcutLocations = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName),
    (Join-Path ([Environment]::GetFolderPath('Programs')) $shortcutName)
)
foreach ($shortcutPath in $shortcutLocations) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.WorkingDirectory = $installDirectory
    $shortcut.IconLocation = "$executable,0"
    $shortcut.Description = 'Design and run paperGIF remotes'
    $shortcut.Save()
}

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Remove-ItemProperty `
    -Path $runKey `
    -Name 'paperGIF Windows Companion' `
    -ErrorAction SilentlyContinue

$taskName = 'paperGIF Windows Companion'
$taskAction = New-ScheduledTaskAction `
    -Execute $executable `
    -WorkingDirectory $installDirectory
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited
$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Principal $taskPrincipal `
    -Settings $taskSettings `
    -Force | Out-Null

if (-not $NoLaunch) {
    Start-ScheduledTask -TaskName $taskName
}

Write-Host "paperGIF installed to $installDirectory"