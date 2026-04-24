# Diagnostics Scripts

This folder contains non-entrypoint validation and profiling helpers.

These scripts are not part of the normal NetFusion startup or shutdown flow. Keep new diagnostic helpers here unless they become a documented root-level operator command.

- `legacy-ecmp-test.ps1` checks the older ECMP route behavior.
- `legacy-speed-test.ps1` runs the older speed-test helper.
- `proxy-limit-test.ps1` tests proxy throughput limits.
- `test-smartproxy-csharp-compile.ps1` validates the SmartProxy C# compile path.
