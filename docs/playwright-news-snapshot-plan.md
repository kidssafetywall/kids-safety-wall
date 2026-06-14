# 新聞封存升級計劃：Playwright headless browser

## 問題背景

Google News RSS 的每篇文章連結（`news.google.com/rss/articles/CBMi...?oc=5`）在伺服器端回傳的是 HTTP 200 + JavaScript relay 頁面，實際文章 URL 只存在 obfuscated JS 裡。PowerShell `Invoke-WebRequest` 無法執行 JS，因此目前的 `fetch-news.ps1` 存下來的快照全是 relay 頁面（觸發 `intent://` scheme → 瀏覽器顯示 "invalid web address"），已全部設為 null。

## 目標

在 GitHub Actions 加入 Playwright，讓 `fetch-news.ps1` 能夠：
1. 對 Google News 連結執行真正的 JS redirect，取得最終文章 URL
2. 抓取真正的文章頁面並存為封存快照

## 技術選型

| 選項 | 優點 | 缺點 |
|------|------|------|
| **Playwright for Node.js** | 官方支援 GitHub Actions；chromium/firefox/webkit 全支援；速度快 | 需加 Node.js 安裝步驟 |
| Playwright for Python | 生態系豐富 | 需加 Python 安裝步驟 |
| Puppeteer | 熟悉度高 | 僅支援 Chromium；功能較少 |
| Selenium | 老牌穩定 | 設定繁瑣；速度慢 |

**選擇：Playwright for Node.js**。GitHub Actions `windows-latest` 已內建 Node.js，安裝成本最低。

## 實作架構

### 新增檔案

```
scripts/
  fetch-news.ps1          ← 現有，負責 RSS 解析與事件建立
  snapshot-news.js        ← 新增，Playwright 批次抓取腳本
  package.json            ← 新增，Playwright 相依套件定義
```

### 資料流程

```
fetch-news.ps1
  ↓ 寫入 data/news-pending-snapshot.json
    [ { "eventId": "news-xxx", "url": "https://news.google.com/rss/articles/..." }, ... ]
  ↓
snapshot-news.js (Playwright)
  ↓ 對每個 URL 用 Chromium 等待 JS redirect 完成
  ↓ 取得最終文章 URL（page.url() after navigation）
  ↓ 抓取最終頁面 HTML（page.content()）
  ↓ 存到 archive/raw/news-{hash}.html
  ↓ 寫入 data/news-snapshot-results.json
    [ { "eventId": "news-xxx", "finalUrl": "...", "snapshotPath": "archive/raw/...", "capturedAt": "..." } ]
  ↓
fetch-news.ps1 第二階段（或 update-data.ps1）
  讀取 news-snapshot-results.json 更新 events.json 的 snapshotPath
```

## 實作步驟

### Step 1：`scripts/package.json`

```json
{
  "name": "kids-safety-wall-snapshots",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "playwright": "^1.44.0"
  }
}
```

### Step 2：`scripts/snapshot-news.js`

```javascript
// 讀取 data/news-pending-snapshot.json
// 對每個 URL：
//   1. browser.newPage()
//   2. page.goto(googleNewsUrl, { waitUntil: 'commit' })  // 等 JS redirect 啟動
//   3. page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 10000 })
//   4. finalUrl = page.url()  // Google News redirect 後的真正文章 URL
//   5. content = await page.content()
//   6. 寫入 archive/raw/news-{hash(finalUrl)}-{hash(eventId)}.html
// 寫出 data/news-snapshot-results.json
```

關鍵細節：
- 使用 `headless: true`（GitHub Actions 無顯示器）
- `--no-sandbox` flag（Linux runner 需要）
- timeout 設 15 秒，失敗就 null
- 一次最多處理 `MAX_PER_RUN`（預設 30）筆，避免超時
- 同時開 3 個 page（並行）加速
- User-Agent 設為正常瀏覽器

### Step 3：修改 `scripts/fetch-news.ps1`

在現有邏輯之後新增：
1. 把新事件的 Google News URL 寫入 `data/news-pending-snapshot.json`
2. （由 workflow 呼叫 `snapshot-news.js` 後）讀取 `data/news-snapshot-results.json`，更新對應事件的 `snapshotPath` 與 `capturedAt`

### Step 4：修改 `.github/workflows/update-data.yml`

在 Step 2（fetch-news.ps1）後插入新 Step：

```yaml
# ── Step 2b：安裝 Playwright 並抓取新聞封存 ─────────────────────────────
- name: 安裝 Playwright
  run: |
    cd scripts
    npm ci
    npx playwright install chromium --with-deps

- name: 用 Playwright 封存新聞文章
  shell: pwsh
  run: node scripts/snapshot-news.js
  timeout-minutes: 10
```

並在提交步驟加入：
```yaml
git add data/news-pending-snapshot.json
git add data/news-snapshot-results.json
```

## 注意事項與風險

### Google 反爬蟲
- Google News 可能偵測 headless browser 並封鎖
- 緩解：使用 `playwright-extra` + `stealth` plugin，或加 random delay
- 若封鎖，fallback 為 null（顯示「待封存」），不中斷其他流程

### CI 時間成本
- 安裝 Playwright + Chromium：約 2–3 分鐘
- 每篇文章：約 3–8 秒（含 JS redirect + 頁面載入）
- 每次最多 30 篇：約 2–4 分鐘額外時間
- 總計：約 5–7 分鐘額外 CI 時間

### 快照檔案大小
- 真正的新聞文章 HTML 含圖片 base64 可能很大
- 建議抓取前先判斷頁面大小，超過 2 MB 就只存 `<article>` 節點的文字
- 或改用 `page.evaluate()` 提取純文字 + metadata

### 封存頁面可能包含動態廣告 / 登入牆
- 部分新聞需登入才能閱讀全文
- 建議存下任何狀態（即使只有截斷內容），snapshotPath 仍設為有效路徑

### 現有資料遷移
- 現有 205 個 news snapshotPath 都已設為 null
- 實作後不自動補抓，因為 news-seen.json 裡的文章大多已超過 30 天，原始 URL 可能失效
- 僅對未來新增的新聞事件生效

## 驗收標準

- [ ] `snapshot-news.js` 能正確解析 Google News relay，取得真正文章 URL
- [ ] 快照 HTML 第一行包含 `<!-- source: https://actual-article-url -->`，而非 Google News URL
- [ ] 快照檔案在 GitHub Pages 可正常開啟（不觸發 "invalid web address"）
- [ ] 失敗的 URL 寫入 null，不中斷整體 CI
- [ ] CI 總時間不超過原有 +10 分鐘

## 優先順序

此功能屬於**錦上添花**，建議在以下項目完成後再實作：
1. 確認裁罰封存（`penalty-moe-detail-*`）在新 CI 跑後正常顯示
2. 確認其他資料更新流程穩定

預估實作時間：3–4 小時
