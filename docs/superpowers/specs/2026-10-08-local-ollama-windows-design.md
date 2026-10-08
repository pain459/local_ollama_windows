# Local Ollama Windows Performance Stack Design

Date: 2026-10-08

## Objective

Build a local, single-user coding inference stack on Windows that prioritizes low latency and reliable long-context tool use. A Mac or another trusted device on the same LAN connects through an authenticated LiteLLM gateway. One PowerShell controller sets up, starts, stops, inspects, and benchmarks the complete stack.

Success means:

- the primary coding model and its 100K context remain fully resident on the RTX 4090;
- Claude Code and OpenAI-compatible clients can stream responses over the LAN;
- LiteLLM records request and token usage in its browser dashboard;
- the Windows host exposes only authenticated LiteLLM traffic to the private subnet;
- startup and shutdown are repeatable and do not interfere with unrelated processes or containers.

## Known Host Baseline

- Windows host with an NVIDIA GeForce RTX 4090 and 24 GiB VRAM
- AMD Ryzen 9 7950X, 16 physical cores and 32 logical processors
- 128 GiB system RAM
- Ollama 0.40.1 installed natively
- NVIDIA driver 610.88
- Existing Qwen 3.8 27B Q4_K_M model images
- Existing Ollama environment uses Flash Attention, Q8 KV cache, one model, one parallel request, and a 64K context
- Existing firewall rules include overly broad Ollama access on Public networks and must not remain enabled

The implementation must re-detect versions and capabilities during setup rather than assuming this snapshot remains current.

## Scope

The stack includes:

- native Windows Ollama for direct GPU access;
- Dockerized LiteLLM AI Gateway and PostgreSQL;
- persistent LiteLLM request and token accounting;
- private-LAN access for Claude Code and OpenAI-compatible clients;
- a parameterized PowerShell controller;
- repeatable performance and GPU-residency checks.

The stack does not include internet exposure, remote VPN access, TLS termination, multi-user scheduling, host CPU/GPU dashboards, simultaneous model residency, automatic overclocking, or a general-purpose container management layer.

## Architecture

```text
Mac or trusted LAN client
        |
        | HTTP + LiteLLM virtual key
        v
Windows host LAN address:4000
        |
        | Docker published port
        v
LiteLLM container  <---->  PostgreSQL container
        |
        | ollama_chat via host.docker.internal:11434
        v
Native Ollama process  --->  RTX 4090
```

The LiteLLM container has a private Docker address that may change. LAN clients never use it. Docker publishes port 4000 on the Windows host, and clients use the Windows host's current LAN IPv4 address. A router DHCP reservation is recommended later but is not required for the first working deployment.

PostgreSQL is attached only to the private Compose network and has no host-published port. LiteLLM is the only LAN-facing application endpoint.

## Repository Components

The implementation will add these focused components:

- `ollama-stack.ps1`: the only operator-facing command; dispatches actions and owns lifecycle state.
- `compose.yaml`: pinned LiteLLM and PostgreSQL services, health checks, private network, persistent database volume, and port 4000 publishing.
- `config/litellm.yaml`: model aliases, Ollama provider configuration, authentication, database-backed usage logging, and conservative single-user settings.
- `.env.example`: documented non-secret environment names.
- `.env.local`: generated secrets and runtime settings; ignored by Git.
- `.state/`: generated process IDs, previous power scheme, firewall backup, and controller ownership data; ignored by Git.
- `tests/`: Pester tests for controller behavior plus integration smoke tests.
- `README.md`: setup, operation, Mac client configuration, security boundary, and troubleshooting.

## Controller Interface

The single entry point is:

```powershell
.\ollama-stack.ps1 -Action <Setup|Start|Stop|Status|Benchmark>
```

It supports `-Model devstral`, `-Model qwen`, or `-Model ministral`, with `devstral` as the default. `Start -Model qwen` switches explicitly; the controller unloads the current model before loading another one.

### Setup

`Setup` is idempotent and performs one-time preparation:

1. Verify PowerShell, Ollama, NVIDIA driver/GPU, virtualization, WSL2, Docker Desktop, and Docker Compose.
2. Offer an explicit prerequisite installation path through `winget` when Docker Desktop is absent. Reboots remain explicit and setup resumes safely after one.
3. Verify and pull the container image versions pinned by the repository; never substitute a moving `latest` tag.
4. Generate strong LiteLLM master, salt, and PostgreSQL secrets in `.env.local`.
5. Pull the Compose images and the selected Ollama models.
6. Back up the enabled state of existing Ollama firewall rules, disable broad inbound Ollama rules, and create one inbound TCP 4000 rule limited to the Private profile and `LocalSubnet`.
7. Detect the active default-route adapter and print its name, MAC address, and IPv4 address for an optional router reservation.
8. Validate generated configuration without leaving the stack running.

