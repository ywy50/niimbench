# Contributing

niimbench is Zig 0.17. Behavior changes need `make test` from the repository root: the lint, the node and browser checks, and `zig build test`. Add or change the test that shows the behavior first, and see it fail, before changing the code. CI runs the same `make test` on every pull request. A user-visible change adds a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

Read [docs/architecture.md](docs/architecture.md) before changing plugins, and [docs/cookbook/adding-a-plugin.md](docs/cookbook/adding-a-plugin.md) before adding one. Setup and the boot list are in [docs/development.md](docs/development.md).

Documentation follows [docs/AGENTS.md](docs/AGENTS.md). The index is [docs/README.md](docs/README.md). Put a fact in the tier that owns it, and link that page from anywhere else.

Agents use [AGENTS.md](AGENTS.md).
