# ==================================================================
# 유료방송(IPTV/SO) 업계 뉴스 자동 수집 스크립트 - GitHub Actions 클라우드 실행용
# - RSS(전자신문/미디어스/미디어오늘) + 네이버뉴스 검색을 수집
# - IPTV/SO 관련 키워드로 필터링
# - '대가산정안','채널평가','채널퇴출','프로그램사용료' 포함 기사는 최상단 우선 노출
# - 결과를 index.html로 저장 (리포지토리 루트) - Vercel이 이 저장소를 보고 있어
#   .github/workflows/update-news.yml 이 커밋+푸시하면 자동 재배포됨
# - 이 파일은 로컬 PC가 아니라 GitHub의 클라우드 서버(러너)에서 3시간마다 실행되므로
#   PC를 꺼놔도 계속 갱신된다
# ==================================================================

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Actions 러너는 체크아웃한 저장소 루트가 현재 작업 폴더이므로 상대경로를 그대로 쓴다
$OutDir      = Get-Location
$ReportPath  = Join-Path $OutDir "index.html"
$LogPath     = Join-Path $OutDir "collect_log.txt"
$HistoryPath = Join-Path $OutDir "news_history.json"
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

# ------------------------------------------------------------------
# 키워드 정의
# ------------------------------------------------------------------
# 처음에 요청하신 '유료방송업계(IPTV/SO)' 그 자체를 가리키는 핵심 키워드.
# 이 목록에 걸리면 무조건 "핵심 유료방송 뉴스" 탭에도 들어간다.
$CoreIndustryKeywords = @(
    'IPTV','케이블방송','유료방송','종합유선방송','재송신','MSO','MPP',
    '프로그램사용료','채널평가','채널퇴출','대가산정','방송채널사용사업자',
    '스카이라이프','헬로비전','딜라이브','케이블TV','유료방송시장',
    '유료방송플랫폼','방송통신위원회','과기정통부','시청점유율','재허가',
    '유료방송가입자','디지털전환','실시간채널'
)
# 이후 대화에서 넓힌 범위(OTT/사업자/채널사/제작유통 등). 여전히 구체적 고유명사라 오탐 위험은 낮지만
# '핵심 유료방송' 탭이 아니라 '미디어·콘텐츠 전체' 탭에만 들어간다.
$ExtendedTopicKeywords = @(
    '웨이브','티빙','왓챠','디즈니플러스','쿠팡플레이',
    '망사용료','합산규제','인수합병','M&A',
    '외주제작','K-콘텐츠','K콘텐츠','방송광고',
    '홈쇼핑','T커머스',
    '유튜브','크리에이터',
    'SK브로드밴드','LG유플러스','현대HCN','티브로드','CJ ENM',
    'JTBC','tvN','채널A','TV조선','MBN','MBC','KBS','SBS'
)
$TopicKeywords = @($CoreIndustryKeywords + $ExtendedTopicKeywords)
# 사용자 요청으로 범위 확장(콘텐츠 회사라 시청률·콘텐츠·연예 뉴스도 관심 있음): 방송 맥락 조건 없이 그대로 인정
$BroadKeywords = @('미디어','방송사','콘텐츠','OTT','프로그램','넷플릭스','시청률','엔터테인먼트')
# 이 아래 '확장 매칭'(넓은 의미 키워드/고빈도 대기업명)에 공통으로 적용하는 제외어.
# '콘텐츠' 같은 단어는 건설사 마케팅·IT 보안/개인정보 뉴스에도 흔히 붙어 나오고,
# 'KT' 같은 단어는 야구단(kt wiz) 소식에도 흔히 붙어 나오므로 그런 무관한 카테고리는 제외한다.
$ExclusionKeywords = @(
    '건설','분양','아파트','부동산','시행사','시공','견본주택','재건축','재개발',
    'CSAM','앱스토어','해킹','랜섬웨어','피싱','개인정보','보안 취약점','악성코드',
    '야구단','프로야구','KBO','NPB','드래프트','위즈'
)
# 'KT','삼성','애플','SK텔레콤'은 사업 영역이 워낙 넓어(5G, 반도체, 스마트폰, 클라우드, 야구단 등)
# 이름만으로 인정하면 무관한 뉴스가 쏟아진다. 그래서 미디어/방송/콘텐츠 맥락 단어가 같이 나올 때만 인정한다.
$HighVolumeEntityKeywords = @('삼성','애플','SK텔레콤','SKT')
$MediaContextWords = @(
    '방송','채널','미디어','콘텐츠','OTT','IPTV','유료방송','케이블','넷플릭스',
    'TV','셋톱박스','스카이라이프','시청률','드라마','예능','스트리밍','엔터테인먼트'
)
$PriorityKeywords = @(
    '대가산정안','대가산정','채널평가','채널퇴출','프로그램사용료',
    # 사용자 요청으로 추가: IPTV/SO/PP 등 매출·실적 관련 뉴스도 핵심이슈로 표시
    # (이 목록은 이미 업계 관련으로 필터링된 기사에만 적용되므로 노이즈 걱정 없이 넓게 잡아도 됨)
    '매출','영업이익','영업익','실적'
)

