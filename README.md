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
- Very few options in terms of boot devices.
- I want some level of redundancy on the boot drive, so we're not completely lost when the SSD's flash wears down and fails.

We can only boot from the eUSB DOM, since the following options aren't available/ideal:
- SATA Hard Disks (x6). The SATA controllers are passed (PCI passthrough) to the NAS VM. Beside, this wouldn't be so smart to sacrifice one disk to use as a boot drive
- M.2 NVMEs on the expansion card. The system's BIOS cannot boot from those
- USB drive connected on one of the external ports: Impractical. Not a nice solution to have dongles hanging down like appendages permanently from an external USB port. Imagine the accidental unplugging just by bumping into it.

So I've reached the following compromised of using the internal eDOM as a boot drive, but configured in RAID 1 (software) with the Patriot P300 on the expansion card. While the M.2 drive cannot be used to boot, it can at least be considered like an offline always-up-tp-date backup to restore a new eUSB DOM if it ever fails. In case of eDOM failure, I suspect we could replace it, boot on a live CD linux OS, and use mdadm to rebuild the eDOM.

### RAM situation
The AMD CPU on this motherboard supports ECC RAM, which would have been ideal for a server. I did try, but sadly with no joy. It seems the QNAP BIOS doesn't support it. Regular non-ECC unbuffered RAM it is.

Maxed out at 16 GB (2x8 GB DDR3L), SODIMM.
I went with a Timetec 2Rx8 CL13 1866 Mhz kit, but running at only 1600 MHz (BIOS doesn't support faster).

### Sofware situation
The goal was to have a vHost using XCP-ng. Why virtualize the NAS? I like being able to take snapshots and restore points between upgrades or configuration changes. It saved my life many times in the past. Also, it can be nice to extend our XCP-ng pool. Having a backup location to run VMs can always be useful.

## Development ##
Using Microsoft VS Code

### Setup
1. Create SSH credentials on your client dev machine if you don't have any already.
2. Add the public key to `/root/.shh/authorized_keys` on the server (Qnap TVS-663)
3. Using the VS Code extension "Remote - SSH" from Microsoft, edit your client-local `~/.ssh/config` by adding the following entry:
```
Host Qnap
  HostName qnap.demers.jeremfg.com
  User root
  PreferredAuthentications publickey
  IdentityFile <private key>
```
4. Open a remote session in VS Code, on Qnap, and open this git repository folder which should already be on the server following the installation above.

### TODO

- [x] Config library (.env files) (Still need to use it, and thus confirm it works with SOPS+AGE)
- [ ] PCI Passthrough
- [ ] Fans and sensors
- [x] 10Gbe NIC driver (Possibly needs more configuration, like MTU)
- [ ] LCD
- [ ] XCP-ng email notifications
- [ ] NUT UPS support
- [ ] TrueNAS VM creation
- [ ] Linter (pre-commit hook)

### Nice to have

- [ ] When generating a new key for github, use the github CLI to install it