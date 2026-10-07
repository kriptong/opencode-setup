# ============================================================
#  opencode-setup (Windows) — автораскладка рабочей конфигурации opencode
#  Запуск:  powershell -ExecutionPolicy Bypass -File setup.ps1
#  (в папке репозитория opencode-setup)
#  Идемпотентен: существующие файлы получают бэкап с датой.
#  Аналог setup.sh для macOS: launchd -> Планировщик заданий,
#  bash/sqlite3 -> Node.js (node:sqlite).
# ============================================================
$ErrorActionPreference = 'Continue'

$CONFIG = "$HOME\.config\opencode"
$DATA   = "$HOME\.local\share\opencode"
$REPO   = Split-Path -Parent $MyInvocation.MyCommand.Path
$STAMP  = Get-Date -Format 'yyyyMMdd-HHmmss'

function Backup($path) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak-$STAMP" -Recurse -Force -ErrorAction SilentlyContinue
  }
}
function Say($msg)  { Write-Host "`n== $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }

# PATH текущей сессии (свежие установки winget ещё не видны родителю)
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

New-Item -ItemType Directory -Force -Path $CONFIG, $DATA, "$HOME\Projects" | Out-Null

# ---------- 1. Основные конфиги ----------
Say "1/6 Раскладываю конфиги в $CONFIG"
foreach ($f in 'AGENTS.md','opencode.jsonc','package.json','oh-my-openagent.json','tui.json','lsp-install-decisions.json') {
  Backup "$CONFIG\$f"
  Copy-Item "$REPO\config\$f" "$CONFIG\$f" -Force
}

# ---------- 2. MCP-пакеты и утилиты (локально, без npx-задержек) ----------
Say "2/6 Устанавливаю MCP-пакеты (playwright, memory, filesystem, sqz + утилиты)"
Push-Location $CONFIG
if (Get-Command node -ErrorAction SilentlyContinue) {
  npm install --no-audit --no-fund
  if (Test-Path "$CONFIG\node_modules\@playwright\cli.js") {
    Say "    Браузеры Playwright (chromium)"
    & node "$CONFIG\node_modules\playwright\cli.js" install chromium 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Say "    chromium установлен" }
    else { Warn "браузеры не установились (можно позже: npx playwright install chromium)" }
  } elseif (Test-Path "$CONFIG\node_modules\.bin\playwright.cmd") {
    Say "    Браузеры Playwright (chromium)"
    & "$CONFIG\node_modules\.bin\playwright.cmd" install chromium 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Say "    chromium установлен" }
    else { Warn "браузеры не установились (можно позже: npx playwright install chromium)" }
  } else {
    Warn "бинарник playwright не найден — пропускаю установку браузеров"
  }

  # sqz: постустановка иногда молча не докачивает бинарники (0 байт) — проверяем и докачиваем вручную
  $sqzBin = "$CONFIG\node_modules\sqz-cli\bin"
  if ((Test-Path "$CONFIG\node_modules\sqz-cli") -and -not (Test-Path "$sqzBin\sqz-mcp.exe")) {
    Warn "бинарники sqz не скачались — докачиваю из GitHub Releases"
    $sqzVer = (Get-Content "$sqzBin\..\package.json" -Raw | ConvertFrom-Json).version
    $base = "https://github.com/ojuschugh1/sqz/releases/download/v$sqzVer"
    foreach ($name in 'sqz','sqz-mcp') {
      $zip = "$sqzBin\$name-v$sqzVer-x86_64-pc-windows-msvc.zip"
      try {
        Invoke-WebRequest -Uri "$base/$name-v$sqzVer-x86_64-pc-windows-msvc.zip" -OutFile $zip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $sqzBin -Force -ErrorAction Stop
        Remove-Item $zip -Force
        Say "    $name скачан и распакован"
      } catch {
        Warn "$name не скачался: $($_.Exception.Message)"
      }
    }
  }
} else {
  Warn "node не найден — пропускаю npm-установку (установите Node.js перед настройкой)"
}
Pop-Location

# ---------- 3. Скиллы из публичного репозитория agent-skills ----------
Say "3/6 Скиллы: клонирую bestdeejay-design/agent-skills"
$skillsOk = (Test-Path "$CONFIG\skills") -and (@(Get-ChildItem "$CONFIG\skills" -Directory -ErrorAction SilentlyContinue).Count -gt 0)
if (-not $skillsOk) {
  $TMP_SK = Join-Path $env:TEMP "agent-skills-$STAMP"
  git clone --depth 1 -q https://github.com/bestdeejay-design/agent-skills $TMP_SK
  if ($LASTEXITCODE -eq 0 -and (Test-Path "$TMP_SK\skills")) {
    Backup "$CONFIG\skills"
    New-Item -ItemType Directory -Force -Path "$CONFIG\skills" | Out-Null
    Copy-Item "$TMP_SK\skills\*" "$CONFIG\skills\" -Recurse -Force
    $count = @(Get-ChildItem "$CONFIG\skills" -Directory).Count
    Say "    Установлены скиллы: $count шт"
    # зависимости скилла frontend-perfection (lighthouse и т.п.)
    if (Test-Path "$CONFIG\skills\frontend-perfection\scripts\package.json") {
      Push-Location "$CONFIG\skills\frontend-perfection\scripts"
      npm install --no-audit --no-fund 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { Say "    Зависимости frontend-perfection установлены" }
      else { Warn "зависимости frontend-perfection не установились" }
      Pop-Location
    }
  } else {
    Warn "не удалось склонировать agent-skills"
  }
  Remove-Item $TMP_SK -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Say "    Скиллы уже на месте — пропускаю"
}

