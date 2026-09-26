# Linux CAC

A project for consistently configuring Debian-based Linux distributions to work with Common Access Cards (CACs).

## Installation

DoD certificates come from the public Cyber Exchange PKCS#7 bundle:
https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip
listed on https://www.cyber.mil/pki-pke/tools-configuration-files

Download, review, then run. Do not pipe a remote script into sudo bash.

```bash
curl -fsSLO https://raw.githubusercontent.com/seakintruth/linux_cac/main/cac_setup.sh
less cac_setup.sh
sudo bash cac_setup.sh
```

The script prompts first for extra public bundles (ECA, external partners, WCF, or all).
Non-interactive: `sudo CAC_BUNDLES=all bash cac_setup.sh`

Requires wget, unzip, and openssl (installed by the script).

## Supported configurations

Only rows we have actually run, or that the Proxmox lab in [`iac/`](iac/README.md) has smoked, belong here.

| Distribution | Version | Browsers | Status |
| --- | --- | --- | --- |
| Ubuntu | 26.04 | Snap Firefox, Chrome | Verified on hardware |
| Ubuntu | 24.04 LTS | Snap Firefox, Chrome | Planned in `iac/matrix.yml` |
| Ubuntu | 22.04 LTS | Snap Firefox, Chrome | Planned in `iac/matrix.yml` |
| Debian | 12 / 13 | Firefox ESR | Planned in `iac/matrix.yml` |
| Linux Mint | 22 | Firefox | Planned in `iac/matrix.yml` |
| Fedora | — | — | Blocked: script is `apt` only |

GitHub Actions runs ShellCheck only. CAC, USB, and browser-picker tests run on Proxmox via Ansible. See [iac/README.md](iac/README.md).

## License
MIT. See LICENSE.
