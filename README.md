# Vanilla Sky 放票监测 · 云端兜底

每 5 分钟查一次 Vanilla Sky 十月梅斯蒂亚航线，有票就推 Bark。
本机脚本是主力（45–150 秒一轮），这里只是家里断电断网时的最后一道保险。

## 部署（十分钟）

1. 在 GitHub 上建一个**公开**仓库，随便叫什么，比如 `vs-watch`。

   必须公开。私有仓库的 Actions 每月只有 2000 分钟免费额度，
   而每 5 分钟跑一次一个月要用掉八千多分钟；公开仓库不限量。
   Bark key 走 Secrets，公开仓库也读不到。

2. 往仓库里放三个文件，**只放这三个**：

   ```
   vs-core.ps1                              <- 从上级目录复制过来
   watch-once.ps1
   .github/workflows/vanillasky-watch.yml
   ```

   `.gitignore` 已经把乘客信息、日志、本机脚本全挡在外面了。
   推之前自己再扫一眼 `git status`，确认没有任何带姓名护照号的文件。

3. 仓库 → Settings → Secrets and variables → Actions → New repository secret
   Name 填 `BARK_KEY`，Value 填你的 Bark key —— **`https://api.day.app/XXXX/` 中间那段**，
   不是整条 URL。整条粘进去脚本也认（会自动拆），但填 key 最干净。

4. Actions 标签页 → 左边选「Vanilla Sky 放票监测」→ Run workflow 手动跑一次。
   日志里应该看到六行查询结果。

5. 验证推送真的能到手机：把 `watch-once.ps1` 里 `$Targets` 临时改成一个当前有票的班次
   （比如 `Dep='7'; Arr='4'; Date='08/24/2026'`），提交、手动触发、确认手机响。
   验完改回来。

## 停掉

抢到票之后：Actions → 选这个 workflow → 右上角 `⋯` → Disable workflow。
或者直接把仓库删了。

## 两个注意事项

- **cron 会延迟。** GitHub 的定时任务在高峰期经常晚几分钟甚至更久，
  所以它只能当兜底。真正的快档在你自己电脑上。
- **命中后会一直推。** 每 5 分钟重复一次，直到你手动停掉 workflow。
  这是故意的 —— 云端是最后一道保险，宁可吵也不能漏。
