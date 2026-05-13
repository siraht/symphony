# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

## This Fork

This branch contains a focused change on top of OpenAI's Symphony repository:

- `f280525` installs Codex in the live E2E worker image with Bun instead of npm.
- The live E2E Docker image now installs `curl` and `unzip`, sets `BUN_INSTALL=/root/.bun`, adds Bun to `PATH`, installs Bun from `https://bun.sh/install`, and runs `bun add --global @openai/codex`.
- The change is limited to `elixir/test/support/live_e2e_docker/Dockerfile`.

The intent is to make the live E2E worker image install Codex through the Bun-based path used by this fork while leaving the rest of Symphony unchanged.

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
