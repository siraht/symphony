# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## This Fork

This fork tracks OpenAI's Symphony repository while carrying Third Space-specific evaluation work.
The current `main` branch intentionally separates what is already implemented from what is still
planned for the Third Space deployment.

### Merged Changes Versus OpenAI `main`

The fork currently has two commits on top of OpenAI `main`:

- `f280525` installs Codex in the live E2E worker image with Bun instead of npm.
- `c1acef0` documents the fork-specific E2E image change in this README.

The code change is limited to `elixir/test/support/live_e2e_docker/Dockerfile`. The live E2E
Docker image now installs `curl` and `unzip`, sets `BUN_INSTALL=/root/.bun`, adds Bun to `PATH`,
installs Bun from `https://bun.sh/install`, and runs `bun add --global @openai/codex`.

The intent is to make the live E2E worker image install Codex through the Bun-based path used by
this fork while leaving the rest of Symphony unchanged.

### Third Space Deployment Direction

The Third Space website automation plan is broader than the merged code above. Those items should
be treated as planned deployment/fork work until they are implemented and committed here.

Planned differences from upstream OpenAI Symphony:

- Use Symphony first as a pilot/evaluation runner, not as a fully hardened production daemon.
- Keep Linear as the first dispatch source, with issue state as the primary approval gate.
- Add GitHub Issues only through a mirror or tracker adapter that normalizes issues into Symphony's issue model.
- Use a trusted PR wrapper when the runner should not hold broad GitHub write credentials.
- Require build output and written proof first, then add durable screenshots/videos after browser tooling and artifact storage exist.
- Add wrapper or fork extensions for label filters, exact retry limits, usage/budget gates, max-diff checks, notifications, workspace cleanup, and post-deploy smoke checks.
- Keep ThirdText integration as a sanitized task-handoff boundary, not direct production data access from the website runner.

Local work may exist toward these items before it is merged into this fork. Only committed changes
listed above should be assumed to be present in `main`.

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
