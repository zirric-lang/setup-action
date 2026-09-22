# setup-action

A setup action that installs the [Zirric](https://zirric.knabel.dev) toolchain,
puts `zirric` on `PATH` and exports `ZIRRIC_PATH`.

Works with [Forgejo Actions](https://forgejo.org/docs/latest/user/actions/) and
GitHub Actions. It is a composite action driven by a single POSIX-ish bash
script, so it needs no Node.js runtime and no bundled `dist/`.

## Usage

```yaml
jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - uses: https://code.knabel.dev/zirric-lang/setup-action@v1
      - run: zirric run examples/hello.zirr
```

On GitHub the same action is used as `zirric-lang/setup-action@v1` if you
mirror this repository there; on Forgejo, actions from other instances are
referenced by their full URL as shown above.

Pin a specific release:

```yaml
      - uses: https://code.knabel.dev/zirric-lang/setup-action@v1
        with:
          zirric-version: v0.1.0
```

`latest` resolves to the newest stable release. Opt into alphas and betas with
`prerelease: true`:

```yaml
      - uses: https://code.knabel.dev/zirric-lang/setup-action@v1
        with:
          zirric-version: latest
          prerelease: true
```

Read the version from a file — either a plain `.zirric-version` or an asdf
`.tool-versions` containing a `zirric <version>` line:

```yaml
      - uses: https://code.knabel.dev/zirric-lang/setup-action@v1
        with:
          zirric-version-file: .tool-versions
```

Use the outputs:

```yaml
      - id: zirric
        uses: https://code.knabel.dev/zirric-lang/setup-action@v1
      - run: |
          echo "installed ${{ steps.zirric.outputs.zirric-version }}"
          "${{ steps.zirric.outputs.zirric-bin }}" run examples/hello.zirr
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `zirric-version` | `latest` | Tag (`v0.1.0`), bare version (`0.1.0`) or `latest`. |
| `zirric-version-file` | — | Read the version from this file instead. Supports `.tool-versions` and plain version files. |
| `prerelease` | `false` | Whether `latest` may resolve to a pre-release, e.g. `v0.2.0-beta.1`. |
| `forge-url` | `https://code.knabel.dev` | Forgejo instance hosting the releases. |
| `repository` | `zirric-lang/zirric` | Repository that publishes the releases. |
| `token` | — | Token for the release API and downloads, if your forge requires authentication. |
| `install-dir` | `$RUNNER_TOOL_CACHE/zirric/<version>/<arch>` | Where the archive is extracted. |
| `zirric-path` | `$HOME/.zirric` | Exported as `ZIRRIC_PATH`, the directory zirric keeps its package registry in. |
| `verify-checksum` | `true` | Verify the archive against the release `checksums.txt`. |

## Outputs

| Output | Description |
| --- | --- |
| `zirric-version` | Installed version without the leading `v`, e.g. `0.1.0`. |
| `zirric-tag` | Installed release tag, e.g. `v0.1.0`. |
| `zirric-bin` | Absolute path of the `zirric` binary. |
| `zirric-dir` | Directory added to `PATH`. |
| `zirric-path` | Value exported as `ZIRRIC_PATH`. |
| `cache-hit` | `true` when the version was already in the tool cache. |

## Supported runners

The action downloads the release archives built by GoReleaser:

| OS | `x86_64` | `arm64` |
| --- | --- | --- |
| Linux | `zirric_Linux_x86_64.tar.gz` | `zirric_Linux_arm64.tar.gz` |
| macOS | `zirric_Darwin_x86_64.tar.gz` | `zirric_Darwin_arm64.tar.gz` |
| Windows | `zirric_Windows_x86_64.zip` | `zirric_Windows_arm64.zip` |

The archive is verified against the release `checksums.txt` before it is
extracted. Repeated runs on the same runner reuse `$RUNNER_TOOL_CACHE`, so only
the first job of a self-hosted runner pays for the download.

## Caching the package registry

Zirric resolves dependencies into `$ZIRRIC_PATH/registry` (default
`~/.zirric/registry`). The prelude is embedded in the binary, so a plain
`zirric run` needs no network — cache the registry only once your project pulls
git dependencies through its `Cavefile`:

```yaml
      - uses: https://code.knabel.dev/zirric-lang/setup-action@v1
      - uses: actions/cache@v4
        with:
          path: ~/.zirric/registry
          key: zirric-registry-${{ runner.os }}-${{ hashFiles('Cavefile') }}
```

## Alternatives to this action

* Run the job inside the published image instead of installing the toolchain:

  ```yaml
  jobs:
    test:
      runs-on: docker
      container:
        image: code.knabel.dev/zirric-lang/zirric:latest
  ```

  Note that the image's entrypoint is `zirric` itself and it runs as UID 10001.

* Install from the distribution repositories (`apt`, `apk`, `pacman`),
  Homebrew or asdf as described in the
  [installation guide](https://zirric.knabel.dev/guides/installation/).

## Which zirric commands you can call

Which subcommands exist depends on the version you install — through
`v0.1.0-alpha.1` only `run`, `repl`, `lsp` and `completion` were implemented,
while `init`, `install`, `task`, `test`, `lint`, `fmt` and `docs` were still
help topics. Check the [changelog](https://zirric.knabel.dev/changelog/) for the
version you pin before adding a `zirric test` or `zirric fmt` step.

There is no `zirric version` command up to and including `v0.1.0-alpha.1`, so
the action reports the installed version from the release tag and verifies the
binary with `zirric --help` rather than asking it for its version.

## Development

`scripts/setup-zirric.sh` can be run outside of a workflow; it falls back to
`$HOME/.cache/zirric-tools` when `RUNNER_TOOL_CACHE` is unset and only writes
`GITHUB_PATH` / `GITHUB_ENV` / `GITHUB_OUTPUT` when those are set:

```bash
ZIRRIC_SETUP_VERSION=latest ./scripts/setup-zirric.sh
```

The workflows in `.forgejo/workflows/` and `.github/workflows/` exercise the
action against `latest`, a pinned tag and a version file.

## License

[MPL-2.0](./LICENSE), the same license as the Zirric compiler.
