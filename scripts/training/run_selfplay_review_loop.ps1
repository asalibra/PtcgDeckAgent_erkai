# run_selfplay_review_loop.ps1
# 自博弈复盘循环启动器
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\training\run_selfplay_review_loop.ps1
#
# 可选参数：
#   -Games 10             每轮自博弈局数
#   -Iterations 10        循环迭代次数
#   -DeckA 578647         己方卡组 ID
#   -DeckB 578647         对手卡组 ID
#   -Loop                 启用循环模式（默认单次）
#   -Encoder gardevoir    编码器（gardevoir/miraidon/arceus_giratina 等）
#
# 前置条件：
#   1. 已创建 user://review_llm_config.json（复盘 LLM 配置）
#   2. 已导入至少两个卡组

param(
    [int]$Games = 10,
    [int]$Iterations = 10,
    [int]$DeckA = 578647,
    [int]$DeckB = 578647,
    [switch]$Loop,
    [string]$Encoder = "gardevoir"
)

$ErrorActionPreference = "Stop"

$GodotBin = "D:/ai/godot/Godot_v4.6.1-stable_win64_console.exe"
$ProjectDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Write-Host "===== 自博弈复盘循环 =====" -ForegroundColor Cyan
Write-Host "Godot: $GodotBin"
Write-Host "项目: $ProjectDir"
Write-Host "模式: $(if ($Loop) { '循环' } else { '单次' })"
Write-Host "每轮: $Games 局"
if ($Loop) {
    Write-Host "迭代: $Iterations 轮"
}
Write-Host "卡组: $DeckA vs $DeckB"
Write-Host "编码器: $Encoder"

$args = @(
    "--headless",
    "--path", $ProjectDir,
    "--quit-after", "99999",
    "-s", "res://scenes/tuner/SelfPlayEvolvementRunner.gd",
    "--",
    "--games=$Games",
    "--deck-a=$DeckA",
    "--deck-b=$DeckB",
    "--encoder=$Encoder",
    "--max-iterations=$Iterations"
)

if ($Loop) {
    $args += "--loop=true"
}

Write-Host ""
Write-Host "启动中..." -ForegroundColor Yellow

& $GodotBin @args

if ($LASTEXITCODE -ne 0) {
    Write-Host "[错误] 运行失败 (exit code: $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "===== 完成 =====" -ForegroundColor Green
