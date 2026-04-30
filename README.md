# Fangz

A CLI parsing and documentation library for Zig.

Fangz handles argument parsing, help rendering, shell completions, and AsciiDoc documentation generation, all from a single command tree definition.

## Core concepts

### Command tree

A Fangz application is a tree of commands. The root command represents the application binary itself. Each node in the tree owns its arguments, flags, and optionally subcommands. Parsing is always scoped to the matched command: subcommand flags do not bleed into the parent scope, and parent flags are not visible inside subcommands unless explicitly registered on both.

### Arguments vs. flags

Positional arguments are identified by their position in the command line, not by a prefix. In `ls ~/Downloads`, `~/Downloads` is a positional argument.

Flags (also called options) are identified by a `-` or `--` prefix. In `git commit --message "my message"`, `--message` is a long flag and `-m` is its short equivalent. Each flag belongs to the command it is registered on and is not visible to sibling or parent commands.

## Arguments

### Positional arguments

Positional arguments are matched by their position in the command line, in the order they were registered on the command.

### Variadic positionals

A variadic positional collects all remaining unmatched tokens into a list. Only one variadic positional may exist per command, and it must be the last positional registered. This covers patterns like `ls file1 file2 file3`, where the number of values is open-ended.

## Flags

### Boolean flags

A boolean flag is a presence switch. Its presence in the command line sets it to true; its absence leaves it false. No value token is consumed. `rm --recursive` and `rm -r` are equivalent expressions of the same boolean flag.

#### Netagable boolean flags

Some boolean flags support both an enabled and disabled spelling. For example, `git commit --[no-]short` allows both `--short` (true) and `--no-short` (false) forms of the same flag. This is a common pattern for flags that default to true, where the disabled form is more common in practice than the enabled form.

#### Mixed short boolean flags

Short boolean flags can be combined into a single token. `ls -lah` is equivalent to `ls -l -a -h`, and `rm -rf` is equivalent to `rm -r -f`. The parser resolves each character in the combined token as an independent short flag. If a non-boolean short flag (one that consumes a value) appears in the chain, it terminates the combination and consumes the next token as its value.

### Value flags

A value flag consumes the token that follows it as its value. `git commit --message "my message"` and `git commit -m "my message"` are equivalent. Supported value types are raw strings, integers, floats, explicit booleans, and enumerations.

> **Planned:** support for `=`-separated values, such as `ls --color=auto`, as an equivalent form to `ls --color auto`.

### Enumerated flags

An enumerated flag constrains its value to a predefined set of allowed strings. Any value outside that set is rejected at parse time with a diagnostic listing the valid options. A log level flag that only accepts `debug`, `info`, `warn`, and `error` is an enumerated flag.

### Key-value flags

A key-value flag accepts repeated `key=value` pairs. Each invocation of the flag contributes one entry, and the flag may appear any number of times. This is the right design for configuring a named set of items, such as overriding severities per lint rule or setting build variables.

Alternative designs were considered and rejected:

- **Comma-separated values** (`--rule a=warn,b=deny`): fragile under shell escaping, and you cannot add one more entry later in a pipeline without reconstructing the entire string from scratch.
- **Per-key flags** (`--missing-doc-comment=deny`): the flag namespace grows linearly with the number of keys, and the pattern cannot generalize to user-defined or dynamic keys.

Repeated flags compose cleanly. Each pair is independent, shell history stays readable, and tab completion can suggest valid keys and values at each position. When the same key appears more than once, the last occurrence wins, which makes override chains predictable and explicit.

#### Constrained key-value flags

Both keys and values come from a known, finite set declared at registration time. Any unknown key or value is rejected at parse time before the command handler is called.

#### Unconstrained key-value flags

Keys and values are arbitrary strings. Structural validation only: the token must contain an `=` sign, the key must be non-empty, and the value must be non-empty. This covers patterns like `--define KEY=VALUE` where the key space is user-controlled.

## Subcommands

Each subcommand is a command node with its own argument and flag registrations. When a subcommand is matched, parsing is dispatched to it before any handler runs. Subcommands compose naturally, a subcommand can itself have subcommands, forming an arbitrarily deep command tree.

> **Planned:** Git-style external command dispatch. If a subcommand is not found in the registered tree, the parser will attempt to locate and execute `<binary>-<subcommand>` on `PATH` rather than emitting an error. This allows a binary to be extended by third-party plugins without recompilation, the same mechanism that gives Git its `git lfs` and similar extensions.

## Help

### Short and long help

Fangz renders two levels of help output, selected by which flag the user passes.

`-h` produces short help: the synopsis, the argument list, the flag list with summaries only, and the subcommand list with one-line descriptions. It is compact enough to read at a glance and is the right default for users who already know the tool.

`--help` produces long help, which is equivalent in behavior to `app help <command>`. It includes everything in short help, plus per-flag descriptions, per-subcommand descriptions, and examples. This mirrors Cobra's design, where `--help` and `help <cmd>` are interchangeable.

### Three tiers of help content

Every flag and command accepts three tiers of content, each mapped to a different rendering context:

