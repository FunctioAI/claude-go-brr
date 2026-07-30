# Architecture

`claude-go-brr` offloads Claude Code tasks to lightning-fast bare-metal cloud workers. The biggest gains come from parallel-agent tasks, Ultracode workflow tasks, and deep-research tasks, where users can get results 2–3× faster than with local execution.

## Setup and Repository Access

Run `/claude-go-brr:setup` from the repository you want to use:

1. The command starts a GitHub device login and prints a login URL.
2. Open the URL and authorize `claude-go-brr` with GitHub.
3. Run `/claude-go-brr:setup` again. The client exchanges the saved device code for an API key in `~/.config/offload/config` and asks the host to determine repository access.
4. Public repositories are ready immediately. For private repositories, open the printed installation URL and grant the GitHub App access to the repository.

If you are already signed in, `/claude-go-brr:setup` skips the login flow and asks the host to check the current repository. It prints an installation URL only when the host requires GitHub App authorization.

Project environment variables are managed through the cloud settings page. Run `/claude-go-brr:env` from the project to print its settings URL and configured key names, then add or update values in the browser. Secret values are never accepted or printed by the local command and are injected into subsequent cloud runs.

## Claude Code Integration

The plugin exposes one way to submit agent tasks:

```text
/claude-go-brr:claude-go-brr "prompt"
```

The command treats each input line as one prompt in a multi-prompt run and
rejects blank lines.
A single line is submitted as a one-item `prompts` array. All prompts use the
host's shared worker queue.

The local client resolves the current GitHub repository, checked-out branch, and project subdirectory, then submits them to the offload API. Local uncommitted changes are excluded because cloud runs use the branch stored on GitHub.

## Cloud Execution

The offload service starts a run from the selected GitHub ref and executes the requested task on cloud workers. This removes local CPU, memory, and I/O limits from high-fanout workflows such as deep research, ultracode, and parallel agent jobs.

```text
Claude Code -> plugin -> offload API -> cloud workers
```

Public repositories are cloned without authentication. Private repository access is granted through the GitHub App. Optional project environment variables are stored by the service and injected into cloud runs; their values are managed only through the browser settings page.

## Result Delivery

The background client separately polls the run record and append-only live events, which can be monitored through `/tasks`. On completion it writes the complete run record, agent output, and returned patch to `.git/offload/`.

Non-empty patches are checked with `git apply --check` before the client prints the exact apply command. Applying the patch remains an explicit local action.
