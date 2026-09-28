<#
================================================================================
  watch-once.ps1  —  云端兜底
  给 GitHub Actions 用（ubuntu-latest + pwsh）。

  Bark key 从环境变量 BARK_KEY 读，别写进文件里。

  【2026-08-23 改：一次触发覆盖一小时，别再指望 cron 的频率】

    原来是「查一轮就退出」，靠 workflow 里的 cron 来控制密度：
    密档 */15、疏档每小时，设计上 57 次/天。

    实测完全不是这么回事 —— 8/22 只触发 19 次、8/23 到傍晚 8 次，
    密档那条 */15 被 GitHub 整条压成了大约一小时一次，最大空档 224 分钟。
    这是 GitHub 对 public repo 的 schedule 的既有行为：best-effort，
    高频 cron 会被直接丢弃。**指望 cron 给你 15 分钟一次是不成立的。**

    所以改成：cron 只负责「把这个 job 拉起来」，密度由 job 自己在内部
    循环控制。一次触发跑 VS_LOOP_MINUTES 分钟，期间每隔几分钟查一轮。
    GitHub 一小时肯给一次触发是稳的，这样实际检查密度就回到了设计值。

  【推送冷却】
    改成循环之后，一次命中在同一次触发里会被反复查到（35 分钟约 6 轮）。
    原来一轮一推没问题（一小时才一轮），现在照推就是连着好几条 critical。
    天天亮屏的通知会被静音，真正要命的那条也就跟着废了 —— 这个项目里
    到处都在防这件事。所以同一条腿在 VS_PUSH_COOLDOWN_MIN 分钟内只推一次。
    不同的腿互不影响，漏不掉。

  【环境变量】
    BARK_KEY                Bark key（仓库 Secret）
    VS_TEST_PUSH            'true' = 只测推送，不查航班
    VS_LOOP_MINUTES         循环多少分钟。0 或不设 = 查一轮就退出（老行为）
    VS_ROUND_EVERY_SEC      格鲁吉亚白天多久查一轮，默认 300
    VS_ROUND_NIGHT_SEC      其余时段多久查一轮，默认 900
    VS_PUSH_COOLDOWN_MIN    同一条腿的推送冷却，默认 15
================================================================================
#>

$ErrorActionPreference = 'Continue'

$core = Join-Path $PSScriptRoot 'vs-core.ps1'
if (-not (Test-Path $core)) { $core = Join-Path (Split-Path -Parent $PSScriptRoot) 'vs-core.ps1' }
if (-not (Test-Path $core)) {
    Write-Host '找不到 vs-core.ps1（本目录和上级目录都没有）'
    exit 1
}
. $core

$BarkKey = $env:BARK_KEY
if (-not $BarkKey) { Write-Host '警告：环境变量 BARK_KEY 没设，只会打日志，不会推送。' }

# 只测推送：在 Actions 页面手动触发时把「只测推送」勾上就会走到这里。
# 存在的理由：平时六条腿全是「无票」，推送分支根本不会被执行到，
# 云端到手机这条链断了你也不知道 —— 只有真放票那天才会发现，那时候已经晚了。
if ("$env:VS_TEST_PUSH" -eq 'true') {
    Write-Host '只测推送模式：不查航班。'
    if (-not $BarkKey) {
        Write-Host '失败：BARK_KEY 这个 Secret 没配，或者名字拼错了。'
        exit 1
    }
    $ok = Send-Bark -Key $BarkKey -Critical `
          -Title '【测试】云端监测推送正常' `
          -Body "这条是 GitHub Actions 推的，说明云端到手机这条链是通的。`nUTC $(Get-Date -Format 'MM-dd HH:mm:ss')"
    if ($ok) {
        Write-Host '服务端已接收。现在看手机，收到就说明云端兜底真的能叫醒你。'
        exit 0
    }
    Write-Host '推送失败，原因见上面那行。404 基本都是 Secret 里的 key 抄错了（别把整条 URL 填进去）。'
    exit 1
}

