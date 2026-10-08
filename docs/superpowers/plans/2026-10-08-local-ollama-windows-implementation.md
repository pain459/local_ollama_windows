# Local Ollama Windows Performance Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single PowerShell-controlled Windows stack that runs GPU-native Ollama behind an authenticated, Dockerized LiteLLM gateway with PostgreSQL-backed token metrics for trusted LAN clients.

**Architecture:** A root PowerShell command imports a focused module whose configuration, Windows-host, Ollama, LiteLLM, lifecycle, and benchmark concerns are split into separate files. Ollama runs natively for direct RTX 4090 access; Docker Compose publishes LiteLLM on host port 4000 and keeps PostgreSQL internal, while LiteLLM reaches Ollama through `host.docker.internal:11434`.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4-compatible tests, Ollama 0.40.1+, Docker Desktop 29.8.1+, Docker Compose 5.5.1+, LiteLLM 1.104.0, PostgreSQL 17 Alpine, YAML, Windows Defender Firewall cmdlets

**Spec:** `docs/superpowers/specs/2026-10-08-local-ollama-windows-design.md`

## Global Constraints

- Keep `ollama-stack.ps1` as the only operator-facing command; internal PowerShell module files are allowed.
- Support Windows PowerShell 5.1: do not use PowerShell 7-only syntax or cmdlet parameters.
- Use `devstral-small-2:24b` as `local-coder`, `qwen3.8:27b` as `local-qwen`, and `ministral-3:14b` as `local-fast`.
- Apply context `102400`, Q8 KV cache, Flash Attention, one loaded model, one parallel request, indefinite keep-alive, and queue length four.
- Never silently accept CPU offload or silently downgrade the KV cache to Q4.
- Publish only host port 4000; do not publish PostgreSQL and do not create a LAN allow rule for 11434.
- Limit the port-4000 firewall rule to the Private profile and `LocalSubnet`; refuse startup on a Public profile.
- Store secrets in ignored `.env.local`; never print them from `Status` or ordinary logs.
- Pin LiteLLM to `ghcr.io/berriai/litellm:1.104.0`; pin PostgreSQL to `postgres:17.6-alpine` and record resolved image IDs after pull.
- Scope every Docker operation to Compose project `local-ollama-windows`.
- Identify managed processes by PID, creation time, and executable path; never kill by process name alone.
- Run Docker commands with the user's normal Docker Desktop permissions. The Codex sandbox cannot currently open the Docker named pipe, so machine-level verification may require an approved escalated command.

## Review Focus

- Docker CLI exists but the daemon or named pipe is inaccessible: preflight must fail before firewall, power, process, or container mutation (Task 3 test).
- The active route is Public or multiple adapters exist: choose the lowest-metric default route deterministically and refuse Public exposure (Task 3 tests).
- Port 11434 belongs to an unknown process or state contains a reused PID: do not terminate it and return an actionable conflict (Task 5 tests).
- Startup fails after changing power state or starting some resources: roll back only resources started in that invocation and restore the prior power scheme (Task 7 test).
- LAN address changes and secrets exist in state: `Status` warns about the address but redacts all secret values (Task 7 test).

---

### Task 1: Define the PowerShell module and configuration contract

**Files:**
- Create: `.gitignore`
- Create: `src/OllamaStack/OllamaStack.psd1`
- Create: `src/OllamaStack/OllamaStack.psm1`
- Create: `src/OllamaStack/Configuration.ps1`
- Create: `tests/Configuration.Tests.ps1`

**Interfaces:**
- Produces: `Get-StackConfiguration([string]$RootPath, [string]$Model) -> [pscustomobject]`
- Produces: `Get-ModelConfiguration([string]$Model) -> [pscustomobject]`
- Produces: `Get-StackPaths([string]$RootPath) -> [pscustomobject]`
- Produces: model objects with `Name`, `Alias`, `OllamaName`, `LiteLLMName`, and `ContextLength`

- [ ] **Step 1: Write failing configuration tests**

