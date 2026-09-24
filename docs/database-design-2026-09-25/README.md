# Vitail 完整資料庫設計

設計日期：2026-09-25 · **設計提案，尚未套用 migration 或修改資料**。

## 建議結論

沿用 Django + MySQL 與現在的點數帳本、商品、訂單、文件資格；補上 Venue、Check-in、每日目標及社交散步需要的資料。**核心共 22 張業務表，另 6 張依功能啟用**，包含一張 Walk–Dog 關聯表，不含 Django 內建 auth/admin/session 表。目前是 14 張業務模型表加一張關聯表；核心設計淨增加 7 張，CafeProfile 由 Venue 取代。

這份是全團隊的資料設計，所以包含其他組員負責的 Venue、Friends、Leaderboard；不代表把它們的實作接到本次 Quest 工作中。

- [完整欄位與關係：schema.dbml](./schema.dbml)
- [逐項 Jira／需求覆蓋：coverage.md](./coverage.md)
- [完整 ERD：schema.mmd](./schema.mmd)
- [資料關係概覽：overview.svg](./overview.svg)

**刻意不建立** Wallet、Leaderboard、QuestProgress、每日點數 Counter、ShoppingCart、OrderItem、通用規則引擎、商家員工權限系統。Wallet 是帳本查詢；排行榜是活動查詢；Quest 是各來源狀態的統一呈現。單次訂單目前只有一個商品。多店員、多分店、金流、評論、群聊均未獲得足夠需求支持。

## 1. 依據與優先順序

2026-09-25 完整查詢 `project = SCRUM ORDER BY key ASC`，取得 **37 張可見工作項目，isLast=true**；包含 Done／To Do 等所有狀態，而非只取目前 Sprint。這是目前帳號可見的 SCRUM 專案範圍，不宣稱涵蓋無權限讀取或其他未指定專案。

1. 本次對話已確認的規則，以及 [DECISIONS.md](../DECISIONS.md) R31–R56。
2. [New Point Retrieval / Calculation](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation)，本次讀取 **v3，2026-09-24 15:06 UTC**。使用者指定它是會後最新定案。
3. [Client Meeting 09/24](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/26738689/Client+Meeting+09+24) v7、[Detailed Meeting Minutes](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27787267/Detailed+Meeting+Minutes) v4，以及 Jira 各項功能。
4. Jira 連結的 [Client Requirements](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/294913/Client+Requirements) 與 [User Story](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/10518529/User+Story)。兩者回傳為 live document、status=draft；是重要來源，但其中舊規則不能覆蓋後續決策。

[New Features Listings](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28377100/New+Features+Listings) v1 目前是空白；不拿它補想像中的驗收條件。舊的 `docs/architecture/2026-09-24` 是未實作提案，已過時的文件審核、點數和資料表假設不沿用，也不覆寫該目錄。

### 已解決的文件衝突

| 議題 | 本設計採用 | 舊資料差異 |
|---|---|---|
| Daily goal | 最新點數表明列 **20 點／天**；每狗計算進度、帳號每日最多一份獎勵；公式待提供 | 舊設計稱新表未列 goal，已不適用 v3 |
| 72 點 cap | 已確認 Walk + Check-in；Goal／Net 是否計入仍待明確化 | 舊文件寫 Walk + Goal + Check-in |
| 文件 | 每狗各別資格，提交 → READY，Collect 才發點；之後可抽查 | 舊文件先審核才發點；先前對話也曾暫定提交即發點 |
| Council | 每狗終身一次 300 | 舊需求每年一次 |
| Streak | 7 天 20；30／60／90…各 100；7 天是否每次新 run 都可再領待確認 | 舊文件稱 7／30 一次性 |
| 狗數量 | 現行 R32 上限 10；schema 使用一對多，不把上限寫死在表 | 舊資料先 1，後 2，並曾要求每狗分別賺 walking points |
| Walking 點數單位 | 目前每帳號 8/km、40/day，不因狗數乘倍；保留每狗活動資料 | 舊「每狗分別得分」需產品再確認，不能默默改現有經濟 |
| 店家 | Admin 建帳，店家自己管理商品與公開資料 | 舊 User Story 不要店家管理頁 |
| 兌換 | Purchase 扣點，Slide Collect 只改狀態；到期退款 | 舊 User Story 寫 swipe 才扣點 |
| Auth | Email/password 現行；Apple 後續；Google 非目前交付範圍 | 舊文件 Android + Google／Apple |
| 定價 | Phase 1 Puppuccino 約 72、咖啡約 504；實際仍是各商品價格 | 原本 60 點咖啡估算已被最新點數方向取代，不自動改既有訂單 |

