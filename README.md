# demers-qnap

Configuration code for the Demers machine called qnap.
The hardware is actually a modified QNAP TVS-663 running XCP-ng 8.2.1

## Installation

The server can be configured by calling this one-liner:

<!-- markdownlint-disable MD013 -->
```bash
wget -qO- 'https://raw.githubusercontent.com/jeremfg/setup/refs/heads/main/src/setup_git' | bash -s -- git@github.com:homeinfra/demers-qnap.git main -- ./src/setup
```
<!-- markdownlint-enable MD013 -->

## Hardware

The following hardware changes were made to the stock 4GB configuration:

- Replaced the 512MB internal eUSB DOM with a 64GB SD Card.
  - Using a female DuPont connector to female USB A adaptor cable
  - Using a USB SD Card Reader
    ([Kingston's MobileLite Plus SD Reader](https://www.kingston.com/en/memory-card-readers/mobilelite-plus-sd-reader))
  - Using a 64 GB microSD card
    ([Lexar® microSDXC UHS-I Card E-Series Plus](https://americas.lexar.com/product/lexar-microsdxc-uhs-i-card-e-series-plus/))
  - Using a "SD Adapter for microSD"
    ([Came with the microSD Card pack](https://www.amazon.ca/dp/B09Q8W7KKC))
- Added a [QM2-2P10G1TB](https://www.qnap.com/en/product/qm2-2p10g1tb)
  expansion card. Goal is to get 10 GbE connectivity. Also need more local storage.
  - M.2 Slot 1:
    [Patriot P310](https://www.patriotmemory.com/products/p310-pcie-m-2-internal-ssd)
    240 GB.
  - M.2 Slot 2:
    [Patriot P300](https://www.patriotmemory.com/products/p300-pcie-m-2-internal-ssd)
    128 GB.
- RAM upgraded to 16GB
  - Replaced with 2x8GB DDR3L SODIMM 1866 MHz 2Rx8 Non-ECC Unbuffered from
    [Timetec](https://www.amazon.ca/dp/B07FV16JFQ)
  - Would have preferred ECC memory, but ended up wasting money. Despite the
    AMD CPU supporting ECC, it seems the QNAP BIOS doesn't.
- Replaced the two rear fans with Noctua NF-A9 PWM
- Replaced the PSU fan with Noctua NF-A4x20 FLX

### Local storage situation

Challenging requirements:

- Install XCP-ng, which requires at least 46GB of disk space.
- Existing eUSB DOM is only 512MB in size.
- Can only boot from USB. No support for booting from PCIe NVME drives.
- Do not use one of the 6 3.5" drive bays (we want to maximize for the NAS)
- I want RAID1 redundancy on the critial parts (boot + local VM storage)

I have tried the following (from best option to working option):

#### Industrial eUSB pSLC DOM USB 3

Pros:

- Bougth from Digikey (reputable source)
- Amazing performance
- Should be reliable (pSLC technology, industrial applications)

Cons:

- Very expensive (paid > $500 CAD)
- Maximum size: 32GB

Conclusion:
That was before I figured out XCP-ng would refuse to install on anything less
than 46 GB. Unusable. Thus began a search for a bigger eUSB DOM.

#### Random chinese 64 GB eUSB DOM for Nas purpose

Pros:

- It exists! Only real option I could find as a eUSB DOM >= 64GN
- More reasonable price: ~$60 CAD

Cons:

- Bought from AliExpress (not reputable).
- MLC tecnology (probably not very reliable as a boot drive). At least I'm
  planning for RAID1.
- USB 2.0 only.
- Slow AF

#### SD Card

Pros:

- Should appear as USB Mass Storage to the system's BIOS and we should be able
  to boot form it
- Cheaper and more compact in size than USB NVME

Cons:

- Will a SD card be reliable enough? Contingency with RAID1 regardless.
- Dongle hell. Not a nice physical mounting option.
- USB 3 support? Maybe

Conclusion:
Not ideal, but this works. Bottleneck is USB 2.0 speeds at ~30MBps.
Tucked away between motherboard and internal drive chassis.
I prefer SD Card over other flash<->usb solutions because
I can get a smaller 64GB media. Smaller is better for ease of installation
and not wasting space with a larger boot drive.

### Local storage configuration

I need 3 drives, the first two being redundant/reliable.

1. Boot drive (At least 64 GB)
1. VM Store (At least 64 GB)
1. ISO Store (At least 16 GB)

I went with a quite hacky solution using 2 non-bootable NVME drives.

Boot drive:

- Software RAID1 between the USB SD card and the 240 GB NVME SSD

 VM Store

- Software RAID1 between the 128 GB NVME SDD and a virtual loop device
   mapped after the first 64GB on the 240 GB SSD

ISO Store

- No need fore reundancy. Used a virtual loop device mapped over the remaining
   space on the 240 GB SSD (around ~49 GB left)

If my boot drive ever fails, I won't be able to boot from the RAID1 mirror since
it's located on a NVME SSD. However it should be quite easy to boot on a live CD
and using mdadm, reoncstruct the array and re-populate a new SD card from that
copy. I conside a non-bootable hot-copy that is always up to date with the boot
drive.

### NAS Storage situation

Originally, I though I should be able to use PCI Passthrough to pass the 4 SATA
controllers to a VM running TrueNAS. However, it turns out that IOMMU is not
supported on this hardware.
Furthermore, XCP-ng has known issues making it impossible to mount drives larger
than 2 TiB. I was stuck.
I finally figured out a way to mount my 24 TB drives in a similar fashion to
removable drives by creating a udev storage and symlinks to /dev/sd*. For some
reason, we can only symlink to /dev/sd* and cannot use other locations. The best
documentation on the subject is available
[here](https://forums.lawrencesystems.com/t/xenserver-hard-drive-whole-disk-passthrough-with-xcp-ng/3433).

This all required extensive scripting to detect the drives, create the storage
record and attach the disks to the VM.

### RAM situation

The AMD CPU on this motherboard supports ECC RAM, which would have
been ideal for a server. I did try, but sadly with no joy. It seems
the QNAP BIOS doesn't support it. Regular non-ECC unbuffered RAM it is.

Maxed out at 16 GB (2x8 GB DDR3L), SODIMM.
I went with a Timetec 2Rx8 CL13 1866 Mhz kit, but running at only
1600 MHz (BIOS doesn't support faster).

### Sofware situation

The goal was to have a vHost using XCP-ng. Why virtualize the NAS?
I like being able to take snapshots and restore points between
upgrades or configuration changes. It saved my life many times
in the past. Also, it can be nice to extend our XCP-ng pool.
Having a backup location to run VMs can always be useful.

Because of the strage drive situation however, it makes snapshots a lot more
complex. I will need to detach all the drives before taking a snapshot.

## Development

Using Microsoft VS Code

### Setup

1. Create SSH credentials on your client dev machine if you
don't have any already.
2. Add the public key to `/root/.shh/authorized_keys` on the
server (Qnap TVS-663)
3. Using the VS Code extension "Remote - SSH" from Microsoft, edit
your client-local `~/.ssh/config` by adding the following entry:

```txt
Host Qnap
  HostName qnap.demers.jeremfg.com
  User root
  PreferredAuthentications publickey
  IdentityFile <private key>
```

4. Open a remote session in VS Code, on Qnap, and open this git
repository folder which should already be on the server following
the installation above.

## QNAP HAL support

I was able to get almost everything working:

- Physical buttons: Power, USB Copy, Reset
- LEDs: Disk Error 1-6, Status Green, Status Red, Front USB
- Beep sounds (buzzer)

Not working:

- Front panel LCD

Strangely, the one piece of hardware everyong seems to get working easily, the
LCD panel, is the only one piece of custom hardware I was unable to get working.

It should be as simple as running /dev/ttyS1 @ 1200 bauds. But it's not working
for me. I'm stuck with the blue LCD backlight on.

### TODO

- [x] HAL Support
  - [x] LCD + Buttons (NOT WORKING)
- [ ] Report failing drive on the corresponding LEDs.
