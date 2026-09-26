<h1 align="center">Linux CAC</h1>

<p align='center'>
  <a href="https://github.com/sponsors/jdjaxon"><img alt="Sponsor" src="https://img.shields.io/badge/sponsor-30363D?style=flat&logo=GitHub-Sponsors&logoColor=#white" /></a>
</p>

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

## License
MIT. See LICENSE.
