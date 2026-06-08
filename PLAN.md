# 兒少防火牆 — 完整實作計畫書

> 撰寫日期：2026-06-08  
> 目標：讓家長與民眾能查詢幼兒園、國小、國中及各教育機構的負面新聞、政府裁罰、司法判決與家長回饋，資訊公開透明，並保留原始來源快照避免資料消失。

---

## 一、現況盤點

### 已完成
| 項目 | 說明 |
|------|------|
| `index.html` | 前台：搜尋、篩選、機構卡片、詳情面板、來源連結 |
| `admin.html` | 靜態後台表單：填寫事件後下載 JSON（無伺服器） |
| `scripts/update-data.ps1` | 抓取政府名錄、封存 HTML 快照、產生 `site-data.js` |
| `archive/raw/` | 已有幼兒園/國小/國中/高中/補習班名錄頁快照 |
| `archive/datasets/` | 已有 4 份政府 JSON 名錄 |
| `sources/source-registry.json` | 6 個政府資料源清單 |
| `data/events.json` | 正式事件資料（目前為 seed 資料） |
| `data/review-queue.json` | 待審事件佇列 |

### 尚未實作（優先缺口）
| 項目 | 說明 |
|------|------|
| 新聞自動抓取 | 無新聞爬蟲，事件需全手動建立 |
| 政府裁罰公告解析 | 只抓頁面快照，沒有解析裁罰條目的邏輯 |
| 司法院 API 整合 | source-registry 有列，腳本只處理 government_dataset，API 未實作 |
| 真實地理座標 | XY 欄位是 Get-Random 亂數 |
| 家長投稿後端 | 前台有按鈕但無實際表單或入庫機制 |
| GitHub Actions 排程 | workflow 檔存在但尚未與 repo 連動 |
| 全文搜尋 | 目前為前端 JS 字串比對 |

---

## 二、目標功能範圍（本計畫執行項目）

本計畫聚焦在**不需要正式後端伺服器**的靜態／腳本架構下，最大化自動化程度。正式後端（Next.js + PostgreSQL）列為未來升級路徑，不在本次範圍。

---

## 三、分階段執行計畫

### Phase 1 — 新聞自動抓取（Google News RSS）

**目標**：每日自動搜尋各機構名稱 + 負面關鍵字，將新聞條目寫入待審佇列。

**技術方式**：
- Google News RSS：`https://news.google.com/rss/search?q={QUERY}&hl=zh-TW&gl=TW&ceid=TW:zh-Hant`
- 不需 API 金鑰，合法公開 RSS
- 搜尋關鍵字策略：`"{機構名稱}" (裁罰 OR 虐待 OR 霸凌 OR 違規 OR 檢舉 OR 停辦 OR 撤銷)` 
- 每次只抓**新增條目**（比對 RSS `guid` 與已知條目）

**腳本**：`scripts/fetch-news.ps1`

**流程**：
1. 讀取 `data/institutions.json` 取得所有機構名稱
2. 對每個機構呼叫 Google News RSS（加入負面關鍵字）
3. 解析 RSS XML：title、link、pubDate、source
4. 比對 `data/news-seen.json`（已抓取 guid 紀錄），去除重複
5. 將新條目寫入 `data/review-queue.json`，`verificationStatus: "pending"`，`category: "news"`
6. 對新聞原始 URL 執行 HTML 快照，存入 `archive/raw/`
7. 更新 `data/news-seen.json`

**新增檔案**：
- `scripts/fetch-news.ps1`
- `data/news-seen.json`（已抓取 RSS guid 的去重紀錄）

**前台連動**：新聞條目進入 review-queue 後，`update-data.ps1` 執行時自動納入並顯示於前台（`verificationStatus: pending` 狀態）。

---

### Phase 2 — 司法院裁判書 API 整合

**目標**：自動搜尋司法裁判書中含有各機構名稱的判決，擷取案件摘要、判決日期、案號，寫入待審佇列。

**技術方式**：
- 司法院開放 API：`https://data.judicial.gov.tw/jdg/api/SearchResult`
- 參數：`kw={機構名稱}`、`judgeYM={年月}`
- 回傳欄位：案號、法院、裁判日期、案由、全文連結
- 不需 API 金鑰（公開）

**腳本**：`scripts/fetch-judicial.ps1`

