# Blizzard DeScrewer

A small Windows tool that fixes the infamous **Battle.net installer "stuck at 45%"** problem — it wipes every left-over Blizzard / Battle.net file, folder and registry key, then downloads and runs a fresh installer.

![Blizzard DeScrewer screenshot](screenshot.png)

It also handles the deeper causes that keep the installer stuck: firewall/WMI trouble, a stale hosts file, the Secondary Logon service, a broken network stack, corrupted system files, and a launcher stuck in the wrong language.

### 👉 Full guide, how it works, and download: **[gabrielmoraru.com — Battle.net installer stuck at 45%](https://gabrielmoraru.com/solution-to-battle-net-installer-stuck-to-45/)**

That page explains *why* the installer freezes, walks through every fix (with and without the tool), and has the latest download.

---

Built with [Delphi](https://gabrielmoraru.com) and the [LightSaber](https://github.com/GabrielOnDelphi/Delphi-LightSaber) library. Freeware, MIT — see [LICENSE](LICENSE). Author: Gabriel Moraru.
