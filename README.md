## arch-installer

A very opinionated Arch Linux installer script.

- Create an encrypted OS (on XFS) and Swap setup on LVM/LUKS
- Create encrypted ZFS datasets for /home and some other mountpoints
  - Dataset gets unlocked on boot using a randomly generated keyfile
- Use GRUB for booting
  - systemd-boot would have been a nice choice, but the UEFI-only nature makes testing in vagrant way harder. Most boxes do not support UEFI.