# PP(방송채널사용사업자 - 지상파/종편/PP 등 채널·콘텐츠 공급사) 전용 탭 판정 키워드.
# SO/IPTV 플랫폼사와는 다른 축(채널을 만드는 쪽)이라 별도로 분리한다.
$PPKeywords = @(
    'MBC','KBS','SBS','JTBC','tvN','채널A','TV조선','MBN','CJ ENM',
    '방송채널사용사업자','채널평가','채널퇴출','프로그램사용료','MPP',
    'PP협의회','콘텐츠 사용료','대가산정','중복편성',
    # 사용자 요청으로 추가: 신규 콘텐츠·프로그램 제작 소식
    '편성표','제작발표회','신작 드라마','신작 예능','오리지널 콘텐츠','시즌2 제작','첫방송','편성 확정'
)

# "처음에 얘기했던 유료방송업계" 판정 - 핵심 키워드 목록에만 근거(확장 범위는 포함하지 않음)
function Test-CoreTopicMatch($text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($kw in $CoreIndustryKeywords) {
        if ($text.Contains($kw)) { return $true }
    }
    if ($text -match '(?<![A-Za-z0-9])SO(?![A-Za-z0-9])') { return $true }
    return $false
}

function Test-PPMatch($text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($kw in $PPKeywords) {
        if ($text.Contains($kw)) { return $true }
    }
    return $false
}

function Test-TopicMatch($text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($kw in $TopicKeywords) {
        if ($text.Contains($kw)) { return $true }
    }
    # 'SO'(케이블 플랫폼 약칭)는 영문 안에 낀 경우(SOC, SONY, ISO 등) 오탐이 많아 별도 처리
    if ($text -match '(?<![A-Za-z0-9])SO(?![A-Za-z0-9])') { return $true }

    $hasContext = $false
    foreach ($c in $MediaContextWords) {
        if ($text.Contains($c)) { $hasContext = $true; break }
    }

    # 아래 세 갈래(KT/고빈도 대기업/범용 키워드)는 전부 같은 제외어 검사를 통과해야 최종 인정된다
    $expandedMatch = $false
    if ($hasContext -and ($text -match '(?<![A-Za-z0-9])KT(?![A-Za-z0-9])')) { $expandedMatch = $true }
    if (-not $expandedMatch) {
        foreach ($kw in $HighVolumeEntityKeywords) {
            if ($hasContext -and $text.Contains($kw)) { $expandedMatch = $true; break }
        }
    }
    if (-not $expandedMatch) {
        foreach ($kw in $BroadKeywords) {
            if ($text.Contains($kw)) { $expandedMatch = $true; break }
        }
    }

    if ($expandedMatch) {
        foreach ($ex in $ExclusionKeywords) {
            if ($text.Contains($ex)) { return $false }
        }
        return $true
    }
    return $false
}

# 링크의 도메인은 오탐 가능성이 없는 유일하게 신뢰할 수 있는 출처 정보이므로
# (텍스트 근접도로 언론사명을 추측하는 방식은 다른 기사와 뒤섞이는 오류가 있어 폐기)
# 잘 알려진 도메인은 한글 매체명으로, 그 외는 도메인 그대로 표시한다.
$PressNameMap = @{
    'yna.co.kr'          = '연합뉴스'
    'mt.co.kr'           = '머니투데이'
    'edaily.co.kr'       = '이데일리'
    'fnnews.com'         = '파이낸셜뉴스'
    'digitaltoday.co.kr' = '디지털투데이'
    'etnews.com'         = '전자신문'
    'ddaily.co.kr'       = '디지털데일리'
    'mediaus.co.kr'      = '미디어스'
    'mediatoday.co.kr'   = '미디어오늘'
    'newsis.com'         = '뉴시스'
    'news1.kr'           = '뉴스1'
    'dealsite.co.kr'     = '딜사이트'
    'ebn.co.kr'          = 'EBN'
    'shinailbo.co.kr'    = '신아일보'
    'dailian.co.kr'      = '데일리안'
    'it.chosun.com'      = 'IT조선'
    'biz.chosun.com'     = '조선비즈'
    'zdnet.co.kr'        = 'ZDNet Korea'
    'techm.kr'           = '테크M'
    'koit.co.kr'         = 'KOIT'
    'sportschosun.com'   = '스포츠조선'
    'newsroad.co.kr'     = '뉴스로드'
    'junggi.co.kr'       = '중기이코노미'
    'thebigdata.co.kr'   = '빅데이터뉴스'
    'm-i.kr'             = '매일일보'
}

# 제목을 단어 단위로 쪼개 비슷한 기사(같은 사건을 여러 매체가 다룬 경우)를 찾기 위한 토큰화
function Get-TitleTokens($title) {
    $clean = $title -replace "[""'…·|/\[\]\(\)%↓↑!?<>“”‘’,.\-]", ' '
    $tokens = $clean -split '\s+' | Where-Object { $_.Length -ge 2 }
    return @($tokens)
}

# 제목에 등장하는 대표 사업자명을 잡아낸다. 같은 사업자를 다룬 기사는
# 표현이 서로 달라 단어 겹침만으로는 같은 묶음으로 못 잡는 경우가 많아
# (예: "영업이익 감소" vs "영업익 급감") 이 사업자명을 우선 신호로 사용한다.
$EntityAliasMap = [ordered]@{
    'KT스카이라이프' = '스카이라이프'
    '스카이라이프'   = '스카이라이프'
    'LG헬로비전'     = '헬로비전'
    'CJ헬로비전'     = '헬로비전'
    '헬로비전'       = '헬로비전'
    'SK브로드밴드'   = 'SK브로드밴드'
    'LG유플러스'     = 'LG유플러스'
    '현대HCN'        = '현대HCN'
    '티브로드'       = '티브로드'
    '딜라이브'       = '딜라이브'
    'CJ ENM'         = 'CJ ENM'
    'MBC'            = 'MBC'
    'KBS'            = 'KBS'
    'SBS'            = 'SBS'
    'JTBC'           = 'JTBC'
    'tvN'            = 'tvN'
    '채널A'          = '채널A'
    'TV조선'         = 'TV조선'
    'MBN'            = 'MBN'
    'SK텔레콤'       = 'SK텔레콤'
    'SKT'            = 'SK텔레콤'
    'KT'             = 'KT'
}
function Get-EntityKey($title) {
    foreach ($k in $EntityAliasMap.Keys) {
        if ($title.Contains($k)) { return $EntityAliasMap[$k] }
    }
    return $null
}