**流程**：
1. 讀取 `data/institutions.json` 取得機構名稱清單
2. 對有 `code` 欄位或名稱較特殊的機構（避免通用名稱誤配）呼叫 API
3. 解析回傳 JSON：過濾出「被告為教育機構或相關人員」的案件
4. 比對 `data/judicial-seen.json` 去重（用案號）
5. 寫入 `data/review-queue.json`，`category: "judicial"`，`verificationStatus: "pending"`
6. 對裁判書全文 URL 執行快照

**新增檔案**：
- `scripts/fetch-judicial.ps1`
- `data/judicial-seen.json`

**source-registry.json 更新**：將 `judicial-judgment-api` 的 `type` 流程接上腳本。

---

### Phase 3 — 政府裁罰公告抓取

**目標**：從教育部與各縣市教育局的公開裁罰公告頁面，解析出機構名稱、裁罰原因、罰鍰金額、裁罰日期，自動寫入事件資料。

**技術方式**：
以下為台灣政府已有結構化資料或可解析的公開頁面：

| 來源 | 網址 | 格式 |
|------|------|------|
| 教育部幼兒園裁罰公告 | `https://data.gov.tw/dataset/6258` | JSON（政府開放資料） |
| 全國違規幼兒園名單 | 教育部幼兒教育及照顧資訊網（html 表格） | HTML table |
| 各縣市教育局公告 | 各縣市政府官網（需個別解析） | HTML |

**第一批目標**（結構化，可立即解析）：
1. 教育部開放資料 `dataset/6258`（幼兒園裁處案件）— 若存在 JSON 資源直接下載
2. 補習班違規紀錄（查詢教育部終身教育司補習班立案查詢系統）

**腳本**：`scripts/fetch-penalties.ps1`

**流程**：
1. 從各已知裁罰資料源下載或抓取頁面
2. 解析出：機構名稱、城市、裁罰日期、裁罰原因、法規依據、罰鍰金額
3. 用名稱 + 城市比對 `institutions.json` 中的機構
4. 比對去重（用原始 URL + 日期）
5. 高確信度（政府 JSON 資料）直接寫入 `data/events.json`（`verificationStatus: "verified"`）
6. 低確信度（HTML 解析）寫入 `review-queue.json`（`verificationStatus: "pending"`）
7. 執行快照封存

**新增檔案**：
- `scripts/fetch-penalties.ps1`
- `data/penalty-seen.json`
- `sources/source-registry.json` 新增裁罰資料源條目

---

### Phase 4 — 前台搜尋與顯示強化

**目標**：改善使用者查詢體驗，補完目前 UI 缺漏。

#### 4-1 縣市篩選選項自動補全
- 現況：HTML 中只硬寫 6 個城市
- 修改：`populateFilterOptions()` 已有動態補全邏輯，移除 HTML 中的硬寫城市 option，全部由資料驅動

#### 4-2 新聞條目顯示強化
- 事件列表加入新聞來源媒體名稱（`sourcePublisher`）
- 快照連結顯示「原始來源 ↗」＋「本站快照（備份）↗」，標示擷取時間

#### 4-3 「待審核」事件的視覺提示
- 前台卡片顯示待審事件數（目前有 `pending` 欄位）
- 詳情面板中 pending 事件加入明顯「待審核」標籤，說明尚未人工查證

#### 4-4 機構無事件狀態處理
- 政府名錄匯入的機構若無任何事件，顯示「目前無紀錄，此機構已在監測範圍」
- 避免民眾誤以為空白代表有問題

#### 4-5 統計數字修正
- Hero 區的統計數改為：「已收錄機構數」、「已查證裁罰件數」、「資料來源數」

#### 4-6 地圖視圖（暫保留示意圖）
- 目前地圖為示意，加入說明文字：「地圖為示意，正式版將接入地理座標」
- 真實座標需後端地理編碼（Google Maps Geocoding API 或 TGOS），列為 Phase 6

---

### Phase 5 — 家長回饋投稿入口

**目標**：讓民眾可在前台提交對特定機構的回饋，進入審核流程。

