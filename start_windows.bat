@echo off
chcp 65001 >nul
setlocal
rem =============================================================================
rem Start the R analysis environment (Windows). Double-click it inside this folder
rem -----------------------------------------------------------------------------
rem   1. Check that Docker Desktop is running (if it is stopped, start it and wait)
rem   2. Build the image (a few minutes to over ten minutes the first time; tens of seconds after that)
rem   3. Start RStudio and open it in the browser
rem   4. Press Enter in this window to stop
rem The names (of the Docker image and container) are made from this folder's name and location, so
rem even if you copy the folder and use it for another analysis, they do not conflict with each other.
rem To only diagnose the environment, use diagnose_windows.bat (it starts nothing; "If something goes wrong" in HOW_TO_USE_Windows.html).
rem This file stays ASCII only. The messages are in launcher/start_messages.txt (UTF-8), shown by :say at the end
rem =============================================================================
cd /d "%~dp0"

rem --- Double-clicked: open the launcher window (launcher\windows_gui.ps1), which runs this file with --gui-worker (HOW_TO_USE_Windows.html "3") ---
set "GUI="
if /i "%~1"=="--gui-worker" (
  set "GUI=1"
  goto worker
)
if not exist "launcher\windows_gui.ps1" goto worker
set "LAUNCHER_ROOT=%CD%"
powershell -NoLogo -NoProfile -Command "Get-ChildItem -LiteralPath $env:LAUNCHER_ROOT -Recurse -Force -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
start "" conhost.exe powershell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ([ScriptBlock]::Create((Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $env:LAUNCHER_ROOT 'launcher\windows_gui.ps1'))))"
exit /b 0
:worker

rem --- Check that this is the analysis folder ---
if not exist "docker-compose.yml" (
  rem --- Opened from inside the Zip, where only this file was taken out: ask to extract it first ---
  if not exist "launcher\start_messages.txt" (
    echo Extract the Zip first: right-click it, choose "Extract All", and open start_windows.bat in the extracted folder.
    if not defined GUI pause
    exit /b 1
  )
  set "MSG=not_project"
  goto fail
)

rem --- Name: folder name (lowercase letters and digits only) + 6 digits made from the location; also the launch ID and start time (made with PowerShell) ---
set "PROJDIR=%CD%"
for /f "usebackq tokens=1-3 delims=|" %%i in (`powershell -NoProfile -Command "$b = ((Split-Path -Leaf $env:PROJDIR).ToLower() -replace '[^a-z0-9]', ''); if (-not $b) { $b = 'r' }; $h = [BitConverter]::ToUInt32([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($env:PROJDIR)), 0) %% 1000000; $u = (Get-Date).ToUniversalTime(); '{0}-{1:D6}|{2}-{3:D5}|{4}' -f $b, $h, $u.ToString('yyyyMMddTHHmmssZ'), (Get-Random -Maximum 100000), $u.ToString('yyyy-MM-ddTHH:mm:ssZ')"`) do (
  set "NAME=%%i"
  set "LID=%%j"
  set "START_T=%%k"
)
if not defined NAME (
  set "MSG=no_name"
  goto fail
)

rem --- Add the progress to outputs\launcher\launch_<launch ID>.jsonl one line at a time (R_LAUNCHER_RECORD=0 turns it off; "If something goes wrong" in HOW_TO_USE_Windows.html) ---
set "LOG="
if "%R_LAUNCHER_RECORD%"=="0" goto record_ready
mkdir "outputs\launcher" >nul 2>&1
if exist "outputs\launcher\" set "LOG=outputs\launcher\launch_%LID%.jsonl"
if defined LOG (>>"%LOG%" echo {"v":1,"id":"%LID%","t":"%START_T%","clock":"%DATE% %TIME%","stage":"launch_start","rc":null}) 2>nul
if defined LOG if not exist "%LOG%" set "LOG="
if not defined LOG call :say record_failed
:record_ready