Assert that `Get-ModelConfiguration 'devstral'` maps to alias `local-coder`, Ollama model `devstral-small-2:24b`, and context `102400`; assert equivalent Qwen and Ministral mappings; assert an unknown model throws; assert generated paths stay under the supplied repository root; assert `.env.local`, `.state/`, logs, and benchmark output are ignored.

- [ ] **Step 2: Run the tests and confirm the contract is missing**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Configuration.Tests.ps1 -PassThru"`

Expected: FAIL because the module and configuration functions do not exist.

- [ ] **Step 3: Implement the module skeleton and configuration functions**

`OllamaStack.psm1` dot-sources the focused implementation files and exports only action entry points plus configuration functions needed by tests. `Get-StackConfiguration` fixes ports 4000/11434, Compose project name, environment values, timeouts, and paths; it performs no I/O or mutation.

- [ ] **Step 4: Run configuration tests**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Configuration.Tests.ps1 -PassThru"`

Expected: all tests PASS.

- [ ] **Step 5: Commit the configuration contract**

```powershell
git add .gitignore src/OllamaStack tests/Configuration.Tests.ps1
git commit -m "test: define Ollama stack configuration contract"
```

### Task 2: Add the pinned LiteLLM and PostgreSQL deployment

**Files:**
- Create: `compose.yaml`
- Create: `config/litellm.yaml`
- Create: `.env.example`
- Create: `tests/Deployment.Tests.ps1`

**Interfaces:**
- Consumes: paths and model constants from Task 1
- Produces: Compose services `litellm` and `postgres`
- Produces: LiteLLM model names `local-coder`, `local-qwen`, and `local-fast`
- Produces: required environment names `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `POSTGRES_PASSWORD`, and `DATABASE_URL`

- [ ] **Step 1: Write failing deployment-structure tests**

Assert exact image tags, Compose project name, `4000:4000`, no PostgreSQL host port, private dependency/health checks, persistent database volume, one LiteLLM worker, and `host.docker.internal:host-gateway`. Assert each model uses `ollama_chat`, `http://host.docker.internal:11434`, zero input/output prices, and function-calling metadata. Assert request/response body storage is disabled.

- [ ] **Step 2: Run deployment tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Deployment.Tests.ps1 -PassThru"`

Expected: FAIL because deployment files do not exist.

- [ ] **Step 3: Implement Compose and LiteLLM configuration**

Use LiteLLM `ghcr.io/berriai/litellm:1.104.0`, PostgreSQL `postgres:17.6-alpine`, `pg_isready` for the database health check, and an authenticated-capable LiteLLM health check. Mount `config/litellm.yaml` read-only and run `--config /app/config.yaml --port 4000 --num_workers 1`.

- [ ] **Step 4: Run structural and Compose validation**

Run:

```powershell
powershell -NoProfile -Command "Invoke-Pester .\tests\Deployment.Tests.ps1 -PassThru"
Copy-Item .env.example .env.plan-test
docker compose --env-file .env.plan-test config --quiet
Remove-Item .env.plan-test
```

Expected: Pester passes and Compose exits 0 without starting containers.

- [ ] **Step 5: Commit the deployment definition**

```powershell
git add compose.yaml config/litellm.yaml .env.example tests/Deployment.Tests.ps1
git commit -m "feat: add pinned LiteLLM compose stack"
```

### Task 3: Implement non-mutating Windows host preflight

**Files:**
- Create: `src/OllamaStack/Host.ps1`
- Create: `tests/Host.Tests.ps1`
- Modify: `src/OllamaStack/OllamaStack.psm1`

**Interfaces:**
- Consumes: stack configuration from Task 1
- Produces: `Get-HostPreflight([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Get-ActiveLanAdapter() -> [pscustomobject]` with `InterfaceIndex`, `Name`, `MacAddress`, `IPv4Address`, `NetworkCategory`, and `RouteMetric`
- Produces: `Get-PortOwner([int]$Port) -> [pscustomobject] or $null`
- Produces: `Get-DockerAvailability() -> [pscustomobject]` with `CliPresent`, `ComposePresent`, `EngineReachable`, and `Error`
- Produces: `Test-IsAdministrator() -> [bool]`

- [ ] **Step 1: Write failing host-preflight tests**

