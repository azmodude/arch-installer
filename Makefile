destroy:
	vagrant destroy -f
up:
	vagrant up
reload:
	vagrant reload
ssh:
	TERM=xterm-256color vagrant ssh
clean: destroy up reload
cleanssh: clean ssh
