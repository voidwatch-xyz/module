# Voidwatch module

The game module and the upload scripts for [Voidwatch](https://voidwatch.xyz), a dashboard for players who run many OTClientV8 clients.

- `voidwatch/`: the OTClientV8 module. It makes no web requests. It writes the character state into files and reads commands from files.
- `upload/`: the upload script for Windows (`upload.ps1`) and for macOS and Linux (`upload.sh`). It sends the files to the website and brings back the replies.
- `setup-*` and `remove-*`: they install the upload script to start at every login, or remove it.

**The upload script is required.** The game client sends nothing itself, so without the script nothing reaches the website.

## Install

1. Download `voidwatch-module.zip` from the [latest release](https://github.com/voidwatch-xyz/module/releases/latest).
2. Follow `README.txt` in the zip, or the [getting started guide](https://voidwatch.xyz/docs/getting-started).

## Check a download

Every release has a `SHA256SUMS` file. Compare it with the hash of your zip:

```bash
shasum -a 256 voidwatch-module.zip
```

## Adapt the module to a server

Server-specific data (routes, supplies, tasks) comes from adapters. See [adding a server](https://voidwatch.xyz/developers/new-server).

## Release

Push a tag like `v0.3.0`. The release workflow packs the zip and the checksum file and publishes the release.

## Licence

MIT, see `LICENSE`.
