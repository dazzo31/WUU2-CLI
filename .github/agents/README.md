# Antigravity Multi-LLM Orchestration Pack v2

## Included

- `AGENTS.md` — master Antigravity/Gemini orchestration policy.
- `OLLAMA-WORKER.md` — Ollama worker contract.
- `COPILOT-REVIEWER.md` — independent GitHub Copilot review contract.

## Recommended installation

### Antigravity / Gemini

Use `AGENTS.md` as the master orchestration instruction.

For a repository-local setup, put it at:

`<repo>\AGENTS.md`

If your existing Antigravity/Gemini environment uses `GEMINI.md` as the authoritative global instruction file, merge this policy into that file rather than maintaining competing global instructions.

Gemini CLI also supports custom subagents in:
- user: `~/.gemini/agents/`
- project: `.gemini/agents/`

Use those only if you want separate callable Gemini subagents; the master policy should remain authoritative.

### GitHub Copilot CLI

For a user-wide reviewer:

`%USERPROFILE%\.copilot\agents\copilot-reviewer.agent.md`

For repository-only:

`<repo>\.github\agents\copilot-reviewer.agent.md`

The repository-specific option is useful if you want the review contract to travel with the project.

### Ollama

Do not install `OLLAMA-WORKER.md` into Ollama.

Antigravity should include its relevant instructions when invoking Ollama.

Use the exact identifiers exposed by your Ollama installation if they differ from:
- `deepseek-v4.1-flash:cloud`
- `deepseek-v4-pro:cloud`
- `kimi-k3:cloud`

## Recommended project structure

For a project such as WUU2-CLI:

<repo>\
├── AGENTS.md
├── .github\
│   └── agents\
│       └── copilot-reviewer.agent.md
└── ...project files...

Keep `OLLAMA-WORKER.md` in your orchestration/instruction area or reference it from your Antigravity setup. It is a prompt contract, not an Ollama configuration file.

## First test

Give Antigravity a meaningful but bounded task:

"Use the multi-LLM orchestration policy. Decompose this task first. Delegate independent investigation in parallel. Use the cheapest capable worker. Use Copilot Auto as an independent reviewer after implementation. Show the delegation card before material worker calls. Do not declare completion without evidence."

Expected behaviour:
1. Gemini decomposes.
2. Independent investigations run concurrently.
3. One implementation owner is selected.
4. Tests are run.
5. Copilot independently challenges the result.
6. Gemini resolves findings.
7. Gemini verifies acceptance criteria.

## What this pack deliberately prevents

- Gemini doing all work itself.
- Every worker receiving the entire user request.
- Multiple workers editing the same files concurrently without coordination.
- Using premium models for trivial work.
- Treating "done" as evidence.
- Asking the implementation worker to validate itself.
- Infinite retry loops after worker failure.
- Silent scope expansion.
- Serial execution of independent tasks.
- High-capability models becoming default workers for everything.

## Suggested invocation language

For future tasks you can simply say:

"Use the multi-LLM orchestration policy. Optimize for parallel completion and use the least capable model likely to succeed. Delegate implementation to Ollama where appropriate and use Copilot Auto for independent challenge. Keep architecture and final acceptance in Gemini."

For high-risk changes add:

"Require an adversarial Copilot review and targeted evidence for every acceptance criterion."
