# Graph Report - DualWifi  (2026-04-26)

## Corpus Check
- 27 files · ~45,154 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 237 nodes · 423 edges · 10 communities detected
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 9 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]

## God Nodes (most connected - your core abstractions)
1. `Ensure-NetFusionRoutes()` - 20 edges
2. `Measure-InterfaceHealth()` - 13 edges
3. `Invoke-NetworkRestore()` - 12 edges
4. `Invoke-WatchMode()` - 12 edges
5. `Write-NetworkStateMessage()` - 11 edges
6. `Save-OriginalNetworkState()` - 11 edges
7. `Get-CachedJsonFile()` - 10 edges
8. `Update-AdaptersAndWeights()` - 9 edges
9. `Normalize-DisplayText()` - 9 edges
10. `Write-RouteEvent()` - 8 edges

## Surprising Connections (you probably didn't know these)
- `Invoke-EngineNetworkRestore()` --calls--> `Invoke-NetworkRestore()`  [INFERRED]
  core\NetFusionEngine.ps1 → core\NetworkState.ps1
- `Ensure-EngineNetworkRoutes()` --calls--> `Ensure-NetFusionRoutes()`  [INFERRED]
  core\NetFusionEngine.ps1 → core\NetworkState.ps1
- `Set-DynamicMetrics()` --calls--> `Read-NetworkState()`  [INFERRED]
  core\RouteController.ps1 → core\NetworkState.ps1
- `Set-DynamicMetrics()` --calls--> `Ensure-NetFusionRoutes()`  [INFERRED]
  core\RouteController.ps1 → core\NetworkState.ps1
- `Get-ActiveInterfaces()` --calls--> `Get-NetworkAdapters()`  [INFERRED]
  core\RouteController.ps1 → core\RouteAdapter.ps1

## Communities

### Community 0 - "Community 0"
Cohesion: 0.12
Nodes (40): Ensure-NetFusionRoutes(), Ensure-RouteMetric(), Get-InterfaceSourceIPv4(), Get-LiveInterfaces(), Get-MetricLookup(), Get-MinRouteMetric(), Get-OriginalDhcpSettings(), Get-OriginalDnsSettings() (+32 more)

### Community 1 - "Community 1"
Cohesion: 0.1
Nodes (32): Compare-FixedToken(), Ensure-DashboardToken(), Get-CachedJsonFile(), Get-ClientConfig(), Get-ClientHealth(), Get-ClientInterfaces(), Get-ClientProxy(), Get-ClientSafety() (+24 more)

### Community 2 - "Community 2"
Cohesion: 0.12
Nodes (23): Clear-SessionAffinityForAdapters(), Copy-ChunkedRequestBody(), Get-AdapterObservedMbps(), Get-AdapterSelectionOrder(), Get-AtomicCounterValue(), Get-LocalAdapterObservedMbps(), Get-LocalAdapterSelectionOrder(), Get-LocalAtomicCounterValue() (+15 more)

### Community 3 - "Community 3"
Cohesion: 0.2
Nodes (22): Add-Route(), Enable-AutomaticMetric(), Get-NetworkAdapters(), Remove-Route(), Set-InterfaceMetric(), Write-AdapterLog(), Add-SplitRoutes(), Get-ActiveInterfaces() (+14 more)

### Community 4 - "Community 4"
Cohesion: 0.22
Nodes (18): Get-ConfiguredEwmaAlphaMap(), Get-EwmaAlphaForMode(), Get-StabilityScore(), Measure-InterfaceHealth(), Measure-Jitter(), Repair-EventsFile(), Rotate-CSVLog(), Test-BoundTcpLatency() (+10 more)

### Community 5 - "Community 5"
Cohesion: 0.18
Nodes (2): Get-LinkSpeedMbps(), Get-UsableAdapters()

### Community 6 - "Community 6"
Cohesion: 0.32
Nodes (10): Apply-Decay(), Detect-Patterns(), Get-HourBucket(), Repair-EventsFile(), Save-LearningData(), Update-AdapterProfile(), Update-LearningState(), Update-Recommendations() (+2 more)

### Community 7 - "Community 7"
Cohesion: 0.31
Nodes (4): Show-MetricGuidance(), Show-ProxyGuidance(), Write-Step(), Write-Warn()

### Community 8 - "Community 8"
Cohesion: 0.25
Nodes (3): Enforce-ECMP(), Ensure-EngineNetworkRoutes(), Invoke-EngineNetworkRestore()

### Community 9 - "Community 9"
Cohesion: 0.42
Nodes (8): Get-AdapterCapabilityScore(), Get-AdapterFingerprint(), Get-AllNetworkInterfaces(), Get-LinkSpeedMbps(), Select-BestDefaultRoute(), Test-GatewayNeighborUsable(), Update-NetworkState(), Write-AtomicJson()

## Knowledge Gaps
- **Thin community `Community 5`** (12 nodes): `Add-CacheBuster()`, `Get-DashboardStats()`, `Get-LinkSpeedMbps()`, `Get-RxBytes()`, `Get-TxBytes()`, `Get-UsableAdapters()`, `Invoke-BoundCurlDownload()`, `Invoke-BoundCurlUpload()`, `New-SpeedTestGate()`, `test-combined-speed.ps1`, `Select-TestUrl()`, `Wait-SpeedJobsReady()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Set-DynamicMetrics()` connect `Community 3` to `Community 0`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Why does `Ensure-NetFusionRoutes()` connect `Community 0` to `Community 8`, `Community 3`?**
  _High betweenness centrality (0.041) - this node is a cross-community bridge._
- **Why does `Ensure-EngineNetworkRoutes()` connect `Community 8` to `Community 0`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Ensure-NetFusionRoutes()` (e.g. with `Ensure-EngineNetworkRoutes()` and `Set-DynamicMetrics()`) actually correct?**
  _`Ensure-NetFusionRoutes()` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.12 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.12 - nodes in this community are weakly interconnected._