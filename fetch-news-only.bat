@echo off
pushd "%~dp0"

echo ==========================================
echo  Kids Safety Wall - Fetch News Only
echo ==========================================
echo.

rem Fix UTF-8 BOM so PowerShell 5.1 reads scripts correctly
powershell -ExecutionPolicy Bypass -Command ^
  "$enc=[System.Text.UTF8Encoding]::new($true);" ^
  "@('scripts\fetch-news.ps1') | ForEach-Object {" ^
  "  $p = Join-Path $pwd $_;" ^
  "  [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8), $enc)" ^
  "}"
echo Encoding fixed.
echo.

echo [1/1] Fetching Google News (confirmed penalties + evidence)...
powershell -ExecutionPolicy Bypass -File ".\scripts\fetch-news.ps1" -MaxNewPerRun 100 -DelayMs 2000
if %errorlevel% neq 0 (
    echo WARNING: fetch-news.ps1 had errors. Check output above.
) else (
    echo Done.
)
echo.

echo ==========================================
echo  News fetch complete!
echo  New items saved to: data\review-queue.json
echo.
echo  Next steps (manual):
echo  1. Open admin.html and log in
echo  2. Go to Review Queue tab
echo  3. Load data\review-queue.json
echo  4. Approve or remove each item
echo  5. Download approved events.json
echo  6. Overwrite data\events.json with the download
echo  7. Run: powershell -ExecutionPolicy Bypass -File scripts\update-data.ps1
echo  8. git add + commit + push
echo ==========================================
cmd /k