**架構**（靜態方案，無伺服器）：
- 使用 [Formspree](https://formspree.io) 或 [Web3Forms](https://web3forms.com)（免費靜態表單服務）
- 提交後發 email 通知管理員，管理員用 `admin.html` 手動入庫

**表單欄位**：
- 機構名稱（文字，必填）
- 縣市（下拉，必填）
- 機構類型（下拉，必填）
- 事件類型：個人經歷 / 目擊 / 轉述
- 事件描述（textarea，必填，200 字以上）
- 發生時間（年月，必填）
- 佐證說明（可選，例如截圖說明）
- 同意去識別化聲明（checkbox，必填）

**前台修改**：
- 詳情面板「提出補充資料」按鈕改為開啟 modal 表單
- 首頁 Hero 區加入「回報問題機構」入口

**新增檔案**：
- 表單設定寫入 `admin.html` 說明區段
- `index.html` 加入投稿 modal

---

### Phase 6 — GitHub Actions 每日排程整合

**目標**：讓 `.github/workflows/update-data.yml` 正確執行完整的每日更新流程。

**現況問題**：
- `update-data.yml` 存在但內容未知，需確認是否已包含新腳本的呼叫
- PowerShell 腳本需在 GitHub Actions 的 Ubuntu runner 上改用 `pwsh`（PowerShell Core）

**修改內容**：

`.github/workflows/update-data.yml` 完整流程：
```
1. checkout repo
2. pwsh scripts/update-data.ps1 -MaxImportedPerSource 500
3. pwsh scripts/fetch-news.ps1
4. pwsh scripts/fetch-judicial.ps1
5. pwsh scripts/fetch-penalties.ps1
6. git add data/ archive/
7. git commit -m "chore: daily data update {date}"
8. git push
```

**注意事項**：
- 每次只抓增量（靠 `news-seen.json`、`judicial-seen.json` 去重）
- `archive/raw/` 快照只新增不刪除（保留歷史）
- commit 訊息帶日期，方便追蹤

---

### Phase 7 — admin.html 強化

**目標**：讓管理員能在 admin.html 中直接審核 review-queue，標記已查證/有爭議/移除。

**現況**：admin.html 只有新增事件表單，無審核介面。

**新增功能**：
- 讀取 `data/review-queue.json`（fetch 本地檔案，或貼上 JSON）
- 逐筆顯示待審事件，可點選：✓ 移入 events.json / ✗ 標記 disputed / 🗑 移除
- 輸出兩個更新後的 JSON：`events.json`（已審）、`review-queue.json`（剩餘待審）
- 顯示佐證 URL 與快照狀態

---

## 四、執行順序與相依性

```
Phase 1（新聞 RSS）
  → 不相依其他 Phase，可立即執行
  → 完成後 review-queue 開始有真實新聞條目

Phase 2（司法院 API）
  → 不相依 Phase 1，可平行執行
  → 需確認司法院 API 回應格式

Phase 3（裁罰公告）
  → 先確認教育部開放資料集 6258 是否有 JSON 資源
  → 若有：直接接，與 Phase 1/2 平行
  → 若無：需 HTML 解析，複雜度較高，延後

Phase 4（前台強化）
  → 不相依腳本 Phase，可隨時執行
  → 建議在 Phase 1/2 完成後執行，讓強化有真實資料驗證

Phase 5（家長投稿）
  → 需決定 Formspree / Web3Forms / 其他方案
  → 不相依其他 Phase

Phase 6（GitHub Actions）
  → 相依 Phase 1/2/3 腳本全部完成
  → 最後整合

Phase 7（admin 強化）
  → 相依 Phase 1/2/3（有足夠待審資料才有審核需求）
  → 可與 Phase 6 平行
```

**建議執行順序**：1 → 4（部分）→ 2 → 3 → 5 → 4（完整）→ 6 → 7

---

## 五、資料格式規範

### 事件（event）完整格式
```json
{
  "id": "news-{source}-{slug}",
  "verificationStatus": "pending | verified | disputed | removed",
  "autoImported": true,
  "importSource": "google-news-rss | judicial-api | penalty-gov",
  "institution": {
    "name": "機構名稱",
    "type": "幼兒園 | 國小 | 國中 | 高中職 | 補習班 | 課後照顧中心",
    "city": "台北市",
    "district": "大安區",
    "address": "完整地址",
    "code": "政府代碼（若有）",
    "aliases": []
  },
  "risk": "high | mid | low",
  "category": "news | judicial | penalty | parent_review | government_dataset",
  "title": "事件標題",
  "summary": "摘要（新聞只保留標題+摘要，不轉載全文）",
  "eventDate": "YYYY-MM-DD",
  "importedAt": "ISO8601",
  "tags": [],
  "evidence": [
    {
      "title": "來源標題",
      "publisher": "媒體/機關名稱",
      "url": "原始 URL",
      "type": "news | government_doc | judicial | parent_review",
      "capturedAt": "ISO8601",
      "snapshotPath": "archive/raw/{prefix}-{hash}.html",
      "httpStatus": 200,
      "status": "captured | capture_failed: ..."
    }
  ]
}
```

### 機構（institution）完整格式
```json
{
  "key": "唯一鍵（code 或 hash）",
  "name": "機構名稱",
  "city": "縣市",
  "district": "鄉鎮市區",
  "type": "機構類型",
  "address": "地址",
  "code": "政府代碼",
  "aliases": [],
  "phone": "電話",
  "website": "網址",
  "risk": "high | mid | low",
  "penalties": 0,
  "news": 0,
  "reviews": 0,
  "pending": 0,
  "disputed": 0,
  "updated": "YYYY-MM-DD",
  "tags": [],
  "dataSourceId": "moe-kindergarten-directory",
  "dataSourceTitle": "幼兒園名錄",
  "dataResourceUrl": "https://...",
  "xy": [50, 50],
  "events": []
}
```

### news-seen.json 格式
```json
{
  "updatedAt": "ISO8601",
  "seen": ["rss-guid-1", "rss-guid-2"]
}
```

### judicial-seen.json 格式
```json
{
  "updatedAt": "ISO8601",
  "seen": ["案號-1", "案號-2"]
}
```

---

## 六、法務與內容治理規範

（執行時每個腳本均需遵守）

1. **新聞只摘要，不全文轉載**：title + 100 字以內摘要 + 原始連結 + 快照連結
2. **家長回饋需去識別化**：不儲存姓名、不顯示聯絡方式
3. **區分「疑似」與「已定案」**：`verificationStatus: pending` 的條目明確標示「待查證」
4. **機構有更正申請管道**：詳情面板保留「機構聲明/補充說明」入口（Phase 7）
5. **每筆事件保留佐證鏈**：原始 URL + 快照 + 擷取時間 + HTTP 狀態
6. **政府名錄資料遵守授權**：「政府資料開放授權條款-第1版」，須標示來源與日期
7. **司法裁判書**：依司法院授權條款僅摘要轉載，全文以連結呈現

---

## 七、需確認的外部事項

| 事項 | 狀態 | 說明 |
|------|------|------|
| 司法院 API 實際端點格式 | 待確認 | 需實測 API 回應結構 |
| 教育部 dataset/6258（裁罰）是否有 JSON 資源 | 待確認 | 若只有 HTML 需另寫解析邏輯 |
| Formspree / Web3Forms 帳號 | 待決定 | Phase 5 家長投稿需要 |
| GitHub repo 是否已建立 | 待確認 | Phase 6 Actions 排程前置條件 |
| Google News RSS 速率限制 | 待測試 | 機構數多時需加 delay 避免被封鎖 |

---

## 八、不在本計畫範圍

- 正式後端（Next.js + PostgreSQL + PostGIS + Meilisearch）
- 真實地圖地理編碼（Google Maps Geocoding API）
- 使用者帳號系統
- 機構主動申訴的正式後端流程
- PTT、Dcard 等論壇爬蟲（涉及平台授權問題）

---

## 九、檔案變動總覽

### 新增檔案
```
scripts/fetch-news.ps1          # Phase 1：Google News RSS 抓取
scripts/fetch-judicial.ps1      # Phase 2：司法院 API 整合
scripts/fetch-penalties.ps1     # Phase 3：裁罰公告抓取
data/news-seen.json             # Phase 1：已抓取 RSS guid 去重紀錄
data/judicial-seen.json         # Phase 2：已抓取案號去重紀錄
data/penalty-seen.json          # Phase 3：已抓取裁罰紀錄去重
```

### 修改檔案
```
index.html                      # Phase 4：UI 強化
admin.html                      # Phase 5/7：投稿入口、審核介面
.github/workflows/update-data.yml  # Phase 6：加入新腳本呼叫
sources/source-registry.json    # Phase 3：新增裁罰資料源
```

### 保持不變
```
scripts/update-data.ps1         # 政府名錄匯入主腳本（不動）
scripts/add-event.ps1           # 命令列新增工具（不動）
data/events.json                # 正式事件（僅由腳本寫入）
archive/                        # 快照目錄（僅新增）
```