# 두 제목의 단어 겹침 비율(자카드 유사도) - 값이 클수록 같은 사건을 다룬 기사일 가능성이 높음
function Get-JaccardSim($tokensA, $tokensB) {
    if (-not $tokensA -or -not $tokensB -or $tokensA.Count -eq 0 -or $tokensB.Count -eq 0) { return 0 }
    $setA = @($tokensA | Select-Object -Unique)
    $setB = @($tokensB | Select-Object -Unique)
    $inter = @($setA | Where-Object { $setB -contains $_ }).Count
    $union = @(@($setA) + @($setB) | Select-Object -Unique).Count
    if ($union -eq 0) { return 0 }
    return [double]$inter / [double]$union
}

function Get-HostLabel($link) {
    try {
        $h = ([uri]$link).Host -replace '^www\.', ''
        if ($PressNameMap.ContainsKey($h)) { return $PressNameMap[$h] }
        return $h
    } catch { return "출처 미상" }
}

function Test-PriorityMatch($text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    foreach ($kw in $PriorityKeywords) {
        if ($text.Contains($kw)) { return $true }
    }
    return $false
}

# ------------------------------------------------------------------
# 날짜 파싱 헬퍼
# ------------------------------------------------------------------
function Parse-RssDate($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try {
        return [datetime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AllowWhiteSpaces)
    } catch { return $null }
}

# 네이버 검색결과의 상대시간 라벨(분/시간/일/주/개월/년 전)을 실제 날짜로 환산.
# 분/시간 단위는 시:분까지, 일 단위 이상은 '날짜'까지만 표기해 헛된 정밀함을 주지 않음.
function Resolve-NaverTime($rawLabel, $now) {
    if ([string]::IsNullOrWhiteSpace($rawLabel)) { return $null }
    $s = $rawLabel.Trim()

    # 검색결과 페이지의 다른 숫자(전화번호/ID 등)가 우연히 매칭돼 비정상적으로 큰 값이 들어오면
    # AddYears/AddMonths에서 DateTime 범위를 벗어나 예외가 나므로 전체를 try/catch로 감싸 방어
    try {
        if ($s -match '^(\d+)\s*분\s*전$') {
            $d = $now.AddMinutes(-[int]$Matches[1])
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("MM/dd HH:mm") }
        }
        if ($s -match '^(\d+)\s*시간\s*전$') {
            $d = $now.AddHours(-[int]$Matches[1])
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("MM/dd HH:mm") }
        }
        if ($s -match '^(\d+)\s*일\s*전$') {
            $d = $now.AddDays(-[int]$Matches[1])
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("MM/dd") + " (" + [int]$Matches[1] + "일 전)" }
        }
        if ($s -match '^(\d+)\s*주\s*전$') {
            $d = $now.AddDays(-7 * [int]$Matches[1])
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("MM/dd") }
        }
        if ($s -match '^(\d+)\s*(개월|달)\s*전$') {
            $n = [int]$Matches[1]
            if ($n -gt 1000) { return $null }
            $d = $now.AddMonths(-$n)
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("yyyy/MM/dd") }
        }
        if ($s -match '^(\d+)\s*년\s*전$') {
            $n = [int]$Matches[1]
            if ($n -gt 500) { return $null }
            $d = $now.AddYears(-$n)
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("yyyy/MM/dd") }
        }
        if ($s -match '^(\d{4})\.(\d{2})\.(\d{2})\.?$') {
            $d = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            return [PSCustomObject]@{ PubDate = $d; Display = $d.ToString("yyyy/MM/dd") }
        }
    } catch {
        return $null
    }
    return $null
}

# ------------------------------------------------------------------
# 결과 저장용 리스트
# ------------------------------------------------------------------
$Items = New-Object System.Collections.Generic.List[object]
# GitHub Actions 러너의 시스템 시각은 UTC라서, 한국 독자 기준 시각이 나오도록 고정 오프셋(UTC+9)으로 보정한다
# (한국은 서머타임이 없어 항상 UTC+9로 고정해도 안전함)
$Now = (Get-Date).ToUniversalTime().AddHours(9)

function Add-NewsItem($title, $link, $source, $pubDate, $displayTime) {
    if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($link)) { return }
    $title = $title.Trim()
    if ([string]::IsNullOrWhiteSpace($displayTime)) {
        $displayTime = if ($pubDate) { $pubDate.ToString("MM/dd HH:mm") } else { "시간 미상" }
    }
    $Items.Add([PSCustomObject]@{
        Title       = $title
        Link        = $link.Trim()
        Source      = $source
        PubDate     = $pubDate
        DisplayTime = $displayTime
        Priority    = (Test-PriorityMatch $title)
        IsCore      = (Test-CoreTopicMatch $title)
        IsPP        = (Test-PPMatch $title)
    })
}