Firewall changes require elevation. Setup must explain the exact rules it will change before requesting elevation and retain enough state to restore those rules manually if needed.

### Start

`Start` performs an ordered, health-checked startup:

1. Refuse LAN exposure when the active Windows network profile is Public; print the corrective action.
2. Check that ports 4000 and 11434 are not owned by unrelated processes. If the verified official Ollama tray application owns 11434, stop that exact executable before launching the controller-owned server; never terminate an unknown owner.
3. Start Docker Desktop only when its engine is unavailable, then wait with a bounded timeout.
4. Record the active Windows power scheme and temporarily select High Performance when available.
5. Start native `ollama serve` with controller-owned environment variables and record its PID.
6. Start PostgreSQL and LiteLLM with `docker compose up -d` and wait for both health checks.
7. Preload the selected model with a 102,400-token context and an indefinite keep-alive.
8. Set controller-owned Ollama processes to Windows `High` priority, never `RealTime`; leave CPU affinity on all processors.
9. Verify through `ollama ps` that the model reports `100% GPU` and the requested context. A CPU/GPU split is a failed performance validation, not a silent success.
10. Create or confirm the restricted LiteLLM client key and perform a short authenticated streaming request through port 4000.
11. Print the detected LAN URLs, dashboard URL, model alias, and ready-to-copy Mac environment commands.

If any stage fails, Start stops only resources started during that attempt and reports the failing health check or command.

### Stop

`Stop` performs graceful teardown:

1. Stop the LiteLLM and PostgreSQL Compose services while preserving the PostgreSQL volume.
2. Unload the active Ollama model.
3. Stop only Ollama processes whose IDs and start times match controller state.
4. Restore the previous Windows power scheme when Start changed it.
5. Stop Docker Desktop only if the controller started it and doing so will not interrupt unrelated running containers.
6. Remove transient state while retaining logs, database data, configuration, and secrets.

Stop is idempotent. Missing processes or already-stopped containers are reported as such and are not errors.

### Status

`Status` reports:

- current LAN IPv4 and adapter;
- Ollama, LiteLLM, and PostgreSQL health;
- controller ownership and process IDs;
- active model, context, keep-alive, and CPU/GPU residency;
- LiteLLM API and dashboard URLs;
- whether the firewall rule is enabled and limited to Private/LocalSubnet;
- whether the current address differs from the last successful Start.

It does not print secrets. It prints the path holding the client configuration instead.

### Benchmark

`Benchmark` runs models sequentially, never concurrently. For each selected model it:

1. unloads the previous model;
2. preloads at the configured 100K context;
3. verifies full GPU residency;
4. executes fixed warm-up and measured prompts;
5. records model load duration, prompt-evaluation rate, output-token rate, time to first token, total latency, and peak reported VRAM;
6. writes a timestamped local result without prompts or secrets.

The benchmark compares Devstral and Qwen under identical conditions. It is evidence for changing the default, not part of normal startup.

## Model and Performance Policy

### Default model

The default alias `local-coder` maps to `ollama_chat/devstral-small-2:24b`. Devstral Small 2 is selected because it is designed for software-engineering agents and tool use, its 15 GB Q4_K_M weights leave useful VRAM for long context, and its supported context exceeds the requested 100K.

### Alternatives

- `qwen3.8:27b` remains a benchmarked quality alternative. Its Q4_K_M weights are about 17 GB and its hybrid attention layout makes a 100K Q8 cache plausible on 24 GiB, but runtime GPU-residency verification is authoritative.
- `ministral-3:14b` is the speed/headroom fallback when lower latency matters more than maximum coding quality.
- Only one model is loaded at a time.

### Ollama runtime

Normal startup applies these values to the controller-owned Ollama server:

```text
OLLAMA_HOST=0.0.0.0:11434
OLLAMA_CONTEXT_LENGTH=102400
OLLAMA_FLASH_ATTENTION=1
OLLAMA_KV_CACHE_TYPE=q8_0
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_NUM_PARALLEL=1
OLLAMA_KEEP_ALIVE=-1
OLLAMA_MAX_QUEUE=4
```

Binding Ollama to all host interfaces is needed for Docker Desktop's `host.docker.internal` route. The security boundary is Windows Firewall: no inbound allow rule for port 11434 remains enabled. Only LiteLLM port 4000 is allowed from the private local subnet.

Q8 is the default KV format. The controller does not silently fall back to Q4 because Q4 can reduce long-context quality. If Q8 at 100K does not remain fully on GPU, Benchmark reports the result and the user chooses between a smaller context, Q4 KV, or a smaller model.

