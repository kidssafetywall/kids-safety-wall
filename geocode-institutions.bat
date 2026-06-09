@echo off
pushd "%~dp0"

echo ==========================================
echo  Geocode Institutions
echo  Source: OSM Nominatim (free, 1 req/sec)
echo  Run this after publish-news.bat
echo ==========================================
echo.

echo [0/2] Fixing script encoding...
powershell -ExecutionPolicy Bypass -Command "$enc=[System.Text.UTF8Encoding]::new($true);$p='scripts\geocode-institutions.ps1';[IO.File]::WriteAllText($p,[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8),$enc)"

echo [1/2] Querying coordinates (500 per run, ~11 min)...
powershell -ExecutionPolicy Bypass -File ".\scripts\geocode-institutions.ps1" -MaxRequests 500 -DelayMs 1300
if %errorlevel% neq 0 (
    echo FAILED: geocode-institutions.ps1
    cmd /k
    exit /b 1
)

echo [2/2] Rebuilding site data with coordinates...
powershell -ExecutionPolicy Bypass -File ".\scripts\update-data.ps1" -MaxImportedPerSource 9999
if %errorlevel% neq 0 (
    echo FAILED: update-data.ps1
    cmd /k
    exit /b 1
)

echo.
echo ==========================================
echo  Done! Run publish-news.bat to deploy.
echo  Re-run this bat to geocode more entries.
echo ==========================================
cmd /k
