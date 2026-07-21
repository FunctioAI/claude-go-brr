# Getting Started

## Prerequisites

- Claude Code with plugin support
- A Git repository hosted on GitHub, with the branch you want to use pushed to a GitHub remote
- Bash, Git, curl, and Python 3.9 or newer

## Installation

Install `claude-go-brr` from the Claude Code plugin marketplace:

### Plugin installation

Run these commands in Claude Code:

```text
/plugin marketplace add Functio-AI/claude-go-brr
/plugin install claude-go-brr@claude-go-brr
/reload-plugins
```

From the GitHub repository you want to offload, start the one-time setup:

```text
/claude-go-brr:setup
```

Open the printed login URL and authorize with GitHub. When login completes, run `/claude-go-brr:setup` again, then open the GitHub App installation URL and grant access to the repository.

## Let's run it

Submit a task from your project directory:

```text
/claude-go-brr:claude-go-brr Fix the failing tests
```

You can offload multi-agent ultracode workflows, and deep-research tasks by including their command in the prompt:

```text
/claude-go-brr:claude-go-brr /deep-research Find the best photonics stocks to invest in right now
/claude-go-brr:claude-go-brr ultracode implement the authentication flow
```

Use `/claude-go-brr:ind` to run each line of the prompt as an independent cloud agent task, each in its own claude intance:

```text
/claude-go-brr:ind Review the API implementation
Review the database migrations
Review the test coverage
```

The task runs in the cloud against the current branch on GitHub. Use `/tasks` to follow progress and view the final output. Any returned patch is saved under `.git/offload/`; the task output shows the exact `git apply` command. Local uncommitted changes are not included, so push required changes before submitting.
