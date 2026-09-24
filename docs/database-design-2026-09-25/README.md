# Vitail 資料庫現況與需求對照

2026-09-25。這份文件對齊本分支目前的 **22 張業務模型表**，包含 `WalkDog`；排除 Django auth、admin、session、token 及自動權限關聯表。它描述程式中的模型與 migration，**不是任何部署環境已完成 migration 的證明**。六張延後的表尚未建立，也不混進現況 ERD。

- [完整欄位、唯一鍵、索引與約束](./schema.dbml)：由 Django 模型產生。
- [完整關係圖](./schema.mmd) · [概覽圖](./overview.svg)。
- [37 張 Jira、14 條 User Story 逐項對照](./coverage.md)：保留來源與未完成範圍。
- [點數規則](../QUESTS.md) · [待定決策](../DECISIONS.md) · [現有 API](../openapi.yaml)。規則以這些文件為單一維護位置。

## 已連接與僅有資料基礎

「有表」不等於「功能可用」。目前沒有社交／GPS ingestion 公開 API、同行配對引擎，亦未啟用每日目標、streak 或 net-walking 發點。

| 表 | 現況與邊界 |
|---|---|
| `User`、`Breed`、`Dog` | Email/password、角色、頭貼、狗資料與生日已連接。社交偏好、晶片記錄、封存／刪除欄位提供基礎，不代表已有完整設定、晶片兌換 gate 或刪帳流程。 |
| `Venue`、`Reward` | 店家資料／菜單已連接；`Venue` 取代 `CafeProfile`。商品支援有效期間、每日供應量、條款。其他類別地點及其座標可儲存，尚未自動提供地圖打卡。 |
| `Redemption`、`CafeOrderFeedState` | 購買扣點、收據、滑動領取、到期退款及店家增量同步已連接。 |
| `PointEntry` | 唯一點數帳本；credit lot、到期、扣點、退款、來源分類及 Walk＋Check-in 共用 cap 已連接。 |
| `Walk`、`WalkDog` | Finish 後驗證上傳、距離／有效活動秒數、參與狗、重試與走路發點已連接。舊資料未知的秒數／快照維持 null。 |
| `WalkSession`、`LocationSample`、`NetWalkInterval` | 即時狀態、有限 GPS 證據與同行區間的模型／內部服務基礎。現行手機散步上傳不寫這些表；沒有持續 GPS 上傳、對外位置共享或 matching。 |
| `DogDailyGoal` | 每狗每日凍結目標及最終結果的資料基礎；20 點／天已定，公式與資格判斷未定，因此不產生目標或發點。 |
| `QuestDefinition`、`QuestAward` | Quest 目錄、生日資格與 Collect 已連接。模型可表達 goal／streak 資格，但沒有建立／領取這兩類的服務。開啟目錄不會啟動未實作規則。 |
| `CheckIn` | 共用進度查詢／Collect、每日類別唯一性及 cap 保護；Map／Quest 共用 iOS store。Start／定位驗證及正式 provider 尚未連接，不顯示假的進度或可領任務。 |
| `DocumentEntitlement`、`DocumentSubmission`、`EvidenceFingerprint` | 每狗私人文件、版本、證據重用保護、提交 READY → Collect 已連接。抽查／凍結欄位已建立，完整人工抽查與追回點數流程未交付。 |
| `Friendship`、`UserBlock` | canonical pair、邀請／回覆、雙向封鎖判斷的內部服務基礎；沒有朋友、搜尋、leaderboard 或位置公開 API／頁面。 |

延後且**未建立**：`ExternalIdentity`（Apple）、`ChatMessage`（單對單聊天／nudge）、`Charity`＋`Donation`（捐點）、`PushDevice`＋`NotificationDelivery`（遠端通知）。這裡只保留需求落點，不刊登尚未實作的欄位作為現有 schema。

不另建 Wallet、Leaderboard、通用 QuestProgress、每日點數 counter、ShoppingCart、OrderItem、支付或通用規則引擎。單次兌換仍只有一個商品；餘額與排名分別由帳本／活動查詢衍生。

## 核心關係與不變條件

**地點與帳號分開。** `Venue.manager_user` 可空且唯一；公園不必有登入帳號，一個 café 帳號目前最多管理一個地點。地點公開照片與 `User.photo` 各自保存。`Reward.venue_id` 是商品唯一歸屬，沒有永久雙寫的 `Reward.cafe_user_id`。API 為相容保留的 `cafe_id` 仍是 café **User ID**，新增的 `venue_id` 才是地點 ID；不能互換。

**訂單保存購買當下的責任與價格。** `Redemption` 的 venue、café User、商品／店名／顧客名／價格／條款快照保留歷史。每日供應量以 Melbourne `order_date` 計，未到期 PENDING 與 COLLECTED 占額度，取消／到期釋放。`requires_store_purchase` 目前只表達店內購買條件，沒有現金支付或最低消費核驗。

**帳本是唯一餘額來源。** 可用餘額來自未到期 credit 的 `remaining_points`，不是直接加總 `amount`。來源唯一鍵及業務資格的唯一 ledger FK 防止重複發／扣點。新增 earn 保存 `earn_category`、`earned_on`、`rules_version`；無法可靠判定的歷史來源不偽造分類。owner row lock 串行化領點、購買及退款。