# ---------- 4. Обслуживание базы (Планировщик заданий, каждые 6 ч + 4:00) ----------
Say "4/6 Сервис обслуживания базы (чистка чатов, WAL, VACUUM)"
Backup "$DATA\maintenance.mjs"
Copy-Item "$REPO\maintenance\maintenance.mjs" "$DATA\maintenance.mjs" -Force

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = "C:\Program Files\nodejs\node.exe" }

# Три триггера: при входе в систему, каждый день в 4:00, и каждые 6 часов.
$action    = New-ScheduledTaskAction -Execute $nodeExe -Argument "`"$DATA\maintenance.mjs`""
$trigLogon = New-ScheduledTaskTrigger -AtLogOn
$trigDaily = New-ScheduledTaskTrigger -Daily -At 04:00
$trig6h    = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(4) `
               -RepetitionInterval (New-TimeSpan -Hours 6) `
               -RepetitionDuration (New-TimeSpan -Days 3650)
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
               -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

try {
  Register-ScheduledTask -TaskName "opencode-maintenance" `
    -Action $action -Trigger $trigLogon,$trigDaily,$trig6h `
    -Settings $settings -Principal $principal `
    -Description "opencode: очистка старых сессий (>3 дней), WAL checkpoint, VACUUM" `
    -Force -ErrorAction Stop | Out-Null
  Say "    Планировщик: задача opencode-maintenance активна"
} catch {
  Warn "нет прав на регистрацию задачи — пробую с повышением (UAC)"
  # Скрипт пишем в файл: литеральная здесь-строка @'...'@ не требует экранирования
  # кавычек/символов $, а значения подставляются через плейсхолдеры.
  $elevFile = Join-Path $env:TEMP 'opencode-maint-register.ps1'
  $template = @'
$ErrorActionPreference = 'Stop'
try {
  $dataDir  = '__DATA__'
  $nodeExe  = '__NODEEXE__'
  $arg      = '"' + (Join-Path $dataDir 'maintenance.mjs') + '"'
  $action    = New-ScheduledTaskAction -Execute $nodeExe -Argument $arg
  $trigLogon = New-ScheduledTaskTrigger -AtLogOn
  $trigDaily = New-ScheduledTaskTrigger -Daily -At 04:00
  $trig6h    = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(4) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  Register-ScheduledTask -TaskName 'opencode-maintenance' -Action $action -Trigger $trigLogon,$trigDaily,$trig6h -Settings $settings -Description 'opencode maintenance: cleanup sessions >3d, WAL, VACUUM' -Force | Out-Null
  exit 0
} catch {
  [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
  exit 1
}
'@
  $content = $template.Replace('__DATA__', $DATA).Replace('__NODEEXE__', $nodeExe)
  Set-Content -Path $elevFile -Value $content -Encoding UTF8
  try {
    $p = Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$elevFile`"" -Wait -PassThru
    if ($p.ExitCode -eq 0) { Say "    Планировщик: задача opencode-maintenance активна (через UAC)" }
    else { Warn "повышение завершилось с кодом $($p.ExitCode)" }
    Remove-Item $elevFile -Force -ErrorAction SilentlyContinue
  } catch {
    Warn "UAC отклонён — задача не зарегистрирована. Запусти setup.ps1 от администратора или создай задачу вручную."
  }
}

# ---------- 5. Проверки ----------
Say "5/6 Проверки"
$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($gh) { Write-Output ("  gh CLI:      " + ((gh --version | Select-Object -First 1))) } else { Warn "gh не установлен: winget install GitHub.cli && gh auth login" }
$nd = Get-Command node -ErrorAction SilentlyContinue
if ($nd) { Write-Output ("  node:        " + (node --version)) } else { Warn "node не установлен" }

$bins = @(
  "$CONFIG\node_modules\@playwright\mcp\cli.js",
  "$CONFIG\node_modules\@modelcontextprotocol\server-memory\dist\index.js",
  "$CONFIG\node_modules\@modelcontextprotocol\server-filesystem\dist\index.js"
)
$found = @($bins | Where-Object { Test-Path $_ }).Count
Write-Output "  MCP-бинарки: $found из 3 на месте"
if (Test-Path "$HOME\.local\bin\serena.exe") { Write-Output "  serena:      $HOME\.local\bin\serena.exe" } else { Warn "serena не найдена (uv tool install serena-agent --python 3.12)" }
if (Test-Path "$CONFIG\node_modules\sqz-cli\bin\sqz-mcp.exe") { Write-Output "  sqz-mcp:     $CONFIG\node_modules\sqz-cli\bin\sqz-mcp.exe" } else { Warn "sqz не установлен" }

# ---------- 6. Итог ----------
Write-Host "`nГОТОВО. Дальше:" -ForegroundColor Cyan
Write-Host "  1. Перезапустить OpenCode (конфиг MCP читается при старте)."
Write-Host "  2. Авторизация GitHub, если ещё нет:  gh auth login"
Write-Host "  3. В новом чате сказать: «настрой всё по репозиторию opencode-setup» — агент проверит сам."
Write-Host "  4. Логи обслуживания: $DATA\maintenance.log"
Write-Host "  5. Скиллы обновляются: git -C <path-to-agent-skills> pull (или перезапуск setup.ps1)."
