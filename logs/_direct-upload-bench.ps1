$jobCount=12
$file='logs/upload.bin'
if(-not (Test-Path $file)){ $bytes=New-Object byte[] 5242880; (New-Object System.Random).NextBytes($bytes); [System.IO.File]::WriteAllBytes($file,$bytes)}
$start=Get-Date
$jobs=@()
for($i=1;$i -le $jobCount;$i++){
  $u="https://httpbin.org/post?directup=$([guid]::NewGuid().ToString('N'))&i=$i"
  $jobs += Start-Job -ScriptBlock {
    param($url,$path)
    $out=& curl.exe -k --http1.1 -L --connect-timeout 8 --max-time 120 -o NUL -sS -w "CODE=%{http_code};UP=%{size_upload};TIME=%{time_total};SPEED=%{speed_upload};ERR=%{errormsg}" -X POST --data-binary "@$path" $url 2>&1
    [pscustomobject]@{code=$LASTEXITCODE;out=($out -join "`n")}
  } -ArgumentList $u,((Resolve-Path $file).Path)
}
Wait-Job -Job $jobs | Out-Null
$res=@($jobs | Receive-Job)
$jobs | Remove-Job -Force | Out-Null
$elapsed=[math]::Max(0.001,((Get-Date)-$start).TotalSeconds)
$ok=@($res | Where-Object { $_.out -match 'CODE=200' }).Count
$upBytes=0.0
foreach($r in $res){ if($r.out -match 'UP=(\d+)'){ $upBytes += [double]$Matches[1] } }
$aggMbps=[math]::Round((($upBytes*8/1000000.0)/$elapsed),2)
[pscustomobject]@{jobs=$jobCount;success=$ok;failures=($jobCount-$ok);elapsedSec=[math]::Round($elapsed,2);aggregateUploadMbps=$aggMbps} | ConvertTo-Json -Compress
