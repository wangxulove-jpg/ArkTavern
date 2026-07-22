# 连续 5 次打开和关闭 3D PoC 页面测试
$target = "127.0.0.1:5555"
$hdc = "hdc"
$targetArg = "-t $target"

# 假设应用已在设置页,3D PoC 入口在屏幕中下部位置 (601, 1997)
# 返回按钮在 (87, 208)

Write-Host "===== 开始 5 次连续打开/关闭测试 ====="

for ($i = 1; $i -le 5; $i++) {
  Write-Host ""
  Write-Host "----- 第 $i 次 -----"

  # 1. 点击 3D PoC 入口
  Write-Host "[1] 点击 3D PoC 入口"
  & $hdc $targetArg.Split(' ') shell "uitest uiInput click 601 1997" | Out-Null
  Start-Sleep -Milliseconds 1500

  # 2. 检查进程是否仍存在
  $pid_result = & $hdc $targetArg.Split(' ') shell "pidof com.example.arktavern"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($pid_result)) {
    Write-Host "ERROR: 进程不存在,应用崩溃!"
    exit 1
  }
  Write-Host "[2] 进程 PID: $pid_result"

  # 3. 点击返回按钮 (87, 208)
  Write-Host "[3] 点击返回"
  & $hdc $targetArg.Split(' ') shell "uitest uiInput click 87 208" | Out-Null
  Start-Sleep -Milliseconds 1000

  # 4. 再次检查进程
  $pid_result2 = & $hdc $targetArg.Split(' ') shell "pidof com.example.arktavern"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($pid_result2)) {
    Write-Host "ERROR: 返回后进程不存在,应用崩溃!"
    exit 1
  }
  Write-Host "[4] 返回后进程 PID: $pid_result2"
}

Write-Host ""
Write-Host "===== 5 次循环完成,检查错误日志 ====="
& $hdc $targetArg.Split(' ') shell "hilog -x | grep -iE 'FATAL|TypeError|Char3DPocPage|Char3DPocVM' | tail -n 60"
