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
    arch.vm.provider :virtualbox do |vb|
      disk_file = 'tmp/arch_install.vdi'
      vb.name = "arch"
      vb.gui = true
      vb.customize ["modifyvm", :id, "--vram", "64"]
      vb.customize ['modifyvm', :id, '--clipboard', 'bidirectional']
      vb.customize ["modifyvm", :id, "--accelerate3d", "on"]
      unless File.exist?(disk_file)
        vb.customize ['createhd', '--filename', disk_file, '--size', 20 * 1024]
      end
      vb.customize ['storageattach', :id, '--storagectl', 'SATA Controller', '--port', 1, '--device', 0, '--type', 'hdd', '--medium', disk_file]
    end
    arch.vm.provider :libvirt do |lv|
      # lv.loader = '/usr/share/qemu/OVMF.fd'
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
        pacman -Sy
        rm -rf /etc/pacman.d/gnupg
        # Work around Arch's keymgmt being anal sometimes
        pacman-key --init && pacman-key --populate archlinux && \
            pacman -Syw --noconfirm archlinux-keyring && \
            pacman --noconfirm -S archlinux-keyring

        # copy pacman related files over
        cp /vagrant/etc/pacman.d/* /etc/pacman.d
        cp /vagrant/etc/pacman.conf /etc/pacman.conf
        # get and lsign archzfs keys
        pacman-key --keyserver pool.sks-keyservers.net -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
        pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
        pacman -Syyu --noconfirm
        pacman -S --noconfirm zfs-linux zfs-utils
SCRIPT
    arch.vm.provision "shell", inline: $provisioning_script_archkeys

  end
end