## 2. 資料表分組

| 領域 | 核心表 | 用途 |
|---|---|---|
| 身分、狗狗 | User、Breed、Dog | 登入角色、頭貼、狗狗資料與真實生日 |
| 地點、商店 | Venue、Reward、Redemption、CafeOrderFeedState | 地圖地點、菜单商品、訂單／領取、店家更新游標 |
| 點數 | PointEntry | 唯一餘額來源，含到期 credit lot 與扣點／退款 |
| 散步 | Walk、WalkDog、WalkSession、LocationSample、NetWalkInterval | 已驗證活動、狗狗參與、即時狀態、短期 GPS 證據、同行區間 |
| Quest | DogDailyGoal、QuestDefinition、QuestAward、CheckIn | 每狗目標快照、小型目錄、一次性領獎資格、四類 check-in |
| 文件 | DocumentEntitlement、DocumentSubmission、EvidenceFingerprint | 獎勵資格、版本化證據、防重複提交 |
| 朋友 | Friendship、UserBlock | 邀請／接受、位置可見性與封鎖 |

延後按功能新增的 6 表：ExternalIdentity（Apple）、ChatMessage（單對單訊息／nudge）、Charity + Donation（點數捐贈）、PushDevice + NotificationDelivery（遠端通知）。它們已有具體 schema；不必為尚未交付的功能先建立空表。

保留 Django 的群組／權限和 `django_admin_log`；不另建 admin 帳號表、權限框架或通用 AuditEvent。所有需要留痕的 API 與 admin 變更都透過共用 service 寫入 LogEntry，詳見第 9 節。

## 3. 共通規範

- 內部主鍵沿用 bigint；對外操作 UUID 是重試識別，不能拿來代替權限檢查。既有主鍵不重編。
- 時間戳存 UTC；點數、生日、Streak、四個 Check-in、今日已領取都用 **Australia/Melbourne** 日期。日期歸屬欄位一旦結算不能因換手機時區改變。
- 金額是整數 points，距離 `decimal(10,2)` 公尺，時間整數秒；不使用浮點點數。GPS 座標 `decimal(9,6)`，不用額外 GIS 服務即可先做 bounding-box + 距離檢查。
- 欄位中的 enum 是有限值（Django TextChoices + 必要 DB CHECK），不是可以任意執行的文字規則。版本化計算規則放程式碼；資料保存 `rules_version` 和重要輸入快照。
- 照片／PDF 放檔案儲存，DB 存 storage key／雜湊／MIME／大小。Avatar 是公開或授權顯示資產；文件是 private storage，不能共用公開網址。不要把短期簽名 URL 存成永久照片來源。
- JSON 僅用不可變快照、原始重試回應、結構固定的通知偏好；FK、狀態、點數、日期、配額不可藏在 JSON。沒有 EAV／任意 condition-expression 模型。
- DB 管唯一、非負、合法時間與單列 state shape；跨列的權限／每日總額／間隔／區間不重疊，由交易內 service + locks 保證。不能把 API validator 當成並行安全保證。

## 4. Venue 與 Check-in

### Venue 不再等於 User

`Venue` 的種類是 CAFE / RESTAURANT / PARK / VET；保存名稱、介紹、照片、地址、經緯度、營業時間文字、Google Maps URL、是否開放 check-in、是否為合作商家。

