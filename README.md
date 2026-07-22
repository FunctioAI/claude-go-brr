# claude-go-brr

<img src="media/header.png" alt="" width="100%">

[![Release](https://img.shields.io/github/v/release/Functio-AI/claude-go-brr?style=flat-square)](https://github.com/Functio-AI/claude-go-brr/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](plugins/claude-go-brr/LICENSE.md)
![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757?style=flat-square)

Offload Claude Code workflows, deep-research, and parallel agent tasks to the cloud, and get results 2-3x faster.

- **2–3× faster** ultracode workflow execution ⚙️
- **2–3× faster** deep-research 🔬
- **2–3× faster** swarm of claude code instances 🐝


<p align="center">
  <img src="media/speed-comparison.gif" alt="claude-go-brr speed comparison" width="100%">
  <br>
  <em>We can speed up ultracode workflows 2–3×.</em>
</p>

## Install

```text
/plugin marketplace add Functio-AI/claude-go-brr
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

<p align="left">
  <sub>Made by devs from</sub>
  <br><br>
  <img src="media/logos/mit_chip.png" alt="MIT" height="88">
  &nbsp;&nbsp;&nbsp;
  <img src="media/logos/nvidia_chip.png" alt="NVIDIA" height="88">
  &nbsp;&nbsp;&nbsp;
  <img src="media/logos/eth_chip.png" alt="ETH Zürich" height="88">
  <br><br>
  Reach out to us! <a href="https://x.com/MakarKuznietsov">@MakarKuznietsov</a> 
</p>

<img src="media/footer.png" alt="claude-go-brr" width="100%">
