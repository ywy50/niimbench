# Label catalogue

Every label the vendor cloud offers in the sizes its own template endpoint groups by series, keyed on the barcode an RFID tag carries, and the rolls added from a tag the cloud answered for. The app reads a roll's barcode from the tag and looks it up here to size the canvas, so this page is the reference for what a roll can be, and `catalogue.json` beside it is the same data for code to read.

`catalogue.json` and this page are written by [tools/fetch-labels.py](../../tools/fetch-labels.py); do not edit either by hand. [Regenerating](#regenerating) says how.

## Coverage

| Sizes | Labels | Added from a tag | Sizes a bench model takes |
|---|---|---|---|
| 26 | 219 | 1 | 24 |

The printer heads this bench drives take these label widths: 12, 14 and 15 mm on the D-series, 20 to 50 mm on the B-series, and 10 to 14 mm on the B18. A catalogue entry names the machines the vendor ships it for; the `bench` column below only says that one of this bench's heads appears in that list.

## Labels by size

`paper` is the vendor's paper type for the roll; niimbench does not send it and always tells the printer label type 1, a gap label, and `bench` lists the models here that the vendor lists the label for. A dash in `bench` means no model this bench drives is on the label's machine list, but the size may still be printable if a roll measures that way.

### 12x40 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424777` | Commodity marking-egg | gap | d11, d110 |
| `01222281` | Price label-egg | gap | d11, d110 |
| `6978642801825` | label-Light | gap | d11, d110 |

### 14x30 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424781` | Price label-bunny cake | gap | d11, d110 |
| `07072205` | Price label-bunny | gap | b18 |
| `12242117` | Price label-candle | gap | b18 |

### 22x12 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `6972842743558` | RP12*22-260 | gap | d11, d110 |
| `6972842747549` | Name Tag-Boys | gap | d11, d110 |

### 28x14 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `12271912` | compound | gap | d11, d110 |

### 30x12 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `091225179` | Cockatiel | gap | d11, d110 |
| `6972842743831` | Food Delivery | transparent | d11, d110 |

### 30x14 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `02092303` | compound | gap | d11, d110 |
| `081224235` | Hand Soap | gap | — |

### 30x15 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `02282280` | Rabbit food | gap | d11, d110 |
| `040724014` | Freeze Reminder | gap | b1, b21 |
| `04162207` | freeze dried fruit | transparent | — |
| `070424277` | Happy Thanksgiving | gap | — |
| `07182153` | shipping-fragile | gap | b1, b21 |
| `12222114` | Baking Tool | gap | b1, b21 |
| `123025201` | Happy Teacher's Day | gap | b21 |
| `26290423` | Happy Mother's Day | gap | d11, d110 |
| `69522800002158` | fish | gap | b1, b21 |
| `6971501224599` | Fresh Food-Product Detail | gap | d11, d110 |
| `6971501225428` | Product name | gap | d11, d110 |
| `6971501227873` | Cookies Store Information | gap | b1, b21 |
| `6972842740045` | YOU ARE INVITED TO PARTY HALLOWEEN | gap | d11, d110 |
| `6972842740182` | Beauty Care-Product Information | gap | d11, d110 |
| `6972842743725` | Toilet Area Sign | transparent | d11, d110 |
| `6978061957066` | coriander | gap | — |

### 30x20 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `11262108` | Brunch | gap | b1, b21 |

### 30x30 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `032625158` | Sealed for safety | gap | b1, b21 |
| `110825042` | Thank You | gap | b1, b21 |

### 30x50 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `6978642804963` | Happy Thanksgiving | gap | — |

### 40x12 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424787` | First Aid | gap | d11, d110 |
| `010424809` | Clearance Label | gap | d11, d110 |
| `022324001` | Moving box label | gap | d11, d110 |
| `041025002` | Trash | gap | d11, d110 |
| `05292005` | fish | transparent | d11, d110 |
| `06172280` | kids wash label | gap | d11, d110 |
| `06172304` | label-Cow milk | gap | d11, d110 |
| `06232104` | Dog Biscuits | gap | d11, d110 |
| `07052201` | Reminder | transparent | d11, d110 |
| `08192107` | Lag screws | gap | d11, d110 |
| `091225177` | Pumpkin | gap | d11, d110 |
| `11242009` | T-shirt | gap | d11, d110 |
| `112423208` | Father's Day | gap | d11, d110 |
| `11262116` | Fish food | transparent | b1, b21 |
| `12222122` | Reminder | gap | b1, b21 |
| `6972842740175` | Easter | gap | d11, d110 |
| `6972842740328` | Code blue | gap | d11, d110 |
| `6972842740861` | Label-House number | gap | d11, d110 |
| `6972842743572` | Goodwill | gap | d11, d110 |
| `6977031210613` | thyme | gap | d11, d110 |
| `6977031211887` | Scratching Post | gap | d11, d110 |
| `6977031217858` | Trash | transparent | b1, b21 |
| `6978061950197` | expiration-Makeup | gap | d11, d110 |

### 40x14 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `021325262` | compound | black mark gap | b18 |
| `08152233` | Thankful For You | gap | d11, d110 |
| `6972842747556` | Love | gap | d11, d110 |

### 40x20 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424153` | clean-building block | gap | b1, b21 |
| `010424602` | Commodity marking-perfume | gap | b1, b21 |
| `010924601` | Pet Emergency | gap | — |
| `01102214` | Period of validity-Beaf sausage | gap | b1, b21 |
| `041025001` | Birthday | gap | b1, b21 |
| `041626123` | Tirzepatide | gap | — |
| `05092172` | On Fire | transparent | d11, d110 |
| `070626199` | Tesamorelin | gap | b1, b21 |
| `070726069` | Reta | gap | — |
| `071123018` | Price Label-delicious bread | gap | b1, b21 |
| `08042118` | Period of validity-banana bread | gap | — |
| `080624222` | tesa | gap | — |
| `082026285` | semaglutide | gap | — |
| `082026287` | Templates-260916042200 | gap | — |
| `112523208` | Categorization of ingredients-garrot ginger soup | gap | b1, b21 |
| `11262109` | MERRY CHRISTMAS | gap | b1, b21 |
| `12291950` | Period of validity-Brownie | transparent | b1, b21 |
| `69522800011098` | Fixed Assets-Labeling Machine | gap | b1, b21 |
| `6971501227743` | Advertising drainage label-Niimbot | gap | b1, b21 |
| `6975746632072` | Compound | gap | b1, b21 |
| `6978061951279` | Semaglutide | gap | b1, b21 |

### 40x30 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424611` | PICNIC | gap | b1, b21 |
| `010424618` | Candle | gap | b1, b21 |
| `010424764` | Happy Birthday | transparent | b1, b21 |
| `02262179` | Advertising drainage label-easter game | gap | b1, b21 |
| `022824259` | Employee ID card-name | gap | b1, b21 |
| `040824041` | STRAWBERRY JAM | gap | b1, b21 |
| `05092121` | Rum Pound | transparent | b1, b21 |
| `05152061` | Name tag | transparent | b1, b21 |
| `06202204` | Blessings this Easter | gap | b1, b21 |
| `08042123` | Stationery-Notes | gap | — |
| `08262104` | CHEESE BURGER | transparent | b1, b21 |
| `08282053` | Church | gap | b21 |
| `08282055` | Bakery | gap | b1, b21 |
| `08312299` | HAPPY HALLOWEEN | transparent | b1, b21 |
| `09032060` | Employee Activities-tennis tournament | gap | b1, b21 |
| `09142055` | Drone Label | gap | b1, b21 |
| `11102108` | Olive Oil | gap | b1, b21 |
| `11122067` | Point out-seafood | gap | b1, b21 |
| `11202067` | Price Label-Sandwich | transparent | b1, b21 |
| `11262113` | Easter  | gap | b1, b21 |
| `12092202` | Fixed Asset-Code | gap | b1, b21 |
| `12092290` | Makeup-Spa | transparent | b1, b21 |
| `122623023` | Whole Wheat Bread | transparent | b1, b21 |
| `6971501224001` | Price Label-Sandwich | gap | b1, b21 |
| `6971501224247` | Information-Bake gift box | gap | b1, b21 |
| `6971501224315` | Food information-Bacon | gap | b21 |
| `6971501224414` | Candle Brand | gap | — |
| `6971501227750` | Specification label-punk dress | gap | b1, b21 |
| `6972842747129` | Haircare Oil | gap | d11, d110 |
| `6972842748553` | salmon | gap | b1, b21 |
| `6975746632102` | Thanksgiving | gap | b1, b21 |
| `6977031210545` | Halloween | gap | b1, b21 |
| `6978061951255` | dna | gap | — |
| `6978061956144` | compound | gap | — |

### 40x60 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `040426052` | Radish Kimchi | gap | b1, b21 |
| `04072105` | Information-Cookies | transparent | b1, b21 |
| `07132202` | Advertising drainage label-Bakery | gap | b1, b21 |
| `07182159` | Employee Activities-Prize | gap | b1, b21 |
| `08152061` | Price Label-Cat food | gap | — |
| `09032061` | Price label-Banana | gap | b1, b21 |
| `6972842748560` | Commodity marking-coffee | gap | b1, b21 |
| `6975746632171` | Fixed Assets-Label | transparent | b1, b21 |

### 40x70 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `01041905` | Fixed Assets-Diskstation | gap | b1, b21 |
| `03222122` | Information-Facial Cleanser | gap | b1, b21 |
| `032624001` | Cat food | gap | — |
| `09292060` | Information-Rusks | gap | — |
| `697150122202` | Employee Activities-Contest | gap | — |
| `6977031212082` | Facial Mask | gap | b1, b21 |

### 50x14 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `060226270` | compound | black mark gap | b18 |
| `08202164` | Body Lotion | gap | d11 |

### 50x15 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `102825117` | Happy Thanksgiving | gap | d11, d110 |
| `6971501224179` | Pepper | gap | b21 |

### 50x30 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424606` | chocolate cake | gap | b1, b21 |
| `010424703` | name tag-camp | gap | b1, b21 |
| `010424708` | Dead stock | gap | b1, b21 |
| `02262167` | General Information | gap | b1, b21 |
| `022824255` | Fixed Assets-number | gap | b1, b21 |
| `022824258` | Private Storage | gap | b1, b21 |
| `03052209` | Templates-260910112141 | black | b1, b21 |
| `03102119` | Information-Christmas cupcakes | gap | b1, b21 |
| `03222221` | Butterfly Decor Label | gap | b1, b21 |
| `040726110` | vacation clothes | gap | b1, b21 |
| `04112204` | Baby Shower | gap | b18 |
| `04152219` | PIZZA | gap | b1, b21 |
| `042224055` | travel tag | gap | b1, b21 |
| `042225005` | paprika | gap | — |
| `05092110` | Product Name | gap | b1, b21 |
| `052124177` | legend | gap | — |
| `052126061` | Birds | gap | — |
| `05262150` | Sheet Masks | gap | b1, b21 |
| `060723012` | Happy Christening | gap | b1, b21 |
| `061625108` | Happy Easter | gap | b1, b21 |
| `06202055` | Fixed Asset-Code | transparent | — |
| `06222212` | Happy Easter | transparent | b1, b21 |
| `06282164` | PET FOOD | gap | b1, b21 |
| `07082005` | Nail Studio | transparent | b1, b21 |
| `07112067` | Price tag | gap | b1, b21 |
| `071123021` | Muffin Price | gap | b1, b21 |
| `080725137` | Klow | gap | — |
| `082825078` | BODY WASH | gap | b1, b21 |
| `090323016` | General Information | gap | b1, b21 |
| `09052001` | label-milk | gap | b1, b21 |
| `092024077` | Dog Return Address | gap | b1, b21 |
| `09272204` | Genernal Information | gap | b1, b21 |
| `10222092` | Congratulations Label | gap | b1, b21 |
| `102425141` | Retatrutide | black | b21 |
| `10262260` | Period of validity-ever spring tea | gap | b1, b21 |
| `10292112` | General Information | gap | b1, b21 |
| `110125004` | compound | gap | — |
| `110825008` | Book Tag | gap | b1, b21 |
| `111225131` | Happy Teacher's Day | gap | b1, b21 |
| `11262112` | Room Information | gap | b1, b21 |
| `11262119` | green tea | gap | b1, b21 |
| `112723293` | Bike Shop | gap | b1, b21 |
| `121123110` | Mother's Day | gap | — |
| `12132202` | General Information | gap | b1, b21 |
| `12142109` | Promotion | gap | b1, b21 |
| `12222117` | Father’s Day | gap | b1, b21 |
| `20171230000007` | label-Cookies | gap | b1, b21 |
| `20180331000008` | Kitchen Candles | gap | b1, b21 |
| `69522800000558` | Cat Food | gap | b1, b21 |
| `6971501227941` | Commodity marking-Cappuccino | gap | b1, b21 |
| `6971501229174` | Switch-Fan | transparent | d11, d110 |
| `6972842741066` | label-car | transparent | d11, d110 |
| `6972842743268` | PROPERTY LABEL | gap | — |
| `6972842748577` | Bakery-Price Label | gap | b1, b21 |
| `6975746632096` | Happy Easter | gap | b1, b21 |
| `6975746632140` | Cake | gap | b1, b21 |
| `6977031210569` | Clothing Storage | gap | b1, b21 |
| `6977031212037` | Product Name | gap | b1, b21 |
| `6977031212051` | Soap Table | gap | b1, b21 |
| `6977031214215` | Price tag | gap | b1, b21 |
| `6977031218343` | label-makeup | transparent | d11, d110 |
| `6977031219005` | candle-pure powder | gap | b1, b21 |
| `6977388391614` | label-Candle | gap | b1, b21 |
| `6978061953204` | price tag-macaroni | gap | b21 |
| `6978061956984` | Klow | gap | — |
| `6978061957028` | Price Tag | gap | — |

### 50x50 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `010424608` |  Price Label-baby socks | gap | b1, b21 |
| `03112116` | best dad ever | gap | b1, b21 |
| `101625194` | compound | gap | — |
| `112723291` | thank you | gap | b1, b21 |
| `6977031212075` | Give Thanks | gap | b1, b21 |
| `6977388391683` | Chocolate Strawberry | gap | b1, b21 |

### 50x70 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `091423020` | Information-Shampoo | gap | — |
| `11202062` | Fixed Assets-table | gap | b1, b21 |
| `6971501220577` | Information-Candy Cake | gap | b1, b21 |

### 50x80 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `051923030` | Commodity marking-Toner | transparent | b1, b21 |
| `10182102` | Fixed Asset-Property | gap | b1, b21 |
| `69522800000798` | Employee Activities-gift | gap | b1, b21 |
| `6971501220607` | Price Label-chocolate | gap | b1, b21 |

### 60x40 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `69522800011308` | commodity marking-decaf cold brew | gap | b1, b21 |
| `6978642801313` | Scented Candle | gap | — |

### 70x50 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `112723297` | CATERING BRANG | gap | b1, b21 |
| `6971501227712` | Bakery Brand | gap | b1, b21 |

### 70x80 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `6977031215786` | Ingredients | gap | — |

### 80x50 mm

| Barcode | Name | Paper | Bench |
|---|---|---|---|
| `01162101` | Spices and Herbs | transparent | b1, b21 |
| `04162113` | Promotion | gap | b1, b21 |
| `060923019` | This is my luggage | gap | — |

## Regenerating

Refresh the whole catalogue from the vendor cloud:

```sh
make labels
```

The script walks `industryTemplate/sizes` and then pages through `industryTemplate/page` for each size in both orientations. It needs no key and no account. It also writes `src/catalogue.json`, the copy the binary embeds, and this page, so the table the code reads and this one cannot drift apart. The rows in `added.json` that the listing lacks are kept.

Add the rolls a server saved from the cloud, from `.niimbench.rolls.json` in the folder it runs from:

```sh
make add-rolls
```

A roll's tag can carry a barcode the listing does not hold: one roll has several. When the server asks the cloud about one, it saves the answer. This asks the cloud for that barcode's full record, keeps it in `added.json`, and writes it into the catalogue. `ROLLS=` names another saved file, such as the app's under `~/.local/state/niimbench` or `~/Library/Application Support/niimbench`, or a barcode.

Check that the JSON, the embedded copy and this page agree:

```sh
make labels-check
```