The 128 GiB of system RAM is left available to Windows file caching and recovery. The design does not intentionally offload layers to CPU, create a RAM disk, or force model data into RAM: those actions consume resources without improving GPU-resident token generation. Full CPU access remains available for tokenization and any unavoidable fallback work.

Start may temporarily select the Windows High Performance power scheme and records the prior scheme for restoration by Stop. It does not overclock the GPU, alter firmware, or apply undocumented NVIDIA registry settings.

## LiteLLM and Usage Data

LiteLLM exposes these logical models:

- `local-coder` -> Devstral Small 2
- `local-qwen` -> Qwen 3.8 27B
- `local-fast` -> Ministral 3 14B when installed

The provider uses `ollama_chat` and `http://host.docker.internal:11434`. LiteLLM runs one worker because this is a single-user gateway and additional workers add no inference throughput.

PostgreSQL stores keys, request records, and usage totals. The Admin UI at `/ui` provides request counts and prompt, completion, and total-token metrics. Host CPU, RAM, and GPU telemetry is deliberately excluded.

Model prices are explicitly configured as zero so local requests are represented as free rather than as missing-pricing errors.

## LAN Clients

Docker publishes `4000:4000` on the Windows host. On each Start, the controller discovers the active private IPv4 and prints commands similar to:

```bash
export ANTHROPIC_BASE_URL="http://192.168.1.50:4000"
export ANTHROPIC_AUTH_TOKEN="<LiteLLM virtual key>"
export ANTHROPIC_MODEL="local-coder"
unset ANTHROPIC_API_KEY
claude
```

OpenAI-compatible clients use:

```text
Base URL: http://192.168.1.50:4000/v1
Model: local-coder
Authorization: Bearer <LiteLLM virtual key>
```

The Admin UI uses `http://192.168.1.50:4000/ui` and the master key. The master key is not reused by coding clients.

An address change is not fatal before a DHCP reservation exists; Start prints the new address and Status highlights the change. A future router reservation applies to the Windows network adapter's MAC address, not the Docker container.

## Security and Secret Handling

- Access is limited to trusted devices on the same private subnet.
- Port 4000 requires a LiteLLM key even on the LAN.
- Port 11434 has no inbound LAN allow rule.
- PostgreSQL has no published host port.
- `.env.local`, `.state/`, logs containing identifiers, and benchmark results are excluded from Git as appropriate.
- Secrets are never printed by Status or written to normal logs.
- The dashboard master key and client virtual key are distinct.
- HTTP is accepted only because the agreed scope is a trusted home LAN. Internet, guest-network, or untrusted-Wi-Fi access requires a separate TLS/VPN design.
- LiteLLM request/response bodies are not retained; only operational and token-usage metadata is stored unless the user later opts in.

## Error Handling

Every action validates prerequisites before mutation and produces an actionable error. Important cases include:

- missing Docker/Ollama/NVIDIA tooling;
- required reboot after installing WSL2 or Docker Desktop;
- Public Windows network profile;
- conflicting port owners;
- unavailable Docker engine;
- unhealthy PostgreSQL or LiteLLM containers;
- missing model or failed model pull;
- authentication/database migration failure;
- context mismatch or any CPU offload;
- changed LAN address;
- stale PID state after a crash;
- partial startup.

The controller identifies owned processes by PID plus creation time and executable path. It never performs broad process termination. Container commands are scoped to a fixed Compose project name.

## Verification Strategy

### Automated tests

Pester tests cover argument validation, environment construction, LAN-address selection, firewall command generation, PID ownership checks, idempotent Start/Stop behavior, secret redaction, and rollback after simulated stage failures.

Static validation covers PowerShell syntax and `docker compose config` using a non-secret test environment.

### Integration verification

The implementation is not complete until these checks pass on the target machine:

1. Setup completes twice without corrupting state.
2. Start reaches healthy Ollama, PostgreSQL, and LiteLLM endpoints.
3. `ollama ps` reports the selected model at a 102,400 context and `100% GPU`.
4. An authenticated streaming request through LiteLLM succeeds and returns token usage.
5. The LiteLLM Admin UI displays the request and its token counts.
6. A Mac on the same LAN can reach port 4000 with the virtual key.
7. The Mac cannot reach port 11434 or PostgreSQL.
8. An unauthenticated port-4000 request is rejected.
9. Stop unloads the model and stops only managed resources while retaining dashboard history.
10. A second Start works without repair or manual cleanup.

### Acceptance criteria

The stack is accepted when Devstral at 100K/Q8 remains fully GPU-resident, a Claude Code tool-calling smoke task completes from the Mac, token usage appears in the browser dashboard, forbidden ports are unreachable from the LAN, and Start/Stop passes two consecutive cycles.

