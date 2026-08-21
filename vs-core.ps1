<#
================================================================================
  vs-core.ps1  —  Vanilla Sky 监测共享核心
  本机脚本（VanillaSky-放票监测-V2.ps1）和云端脚本（cloud\watch-once.ps1）
  都 dot-source 这个文件，保证两边判定逻辑永远一致。

  自己不做任何事，只提供四个函数：
    New-VSSession       建一个会话（拿 cookie 和 form_build_id）
    Test-Availability   查一个班次有没有票
    Get-MaxSeats        最多能几个人一起订
    Send-Bark           推一条 Bark
================================================================================
#>

# Linux 上的 PowerShell 7 没有这个开关，包一层 try 免得云端跑不起来
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

$Global:VSBase = 'https://ticket.vanillasky.ge'
$Global:VSUA   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

# 机场代码。1=Tbilisi 是个死选项，任何日期任何组合都无票，别用。
$Global:VSAirports = @{
    '2' = 'Ambrolauri'; '4' = 'Batumi'; '5' = 'Kutaisi'
    '6' = 'Mestia';     '7' = 'Natakhtari'
}

function Get-VSAirport {
    param([string]$Code)
    if ($Global:VSAirports.ContainsKey($Code)) { $Global:VSAirports[$Code] } else { $Code }
}

# Windows PowerShell 5.1 和 PowerShell 7 拿最终 URL 的方式不一样，两个都试
function Get-VSFinalUri {
    param($Response)
    try { if ($Response.BaseResponse.ResponseUri) { return "$($Response.BaseResponse.ResponseUri)" } } catch { }
    try { if ($Response.BaseResponse.RequestMessage.RequestUri) { return "$($Response.BaseResponse.RequestMessage.RequestUri)" } } catch { }
    return ''
}

<#
  建一个会话：GET 一次搜索页，留下 cookie，顺便把 form_build_id 抠出来。

  实测这个 form_build_id 可以在同一会话里连续复用于多次查询，
  所以一轮监测只需要建一次会话，四条腿共用，能省掉四次 GET。
  返回 @{ Session = ...; BuildId = ... }，失败返回 $null。
