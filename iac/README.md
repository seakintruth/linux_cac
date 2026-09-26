# Proxmox CAC test lab

Ansible drives a Proxmox cluster through the OS × browser matrix.
GitHub Actions only lints `cac_setup.sh`. Real CAC and USB tests run here.

## Why not CI runners

A GitHub-hosted runner cannot attach a CAC reader, cannot pop a browser
certificate picker, and cannot type a PIN. Those need a KVM desktop VM
with USB passthrough on a node you control.

## Layout

```
iac/
  matrix.yml                 # OS × browser combinations
  inventory/hosts.example.yml
  group_vars/all.yml.example
  playbooks/
    10_provision.yml         # clone + start VMs from cloud-init templates
    20_guest.yml             # desktop, browsers, auto-login user
    30_cac_setup.yml         # copy and run cac_setup.sh
    40_smoke.yml             # certutil + pcsc_scan (no PIN)
    50_gui.yml               # attach USB, open CAC URL, screenshot
    60_teardown.yml          # detach USB, stop or destroy VMs
  scripts/
    usb_attach.sh            # run on the Proxmox node
    usb_detach.sh
```

## One reader, many VMs

QEMU will give the USB reader to **one** VM at a time. Playbooks take a
flock on the Proxmox node, attach `host=<vendor>:<product>`, run tests,
then detach. Do not start `50_gui.yml` against two hosts in parallel.

Find the reader on the node that has it plugged in:

```bash
ssh root@pve 'lsusb | grep -iE "scm|identiv|omnikey|gemalto|broadcom|cac"'
# example: 04e6:5116  → set cac_usb_id: "04e6:5116"
```

## Stages

| Stage | Needs card | What it proves |
| --- | --- | --- |
| `30` + `40` | No | Packages, DoD zip, NSS import, `pcscd` running |
| `50` with card | Yes | Guest sees the reader (`pcsc_scan`), browser cert list |
| `50` with PIN | Yes + vault PIN | Optional: `ydotool` types the PIN (do not commit it) |

Playwright cannot drive the OS/NSS PIN dialog by itself. Stage 50 takes
a screenshot of the picker. PIN entry is opt-in via Ansible Vault.

## First-time setup

On the Ansible control machine (can be a LXC on the cluster):

```bash
sudo apt install -y ansible python3-proxmoxer python3-requests python3-pip
ansible-galaxy collection install -r iac/requirements.yml
cp iac/inventory/hosts.example.yml iac/inventory/hosts.yml
cp iac/group_vars/all.yml.example iac/group_vars/all.yml
# edit hosts.yml and all.yml — never commit those two files
```

Build **one cloud-init template per OS** in Proxmox (Ubuntu 22.04/24.04/26.04,
Debian 12/13). Give each a qemu-guest-agent, cloud-init user, and SSH key.
Record the template VMID in `matrix.yml`.

Then:

```bash
cd iac
ansible-playbook -i inventory/hosts.yml playbooks/10_provision.yml
ansible-playbook -i inventory/hosts.yml playbooks/20_guest.yml
ansible-playbook -i inventory/hosts.yml playbooks/30_cac_setup.yml
ansible-playbook -i inventory/hosts.yml playbooks/40_smoke.yml
# plug the reader into the USB node, then:
ansible-playbook -i inventory/hosts.yml playbooks/50_gui.yml --limit cac-u26-ff
ansible-playbook -i inventory/hosts.yml playbooks/60_teardown.yml
```

`cac_setup.sh` is still Debian/Ubuntu `apt` only. Fedora/RHEL guests are
in the matrix as `unsupported` until the script grows a `dnf` path.
