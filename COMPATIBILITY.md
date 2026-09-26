# Compatibility details

The README lists only OS × browser pairs that passed. This file is the log.

Status values:

- **verified** — `50_gui` with a real CAC reader (guest saw the reader; browser opened a CAC URL)
- **smoke** — `40_smoke` only (DoD Root in an NSS DB, `pcscd` running; no card)
- **planned** — row exists in [`iac/matrix.yml`](iac/matrix.yml), not run yet
- **blocked** — script cannot install on that OS yet

Screenshots from `50_gui` stay on the control node under `iac/screenshots/` (gitignored). Attach a screenshot to the PR or issue when you change a row from planned → verified. Do not commit PNGs here.

## Verified

| Date | OS | Browser | Host | Notes |
| --- | --- | --- | --- | --- |
| 2026-09-26 | Ubuntu 26.04 Resolute | Snap Firefox | Metal (ATOP NUC) | CAC login already worked via `firefox:pcscd`. Ubuntu `apt` `firefox` is the `1snap1` stub. |
| 2026-09-26 | Ubuntu 26.04 Resolute | Google Chrome | Metal (ATOP NUC) | NSS import into Chrome/Chromium DBs. Headless `--disable-gpu` can trap; skip launch when a `cert9.db` already exists. |

## Smoke

_None yet._

## Planned

| OS | Browser | Template VMID (example) |
| --- | --- | --- |
| Ubuntu 24.04 LTS | Snap Firefox | 9004 |
| Ubuntu 24.04 LTS | Google Chrome | 9004 |
| Ubuntu 22.04 LTS | Snap Firefox | 9002 |
| Debian 12 | Firefox ESR | 9012 |
| Debian 13 | Firefox ESR | 9013 |
| Linux Mint 22 | Firefox | 9022 |

## Blocked

| OS | Reason |
| --- | --- |
| Fedora | `cac_setup.sh` is `apt` only. Add a `dnf` path before this row can move to planned. |

## How a row moves

1. Add or edit the combination in [`iac/matrix.yml`](iac/matrix.yml).
2. Run `40_smoke.yml`. If it passes, set status **smoke** here.
3. Run `50_gui.yml` with the reader attached. If the guest sees the reader and the browser shows a cert picker or completes CAC login, set status **verified**, fill the Verified table, and add the OS × browser pair to the README list.
4. Failed runs stay in this file under a short “Failed” note. Do not leave a broken pair on the README.

Lab mechanics (USB flock, playbooks, vault PIN): [`iac/README.md`](iac/README.md).
