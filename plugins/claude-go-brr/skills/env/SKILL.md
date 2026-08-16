---
name: env
description: Show offload project environment variable key names and the browser settings URL.
argument-hint: "[-d DIR]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/env.sh *)
---

# Claude Go Brr Env

Use this skill when the user invokes `/claude-go-brr:env`.

Run this command exactly:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/env.sh" "$ARGUMENTS"
```

The script delegates to `offload.sh env`, which derives the current project's `folder_id`, fetches metadata containing env variable key names only, and prints the project settings URL. For a controlled benchmark it may also pass repeated `--expect KEY=VALUE` arguments for the documented non-secret runtime allowlist; this returns only checked, missing, and mismatched key names and must fail closed when verification is unavailable. Never use it with credentials, base URLs, or arbitrary project values.

Stored env variable values are set in the browser and never returned by this command. `--expect` accepts only documented non-secret comparison values; it must never accept, request, echo, or store secret values.

Report the script output directly.