`manager_user_id` 可空且 unique：一個 Café 帳號目前最多管理一個 Venue；公園、非合作獸醫院不需要帳號。店家登入照片和地點公開照片分開；登入身分改名不應替所有舊訂單改店名。坐標未知可為 null，但不能開啟定位驗證。營業時間先維持可展示文字，不假裝支援「現在營業中」的精準排程查詢。

`Reward.venue_id` 是商品歸屬的最終來源；過渡期保留 `cafe_user_id` 雙寫，完成遷移才移除。歷史 `Redemption.cafe_user_id` 則保留：它代表下單時負責的帳號，不隨新店長接手自動搬走。舊訂單存 Venue／商品／顧客／條款快照。

### 四個每日機會

建議解讀為四種類別各一個：Cafe、Restaurant、Park、Vet；各 12 點，達成門檻分別 10／20／5／3 分鐘，半徑 20m。這符合最新表四列各 12/day，但「四個是否可為任意四家」仍是產品解讀，非假稱已確認。

`CheckIn` 每 owner + local_date + category_slot 唯一，最多四列。當 API 顯示當日機會時可建立四個 slot；附近可用地點配到各列，缺地點的 slot 不回傳為可做任務。`venue_id` 在 Start 時固定；不允許換地點沿用前一家進度。若要換地點，必須在同一列原子重設未完成進度並更換 attempt_id，不能新增第五次機會；舊 attempt 的 GPS 批次一律拒絕。

保存 `verified_seconds`、`last_verified_at`、最後採樣時間／座標的小型驗證游標、地點中心／半徑／時長／點數規則快照、READY 時間、Collect 時間、ledger FK。開始後店家編輯座標不改本次圍欄。同一天離開後回來，累加已驗證停留秒數；離開或 GPS gap 不累加，也不把最後一點和很久後下一點連成停留。新的一天建立新列；昨天未完成不發點且不延續。READY 的領取期限預設當日結束，需在功能啟用前與組員確認。樣本去重插入與各消費者進度更新必須同交易完成，不能先存 sample 成功、再讓 crash 造成永久漏算或重試重算。

Map 和 Quest 讀寫同一個 `CheckIn.id`；兩邊同時按 Collect 也只有一個 ledger entry。畫面三態為 IN_PROGRESS / READY / COLLECTED；定位無效、已過期等後端狀態不必增加 UI 主分類。

尚未到 72 點時，四個可用機會全部顯示；到 cap 後隱藏未領取項目，保留今天領過的列。這是查詢條件，**不刪除資料**。生日、文件、退款、管理員加點及目前餘額不影響這個 cap。

## 5. Walking、Daily goal、Streak、Net-Walking

### 分開已完成紀錄與即時狀態

`Walk` 保留目前已完成、已驗證的摘要及 UUID 重試。新增 validated active_seconds、net_distance_m、base/net ledger FK、規則版本；未知的歷史 active_seconds 保持 null，不能拿 ended_at − started_at 冒充走路時間。

現有多對多 join 升級為具名 `WalkDog`：每 Walk + Dog 一筆，保留 dog_id/name 快照與本次已確認參與的 active_seconds / distance。若本次所有狗全程同行，數值等於 Walk；未來要支援中途加入才需要更細區段，目前不新增 WalkDogSegment。

`WalkSession` 是在線開始／暫停／結束／逾時的短期控制紀錄，可先沒有 Walk；`walk_id` nullable unique，舊 Walk 也不必補 session。`User.active_walk_session_id` nullable unique + owner 鎖是 MySQL 可用的一人一個 active session 防護；service 檢查 session.owner 相同，避免依賴不受支援的 partial unique index。

`LocationSample` 保存有明確目的的短期 GPS 樣本，可用於 walk／check-in／同行驗證。owner + stream UUID + sequence 唯一，重送批次不能重複累計；server 接收時間、採樣時間、accuracy、speed、來源標記全部驗證。沒有進行中的功能或同意，不收集樣本。GPS 不是百分之百防作弊；保留驗證結果與版本，不對單個壞點自動停權。

