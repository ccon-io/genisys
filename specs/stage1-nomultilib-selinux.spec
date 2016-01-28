subarch: ###BUILD_ARCH###
target: stage1
version_stamp: ###VERSION_STAMP###
rel_type: ###BUILD_NAME###/###BUILD_TARGET###
profile: ###BASE_PROFILE_PATH###
snapshot: ###PORTAGE_SNAPSHOT###
source_subpath: ######BUILD_SRC_PATH######
portage_confdir: ###CATALYST_OVERLAY_DIR###/portage
kerncache_path: ###CATALYST_BASE_DIR###/kerncache/###BUILD_NAME###
update_seed: yes
update_seed_command: --update --deep @world