Mock route, adapter, connection, command, and external-process calls. Assert lowest route metric wins, APIPA/loopback/virtual-only addresses are rejected, Public profile sets `CanExposeLan=$false`, inaccessible Docker daemon fails before mutation, unrelated port owners are reported with PID/path, and healthy prerequisites return `CanStart=$true`.

- [ ] **Step 2: Run host tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Host.Tests.ps1 -PassThru"`

Expected: FAIL because host functions do not exist.

- [ ] **Step 3: Implement read-only detection**

Use `Get-NetRoute`, `Get-NetIPConfiguration`, `Get-NetConnectionProfile`, `Get-NetTCPConnection`, `Get-Process`, `Get-Command`, `docker version`, `docker compose version`, `ollama --version`, and `nvidia-smi`. Catch access-denied errors and return actionable structured errors rather than partial success.

- [ ] **Step 4: Run host tests**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Host.Tests.ps1 -PassThru"`

Expected: all tests PASS.

- [ ] **Step 5: Commit preflight support**

```powershell
git add src/OllamaStack/Host.ps1 src/OllamaStack/OllamaStack.psm1 tests/Host.Tests.ps1
git commit -m "feat: add Windows host preflight checks"
```

### Task 4: Implement idempotent setup, secrets, and firewall hardening

**Files:**
- Create: `src/OllamaStack/Setup.ps1`
- Create: `tests/Setup.Tests.ps1`
- Modify: `src/OllamaStack/Host.ps1`
- Modify: `src/OllamaStack/OllamaStack.psm1`

**Interfaces:**
- Consumes: `Get-HostPreflight`, paths, and model configuration
- Produces: `New-StackSecret([int]$ByteCount) -> [string]`
- Produces: `Read-DotEnv([string]$Path) -> [hashtable]`
- Produces: `Write-DotEnvAtomic([string]$Path, [hashtable]$Values) -> [void]`
- Produces: `Get-FirewallPlan([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Enable-StackFirewall([pscustomobject]$Plan) -> [void]`
- Produces: `Invoke-StackSetup([pscustomobject]$Config, [switch]$InstallPrerequisites) -> [pscustomobject]`

- [ ] **Step 1: Write failing setup tests**

Assert cryptographic secrets start with `sk-` where required, contain sufficient entropy, and are preserved on a second Setup. Assert atomic env writes never expose partial files. Assert only inbound Allow rules associated with Ollama/port 11434 are backed up and disabled, the new rule is TCP 4000 + Private + LocalSubnet, non-admin setup returns the exact elevation command, and no secret appears in results or logs.

- [ ] **Step 2: Run setup tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Setup.Tests.ps1 -PassThru"`

Expected: FAIL because setup functions do not exist.

- [ ] **Step 3: Implement setup behavior**

Generate `.env.local` with master/salt/PostgreSQL values, derive `DATABASE_URL` for the Compose network, create `.state/firewall-backup.json`, validate Compose, pull pinned images, record their resolved IDs in `.state/image-lock.json`, and pull only the selected Ollama model when absent. `-InstallPrerequisites` may invoke the documented Docker Desktop `winget` package, then exit with a reboot/re-run instruction; it never reboots automatically.

- [ ] **Step 4: Run setup tests**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Setup.Tests.ps1 -PassThru"`

Expected: all tests PASS.

- [ ] **Step 5: Commit setup support**

```powershell
git add src/OllamaStack/Setup.ps1 src/OllamaStack/Host.ps1 src/OllamaStack/OllamaStack.psm1 tests/Setup.Tests.ps1
git commit -m "feat: add idempotent stack setup"
```

### Task 5: Manage the native Ollama lifecycle and GPU residency

**Files:**
- Create: `src/OllamaStack/Ollama.ps1`
- Create: `tests/Ollama.Tests.ps1`
- Modify: `src/OllamaStack/OllamaStack.psm1`