目前 route 仍只存在手機。新增 server 短期證據不等於承諾永久 route history；原始資料刪除前必須完成驗證與摘要結算。位置保留天數與同意尚待定，不能先無期限存。

### Daily goal

`DogDailyGoal` 每 dog + date 一筆：目標 active seconds、公式版本、當日 breed/age/size/brachycephalic/季節等輸入快照。公式未定時不建立假的 15 分鐘目標，不發 goal 點數；SCRUM-45 的 15 分鐘是示例。

已完成進度來自當天有效 `WalkDog`；散步中的暫時進度可用 session 驗證結果加上去展示，Finish 選狗確認前不能正式記入每狗紀錄／發點。參與狗狗在 Finish 才選是現行 UX；若要每狗即時進度完全準確，需要組員確認提前選狗或明確標示暫估。

Daily goal 的 20 點先沿用 R31：當日有參與的狗各自達標，帳號最多領一次。`QuestAward` 保存 Collect 當下的 goal IDs／目標／達成值快照。建議收取後當日新加狗不追回既得點數；此結算時點是提案，需產品確認。

### QuestAward 與 Streak

擴充目前生日專用 `QuestAward`，只承接 BIRTHDAY / DAILY_GOAL / STREAK 三種獎勵；不把文件、Check-in、Walking 再包成另一份 PointAward。

`qualification_key` 全域唯一，例：`birthday:dog:42:2026`、`goal:owner:7:2026-09-25`、`streak:owner:7:run:2026-09-01:30`。生日按狗身分唯一，不能換 owner 重领。Daily goal 按 owner + day；Streak 按 run 起始日 + milestone；規則版本不放進 uniqueness key，避免升版重領。

READY 可由已驗證活動建立資格；point_entry 及 collected_at 為空。Collect 原子建立 ledger 並更新資格。UI 的 collected 是收取狀態，不能與「已達標」混為一談。

Streak 從每日合格活動查詢；斷一天重新開始。保留 `qualified_on`、run_start_date、milestone_days、資格快照。不用為畫 7 格進度條建立 StreakDay 表。若合格標準採每天完成所有狗 goal，就從 frozen DogDailyGoal + validated WalkDog 計算；若採任一有效 walk，改同一個版本化 predicate。**標準尚未確認，兩種不得混算。** 30/60/90…反覆里程碑有來源；7 天是每新 run 一次或帳號終身一次、領取期限仍待定。

### Net-Walking

`NetWalkInterval` 保存兩個不同 owner 的 session 之間驗證合格的共同時間區間、兩人的合格距離、matching 規則版本及最少的證據摘要。session pair 用 low/high 正規順序；同一 pair 的有效區間不得重疊。兩人皆同意 matching，但不必是朋友；分享地圖位置與 matching 同意分開。

計算每個 session 的同行距離時，對合格區間取**時間聯集後重算該使用者距離**，不是加總 pair distance。A 同時與 B、C 走 1km，A 只有 1km boost。不能用兩人距離的平均或任意一方距離。

session 結束後，等已收到的驗證批次在有界視窗內 settle，再一次性產生 `Walk.net_point_entry`；每帳號 2/km、10/day。`net_settled_at` 後不接受樣本補算或重發，避免晚到資料造成第二次 bonus。具體 proximity、時間窗、截止、速度與 consent 規則待 social 組確認；目前 finished Walk 摘要不足以回推歷史同行，不補發過去 bonus。

## 6. 點數交易與每日 cap

PointEntry 是唯一帳本。正數 credit 有 `remaining_points` 與 12 個月到期日；spend 使用最早到期的 credit。餘額為有效 credit 的剩餘總和，**不是單純 SUM(amount)**。不另外建 Wallet.balance。

