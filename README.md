# Local Ollama Windows performance stack

This repository runs native Windows Ollama behind an authenticated LiteLLM gateway and private PostgreSQL database. Docker publishes only LiteLLM on TCP 4000; LAN clients never connect to a container IP. The default `local-coder` model is Ministral 3 14B at a 102,400-token context with Q8 KV cache and mandatory `100% GPU` residency.

## Prerequisites

- Windows PowerShell 5.1, NVIDIA RTX GPU/driver, and native Ollama 0.40.1+
- Docker Desktop with Compose
- A Windows network connection categorized as **Private**
- Administrator access for the one-time Setup firewall changes

## One command for every operation

Open an elevated PowerShell for Setup only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ollama-stack.ps1 -Action Setup -Model ministral
```

If Docker Desktop is absent, append `-InstallPrerequisites`; the script uses the official `Docker.DockerDesktop` winget package and asks you to reboot/rerun when required. Setup is idempotent: it preserves all generated secrets, pulls pinned images and only the selected Ollama model, records image IDs, disables broad inbound Ollama/11434 allow rules, and creates one Private/LocalSubnet TCP 4000 rule.

Normal operation does not require elevation:

```powershell
.\ollama-stack.ps1 -Action Start -Model ministral
.\ollama-stack.ps1 -Action Status -Model ministral
.\ollama-stack.ps1 -Action Benchmark
.\ollama-stack.ps1 -Action Stop -Model ministral
```

Models are `ministral` → `local-coder` (default and verified fully GPU-resident), `qwen` → `local-qwen`, and `devstral` → `local-devstral`. Only one is loaded at a time. Start fails instead of accepting CPU offload, a context below 102400, a Public network, or an unknown owner of port 11434/4000. Stop preserves PostgreSQL history and only terminates the Ollama PID whose path and creation time match controller state.

Generated `.env.local`, `.state/`, logs, client key, and benchmark JSON are Git-ignored. Status prints the client-key file path, never a credential. LiteLLM stores token/latency metadata but message and response content logging is disabled.

## Connect from a Mac on the same LAN

Use the Windows IPv4 shown by Start/Status—not a Docker address. Until you add a DHCP reservation this address can change, and Status flags that change.

```bash
export ANTHROPIC_BASE_URL="http://WINDOWS_LAN_IP:4000"
export ANTHROPIC_AUTH_TOKEN="$(cat /secure/path/copied-client-key)"
export ANTHROPIC_MODEL="local-coder"
unset ANTHROPIC_API_KEY
claude
```

For OpenAI-compatible clients use `http://WINDOWS_LAN_IP:4000/v1`, model `local-coder`, and `Authorization: Bearer <client-key>`. Open `http://WINDOWS_LAN_IP:4000/ui`, sign in as `admin`, and use `LITELLM_MASTER_KEY` from `.env.local` as the dashboard password. Do not copy the master key into coding clients.

Port 11434 and PostgreSQL 5432 must remain unreachable from the Mac. This HTTP design is only for a trusted Private LAN; use a separate TLS/VPN design for any untrusted or internet path.

## Benchmark and troubleshooting

Benchmark runs Devstral then Qwen sequentially and writes load time, TTFT, prompt/output token rates, total time, peak reported VRAM, context, and residency under `.state/benchmarks`. It aborts on any CPU split; it never silently changes Q8 to Q4.

If Docker reports named-pipe or `config.json` access denied, run the controller in your normal interactive Windows account with Docker Desktop running. If Start is interrupted, run Stop once and then Start again; rollback and Stop preserve unrelated containers and restore the previous power scheme. If the network is Public, change it to Private before retrying. Use `docker compose --project-name local-ollama-windows --env-file .env.local -f compose.yaml logs` for container diagnostics without pasting `.env.local` contents.

Run unit tests (live acceptance is skipped by default):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\*.Tests.ps1 -PassThru; if($r.FailedCount){exit 1}'
```

After Setup and Start, opt into live target-machine acceptance with `$env:RUN_STACK_INTEGRATION='1'` and run `tests\Stack.Integration.Tests.ps1`.