#>
function New-VSSession {
    param([int]$TimeoutSec = 30)
    $session = $null
    try {
        $g = Invoke-WebRequest -Uri "$Global:VSBase/en/tickets" -SessionVariable session `
             -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent $Global:VSUA
    } catch {
        return $null
    }
    $m = [regex]::Match($g.Content, '<input[^>]*name="form_build_id"[^>]*value="([^"]+)"')
    if (-not $m.Success) {
        $m = [regex]::Match($g.Content, '<input[^>]*value="([^"]+)"[^>]*name="form_build_id"')
    }
    if (-not $m.Success) { return $null }
    return @{ Session = $session; BuildId = $m.Groups[1].Value }
}

<#
  查一个班次。返回 hashtable：
    State  = AVAILABLE | NONE | ERROR | UNKNOWN
    Detail = 给人看的一行字，例如 "11:00 90GEL"
    Time / Price / Count = 拆开的字段，报警文案用

  原理：订票站是 Drupal，查询只能 POST /en/tickets，GET 带参数无效。
  POST 之后跳到 /en/flights-form，读那一页判定。

  -Ctx 传 New-VSSession 的返回值就复用会话；不传就自己建一个（一次性）。
  复用的会话如果被站方判成失效，会自动换新会话重试一次，并就地更新 -Ctx，
  所以调用方不用管这件事。
#>
function Test-Availability {
    param(
        [Parameter(Mandatory)][string]$Dep,
        [Parameter(Mandatory)][string]$Arr,
        [Parameter(Mandatory)][string]$Date,   # 必须是 mm/dd/yyyy
        [int]$Pax = 1,
        [hashtable]$Ctx,
        [int]$TimeoutSec = 30
    )

    $reused = $true
    if (-not $Ctx) {
        $reused = $false
        $Ctx = New-VSSession -TimeoutSec $TimeoutSec
        if (-not $Ctx) { return @{ State = 'ERROR'; Detail = '建会话失败（GET 不到搜索页，或页面里没有 form_build_id）' } }
    }

    $fields = [ordered]@{
        'types'                = '0'          # 0 = 单程, 1 = 往返
        'departure'            = $Dep
        'arrive'               = $Arr
        'date_picker'          = $Date
        'date_picker_arrive'   = $Date
        'person_count'         = "$Pax"
        'person_types[adult]'  = "$Pax"
        'person_types[child]'  = '0'
        'person_types[infant]' = '0'
        'op'                   = ''
        'form_build_id'        = $Ctx.BuildId
        'form_id'              = 'form_select_date'
    }

    $post = {
        param($buildId, $session)
        $fields['form_build_id'] = $buildId
        $body = ($fields.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f [uri]::EscapeDataString($_.Key), [uri]::EscapeDataString($_.Value)
        }) -join '&'
        Invoke-WebRequest -Uri "$Global:VSBase/en/tickets" -Method Post -Body $body `
            -WebSession $session -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent $Global:VSUA `
            -ContentType 'application/x-www-form-urlencoded'
    }

    try {
        $r = & $post $Ctx.BuildId $Ctx.Session
    } catch {
        return @{ State = 'ERROR'; Detail = "POST 失败: $($_.Exception.Message)" }
    }

    # 落回搜索页（还有 date_picker 输入框）= 表单被退回来了。
    # 复用会话时这多半是 form_build_id 过期，换个新会话重试一次就好。
    if ($r.Content -match 'name="date_picker"' -and $reused) {
        $fresh = New-VSSession -TimeoutSec $TimeoutSec
        if ($fresh) {
            $Ctx.Session = $fresh.Session      # 就地更新，后面几条腿直接用新的
            $Ctx.BuildId = $fresh.BuildId
            try { $r = & $post $fresh.BuildId $fresh.Session }
            catch { return @{ State = 'ERROR'; Detail = "重试 POST 失败: $($_.Exception.Message)" } }
        }
    }

    $html  = $r.Content
    $final = Get-VSFinalUri $r

    if ($html -match 'NO AVAILABLE TICKETS') {
        return @{ State = 'NONE'; Detail = '' }
    }
    if ($html -match 'name="date_picker"') {
        return @{ State = 'ERROR'; Detail = '表单被退回，没跳到结果页（参数或站点结构可能变了）' }
    }

    # 结果页真实结构：<span class="flight-item-small">September 27</span> 11:00 ... 90GEL
    $times  = [regex]::Matches($html, '<span class="flight-dates">\s*<span class="flight-item-small">[^<]*</span>\s*(\d{1,2}:\d{2})')
    $prices = [regex]::Matches($html, '<span class="gel style-price-box">\s*(\d{1,4})\s*GEL')

    # 精确匹配失败就退回宽松正则，站点改版也不至于当场瞎掉
    $time  = ''
    $price = ''
    if ($times.Count)  { $time  = $times[0].Groups[1].Value }  else { $time  = [regex]::Match($html, '(\d{1,2}:\d{2})').Value }
    if ($prices.Count) { $price = $prices[0].Groups[1].Value + 'GEL' } else { $price = [regex]::Match($html, '(\d{1,4})\s*GEL').Value }

    if ($final -match '/en/flights-form' -and $time -and $price) {
        $extra = ''
        if ($times.Count -gt 1) { $extra = "（当天 $($times.Count) 班）" }
        return @{
            State  = 'AVAILABLE'
            Detail = ('{0}  {1}{2}' -f $time, $price, $extra)
            Time   = $time
            Price  = $price
            Count  = $times.Count
        }
    }

    return @{ State = 'UNKNOWN'; Detail = "结果页读不出票价+时间（url=$final，长度 $($html.Length)）" }
}

<#
  最多能几个人一起订。
  结果页不显示余座数，所以只能按人数逐个试。4 → 3 → 2，都不行就是只有 1 座。
  只在已经确认有票（1 人查询命中）之后才调用，日常轮询不会跑到这里。
#>
function Get-MaxSeats {
    param(
        [Parameter(Mandatory)][string]$Dep,
        [Parameter(Mandatory)][string]$Arr,
        [Parameter(Mandatory)][string]$Date,
        [int]$Max = 4,
        [hashtable]$Ctx
    )
    for ($n = $Max; $n -ge 2; $n--) {
        $r = Test-Availability -Dep $Dep -Arr $Arr -Date $Date -Pax $n -Ctx $Ctx
        if ($r.State -eq 'AVAILABLE') { return $n }
        Start-Sleep -Milliseconds 600
    }
    return 1
}

<#
  把 key 和服务器地址整理成能用的形式。

  Bark App 首页给的是一整条 https://api.day.app/XXXXXXXX/ ，
  很容易连着 https:// 一起抄进配置里 —— 那样会拼出
  https://api.day.app/https://api.day.app/XXXXXXXX/... ，站方直接 404，
  而且平时全是「无票」根本不推送，等到真放票那天才发现推不出去。
  所以这里做兼容：整条 URL、去掉协议的、光秃秃的 key，三种都认。
#>
function Resolve-BarkTarget {
    param([string]$Key, [string]$Server = 'https://api.day.app')

    $k = ($Key + '').Trim().Trim('/')
    $s = ($Server + '').Trim().TrimEnd('/')
    if (-not $s) { $s = 'https://api.day.app' }

    # 填的是一整条 URL：从里面把服务器和 key 拆出来，服务器以 key 里带的为准
    if ($k -match '^https?://') {
        try {
            $u = [uri]$k
            $s = '{0}://{1}' -f $u.Scheme, $u.Authority
            $seg = @($u.AbsolutePath.Split('/') | Where-Object { $_ })
            if ($seg.Count) { $k = $seg[-1] } else { $k = '' }
        } catch { }
    }
    # 填成了 api.day.app/XXXX 这种没协议的
    elseif ($k -like '*/*') {
        $seg = @($k.Split('/') | Where-Object { $_ })
        if ($seg.Count) { $k = $seg[-1] }
    }

    return @{ Server = $s; Key = $k }
}

function Get-MaskedKey {
    param([string]$Key)
    if ($Key.Length -le 6) { return '***' }
    return $Key.Substring(0, 3) + ('*' * ($Key.Length - 6)) + $Key.Substring($Key.Length - 3)
}

<#
  把 -Key 里的东西摊平成一串 key。

  接受：单个字符串、数组、逗号/分号/换行分隔的一串。
  最后一种是给云端用的 —— GitHub Secret 只能存一个值，
  多个人收推送时就往里塞 "key1,key2"。
#>
function Expand-BarkKeys {
    param($Key)
    $out = @()
    foreach ($k in @($Key)) {
        if (-not $k) { continue }
        foreach ($piece in ("$k" -split '[,;\r\n]')) {
            $p = $piece.Trim()
            if ($p) { $out += $p }
        }
    }
    return @($out | Select-Object -Unique)
}

<#
  推 Bark。-Key 可以给多个（见 Expand-BarkKeys），会逐个推。

  返回：只要有一个推成功就是 $true。
  这个「有一个就算成功」是有意的 —— 朋友的 key 填错了不该把你自己的通知
  也一起判成失败。但每个失败的都会单独打一行，不会被吞掉。
#>
function Send-Bark {
    param(
        $Key,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string]$Server = 'https://api.day.app',
        [switch]$Critical
    )

    $keys = Expand-BarkKeys $Key
    if (-not $keys.Count) { return $false }

    $okCount = 0
    foreach ($k in $keys) {
        $t = Resolve-BarkTarget -Key $k -Server $Server
        if (-not $t.Key) { continue }
        try {
            $u = '{0}/{1}/{2}/{3}' -f $t.Server, $t.Key,
                 [uri]::EscapeDataString($Title), [uri]::EscapeDataString($Body)
            # critical + call=1 会无视静音和专注模式持续响，这是唯一能把人从睡眠里叫醒的通道
            if ($Critical) { $u += '?level=critical&volume=8&call=1&group=VanillaSky' }
            else           { $u += '?group=VanillaSky' }
            Invoke-RestMethod -Uri $u -TimeoutSec 15 | Out-Null
            $okCount++
        } catch {
            Write-Host "  -> Bark 推送失败（$(Get-MaskedKey $t.Key)）: $($_.Exception.Message)" -ForegroundColor DarkYellow
            if ($_.Exception.Message -match '404') {
                Write-Host '     404 一般就是这个 key 抄错了。' -ForegroundColor DarkYellow
            }
        }
    }
    return ($okCount -gt 0)
}
