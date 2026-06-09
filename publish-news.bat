@echo off
pushd "%~dp0"

echo ==========================================
echo  Kids Safety Wall - Rebuild and Publish
echo ==========================================
echo.

echo [1/3] Rebuilding frontend data...
powershell -ExecutionPolicy Bypass -File ".\scripts\update-data.ps1" -MaxImportedPerSource 9999
if %errorlevel% neq 0 (
    echo FAILED: update-data.ps1
    cmd /k
    exit /b 1
)
echo Done.
echo.

echo [2/3] Staging changed files...
git add data/events.json data/review-queue.json data/site-data.js data/institutions.json data/institution-overrides.json data/quasi-public.json
if %errorlevel% neq 0 (
    echo FAILED: git add
    cmd /k
    exit /b 1
)
echo Done.
echo.

echo [3/3] Committing and pushing...
for /f "usebackq" %%d in (`powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd'"`) do set TODAY=%%d
git commit -m "feat: update news data %TODAY%"
if %errorlevel% neq 0 (
    echo Nothing to commit or commit failed.
) else (
    git push origin main
    if %errorlevel% neq 0 (
        echo FAILED: git push
        cmd /k
        exit /b 1
    )
    echo Pushed successfully.
)
echo.

echo ==========================================
echo  Done! Site will update in ~2 minutes.
echo ==========================================
cmd /k
