---
name: setup
description: Start, complete, or clear the Claude offload browser login flow.
argument-hint: "[start|login|logout|DEVICE_CODE]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh *)
---

# Claude Go Brr Setup

Use this skill when the user invokes `/claude-go-brr:setup`.

Run this command exactly:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" "$ARGUMENTS"
```

If no device code is provided and auth already exists, the script requests the GitHub App install URL for the current repo. If auth does not exist, it starts GitHub login, saves the pending device code locally, and prints a login URL plus the follow-up `/claude-go-brr:setup` command. That second argument-free invocation exchanges the saved code.

If a device code is provided, the script exchanges it for a client token and saves `~/.config/offload/config`.

If `logout` is provided, the script moves the saved local offload config aside so a different GitHub account can sign in.

Report the script output directly.
