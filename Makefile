destroy:
	vagrant destroy -f
up:
	vagrant up
reload:
	vagrant reload
ssh:
	TERM=xterm-256color vagrant ssh
build-iso:
	VAGRANT_VAGRANTFILE=./Vagrantfile.archiso vagrant up
iso: build-iso destroy
clean: destroy up reload
cleanssh: clean ssh
