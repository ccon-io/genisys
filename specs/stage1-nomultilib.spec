subarch: ###BUILD_ARCH###
target: stage1
version_stamp: ###VERSION_STAMP###
rel_type: ###BUILD_NAME###/###BUILD_TARGET###
profile: ###BASE_PROFILE_PATH###
snapshot: ###PORTAGE_SNAPSHOT###
source_subpath: ###SRC_PATH###
portage_confdir: /etc/catalyst/overlays/portage
kerncache_path: /var/data/catalyst/kerncache/###BUILD_NAME###
update_seed: yes
update_seed_command: --update --deep @world
