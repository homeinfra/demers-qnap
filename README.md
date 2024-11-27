# demers-qnap

Configuration code for the Demers machine called qnap. The hardware is actually a modified QNAP TVS-663 running XCP-ng 8.3.

## Installation
The server can be configured by calling this one-liner:
```bash
wget -qO- 'https://raw.githubusercontent.com/jeremfg/setup/refs/heads/feature/linux-setup/src/setup_git.sh' | bash -s -- git@github.com:homeinfra/demers-qnap.git feature/initial -- ./src/setup.sh
```

## Hardware
The following hardware changes were made to the stock 4GB configuration:

- Replaced the 512MB eUSB DOM with a 64GB eUSB DOM.
- Added a QM2-2P10G1TB expansion card.
  - M.2 Slot 1: Patriot P300 128 GB.
  - M.2 Slot 2: Empty.
- RAM upgraded to 16GB
- Replaced the two rear fans with Noctua NF-A9 PWM
- Replaced the PSU fan with Noctua NF-A4x20 FLX

### Boot drive situation
Challenges:
- Install XCP-ng, which requires at least 46GB of disk space. The stock boot drive is only 512MB in size.
- Very few options in terms of boot drive.
- I want some level of redundancy on the boot drive, so we're not completely lost when the flash wears down and fails.

We can only boot from the eUSB DOM, since the following options aren't available/ideal:
- Hard Disks (x6). The SATA controller are passed (PCI passthrough) to the VM handling the NAS. Beside, this wouldn't be so smart to sacrifice one disk to use as a boot drive
- M.2 on the expansion card. The system cannot boot from those
- USB drive connected on one of the external ports: Impractical. Not a nice solution to have dongles hanging down permanently from a USB port. Accidents can happen easily.

So I've reached the following compromised of using the eDOM as a boot drive, but configured in RAID 1 (software) with the Patriot P300 on the expansion card. While the M.2 drive cannot be used to boot, it can at least be considered a live always-up-tp-date backup to restore a new eUSB DOM if it ever fails.

### RAM situation
The AMD CPU on this motherboard supports ECC RAM, which would have been ideal for a server. I did try, but sadly with no joy. It seems the QNAP BIOS doesn't support it.

Maxed out at 16 GB (2x8 GB DDR3L), SODIMM.
I went with the Timetec 2Rx8 CL13 1866 Mhz kit, but running at only 1600 MHz (BIOS doesn't support faster).

### Sofware situation
The goal was to have a virtual platform using XCP-ng. Why virtualize the NAS? I like being able to take snapshot and restore points before doing upgrades, configuration changes or such. It saved my life many times in the past. So yeah, due to the limited resources of this device

## Development ##
Using Microsoft VS Code

### Setup
1. Create SSH credentials on your client dev machine if you don't have any already.
1. Add the public key to `/root/.shh/authorized_keys` on the server (Qnap)
1. Using extension "Remote - SSH" from Microsoft, edit your client-local `~/.ssh/config` by adding the following entry:
```
Host Qnap
  HostName qnap.demers.jeremfg.com
  User root
  PreferredAuthentications publickey
  IdentityFile <private key>
```
4. Open a remote session in VS Code, on Qnap, and open this repository on 

### TODO

- [ ] SOPS+AGE
- [ ] Config library (.env files)
- [ ] PCI Passthrough
- [ ] Fans and sensors
- [ ] 10Gbe NIC driver
- [ ] LCD
- [ ] Linter (pre-commit hook)