新增 `earn_category`（WALK / NET_WALK / DAILY_GOAL / CHECK_IN / STREAK / BIRTHDAY / DOCUMENT）、`earned_on`、`rules_version`；非 earn entry 留空。歷史可辨識來源安全回填，不明 ADMIN 不硬改 EARN。這讓 daily cap、點數統計不用解析自由格式 source_reference，也不會把 refund 算成收入。計算活動排行榜仍應使用 Walk、CheckIn、Goal 等活動來源，獲得多少點和目前剩多少點是兩件事。

| 來源 | 資格／去重 | 額度 |
|---|---|---|
| Walking | Walk UUID + base ledger 一對一 | floor(當日合格累計 km × 8) 差額，最多 40 |
| Net | Walk + net ledger 一對一，union 後距離 | floor(當日 net 累計 km × 2) 差額，最多 10 |
| Check-in | owner/date/category slot | 每列 12、最多四列；受 72 shared cap |
| Daily goal | owner/date QuestAward | 20/day |
| Streak | owner/run/milestone QuestAward | 7→20、30n→100 |
| Birthday | dog/year QuestAward | 60/year |
| Council | dog/COUNCIL/lifetime entitlement | 300 一次 |
| Microchip | dog/MICROCHIP/實際有效期 entitlement | 300/年期；重疊期不可新增資格 |
| Vet | dog/visit date entitlement | 200、每實際看診年最多兩次、跨年仍隔 ≥60 天 |

同一次發點：transaction → 鎖 owner → 鎖資格／dog／相關紀錄 → 找既有結果 → 算當日已領與剩餘 cap → 寫 ledger → 標記 collected → commit。固定鎖順序；涉及兩人以 user ID 升冪鎖，禁止不同路徑反向拿鎖。

72 cap 候選只先包含 WALK、CHECK_IN；是否再含 GOAL、NET 以版本化集合決定，在確認前不宣称完整經濟已定案。若剩 8 而本次 check-in 值 12，**建議發 8 並以 collected 結束資格，不保留隔天補 4**；partial award 是尚待確認的產品規則。schema 同時保存 promised_points 與 ledger 實得，因此無需改表即可支援全額才可領的另一種決策。

同時兩個 Collect／背景 expiry／購買一律共用 owner lock，不允許先讀 sum 後各自扣點。source_reference 全域唯一且每個來源的 ledger FK unique；資格 unique 是第二道防線。0 點不造 PointEntry；若 cap 全滿不標 collected，由查詢隱藏未領。

跨午夜：現行 Walk 按 ended_at 的 Melbourne 日期結算；此次保留，不暗改為分段計日。CheckIn 只累計自己的 local_date，午夜截斷；特殊／文件獎勵按 entitlement 週期，收取 timestamp 決定何日顯示。新上傳的 walk 仍受既有 12 小時接收窗；接受跨日延遲的 finalised 活動如何影響 Streak 必須統一，不憑 client 時間改已結算資格。

## 7. 文件與抽查

保留三表，因為「獎勵資格」「檔案版本」「證據重用」不是同一件事。

- DocumentEntitlement：每狗每種資格一筆，提交就先保留年度名額；尚未 Collect 也不能重複占另一個名額。保存 validity / event date、rule version、promised points、ledger 與收取時間。
- DocumentSubmission：每次提交不可變，檔案與輸入資料、request fingerprint、原始回應快照；重傳同一資格產生新版本，不產生新獎勵。
- EvidenceFingerprint：同狗同種類同證據不得拿去申請另一個資格；不同狗可使用合法的共用家庭證明。保留現有 owner-scoped uniqueness，跨轉移的 qualification uniqueness 仍靠 entitlement；若要跨 owner 擋重用，需要先釐清個資與轉移政策。

後續抽查只加 DocumentSubmission 的 audit_status、reviewed_by、reviewed_at、review_reason，以及 entitlement 的 eligibility_status/reason。SELF_REPORTED 不是 VERIFIED。Rejected 的資格必須凍結新領取；已領的點數**不直接修改原 ledger**，如需追回另走有理由的 admin adjustment。現行帳本只支援正向 ADMIN；設計新增 ADMIN_DEBIT 負向類別，剩餘 credit 的扣除與 spend 共用原子操作，但理由與行為必須留 log。建議不足餘額就交人工處理、不建立隱藏負債；實際追回政策待確認，不能拿扣點假裝證據已被驗證。

