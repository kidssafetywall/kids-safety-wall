# 兒少防火牆

教育機構風險資訊查詢網站原型。目標是整合幼兒園、國小、國中、補習班、課後照顧中心等機構的公開資料、官方裁罰、新聞紀錄、司法文書與家長回饋。

## 目前完成

- `index.html`：可直接開啟的前台網站。
- `admin.html`：靜態審核後台，可建立待審事件 JSON。
- `data/site-data.js`：前台讀取的資料檔。
- `data/events.json`：已審核或正式納入的事件資料。
- `data/review-queue.json`：待審事件佇列。
- `data/institutions.json`：由更新腳本產生的機構彙整資料。
- `data/manual-events.json`：舊版人工事件資料，保留作為參考。
- `sources/source-registry.json`：政府資料源清單。
- `scripts/update-data.ps1`：擷取來源、封存 HTML 快照、產生前台資料。
- `scripts/add-event.ps1`：用命令列新增待審事件。
- `archive/raw/`：來源頁面的本地快照。原始來源下架時，仍可看到擷取當下的佐證頁。

## 如何更新資料

在 PowerShell 執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-data.ps1
```

開發測試時可限制每個政府資料源匯入筆數，避免前台檔案太大：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-data.ps1 -MaxImportedPerSource 500
```

若要嘗試全量匯入，把 `-MaxImportedPerSource` 拿掉即可。全量資料較大，建議交給每日排程或正式後端處理。

腳本會：

1. 讀取 `sources/source-registry.json` 的政府資料源。
2. 從政府資料集頁自動找 JSON 名錄下載網址。
3. 匯入政府名錄中的教育機構。
4. 讀取 `data/events.json` 與 `data/review-queue.json`。
5. 對每筆事件的 `evidence[].url` 執行擷取。
6. 將原始頁面保存到 `archive/raw/`。
7. 重新產生 `data/institutions.json` 與 `data/site-data.js`。

## 新增事件

可用兩種方式新增事件：

1. 開啟 `admin.html`，填寫表單後下載 `review-queue.json`。
2. 使用 `scripts/add-event.ps1` 將事件加入 `data/review-queue.json`。

正式事件格式至少包含：

- `id`
- `verificationStatus`
- `institution.name`
- `institution.type`
- `institution.city`
- `risk`
- `category`
- `title`
- `summary`
- `eventDate`
- `evidence[].title`
- `evidence[].publisher`
- `evidence[].url`
- `tags`

沒有 `evidence[].url` 的事件會被跳過，不會進入前台。

## 每日定時更新

可用三種方式：

- GitHub Actions：使用 `.github/workflows/update-data.yml` 每日自動更新並提交變更。
- Windows 工作排程器：每日執行 `scripts/update-data.ps1`。
- 雲端排程：部署到正式後端後，用 Cloudflare Cron、Vercel Cron 或 Linux cron 執行同樣流程。

## 可引用資料源

- 幼兒園名錄：https://data.gov.tw/dataset/6086
- 國民小學名錄：https://data.gov.tw/dataset/6087
- 國民中學校別資料：https://data.gov.tw/dataset/6239
- 一般高級中等學校名錄：https://data.gov.tw/dataset/6089
- 全國立案短期補習班基本資料：https://data.gov.tw/dataset/16461
- 司法院裁判書開放 API：https://data.nat.gov.tw/dataset/63205

## 法務與治理重點

- 每筆事件都要保留來源、日期、擷取時間、原始連結與快照。
- 不要把新聞線索寫成已定案事實。
- 家長回饋需審核、分類、去識別化。
- 機構應有更正、補充說明與申訴入口。
- 新聞只摘要與連結，不全文轉載。
