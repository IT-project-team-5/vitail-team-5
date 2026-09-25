# 墨爾本寵物文件與圖片判讀：討論稿

查證：2026-09-25。這份研究供下一輪 UI／資格規則討論使用，尚未改動目前上傳頁或發點規則。

## 先釐清兩種登記

| 項目 | Council registration | Microchip registration |
|---|---|---|
| 管理者 | 狗居住地址所屬的 local council | 維州核准的 microchip registry |
| 用途 | 地方政府的寵物登記 | 晶片號碼與寵物／聯絡人資料連結 |
| 時間 | 維州三個月大起須登記，既有登記每年 4 月 10 日前續期 | 晶片與基本登記是終身識別；資料變更時需更新 |
| 初次辦理 | 先植入晶片，再向所屬 council 申請 | 找獸醫／合法 implanter 植入並登錄 |
| 文件 | Council 核發的登記確認／相關當期文件 | Registry 的 certificate of identification／registration |

依據：[Agriculture Victoria：Council registration](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/dog-and-cat-registration/pet-registration-benefits)、[Microchipping](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/microchipping-of-dogs-and-cats)。Council 與 registry 的地址／聯絡資料也需要各自更新，見[登記與搬家說明](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/dog-and-cat-registration/dog-and-cat-registration-fees)。

**目前 Microchip 頁面要求完整年度起訖，與實際流程不符。** [CAR 官方 FAQ](https://car.com.au/apps/help-center) 說明基本登記一次付費、終身有效；不應把額外付費服務或 registry 公司牌照的續期當成每隻狗的證書期限。[維州 registry 規定](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/domestic-animal-microchip-registries)要求保留動物一生或首次建檔後 30 年，取較長。

Council 文件的期間也不能推定為申請日起剛好 12 個月。例如 [Port Phillip](https://www.portphillip.vic.gov.au/council-services/pets-and-animals/pet-registration)有指定登記年度及接近年度末首次登記的安排。

## 頁面結構建議

每個頁面固定綁定 `dogID + documentKind`，例如「Mishowww · Council registration」。不同狗各自一個 Quest。

1. 顯示點進來的任務名稱及狗狗；沒有文件或狗的下拉選單。
2. 上方兩小段教學：「已登記，去哪找」及「還沒登記，去哪辦」。
3. 下方一個上傳區：照片／PDF → 檢查辨識結果 → Submit。
4. 有需要時僅提供號碼／必要日期的補正，不要求在另一張表重新填寫全部資料。
5. 移除重複獎勵說明、年度確認勾選、整個帳號的提交歷史。僅保留這個 Quest 的必要狀態和錯誤提示。

現行 production route 已傳入特定狗及 document kind；這輪先討論，尚未實作上述修改。

## Council tutorial 草稿

**Already registered?**

Check the registration confirmation or renewal paperwork from your local council. If you cannot find your pet's registration details, ask that council for a copy. Upload a document that shows the council and your dog's details.

**Not registered yet?**

Make sure your dog is microchipped, then apply through the council where your dog lives. Have your microchip details and any supporting documents ready. Upload the confirmation once registration is complete.

- City of Melbourne 居民：[官方 eServices](https://eservices.melbourne.vic.gov.au/ePathway/Production/Web/Default.aspx) → Pet Registration。
- [政府 ABLIS 登記／聯絡入口](https://ablis.business.gov.au/service/vic/registration-of-cats-and-dogs-city-of-melbourne/28570)：含申請連結及 City of Melbourne Animal Management 聯絡資料。
- 其他地區：[VEC 地址與 Council 查詢](https://www.vec.vic.gov.au/electoral-boundaries/which-boundaries-cover-where-i-live)，再進所屬 Council 的寵物登記頁。

教學不能把所有 Greater Melbourne 使用者導到同一 Council。Council 的 tag number、reference number、付款參考及 microchip number 可能同時出現在文件上，不能靠抓第一串數字認定是登記號碼。現有 City of Melbourne 表格也把 tag number 和 reference number 分列，見[官方表格](https://mvga-prod-files.s3.ap-southeast-4.amazonaws.com/public/2024-07/Pet-registration-form-2024-25.pdf)（舊年度樣式僅用來理解欄位，不引用舊費率）。

產品建議：若獎勵要證明「當期登記完成」，應收已完成登記的確認資料；僅有空白申請表、待付款通知或吊牌照片不足以證明已完成當期程序。這是建議的 Vitail 證據標準，尚未定案。

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

建議第一版採 **OCR 輔助填寫＋使用者確認**：

- 圖片／掃描 PDF 讀出文字；有文字層的 PDF 優先抽取文字。
- 在已知 Quest 類型內辨識號碼、狗名、核發機構；Council 若需當期資格，再辨識有標籤的日期。
- 不把晶片號碼、Council 參考號碼及付款號碼混用；找不到明確候選就要求補正。
- 與這隻狗已存的晶片資料比對。尚無可信號碼時，圖片無法單獨建立真實所有權。
- 模糊、反光、裁切、手寫及多隻狗共用文件會增加錯讀；保留重拍／手動修正。
- 一般文件資訊可在裝置端讀取。Apple 說明 Vision 在裝置端執行；目前 app 支援 iOS 17，實作應使用相容的 `VNRecognizeTextRequest`，避免把新版 API 當成所有裝置都能用。[Apple Vision](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)、[Apple WWDC 說明](https://developer.apple.com/videos/play/wwdc2025/272/)。

OCR 能讀文字與提出一致性提示，不能證明文件未變造、當下政府／registry 登記狀態或實際所有權。未串接獲授權的查驗服務前，狀態仍應是 self-reported／已提交。前端 OCR 結果不得當成後端已驗證的發點授權。

尚未取得真實 Council／registry 文件樣本，沒有量測辨識率。先測各家格式、低品質照片、多狗文件及錯誤號碼，再決定哪些結果可直接帶入、哪些需要確認。不要為不確定的辨識結果新增一整套複雜表單。

## 需要討論的產品規則

- 維州實際登記頻率和 Vitail 給點頻率分開決定。現行 Council 每狗一次、Microchip 每年度 300 點，是既有產品規則，這份研究不會自動變更已發點資料。
- 建議 Microchip 改為每狗一次；若保留每年獎勵，可改成「年度確認晶片聯絡資料」Quest，另定有效確認證據，不再要求虛構的證書年度期限。
- 建議先做 OCR 協助讀取與補正，延續提交成功後可 Collect、後續抽查的方向；不加入前置人工審核。