**Interfaces:**
- Consumes: preflight results, configuration, and `.state` paths
- Produces: `Start-ManagedOllama([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Wait-OllamaReady([uri]$BaseUri, [timespan]$Timeout) -> [void]`
- Produces: `Initialize-OllamaModel([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Get-OllamaResidency([string]$ModelName) -> [pscustomobject]` with `ContextLength`, `Processor`, and `FullyGpuResident`
- Produces: `Stop-ManagedOllama([pscustomobject]$Config) -> [pscustomobject]`
- Produces: runtime state fields `Pid`, `StartedAtUtc`, `ExecutablePath`, and `Model`

- [ ] **Step 1: Write failing Ollama lifecycle tests**

Assert the child environment contains all seven required `OLLAMA_*` values without mutating the parent environment. Assert the official Ollama tray owner can be stopped only after executable-path validation, an unknown port owner causes a conflict, PID creation-time/path mismatch prevents termination, Stop is idempotent, preload sends `num_ctx=102400` and `keep_alive=-1`, and residency parsing rejects any processor value other than `100% GPU` or a context other than 102400.

- [ ] **Step 2: Run Ollama tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Ollama.Tests.ps1 -PassThru"`

Expected: FAIL because Ollama lifecycle functions do not exist.

- [ ] **Step 3: Implement native Ollama lifecycle**

Launch `ollama serve` with `System.Diagnostics.ProcessStartInfo` and a per-child environment. Record state atomically, wait on `/api/version`, preload through `/api/chat`, set verified controller-owned Ollama processes to `High`, and use `ollama ps` plus API data for residency validation. On Stop, unload with `ollama stop <model>` before terminating the verified server process.

- [ ] **Step 4: Run Ollama tests**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Ollama.Tests.ps1 -PassThru"`

Expected: all tests PASS.

- [ ] **Step 5: Commit Ollama lifecycle support**

```powershell
git add src/OllamaStack/Ollama.ps1 src/OllamaStack/OllamaStack.psm1 tests/Ollama.Tests.ps1
git commit -m "feat: manage native Ollama lifecycle"
```

### Task 6: Manage LiteLLM, PostgreSQL, authentication, and smoke checks

**Files:**
- Create: `src/OllamaStack/LiteLLM.ps1`
- Create: `tests/LiteLLM.Tests.ps1`
- Modify: `src/OllamaStack/OllamaStack.psm1`

**Interfaces:**
- Consumes: Compose definition, `.env.local`, configuration, and `Write-DotEnvAtomic`
- Produces: `Start-GatewayStack([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Wait-GatewayReady([pscustomobject]$Config) -> [void]`
- Produces: `Ensure-LiteLLMClientKey([pscustomobject]$Config) -> [string]`
- Produces: `Invoke-GatewaySmokeTest([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Get-GatewayStatus([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Stop-GatewayStack([pscustomobject]$Config) -> [pscustomobject]`

- [ ] **Step 1: Write failing gateway tests**

Assert every Docker command includes the fixed project and env-file arguments; health polling times out with the last failure; an existing valid client key is reused; a missing/invalid key triggers one `/key/generate` call scoped to the three local model aliases and is stored without logging; an unauthenticated model request is rejected; and Stop preserves the named PostgreSQL volume.

- [ ] **Step 2: Run gateway tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\LiteLLM.Tests.ps1 -PassThru"`

Expected: FAIL because gateway functions do not exist.

- [ ] **Step 3: Implement the gateway lifecycle**

Start with `docker compose --project-name local-ollama-windows --env-file .env.local up -d`, poll PostgreSQL and LiteLLM health, validate or generate the virtual key, then send a minimal streaming `/v1/chat/completions` request to the selected alias and capture usage. Stop with Compose `stop`, not `down -v`.

- [ ] **Step 4: Run gateway tests**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\LiteLLM.Tests.ps1 -PassThru"`

Expected: all tests PASS.

- [ ] **Step 5: Commit gateway lifecycle support**

```powershell
git add src/OllamaStack/LiteLLM.ps1 src/OllamaStack/OllamaStack.psm1 tests/LiteLLM.Tests.ps1
git commit -m "feat: manage LiteLLM gateway lifecycle"
```

### Task 7: Orchestrate Setup, Start, Stop, and Status through one script

