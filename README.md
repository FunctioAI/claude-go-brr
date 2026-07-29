# claude-go-brr



[Release](https://github.com/FunctioAI/claude-go-brr/releases)
[License: MIT](plugins/claude-go-brr/LICENSE.md)
Claude Code plugin

Offload Claude Code workflows, deep-research, and parallel agent tasks to the cloud, and get results 2-3x faster.

- **2–3× faster** ultracode workflow execution ⚙️
- **2–3× faster** deep-research 🔬
- **2–3× faster** swarm of claude code instances 🐝

  
*We can speed up ultracode workflows 2–3×.*

## Install

```text
/plugin marketplace add FunctioAI/claude-go-brr
/plugin install claude-go-brr@claude-go-brr
/reload-plugins
/claude-go-brr:setup
/claude-go-brr:claude-go-brr Fix the failing tests
```



## Setup your inference



### Claude subscription

Run `claude setup-token` locally and sign in with your Claude Pro or Max account, then copy the generated token. Run `/claude-go-brr:env` from your project, open the settings URL it prints, and add the token as `CLAUDE_CODE_OAUTH_TOKEN` to authenticate subsequent workers with your Claude account.

### Claude API

Create an API key in the [Claude Console](https://console.anthropic.com/settings/keys), then run `/claude-go-brr:env`, open the printed settings URL, and add it as `ANTHROPIC_API_KEY` to use separately billed API credits. Set only one credential: Claude Code gives `ANTHROPIC_API_KEY` precedence when both are present. Values are stored securely, never printed by the command, and injected into subsequent workers for that project.

---



## Docs

- [Getting Started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Demos](docs/usage_examples.md)

---

Made by devs from  
  
           
  
Reach out to us! [@MakarKuznietsov](https://x.com/MakarKuznietsov)

