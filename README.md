# Fangz

Zig CLI library.

## Usage

Check `src/tests/` for usage examples.

## Credits

- [Yazap](https://github.com/prajwalch/yazap): Forked from.
- [Cobra](https://github.com/spf13/cobra): As inpiration.

## Key Features:

- [**Options (short and long)**](#adding-arguments):
  - Providing values with `=`, space, or no space (`-f=value`, `-f value`, `-fvalue`).
  - Supports delimiter-separated values with `=` or without space (`-f=v1,v2,v3`, `-fv1:v2:v3`).
  - Chaining multiple short boolean options (`-abc`).
  - Providing values and delimiter-separated values for multiple chained options using `=` (`-abc=val`, `-abc=v1,v2,v3`).
  - Specifying an option multiple times (`-a 1 -a 2 -a 3`).

- [**Positional arguments**](#adding-arguments):
  - Supports positional arguments alongside options for more flexible command-line inputs. For example:
    - `command <positional_arg>`
    - `command <arg1> <arg2> <arg3>`

- [**Nested subcommands**](#adding-subcommands):
  - Organize commands with nested subcommands for a structured command-line interface. For example:
    - `command subcommand`
    - `command subcommand subsubcommand`

- [**Automatic help handling and generation**](#handling-help)

- **Custom Argument definition**:
  - Define custom [Argument](/src/Arg.zig) types for specific application requirements.

## Limitations:

- [ ] Does not support delimiter-separated values using space (`-f v1,v2,v3`).
- [ ] Does not support providing value and delimiter-separated values for multiple chained options using space (`-abc value, -abc v1,v2,v3`).
