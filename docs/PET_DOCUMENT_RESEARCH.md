# 墨爾本寵物登記：流程、提交方式與辨識邊界

查證：2026-09-25。使用者已確認登記 Quest 採「填資料」或「上傳證明」二選一。提交為 self-reported，成功後可 Collect；不做事前人工審查或宣稱官方驗證。

## 先釐清兩種登記

| 項目 | Council registration | Microchip registration |
|---|---|---|
| 管理者 | 狗居住地址所屬的 local council | 維州核准的 microchip registry |
| 用途 | 地方政府的寵物登記 | 晶片號碼與寵物／聯絡人資料連結 |
| 時間 | 維州三個月大起須登記，既有登記每年 4 月 10 日前續期 | 晶片與基本登記是終身識別；資料變更時需更新 |
| 初次辦理 | 先植入晶片，再向所屬 council 申請 | 找獸醫／合法 implanter 植入並登錄 |
| 文件 | Council 核發的登記確認／相關當期文件 | Registry 的 certificate of identification／registration |

依據：[Agriculture Victoria：Council registration](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/dog-and-cat-registration/pet-registration-benefits)、[Microchipping](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/microchipping-of-dogs-and-cats)。Council 與 registry 的地址／聯絡資料也需要各自更新，見[登記與搬家說明](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/dog-and-cat-registration/dog-and-cat-registration-fees)。