# 全团人数。只用来判断「Kutaisi 那条够不够四个人一起走」这个兜底。
# 每条腿实际要几张看 $Targets 里各自的 Pax。
$PartySize = 4

# 行程最后一天。过了就什么都不查直接退出 —— 免得哪天你忘了这个仓库，
# 它还在替你一年三百六十五天地敲人家的订票站。
# 定时任务本身没法自己关掉，所以这里只能少花点力气并提醒你去 Disable。
$TripLastDate = '10/05/2026'
$tripEnd = [datetime]::ParseExact($TripLastDate, 'MM/dd/yyyy', $null).Date
if ((Get-Date).Date -gt $tripEnd) {
    Write-Host "已过行程最后一天（$TripLastDate），本轮不查询。"
    Write-Host '去 Actions -> 这个 workflow -> 右上角 ... -> Disable workflow 把它关掉。'
    exit 0
}

# 【2026-09-01：回程改成分头走，两条腿各买 2 张，都必须抢到】
#   去程 10/2 四个人一起，首选/备选仍是二选一。
#   回程 10/5 两条腿各 2 人 —— 谁跟谁一单不写在这里，这是公开仓库。
#   分组只存在本机的油猴脚本和 乘客信息\ 里。
#
#   Pax       这条腿实际要买几张。命中后拿它判断够不够，别再拿全团 4 人去判 ——
#             回程 2 座正好够，按 4 判会报成「不够」。
#   MaxProbe  往上试到几座为止。Kutaisi 那条只买 2 张却探到 4，是为了兜底：
#             Natakhtari 抢不到的话四个人全走 Kutaisi。
#   Loud      $false = 降级。云端没有铃也没有浏览器，降级只体现在推送级别：
#             critical（无视静音）降成 active（正常响一声）。
#   Fallback  $true = 这条腿够全团人数时，推送里多说一句「四个人可以全走这条」。
#   Sequential $true = 推送里提醒「两单一前一后买」。2026-09-01 实测：两个标签页几乎同时
#             按锁座，只有一个走到乘客页，另一个落到「THERE ARE NO AVAILABLE TICKETS」——
#             站点同一个会话容不下两个 hold，而且失败是静默的，看着就像票没了。
#
# 【2026-09-28 改：十月已开卖，只盯主抢】
#   9/28 18:25（北京）十月库存放出：哨兵 Batumi/Ambrolauri、Kutaisi 回程都有票了，
#   但 Natakhtari<->Mestia 两个方向整条线（9 月底到 10/9 每一天）仍然全空。
#   · 哨兵删掉：它的使命（探测十月上架）已经完成，留着只会拖慢主抢那两条的节奏。
#   · Loud=$false 的腿改成「安静腿」：不单独推送，状态并进每小时心跳（passive）；
#     且每 VS_QUIET_EVERY_MIN 分钟才查一次，每一轮的时间都留给主抢的两条。
#   · 备选去程（Kutaisi->Mestia 10/2）删掉：用户决定去程只走 Natakhtari。
#   · 只有 Loud=$true 的两条（Natakhtari 往返）命中才 critical 强提醒。
$Targets = @(
    @{ Tag = '首选';     Name = '10/2 去程 Natakhtari->Mestia';          Dep = '7'; Arr = '6'; Date = '10/02/2026'; Pax = 4; MaxProbe = 4; Loud = $true;  Fallback = $false; Sequential = $false }
    @{ Tag = '回程·优先'; Name = '10/5 回程 Mestia->Natakhtari (2 张)';    Dep = '6'; Arr = '7'; Date = '10/05/2026'; Pax = 2; MaxProbe = 2; Loud = $true;  Fallback = $false; Sequential = $true }
    @{ Tag = '回程·次要'; Name = '10/5 回程 Mestia->Kutaisi (2 张)';       Dep = '6'; Arr = '5'; Date = '10/05/2026'; Pax = 2; MaxProbe = 4; Loud = $false; Fallback = $true;  Sequential = $true }
)