Dog.microchip_number 是 onboarding／兌換 gate 的帳面識別值；文件資格是「這次登記期間是否領過獎」，两者分開。填 number 或上傳證明不自動變成 verified。PDF 只有檔案但未能抽取 number 時，也不能憑空滿足要求 number 的 gate。格式與兌換要檢查哪隻狗待確認；order 保存當次檢查所用 dog IDs／number 是否存在的結果快照，不複製敏感 number 到公開收據。

## 8. 店家、訂單、捐贈

Reward 加 validity start/end、每日供應量上限 nullable、條款、是否需店內最低購買、可選圖片。最低消費以文字展示＋需要購買的布林值足夠；未有正式金額與支付需求，不建 payment 表。每日供應量在 reward row lock 內依當地訂單計算；建議 PENDING/COLLECTED 占名額，CANCELLED/EXPIRED 釋放，需與店家政策確認。

Redemption 保留單商品、unique reference、request UUID、point cost／商品／店名／顧客名快照；加 venue FK、terms snapshot、spend/refund ledger unique FK 及微晶片 gate 的最小快照。Purchase 原子扣點；Collect 不再扣；到期或 admin cancel 最多一次 refund。按現行退款是新的 12 個月 credit，不需要 PointAllocation 表；若將來要求退回原 credit lot 的原到期日，再增加 allocation，不能假稱目前可以逐 lot 還原。

店家 order 上狗狗頭貼目前代表**顧客 profile dogs**，不聲稱這筆訂單一定帶了哪隻狗；由顧客當前 profile 授權查詢即可。若產品決定兌換綁定狗，再將 chosen dog IDs/name/photo 快照加在 order；不先新增 order-dog 關聯。

Charity / Donation 是 User Story 8 的 later slice：approved charity、確認後扣點、唯一 reference、request UUID、spend ledger FK、名稱與點數快照；不冒充 cafe order。這裡是捐出 points 的可稽核記錄，不宣稱已轉成金錢或完成外部慈善匯款。Phase 1 沒有 app 內金流。

## 9. 朋友、Leaderboard、隱私與後續功能

Friendship 使用 canonical user_low/user_high pair，unique 且 low < high，requested_by 必須是 pair 成員。PENDING 不能讀對方位置；只有收件方能接受。拒絕／取消刪除或改為 DECLINED 同一列後可受限重邀，不建第二份 FriendRequest。UserBlock 為有方向的 blocker/blocked unique，任一方向封鎖即拒絕搜尋結果中的可見資料、邀請、地圖、訊息和 matching；封鎖時同步清除可見快取。

User 存 public_id（隨機唯一且不能當授權 token）、virtual_avatar_key、location_visibility=OFF/FRIENDS、net_matching_enabled。預設位置 OFF。WalkSession 中最新有效位置及 expires_at 用來顯示**正在散步且新鮮的**位置；權限每次讀取重查，停止／登出立即撤掉。精度、TTL、陌生人是否可見未定；本設計保守採朋友才顯示精確位置，任何人 matching 則由 server 內部處理，不暴露陌生人 GPS。

Leaderboard **沒有表**：查自己 + 同意排行榜分享的 accepted friends − blocks，以 Walk 已驗證距離/時間、DogDailyGoal 日達成、Streak 7 日狀態聚合；當日／本週條件採 Melbourne。metric 與同分排序待 social 組確認，不能把 wallet balance 當活動分數。初期加索引足夠，等量測出瓶頸再加可重建 cache，不先建 materialized ranking。DogDailyGoal 在接受晚到 walk 的窗口結束後保存 final_active_seconds／final_goal_met／finalised_at，保留過去七天結果；未 finalise 的今天仍從活動動態計算。

