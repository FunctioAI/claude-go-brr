# Architecture

`claude-go-brr` offloads Claude Code tasks to optimized bare-metal cloud workers. The best results can be seen on parallel agent tasks, ultracode workflow tasks, and deep-research tasks, where user can get the result 2-3x faster compared to local execution.

## Setup and Repository Access

Run `/claude-go-brr:setup` from the repository you want to use:

1. The command starts a GitHub device login and prints a login URL.
2. Open the URL and authorize `claude-go-brr` with GitHub.
3. Run `/claude-go-brr:setup` again. The client exchanges the saved device code for an API key in `~/.config/offload/config` and prints a GitHub App installation URL.
4. Open the installation URL and grant the GitHub App access to the repository.

If you are already signed in, `/claude-go-brr:setup` skips the login flow and prints the installation URL for the current repository.

Project environment variables are managed through the cloud settings page. Run `/claude-go-brr:env` from the project to print its settings URL and configured key names, then add or update values in the browser. Secret values are never accepted or printed by the local command and are injected into subsequent cloud runs.

## Claude Code Integration

The plugin exposes 2 ways to submit agent tasks:
`/claude-go-brr "prompt"` passes prompt unchanged to an optimized bare-metal worker running as a managed background task.
`/claude-go-brr:ind "prompt 1`
`prompt 2"` 
uses the same path but treats each prompt line as an independent cloud agent task.

The local client resolves the current GitHub repository, checked-out branch, and project subdirectory, then submits them to the offload API. Local uncommitted changes are excluded because cloud runs use the branch stored on GitHub.

## Cloud Execution

The offload service starts a run from the selected GitHub ref and executes the requested task on cloud workers. This removes local CPU, memory, and I/O limits from high-fanout workflows such as deep research, ultracode, and parallel agent jobs.

```text
Claude Code -> plugin -> offload API -> cloud workers
```

Repository access is granted through the GitHub App. Optional project environment variables are stored by the service and injected into cloud runs; their values are managed only through the browser settings page.

## Result Delivery

The background client polls the run event stream, which can be monitored through `/tasks`. On completion it writes the agent output and returned patch to `.git/offload/`.

Non-empty patches are checked with `git apply --check` before the client prints the exact apply command. Applying the patch remains an explicit local action.
