# chise.sh

Minimal Debian 13 (Trixie) Btrfs installation script — ~150 MB after install.

## Key Features

- Btrfs with zstd compression and SSD optimizations  
- IPv4/IPv6 support via systemd-networkd (selectable: DHCP or static)  
- Works on UEFI (GPT) and BIOS (MBR) systems  
- Enables BBR + FQ and zRAM by default  
- SSH key–only access  

## Usage

### On Alpine / Debian Rescue System / Live OS

```bash
curl -LO cdn.jsdelivr.net/gh/angr6908/chise/chise.sh && sh chise.sh --ssh-key "your-key"
```

### On Any System

#### Step 1: Reboot into Alpine Live OS

```bash
curl -LO cdn.jsdelivr.net/gh/bin456789/reinstall/reinstall.sh && bash reinstall.sh alpine --hold 1 --ssh-key "your-key"
```

#### Step 2: Install chise.sh
```bash
curl -LO cdn.jsdelivr.net/gh/angr6908/chise/chise.sh && sh chise.sh --ssh-key "your-key"
```
