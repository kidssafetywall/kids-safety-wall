@echo off
pushd "%~dp0"

echo ==========================================
echo  兒少防火牆 - 新聞資料更新
echo ==========================================
echo.

rem -- 修正 UTF-8 BOM，確保 PowerShell 5.1 可正確讀取 --
powershell -ExecutionPolicy Bypass -Command ^
  "$enc=[System.Text.UTF8Encoding]::new($true);" ^
  "@('scripts\fetch-news.ps1') | ForEach-Object {" ^
  "  $p = Join-Path $pwd $_;" ^
  "  [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8), $enc)" ^
  "}"
echo Encoding fixed.
echo.

echo [1/1] 搜尋 Google News（已確認裁罰 + 明確物證）...
powershell -ExecutionPolicy Bypass -File ".\scripts\fetch-news.ps1" -MaxNewPerRun 100 -DelayMs 2000
if %errorlevel% neq 0 (
    echo WARNING: fetch-news.ps1 發生錯誤，請查看上方訊息。
) else (
    echo Done.
)
echo.

echo ==========================================
echo  新聞抓取完成！新聞已存入 data\review-queue.json
echo.
echo  下一步（需人工操作）：
echo  1. 開啟 admin.html，登入後進入「審核待審佇列」
echo  2. 載入 data\review-queue.json
echo  3. 逐條點開原文，確認後按「通過」，無關按「移除」
echo  4. 點「下載已審核 events.json」，覆蓋 data\events.json
echo  5. 執行下方指令重建前端：
echo     powershell -ExecutionPolicy Bypass -File scripts\update-data.ps1
echo  6. git add + commit + push
echo ==========================================
cmd /k
