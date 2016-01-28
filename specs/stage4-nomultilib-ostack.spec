subarch: ###BUILD_ARCH###
target: stage4
version_stamp: ###VERSION_STAMP###
rel_type: ###BUILD_NAME###/###BUILD_TARGET###
profile: ###BASE_PROFILE_PATH###
snapshot: ###PORTAGE_SNAPSHOT### 
source_subpath: ######BUILD_SRC_PATH###### 
portage_confdir: ###CATALYST_OVERLAY_DIR###/portage
kerncache_path: ###CATALYST_BASE_DIR###/kerncache/###BUILD_NAME###
stage4/packages:
  app-admin/logrotate
	app-admin/pwgen
	app-admin/sudo
	app-admin/rsyslog
  app-admin/localepurge
  app-admin/ansible
  app-arch/unzip
	app-crypt/gnupg
	app-editors/vim
  app-emulation/cloud-init
  app-forensics/aide 
  app-forensics/rkhunter
  app-misc/tmux
	app-misc/vlock
  app-portage/layman
  app-portage/eix
  app-portage/euses
  app-portage/genlop
  app-portage/gentoolkit 
	app-text/wgetpaste
  dev-python/boto
  dev-python/pip
  dev-python/pyzmq
	dev-vcs/git
	media-gfx/fbgrab
	net-analyzer/netcat
	net-analyzer/nmap
	net-analyzer/tcpdump
	net-analyzer/traceroute
	net-firewall/iptables
  net-firewall/ufw
  net-dns/bind-tools
	net-misc/dhcpcd
	net-misc/iputils
	net-misc/whois
  net-misc/openntpd
  net-p2p/rtorrent
  sys-apps/dmidecode
  sys-apps/elfix 
	sys-apps/ethtool
	sys-apps/hdparm
	sys-apps/hwsetup
	sys-apps/iproute2
	sys-apps/memtester
	sys-apps/mlocate
	sys-apps/netplug
	sys-apps/sdparm
	sys-block/disktype
	sys-block/parted
	sys-block/partimage
	sys-boot/grub
	sys-boot/syslinux
  sys-cluster/glusterfs
  sys-devel/bc
	sys-fs/cryptsetup
	sys-fs/dmraid
	sys-fs/e2fsprogs
	sys-fs/lsscsi
	sys-fs/lvm2
	sys-kernel/genkernel
  sys-libs/ncurses
	sys-power/acpid
	sys-process/htop
	sys-process/vixie-cron
	www-client/links
stage4/use:
	bash-completion
  elasticsearch
  minimal
  deblob
  -X
  -doc
  -examples
	mmx
	sse
	sse2
	urandom
boot/kernel: gentoo
boot/kernel/gentoo/sources: ###BASE_PROFILE###-sources
boot/kernel/gentoo/config:  /etc/catalyst/kconfig/###BUILD_ARCH###-###BASE_PROFILE###-###BUILD_TARGET###-###TARGET_KERNEL###.config
boot/kernel/gentoo/extraversion: ###BUILD_NAME###
boot/kernel/gentoo/gk_kernargs: --all-ramdisk-modules
stage4/users: ###CATALYST_USERS###
#stage4/fsscript: /release/releng/releases/weekly/scripts/cloud-prep.sh
stage4/root_overlay: ###CATALYST_OVERLAY_DIR###/root/
stage4/rcadd:
	acpid|default
	cloud-config|default
	cloud-final|default
	cloud-init-local|default
	cloud-init|default
	cronie|default
	dhcpcd|default
	net.lo|default
	netmount|default
	sshd|default
	rsyslog|default
