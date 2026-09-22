## 2026-09-22 — Isolated crash self-tests

### Goal

Verify both fatal-signal and uncaught-Objective-C-exception logging from an external process without modifying the operator's real log.

### Golden path

1. Build `OmEditor` with `swift build` or `swift test`.
2. Set `OM_SELFTEST_CRASH` to `signal` or `exception`.
3. Set `OM_SELFTEST_LOG_PATH` to a temporary file path.
4. Launch `.build/debug/OmEditor` as a child process and expect a nonzero exit.
5. Decode the single JSON line and assert `event == "app.crash"` plus `signal` or `exception`, `reason`, and a nonempty `stack`.

### Verification

`CrashMonitorAcceptanceTests.testSignalAndExceptionSelfTestsLeaveCrashEvents` passes for both child-process modes.

### Failure pattern avoided

Tests must not redirect or overwrite `~/Library/Logs/om/om.log`, and one Objective-C exception must not produce both an exception record and a second abort-signal record.

### Ruled-out approaches

- Tried setting `CFFIXED_USER_HOME` on a `Process`; the compiled executables continued resolving `FileManager.default.homeDirectoryForCurrentUser` to the account home, so the intended temporary log was never read.

### Notes

`OM_SELFTEST_LOG_PATH` is honored only when `OM_SELFTEST_CRASH` is also set; normal application logging always uses `~/Library/Logs/om/om.log`.