rem --- Check for Docker Desktop (if docker is not on PATH yet, e.g. right after installing it, look in Docker Desktop's folders) ---
where docker >nul 2>&1
if not errorlevel 1 goto docker_cli_found
set "DOCKER_BIN=%LOCALAPPDATA%\Programs\DockerDesktop\resources\bin"
if not exist "%DOCKER_BIN%\docker.exe" set "DOCKER_BIN=%ProgramFiles%\Docker\Docker\resources\bin"
if exist "%DOCKER_BIN%\docker.exe" set "PATH=%DOCKER_BIN%;%PATH%"
where docker >nul 2>&1
if errorlevel 1 (
  call :rec docker_missing
  set "MSG=no_docker"
  goto fail
)
:docker_cli_found

rem --- If Docker Desktop is not running, start it and wait until it is ready (up to 2 minutes) ---
call :rec docker_check
call :check_linux_engine
if not errorlevel 1 goto docker_ready
call :say starting_docker
call :rec docker_starting
if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" start "" "%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
set /a TRIES=0
:wait_docker
ping -n 3 127.0.0.1 >nul
call :check_linux_engine
if not errorlevel 1 goto docker_ready
set /a TRIES+=1
if %TRIES% lss 60 goto wait_docker
call :rec docker_timeout 1
set "MSG=docker_not_ready"
goto fail
:docker_ready
call :rec docker_ready 0

rem --- Match the CPU (arm64 for Windows on ARM, amd64 for everything else) ---
set "ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=%PROCESSOR_ARCHITEW6432%"
set "PLATFORM=linux/amd64"
if /i "%ARCH%"=="ARM64" set "PLATFORM=linux/arm64"
set "OVDIR=%TEMP%\rlauncher_%RANDOM%%RANDOM%"
mkdir "%OVDIR%" >nul 2>&1
set "OV=%OVDIR%\override.yml"
> "%OV%" echo services:
>> "%OV%" echo   dev:
>> "%OV%" echo     platform: %PLATFORM%
>> "%OV%" echo   lock:
>> "%OV%" echo     platform: %PLATFORM%

rem --- Build the image (if nothing changed, the cached build is reused, so it is fast) ---
call :say preparing
rem Pass the git commit if there is git, otherwise the version stamp (the template line of TEMPLATE_VERSION.txt), to the image's vcs_ref
set "VCS_REF="
if exist ".git" for /f "delims=" %%i in ('git describe --always --dirty --abbrev^=40 --exclude^=* 2^>nul') do set "VCS_REF=%%i"
if not defined VCS_REF if exist "TEMPLATE_VERSION.txt" for /f "usebackq tokens=1,3" %%a in ("TEMPLATE_VERSION.txt") do if "%%a"=="template" set "VCS_REF=%%b"
if not defined VCS_REF set "VCS_REF=unknown"
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)"`) do set "BUILD_DATE=%%i"

rem --- If packages were added to DESCRIPTION, rebuild the package list (renv.lock) and rebuild the image too ---
rem (if an added package is not in renv.lock, the final check of the image stops the build; even if it does not stop, check for a mismatch)
call :build_dev
if not "%RC%"=="0" goto relock
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" run --rm --user rstudio dev Rscript --vanilla tools/make_lockfile.R --check >nul 2>&1
set "RC=%errorlevel%"
call :rec lock_check_end %RC%
if "%RC%"=="0" goto packages_ok
:relock
call :say relocking
call :rec relock_start
set "MSG=relock_failed"
docker build --platform %PLATFORM% --target bootstrap -t %NAME%:bootstrap .
set "RC=%errorlevel%"
if not "%RC%"=="0" goto relock_done
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" run --rm --user rstudio -v renv-cache:/opt/renv/cache lock Rscript --vanilla tools/make_lockfile.R
set "RC=%errorlevel%"
:relock_done
call :rec relock_end %RC%
if not "%RC%"=="0" goto fail_cleanup
set "MSG=build_failed"
call :build_dev
if not "%RC%"=="0" goto fail_cleanup
:packages_ok

rem --- Start RStudio, and when it responds, open it in the browser ---
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" up -d dev
set "RC=%errorlevel%"
call :rec up_end %RC%
if not "%RC%"=="0" (
  set "MSG=up_failed"
  goto fail_cleanup
)
set /a TRIES=0
:wait_rstudio
ping -n 2 127.0.0.1 >nul
set "HOSTPORT="
for /f "delims=" %%p in ('docker compose -p %NAME% -f docker-compose.yml -f "%OV%" port dev 8787 2^>nul') do set "HOSTPORT=%%p"
if defined HOSTPORT (
  curl.exe -fs --max-time 2 -o nul "http://%HOSTPORT%/" && goto rstudio_ready
)
set /a TRIES+=1
if %TRIES% lss 90 goto wait_rstudio
call :rec ui_timeout 1
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" down
set "RC=%errorlevel%"
call :rec down_end %RC%
set "MSG=no_response"
goto fail_cleanup
:rstudio_ready
call :rec ui_ready 0
set "URL=http://localhost:%HOSTPORT:*:=%"
echo.
call :say ready "%URL%"
if defined GUI goto gui_wait
start "" "%URL%"
call :say browser_hint
echo.
call :say enter_to_stop
set /p "_="
call :rec stop_requested

