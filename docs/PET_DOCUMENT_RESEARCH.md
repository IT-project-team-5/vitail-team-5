# Pet registration evidence in Melbourne

Research checked 25 September 2026; implementation decisions updated 27 September. English editorial revision: 15 October. This records the research and decisions at those dates; current reward rules are maintained in [QUESTS.md](QUESTS.md).

Registration Quests default to **Upload proof**. The app reads available text, then asks the owner to check or complete the details. **Enter details** is a secondary option. Submissions are self-reported: collecting a reward does not certify government registration or document authenticity.

## The two registrations

| | Council registration | Microchip registration |
|---|---|---|
| Responsible organisation | The local council where the dog lives | An approved Victorian microchip registry |
| Purpose | Register the pet with local government | Link the chip number to the pet and contact details |
| Timing | Required from three months of age; existing registrations renew annually by 10 April | Basic registration identifies the pet for life; update contact details when they change |
| First application | Microchip the dog, then apply to the local council | A vet or authorised implanter inserts the chip and arranges registration |
| Completed evidence | Council registration confirmation or current registration record | Registry identification or registration certificate |

Sources: [Agriculture Victoria — registration](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/dog-and-cat-registration/pet-registration-benefits), [microchipping](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/microchipping-of-dogs-and-cats), and [registration and moving address](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/dog-and-cat-registration/dog-and-cat-registration-fees). Council and registry contact details must be updated separately.

