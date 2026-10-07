# Vitail 需求與現況覆蓋表

2026-10-07。對照本分支實際 23 張業務模型表及六張尚未建立的後續表；功能完成程度獨立標註，不能由資料表或 Jira 狀態推論。

## 覆蓋範圍與來源優先順序

本次來源快照的 Jira 查詢為 `project = SCRUM ORDER BY key ASC`，回傳 **37 筆，`isLast=true`**；下表逐筆列出，包含文件、範例與其他非產品工作。Jira 的 `Done`／`To Do` 等狀態照來源記錄，**不等於本文件已驗證該功能的實作狀態**。

另逐項覆蓋 [User Story](https://group5-vitail-project.atlassian.net/wiki/pages/viewpage.action?pageId=10518529) 的 **14 條需求**，以及 09/24 會議與後續使用者決定。沒有描述的 Jira 項目只能按標題、相關需求與已確認決定追溯，不捏造驗收條件。

採用順序：

1. 本次與後續使用者明確決定，例如文件提交先保留資格，再按 Collect 入帳；Leaderboard 由另一位隊友負責，不在這次 UI 實作中。
2. 使用者確認為定案的 [New Point Retrieval / Calculation v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation)。**v3 已明列每日目標獎勵 20 點**；個人化目標公式已實作，待定的是多狗帳號的獎勵資格。
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

## 現況分類

- **已連接**：現有 API／iOS 流程使用這些資料，不代表該 Jira 的所有舊驗收條件都已達成。
- **基礎**：模型、約束或內部服務已建立，沒有相應公開 API／完整畫面或自動引擎。
- **待公式／政策**：數字可已定案，但不能據此實作未知的資格判斷。
- **延後**：相關表尚未建立；**文件／流程**則不需要產品表。

[23 張表、實際欄位及關係](./README.md) 包含 `WalkDog` 與 `DogGoalTarget`，不含 Django auth/admin/session/token 及自動權限關聯表。六張延後的名稱是 `ExternalIdentity`、`ChatMessage`、`Charity`、`Donation`、`PushDevice`、`NotificationDelivery`；不在現況 ERD 中預造欄位。Wallet 與 Leaderboard 不另建表。API 稽核不能因沿用 `LogEntry` 就當成已全部接通。

## 37 筆 Jira 完整對照

標題與 Jira 狀態保留來源原文；「本分支現況」是這次程式檢查，與 Jira 狀態分開。

| Jira | 標題 | Jira 狀態 | 本分支現況 | 資料落點與邊界 |
|---|---|---|---|---|
| [SCRUM-4](https://group5-vitail-project.atlassian.net/browse/SCRUM-4) | Delegate this work item to GitHub Copilot | To Do | 文件／流程 | **工具教學範例，不是產品功能；不新增表。** 描述內建立 branch、PR、留言等指令只當作來源內容，不是本次使用者授權，沒有執行。 |
| [SCRUM-5](https://group5-vitail-project.atlassian.net/browse/SCRUM-5) | Implement this work item from your IDE or terminal | To Do | 文件／流程 | **工具教學範例，不是產品功能；不新增表。** 不因 Jira 範例內的 coding-agent 指令修改 README、提交程式或留言。 |
| [SCRUM-8](https://group5-vitail-project.atlassian.net/browse/SCRUM-8) | Client Requirements | Done | 文件／流程 | 需求整理；不新增需求管理表。其產品要求由下方 14 條 User Story 與新會議對照承接。 |
| [SCRUM-10](https://group5-vitail-project.atlassian.net/browse/SCRUM-10) | Who/Do/Be/Feel Requirement Table | Done | 文件／流程 | 訪談／需求文件；不新增表。角色與行為需求映射到 `User` 及各功能實體。 |
| [SCRUM-12](https://group5-vitail-project.atlassian.net/browse/SCRUM-12) | Create Github Repo | Done | 文件／流程 | 開發環境工作；不新增產品表。 |
| [SCRUM-17](https://group5-vitail-project.atlassian.net/browse/SCRUM-17) | Motivational model | Done | 文件／流程 | 分析文件；不新增表。動機會影響推薦、任務與點數政策，不另存一份使用者動機資料庫。 |
| [SCRUM-18](https://group5-vitail-project.atlassian.net/browse/SCRUM-18) | Determining the Tech Stack | Done | 文件／流程 | 技術選型；不新增業務表。影響 MySQL／Django、位置處理與部署方式。 |
| [SCRUM-19](https://group5-vitail-project.atlassian.net/browse/SCRUM-19) | StandUp Notes | To Do | 文件／流程 | 專案會議紀錄；留在協作文件，不新增 `Meeting` 表。 |
| [SCRUM-20](https://group5-vitail-project.atlassian.net/browse/SCRUM-20) | Development Minimium Viable Product | To Do | 文件／流程 | MVP Epic；不建立 Epic 表。彙總 `User`、`Dog`、`Walk`、`PointEntry`、`Venue`、`Reward`、`Redemption` 等子項需求。 |
| [SCRUM-21](https://group5-vitail-project.atlassian.net/browse/SCRUM-21) | Full Development | To Do | 文件／流程 | 後續開發 Epic；不建立 Epic 表。涵蓋任務、打卡、社交與 UI；以具體功能列為資料來源。 |
| [SCRUM-22](https://group5-vitail-project.atlassian.net/browse/SCRUM-22) | Project Documentation | To Do | 文件／流程 | 文件 Epic；不新增產品表。 |
| [SCRUM-23](https://group5-vitail-project.atlassian.net/browse/SCRUM-23) | Project Deliverables | To Do | 文件／流程 | 交付管理 Epic；不新增產品表。 |
| [SCRUM-24](https://group5-vitail-project.atlassian.net/browse/SCRUM-24) | Use Case | Done | 文件／流程 | 使用案例文件；不新增表。由角色、持久狀態與交易流程支援；目前 Jira 描述空白，不補造其他需求。 |
| [SCRUM-25](https://group5-vitail-project.atlassian.net/browse/SCRUM-25) | Further Questions Requirement Clarification | Done | 文件／流程 | 需求澄清；不新增表。影響規則版本、限制與下方衝突解法。 |
| [SCRUM-26](https://group5-vitail-project.atlassian.net/browse/SCRUM-26) | Login Implementation | Done | 已連接＋延後 | `User`：email/password、角色、頭貼、JWT；`auth_version` 失效檢查已接通。完整密碼重設／刪帳尚未完成；Apple 的 `ExternalIdentity` 未建立，Google 非目前範圍。 |
| [SCRUM-27](https://group5-vitail-project.atlassian.net/browse/SCRUM-27) | User Story | Done | 文件／流程 | User Story 文件本身不新增表；下方 US-01～US-14 完整映射其產品要求。 |
| [SCRUM-28](https://group5-vitail-project.atlassian.net/browse/SCRUM-28) | Progress Report | Done | 文件／流程 | 報告與連結彙整；不新增產品表。 |
| [SCRUM-29](https://group5-vitail-project.atlassian.net/browse/SCRUM-29) | Track Dog Walk | Done | 已連接＋基礎 | `Walk`、`WalkDog` 保存 Finish 後驗證摘要與狗參與；手機保留暫停／復原流程。`WalkSession`、`LocationSample` 是基礎，現行上傳不寫這兩表，沒有持續 GPS API。 |
| [SCRUM-30](https://group5-vitail-project.atlassian.net/browse/SCRUM-30) | Manage Dog Profile | Done | 已連接 | `Dog`、`Breed` 的照片、真實生日、體重及 profile 已連接；Dog Profile 可預覽並設定個人化每日散步目標。晶片／archive 欄位是基礎。 |
| [SCRUM-31](https://group5-vitail-project.atlassian.net/browse/SCRUM-31) | Order Page | Done | 已連接 | `Redemption` 是單商品訂單／收據；`PointEntry` 處理扣點退款，`CafeOrderFeedState` 支援同步，沒有第二套 Order。 |
| [SCRUM-32](https://group5-vitail-project.atlassian.net/browse/SCRUM-32) | Redeem Rewards Page | Done | 已連接＋待政策 | `Venue`、`Reward`、`Redemption`、`PointEntry` 支援菜單、購買／取餐／退款。晶片號碼格式與需檢查哪隻狗尚未定案，沒有完整兌換 gate。 |
| [SCRUM-33](https://group5-vitail-project.atlassian.net/browse/SCRUM-33) | Cafe Management Page | Done | 已連接 | CAFE `User` 管自己的 `Venue`／`Reward`；訂單以購買時 café User 歸屬。公開地點照片與帳戶照片分離；輪詢不新增表。 |
| [SCRUM-34](https://group5-vitail-project.atlassian.net/browse/SCRUM-34) | Database Setup | Done | 已建立模型／migration | 23 張業務模型表；`Venue` 取代 `CafeProfile`，`WalkDog` 沿用既有 join 實體表，`DogGoalTarget` 保存生效日版本化目標。部署是否已套用 migration 另驗證。 |
| [SCRUM-35](https://group5-vitail-project.atlassian.net/browse/SCRUM-35) | review & merge usecase | Done | 文件／流程 | 文件／程式審查流程；不新增產品表。 |
| [SCRUM-36](https://group5-vitail-project.atlassian.net/browse/SCRUM-36) | Seeking Suggestion on Built Product | In Progress | 文件／流程 | 收集回饋；不新增表。已確認的改動再映射到具體功能，不將所有意見自動變成需求。 |
| [SCRUM-37](https://group5-vitail-project.atlassian.net/browse/SCRUM-37) | Identify Front End Problem and Polish | In Progress | 已連接 | 現有 UI 使用 `User`／`Dog`／`Venue` 照片及活動資料；展開、捲動、彈窗、System/Light/Dark 不新增表。 |
| [SCRUM-38](https://group5-vitail-project.atlassian.net/browse/SCRUM-38) | Update Documentation for Last Sprint and Code Implementation | In Review | 文件／流程 | 文件維護；不新增產品表。 |
| [SCRUM-40](https://group5-vitail-project.atlassian.net/browse/SCRUM-40) | Create App Icons and Decide Brand Image | Done | 已連接＋基礎 | App icon 為靜態資源；`User.virtual_avatar_key` 僅資料基礎，未接虛擬頭貼選擇器或商城。 |
| [SCRUM-41](https://group5-vitail-project.atlassian.net/browse/SCRUM-41) | Test Current MVP and Resolve Identified Bugs | In Review | 文件／流程 | 測試／修正工作；測試資料與結果不成為產品業務表。資料一致性測試需涵蓋重試、並行扣點／領點、角色隔離及日期界線。 |
| [SCRUM-42](https://group5-vitail-project.atlassian.net/browse/SCRUM-42) | Venue check-in | To Do | 已連接；實機驗收待完成 | 與 SCRUM-43 共用 `Venue`、`CheckIn`、`LocationSample`、`PointEntry`，不建立第二套打卡表；認證定位與 Collect 已連接。 |
| [SCRUM-43](https://group5-vitail-project.atlassian.net/browse/SCRUM-43) | Venue check-in | To Do | 已連接；實機驗收待完成 | `CheckIn` 保存類別／日期唯一 slot、attempt、圈域／時長快照、已驗證秒數及唯一 ledger FK。地圖、Core Location、認證 API 與共享 UI store 已接，仍需戶外／背景實機驗收。 |
| [SCRUM-44](https://group5-vitail-project.atlassian.net/browse/SCRUM-44) | Task system | To Do | 已連接＋基礎 | `QuestDefinition` 與任務投影；生日 `QuestAward`、文件三表及 Collect 已連接。Daily Goal 七日進度已連接但獎勵停用；Check-in 共用真實伺服器進度；streak 已用 Walk 驗證日期與 QuestAward 接通，不建立通用 QuestProgress。 |
| [SCRUM-45](https://group5-vitail-project.atlassian.net/browse/SCRUM-45) | Daily goals & rewards | To Do | 進度已連接＋待獎勵政策 | `DogGoalTarget`、`DogDailyGoal`、`WalkDog`、`QuestAward` 有資料落點；體重／品種活動量／年齡／短吻係數與飼主 50–200% 調整已接 Dog Profile、Quest 七日進度及有效散步累計。20/day 已定；多狗資格未定，因此未開放領點。 |
| [SCRUM-46](https://group5-vitail-project.atlassian.net/browse/SCRUM-46) | Statistics & leaderboard | To Do | 基礎＋待政策 | `Friendship`／`UserBlock` 可供未來篩選，`Walk`／`DogDailyGoal`／`QuestAward` 可供彙總。没有 leaderboard 表、API 或頁面；指標／週期與隊友整合待定。 |
| [SCRUM-47](https://group5-vitail-project.atlassian.net/browse/SCRUM-47) | Friends system, show friends location on map | To Do | 基礎 | 關係、封鎖及 User 分享偏好已建模；內部關係服務有鎖及同意判斷。沒有好友搜尋／位置共享 API；`WalkSession`／`LocationSample`／`NetWalkInterval` 尚未接 matching。 |
| [SCRUM-48](https://group5-vitail-project.atlassian.net/browse/SCRUM-48) | UI & sharing | To Do | UI 已連接；分享待整合 | 使用既有摘要與照片，不建 Sharing／Post 表。公開分享、位置脫敏及撤銷要求尚未形成完整流程。 |
| [SCRUM-49](https://group5-vitail-project.atlassian.net/browse/SCRUM-49) | Client Meeting | In Review | 文件／流程 | 會議紀錄本身不新增表；新增功能與政策由下方會議對照承接。 |

## 14 條 User Story 對照

索引與原優先級保留；來源是 [User Story](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/10518529/User+Story)，較新決定優先。

| 索引／來源標題 | 現況／資料落點 | 未完成或已取代的條件 |
|---|---|---|
| US-01 Account and Sign-in（Must） | 已連接：`User` 登入／角色；失效版本檢查。 | 完整刪帳／密碼重設未交付；Apple `ExternalIdentity` 延後。iOS＋email/password 取代舊 Android／Google 優先範圍。 |
| US-02 Dog Profile and Daily Goal（Must） | 已連接：`Dog`、`Breed`、`DogGoalTarget`、`DogDailyGoal`。 | 現行最多10狗；個人化公式、飼主調整、有效日版本與七日進度已接。20/day 已定，多狗獎勵資格待定。 |
| US-03 Track a Walk with GPS（Must） | 已連接：手機記錄／暫停／Finish、`Walk`、`WalkDog`驗證。 | server session／GPS樣本表是基礎，未接持續上傳；保留期限及分享同意未定。 |
| US-04 Earn and View Points（Must） | 已連接：`PointEntry` credit lot、到期、Walking來源及共享cap。 | Daily Goal 已納入 72 cap，但發點仍待多狗資格；Net 是否納入待定。多狗不倍增 Walking 點數。 |
| US-05 Check In at a Place（Must） | 已連接：`Venue`、`CheckIn`、`LocationSample`、Core Location 與 Collect。 | 戶外／背景實機驗收待完成；目前共享72cap，部分發點不開放。不能靠新增地點繞過每日四類限制。 |
| US-06 Vet and Registration Proof（Should） | 已連接：三個文件模型、私人檔案、READY→Collect。 | Council 每狗每實際有效期一次，Microchip 每狗終身一次；手填或 PDF／照片皆為 self-reported。舊事前核准已取代；完整抽查與處置服務未交付。 |
| US-07 Use Points for Rewards（Must） | 已連接：Venue菜單、Reward有效期／配額、Redemption與ledger。 | Purchase扣點，swipe只確認取餐，取代舊swipe扣點。店內購買條件可展示但未驗證現金消費。 |
| US-08 History and Charity Donations（Should） | 已連接：`Redemption`／`PointEntry`歷史；延後：`Charity`／`Donation`。 | 沒有捐點表或API；合作方、確認／退款／對帳規則待定，不預建支付結算系統。 |
| US-09 Recommendations and Streaks（Should） | 已連接：`DogGoalTarget` 個人化建議、`DogDailyGoal`、`QuestAward`。 | 沒有更廣泛的行為／天氣推薦引擎；streak 已接有效散步日、漏日歸零及每段7／30／60／90…領點，已達標未領資格保留。 |
| US-10 Notifications（Should） | 基礎：`User.notification_preferences`空JSON容器。 | 尚未定義完整偏好格式、安靜時段與投遞流程；`PushDevice`／`NotificationDelivery`未建立。 |
| US-11 Photos, Sharing and Walking Together（Could） | 已連接：人／狗／地點照片；基礎：關係、位置與Net區間。 | 沒有分享／matching／net發點流程。分享精確位置需明確同意；未來對區間取聯集，不能按人數倍增。 |
| US-12 Manage Merchants and Offers（Must） | 已連接：Admin建帳、café自管Venue／Reward及orders。 | 舊無店家管理頁已被取代；API改價未全面接LogEntry，多分店／員工權限未在範圍。 |
| US-13 Review User Proof（Should） | 已連接：文件原件與版本；基礎：audit／review、eligibility凍結欄位。 | 不是事前審核gate；完整抽查與追回服務未交付，沒有ADMIN_DEBIT，不改寫原ledger。 |
| US-14 Review Transactions and Possible Misuse（Should） | 已連接：訂單參考號、ledger與來源；基礎：位置證據、停用欄位。 | 目前不是完整警告／停權／調點稽核工作流；LogEntry不自動記錄所有API，單次GPS異常不等於封鎖理由。 |

## 09/24 會議與後續決定

| 方向 | 目前落點 | 仍未完成的部分 |
|---|---|---|
| Map／Quest 共用進度、最多四類打卡 | `CheckIn`、認證 API、Core Location、iOS共享store／detail | 戶外／背景實機驗收；不能靠本機倒數宣布達標。 |
| READY優先、當日COLLECTED置底 | Quest的真實生日／文件tasks及伺服器日期 | 過午夜從主列表隱藏，不刪歷史；未知goal不顯示placeholder；streak以單一進度條顯示真實天數。 |
| 文件提交與Collect分開 | 三個文件模型與私人存取 | pending占資格；抽查、爭議、追回政策待定。 |
| 生日、每狗目標、streak | Birthday60、個人化目標進度與streak已連接 | 不由舊age猜DOB；2/29目前只在實際日期領，替代日未定；daily goal 獎勵待多狗政策；streak按每日有效散步判定。 |
| 朋友、虛擬頭貼、即時位置 | canonical Friendship、directional UserBlock、User偏好、session位置expiry | 搜尋／頭貼選擇器／位置共享API未接。 |
| Net-Walking可與非好友同行 | `NetWalkInterval`保存兩人各自距離與consent時間 | 無自動matching／net award；距離、時窗及公開規則未定。 |
| 好友stats／leaderboard | 活動事實可供聚合，不建固定排名表 | SCRUM-46需求保留；本slice移除頁面，不代表功能被取消或已交付。 |
| 簡單聊天／nudge與遠端通知 | 六個延後名稱中的ChatMessage、PushDevice、NotificationDelivery | 沒有表／API；訊息保留、頻率、鎖定畫面內容與安靜時段待定。 |
| 晶片可稍後填、兌換前需補 | Dog晶片欄位；證明文件資格分開 | API gate與多狗選擇規則未接。文件 Quest 手填採15位數字、不限9開頭，其他格式可上傳證明；這不等於已實作兌換 gate。 |
| Café曝光、Admin onboarding、自管商品 | Venue取代CafeProfile；Reward.venue唯一歸屬 | 公園不需帳號；無多分店組織／支付平台。API `cafe_id`是User ID，`venue_id`才是地點。 |
| Puppuccino、最低消費、簡單取餐 | Reward條款／需店內購買旗標，Redemption價格／條款快照 | 咖啡提示504，實際商品價格不改；未驗證現金支付，顧客狗照片不證明狗在場。 |
| 位置反作弊 | Walk upload驗證及validation摘要；LocationSample是基礎 | 持續定位、raw GPS保留／清除與個資刪除政策未完成。 |
| 天氣與推薦 | DogGoalTarget.calculation_inputs 保存個人化公式輸入；DogDailyGoal 凍結每日結果 | 個人化運動目標已連接；沒有天氣供應者或更廣泛推薦引擎，不建 Weather 歷史表。 |
| Playful視覺、分享、icon | 靜態資源與既有照片／活動 | 不因動畫／配色建表；對外分享與精確位置處理仍需驗收。 |
| Australian-region、常駐服務與demo | 部署政策；DB及private storage | 不是新增Hosting表；資料區域、容量、保存及維護承諾需部署驗證。 |

## 點數表每列的資料落點

數值、日額度與完整政策集中於 [QUESTS.md](../QUESTS.md)，待定事項集中於 [DECISIONS.md](../DECISIONS.md)。此表區分實作狀態，不另維護一份容易分歧的點數表。

| v3項目 | 資料來源 | 現況 |
|---|---|---|
| Walk | Walk／WalkDog → PointEntry | 已連接，帳戶距離計分。 |
| Net-Walking | NetWalkInterval、WalkSession、Walk.net_point_entry | 基礎；沒有matching／發點。 |
| Daily exercise time | DogGoalTarget、DogDailyGoal、QuestAward | 個人化目標與進度已連接；20/day 已定，多狗獎勵資格待定。 |
| Café check-in | Venue、CheckIn → PointEntry | 已連接；實機驗收待完成。 |
| Restaurant check-in | 同上，以category_slot區分 | 同上。 |
| Park check-in | 同上，以category_slot區分 | 同上。 |
| Vet check-in | 同上；不同於vet文件 | 同上。 |
| 7-day streak | Walk驗證日期 → QuestAward.run_start_date／milestone_days → PointEntry | 已連接；每段新streak可重新達標，Collect防重領。 |
| 30/60/90…day streak | 同上 | 已連接；單一進度條等待Collect後切換下個目標。 |
| Vet checkup | DocumentEntitlement事件日 → PointEntry | 已連接。 |
| Council registration | 每狗／實際到期日 entitlement → PointEntry | 已連接；過期後開新期，舊未領任務失效；舊收據／點數保留。 |
| Microchip certificate | 每狗終身 entitlement → PointEntry | 已連接；舊年期／點數保留，歷史已領資格不能重領。 |
| Dog birthday | Dog.date_of_birth、QuestAward → PointEntry | 已連接；每狗／年份唯一，跨轉移防重領。 |

Walk＋Daily Goal＋Check-in 共享 72/day 已在服務保護；Daily Goal 對外發點仍停用，Net 是否納入待定。餘額、生日、文件及退款不代表該日活動收入。若剩餘不足 12，現在拒絕 check-in Collect；沒有先行實作尚未確認的部分發點。

## 保留的衝突與未完成範圍

- 最新決定取代舊一狗／兩狗限制、Council終身一次、咖啡60提示、事前文件核准及swipe扣點；完整現行規則見[QUESTS.md](../QUESTS.md)。Council依2026-09-27更正決定按文件實際到期日刷新。目前最多10狗，walking仍按帳戶計分。
- Daily goal 20/day 不是未知金額；個人化公式已實作，未知的是多狗帳號的獎勵資格。Daily Goal 若啟用發點，與 Walk／Check-in 共用 72/day。
- Streak已定案為有效散步日、漏日重置，每段7日與30/60/90…可領；已達標未領保留。Net規則與Daily Goal多狗獎勵資格仍需定案，資料表不代表發點引擎已啟用。
- User刪除／Dog封存欄位、文件audit欄位及LogEntry不等於完整刪除／抽查／稽核流程；保存、匿名化及點數追回待政策。六個延後模型不以假欄位冒充完成。

**37張可見Jira與14條User Story均保留落點；23張表是現有模型，6張表未建立。資料覆蓋不等於所有功能已可交付。**
