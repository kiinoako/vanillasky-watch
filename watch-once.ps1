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

$Targets = @(
    @{ Tag = '首选'; Name = '10/2 去程 Natakhtari->Mestia'; Dep = '7'; Arr = '6'; Date = '10/02/2026' }
    @{ Tag = '备选'; Name = '10/2 去程 Kutaisi->Mestia';    Dep = '5'; Arr = '6'; Date = '10/02/2026' }
    @{ Tag = '首选'; Name = '10/5 回程 Mestia->Natakhtari'; Dep = '6'; Arr = '7'; Date = '10/05/2026' }
    @{ Tag = '备选'; Name = '10/5 回程 Mestia->Kutaisi';    Dep = '6'; Arr = '5'; Date = '10/05/2026' }
    @{ Tag = '哨兵'; Name = 'Natakhtari->Batumi 10/02';     Dep = '7'; Arr = '4'; Date = '10/02/2026' }
    @{ Tag = '哨兵'; Name = 'Natakhtari->Ambrolauri 10/02'; Dep = '7'; Arr = '2'; Date = '10/02/2026' }
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

# 同一条腿上次推送的时间。key 是腿的名字。
$lastPush = @{}

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

    foreach ($t in $Targets) {
        $r = Test-Availability -Dep $t.Dep -Arr $t.Arr -Date $t.Date -Pax 1 -Ctx $ctx
        $line = '[{0}] 【{1}】{2}  {3}  ->  {4} {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
                $t.Tag, $t.Name, $t.Date, $r.State, $r.Detail
        Write-Host $line

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
                if ($t.Tag -eq '哨兵') {
                    $title = '十月开卖了（云端发现）'
                    $body  = "$($t.Name) 出票：$($r.Detail)`n梅斯蒂亚可能正在被抢，立刻去看。"
                } else {
                    Start-Sleep -Seconds 2
                    $seats = Get-MaxSeats -Dep $t.Dep -Arr $t.Arr -Date $t.Date -Max $PartySize -Ctx $ctx
                    $title = "【$($t.Tag)】放票了（云端发现）"
                    $body  = "$($t.Name)  $($t.Date)`n$($r.Detail)  最多可订 $seats 座`nhttps://ticket.vanillasky.ge/en/tickets"
                    Write-Host "    最多可订 $seats 座"
                }
                Send-Bark -Key $BarkKey -Title $title -Body $body -Critical | Out-Null
                $lastPush[$t.Name] = Get-Date
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

$round = 0
while ($true) {
    $round++
    Invoke-Round -Index $round | Out-Null

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