ChatMessage 是有需求再開的一對一文字／NUDGE，同一 canonical pair 可排序查詢，不需要 Conversation/Participant/Thread 三表；保存 sender、recipient、client UUID、body、sent/read timestamps。每次送／讀檢查 accepted friendship 和 blocks；刪除友誼後是否仍可讀歷史待確認。群聊、附件、通話不在已定案範圍。分享 walk stats 走 iOS share sheet，預設不含精確路線／住址，無需 Share/Post 表。

ExternalIdentity 用 unique(provider, subject) 連 User，為 Apple／未來真的需要的 provider 預留；不能用未驗證 email 自動合併帳號。Password reset 使用 Django 標準 token，不建明文 ResetPassword 表。強制停權、登出全部裝置採 user auth_version + JWT驗證或既有套件的失效機制；只刪 client Keychain 不足以撤銷所有 token。

通知延後實作時才新增 PushDevice（多裝置 token、平台、啟用）與 NotificationDelivery（user/type/dedupe_key、排程、過期、重試／狀態、最小 payload）。User 結構固定的通知 preferences 包含種類開關、quiet hours、時區／頻率。排程與 cooldown 查 delivery，重試同 dedupe_key；provider timeout 無法保證設備端 exactly-once，不對外作此承諾。可以先用本機提醒，無需先建 server push 系統。

Admin 稽核：沿用 `django_admin_log`，在 domain service 裡寫 actor、action、target id/名稱快照、時間和結構化 before/after/理由。店家 API 改商品也要寫，不能依賴 Django Admin 自動記錄它沒經過的操作。停權、手動加減點、證據判定必有 reason；不把完整 GPS、證件號、檔案內容寫入 log。保留 point ledger 的獨立記錄，log 不能拿來計算餘額。刪除 actor 帳號時採匿名 tombstone，避免 Django 的 cascade 一起刪除 log。若未來需要法規等級不可變稽核，才另評估專用 append-only log，現在不宣稱 Django log 有防竄改保證。

## 10. 索引、查詢與不變條件

所有 FK 預設建索引；`schema.dbml` 明列業務 unique 與重要複合索引。最常用查詢：

| 查詢 | 建議索引／來源 |
|---|---|
| Wallet／即將到期 | PointEntry(user_id, expires_at)，篩 remaining_points > 0 |
| Daily cap／點數收入 | PointEntry(user_id, earned_on, earn_category)，只取 EARN |
| Walk history／排行榜 | Walk(owner_id, point_date)，Walk(owner_id, ended_at) |
| 每狗當日進度 | WalkDog(dog_id_snapshot, walk_id) + Walk.point_date；DogDailyGoal(dog_id_snapshot, local_date) unique |
| Check-in／Quest 共用狀態 | CheckIn(owner_id, local_date, category_slot) unique |
| 今日收取 | 各來源(owner_id, collected_at)；依 Melbourne 日的 UTC 起迄 range 查 |
| GPS 驗證與清除 | LocationSample(owner_id, recorded_at)、(session_id, recorded_at)、(received_at) |
| Cafe orders 增量更新 | Redemption(cafe_user_id, feed_cursor)，保留現行 cursor 機制 |
| 商品日配額 | Redemption(reward_id, order_date, status) |
| Friends | unique(low, high)，另(high, status)；low 前綴已可用 |
| Leaderboard | 同日 Walk／Goal 聚合，好友集合獨立查；不把 M2M join 放同一 sum 造成點數乘狗數 |

特別需要 DB／service 保護：positive price；非負距離和秒數；end > start；lat/long 範圍；coordinate 成對存在；slot 固定四種類型；claim ledger owner 與 claim owner 相同；收取時間與 ledger 成對；文件週期不重疊；vet 60 天間隔涵蓋跨年；跨狗轉移不重领；reward manager 角色檢查；單一 active session；任何改點入口鎖同一 owner。

## 11. 刪除、保留與資料遷移

