# Council search data

`councils.json` contains the 79 Victorian Council names and distinct Council/postcode
pairs extracted from the Victorian Electoral Commission's **Victorian Electors by
Locality, Postcode and Electorates**, dated 20 August 2026.

Source: https://discover.data.vic.gov.au/dataset/victorian-electors-by-locality-postcode-and-electorates

Workbook: https://www.vec.vic.gov.au/-/media/fd9bc5bf2896490daa4aedb9794d263c.xlsx

Attribution: Victorian Electoral Commission, licensed CC BY 4.0:
https://creativecommons.org/licenses/by/4.0/

Rebuild with `python -m evidence.import_councils PATH_TO_VEC_XLSX`. No elector counts,
household counts, addresses or individual records are retained. The source describes
enrolled-elector localities, so postcode matches are suggestions, not a boundary or
residency determination. Users must select the Council on their registration. Name
search is available when a postcode has no match. Coverage is Victoria for this pilot.