- **Summary** — one line. Appears in `-h` tables, AsciiDoc option headers, and the one-line entries in subcommand lists.
- **Description** — one to several paragraphs. Appears in `--help` and in AsciiDoc documentation. Never shown in `-h`.
- **Examples** — annotated code blocks. Appear in `--help` and in AsciiDoc documentation. Grouped and labeled so they read as usage patterns rather than raw invocations.

This means `--help` is a complete inline reference for a command, and the generated AsciiDoc is the same content in a format suited for offline or web reading. One source, two consumers, different verbosity budgets.

### AsciiDoc-only sections

Some documentation content does not belong in a terminal at all — comparison tables, behavioral matrices, compatibility notes. Fangz allows attaching raw AsciiDoc content to any command or flag that is excluded from all terminal output and only appears in generated documentation.

### Issues

#### Help with inconsistencie

For example:

`zig build cli -- docs --help`:

```txt
docs
Generate markdown documentation for the CLI

Usage: docs [OPTIONS]

Options:
  --output-dir <STRING>  Directory where markdown documentation is written. [default: docs]
  --mode <VALUE>         Markdown layout to generate. [default: single_file] [possible values: single_file, per_command]
  --file <STRING>        File name to use with --mode single_file. [default: cli.md]
  -h, --help             Print help
```

and

`zig build cli -- completion --help`:

```txt
zig build cli -- completions --help
docent
Documentation linter for Zig projects

Usage: docent [OPTIONS] <COMMAND> <paths>...

Arguments:
  <paths>...  Files or directories to lint [variadic]

Commands:
  docs        Generate markdown documentation for the CLI
  completion  Generate shell completion scripts
  help        Print this message or the help of the given subcommand(s)

Options:
  -r, --rule <<rule>=<severity>>...  Override severity: <name>=<allow|warn|deny|forbid> [possible values: allow, warn, deny, forbid]
  --all <VALUE>                      The level to apply to all rules. [possible values: warn, deny]
  -f, --format <VALUE>               The output format of the lints. [default: pretty] [possible values: pretty, text, minimal, json]
  --include-build-scripts            Include build.zig and build/*.zig files in lint targets. [default: false]
  -h, --help                         Print help
  -V, --version                      Print version
```

Should be fixed and tested:

- First, it should be "completions", I believe, not singular "completion", as it generates the completion scripts or suggestions for the given shell. But I'm not sure, as I want to be good UX.
- The compeltions command, keeps showing "documentation linter..." in its help, shouldn't it be showing like in the docs command?
- OH, no I typed, `completions` and it still threw me normal, i guess it should allow for both completion/s, normally but show idk whichever sounds, reads and feels better.

```txt
zig build cli -- completion
completion
Generate shell completion scripts

Usage: completion [OPTIONS] <shell>

Arguments:
  <shell>  One of: bash, zsh, fish, pwsh, sh, nu, nushell [required]

Options:
  --dynamic   For Nushell, emit dynamic completer module (default: static) [default: false]
  -h, --help  Print help

```

The list of shells should be using my carnaval list styling, not just a comma-separated list, as it'll look prettier.

## Documentation generation

Fangz generates documentation in AsciiDoc format. AsciiDoc is the only format Fangz emits directly. Conversion to HTML, PDF, or other formats is handled by `asciidoctor`, which accepts the same source for different output backends.

If you need formats beyond what `asciidoctor` covers, [Pandoc](https://pandoc.org/MANUAL.html) can convert AsciiDoc to most document formats.

The built-in `docs` subcommand, which Fangz injects into every application, writes documentation to a configurable output directory and supports both single-file and per-command layout modes.

## App metadata

### Name

The application name is inferred from the `.name` tag in `build.zig.zon` and can be overridden at initialization.

### Version

The version is read from `build.zig.zon` at build time via a build injection step. When building inside a Git repository, the branch name and short commit hash are appended to the version string. Version is exposed as `--version` / `-V` by default.

### Description

The description is inferred from a `.description` field in `build.zig.zon` if present, and can be overridden at initialization.

## Shell completions

Fangz injects a `completion` subcommand into every application. Supported shells are Bash, Zsh, Fish, PowerShell, and Nushell. Nushell supports both a static completion list and a dynamic completer module via a `--dynamic` flag on the completion subcommand.

Priority is given to shells that see active use during development. Nushell is the current primary. Additional shells beyond this list are not planned for first-party support and are open to contributions.

> **Known issue:** Nushell's completion engine produces a syntax error on kebab-cased names in some completion contexts. Under investigation.

The issue is the following, on my TypM project, it generates:

```nu
export extern "typm install" [
  --help(-h)              # Print help
  git-source: string
]
```

Where `git-source` seeems invalid.

## Credits

- [Cobra](https://cobra.dev/) — subcommand model and short/long help distinction
- [Clap](https://github.com/clap-rs/clap) — type-driven flag registration and error formatting
- [Typer](https://typer.tiangolo.com/) — type-first CLI design
- [ZLI](https://github.com/xcaeser/zli) — Zig CLI prior art
- [Yazap](https://github.com/prajwalch/yazap) — Zig CLI prior art