function Get-EnvInt {
    param([string]$Name, [int]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if (-not $v) { return $Default }
    $n = 0
    if ([int]::TryParse($v.Trim(), [ref]$n)) { return $n }
    return $Default
}

$LoopMinutes  = Get-EnvInt 'VS_LOOP_MINUTES'      0
$RoundDay     = Get-EnvInt 'VS_ROUND_EVERY_SEC'   300
$RoundNight   = Get-EnvInt 'VS_ROUND_NIGHT_SEC'   900
$CooldownMin  = Get-EnvInt 'VS_PUSH_COOLDOWN_MIN' 15
$QuietEvery   = Get-EnvInt 'VS_QUIET_EVERY_MIN'   10

# 同一条腿上次推送的时间。key 是腿的名字。
$lastPush = @{}

# 安静腿：上次查的时间、最近一次的状态（一行字，心跳里原样带出去）
$lastQuiet   = (Get-Date).AddYears(-1)
$QuietStatus = [ordered]@{}

function Invoke-Round {
    param([int]$Index)

    $hits = 0
    $errs = 0

    # 一轮共用一个会话，form_build_id 可以复用，能省掉五次 GET
    $ctx = New-VSSession
    if (-not $ctx) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 建会话失败（GET 不到搜索页）。本轮什么都没查。"
        return @{ Hits = 0; Errs = 1 }
    }

    # 安静腿每 $QuietEvery 分钟才查一次，其余轮次只查主抢
    $doQuiet = ((Get-Date) - $script:lastQuiet).TotalMinutes -ge $QuietEvery
    if ($doQuiet) { $script:lastQuiet = Get-Date }

    foreach ($t in $Targets) {
        if (-not $t.Loud -and -not $doQuiet) { continue }

        $r = Test-Availability -Dep $t.Dep -Arr $t.Arr -Date $t.Date -Pax 1 -Ctx $ctx
        $line = '[{0}] 【{1}】{2}  {3}  ->  {4} {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
                $t.Tag, $t.Name, $t.Date, $r.State, $r.Detail
        Write-Host $line

        # 安静腿：不推送，只记下状态，等心跳一起带出去
        if (-not $t.Loud) {
            $stamp = [datetime]::UtcNow.AddHours(8).ToString('HH:mm')
            switch ($r.State) {
                'AVAILABLE' {
                    Start-Sleep -Seconds 2
                    $seats = Get-MaxSeats -Dep $t.Dep -Arr $t.Arr -Date $t.Date -Max ([int]$t.MaxProbe) -Ctx $ctx
                    $s = "有票 $($r.Detail)，最多 $seats 座"
                    if ($t.Fallback -and $seats -ge $PartySize) { $s += "（够四人全走）" }
                    $script:QuietStatus["【$($t.Tag)】$($t.Name)"] = "$s（$stamp 查）"
                }
                'NONE'  { $script:QuietStatus["【$($t.Tag)】$($t.Name)"] = "无票（$stamp 查）" }
                default { $errs++ }
            }
            Start-Sleep -Seconds 2
            continue
        }

        if ($r.State -eq 'AVAILABLE') {
            $hits++

            # 冷却：同一条腿短时间内不重复推。不同的腿互不影响。
            $skip = $false
            if ($lastPush.ContainsKey($t.Name)) {
                $mins = ((Get-Date) - $lastPush[$t.Name]).TotalMinutes
                if ($mins -lt $CooldownMin) {
                    $skip = $true
                    Write-Host ('    仍有票，但 {0:N1} 分钟前已推过，冷却中（{1} 分钟）' -f $mins, $CooldownMin)
                }
            }

            if (-not $skip) {
                # 2026-09-27 加：点通知直接进抢票链。iPhone 装了 Userscripts 之后，
                # Safari 打开这条链接，脚本按 #vsauto 参数自动搜索、停在班次列表、按 pax 选这一单的人。
                # 参数里只有航线/日期/张数，没有任何乘客信息，可以放进公开仓库。
                $link = 'https://ticket.vanillasky.ge/en/tickets#vsauto=1&dep={0}&arr={1}&date={2}&pax={3}' -f `
                        $t.Dep, $t.Arr, $t.Date, $t.Pax
                # 走到这里的一定是主抢（安静腿上面已经 continue 掉了）。
                # 【2026-09-28 改：先推 critical，再探余座】
                #   原来是先 4→3→2 逐个探余座（多两三次 POST，二三十秒）再推 ——
                #   Natakhtari 这条几个座位几分钟就没，这二三十秒不能花在推送之前。
                #   现在命中就立刻强提醒，余座数探完再补一条普通推送。
                $need  = [int]$t.Pax
                $title = "【$($t.Tag)】放票了（云端发现）"
                $body  = "$($t.Name)  $($t.Date)`n$($r.Detail)  余座确认中，先去抢"
                if ($t.Sequential) {
                    $body += "`n回程两单一前一后买：这一单买完（付款）再去买另一单，别同时锁座。"
                }
                $body += "`n点这条通知直接进抢票页（手机需装好 Userscripts 脚本）"

                # BARK_KEY 这个 Secret 里第一个 key 就是主账号 —— 同步云端.ps1
                # 按 $BarkKey -> $BarkAlso 的顺序抄，主账号一定排在最前面。
                # 以后往 Secret 里加人请往后面加，别插到第一个去。
                $allKeys = @(Expand-BarkKeys $BarkKey)
                $mainKey = @($allKeys | Select-Object -First 1)
                $others  = @($allKeys | Select-Object -Skip 1)
                $myLevel = Get-BarkAlertLevel -IsMain -Base 'critical'
                Send-Bark -Key $mainKey -Title $title -Body $body -Level $myLevel -Url $link | Out-Null
                if ($others.Count) {
                    Send-Bark -Key $others -Title $title -Body $body -Level 'critical' -Url $link | Out-Null
                }
                $lastPush[$t.Name] = Get-Date

                # 补一条余座数（普通推送，只给主账号）
                $seats  = Get-MaxSeats -Dep $t.Dep -Arr $t.Arr -Date $t.Date -Max ([int]$t.MaxProbe) -Ctx $ctx
                $enough = if ($seats -ge $need) { "够这一单的 $need 张" } else { "只够 $seats 座，不够这一单的 $need 张，先把能锁的锁住" }
                Write-Host "    最多可订 $seats 座（本单需 $need）"
                Send-Bark -Key $mainKey -Title "【$($t.Tag)】余座：最多 $seats 座" `
                          -Body "$($t.Name)  $($t.Date)`n$enough" -Level 'active' -Url $link | Out-Null
            }
        }
        elseif ($r.State -eq 'ERROR') { $errs++ }

        Start-Sleep -Seconds 2
    }

    Write-Host "第 $Index 轮结束：命中 $hits，出错 $errs"
    return @{ Hits = $hits; Errs = $errs }
}

