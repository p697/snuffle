import Foundation

/// The App Store's storefronts. App Store Connect reports review territories as ISO 3166 alpha-3 codes; the public
/// App Store and Foundation use alpha-2.
public enum Territory {
    public static func alpha2(fromAlpha3 code: String) -> String? {
        table[code.uppercased()]
    }

    public static func alpha3(fromAlpha2 code: String) -> String? {
        byAlpha2[code.uppercased()]
    }

    /// Every storefront, as the public App Store names them in its URLs: lowercase alpha-2.
    public static let storefronts: [String] = table.values.map { $0.lowercased() }.sorted()

    static let byAlpha2: [String: String] = Dictionary(table.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })

    static let table: [String: String] = {
        let pairs = """
        AFG AF,ALB AL,DZA DZ,AGO AO,AIA AI,ATG AG,ARG AR,ARM AM,AUS AU,AUT AT,AZE AZ,BHS BS,BHR BH,BGD BD,BRB BB,BLR BY,BEL BE,BLZ BZ,\
        BEN BJ,BMU BM,BTN BT,BOL BO,BIH BA,BWA BW,BRA BR,VGB VG,BRN BN,BGR BG,BFA BF,KHM KH,CMR CM,CAN CA,CPV CV,CYM KY,TCD TD,CHL CL,\
        CHN CN,COL CO,COD CD,COG CG,CRI CR,CIV CI,HRV HR,CYP CY,CZE CZ,DNK DK,DMA DM,DOM DO,ECU EC,EGY EG,SLV SV,EST EE,SWZ SZ,FJI FJ,\
        FIN FI,FRA FR,GAB GA,GMB GM,GEO GE,DEU DE,GHA GH,GRC GR,GRD GD,GTM GT,GNB GW,GUY GY,HND HN,HKG HK,HUN HU,ISL IS,IND IN,IDN ID,\
        IRQ IQ,IRL IE,ISR IL,ITA IT,JAM JM,JPN JP,JOR JO,KAZ KZ,KEN KE,KOR KR,XKS XK,KWT KW,KGZ KG,LAO LA,LVA LV,LBN LB,LBR LR,LBY LY,\
        LTU LT,LUX LU,MAC MO,MDG MG,MWI MW,MYS MY,MDV MV,MLI ML,MLT MT,MRT MR,MUS MU,MEX MX,FSM FM,MDA MD,MNG MN,MNE ME,MSR MS,MAR MA,\
        MOZ MZ,MMR MM,NAM NA,NRU NR,NPL NP,NLD NL,NZL NZ,NIC NI,NER NE,NGA NG,MKD MK,NOR NO,OMN OM,PAK PK,PLW PW,PAN PA,PNG PG,PRY PY,\
        PER PE,PHL PH,POL PL,PRT PT,QAT QA,ROU RO,RUS RU,RWA RW,KNA KN,LCA LC,VCT VC,WSM WS,STP ST,SAU SA,SEN SN,SRB RS,SYC SC,SLE SL,\
        SGP SG,SVK SK,SVN SI,SLB SB,ZAF ZA,ESP ES,LKA LK,SUR SR,SWE SE,CHE CH,TWN TW,TJK TJ,TZA TZ,THA TH,TON TO,TTO TT,TUN TN,TUR TR,\
        TKM TM,TCA TC,UGA UG,UKR UA,ARE AE,GBR GB,USA US,URY UY,UZB UZ,VUT VU,VEN VE,VNM VN,YEM YE,ZMB ZM,ZWE ZW,PSE PS,SOM SO,SDN SD
        """
        var table: [String: String] = [:]
        for pair in pairs.split(separator: ",") {
            let parts = pair.split(separator: " ")
            if parts.count == 2 { table[String(parts[0])] = String(parts[1]) }
        }
        return table
    }()
}