**Files:**
- Create: `ollama-stack.ps1`
- Create: `src/OllamaStack/Actions.ps1`
- Create: `tests/Actions.Tests.ps1`
- Modify: `src/OllamaStack/Host.ps1`
- Modify: `src/OllamaStack/OllamaStack.psm1`

**Interfaces:**
- Consumes: all functions from Tasks 1-6
- Produces: `Invoke-StackStart([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Invoke-StackStop([pscustomobject]$Config) -> [pscustomobject]`
- Produces: `Get-StackStatus([pscustomobject]$Config) -> [pscustomobject]`
- Produces: root parameters `-Action Setup|Start|Stop|Status|Benchmark`, `-Model devstral|qwen|ministral`, and `-InstallPrerequisites`

- [ ] **Step 1: Write failing action tests**

Assert actions dispatch correctly, Start refuses a Public network, repeated Start/Stop is safe, changed IPv4 produces a warning rather than failure, and partial failure after power change/Ollama/Compose start unwinds in reverse order without touching pre-existing resources. Assert Status reports adapter/IP, three service health values, owned PIDs, model/context/GPU residency, firewall scope, API/dashboard URLs, and address-change state while redacting master/salt/database/client values. Assert the original power scheme is always restored by rollback or Stop.

- [ ] **Step 2: Run action tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Actions.Tests.ps1 -PassThru"`

Expected: FAIL because actions and the root command do not exist.

- [ ] **Step 3: Implement orchestration and power/Docker ownership state**

Use an in-memory rollback stack during Start. Record prior power scheme, whether Docker Desktop was started by the controller, pre-existing running container IDs, the LAN address, and owned process identity in `.state/runtime.json`. Print API/dashboard URLs and Mac exports only after the smoke test passes; print the client-key file path rather than the secret.

- [ ] **Step 4: Run all unit tests**

Run: `powershell -NoProfile -Command "$r=Invoke-Pester .\tests\*.Tests.ps1 -PassThru; if($r.FailedCount){exit 1}"`

Expected: zero failed tests.

- [ ] **Step 5: Commit the operator workflow**

```powershell
git add ollama-stack.ps1 src/OllamaStack tests/Actions.Tests.ps1
git commit -m "feat: orchestrate Ollama stack actions"
```

### Task 8: Add sequential Devstral/Qwen benchmarking

**Files:**
- Create: `src/OllamaStack/Benchmark.ps1`
- Create: `tests/Benchmark.Tests.ps1`
- Create: `tests/fixtures/ollama-stream.ndjson`
- Modify: `src/OllamaStack/Actions.ps1`
- Modify: `src/OllamaStack/OllamaStack.psm1`

**Interfaces:**
- Consumes: Ollama lifecycle and residency functions
- Produces: `Measure-OllamaModel([pscustomobject]$Config, [string]$Model) -> [pscustomobject]`
- Produces: `Invoke-StackBenchmark([pscustomobject]$Config) -> [pscustomobject[]]`
- Produces: benchmark properties `Model`, `ContextLength`, `FullyGpuResident`, `LoadMilliseconds`, `TimeToFirstTokenMilliseconds`, `PromptTokensPerSecond`, `OutputTokensPerSecond`, `TotalMilliseconds`, and `PeakVramMiB`

- [ ] **Step 1: Write failing benchmark tests**

Using the fixed NDJSON fixture and mocked clock/NVIDIA output, assert metric math, first-token timing, secret/prompt omission, sequential unload-before-next-load order, immediate failure on CPU offload, and timestamped JSON output under `.state/benchmarks`.

- [ ] **Step 2: Run benchmark tests and verify failure**

Run: `powershell -NoProfile -Command "Invoke-Pester .\tests\Benchmark.Tests.ps1 -PassThru"`

Expected: FAIL because benchmark functions do not exist.

- [ ] **Step 3: Implement streaming measurement and benchmark orchestration**

Use `System.Net.Http.HttpClient` response streaming for time-to-first-token and Ollama's final timing fields for token rates. Run Devstral then Qwen with a full unload between them; query `nvidia-smi` during each run for peak VRAM.

- [ ] **Step 4: Run benchmark and full unit tests**

