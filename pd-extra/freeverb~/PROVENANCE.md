# freeverb~ - vendored source

`freeverb~.c` is vendored (copied verbatim, no local modifications) from:

- Upstream: <https://github.com/pd-l2ork/pd>
- Path: `externals/freeverb~/`
- Commit: `eb8ffbab8b65c75609fd9479d4b872bfefdd9f7d`

It used to be pulled in through the `pd-extra/pd` git submodule. That submodule
was removed because it is a ~250 MB tree with seven nested submodules, two of
which use `git://` URLs, including `git://git.drogon.net/wiringPi`, whose host
is dead. A local clone can skip the failed submodule, but Xcode Cloud's "Resolve
Git submodules" step recurses unconditionally and aborts the whole build on it.
This single 26 KB file was the only thing the Xcode project ever consumed from
that submodule.

To update: fetch the file from the upstream path above and record the new commit
here. `freeverb~.c` compiles with `PD` defined and only needs `m_pd.h`, which
comes from the `libpd` submodule (`libpd/pure-data/src`, already on
`USER_HEADER_SEARCH_PATHS`).

Licensed GPL-2.0 - see `LICENSE.txt`, retained alongside the source.