# ---------------------------------------------------------------- 跑
if ($LoopMinutes -le 0) {
    # 老行为：查一轮就退出。手动触发调试的时候用这个。
    Invoke-Round -Index 1 | Out-Null
    exit 0
}

$deadline = (Get-Date).AddMinutes($LoopMinutes)
Write-Host "循环模式：跑到 UTC $($deadline.ToUniversalTime().ToString('HH:mm:ss')) 为止（$LoopMinutes 分钟）。"
Write-Host "节奏：格鲁吉亚白天（UTC 05-15）每 $RoundDay 秒一轮，其余时段每 $RoundNight 秒一轮。"
Write-Host ''

# 【2026-09-27 加：云端心跳】
#   人不在电脑旁、本机也可能断网时，「没收到推送」分不清是没放票还是云端停了。
#   所以手动长跑期间每 VS_HEARTBEAT_MIN 分钟给主账号推一条汇总，本趟第一轮查完就先推一条。
#   只推主账号（同行的人不需要知道监测的死活）；平时走 passive 静默进通知列表，
#   但这一段时间里轮轮出错就升成 active 响一声 —— 那是云端实际上已经瞎了。
$HeartbeatMin = Get-EnvInt 'VS_HEARTBEAT_MIN' 0
$hbMainKey    = @(Expand-BarkKeys $BarkKey | Select-Object -First 1)
$nextBeat     = Get-Date
$hbRounds = 0; $hbErrRounds = 0; $hbHits = 0; $hbSince = Get-Date