Run: `powershell -NoProfile -Command "$r=Invoke-Pester .\tests\*.Tests.ps1 -PassThru; if($r.FailedCount){exit 1}"`

Expected: zero failed tests.

- [ ] **Step 5: Commit benchmarking**

```powershell
git add src/OllamaStack/Benchmark.ps1 src/OllamaStack/Actions.ps1 src/OllamaStack/OllamaStack.psm1 tests/Benchmark.Tests.ps1 tests/fixtures/ollama-stream.ndjson
git commit -m "feat: benchmark local coding models"
```

### Task 9: Document and verify the complete stack on the target machine

**Files:**
- Modify: `README.md`
- Create: `tests/Stack.Integration.Tests.ps1`

**Interfaces:**
- Consumes: the complete operator interface
- Produces: documented Setup/Start/Status/Benchmark/Stop workflow and Mac client configuration

- [ ] **Step 1: Write gated integration tests**

Run only when `RUN_STACK_INTEGRATION=1`. Assert Compose configuration, healthy local endpoints, authenticated and unauthenticated behavior, selected alias, token usage fields, persisted usage after a restart, full GPU residency at context 102400, and idempotent Stop. The test must never print secret values.

- [ ] **Step 2: Run unit tests and confirm integration tests skip safely**

Run: `powershell -NoProfile -Command "$r=Invoke-Pester .\tests\*.Tests.ps1 -PassThru; if($r.FailedCount){exit 1}"`

Expected: unit tests pass; integration tests are skipped because the environment flag is absent.

- [ ] **Step 3: Write operator documentation**

Document prerequisites, administrator-only Setup, normal non-admin Start/Stop/Status, generated files, model aliases, current-IP behavior before DHCP reservation, firewall boundary, dashboard login, Claude Code exports, OpenAI-compatible settings, benchmark interpretation, Docker named-pipe troubleshooting, and recovery from an interrupted Start.

- [ ] **Step 4: Run Setup twice and validate the live deployment**

Run in an elevated PowerShell where required:

```powershell
.\ollama-stack.ps1 -Action Setup -Model devstral
.\ollama-stack.ps1 -Action Setup -Model devstral
$env:RUN_STACK_INTEGRATION='1'
powershell -NoProfile -Command "$r=Invoke-Pester .\tests\Stack.Integration.Tests.ps1 -PassThru; if($r.FailedCount){exit 1}"
```

Expected: Setup is idempotent and integration tests pass. If Docker access is blocked only by the execution sandbox, rerun these exact commands with approved machine-level execution.

- [ ] **Step 5: Verify two lifecycle cycles and dashboard persistence**

Run:

```powershell
.\ollama-stack.ps1 -Action Start -Model devstral
.\ollama-stack.ps1 -Action Status -Model devstral
.\ollama-stack.ps1 -Action Stop -Model devstral
.\ollama-stack.ps1 -Action Start -Model devstral
.\ollama-stack.ps1 -Action Status -Model devstral
```

Expected: both starts pass authenticated smoke tests; both statuses show context 102400 and `100% GPU`; the dashboard retains the first cycle's token record.

- [ ] **Step 6: Perform LAN acceptance from the Mac**

Use the Start output to configure Claude Code, run one small tool-calling repository task, verify that `http://<windows-ip>:4000/ui` shows its token counts, and verify that connections to `<windows-ip>:11434` and PostgreSQL fail.

Expected: Claude Code succeeds through LiteLLM; forbidden ports are unreachable.

- [ ] **Step 7: Stop the stack and run final verification**

Run:

```powershell
.\ollama-stack.ps1 -Action Stop -Model devstral
git diff --check
powershell -NoProfile -Command "$r=Invoke-Pester .\tests\*.Tests.ps1 -PassThru; if($r.FailedCount){exit 1}"
git status --short
```

Expected: stack is stopped, unit tests pass, no whitespace errors exist, and only intended files are modified.

- [ ] **Step 8: Commit documentation and integration verification**

```powershell
git add README.md tests/Stack.Integration.Tests.ps1
git commit -m "docs: document and verify Ollama stack"
```

