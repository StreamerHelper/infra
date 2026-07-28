# Third-party notices

## Biliup

- Project: <https://github.com/biliup/biliup>
- Pinned revision: `adf6a1c03be9f777a76c8c501038c27f3d90a097`
- Crate license declaration: `MIT OR Apache-2.0`
- Repository license: MIT
- Copyright: Biliup contributors; the repository license identifies
  `Copyright (c) 2019 ForgQi`.

This project calls Biliup through its public Rust API and does not copy the
Biliup Douyin implementation into this source tree.

## A-Bogus implementation lineage

Biliup pull request
[biliup/biliup#1451](https://github.com/biliup/biliup/pull/1451) attributes its
A-Bogus implementation to:

- [Johnserf-Seed/f2](https://github.com/Johnserf-Seed/f2), Apache License 2.0,
  authored by JohnserfSeed.
- [hua0512/rust-srec](https://github.com/hua0512/rust-srec), MIT License.

Those implementations are consumed transitively through the pinned Biliup
dependency. Their code is not copied into this directory.

The complete resolved Rust dependency graph is fixed by `Cargo.lock`. Container
release builds must use `cargo build --locked`.
