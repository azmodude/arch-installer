# -*- mode: ruby -*-
# vi: set ft=ruby :
ENV['VAGRANT_DEFAULT_PROVIDER'] = 'libvirt'

Vagrant.configure("2") do |config|

  config.vm.define :archbox do |arch|
    arch.vm.box = "archlinux/archlinux"
    # enable ssh forwarding
    arch.ssh.forward_agent = true

    arch.vm.synced_folder '.', '/vagrant', type: 'sshfs'
    # as we are using a GUI, modify VM to accomodate for that
    arch.vm.provider :libvirt do |lv|
      # lv.loader = '/usr/share/qemu/OVMF.fd'
      lv.cpus = 2
      lv.memory ='1536'
      lv.video_type = 'qxl'
      lv.graphics_type ='spice'
      lv.keymap = 'de'
      lv.channel :type => 'spicevmc', :target_name => 'com.redhat.spice.0', :target_type => 'virtio'
      # we need SCSI as bus here since udev (usually) does not create by-id
      # links when virtio devices are used; particularly bad when used with
      # zfs as we use /dev/disk/by-id/xxxyyyzzz here.
      lv.storage :file, :size => '40G', :type => 'qcow2', :bus => 'scsi', :device => 'sdz'
    end

    arch.vm.box_check_update = true

    $provisioning_script_archkeys = <<-'SCRIPT'
        pacman -Syu --noconfirm
        rm -rf /etc/pacman.d/gnupg
        # Work around Arch's keymgmt being anal sometimes
        pacman-key --init && pacman-key --populate archlinux && \
            pacman -Syw --noconfirm archlinux-keyring && \
            pacman --noconfirm -S archlinux-keyring
SCRIPT
    $provisioning_script_installation = <<-'SCRIPT'
      pacman -S --noconfirm git
      git clone https://github.com/azmodude/arch-installer
SCRIPT

    $provisioning_script_archiso = <<-'SCRIPT'
        pacman -S --noconfirm archiso git
        cp -r /usr/share/archiso/configs/releng /root/archiso

        # get and lsign archzfs keys
        pacman-key --keyserver keyserver.ubuntu.com -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
        pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
        # workaround for dns being flaky sometimes
        ping -c 5 kernels.archzfs.com || true
        # eof is quoted so it will not expand $repo
        cat <<-'EOF' >> /root/archiso/pacman.conf
			[archzfs]
			Server = http://archzfs.com/$repo/x86_64
			Server = http://mirror.sum7.eu/archlinux/archzfs/$repo/$arch
			Server = https://mirror.biocrafting.net/archlinux/archzfs/$repo/$arch
			Server = https://mirror.in.themindsmaze.com/archzfs/$repo/$arch
			[zfs-linux]
			Server = http://kernels.archzfs.com/$repo
EOF
        pacman -Sy
        cat <<-EOF >> /root/archiso/packages.x86_64
			# azmo
			reflector
			git
			neovim
			zfs-linux
			zfs-utils
EOF
      git clone https://github.com/azmodude/arch-installer \
        /root/archiso/airootfs/root/arch-installer
      cd /root/archiso && mkarchiso -v . && cp /root/archiso/out/*.iso /vagrant
SCRIPT

    arch.vm.provision "shell", inline: $provisioning_script_archkeys

    if ENV['BUILDISO']
      arch.vm.provision "shell", inline: $provisioning_script_archiso
    else
      arch.vm.provision "shell", inline: $provisioning_script_installation
    end

  end
end