# ------------------------------------------------------------------
# 이전 실행 결과 누적(히스토리) - 매 실행이 그 순간의 네이버 실시간 검색 결과에만 의존하면,
# 한동안 안 열어본 사이에 화제였다가 지나간 뉴스가 다음 실행에서 통째로 사라질 수 있다.
# 그래서 실행할 때마다 이전 결과를 불러와 새로 수집한 것과 합친 뒤 다시 저장한다.
# ------------------------------------------------------------------
function Load-History {
    $result = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $HistoryPath)) { return $result }
    try {
        $raw = Get-Content -Raw -Encoding UTF8 $HistoryPath | ConvertFrom-Json
        if ($null -eq $raw) { return $result }
        foreach ($r in @($raw)) {
            $pd = $null
            if ($r.PubDateIso) {
                try {
                    $pd = [datetime]::Parse($r.PubDateIso, [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
                } catch {}
            }
            $result.Add([PSCustomObject]@{
                Title       = $r.Title
                Link        = $r.Link
                Source      = $r.Source
                PubDate     = $pd
                DisplayTime = $r.DisplayTime
                Priority    = [bool]$r.Priority
                # 저장 이후 키워드 목록이 바뀌었을 수 있으니 핵심/PP 여부는 매번 다시 판정한다
                IsCore      = (Test-CoreTopicMatch $r.Title)
                IsPP        = (Test-PPMatch $r.Title)
            })
        }
    } catch {
        Write-Log ("히스토리 로드 실패: {0}" -f $_.Exception.Message)
    }
    return $result
}

function Save-History($items) {
    try {
        $toSave = @($items | ForEach-Object {
            [PSCustomObject]@{
                Title       = $_.Title
                Link        = $_.Link
                Source      = $_.Source
                PubDateIso  = if ($_.PubDate) { $_.PubDate.ToString("o") } else { $null }
                DisplayTime = $_.DisplayTime
                Priority    = [bool]$_.Priority
            }
        })
        $toSave | ConvertTo-Json -Depth 3 | Set-Content -Path $HistoryPath -Encoding UTF8
    } catch {
        Write-Log ("히스토리 저장 실패: {0}" -f $_.Exception.Message)
    }
}

# ------------------------------------------------------------------
# 1) RSS 피드 수집
# ------------------------------------------------------------------
$RssFeeds = @(
    @{ name = '전자신문';  url = 'https://rss.etnews.com/Section901.xml' },
    @{ name = '미디어스';  url = 'https://www.mediaus.co.kr/rss/allArticle.xml' },
    @{ name = '미디어오늘'; url = 'https://www.mediatoday.co.kr/rss/allArticle.xml' }
)

foreach ($feed in $RssFeeds) {
    try {
        $resp = Invoke-WebRequest -Uri $feed.url -UseBasicParsing -Headers @{ "User-Agent" = $UA } -TimeoutSec 15
        [xml]$xml = $resp.Content
        $count = 0
        foreach ($it in $xml.rss.channel.item) {
            $title = $it.title.InnerText
            $desc  = $it.description.InnerText
            $link  = $it.link
            $pub   = Parse-RssDate $it.pubDate
            if (Test-TopicMatch "$title $desc") {
                Add-NewsItem -title $title -link $link -source $feed.name -pubDate $pub
                $count++
            }
        }
        Write-Log ("RSS 수집: {0} -> {1}건 매칭" -f $feed.name, $count)
    } catch {
        Write-Log ("RSS 실패: {0} - {1}" -f $feed.name, $_.Exception.Message)
    }
}

# ------------------------------------------------------------------
# 2) 네이버 뉴스 검색 수집
# ------------------------------------------------------------------
$NaverQueries = @(
    'IPTV', '유료방송', 'SO 케이블방송', '케이블방송', '종합유선방송',
    'IPTV 가입자', '유료방송 재송신', '프로그램사용료', '채널평가', '채널퇴출',
    '대가산정안', '유료방송 실적', '스카이라이프', '헬로비전', '딜라이브',
    # 사용자 요청으로 범위 확장: 미디어/방송/OTT/콘텐츠 업계 + 연예뉴스까지 허용
    '미디어 업계', '방송사', '콘텐츠 업계', 'OTT', '넷플릭스', '방송 프로그램', '시청률', '엔터테인먼트',
    '웨이브 티빙', '왓챠 디즈니플러스', '쿠팡플레이', '망사용료', '합산규제', '인수합병 M&A',
    '외주제작', 'K콘텐츠', '방송광고', '홈쇼핑', '유튜브 크리에이터',
    # 사용자 요청으로 추가: 국내 유료방송사·채널사
    'KT', 'SK브로드밴드', 'LG유플러스 방송', 'MBC', 'KBS', 'SBS', 'JTBC',
    # PP(방송채널사용사업자) 탭 전용 검색어
    'PP협의회', 'MPP 채널', '콘텐츠 사용료 협상', '중복편성', 'tvN', 'CJ ENM 채널',
    '드라마 제작발표', '예능 신작', '오리지널 콘텐츠 제작', '편성 확정'
)

foreach ($q in $NaverQueries) {
    try {
        $url = "https://search.naver.com/search.naver?where=news&query=" + [uri]::EscapeDataString($q) + "&sort=1"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers @{ "User-Agent" = $UA } -TimeoutSec 15
        $html = $resp.Content

        $titleMatches = [regex]::Matches($html,
            '<a[^>]+href="(?<href>https?://[^"]+)"[^>]*data-heatmap-target="\.tit"><span[^>]*sds-comps-text-type-headline1"[^>]*>(?<title>.*?)</span>',
            [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $timeRegex  = [regex]'(\d+\s*(분|시간|일|주|개월|달|년)\s*전|\d{4}\.\d{2}\.\d{2}\.)'
        # 검색결과에 "네이버뉴스"로 연결되는 별도 링크가 있으면(대부분의 언론사가 네이버에 기사를 제휴 전송) 그 링크를 우선 사용
        $navLinkRegex = [regex]'<a[^>]+href="(?<href>https?://[^"]+)"[^>]*data-heatmap-target="\.nav"'

        $count = 0
        for ($i = 0; $i -lt $titleMatches.Count; $i++) {
            $rawTitle = $titleMatches[$i].Groups['title'].Value
            $title = [System.Net.WebUtility]::HtmlDecode(($rawTitle -replace '<[^>]+>', ''))
            $originalLink = $titleMatches[$i].Groups['href'].Value

            # 이 기사 항목이 시작하는 지점부터 다음 기사 시작 지점(또는 +1500자) 사이에서만 시간/네이버뉴스링크를 찾아
            # 다른 기사의 정보가 잘못 붙는 것을 방지
            $winStart = $titleMatches[$i].Index
            $winEnd   = if ($i + 1 -lt $titleMatches.Count) { $titleMatches[$i + 1].Index } else { [Math]::Min($html.Length, $winStart + 1500) }
            $window   = $html.Substring($winStart, [Math]::Max(0, $winEnd - $winStart))
            $tMatch   = $timeRegex.Match($window)
            $navMatch = $navLinkRegex.Match($window)

            # 출처(언론사명)는 항상 원본 언론사 도메인 기준으로 판단하되,
            # 실제로 클릭했을 때 열리는 링크는 네이버뉴스 링크가 있으면 그쪽을 사용
            $source = Get-HostLabel $originalLink
            $link = if ($navMatch.Success) { $navMatch.Groups['href'].Value } else { $originalLink }

            $pub = $null
            $disp = $null
            if ($tMatch.Success) {
                $resolved = Resolve-NaverTime $tMatch.Value $Now
                if ($resolved) {
                    $pub  = $resolved.PubDate
                    $disp = $resolved.Display
                }
            }

            if (Test-TopicMatch $title) {
                Add-NewsItem -title $title -link $link -source $source -pubDate $pub -displayTime $disp
                $count++
            }
        }
        Write-Log ("네이버 검색: '{0}' -> {1}건 매칭" -f $q, $count)
    } catch {
        Write-Log ("네이버 검색 실패: '{0}' - {1}" -f $q, $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 400
}

$HistoryItems = Load-History
foreach ($h in $HistoryItems) { $Items.Add($h) }
Write-Log ("히스토리 로드: {0}건 (신규 수집 {1}건과 합산)" -f $HistoryItems.Count, ($Items.Count - $HistoryItems.Count))

# ------------------------------------------------------------------
# 3) 중복 제거 + 필터링 + 정렬
# ------------------------------------------------------------------
$seenLinks  = New-Object 'System.Collections.Generic.HashSet[string]'
$seenTitles = New-Object 'System.Collections.Generic.HashSet[string]'
$deduped = New-Object System.Collections.Generic.List[object]

foreach ($it in $Items) {
    $normTitle = ($it.Title -replace '\s+', '')
    if ($seenLinks.Contains($it.Link)) { continue }
    if ($seenTitles.Contains($normTitle)) { continue }
    [void]$seenLinks.Add($it.Link)
    [void]$seenTitles.Add($normTitle)
    $deduped.Add($it)
}

# 누적 보관 기간(최근 7일). 발행시각을 확인하지 못한 기사는
# 오래된 기사가 몰래 섞여 들어오는 걸 막기 위해 화면에 내보내지 않는다.
$HistoryRetentionHours = 24 * 7
$cutoff = $Now.AddHours(-$HistoryRetentionHours)
$filtered = $deduped | Where-Object { $_.PubDate -and $_.PubDate -ge $cutoff }

$sorted = @($filtered | Sort-Object -Property `
    @{ Expression = { $_.Priority }; Descending = $true }, `
    @{ Expression = { $_.PubDate }; Descending = $true })

# ------------------------------------------------------------------
# 3-1) 같은 사건을 여러 매체가 동시에 보도한 "유사 기사 묶음"은 최대 5건까지만 노출.
#      (예: 실적 발표 하나를 10개 매체가 거의 같은 제목으로 보도하는 경우)
#      제목 단어 겹침이 임계치 이상이면 같은 묶음으로 보고, 나머지 자리는 다른 주제 기사로 채운다.
# ------------------------------------------------------------------
$SimilarityThreshold = 0.18
$MaxPerCluster = 5
$clusters = New-Object System.Collections.Generic.List[object]  # 각 원소: @{ Tokens = [];  }

foreach ($it in $sorted) {
    $tok = Get-TitleTokens $it.Title
    $ent = Get-EntityKey $it.Title
    $bestIdx = -1
    $bestSim = 0

    # 1순위: 같은 사업자명을 언급한 기존 묶음이 있으면 표현이 달라도 무조건 합류
    if ($ent) {
        for ($c = 0; $c -lt $clusters.Count; $c++) {
            if ($clusters[$c].Entity -eq $ent) { $bestIdx = $c; $bestSim = 1; break }
        }
    }
    # 2순위: 사업자명이 없거나 매칭되는 묶음이 없으면 제목 단어 겹침으로 판단
    if ($bestIdx -lt 0) {
        for ($c = 0; $c -lt $clusters.Count; $c++) {
            $sim = Get-JaccardSim $tok $clusters[$c].Tokens
            if ($sim -gt $bestSim) { $bestSim = $sim; $bestIdx = $c }
        }
    }

    if ($bestIdx -ge 0 -and $bestSim -ge $SimilarityThreshold) {
        # 묶음에 합류할 때마다 대표 단어집합을 합쳐서(누적) 이후 기사와의 비교 정확도를 높인다
        $clusters[$bestIdx].Tokens = @($clusters[$bestIdx].Tokens + $tok | Select-Object -Unique)
        if (-not $clusters[$bestIdx].Entity -and $ent) { $clusters[$bestIdx].Entity = $ent }
        $it | Add-Member -NotePropertyName ClusterId -NotePropertyValue $bestIdx -Force
    } else {
        $clusters.Add([PSCustomObject]@{ Tokens = $tok; Entity = $ent })
        $it | Add-Member -NotePropertyName ClusterId -NotePropertyValue ($clusters.Count - 1) -Force
    }
}

$clusterSeen = @{}
$capped = New-Object System.Collections.Generic.List[object]
foreach ($it in $sorted) {
    if (-not $clusterSeen.ContainsKey($it.ClusterId)) { $clusterSeen[$it.ClusterId] = 0 }
    if ($clusterSeen[$it.ClusterId] -lt $MaxPerCluster) {
        $capped.Add($it)
        $clusterSeen[$it.ClusterId]++
    }
}

# 화면에는 최대 10페이지(페이지당 10건)까지, 히스토리 파일에는 그보다 넉넉하게 보관해서
# 당장 화면에 없는 기사도 다음 실행에 다시 후보로 살아있게 한다.
$MaxDisplayItems = 100
$MaxStoredHistoryCore = 200
$MaxStoredHistoryPP   = 200
$MaxStoredHistoryRest = 300

# PowerShell은 결과가 1건뿐이면 배열이 아닌 단일 객체를 반환해 .Count가 비어버리므로 @()로 강제 배열화
$final = @($capped | Select-Object -First $MaxDisplayItems)
# 핵심/PP 탭은 서로 겹칠 수 있다(예: '채널퇴출' 기사는 핵심 유료방송이자 PP 뉴스이기도 함) - 화면 표시는 겹쳐도 자연스러움
$coreFinal = @($capped | Where-Object { $_.IsCore } | Select-Object -First $MaxDisplayItems)
$ppFinal   = @($capped | Where-Object { $_.IsPP } | Select-Object -First $MaxDisplayItems)

# 저장 공간은 세 카테고리(핵심/PP/그 외)를 서로 겹치지 않게 나눠서 예산을 확보한다.
# 물량이 많은 카테고리가 저장공간을 다 차지해서 물량 적은 카테고리가 7일도 못 채우고
# 밀려나는 걸 막기 위함(핵심 유료방송 문제로 이미 한 번 겪은 문제라 PP도 동일하게 분리).
$storedCore = @($capped | Where-Object { $_.IsCore } | Select-Object -First $MaxStoredHistoryCore)
$storedPP   = @($capped | Where-Object { $_.IsPP -and -not $_.IsCore } | Select-Object -First $MaxStoredHistoryPP)
$storedRest = @($capped | Where-Object { -not $_.IsCore -and -not $_.IsPP } | Select-Object -First $MaxStoredHistoryRest)
$storedList = @($storedCore + $storedPP + $storedRest)

Save-History $storedList

Write-Log ("최종 수집 {0}건(핵심 {1}건, PP {2}건) (수집 총 {3}건 -> 중복제거 {4}건 -> 유사기사묶음 상한적용 전 {5}건 -> 적용 후 {6}건, 묶음 {7}개, 히스토리저장 {8}건)" `
    -f $final.Count, $coreFinal.Count, $ppFinal.Count, $Items.Count, $deduped.Count, $sorted.Count, $capped.Count, $clusters.Count, $storedList.Count)

# ------------------------------------------------------------------
# 4) HTML 리포트 생성
# ------------------------------------------------------------------
function HtmlEscape($s) {
    if ($null -eq $s) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

# 기사 수가 많을 때 한 화면에 다 몰아넣지 않고 페이지를 나눠서 보여준다(탭마다 별도 페이지네이션)
$PageSize = 10
function Build-RowsHtml($list, $emptyMsg) {
    $sb = New-Object System.Text.StringBuilder
    if ($list.Count -eq 0) {
        [void]$sb.Append("<p class='empty'>$emptyMsg</p>")
        return $sb.ToString()
    }
    $idx = 0
    foreach ($it in $list) {
        $idx++
        $page = [Math]::Ceiling($idx / $PageSize)
        $timeStr = $it.DisplayTime
        $badge = if ($it.Priority) { "<span class='badge'>🔥 핵심이슈</span>" } else { "" }
        $rowClass = if ($it.Priority) { "row priority" } else { "row" }
        [void]$sb.Append("<li class='$rowClass' data-page='$page'>")
        [void]$sb.Append("$badge<a class='headline' href='$(HtmlEscape $it.Link)' target='_blank' rel='noopener'>$(HtmlEscape $it.Title)</a>")
        [void]$sb.Append("<div class='meta'><span class='source'>$(HtmlEscape $it.Source)</span><span class='dot'>·</span><span class='time'>$timeStr</span></div>")
        [void]$sb.Append("</li>")
    }
    return $sb.ToString()
}

$coreRowsHtml = Build-RowsHtml $coreFinal "최근 7일 내 핵심 유료방송(IPTV/SO) 뉴스가 없습니다."
$ppRowsHtml   = Build-RowsHtml $ppFinal "최근 7일 내 PP(방송채널사용사업자) 관련 뉴스가 없습니다."
$allRowsHtml  = Build-RowsHtml $final "최근 7일 내 수집된 관련 뉴스가 없습니다."

$KoCulture = [System.Globalization.CultureInfo]::GetCultureInfo("ko-KR")
$updatedStr = $Now.ToString("yyyy-MM-dd (ddd) HH:mm", $KoCulture)

$html = @"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tcast Media news clipping(IPTV/SO/PP)</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 0;
    font-family: -apple-system, "Segoe UI", "Malgun Gothic", "맑은 고딕", sans-serif;
    background: #f4f5f7; color: #1a1a1a;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #15171c; color: #e6e6e6; }
    .card { background: #1f2229 !important; border-color: #2c303a !important; }
    .row { border-bottom-color: #2a2d35 !important; }
    .meta { color: #9aa0aa !important; }
    header { background: linear-gradient(135deg,#c2116b,#8e0e50) !important; }
  }
  header {
    background: linear-gradient(135deg,#ec1e79,#c2116b);
    color: #fff; padding: 28px 20px 22px;
  }
  header h1 { margin: 0 0 4px; font-size: 21px; font-weight: 800; letter-spacing: -0.01em; line-height: 1.25; }
  header .subtitle {
    margin: 3px 0 6px; font-size: 14.5px; font-weight: 600; opacity: 0.95;
    display: flex; align-items: baseline; gap: 6px; flex-wrap: wrap;
  }
  header .subtitle .tag { font-size: 12px; font-weight: 500; opacity: 0.8; }
  header .credit { margin: 0 0 6px; font-size: 11.5px; opacity: 0.75; letter-spacing: 0.02em; }
  header .updated { font-size: 13px; opacity: 0.9; }
  .wrap { max-width: 720px; margin: 0 auto; padding: 16px; }
  .card {
    background: #fff; border: 1px solid #e5e7eb; border-radius: 12px;
    padding: 4px 0; margin-top: -18px; box-shadow: 0 4px 16px rgba(0,0,0,0.08);
  }
  ul { list-style: none; margin: 0; padding: 0; }
  .row { padding: 14px 18px; border-bottom: 1px solid #eee; }
  .row:last-child { border-bottom: none; }
  .row.priority { background: rgba(239,68,68,0.06); }
  .badge {
    display: inline-block; background: #ef4444; color: #fff; font-size: 11px;
    padding: 2px 7px; border-radius: 10px; margin-right: 6px; vertical-align: middle;
  }
  .headline { text-decoration: none; color: inherit; font-size: 15px; font-weight: 600; line-height: 1.4; }
  .headline:hover { text-decoration: underline; color: #2563eb; }
  .meta { margin-top: 6px; font-size: 12px; color: #6b7280; }
  .dot { margin: 0 6px; }
  .empty { padding: 30px; text-align: center; color: #888; }
  footer { text-align: center; font-size: 12px; color: #999; padding: 18px; }
  .headerRow { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
  .refresh-btn {
    display: inline-flex; align-items: center; justify-content: center;
    width: 42px; height: 42px; flex: 0 0 auto; padding: 0;
    background: rgba(255,255,255,0.15); color: #fff; border: 1px solid rgba(255,255,255,0.45);
    border-radius: 10px; font-size: 20px; cursor: pointer;
    font-family: inherit; line-height: 1;
  }
  .refresh-btn:hover { background: rgba(255,255,255,0.28); }
  .refresh-btn:active { transform: scale(0.97); }
  .refresh-btn.spin .icon { display: inline-block; animation: spin 0.7s linear; }
  @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
  .pager {
    display: none; align-items: center; justify-content: center; gap: 14px;
    padding: 14px 18px; border-top: 1px solid #eee;
  }
  .pager button {
    background: #fff; border: 1px solid #d1d5db; border-radius: 8px;
    padding: 6px 14px; font-size: 13px; cursor: pointer; font-family: inherit;
  }
  .pager button:hover:not(:disabled) { background: #f3f4f6; }
  .pager button:disabled { opacity: 0.4; cursor: default; }
  .pager .pageIndicator { font-size: 13px; color: #555; min-width: 54px; text-align: center; font-variant-numeric: tabular-nums; }
  @media (prefers-color-scheme: dark) {
    .pager { border-top-color: #2a2d35; }
    .pager button { background: #262a31; border-color: #3a3f47; color: #e6e6e6; }
    .pager .pageIndicator { color: #aaa; }
  }
  .tabs { display: flex; gap: 8px; margin: 14px auto 0; max-width: 720px; padding: 0 16px; }
  .tab-btn {
    flex: 1; padding: 9px 4px; border-radius: 10px 10px 0 0; border: 1px solid #e5e7eb; border-bottom: none;
    background: #e9ebef; color: #555; font-size: 12.5px; font-weight: 600; cursor: pointer; font-family: inherit;
    white-space: nowrap;
  }
  .tab-btn.active { background: #fff; color: #1a1a1a; }
  @media (prefers-color-scheme: dark) {
    .tab-btn { background: #171a1f; color: #9aa0aa; border-color: #2c303a; }
    .tab-btn.active { background: #1f2229; color: #e6e6e6; }
  }
  .tab-section { display: none; }
  .tab-section.active { display: block; }
</style>
</head>
<body>
<header>
  <div class="headerRow">
    <div>
      <h1>📡 Tcast Media news clipping</h1>
      <p class="credit">페이지 만든이: Tcast 매체영업팀</p>
    </div>
    <button class="refresh-btn" id="refreshBtn" onclick="doRefresh()" aria-label="새로고침" title="새로고침"><span class="icon">🔄</span></button>
  </div>
  <div class="updated">마지막 업데이트: $updatedStr · 핵심 $($coreFinal.Count)건 · PP $($ppFinal.Count)건 · 전체 $($final.Count)건 · 최근 7일 누적</div>
</header>
<div class="tabs">
  <button class="tab-btn active" id="tabBtnAll" onclick="showTab('all')">🆕 최신 뉴스</button>
  <button class="tab-btn" id="tabBtnCore" onclick="showTab('core')">📡 핵심 유료방송</button>
  <button class="tab-btn" id="tabBtnPP" onclick="showTab('pp')">🎬 PP 소식</button>
</div>
<div class="wrap" style="margin-top:0; padding-top:0;">
  <div class="tab-section active" id="allSection">
    <div class="card" style="margin-top:0;">
      <ul id="allList">
        $allRowsHtml
      </ul>
      <div class="pager" id="allPager">
        <button id="allPrevBtn" onclick="gotoPage('all', currentPage.all - 1)">이전</button>
        <span class="pageIndicator" id="allPageIndicator"></span>
        <button id="allNextBtn" onclick="gotoPage('all', currentPage.all + 1)">다음</button>
      </div>
    </div>
  </div>
  <div class="tab-section" id="coreSection">
    <div class="card" style="margin-top:0;">
      <ul id="coreList">
        $coreRowsHtml
      </ul>
      <div class="pager" id="corePager">
        <button id="corePrevBtn" onclick="gotoPage('core', currentPage.core - 1)">이전</button>
        <span class="pageIndicator" id="corePageIndicator"></span>
        <button id="coreNextBtn" onclick="gotoPage('core', currentPage.core + 1)">다음</button>
      </div>
    </div>
  </div>
  <div class="tab-section" id="ppSection">
    <div class="card" style="margin-top:0;">
      <ul id="ppList">
        $ppRowsHtml
      </ul>
      <div class="pager" id="ppPager">
        <button id="ppPrevBtn" onclick="gotoPage('pp', currentPage.pp - 1)">이전</button>
        <span class="pageIndicator" id="ppPageIndicator"></span>
        <button id="ppNextBtn" onclick="gotoPage('pp', currentPage.pp + 1)">다음</button>
      </div>
    </div>
  </div>
  <footer>3시간마다 자동 갱신(GitHub Actions 클라우드에서 실행 · PC와 무관하게 항상 최신 상태) · 최근 7일간 누적 · 최대 10페이지까지 보관<br>🔥 핵심이슈 = 대가산정안/채널평가/채널퇴출/프로그램사용료 관련 기사 · 새로고침 버튼은 마지막으로 저장된 최신본을 다시 불러옵니다.</footer>
</div>
<script>
function doRefresh() {
  var btn = document.getElementById('refreshBtn');
  btn.classList.add('spin');
  setTimeout(function () { location.reload(); }, 300);
}

function showTab(name) {
  document.getElementById('coreSection').classList.toggle('active', name === 'core');
  document.getElementById('allSection').classList.toggle('active', name === 'all');
  document.getElementById('ppSection').classList.toggle('active', name === 'pp');
  document.getElementById('tabBtnCore').classList.toggle('active', name === 'core');
  document.getElementById('tabBtnAll').classList.toggle('active', name === 'all');
  document.getElementById('tabBtnPP').classList.toggle('active', name === 'pp');
}

var currentPage = { core: 1, all: 1, pp: 1 };

function gotoPage(scope, p) {
  var rows = document.querySelectorAll('#' + scope + 'List li');
  var maxPage = 1;
  rows.forEach(function (r) {
    var pg = parseInt(r.getAttribute('data-page'), 10) || 1;
    if (pg > maxPage) { maxPage = pg; }
  });
  if (p < 1) { p = 1; }
  if (p > maxPage) { p = maxPage; }
  currentPage[scope] = p;
  rows.forEach(function (r) {
    var pg = parseInt(r.getAttribute('data-page'), 10) || 1;
    r.style.display = (pg === p) ? '' : 'none';
  });
  var indicator = document.getElementById(scope + 'PageIndicator');
  var prevBtn = document.getElementById(scope + 'PrevBtn');
  var nextBtn = document.getElementById(scope + 'NextBtn');
  var pager = document.getElementById(scope + 'Pager');
  if (indicator) { indicator.textContent = p + ' / ' + maxPage; }
  if (prevBtn) { prevBtn.disabled = (p === 1); }
  if (nextBtn) { nextBtn.disabled = (p === maxPage); }
  if (pager) { pager.style.display = (maxPage > 1) ? 'flex' : 'none'; }
}

gotoPage('core', 1);
gotoPage('all', 1);
gotoPage('pp', 1);
</script>
</body>
</html>
"@

Set-Content -Path $ReportPath -Value $html -Encoding UTF8
Write-Log "리포트 생성 완료: $ReportPath"
# git add/commit/push는 이 스크립트가 아니라 .github/workflows/update-news.yml 워크플로우가 담당한다
