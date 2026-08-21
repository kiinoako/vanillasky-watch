<#
================================================================================
  watch-once.ps1  —  云端兜底，查一轮就退出
  给 GitHub Actions 用（ubuntu-latest + pwsh）。本机那份是常驻循环，这份是一次性的。

  Bark key 从环境变量 BARK_KEY 读，别写进文件里。
  命中就推送 —— 之后每 5 分钟会重复推，直到你把 workflow 停掉。
  这是故意的：云端是最后一道保险，宁可吵也不能漏。
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

$PartySize = 4

$Targets = @(
    @{ Tag = '首选'; Name = '10/2 去程 Natakhtari->Mestia'; Dep = '7'; Arr = '6'; Date = '10/02/2026' }
    @{ Tag = '备选'; Name = '10/2 去程 Kutaisi->Mestia';    Dep = '5'; Arr = '6'; Date = '10/02/2026' }
    @{ Tag = '首选'; Name = '10/5 回程 Mestia->Natakhtari'; Dep = '6'; Arr = '7'; Date = '10/05/2026' }
    @{ Tag = '备选'; Name = '10/5 回程 Mestia->Kutaisi';    Dep = '6'; Arr = '5'; Date = '10/05/2026' }
    @{ Tag = '哨兵'; Name = 'Natakhtari->Batumi 10/02';     Dep = '7'; Arr = '4'; Date = '10/02/2026' }
    @{ Tag = '哨兵'; Name = 'Natakhtari->Ambrolauri 10/02'; Dep = '7'; Arr = '2'; Date = '10/02/2026' }
)

$hits = 0
$errs = 0

# 一轮共用一个会话，form_build_id 可以复用，能省掉五次 GET
$ctx = New-VSSession
if (-not $ctx) {
    Write-Host "建会话失败（GET 不到搜索页）。本轮什么都没查。"
    exit 0
}

foreach ($t in $Targets) {
    $r = Test-Availability -Dep $t.Dep -Arr $t.Arr -Date $t.Date -Pax 1 -Ctx $ctx
    $line = '[{0}] 【{1}】{2}  {3}  ->  {4} {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $t.Tag, $t.Name, $t.Date, $r.State, $r.Detail
    Write-Host $line

    if ($r.State -eq 'AVAILABLE') {
        $hits++
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
    }
    elseif ($r.State -eq 'ERROR') { $errs++ }

    Start-Sleep -Seconds 2
}

Write-Host "本轮结束：命中 $hits，出错 $errs"
# 单轮出错不让 workflow 变红，否则 GitHub 会因为「连续失败」自动停掉定时任务
exit 0
