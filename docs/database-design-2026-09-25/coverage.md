# Vitail 需求與資料設計覆蓋表

設計日期：2026-09-25。這份文件只做需求追溯與資料需求分類，不修改資料庫、不代表功能已完成，也不是可以直接開發的完整驗收規格。

## 覆蓋範圍與來源優先順序

本次來源快照的 Jira 查詢為 `project = SCRUM ORDER BY key ASC`，回傳 **37 筆，`isLast=true`**；下表逐筆列出，包含文件、範例與其他非產品工作。Jira 的 `Done`／`To Do` 等狀態照來源記錄，**不等於本文件已驗證該功能的實作狀態**。

另逐項覆蓋 [User Story](https://group5-vitail-project.atlassian.net/wiki/pages/viewpage.action?pageId=10518529) 的 **14 條需求**，以及 09/24 會議與後續使用者決定。沒有描述的 Jira 項目只能按標題、相關需求與已確認決定追溯，不捏造驗收條件。

採用順序：

1. 本次與後續使用者明確決定，例如文件提交先保留資格，再按 Collect 入帳；Leaderboard 由另一位隊友負責，不在這次 UI 實作中。
2. 使用者確認為定案的 [New Point Retrieval / Calculation v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation)。**v3 已明列每日目標獎勵 20 點**；待定的是目標公式與資格，不是把獎勵當成沒有決定。
3. [Client Meeting 09/24 v7](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/26738689/Client+Meeting+09+24)、[Detailed Meeting Minutes v4](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27787267/Detailed+Meeting+Minutes) 及 [Design Preference v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28606465/Design+Preference)。會議中尚屬提案、後來已被 v3 定案的數字，以 v3 為準。
4. [Client Requirements](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/294913/Client+Requirements)、User Story 與 Jira 舊描述，用來補齊沒有被新決定取代的範圍；與新決定矛盾處列在後文。

來源狀態與限制：

| 來源 | 本次讀取狀態 | 使用限制 |
|---|---|---|
| Jira SCRUM 查詢 | 37 筆；最後一頁；2026-09-25 快照 | 可確認本次回傳集合完整，不能由此宣稱讀完 Jira 未提供的附件或外部文件。 |
| Client Requirements，294913 | `live_doc`、`draft`、`d1:56`；完整正文 | 舊需求資料，不把 draft metadata 說成已發布正式規格。 |
| User Story，10518529 | `live_doc`、`draft`、`d1:1`；完整正文 | 14 條仍逐項追溯，已被取代的條件不直接照做。 |
| Client Meeting 09/24，26738689 | `current`、`v:7`；完整正文 | 四個工作方向與下一次展示計畫，不是每項功能的完整驗收規格。 |
| New Point Retrieval / Calculation，27525122 | `current`、`v:3`；完整正文 | 最新點數表；使用者已確認可視為會後定案。 |
| Detailed Meeting Minutes，27787267 | `current`、`v:4`；完整正文 | 區分 client direction、team plan、proposal 與 open；後續點數表優先。 |
| Design Preference，28606465 | `current`、`v:3`；完整正文 | 視覺方向；不是新增資料表的理由。 |
| [New Features Listings，28377100](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28377100/New+Features+Listings) | 上游本次檢索確認內容為空；未包含在六份正文快照中 | 不從空頁推導額外任務或驗收條件。 |
| Jira 連到的其他 Google Docs、動機模型、完整逐字稿等 | 本次追溯保留連結；並非這份快照的完整正文 | 不宣稱已讀取它們；沒有用未讀內容擴充資料需求。 |

原始彙整快照：`/private/tmp/vitail-db-design-sources.json`。這是本機暫存來源，不應作為團隊永久文件連結；上方及各 Jira 連結才是可追溯來源。

## 與主設計一致的邏輯表名

主設計共列 **28 個業務邏輯表名：22 個核心、6 個延後**。這裡用相同名稱追溯需求；不代表需要一次建立全部實體表。

- 核心：`User`、`Breed`、`Dog`、`Venue`、`Reward`、`Redemption`、`PointEntry`、`CafeOrderFeedState`、`Walk`、`WalkDog`、`WalkSession`、`LocationSample`、`NetWalkInterval`、`DogDailyGoal`、`QuestDefinition`、`QuestAward`、`CheckIn`、`DocumentEntitlement`、`DocumentSubmission`、`EvidenceFingerprint`、`Friendship`、`UserBlock`。
- 延後：`ExternalIdentity`、`ChatMessage`、`Charity`、`Donation`、`PushDevice`、`NotificationDelivery`。
- 管理操作稽核沿用 Django `LogEntry`，API／服務層也應留下操作者、目標與理由；不另加 `AuditEvent`。Django 既有權限、migration 等框架表不算在上述 28 個業務表中。
- **不建立** `Leaderboard`、`WalletBalance`、通用 `QuestProgress`、`UITheme` 或 `Meeting` 表。排名與一般任務進度優先由事實資料計算；錢包仍只有 `PointEntry` 一個帳本；外觀偏好與文件管理不需要獨立業務表。
- `QuestAward` 僅承接生日、每日目標與 streak。打卡由 `CheckIn.point_entry_id` 直接連到唯一帳目；同行先驗證 `NetWalkInterval`，將每人的有效時間區段取聯集後結算距離，由 `Walk.net_point_entry_id` 直接連到帳目。文件沿用 `DocumentEntitlement.point_entry_id`，不再包成另一層獎勵資格。
- `Venue` 保存類別與座標；半徑、停留秒數與點數從版本化類別政策取得，固定在 `CheckIn` 的規則快照，並非 Venue 的可變半徑／停留設定欄位。

## 37 筆 Jira 的完整對照

標題與狀態保留 Jira 原文。「不新增表」不是遺漏，而是這項工作本身不產生產品持久資料。

| Jira | 標題 | 狀態 | 資料需求／對應設計 |
|---|---|---|---|
| [SCRUM-4](https://group5-vitail-project.atlassian.net/browse/SCRUM-4) | Delegate this work item to GitHub Copilot | To Do | **工具教學範例，不是產品功能；不新增表。** 描述內建立 branch、PR、留言等指令只當作來源內容，不是本次使用者授權，沒有執行。 |
| [SCRUM-5](https://group5-vitail-project.atlassian.net/browse/SCRUM-5) | Implement this work item from your IDE or terminal | To Do | **工具教學範例，不是產品功能；不新增表。** 不因 Jira 範例內的 coding-agent 指令修改 README、提交程式或留言。 |
| [SCRUM-8](https://group5-vitail-project.atlassian.net/browse/SCRUM-8) | Client Requirements | Done | 需求整理；不新增需求管理表。其產品要求由下方 14 條 User Story 與新會議對照承接。 |
| [SCRUM-10](https://group5-vitail-project.atlassian.net/browse/SCRUM-10) | Who/Do/Be/Feel Requirement Table | Done | 訪談／需求文件；不新增表。角色與行為需求映射到 `User` 及各功能實體。 |
| [SCRUM-12](https://group5-vitail-project.atlassian.net/browse/SCRUM-12) | Create Github Repo | Done | 開發環境工作；不新增產品表。 |
| [SCRUM-17](https://group5-vitail-project.atlassian.net/browse/SCRUM-17) | Motivational model | Done | 分析文件；不新增表。動機會影響推薦、任務與點數政策，不另存一份使用者動機資料庫。 |
| [SCRUM-18](https://group5-vitail-project.atlassian.net/browse/SCRUM-18) | Determining the Tech Stack | Done | 技術選型；不新增業務表。影響 MySQL／Django、位置處理與部署方式。 |
| [SCRUM-19](https://group5-vitail-project.atlassian.net/browse/SCRUM-19) | StandUp Notes | To Do | 專案會議紀錄；留在協作文件，不新增 `Meeting` 表。 |
| [SCRUM-20](https://group5-vitail-project.atlassian.net/browse/SCRUM-20) | Development Minimium Viable Product | To Do | MVP Epic；不建立 Epic 表。彙總 `User`、`Dog`、`Walk`、`PointEntry`、`Venue`、`Reward`、`Redemption` 等子項需求。 |
| [SCRUM-21](https://group5-vitail-project.atlassian.net/browse/SCRUM-21) | Full Development | To Do | 後續開發 Epic；不建立 Epic 表。涵蓋任務、打卡、社交與 UI；以具體功能列為資料來源。 |
| [SCRUM-22](https://group5-vitail-project.atlassian.net/browse/SCRUM-22) | Project Documentation | To Do | 文件 Epic；不新增產品表。 |
| [SCRUM-23](https://group5-vitail-project.atlassian.net/browse/SCRUM-23) | Project Deliverables | To Do | 交付管理 Epic；不新增產品表。 |
| [SCRUM-24](https://group5-vitail-project.atlassian.net/browse/SCRUM-24) | Use Case | Done | 使用案例文件；不新增表。由角色、持久狀態與交易流程支援；目前 Jira 描述空白，不補造其他需求。 |
| [SCRUM-25](https://group5-vitail-project.atlassian.net/browse/SCRUM-25) | Further Questions Requirement Clarification | Done | 需求澄清；不新增表。影響規則版本、限制與下方衝突解法。 |
| [SCRUM-26](https://group5-vitail-project.atlassian.net/browse/SCRUM-26) | Login Implementation | Done | `User` 管帳號、角色、停用；延後 `ExternalIdentity` 支援 Apple 身分連結。密碼重設／刪帳仍要支援，不能把 Google 登入當成目前範圍。 |
| [SCRUM-27](https://group5-vitail-project.atlassian.net/browse/SCRUM-27) | User Story | Done | User Story 文件本身不新增表；下方 US-01～US-14 完整映射其產品要求。 |
| [SCRUM-28](https://group5-vitail-project.atlassian.net/browse/SCRUM-28) | Progress Report | Done | 報告與連結彙整；不新增產品表。 |
| [SCRUM-29](https://group5-vitail-project.atlassian.net/browse/SCRUM-29) | Track Dog Walk | Done | `Walk`、`WalkDog` 保存已驗證摘要及參與狗；`WalkSession`、短期 `LocationSample` 支援即時走路與社交。分開實際活動時間、暫停與距離；原始路線保存期限另定。 |
| [SCRUM-30](https://group5-vitail-project.atlassian.net/browse/SCRUM-30) | Manage Dog Profile | Done | `Dog`、`Breed`；真實生日、照片、品種／體型／短吻因素、可稍後補的晶片資料。`DogDailyGoal` 保存每日目標及計算依據。 |
| [SCRUM-31](https://group5-vitail-project.atlassian.net/browse/SCRUM-31) | Order Page | Done | `Redemption` 是訂單／收據來源；保存訂單編號、品項／店家／價格快照及狀態。`PointEntry` 管扣點與退款，`CafeOrderFeedState` 支援店家同步；不另造另一套 Order。 |
| [SCRUM-32](https://group5-vitail-project.atlassian.net/browse/SCRUM-32) | Redeem Rewards Page | Done | `Venue`、`Reward` 顯示店家及品項；`Redemption`、`PointEntry` 支援購買、履約、到期退款及歷史。兌換前狗資料完整性是伺服器資格檢查。 |
| [SCRUM-33](https://group5-vitail-project.atlassian.net/browse/SCRUM-33) | Cafe Management Page | Done | `User` 的 CAFE 角色管理自己的 `Venue`、`Reward`；`Redemption` 與 `CafeOrderFeedState` 供訂單更新。5 秒刷新是同步策略，不是新的表；畫面已移除更新時間列。 |
| [SCRUM-34](https://group5-vitail-project.atlassian.net/browse/SCRUM-34) | Database Setup | Done | 資料庫、migration、索引與交易設定；不新增「DatabaseSetup」業務表。主設計需保留舊錢包與訂單，採增加式遷移。 |
| [SCRUM-35](https://group5-vitail-project.atlassian.net/browse/SCRUM-35) | review & merge usecase | Done | 文件／程式審查流程；不新增產品表。 |
| [SCRUM-36](https://group5-vitail-project.atlassian.net/browse/SCRUM-36) | Seeking Suggestion on Built Product | In Progress | 收集回饋；不新增表。已確認的改動再映射到具體功能，不將所有意見自動變成需求。 |
| [SCRUM-37](https://group5-vitail-project.atlassian.net/browse/SCRUM-37) | Identify Front End Problem and Polish | In Progress | UI 調整；使用既有 `User`／`Dog`／`Venue` 照片與活動資料。展開、捲動、彈窗、配色本身不新增表。 |
| [SCRUM-38](https://group5-vitail-project.atlassian.net/browse/SCRUM-38) | Update Documentation for Last Sprint and Code Implementation | In Review | 文件維護；不新增產品表。 |
| [SCRUM-40](https://group5-vitail-project.atlassian.net/browse/SCRUM-40) | Create App Icons and Decide Brand Image | Done | 靜態品牌素材；不新增表。可選虛擬頭貼以 `User` 的素材代碼表示，圖檔不逐筆存在關聯式資料庫。 |
| [SCRUM-41](https://group5-vitail-project.atlassian.net/browse/SCRUM-41) | Test Current MVP and Resolve Identified Bugs | In Review | 測試／修正工作；測試資料與結果不成為產品業務表。資料一致性測試需涵蓋重試、並行扣點／領點、角色隔離及日期界線。 |
| [SCRUM-42](https://group5-vitail-project.atlassian.net/browse/SCRUM-42) | Venue check-in | To Do | 打卡 Epic；具體資料與 SCRUM-43 共用 `Venue`、`CheckIn`、`LocationSample`、`PointEntry`，不重複建兩套。 |
| [SCRUM-43](https://group5-vitail-project.atlassian.net/browse/SCRUM-43) | Venue check-in | To Do | `Venue` 保存類別／座標；`CheckIn` 保存半徑／停留門檻的政策快照、有效秒數、日額度與領取狀態；短期 `LocationSample` 供驗證；唯一的 `CheckIn.point_entry_id` 直接連到 `PointEntry`，防重複發點。 |
| [SCRUM-44](https://group5-vitail-project.atlassian.net/browse/SCRUM-44) | Task system | To Do | `QuestDefinition` 為目錄；生日／目標／streak 用 `QuestAward`，打卡用 `CheckIn`，文件用 `DocumentEntitlement`、`DocumentSubmission`、`EvidenceFingerprint`。任務頁由資格與事實資料投影；不把每次 UI 顯示另外寫成進度。 |
| [SCRUM-45](https://group5-vitail-project.atlassian.net/browse/SCRUM-45) | Daily goals & rewards | To Do | `DogDailyGoal`＋`Walk`／`WalkDog` 判斷每日達標；`QuestAward`＋`PointEntry` 保存每日與連續天數獎勵。Jira 的 15 分鐘是例子，不能取代尚待確認的個人化公式。 |
| [SCRUM-46](https://group5-vitail-project.atlassian.net/browse/SCRUM-46) | Statistics & leaderboard | To Do | 以 `Friendship`、`UserBlock` 篩選可見對象，從 `Walk`、`DogDailyGoal`、`QuestAward` 彙總距離／活動／7 日進度；不建固定排名表。完整產品設計保留，這次實作由隊友負責。 |
| [SCRUM-47](https://group5-vitail-project.atlassian.net/browse/SCRUM-47) | Friends system, show friends location on map | To Do | `Friendship`、`UserBlock`、`User` 可見性／頭貼設定；`WalkSession`、`LocationSample` 顯示有權限且未過期的位置。`NetWalkInterval` 計同行資格，不要求先成為好友。 |
| [SCRUM-48](https://group5-vitail-project.atlassian.net/browse/SCRUM-48) | UI & sharing | To Do | UI／使用者主動分享使用現有摘要與照片；預設不含精確路線／住家。不必先新增 Sharing 表；需要長期公開分享連結時再另定資料與撤銷機制。 |
| [SCRUM-49](https://group5-vitail-project.atlassian.net/browse/SCRUM-49) | Client Meeting | In Review | 會議紀錄本身不新增表；新增功能與政策由下方會議對照承接。 |

## 14 條 User Story 的逐項對照

US 編號只是這份覆蓋表的索引，不是新增 Jira key。來源均為上述 User Story 頁面；保留原優先級，但新決定可取代舊驗收條件。

| 索引／來源標題 | 資料需求 | 邊界與被取代的條件 |
|---|---|---|
| US-01 Account and Sign-in（Must） | `User`；延後 `ExternalIdentity`；帳號停用／刪除、身分供應者 subject 唯一性；稽核沿用 `LogEntry`。 | 舊 Android＋Google／Apple 改以 iOS 決定為準。R36／R40：目前 email/password，Apple 延後，Google 不在目前範圍。失敗／取消登入不能產生有效 session；刪帳需確認，歷史交易不能任意 cascade 刪除。 |
| US-02 Dog Profile and Daily Goal（Must） | `Dog`、`Breed`、`DogDailyGoal`；目標保存日別、規則版本、使用因素與達成證據；每日入帳連到 `QuestAward`／`PointEntry`。 | 原一狗限制已改；現行 R32 為最多 10 隻。v3 目標獎勵 20/day 已知，個人化時間公式與資格仍待定；未知目標不可當 0%。 |
| US-03 Track a Walk with GPS（Must） | `WalkSession`、短期 `LocationSample`、`Walk`、`WalkDog`；開始／暫停／結束、驗證後距離與有效活動時間、參與狗及重試識別。 | 30m 精度門檻、速度檢查、5 分鐘停滯／登出結束保留。伺服器長期路線保留尚未定案，不能把「畫面有路線」當成永久儲存授權。 |
| US-04 Earn and View Points（Must） | `PointEntry` 唯一帳本與到期批次；`Walk`、`DogDailyGoal`、`QuestAward` 提供來源／版本／去重依據。 | 8/km、40/day、目標 20/day、12 個月到期；新 72 cap 應依最新範圍分來源計算。多狗參與不能把同一帳戶走路距離倍增。 |
| US-05 Check In at a Place（Must） | `Venue`、`CheckIn`、`LocationSample`；保存有效停留、暫離／續接、政策快照及計分日期，以唯一的 `CheckIn.point_entry_id` 直接連到 `PointEntry`。 | v3 的 20m 與四類停留時間優先；舊「每個地點一次」與新四個每日機會須明確對應，不能靠多建店家繞過額度。未完成不罰點；同日續接規則要保存可判斷狀態。 |
| US-06 Vet and Registration Proof（Should） | `DocumentSubmission` 保存私人檔案／號碼與版本；`DocumentEntitlement` 固定資格期間；`EvidenceFingerprint` 防相同證據重複；`PointEntry` 實際入帳。 | 舊「事前核准／每年 council」已被取代：目前自述證據、稍後抽查；council 每狗一生一次，microchip 每登記期間一次；提交 READY，再 Collect。 |
| US-07 Use Points for Rewards（Must） | `Venue`、`Reward`、`Redemption`、`PointEntry`；有效商品、條款／價格快照、唯一訂單號、原子扣點與退款。 | 舊 swipe 才扣點，已由 R15／R47 改成 Purchase 扣點、swipe 只確認已取餐。不可兩次扣點；商品失效、餘額不足或交易失敗不留半套訂單。 |
| US-08 History and Charity Donations（Should） | `Redemption`、`PointEntry` 提供收據／歷史；延後 `Charity`、`Donation` 保存核准慈善機構、使用者確認、點數扣除與可查參考號。 | 慈善需求保留在完整設計，但合作機構、資金流及操作規則未定。捐點不是 app 內刷卡付款，不預先建 payment／settlement 系統。 |
| US-09 Recommendations and Streaks（Should） | 推薦由 `Venue`／`QuestDefinition` 與近期事實資料查詢；`DogDailyGoal`／`Walk` 形成合格日；`QuestAward` 保存 streak 段與 milestone，連到 `PointEntry`。 | 不需要一套推薦任務庫。30／60／90…重複獎勵依 v3；7 日重複範圍、合格日判定仍需明確。任務可以忽略，不能把推薦記成強制指派。 |
| US-10 Notifications（Should） | `User` 存通知偏好／安靜時段；延後 `PushDevice`、`NotificationDelivery` 管裝置、投遞與去重。 | 通知種類／頻率未完全定案；不要把定位或文件個資放在鎖定畫面，也不因一項任務重試就重複發送。 |
| US-11 Photos, Sharing and Walking Together（Could） | `User`／`Dog`／`Venue` 照片或素材代碼；`Friendship`、`UserBlock`、`WalkSession`、`LocationSample` 管可見性；`NetWalkInterval` 保存同行證據，區段取聯集後結算到 `Walk`，以唯一的 `Walk.net_point_entry_id` 連到 `PointEntry`。 | 照片／對外分享由使用者選擇；不預設分享精確住家／路線。新會議提高社交優先度；Net-Walking 不要求先好友，但不等於未同意即可公開彼此位置。 |
| US-12 Manage Merchants and Offers（Must） | `User`、`Venue`、`Reward`、`Redemption`；`LogEntry` 記錄價格／狀態變更；停用代替刪除既有訂單依賴。 | 舊「商家沒有自己的管理頁」已被新會議及 R43 取代：Admin 建立 café 帳號，café 管理自己的商品；仍不能任意更改角色或接管別人的店。 |
| US-13 Review User Proof（Should） | 原始 `DocumentSubmission` 與 `EvidenceFingerprint` 保留；後續抽查與處置理由記在既有 `LogEntry`，若調整點數以新 `PointEntry` 表達。 | 舊「approve 才發點、reject 不發」不再是現行流程。不要為舊流程增加必經 pending-review gate；抽查結果及撤銷規則仍須定義。 |
| US-14 Review Transactions and Possible Misuse（Should） | `Redemption` 依參考號查詢；`PointEntry`、`QuestAward` 追溯來源；短期 `LocationSample`／`NetWalkInterval` 作證據；`User` 停用狀態與 `LogEntry` 操作者／理由。 | 一次差 GPS 不自動封鎖。管理員變更、補點、警告與停用應留理由，不能靠直接覆寫已完成交易修正歷史。 |

## 最新會議與後續決定的補充覆蓋

這部分補上舊 User Story 沒有充分描述的需求，也保留仍未定案的限制。

| 最新需求／方向 | 資料設計落點 | 已知規則／仍需確認 |
|---|---|---|
| 地圖亮點、Start 後停留、達標 Collect | `Venue`、`CheckIn`、`LocationSample`；唯一的 `CheckIn.point_entry_id` 直接連到 `PointEntry` | 店家地址／Maps 不足以驗證打卡；Venue 存座標，版本化類別政策的半徑／時長固定在 CheckIn 快照。沒有手動 Finish 才算完成的額外要求。GPS 引擎由其他隊友負責，不新增假資料替代。 |
| 四種每日場地機會與 72 上限 | `Venue.kind`、`CheckIn` 的日期／類別及 `PointEntry.earn_category`／`earned_on` | 現行 UI 最多四個機會；未滿 Walk＋Check-in 72 都可看，滿額隱藏未領項目。生日／文件及現有錢包餘額不能用來推算該額度。 |
| 簡潔 Quest 列表與跨頁一致領取 | `QuestDefinition` 目錄；生日／目標／streak 用 `QuestAward`，打卡與文件各自用 `CheckIn`／`DocumentEntitlement` | READY 優先、IN_PROGRESS 其次、當日 COLLECTED 最後；隔 Melbourne 午夜只從主列表移除，不能刪除獎勵／文件歷史。每日目標與 streak 未開放時不捏造可領任務。 |
| 文件先提交、再明確領點 | `DocumentEntitlement`、`DocumentSubmission`、`EvidenceFingerprint`、`PointEntry` | 提交 0 點並保留資格；Collect 一次入帳。重傳不增加資格；pending 也占用限額；舊已發點記錄遷移後保持 COLLECTED，不能再次發點。 |
| 真實生日與 60 點生日獎勵 | `Dog.date_of_birth`、`QuestAward`、`PointEntry` | 每狗每年一次；換主人不能重領。舊 age-only 資料不可猜生日。2/29 非閏年採哪一天，尚待定案。 |
| 每狗每日目標與帳戶獎勵 | `DogDailyGoal`、`WalkDog`、`QuestAward` | 保存輸入因素、目標、驗證後進度、政策版本。R31 目前是當日參與狗都達標才發帳戶一次獎勵；v3 確認 20/day，沒有提供精確目標公式。 |
| 連續天數與 7 日進度 | `Walk`／`DogDailyGoal` 的日期事實、`QuestAward` milestone | 30/60/90…獎勵可重複；不能把「走了任何距離」永久等同「完成當日個人化目標」，需選定合格日定義。 |
| 朋友名單、搜尋、位置與虛擬頭貼 | `User`、`Friendship`、`UserBlock`、`WalkSession`、`LocationSample` | 帳戶 ID／公開搜尋名稱、邀請與同意、分享開關、位置過期時間需明確。虛擬頭貼先用固定素材代碼，沒有必要建頭貼商城。 |
| Net-Walking 不要求好友 | `WalkSession`、`LocationSample`、`NetWalkInterval`；結算到 `Walk` 的同行距離及唯一 `net_point_entry_id` | GPS 判斷同行；2/km、10/day。同一使用者與多位同行的有效時間區段取聯集，再計算本人的距離，不按朋友數倍增。定位驗證完成後一次結算入 `PointEntry`；距離、持續時間、定位採樣與同意流程仍需定義。 |
| 好友 stats／leaderboard | 讀取 `Friendship`、`UserBlock`、`Walk`、`DogDailyGoal`、`QuestAward` 的彙總 | 全產品仍涵蓋 SCRUM-46；R54 是交付分工與移除本次頁面，不是把資料需求刪掉。排名指標與週期尚未完整定案，不用錢包餘額排名。 |
| 簡單聊天與提醒朋友散步 | 延後 `ChatMessage`；通知使用 `PushDevice`、`NotificationDelivery` | 會議 closing recap 提到，不只是假設；但訊息保留、已讀／封鎖、發送頻率與通知偏好仍未定。先不建群組、頻道或推播行銷系統。 |
| 晶片資料可跳過 onboarding、兌換前需補 | `Dog` 晶片欄位、`DocumentSubmission`／`DocumentEntitlement` | 晶片號碼、microchip registration certificate、council registration 是不同資料。15 位及以 9 開頭尚未確認；不要硬寫進資料庫限制。多狗兌換檢查哪一隻仍需定義。 |
| Café 被列出本身有曝光價值 | `Venue`、管理者 `User`、`Reward` | 支援非商家帳號的公園／地點；店家公開資料集中在 `Venue`，不能把 `CafeProfile` 複製成第二份真相。 |
| Admin onboarding、café 自管品項 | `User`、`Venue`、`Reward`、`CafeOrderFeedState`、`LogEntry` | 保留單一 app 內不同角色、自己的店／商品權限；沒有確認多分店／員工群組時不先增加複雜組織權限表。 |
| Puppuccino、最低消費條件、暫不做金流 | `Reward` 條款／點價、`Redemption` 條款與價格快照 | v3 建議 treat 約 72、咖啡約 504，Phase 1 先 Puppuccino。這不是固定現金匯率；最低消費金額／核對方式由合作條件定，不建立刷卡／結算表。 |
| 簡單取餐、照片與訂單號 | `Redemption`、`Reward`、`Venue`、狗照片／歷史資訊 | 不強制店員掃碼；購入即扣點，滑動只標記領取。店員看到的狗照片是視覺參考，不是已完成狗在場驗證的證據。 |
| 位置反作弊優先 | `LocationSample`、`Walk`、`CheckIn`、`NetWalkInterval`；稽核 `LogEntry` | 排除不合理速度／模擬資料並保留必要驗證結果；不把偵測結果直接當封鎖決定。位置保存期限、可見對象與刪除程序仍需定案。 |
| 天氣降為較低優先 | `DogDailyGoal` 的計算依據／規則版本 | 供應者、溫度門檻及季節替代公式都尚未確認；不用先增加長期 Weather 表。 |
| 分享與 playful 視覺、新 icon | 靜態資源、`User` 素材代碼、既有活動摘要 | 新圖示、配色、light/dark、動畫／排版不需要新業務表。分享預設減少精確位置暴露；沒有確認公開 feed。 |
| 常駐伺服器、Australian-region 資料、demo 發布 | 部署／保存政策；既有資料庫與私人檔案儲存 | 不新增「Hosting」表。會議中的費用、1,000 人例子與維護一年不是已驗證容量或合約；本次未授權購買開發者帳號或部署。 |

## 點數表 v3 的每列追溯

全部獎勵仍進同一個 `PointEntry`；資格來源、規則版本、業務期間／日期及去重鍵由其來源實體保存。以下是需求覆蓋，不代表每一列目前都已啟用。

| v3 項目 | 定案數值／限制 | 資料來源 |
|---|---|---|
| Walk | 8/km；40/day | `Walk`、`WalkDog`、`PointEntry`；保留每日計算與伺服器驗證。 |
| Net-Walking | 額外 2/km；10/day | `NetWalkInterval`、`WalkSession`；有效時間區段取聯集後結算每人的 `Walk.net_distance_m`，由唯一 `Walk.net_point_entry_id` 直接連到 `PointEntry`。 |
| Hitting daily exercise time | 20；20/day | `DogDailyGoal`、`QuestAward`；獎勵已定，目標公式未定。 |
| Venue／café check-in | 20m、10 分鐘；12；該列 12/day | `Venue` 的類別／座標、`CheckIn` 的政策快照／進度；唯一的 `CheckIn.point_entry_id` 直接連到 `PointEntry`。 |
| Restaurant check-in | 20m、20 分鐘；12；該列 12/day | 同上，以類別及日期限制。 |
| Park check-in | 20m、5 分鐘；12；該列 12/day | 同上；不能把新增多個公園當成增加每日類別額度。 |
| Vet check-in | 20m、3 分鐘；12；該列 12/day | 同上；與 vet checkup 文件獎勵分開。 |
| 7-day streak | 達 7 日給 20 | `QuestAward` 記 streak 段／milestone；新 streak 能否再次領 7 日獎勵仍需明確。 |
| 30-day streak | 30、60、90…日各 100 | `QuestAward` 使用段＋milestone 唯一性，不能仍寫成終身只發一次。 |
| Vet checkup | 200；2/year，至少間隔 60 日 | `DocumentEntitlement` 的實際事件日；目前按事件曆年，間隔跨年照算。 |
| Council registration | 300；one time reward | 每狗 lifetime entitlement；不按年重置。 |
| Microchip registration certificate | 300；每個一年登記期間一次 | 每狗明確年度期間的 entitlement；重疊／同期間文件不重領。 |
| Dog's birthday | 60；每年一次 | `Dog.date_of_birth`、每狗／年份唯一 `QuestAward`。 |

v3 的總上限文字是 **Walk＋Check-in 合計 72/day**，不是所有入帳總和或錢包餘額。Net-Walking 與 goal 在表中分列；它們與 72 的精確分類要在政策中明寫，不沿用舊表「Walk＋goal＋check-in」的推論。來源欄位應能區分這些類型，即使某項規則尚未啟用也不用重寫舊帳本。

## 明確衝突與設計處理

| 衝突 | 本次採用／保留的界線 |
|---|---|
| 舊一狗／最多兩狗、每狗各自賺點 vs 現行多狗 | 依 [DECISIONS R31/R32](../DECISIONS.md)，目前最多 10 隻；普通 walk 仍按帳戶有效距離計分，每狗文件／生日資格分開。不能因選兩隻狗就複製 walk 點數。這是明確版本衝突，不把舊頁誤稱已更新。 |
| 目標獎勵是否有定案 | v3 有 20/day；不能再寫「獎勵金額未定」。但目標公式、驗證活動時間與達標資格仍未定，不能拿 Jira 15 分鐘例子直接實作。 |
| R31 全部當日參與狗達標 vs Jira 泛稱每日任務 | 保留 R31 每帳戶一次的既有決定；`DogDailyGoal` 能逐狗追蹤。若 client 要改成每狗 20，須重新確認，不能只更改 UI 就暗中倍增發點。 |
| 舊 72 包含 goal vs v3 Walk＋Check-in | 以 v3 範圍文字為新政策基礎；明列各來源分類與上限，不拿全部正點數或餘額計算。Net／goal 邊界需一個清楚、可測的決定。 |
| 舊每店一次 vs 新四機會、每類 12/day | 依最新顯示規則保留最多四個每日機會；類別與來源日期必須入資格鍵。選哪一家代表該類、重新進入與跨午夜歸日由 check-in 規格補齊。 |
| 舊 council 每年 300 vs v3 one time | 每狗一次；年度文件更新不再新增 council 點數。年度 microchip 是另一種 entitlement，不能混名。 |
| 舊 30 日一次 vs v3 30/60/90… | 30 日倍數可持續發；保存 streak 段與 milestone 去重。7 日重啟後是否可再領仍不能猜。 |
| 舊文件 approve 才發點 vs 後續 self-reported | 不做強制事前審核 gate；保留私人證據及後續抽查紀錄。抽查不能把原文件覆寫成不存在。 |
| R53 文件提交即入帳 vs R55 明確 Collect | R55 優先：提交保留 READY，Collect 才入帳；pending 占額度，重複 Collect 回既有結果。遷移前已發點必須標為已領，不能重新開放。 |
| 舊 swipe 扣點 vs 現行 Purchase 扣點 | 購買時原子扣點，取餐滑動只更新 `Redemption`；過期退款用新帳目，不能重複扣／退。 |
| 舊咖啡約 60 vs v3 treat 約 72／coffee 約 504 | 新點數表優先作為設計方向；實際 `Reward.point_cost` 仍是店家設定並留訂單快照，不追溯改價或按匯率重算舊餘額。 |
| 舊商家只聯絡 Admin vs 新 café 自管商品 | Admin onboarding 保留；café 可管自己的店與商品，資料來源集中到 `Venue`／`Reward`，不建另一套 merchant catalogue。 |
| 舊 Android／Google vs iOS／Apple 延後 | R35/R36/R40 優先：現有 iOS＋email/password，Apple 用延後 `ExternalIdentity` 支援；Google 不在目前 scope。平台改變不另建一份帳戶資料庫。 |
| 舊 Net-Walking nice-to-have vs 09/24 社交工作方向 | 完整設計涵蓋 Net-Walking／friends；資格不綁 friendship。即時位置公開仍需同意與封鎖規則，不等於所有鄰近人都可看。 |
| SCRUM-46 要 leaderboard vs R54 移除本次頁面 | 資料設計保留好友 stats 的完整需求；移除的是本次實作與分工，不把 Jira 當作取消，也不宣稱已完成。 |

## 仍不能從「已覆蓋」推導成「可直接實作」的項目

- 個人化每日運動時間公式、短吻／年齡／體型／熱風險調整、有效活動秒數驗證與 streak 合格日。
- 每日上限的來源分類、剩餘額度不足 12 時是否部分發點、check-in 重入／跨午夜／背景定位與 20m 的精度要求。
- Net-Walking 的距離、最短同行時間、取樣／失聯門檻、同意／公開位置規則；leaderboard 分數與時間範圍。
- 晶片號碼格式、兌換需要哪隻狗／哪些證據、年度 microchip 用實際登記期間還是固定曆年、2/29 生日替代日。
- 文件與位置保存期限、後續抽查處理及點數調整程序、刪帳後個資與必要交易歷史的界線。
- 聊天、推播、慈善、Apple 登入等延後項目的操作規格；目前不因此增加 payment、社群 feed 或更多泛用表。

因此，這份文件的結論是：**37 筆 Jira、14 條舊 User Story，以及已讀會議／點數表的需求都有資料設計落點或明確的「不需表」分類；仍有政策待定，不等於 28 張表現在全部要建立，也不等於所有功能已可交付。**