Microchip certificates do not need annual start/end dates. [CAR's FAQ](https://car.com.au/apps/help-center) describes basic registration as a one-time payment for life. Paid extras and a registry company's licence renewal are separate. [Victorian registry rules](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/domestic-animal-microchip-registries) require records for the animal's life or 30 years after first registration, whichever is longer.

Council registration is not necessarily twelve months from application. [Port Phillip](https://www.portphillip.vic.gov.au/council-services/pets-and-animals/pet-registration), for example, specifies a registration year and arrangements for late-year first registrations. The app uses the confirmed expiry printed on the evidence, not an assumed annual date.

## Submission requirements

Each Quest belongs to one dog and one document type; owners do not switch these within the form.

| Evidence | Details to confirm |
|---|---|
| Council | Council name, Animal ID/registration number and actual expiry date (`valid_to`). Valid through that day; renewal opens at midnight the next day in Melbourne. |
| Microchip | Chip number; registry is optional. Manual entry accepts 15 ASCII digits, removes spaces/hyphens, preserves leading zeroes and does not require a leading 9. Older or overseas formats use supporting proof. No expiry is required. |
| Vet visit | Actual visit date and photo. |

Accept PDF, JPEG and PNG, including photos and screenshots. Limits: 4 MiB; unencrypted PDFs of 1–20 pages; images up to 16 megapixels. Fill only clearly identified fields, then require owner confirmation and missing details. Show the current dog's submission and collection status, without an account-wide history in the form.

Council numbers have no Melbourne-wide format. [Greater Dandenong](https://www.greaterdandenong.vic.gov.au/pets-and-animals/renew-your-pet-registration) uses a 1–5 digit Animal number; [Hume](https://www.hume.vic.gov.au/Residents/Pets-and-Animals/Register-Your-Pet) asks for Animal ID rather than tag number. Preserve letters, digits, spaces and hyphens instead of imposing one length rule.

Completed evidence includes a current council certificate or official completion email, and a registry identification/registration certificate. Applications, unpaid notices and processing screens do not establish completion. These are tutorial and later spot-check criteria; the reader cannot verify the issuer's database.

## Council tutorial

**Already registered?** Find the registration confirmation or renewal paperwork from your local council. Request a copy if it is missing. Upload completed-registration proof, then check the council, registration number and printed expiry. You can also enter these details yourself.

**Not registered yet?** Have your dog microchipped, then apply through the council where the dog lives. Prepare the microchip details and supporting documents. Upload confirmation after registration is complete.

- City of Melbourne: [eServices → Pet Registration](https://eservices.melbourne.vic.gov.au/ePathway/Production/Web/Default.aspx), with application/contact information through [government ABLIS](https://ablis.business.gov.au/service/vic/registration-of-cats-and-dogs-city-of-melbourne/28570).
- Elsewhere: [find the council for your address](https://www.vec.vic.gov.au/electoral-boundaries/which-boundaries-cover-where-i-live), then use its pet-registration service.
- Completion varies: [Yarra](https://www.yarracity.vic.gov.au/residents/pets-and-animals/register-your-pet) distinguishes submission/payment acknowledgement from the issued certificate; [Melton](https://www.melton.vic.gov.au/Regulations/Animals) accepts its official completion email without waiting for the tag.

Do not send all Greater Melbourne residents to one council. Documents may contain tag, payment, reference and chip numbers; the first number is not necessarily the registration number. The [older City of Melbourne form](https://mvga-prod-files.s3.ap-southeast-4.amazonaws.com/public/2024-07/Pet-registration-form-2024-25.pdf) separates tag and reference fields. It is a field-layout example, not a source for current fees.

## Microchip tutorial

**Already microchipped?** Find the number in your pet records. Use [Pet Address](https://petaddress.com.au/) to identify the registry, sign in and download the certificate. Check your contact details. This lookup does not expose arbitrary owners' full personal details.

**Cannot find the number?** Ask your usual vet for the recorded number, or take the dog to a vet for a scan.

**Not microchipped yet?** Book a vet appointment for implantation and registration. Upload the registry certificate when received.

- [CAR](https://car.com.au/apps/help-center): sign in → My Animals → select dog → Generate Certificate.
- [AAR Pet Owners](https://www.aar.org.au/pet-owners/): print the pet's registration certificate.
- [Approved Victorian registries](https://agriculture.vic.gov.au/livestock-and-animals/animal-welfare-victoria/domestic-animals-act/registration-legislation-and-permits/microchipping-of-dogs-cats-and-horses/domestic-animal-microchip-registries).

If a chip exists but no registry is found, ask the vet to confirm the number and contact an approved registry. Do not recommend another implant. CAR may require a veterinary scan for a new Victorian registration. Older or overseas numbers can differ from 15 digits; length alone does not prove a document false.

## What document reading can do

The upload flow provides text recognition and suggested values for owner confirmation:

- Extract embedded PDF text first; read scanned pages and images when needed.
- Identify labelled numbers, dog names and issuers for the selected document type. Council expiry must be explicitly labelled; payment deadlines, birthdays and issue dates do not qualify.
- Keep chip, council and payment numbers separate. Leave missing, unclear or conflicting fields unresolved.
- Store the document's dog name as a suggestion, without substituting the app name or automatically changing the dog's main chip record.
- Allow another photo or manual correction for blur, glare, cropping, handwriting and multi-dog documents.

Reading runs on-device using iOS 17-compatible `VNRecognizeTextRequest` and PDFKit, without blocking the screen. See [Apple Vision](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) and [Apple's explanation](https://developer.apple.com/videos/play/wwdc2025/272/).

Text recognition cannot prove ownership, detect every alteration or confirm current official registration. Its suggestions are not permission for the server to award points.

## Reward decisions recorded on 27 September

- Council: 300 points per dog per valid registration period, renewed from the confirmed actual expiry. Microchip: 300 points once per dog for life.
- Expired uncollected council rewards disappear and cannot be claimed through an old link. Original evidence and point records remain.
- A renewed registration can reuse the same Animal ID, but one file cannot establish different qualifications. Editing an unexpired qualification cannot earn another award.
- Missing expiry on an old record must be corrected on that qualification. Previously collected points are not awarded again; do not invent 9 April from an old year value.
- Only a currently valid, uncollected qualification can be collected after confirmation. There is no mandatory review before collection; later spot checks remain separate.

## Recorded reader check — 27 September 2026

The production `DocumentReader.swift` processed 40 real web files: ten council forms, ten registry forms, ten difficult images and ten unrelated images. All completed without a program error. None automatically supplied a registration number or expiry; six suggested only a registry name. Other fields required owner input or a replacement document.

Two blank-form labels had been mistaken for dog names: “Date of Birth of Animal” and “Tick for Cross-Breed”. Exclusion rules and regression tests removed these results on rerun.

This supports conservative handling of blank or unsuitable inputs, **not an accuracy claim for issued certificates**. Separate generated tests cover text/scanned PDFs, Vision image reading, visible form fields, multiple dogs/numbers/dates, low confidence, cancelled reads and manual corrections. They are engineering fixtures, not part of the 40 real files.