**資格和領取分開。** `QuestAward.qualification_key` 全域唯一，生日另有 `(kind, dog_id_snapshot, year)` 唯一限制，換主人不能重領；`point_entry` 與 `awarded_at` 必須同時存在或為空。文件保留 entitlement、submission、fingerprint 三個不同概念；提交保留名額，Collect 才入帳，重傳不生另一份獎勵。Quest API 僅輸出 `server_time`、`timezone`、`local_date`、`next_reset_at`、`tasks`；不再提供無消費者的舊 goal／streak 區塊或 `/dogs/{id}/goal`。

**日期與上限有明確來源。** UTC 儲存 timestamp，日別使用 Australia/Melbourne。Walk 依結束日結算；Check-in 每 `(owner, local_date, category_slot)` 唯一，最多四類。Walk＋Check-in 目前共用 72/day；餘額、生日、文件、退款不納入。剩餘不足完整 12 點的 check-in 目前拒絕 Collect，不部分發點；Goal／Net 是否納入及部分發點政策仍待定。

**位置是尚未啟用的基礎。** `User.active_walk_session` 配合 owner lock；GPS 以 `(owner, stream_id, sequence)` 去重，需有 session 或 check-in 用途。Check-in attempt 可隔離重開前的舊樣本。`NetWalkInterval` 以排序 session pair 保存兩人的各自距離，內部驗證拒絕同 pair 重疊；未來計分仍須對每人的時間區間取聯集，不能按同行人數相加。目前沒有自動 matcher、net 點數結算或對外 GPS ingestion。

**模型約束和服務約束不同。** `schema.dbml` 列出實際欄位、DB unique/check 與索引；FK owner 一致、來源角色、跨列重疊、每日額度等由相應 service 或 `clean()` 驗證。`save()`／bulk 寫入不會自動執行所有 `clean()`；新的入口必須走既有服務，不能把 Python 驗證誤認成 DB CHECK。

## 隱私、稽核及尚未完成的政策

頭貼／商品／地點照片是展示資產，DB 保存 storage key；文件使用 private storage 與帳戶權限檢查。`LocationSample` 的表與索引不代表已有保留期限、清除排程或收集同意流程；這些必須在啟用 provider 前確認。

`auth_version` 已用於 JWT 失效檢查；`deleted_at`、`archived_at` 是支援停用／刪除的欄位，並非完整匿名化或資料刪除 API。財務參照大量使用 PROTECT，不能假設刪除 User 就會安全清掉全部個資。具體保留期限、匿名化與歷史快照處理仍待定。

沿用 Django Admin `LogEntry`，不新增 AuditEvent。但目前不能宣稱所有 café API 改價、點數處置、抽查都會自動寫入 admin log。文件已有 `audit_status`／review 欄位與 entitlement 凍結原因；尚無完整抽查服務。`PointEntry` 目前沒有 `ADMIN_DEBIT`，不要以直接改舊帳目冒充追回點數。

其他未定項目集中在 [DECISIONS.md](../DECISIONS.md)：每日目標公式、streak 合格日／重啟、Net 同意與配對、microchip 年期及兌換門檻、2/29 替代日、保留／刪除、慈善及遠端通知。咖啡約 504 點只是換算提示，不自動更改商品或歷史訂單點價。

## 來源與衝突處理

2026-09-25 查詢 `project = SCRUM ORDER BY key ASC` 取得 **37 張可見工作項目，isLast=true**。這是帳號當時可見的 SCRUM 範圍，不宣稱讀取其他專案或未提供附件。逐筆連結及原始狀態保留在 [coverage.md](./coverage.md)，Jira Done 不等於本文件驗證全部功能可用。

優先順序：後續使用者決定與 [DECISIONS.md](../DECISIONS.md) → [New Point Retrieval / Calculation v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation)（2026-09-24 15:06 UTC）→ [Client Meeting 09/24 v7](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/26738689/Client+Meeting+09+24)、[Detailed Meeting Minutes v4](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27787267/Detailed+Meeting+Minutes) → [Client Requirements](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/294913/Client+Requirements)、[User Story](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/10518529/User+Story)（兩者當時為 live document / draft）。[Design Preference v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28606465/Design+Preference) 提供視覺方向；[New Features Listings v1](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28377100/New+Features+Listings) 為空，不推導額外需求。

舊設計的事前審核、council 年度獎勵、咖啡約 60 點、swipe 扣點、28 張表全數建立及 Reward 雙重歸屬均不再描述現況。原提案與討論歷程留在 Git；目前圖只畫實際模型。

## 重建與驗證

在已安裝 `backend/requirements.txt` 的 Python 環境執行：

```bash
DATABASE_ENGINE=sqlite python docs/database-design-2026-09-25/render.py
DATABASE_ENGINE=sqlite python docs/database-design-2026-09-25/render.py --check
```

工具只載入 Django model metadata，**不連接資料庫、不套用 migration、不查詢使用者資料**。它重建 DBML、Mermaid、SVG，驗證 22 張表及所有 FK 目標，並檢查 37 個 Jira key 與 14 條 User Story 完整且不重複。`--check` 在產物落後於目前模型時失敗。

DBML 是可閱讀的欄位字典，不是 migration：型別採邏輯表示；ORM defaults／`on_delete` 放在 note，不能當成 SQL default／cascade；實際 DB CHECK 以模型 Q expression 註解保留。套用與回滾、舊資料遷移、MySQL 並行交易驗證以 backend migrations／tests 為準，這裡不重複記錄易過期的測試數量。