**先停用，再處理個資刪除**：User 提供 deleted_at/auth_version，請求確認後立即停用登入、撤銷 location sharing／push／social identity；清除 GPS、照片、文件等個資按已批准 retention policy 執行。需要保留參照完整性的財務列採匿名 tombstone user，不能把 email 永久當 tombstone。Dog 採 archived_at 優先；舊紀錄保留無個資的 dog identity snapshot，個資快照仍須一併處理刪除要求。這是技術支援方式，不是自行定義法律保存年限；正式保留期限尚未確定。

Venue／Reward 下架，不刪已被訂單引用的 row。公開頭貼的移除必須同步處理舊 storage object／cache。證據檔案保留期限未定，不因暫時 private 就無限期保存。

遷移順序：

1. **Additive schema**：先新建 Venue，涵蓋所有 CAFE 帳號以及既有商品／訂單引用的 café 身分，再合併存在的 CafeProfile 公開欄位；CafeProfile 可缺少，不能只按 profile 筆數建立。保留 User→Venue 明確對照，不假設 ID 相同。名稱沿用現有公開名稱，照片則把檔案複製到獨立 Venue storage key，避免只複製路徑後更換 User 頭貼把共用檔案刪掉。地址是 demo 就不要編造實際座標。
2. Reward／Redemption 加 nullable Venue FK；逐筆回填、比對筆數、保留既有訂單快照與 reference。新寫入雙寫、改讀 Venue，验证後才設必要 non-null 和移除 Reward.cafe_user／CafeProfile。Redemption.cafe_user 不移除。
3. PointEntry 加分類／日期／版本和各來源 ledger FK；用現有 source_reference 做可證明的 mapping。未知 source 留 legacy，不能重發點或改原 expiry、remaining_points。
4. QuestAward additive 增加 qualification_key，從 birthday dog/year 無歧義回填；nullable ledger 支援 READY。舊 unique 在新 unique 驗證完成後才調整。文件沿用現有資格與收取時間，不把已提交新發一次獎。
5. WalkDog 把原 join 轉為 through model，保留 join IDs／配對；新加 snapshot／activity 欄位只能回填已知資料，未知 duration 和歷史狗名留空，不把目前已改過的名字冒充當時名字，不補發 goal。DogDailyGoal 等公式確認後才啟用。
6. 上線 CheckIn、friends、即時 session／短期 samples，再接 map + Quest。每個來源獨立 feature flag；未完成驗證的功能不得僅因 QuestDefinition.enabled 就發點。
7. Apple、chat/nudge、charity、push 依實際 Sprint 建後續 6 表。SQL schema 有設計，不表示本次執行建表。

遷移前後對帳：User/Dog/Reward/Redemption 數量、所有 PointEntry ID/amount/remaining/expiry、逐 owner balance、訂單負責人及快照、文件 entitlement 唯一性和已領 ledger、原 request UUID 重試回應。零意外差異才切換。先在副本測 migration 與 rollback read path，不刪正式資料重建。

## 12. 實作前還需要定案的少數規則

這些影響計算與顯示，**不阻礙建立本設計的關係**，但功能發點前必須明確：

1. Goal 的公式／單位；參與狗 roster 與收取後新增狗；Streak 合格日標準、7 天重複規則與領取期限。
2. 72 cap 是否包含 Goal／Net；不足一份時 partial award；四個 slot 是四類各一，還是任意四家。若改任意四家，category_slot 改 slot_number 1–4，另訂 category cap；不需重做其他表。
3. Net proximity／最短同行時間／結算視窗；地圖精度／位置 TTL／原始樣本 retention；聊天與 nudge 的確切範圍。
4. Microchip 實際有效期或曆年；格式；兌換需檢查哪隻狗；2/29 生日在平年的領取日。
5. 多狗是否維持現行每帳號 walking cap；文件抽查後追回點數及不足餘額策略；商品配額取消後是否釋出。

其餘都可按上述 schema 分階段實作；不需要先引入微服務、事件匯流排或可程式化 Quest 引擎。
