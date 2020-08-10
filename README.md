## arch-installer

A very opinionated Arch Linux installer script.

- Create an encrypted OS (on XFS) and Swap setup on LVM/LUKS
- Create encrypted ZFS datasets for /home and some other mountpoints
  - Dataset gets unlocked on boot using a randomly generated keyfile
- Use GRUB for booting