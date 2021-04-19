destroy:
	vagrant destroy -f
up:
	vagrant up
reload:
	vagrant reload
ssh:
	TERM=xterm-256color vagrant ssh
move-iso:
	-mv archlinux-*-azmo-zfs.iso old-isos
build-iso:
	VAGRANT_VAGRANTFILE=./Vagrantfile.archiso vagrant up
rename-iso-zfs:
	$(eval FILE=$(shell find . -type f -regextype posix-extended -regex "./archlinux-[0-9\.]+-x86_64.iso"))
	$(eval FILE_NO_EXT=$(shell basename $(FILE) .iso))
	mv $(FILE) $(FILE_NO_EXT)-azmo-zfs.iso
rename-iso:
	$(eval FILE=$(shell find . -type f -regextype posix-extended -regex "./archlinux-[0-9\.]+-x86_64.iso"))
	$(eval FILE_NO_EXT=$(shell basename $(FILE) .iso))
	mv $(FILE) $(FILE_NO_EXT)-azmo.iso
iso: build-iso move-iso rename-iso destroy
clean: destroy up reload
cleanssh: clean ssh
