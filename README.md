# Fangz

A CLI library for Zig inspired by Go's Cobra, Rust's Clap and Python's Typer.

## TODO

- [ ] Help formatting isn't aware of the terminal width, which causes terminal-based wrapping instead of a smarter wrapping, for example `cargo doc --help` will be wrapped with the same indentation as the first line, in constrat to the library's help, which will be wrapped and shown as a new line with no indentation.

## Credits

- [Cobra](https://cobra.dev/)
- [Typer](https://typer.tiangolo.com/)
- [Clap](https://github.com/clap-rs/clap)
- [ZLI](https://github.com/xcaeser/zli)
- [Yazap](https://github.com/prajwalch/yazap)
