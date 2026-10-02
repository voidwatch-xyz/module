# Voidwatch module

The game module and the upload scripts for [Voidwatch](https://voidwatch.xyz), a dashboard for players who run many OTClientV8 clients.

- `voidwatch/`: the OTClientV8 module. It makes no web requests. It writes the character state into files; commands from files come later. A button in the client's top bar opens a window that shows what it sends.
- `voidwatch/bot/` and the `orion*.lua` adapters: what the stock cavebot, vBot and Orion-OTS add, such as routes, tasks, loot, blessings and death redemption.
- `upload/`: the upload script for Windows (`upload.ps1`) and for macOS and Linux (`upload.sh`), also for clients in Wine or CrossOver. It sends the files to the website and brings back the replies.
- `setup-*` and `remove-*`: they install the upload script to start at every login, or remove it.

**The upload script is required.** The game client sends nothing itself, so without the script nothing reaches the website.

Verified on Orion-OTS. Most other servers lock their client against modules.

## Install

1. Download `voidwatch-module.zip` from the [latest release](https://github.com/voidwatch-xyz/module/releases/latest).
2. Follow `README.txt` in the zip, or the [getting started guide](https://voidwatch.xyz/docs/getting-started).

## Check a download

Every release has a `SHA256SUMS` file. Compare it with the hash of your zip:

```bash
shasum -a 256 voidwatch-module.zip
```

## Update

From module 0.6.0, the Voidwatch window in the game shows **Update to X.Y.Z** when a newer release is out. The upload script downloads the zip and `SHA256SUMS` from the releases of this repo, checks the hash and keeps the old module as a backup. **Roll back** puts the backup back. The script never takes code from the website.

## Adapt the module to a server

Server-specific data (routes, supplies, tasks) comes from adapters. See [adding a server](https://voidwatch.xyz/developers/new-server).

## Release

Push a tag like `v0.6.0`. The release workflow packs the zip and the checksum file and publishes the release. Every client with module 0.6.0 or newer then offers it as an update.

## Licence

MIT, see `LICENSE`.
