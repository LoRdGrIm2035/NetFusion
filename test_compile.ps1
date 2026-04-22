$content = Get-Content 'core\SmartProxy.ps1' -Raw
$startStr = 'Add-Type -TypeDefinition @"'
$endStr = '"@ -Language CSharp'

$startIndex = $content.IndexOf($startStr)
if ($startIndex -eq -1) { throw "Start not found" }
$startIndex += $startStr.Length

$endIndex = $content.IndexOf($endStr, $startIndex)
if ($endIndex -eq -1) { throw "End not found" }

$csharp = $content.Substring($startIndex, $endIndex - $startIndex)

try {
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    Write-Host "COMPILE SUCCESS"
} catch {
    Write-Host "COMPILE ERROR"
    Write-Host $_.Exception.Message
}