rem --- Stop and clean up (the built image is kept, so the next start is fast) ---
call :say stopping
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" down
set "RC=%errorlevel%"
call :rec down_end %RC%
rmdir /s /q "%OVDIR%" >nul 2>&1
if not "%RC%"=="0" (
  call :say stop_failed
  call :rec launch_end %RC%
  if not defined GUI pause
  exit /b %RC%
)
call :say stopped
call :rec launch_end 0
if not defined GUI pause
exit /b 0

rem --- Window mode: wait for "stop" from the window; if stopping fails, tell the window and wait again. If the window closes, stop and finish ---
:gui_wait
echo LAUNCHER_UI^|READY^|%URL%
:gui_next
set "ACTION="
set /p "ACTION="
if errorlevel 1 goto gui_closed
if /i not "%ACTION%"=="stop" goto gui_next
call :rec stop_requested
call :say stopping
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" down
set "RC=%errorlevel%"
call :rec down_end %RC%
if not "%RC%"=="0" (
  call :say stop_failed
  echo LAUNCHER_UI^|STOP_FAILED
  goto gui_next
)
rmdir /s /q "%OVDIR%" >nul 2>&1
call :say stopped
call :rec launch_end 0
exit /b 0
:gui_closed
call :rec stop_requested
docker compose -p %NAME% -f docker-compose.yml -f "%OV%" down
set "RC=%errorlevel%"
call :rec down_end %RC%
rmdir /s /q "%OVDIR%" >nul 2>&1
call :rec launch_end %RC%
exit /b %RC%

rem --- Before stopping, wait so the message can be read ---
:fail_cleanup
rmdir /s /q "%OVDIR%" >nul 2>&1
:fail
echo.
call :say %MSG%
call :rec launch_end 1
if not defined GUI pause
exit /b 1

rem --- Build the main image (if nothing changed, the cached build is reused, so it is fast); the exit code is kept in RC ---
:check_linux_engine
powershell -NoProfile -Command "$p = New-Object Diagnostics.Process; try { $p.StartInfo.FileName = 'docker.exe'; $p.StartInfo.Arguments = 'info --format {{.ServerVersion}}:{{.OSType}}:{{.NCPU}}:{{.MemTotal}}'; $p.StartInfo.UseShellExecute = $false; $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true; $null = $p.Start(); $out = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync(); if (-not $p.WaitForExit(1500)) { $p.Kill(); exit 1 }; if ($p.ExitCode -eq 0 -and $out.Wait(100) -and $out.Result -match '\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}:linux:[1-9][0-9]{0,8}:[1-9][0-9]{0,17}\r?\n?\z') { exit 0 }; exit 1 } catch { exit 1 } finally { $p.Dispose() }"
exit /b %errorlevel%

:build_dev
call :rec build_start
docker build --platform %PLATFORM% --target dev --build-arg BUILD_DATE=%BUILD_DATE% --build-arg VCS_REF=%VCS_REF% --build-arg IMAGE_NAME=%NAME% -t %NAME%:dev .
set "RC=%errorlevel%"
call :rec build_end %RC%
exit /b %RC%

rem --- Add one line of progress: call :rec <stage> [exit code]. If it cannot be written, say so once and go on ---
:rec
if not defined LOG exit /b 0
set "REC_RC=%~2"
if not defined REC_RC set "REC_RC=null"
(>>"%LOG%" echo {"v":1,"id":"%LID%","clock":"%DATE% %TIME%","stage":"%~1","rc":%REC_RC%}) 2>nul || (
  set "LOG="
  call :say record_failed
)
exit /b 0

rem --- Show the message with this name from launcher/start_messages.txt (UTF-8) with PowerShell ({0} becomes the 2nd argument) ---
:say
set "SAY_NAME=%~1"
set "SAY_ARG=%~2"
powershell -NoProfile -Command "$line = Get-Content -Encoding UTF8 -LiteralPath 'launcher/start_messages.txt' -ErrorAction SilentlyContinue | Where-Object { $_.StartsWith($env:SAY_NAME + '=') } | Select-Object -First 1; if ($null -eq $line) { exit 1 }; Write-Host ($line.Substring($env:SAY_NAME.Length + 1).Replace('{0}', [string]$env:SAY_ARG))"
if errorlevel 1 echo [launcher/start_messages.txt: %SAY_NAME%] %SAY_ARG%
exit /b 0
