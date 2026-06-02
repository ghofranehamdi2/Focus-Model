# SmartFocus - Lance la session CV (UI) + assistant vocal en parallele
# Usage: powershell -ExecutionPolicy Bypass -File launch_session.ps1

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) { $Python = "python" }

Write-Host "=== SmartFocus Launcher ===" -ForegroundColor Cyan
Write-Host "Python : $Python"
Write-Host "Root   : $Root"
Write-Host ""

# --- Fenetre 1 : Pipeline CV avec UI ---
Write-Host "[1] Demarrage pipeline CV (UI activee)..." -ForegroundColor Green
$cvCmd = "Set-Location `"$Root`"; Write-Host `"[CV] Demarrage...`" -ForegroundColor Green; & `"$Python`" main_cv.py"
$cvProc = Start-Process powershell -ArgumentList "-NoExit", "-Command", $cvCmd -PassThru

# Attendre que le fichier de session .jsonl apparaisse
$SessionsDir = Join-Path $Root "output\sessions"
Write-Host "    Attente du fichier de session dans : $SessionsDir" -ForegroundColor Yellow

$timeout = 60
$elapsed = 0
$found = $false
while ($elapsed -lt $timeout) {
    if (Test-Path $SessionsDir) {
        $files = Get-ChildItem -Path $SessionsDir -Filter "*.jsonl" -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch "_summary" }
        if ($files.Count -gt 0) {
            $found = $true
            Write-Host "    Session detectee : $($files[-1].Name)" -ForegroundColor Green
            break
        }
    }
    Start-Sleep -Seconds 1
    $elapsed++
    Write-Host "    ... $elapsed s" -ForegroundColor DarkGray
}

if (-not $found) {
    Write-Host "    [WARN] Aucune session trouvee apres $timeout s - ID temporaire utilise." -ForegroundColor Yellow
}

# --- Fenetre 2 : Assistant vocal ---
Write-Host "[2] Demarrage assistant vocal..." -ForegroundColor Magenta
$voiceCmd = "Set-Location `"$Root`"; Write-Host `"[VOICE] Demarrage...`" -ForegroundColor Magenta; & `"$Python`" run_voice_assistant.py"
$voiceProc = Start-Process powershell -ArgumentList "-NoExit", "-Command", $voiceCmd -PassThru

Write-Host ""
Write-Host "Les deux processus sont lances :" -ForegroundColor Cyan
Write-Host "  - CV pipeline  (PID $($cvProc.Id))"
Write-Host "  - Voice assistant (PID $($voiceProc.Id))"
Write-Host ""
Write-Host "Appuie sur Q dans la fenetre CV pour arreter la session."
Write-Host "Appuie sur Ctrl-C dans la fenetre Voice pour arreter l assistant."