function Send-CloudHeartbeat {
    $bj     = [datetime]::UtcNow.AddHours(8)
    $bjEnd  = $deadline.ToUniversalTime().AddHours(8)
    $mins   = [int][math]::Round(((Get-Date) - $hbSince).TotalMinutes)
    $allBad = ($hbRounds -gt 0 -and $hbErrRounds -eq $hbRounds)
    $title  = if ($allBad) { '云端监测：这段时间轮轮出错' } else { '云端监测正常' }
    $body   = "北京时间 $($bj.ToString('HH:mm'))｜过去 $mins 分钟查了 $hbRounds 轮，出错 $hbErrRounds 轮"
    $body  += if ($hbHits -gt 0) { "`n主抢期间有 $hbHits 次命中，强提醒已单独发出" } else { '，主抢（Natakhtari 往返）无票' }
    # 2026-09-28 加：安静腿（Kutaisi 回程）不单独推，状态并在这里
    foreach ($k in $QuietStatus.Keys) { $body += "`n$k：$($QuietStatus[$k])" }
    $body  += "`n本趟跑到北京时间 $($bjEnd.ToString('HH:mm'))，之后自动接力"
    $level  = if ($allBad) { 'active' } else { 'passive' }
    if ($BarkKey) { Send-Bark -Key $hbMainKey -Title $title -Body $body -Level $level | Out-Null }
    Write-Host "  [心跳] $title / $($body -replace "`n", ' / ')"
}

$round = 0
while ($true) {
    $round++
    $res = @(Invoke-Round -Index $round)[-1]
    $hbRounds++
    if ($res -and $res.Errs) { $hbErrRounds++ }
    if ($res -and $res.Hits) { $hbHits += $res.Hits }
    if ($HeartbeatMin -gt 0 -and (Get-Date) -ge $nextBeat) {
        Send-CloudHeartbeat
        $hbRounds = 0; $hbErrRounds = 0; $hbHits = 0; $hbSince = Get-Date
        $nextBeat = (Get-Date).AddMinutes($HeartbeatMin)
    }

    # 每轮重看一次收工条件 —— 这个 job 要跑将近一小时，中间跨过零点也算数
    if ((Get-Date).Date -gt $tripEnd) {
        Write-Host "已过行程最后一天（$TripLastDate），提前收工。"
        break
    }

    # 排班上架只会发生在格鲁吉亚上班时间（UTC+4），所以白天密、夜里疏。
    # 这一档跟原来 workflow 里 cron 分档的用意一样，只是搬进了循环里 ——
    # 因为 cron 的分档 GitHub 根本没兑现。
    $utcHour = (Get-Date).ToUniversalTime().Hour
    $gap = $RoundNight
    if ($utcHour -ge 5 -and $utcHour -le 15) { $gap = $RoundDay }

    $left = ($deadline - (Get-Date)).TotalSeconds
    if ($left -le $gap) {
        Write-Host "剩余时间不够下一轮（$([int]$left) 秒），本次触发到此为止。"
        break
    }
    Start-Sleep -Seconds $gap
}

Write-Host ''
Write-Host "本次触发共跑 $round 轮。"
# 单轮出错不让 workflow 变红，否则 GitHub 会因为「连续失败」自动停掉定时任务
exit 0