**Microchip 不要求證書年度起訖。** 舊介面的這項要求與實際流程不符，已移除。 [CAR 官方 FAQ](https://car.com.au/apps/help-center) 說明基本登記一次付費、終身有效；不應把額外付費服務或 registry 公司牌照的續期當成每隻狗的證書期限。[維州 registry 規定](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/domestic-animal-microchip-registries)要求保留動物一生或首次建檔後 30 年，取較長。

Council 文件的期間也不能推定為申請日起剛好 12 個月。例如 [Port Phillip](https://www.portphillip.vic.gov.au/council-services/pets-and-animals/pet-registration)有指定登記年度及接近年度末首次登記的安排。

## 已確認的提交方式

每頁固定綁定 `dogID + documentKind`，標題沿用 Quest 名稱；不同狗各自一個 Quest，不再選狗或文件種類。

1. 上方教學分「已有登記，去哪找」和「還沒登記，去哪辦」，附官方連結。
2. 下方選擇 **Enter details** 或 **Upload proof**。
3. Council 手填：Council 名稱、Animal ID／Registration number、當期有效年度。年度 API 存結束年；`2027` 表示 2026-04-10 至 2027-04-09。依 2026-09-27 使用者最新決定，Council 獎勵為每狗每登記年度一次。
4. Microchip 手填：通常為 15 位 ASCII 數字；清除空格／連字號，保留開頭 0，不限制必須以 9 開頭。舊／海外等其他格式走上傳證明途徑。
5. 上傳接受 PDF、JPEG、PNG（含照片、截圖），不強制再填 Council、號碼或日期。限制為 4 MiB；PDF 1–20 頁且未加密，圖片最多 16 MP。
6. 顯示此狗／此類型的提交與領取狀態，不列整個帳號的歷史或重複政策說明。Vet 保留就診日期＋照片。

Council 編號沒有墨爾本統一格式：[Greater Dandenong](https://www.greaterdandenong.vic.gov.au/pets-and-animals/renew-your-pet-registration) 明確使用 1–5 位 Animal number；[Hume](https://www.hume.vic.gov.au/Residents/Pets-and-Animals/Register-Your-Pet) 要求 Animal ID，不能填 Tag number。手填保存字母、數字、空格、連字號；不套用通用位數規則。

正式證明包括 Council 當年度有效登記證書／正式完成 Email，以及 registry 的 Registration／Identification Certificate。申請表、待付款通知、待處理畫面不能當作完成證明；這是教學與日後抽查標準。第一版只驗證輸入與檔案是否有效，不自動判斷文件內容或真偽。

## Council tutorial 草稿

**Already registered?**

Check the registration confirmation or renewal paperwork from your local council. If you cannot find your pet's registration details, ask that council for a copy. Enter your council, animal registration number and current registration year, or upload proof showing the council and your dog's details.

**Not registered yet?**

Make sure your dog is microchipped, then apply through the council where your dog lives. Have your microchip details and any supporting documents ready. Upload the confirmation once registration is complete.

- City of Melbourne 居民：[官方 eServices](https://eservices.melbourne.vic.gov.au/ePathway/Production/Web/Default.aspx) → Pet Registration。
- [政府 ABLIS 登記／聯絡入口](https://ablis.business.gov.au/service/vic/registration-of-cats-and-dogs-city-of-melbourne/28570)：含申請連結及 City of Melbourne Animal Management 聯絡資料。
- 其他地區：[VEC 地址與 Council 查詢](https://www.vec.vic.gov.au/electoral-boundaries/which-boundaries-cover-where-i-live)，再進所屬 Council 的寵物登記頁。

教學不能把所有 Greater Melbourne 使用者導到同一 Council。Council 的 tag number、reference number、付款參考及 microchip number 可能同時出現在文件上，不能靠抓第一串數字認定是登記號碼。現有 City of Melbourne 表格也把 tag number 和 reference number 分列，見[官方表格](https://mvga-prod-files.s3.ap-southeast-4.amazonaws.com/public/2024-07/Pet-registration-form-2024-25.pdf)（舊年度樣式僅用來理解欄位，不引用舊費率）。

[Yarra 官方流程](https://www.yarracity.vic.gov.au/residents/pets-and-animals/register-your-pet) 明確區分送件付款確認與登記完成後核發證書；[Melton](https://www.melton.vic.gov.au/Regulations/Animals) 的正式完成 Email 也可作為登記證明，不必等實體狗牌寄達。

## Microchip tutorial 草稿

**Already microchipped?**

Find your microchip number on your pet's records. Use Pet Address to find the registry, then sign in and download your dog's registration certificate. Check that your contact details are up to date.

**Cannot find the number?**

Ask your usual vet for the recorded number, or take your dog to a vet for a scan.

**Not microchipped yet?**

Book a vet appointment for microchipping and registration. Once you receive the registry certificate, upload it here.

- [Pet Address](https://petaddress.com.au/)：輸入已知晶片號碼查出 registry；不提供任意查詢人的完整個資。
- [CAR 官方說明](https://car.com.au/apps/help-center)：登入 → My Animals → 選狗 → Generate Certificate。
- [AAR Pet Owners](https://www.aar.org.au/pet-owners/)：Print your pet’s registration certificate。
- [維州核准 registry 清單](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/domestic-animal-microchip-registries)。

已植入卻查不到 registry 時，先請獸醫確認號碼，再向核准 registry 詢問登錄；不要引導重複植入。CAR 的維州新登錄還可能要求獸醫掃描驗證。晶片通常是 15 碼，但須處理舊／海外號碼，不能僅以長度判假。

## 基本圖片判讀的可行性

下列 **OCR 輔助填寫＋使用者確認** 是後續方案，尚未啟用；本輪使用手填或上傳二選一：

- 圖片／掃描 PDF 讀出文字；有文字層的 PDF 優先抽取文字。
- 在已知 Quest 類型內辨識號碼、狗名、核發機構；Council 若需當期資格，再辨識有標籤的日期。
- 不把晶片號碼、Council 參考號碼及付款號碼混用；找不到明確候選就要求補正。
- 與這隻狗已存的晶片資料比對。尚無可信號碼時，圖片無法單獨建立真實所有權。
- 模糊、反光、裁切、手寫及多隻狗共用文件會增加錯讀；保留重拍／手動修正。
- 一般文件資訊可在裝置端讀取。Apple 說明 Vision 在裝置端執行；目前 app 支援 iOS 17，實作應使用相容的 `VNRecognizeTextRequest`，避免把新版 API 當成所有裝置都能用。[Apple Vision](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)、[Apple WWDC 說明](https://developer.apple.com/videos/play/wwdc2025/272/)。

OCR 能讀文字與提出一致性提示，不能證明文件未變造、當下政府／registry 登記狀態或實際所有權。未串接獲授權的查驗服務前，狀態仍應是 self-reported／已提交。前端 OCR 結果不得當成後端已驗證的發點授權。

既有 OCR 研究使用官方空白表格及網路圖片，沒有足夠已核發證書正例，不能據此宣稱完整證書辨識率或涵蓋所有狀況。OCR 不在本輪提交流程中啟用。

## 已確認的獎勵規則

- Council 每隻狗每登記年度 300 點；每年 4 月 10 日墨爾本零時出現新年度 Quest。Microchip 維持每隻狗終身一次 300 點。
- Council 手填年度是 self-reported 證明資料；獎勵年度另存在 entitlement，由伺服器當前年度決定。上傳仍不要求手填年度，且沒有 OCR 判讀文件年度。Microchip 不要求年度或證書起訖。
- 上年度未領獎勵保留，與新年度 Quest 分開顯示。相同 Animal ID 可在續期後再用；同一份檔案不能跨年當作新資格。舊 Council 資格依最早提交的年度（未知則以該次提交日期推定）歸年，不因後續重傳移到新年度。
- 保留原本已發點數、舊年期、提交檔案與收據。曾領過 Microchip 即已使用終身資格，不因換主人、重傳或換年度再發點。
- 手填或上傳成功後可 Collect，狀態是已提交；後續抽查，沒有前置人工審核。OCR 仍屬後續方案。
