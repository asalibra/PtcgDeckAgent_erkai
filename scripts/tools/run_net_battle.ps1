<#
.SYNOPSIS
    Start network battle server and web hosting service
.DESCRIPTION
    1. Start Godot headless server (WebSocket listener)
    2. Start Python HTTP server (web export hosting)
    3. Press Ctrl+C to stop all services
.PARAMETER ServerPort
    WebSocket server port, default 9000
.PARAMETER WebPort
    Web HTTP service port, default 8080
.PARAMETER ExportDir
    Web export directory, default exports/web
.EXAMPLE
    .\run_net_battle.ps1
    .\run_net_battle.ps1 -ServerPort 9001 -WebPort 8081
#>

param(
    [int]$ServerPort = 9000,
    [int]$WebPort = 8080,
    [string]$ExportDir = "",
    [string]$GodotPath = ""
)

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($ExportDir -eq "") {
    $ExportDir = Join-Path $ProjectRoot "exports\web"
}

# Find Godot executable
$GodotExe = ""
if ($GodotPath -ne "" -and (Test-Path $GodotPath)) {
    $GodotExe = $GodotPath
} else {
    $GodotCandidates = @("godot", "godot.exe", "Godot_v4.6*")
    foreach ($candidate in $GodotCandidates) {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($found) {
            $GodotExe = $found.Source
            break
        }
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  PTCG Deck Agent - Network Battle Launcher" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Project dir:     $ProjectRoot" -ForegroundColor Gray
Write-Host "  WebSocket port:  $ServerPort" -ForegroundColor Gray
Write-Host "  Web HTTP port:   $WebPort" -ForegroundColor Gray
Write-Host "  Web export dir:  $ExportDir" -ForegroundColor Gray
Write-Host ""

# Check if web export exists
$HasHtml = (Test-Path $ExportDir) -and ((Test-Path (Join-Path $ExportDir "index.html")) -or (Get-ChildItem -Path $ExportDir -Filter "*.html" -ErrorAction SilentlyContinue).Count -gt 0)
if (-not $HasHtml) {
    Write-Host "[!] Web export directory missing or no HTML files found" -ForegroundColor Yellow
    Write-Host "    Please export Web version from Godot editor first:" -ForegroundColor Yellow
    Write-Host "    Project -> Export -> Select Web preset -> Export Project" -ForegroundColor Yellow
    Write-Host "    Export to: $ExportDir" -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "Continue starting server? (y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        exit 0
    }
}
# Auto-create index.html if missing but other html exists
if ((Test-Path $ExportDir) -and -not (Test-Path (Join-Path $ExportDir "index.html"))) {
    $existingHtml = Get-ChildItem -Path $ExportDir -Filter "*.html" | Select-Object -First 1
    if ($existingHtml) {
        Copy-Item $existingHtml.FullName (Join-Path $ExportDir "index.html")
        Write-Host "  Auto-created index.html from $($existingHtml.Name)" -ForegroundColor Gray
    }
}

# Check Godot
if ($GodotExe -eq "") {
    Write-Host "[!] Godot executable not found" -ForegroundColor Red
    Write-Host "    Please ensure 'godot' is in PATH, or use -GodotPath parameter:" -ForegroundColor Red
    Write-Host '    .\run_net_battle.ps1 -GodotPath "G:\AAA_godot\Godot_v4.6.2-stable_win64_console.exe"' -ForegroundColor Red
    exit 1
}

Write-Host "  Godot path: $GodotExe" -ForegroundColor Gray
Write-Host ""

# Start services
$ServerJob = $null
$WebJob = $null

try {
    Write-Host "[1/2] Starting game server (port $ServerPort)..." -ForegroundColor Green
    $ServerJob = Start-Process -FilePath $GodotExe `
        -ArgumentList "--headless", "--path", $ProjectRoot, "-s", "res://scripts/server/ServerMain.gd", "--", "--port=$ServerPort" `
        -NoNewWindow `
        -PassThru

    Start-Sleep -Seconds 2

    if ($ServerJob.HasExited) {
        Write-Host "[!] Server failed to start" -ForegroundColor Red
        exit 1
    }

    Write-Host "[2/2] Starting web hosting service (port $WebPort)..." -ForegroundColor Green
    $WebJob = Start-Process -FilePath "python" `
        -ArgumentList (Join-Path $ProjectRoot "scripts\tools\serve_web_export.py"), $WebPort.ToString(), $ExportDir `
        -NoNewWindow `
        -PassThru

    Start-Sleep -Seconds 1

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  All services started!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Open browser:  http://localhost:$WebPort" -ForegroundColor White
    Write-Host "  Server addr:   ws://localhost:$ServerPort" -ForegroundColor White
    Write-Host ""
    Write-Host "  Press Ctrl+C to stop all services" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    # Wait for Ctrl+C
    Wait-Event -Timeout ([int]::MaxValue)
}
finally {
    Write-Host ""
    Write-Host "Stopping services..." -ForegroundColor Yellow

    if ($ServerJob -and -not $ServerJob.HasExited) {
        Stop-Process -Id $ServerJob.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Server stopped" -ForegroundColor Gray
    }
    if ($WebJob -and -not $WebJob.HasExited) {
        Stop-Process -Id $WebJob.Id -Force -ErrorAction SilentlyContinue
        Write-Host "  Web service stopped" -ForegroundColor Gray
    }

    Write-Host "Done" -ForegroundColor Green
}
