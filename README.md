# My OpenClaw

My personal [OpenClaw](https://openclaw.ai) assistant for everyday tasks, family
coordination, research, and coding. It is available through Telegram and Discord
and runs on Azure, so I can use it from my phone without keeping my computer on.

## My setup

The choices specific to this installation are:

- **Hosting:** an Azure VM with daily disk snapshots and Azure Monitor.
- **Chat:** Telegram and Discord for personal and family conversations.
- **Model:** GPT-6.1 Sol through GitHub Copilot.
- **Assistants:** a general assistant, an orchestrator, and a fitness assistant.
  The separate `healthcheck` agent is an internal diagnostic.
- **Memory:** automatic cross-conversation recall and Memory Wiki.
- **Integrations:** eBird and Pondlog, with Google tools available when configured.

## This repository

This repository contains my OpenClaw configuration, workspace templates,
integration launchers, and maintenance scripts. Personal conversations,
private workspace content, and credentials are not included.

## Documentation

| Topic | Reference |
|---|---|
| Setting up an installation | [Getting started](docs/getting-started.md) |
| Running and updating it | [Operations](docs/operations.md) |
| Backups and restore | [Backup and restore](docs/backup-restore.md) |
| Access and privacy | [Security model](docs/security-model.md), [telemetry privacy](docs/telemetry-privacy.md), and [credentials](docs/keyvault-integration.md) |
| Installed software versions | [Runtime versions](config/runtime-versions.json) |

For everyday OpenClaw features, see the [OpenClaw documentation](https://docs.openclaw.ai).
