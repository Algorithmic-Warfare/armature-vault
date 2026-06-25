# Sui Move: Environment Aliasing

## Problem

When your package builds under `testnet_wip` but a dependency only declares `testnet` in its `[environments]` table, the resolver cannot automatically find a matching environment entry. You need a way to tell the resolver which of the dependency's environments to use.

## What the Sui CLI offers

The relevant flags are:

| Command | Flag | What it does |
|---|---|---|
| `sui move build` | `-e <ENVIRONMENT>` | Selects the build environment by name |
| `sui move update-deps` | `-e <environment>` | Updates deps for the named environment |
| `sui client new-env` | `--alias <ALIAS>` | Names a client RPC endpoint — unrelated to Move build envs |

## The correct workaround: `use-environment` in `[dep-replacements]`

> **Correction:** The field is **`use-environment`**, not `env`. It cannot be placed directly in the `[dependencies]` entry — it must go in a `[dep-replacements.<env>]` section.

The `use-environment` key tells the resolver which environment name to look up **in that dependency's own `[environments]` table**, regardless of what environment the root package is building with. [[Environment-specific deps](https://docs.sui.io/develop/manage-packages/move-package-management#environment-specific-dependencies)]

```toml
[dependencies]
some_dep = {
  git    = "https://github.com/org/repo.git",
  subdir = "packages/some_dep",
  rev    = "<commit>"
}

[dep-replacements.testnet_wip]
some_dep = { use-environment = "testnet_stillness" }
```

With this declaration, running `sui move build -e testnet_wip` will resolve `some_dep` using the `testnet` entry from its `[environments]` table. [[Manifest reference](https://docs.sui.io/references/package-managers/manifest-reference)]

> **Important:** The `git` fields are **not merged** between `[dependencies]` and `[dep-replacements]`. If you need to change the git source in the replacement, you must re-specify the full `git`, `subdir`, and `rev` fields — they are not copied over from the `[dependencies]` entry.

### Example: this repo

`armature_vault` builds under `testnet_wip`. If a dependency (e.g. `warehouse_receipts`) only declares `testnet`, the fix would be:

```toml
[dependencies]
warehouse_receipts = {
  git    = "https://github.com/loash-industries/warehouse-receipts.git",
  subdir = "packages/contracts",
  rev    = "8a2f80e857d516187c99b28efa935ff7ce42af03"
}

[dep-replacements.testnet_wip]
warehouse_receipts = { use-environment = "testnet_stillness" }
```

## Limitations

- The `use-environment` override is **per dependency**, not global. Each dep that lacks your build environment needs its own entry in `[dep-replacements.<env>]`.
- The named environment must actually exist in **that dep's** `Move.toml`. You cannot invent a name — you can only redirect to one the dep already declares.
- There is no CLI flag or config option to declare a global fallback (e.g. "if `testnet_wip` is missing, try `testnet`").