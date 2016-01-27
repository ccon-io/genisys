#!/bin/env bash

set -u -o pipefail

declare -r WGET='/usr/bin/wget'
declare -r CURL='/usr/bin/curl'
declare -r LFTP='/usr/bin/lftp'
declare -r GPG='/usr/bin/gpg'
declare -r SHA512SUM='/usr/bin/sha512sum'
declare -r OPENSSL='/usr/bin/openssl'
declare -r CATALYST='/usr/bin/catalyst'
declare -r LOGGER='/usr/bin/logger'
declare -r EC2_BUNDLE_IMAGE='/usr/bin/ec2-bundle-image'

declare -ri CPU_COUNT=$(nproc)
declare -i BATCH_MODE='0'
declare -i SCRIPT_SCOPE='0'
declare -i VERBOSITY='0'
declare -i DEBUG='0'
declare -i CLEAR_CCACHE='0'
declare -i QUIET_OUTPUT='0'
declare -i NO_MULTILIB='0'
declare -i SELINUX='0'
declare -i AWS_SUPPORT='0'
declare -i OPENSTACK_SUPPORT='0'
declare -i TAKE_SNAPSHOT='1'

declare -r COLOUR_RED='\033[0;31m'
declare -r COLOUR_GREEN='\033[0;32m'
declare -r COLOUR_RST='\033[0m'

declare BUILD_TARGET_STAGE=""
declare BUILD_TARGET=""
declare BUILD_VERSION=""
declare BUILD_ARCH=""
declare TARGET_KERNEL=""
declare BUILD_NAME=""
declare BASE_PROFILE=""
declare BUILD_TARGET_STAGE=""
declare PORTAGE_SNAPSHOT=""

CATALYST_USERS=""

CATALYST_CONFIG_DIR='/etc/catalyst'
CATALYST_CONFIG="${CATALYST_CONFIG_DIR}/catalyst.conf"
CATALYST_CONFIG_KERNCACHE="${CATALYST_CONFIG_DIR}/catalyst-kerncache.conf"

CATALYST_BASE_DIR="$(grep ^storedir ${CATALYST_CONFIG}|cut -d\" -f2)"
CATALYST_BUILD_DIR_BASE="${CATALYST_BASE_DIR}/builds"
CATALYST_TEMPLATE_DIR=${CATALYST_CONFIG_DIR}/templates
CATALYST_TMP_DIR="${CATALYST_BASE_DIR}/tmp"
CATALYST_LOG_DIR="$(grep ^port_logdir ${CATALYST_CONFIG}|cut -d\" -f2)"
CATALYST_SNAPSHOT_DIR="$(grep ^snapshot_cache ${CATALYST_CONFIG}|cut -d\" -f2)"
declare -r PID_FILE="${CATALYST_TMP_DIR}/genisys.pid"

die () {
  (( $2 == 1 )) && log '2' "$1" && bundleLogs '2' 
  (( $2 == 2 )) && log '4' "$1" && usage && exit
  if (( $2 == 0 ))
  then
    timeElapsed "START_TIME"
    log '1' "${1}: Completed in: ${BUILD_TIME}"
  fi
  exit $2
}

usage () {
  log 0 "Usage:"
  echo -e "\n\t$(basename $0) \t-T { ami | iso | livecd | stage } \t-- Build an AMI for Amazon, bootable iso, livecd image or stage tarball\n\t\t-S { 1..4 } \t\t\t\t-- What stage (1-2 for livecd, 1-4 for regular stage or 'all' for either)\n\t\t-A { amd64 | x32 | ... } \t\t-- Architecture we are building on\n\t\t-K { kernel version } \t\t\t-- Version of kernel to build\n\t\t-N { BuildName }  \t\t\t-- Name / Unique Identifier of this build\n\t\t-P { hardened | vanilla } \t\t-- Base profile for this build\n\t\t-R { snapshot } \t\t\t-- ID of Portage snapshot to use (latest if omitted)\n\t\t-V { version } \t\t\t\t-- Version of stage snapshot to fetch (latest if omitted)"
  echo -e "\n\tOptional args:\t-a [aws support] -k [enable kerncache] -n [no-multilib] -o [openstack support] -s [selinux support]"
  echo -e "\t\t\t-c [clear ccache] -d [debug] -p [purge] -q [quiet] -r [clear autoresume] -v [increment verbosity]"
  echo
}

log () {
  local prefix=$(printf "%${SCRIPT_SCOPE}s")
  local log_tag="$(basename ${0})[$$]"
  case $1 in
    0)
      printf "${prefix// /\\t}${COLOUR_GREEN}->${COLOUR_RST} $2\n"
    ;;
    1)
      printf "${prefix// /\\t}${COLOUR_GREEN}->${COLOUR_RST} $2\n"
      ${LOGGER} -p daemon.info -t "${log_tag}" "$2"
    ;;
    2)
      >&2  printf "${COLOUR_RED}***${COLOUR_RST} $2 ${COLOUR_RED}***${COLOUR_RST}\n"
      ${LOGGER} -p daemon.err -t "${log_tag}" "$2"
    ;;
    3)
      printf "${prefix// /\\t}${COLOUR_GREEN}->${COLOUR_RST} $2"
    ;;
    4)
      >&2  printf "${COLOUR_RED}***${COLOUR_RST} $2 ${COLOUR_RED}***${COLOUR_RST}\n"
    ;;
  esac

}

debug () {
  if (( VERBOSITY == 2 )) || (( VERBOSITY >= 4 ))
  then
    set -v 
  elif (( VERBOSITY >= 3 )) || (( DEBUG == 1 ))
  then
    ( (( QUIET_OUTPUT == 1 )) || (( DEBUG == 1 )) ) && exec 3>| ${CATALYST_LOG_DIR}/catalyst-${RUN_ID}.dbg
    ( (( QUIET_OUTPUT == 1 )) || (( DEBUG == 1 )) ) && BASH_XTRACEFD=3
    exec 3>| ${CATALYST_LOG_DIR}/catalyst-${RUN_ID}.dbg
    set -x
    export PS4='$(date +%s): +(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    DEBUG='1'
  fi
}

timeElapsed () {
    END_TIME=$(date +%s)
    BUILD_TIME=$(( END_TIME - ${1} ))
    seconds=${BUILD_TIME}
    hours=$((seconds / 3600))
    seconds=$((seconds % 3600))
    minutes=$((seconds / 60))
    seconds=$((seconds % 60))
    BUILD_TIME="${hours}h:${minutes}m:${seconds}s"
}

checkPid () {
  PID_ALIVE=0
  kill -0 $1 &> /dev/null
  (( $? == 0 )) && PID_ALIVE=1
  return 0
}

cleanUp () {
  for pid in $(pgrep -P $$)
  do  
    checkPid $pid 
    (( PID_ALIVE == 0 )) && continue
    kill $pid &> /dev/null
    checkPid $pid
    (( PID_ALIVE == 0 )) && continue
    kill -9 $pid &> /dev/null
    checkPid $pid 
    (( PID_ALIVE == 0 )) && continue
    log 2 "Zombie Process Identified: $pid (take its head off)"
  done

  [[ -w ${PID_FILE} ]] && rm ${PID_FILE}
}

verifyObject () {
  local retVal=0
  case $1 in
    dir)
      if [[ ! -d ${2} ]] 
      then
        mkdir -p ${2}
        retVal=$?
        (( retVal == 0 )) || log 2 "Problems encountered creating: ${2}"
      fi
    ;;
    file)
      if [[ ! -f ${2} ]] 
      then
        touch ${2}
        retVal=$?
        (( retVal == 0 )) || log 2 "Problems encountered creating: ${2}"
      fi
    ;;
  esac

  return ${retVal}
}

runWrapper () {
  for i in ${1}
  do
    BUILD_TARGET_STAGE="$i"
    BUILD_START_TIME=$(date +%s)
    main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
    timeElapsed BUILD_START_TIME
    log '1' "Stage ${BUILD_TARGET_STAGE}: Completed in: ${BUILD_TIME}"
  done

  die "${BUILD_TARGET} built" '0'
}

bundleLogs () {
  local SCRIPT_SCOPE='1'
  local CATALYST_LOGS=()
  local CATALYST_LOG_MASKS=( '*.log' '*.info' '*.err' )

  (( DEBUG == 1 )) && CATALYST_LOG_MASKS+=" *.dbg"

  log 0 "Clearing empty logs"
  find ${CATALYST_LOG_DIR} -type f -empty -exec rm {} \; &> /dev/null
  find ${CATALYST_LOG_DIR} -type d -empty -exec rm -rf {} \; &> /dev/null

  log 0 "Collecting logs"
  for mask in ${CATALYST_LOG_MASKS[@]}
  do
    CATALYST_LOGS+=" $(find ${CATALYST_LOG_DIR} -type f -not -path "*/archive/*" -not -path "*/failed/*" -name ${mask})"
  done
  

  case $1 in
    1)
      CATALYST_LOGS+=" ${CATALYST_BUILD_DIR}/${SPEC_FILE}"
      log 0 "Compressing logs"
      tar czvf ${CATALYST_LOG_DIR}/archive/catalyst-build-${BUILD_NAME}-${BUILD_TARGET}-stage${BUILD_TARGET_STAGE}-${RUN_ID}.tgz -C ${CATALYST_BASE_DIR} ${CATALYST_LOGS[@]} &> /dev/null
      (( $? == 0 )) && rm -rf ${CATALYST_LOGS[@]}
    ;;
    2)
      log 0 "Moving logs to: ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-${BUILD_TARGET}-stage${BUILD_TARGET_STAGE}-${RUN_ID}"
      mkdir -p ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-${BUILD_TARGET}-stage${BUILD_TARGET_STAGE}-${RUN_ID}
      for file in ${CATALYST_LOGS[@]}
      do
        [[ -f ${file} ]] && mv ${file} ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-${BUILD_TARGET}-stage${BUILD_TARGET_STAGE}-${RUN_ID}/
      done
    ;;
  esac
}

verifyTemplates () {
  local SCRIPT_SCOPE='1'
  case ${BUILD_TARGET_STAGE} in
    1)
      TEMPLATES=( ${STAGE1_TEMPLATES[@]} )
    ;;
    2)
      TEMPLATES=( ${STAGE2_TEMPLATES[@]} )
    ;;
    3)
      TEMPLATES=( ${STAGE3_TEMPLATES[@]} )
    ;;
    4)
      TEMPLATES=( ${STAGE4_TEMPLATES[@]} )
    ;;
  esac

  log '0' "Checking for templates"
  for template in ${TEMPLATES[@]}
  do 
    local SCRIPT_SCOPE='2'
    (( VERBOSITY > 0 )) && log '0' "Checking: ${template}"
    if [[ ! -f ${CATALYST_TEMPLATE_DIR}/${template} ]]
    then
        log '2' "Missing template: ${template}" 
        exit 1
    fi
  done
}

mangleTemplate () {
  template="${2}"
  var_names=( "${3}" )
  touch ${CATALYST_BUILD_DIR}/${SPEC_FILE} || return 1

  local SCRIPT_SCOPE='1'
  (( VERBOSITY > 0 )) && log '0' "Mangling template: ${template}"
  
  if [[ "$1" == "overwrite" ]] 
  then
    cp ${CATALYST_TEMPLATE_DIR}/${template} ${CATALYST_BUILD_DIR}/${SPEC_FILE}
    (( $? == 0 )) || return 1
  fi
  if [[ "$1" == "append" ]] 
  then
    cat ${CATALYST_TEMPLATE_DIR}/${template} >> ${CATALYST_BUILD_DIR}/${SPEC_FILE}
    (( $? == 0 )) || return 1
  fi

  for var in ${var_names[@]}
  do
    local SCRIPT_SCOPE='2'
    (( VERBOSITY > 0 )) && log '0' "Processing: $var"
    var_name=${var}
    grep $var ${CATALYST_BUILD_DIR}/${SPEC_FILE} &> /dev/null || continue
    var_value=${!var}
    [[ "${var_value}" =~ '/' ]] && var_value=$(echo ${var_value}|sed 's/\//\\\//g')
    sed -i "s/###${var_name}###/${var_value}/g" ${CATALYST_BUILD_DIR}/${SPEC_FILE} &> /dev/null
    (( $? == 0 )) || return 1
  done
}

fetchRemote () {
  local SCRIPT_SCOPE='2'
  local method="$1"
  local url="$2"
  (( ${#@} == 3 )) && local dir="$3"

  log '3' "Fetching: $(basename ${url}) "
  case ${method} in
    simple)
      ${WGET} --directory-prefix=${dir} ${url} &>/dev/null &
    ;;
    print)
      ${CURL} -s ${url} &
    ;;
    parallel)
      ${LFTP} -c pget -O ${dir} ${url} &>/dev/null &
    ;;
    *)
      log '2' "Method: ${method}, not understood"
      return 1
    ;;
  esac

  jobWait $!
  retVal=$?
  (( retVal > 0 )) && log '2' "Could not fetch ${url} to ${dir}" && return ${retVal}
  return 0
}

sumCheck () {
  local method="$1"
  local dir="$2"
  local file="$3"
  local digest="$4"
  local submethod="$5"

  local SCRIPT_SCOPE='2'

  case ${method} in
    sha512)
      cd ${dir}
      (( VERBOSITY > 0 )) && log '0' "Verifying ${method} hash for: ${file}"
      ${SHA512SUM} -c ${digest} | egrep -e ": OK$" | grep "${file}" &>/dev/null
      retVal=$?
      (( retVal == 0 )) || return "${retVal}"
    ;;
    openssl)
      (( VERBOSITY > 0 )) && log '0' "Verifying ${submethod} hash for: ${file} with: ${method}"
      hash=$(${OPENSSL} dgst -r -${submethod} ${dir}/${file}|awk '{print $1}')
      grep ${hash} ${dir}/${digest} &> /dev/null
      retVal=$?
      (( retVal == 0 )) || return "${retVal}"
    ;;
  esac
  return 0
}

sigCheck () {
  local SCRIPT_SCOPE='2'

  (( BUILD_TARGET_STAGE > 1 )) && log '0' "Not verifying GPG Signature, cuz Im lame" && return 0
  (( VERBOSITY > 0 )) && log '0' "Verifying GPG Signature for: $1"
  ${GPG} --verify ${1} 2>&1 | grep "$2" &> /dev/null
  retVal=$?
  (( retVal == 0 )) || return "${retVal}"
}

jobWait() {
  local pid=$1
  local delay=0.15
  local spinstr='|/-\'

  checkPid $pid
  if (( PID_ALIVE == 0 ))
  then
    return 0
  fi

  while (( $? == 0 ))
  do
    [[ $- =~ "i" ]] || break
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
    checkPid $pid
    (( PID_ALIVE == 1 )) || break
  done
  printf "    \b\b\b\b\n"
  wait $pid
  return $?
}

awsBundleImage () {
  verifyObject 'dir' "/${IMAGE_STORE}/ami/${BUILD_NAME}/${BUILD_VER}/"
  ${EC2_BUNDLE_IMAGE} -k ${CATALYST_CONFIG_DIR}/keys/key.pem -c /etc/ec2/amitools/cert-ec2.pem  -u ${AWS_ACCOUNT_ID} -i ${CATALYST_BASE_DIR}/iso/${BUILD_NAME}-${BUILD_ARCH}-${BASE_PROFILE}-installer-${BUILD_VER}.iso -d ${IMAGE_STORE}/ami/${BUILD_NAME}/${BUILD_VER}/ -r x86_64
}

runCatalyst () {
  local method="$1"
  local SCRIPT_SCOPE='1'
  local SCRIPT_OUT="${CATALYST_LOG_DIR}/catalyst-${BUILD_TARGET}-${method}-${RUN_ID}.info"
  local SCRIPT_ERR="${CATALYST_LOG_DIR}/catalyst-${BUILD_TARGET}-${method}-${RUN_ID}.err"
  local SCRIPT_FLAGS="-f -e -q -c"

  case ${method} in
    snapshot)
      local CATALYST_ARGS="${CATALYST_ARGS} -s"
      log '0' "Taking portage snapshot with args: ${CATALYST_ARGS}"

      if (( QUIET_OUTPUT == 1 ))
      then
        local SCRIPT_SCOPE='2'
        log '3' "Running silently... "
        ( script ${SCRIPT_FLAGS} "${CATALYST} ${CATALYST_ARGS} ${DATE_SUFFIX}" ${SCRIPT_OUT}  2> ${SCRIPT_ERR} &> /dev/null ) &
        jobWait $!
        retVal=$?
        if (( retVal > 0 ))
        then
          [[ $- =~ "i" ]] && cat ${SCRIPT_OUT}
          log '2' "Errors reported, check: ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-${BUILD_TARGET}-stage${BUILD_TARGET_STAGE}-${RUN_ID} for details"
        fi
      else
        ${CATALYST} ${CATALYST_ARGS} ${DATE_SUFFIX}
        retVal=$?
      fi
      (( retVal == 0 )) || return "${retVal}"
    ;;
    build)
      [[ ! ${CATALYST_ARGS} =~ "-f" ]] &&  CATALYST_ARGS="${CATALYST_ARGS} -f"
      log '1' "Building with args:${CATALYST_ARGS} ${CATALYST_BUILD_DIR}/${SPEC_FILE}"
      if (( QUIET_OUTPUT == 1 ))
      then
        local SCRIPT_SCOPE='2'
        log '3' "Running silently..."
        ( script ${SCRIPT_FLAGS} "${CATALYST} ${CATALYST_ARGS} ${CATALYST_BUILD_DIR}/${SPEC_FILE}" ${SCRIPT_OUT} 2> ${SCRIPT_ERR} &> /dev/null ) &
        jobWait $!
        retVal=$?
        if (( retVal > 0 ))
        then
          [[ $- =~ "i" ]] && cat ${SCRIPT_OUT}
          log '2' "Errors reported, check: ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-${BUILD_TARGET}-stage${BUILD_TARGET_STAGE}-${RUN_ID} for details"
        fi
      else
        ${CATALYST} ${CATALYST_ARGS} ${CATALYST_BUILD_DIR}/${SPEC_FILE}
        retVal=$?
      fi

      (( retVal > 0 )) && return "${retVal}"
      bundleLogs '1'
      return 0
    ;;
  esac
}

prepCatalystLiveCD () {
  SPEC_FILE="livecd-${SPEC_FILE}"

  STAGE1_TEMPLATES=( "${SPEC_FILE}.header.template" "${SPEC_FILE}.pkg.template" "${SPEC_FILE}.use.template" )
  STAGE2_TEMPLATES=( "${SPEC_FILE}.header.template" "${SPEC_FILE}.boot.template" "${SPEC_FILE}.post.template" )

  if (( ${BUILD_TARGET_STAGE} == '1' ))
  then
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.pkg.template > ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.use.template >> ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep
  elif (( ${BUILD_TARGET_STAGE} == '2' ))
  then
    SRC_PATH_PREFIX="livecd-${SRC_PATH_PREFIX}"
  fi
}

verifyCatalystDeps () {
  local SCRIPT_SCOPE='1'
  WORK_DIR=${CATALYST_BUILD_DIR}
  (( BUILD_TARGET_STAGE == 1 )) && WORK_DIR=${CATALYST_SNAPSHOT_DIR}

  log '0' "Checking for required directories"
  for dir in ${CATALYST_DIRS[@]}
  do
    local SCRIPT_SCOPE='2'
    (( VERBOSITY > 0 )) && log 0 "Checking for directory: ${dir}"
    verifyObject 'dir' "${dir}" || die "Error returned while creating: ${dir}"
  done

  local SCRIPT_SCOPE='1'
  log '0' "Checking for stage files"
  for file in "${SEED_STAGE_DIGESTS}" "${SEED_STAGE_CONTENTS}" "${SEED_STAGE_ASC}" "${SEED_STAGE}"
  do
    #Fix Me... sign your builds!
    (( BUILD_TARGET_STAGE > 1 )) && [[ ${file} =~ "asc"$ ]] && continue
    local SCRIPT_SCOPE='2'
    (( VERBOSITY > 0 )) && log '0' "Checking for: ${file}"
    if [[ ! -f ${WORK_DIR}/${file} ]] 
    then
      if (( BUILD_TARGET_STAGE == '1' ))
      then
        fetchRemote 'parallel' "${DIST_BASE_URL}/${STAGE3_URL_BASE}/${file}" "${WORK_DIR}"
        (( $? == 0 )) || die "Failed to fetch: ${file}" "1"
      else
        die "Cant find: $file" '1'
      fi
    fi
  done

  local SCRIPT_SCOPE='1'
  log '0' "Verifying stage files"
  if [[ -f ${WORK_DIR}/${SEED_STAGE} ]]
  then
    sigCheck "${WORK_DIR}/${SEED_STAGE_ASC}" 'Good signature from "Gentoo Linux Release Engineering (Automated Weekly Release Key) <releng@gentoo.org>"'
    (( $? == 0 )) || die "Failed to verify signature" '1'

    for file in "${SEED_STAGE}" "${SEED_STAGE_CONTENTS}"
    do
      sumCheck 'openssl' "${WORK_DIR}" "${file}" "${SEED_STAGE_DIGESTS}" sha512
      (( $? == 0 )) || die "SHA512 checksum failed for: ${file}" "1"
      sumCheck 'openssl' "${WORK_DIR}" "${file}" "${SEED_STAGE_DIGESTS}" whirlpool
      (( $? == 0 )) || die "Whirlpool checksum failed for: ${file}" "1"
    done
  else
    die "Can't find: ${WORK_DIR}/${SEED_STAGE}" '1'
  fi

  if (( BUILD_TARGET_STAGE == 1 ))
  then
    [[ -f ${CATALYST_BUILD_DIR}/${SEED_STAGE} ]] && return 0
    (( VERBOSITY > 0 )) && log '0' "Copying seed stage to build dir"
    cp ${WORK_DIR}/${SEED_STAGE} ${CATALYST_BUILD_DIR}/
  fi
}

prepCatalystStage () {
  STAGE1_TEMPLATES=( "${SPEC_FILE}.header.template" )
  STAGE2_TEMPLATES=( "${SPEC_FILE}.header.template" )
  STAGE3_TEMPLATES=( "${SPEC_FILE}.header.template" )
  STAGE4_TEMPLATES=( "${SPEC_FILE}.header.template" "${SPEC_FILE}.pkg.template" "${SPEC_FILE}.use.template" )

  if (( BUILD_TARGET_STAGE == 4 ))
  then
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.pkg.template > ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.use.template >> ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep
  fi
}

prepPortage () {
  local SCRIPT_SCOPE='1'
  (( VERBOSITY > 0 )) && log '0' "Validating portage cache"
  if [[ -f ${CATALYST_SNAPSHOT_DIR}/portage-${PORTAGE_SNAPSHOT}.tar.bz2 ]]
  then
    PORTAGE_SNAPSHOT_DATE=$(date +%s -r ${CATALYST_SNAPSHOT_DIR}/portage-${PORTAGE_SNAPSHOT}.tar.bz2)
    PORTAGE_SNAPSHOT_AGE=$(( TIME_NOW - PORTAGE_SNAPSHOT_DATE ))
    PORTAGE_SNAPSHOT_AGE_MAX='14400'
    (( PORTAGE_SNAPSHOT_AGE > PORTAGE_SNAPSHOT_AGE_MAX )) || return
  fi

  runCatalyst 'snapshot' || die "Catalyst failed to make a snapshot of portage" "1"
}

prepCatalyst () {
  (( $UID > 0 )) && die "Must run with root" '2'
  echo $$ > ${PID_FILE}
  DATE_SUFFIX=$(date "+%Y%m%d")
  SPEC_FILE_PREFIX="stage${BUILD_TARGET_STAGE}"

  CATALYST_BUILD_DIR="${CATALYST_BUILD_DIR_BASE}/${BUILD_NAME}/${BUILD_TARGET}"
  declare -a CATALYST_DIRS=( "${CATALYST_BASE_DIR}" "${CATALYST_BUILD_DIR_BASE}" "${CATALYST_TMP_DIR}" "${CATALYST_SNAPSHOT_DIR}" "${CATALYST_LOG_DIR}" "${CATALYST_LOG_DIR}/failed/stale" "${CATALYST_TMP_DIR}/${BUILD_NAME}" "${CATALYST_BUILD_DIR}" "${CATALYST_LOG_DIR}/archive" )

  STALE_LOGS=$(find ${CATALYST_LOG_DIR} -mindepth 1 -maxdepth 1 -type f ! -iname "*${RUN_ID}*" 2> /dev/null)

  if [[ -n ${STALE_LOGS} ]]
  then
    log '0' "Cleaning up stale logs"
    mv ${STALE_LOGS} ${CATALYST_LOG_DIR}/failed/stale/ || die "Could not move stale logs to: ${CATALYST_LOG_DIR}/failed/stale" '1'
  fi

  mount|grep "${CATALYST_TMP_DIR}" &> /dev/null
  (( $? == 0 )) && die "Looks like stuff is still mounted in the chroot. This makes pain. Check: mount | grep ${CATALYST_TMP_DIR}" '1'

  if [[ ${BASE_PROFILE} == 'hardened' ]] 
  then
    BASE_PROFILE_PATH="${BASE_PROFILE}/linux/${BUILD_ARCH}"
  elif [[ ${BASE_PROFILE} == 'vanilla' ]]
  then
    BASE_PROFILE_PATH="default/linux/${BUILD_ARCH}/13.0"
  fi

  if (( NO_MULTILIB == 1 ))
  then
    BASE_PROFILE_PATH="${BASE_PROFILE_PATH}/no-multilib"
    SPEC_FILE_PREFIX="${SPEC_FILE_PREFIX}-nomultilib"
  fi

  if (( SELINUX == 1 )) 
  then 
    BASE_PROFILE_PATH="${BASE_PROFILE_PATH}/selinux"
    SPEC_FILE_PREFIX="${SPEC_FILE_PREFIX}-selinux"
  fi

  if (( BUILD_TARGET_STAGE == 4 ))
  then
    if (( AWS_SUPPORT == 1 ))
    then
      SPEC_FILE_PREFIX="${SPEC_FILE_PREFIX}-aws"
    elif (( OPENSTACK_SUPPORT == 1 ))
    then
      SPEC_FILE_PREFIX="${SPEC_FILE_PREFIX}-ostack"
    fi
  fi

  SPEC_FILE="${SPEC_FILE_PREFIX}.spec"

  if [[ -z ${PORTAGE_SNAPSHOT} ]]
  then
    PORTAGE_SNAPSHOT=${DATE_SUFFIX}
  fi

  DIST_BASE_URL='http://distfiles.gentoo.org/releases'
  STAGE3_URL_BASE="${BUILD_ARCH}/autobuilds"
  STAGE3_MANIFEST="latest-stage3-${BUILD_ARCH}"

  if [[ ${BASE_PROFILE} == 'hardened' ]] 
  then
    STAGE3_MANIFEST="${STAGE3_MANIFEST}-hardened"
    (( NO_MULTILIB == 1 )) && STAGE3_MANIFEST="${STAGE3_MANIFEST}+nomultilib"
  else
    (( NO_MULTILIB == 1 )) && STAGE3_MANIFEST="${STAGE3_MANIFEST}-nomultilib"
  fi

  STAGE3_MANIFEST="${STAGE3_MANIFEST}.txt"

  if (( BUILD_TARGET_STAGE == 1 ))
  then
    SEED_STAGE_PREFIX="stage3-${BUILD_ARCH}"
    SRC_PATH_PREFIX="stage3-${BUILD_ARCH}"
  else
    SEED_STAGE_PREFIX="stage$(( BUILD_TARGET_STAGE - 1 ))-${BUILD_ARCH}"
    SRC_PATH_PREFIX="stage$(( BUILD_TARGET_STAGE - 1 ))-${BUILD_ARCH}"
  fi

  DIST_STAGE3_LATEST="$(fetchRemote 'print' ${DIST_BASE_URL}/${BUILD_ARCH}/autobuilds/${STAGE3_MANIFEST}|grep bz2|cut -d/ -f1)"

  [[ -z ${BUILD_VERSION} ]] && BUILD_VERSION="${DIST_STAGE3_LATEST}"

  STAGE3_URL_BASE="${STAGE3_URL_BASE}/${BUILD_VERSION}"

  VERSION_STAMP_PREFIX=""

  if [[ ${BASE_PROFILE} == 'hardened' ]] 
  then
    STAGE3_URL_BASE="${STAGE3_URL_BASE}/hardened"
    SEED_STAGE_PREFIX="${SEED_STAGE_PREFIX}-${BASE_PROFILE}"
    VERSION_STAMP_PREFIX="${BASE_PROFILE}"
    (( SELINUX == 1 )) && VERSION_STAMP_PREFIX="${VERSION_STAMP_PREFIX}-selinux"
    (( NO_MULTILIB == 1 )) && SEED_STAGE_PREFIX="${SEED_STAGE_PREFIX}+nomultilib"
    (( NO_MULTILIB == 1 )) && VERSION_STAMP_PREFIX="${VERSION_STAMP_PREFIX}+nomultilib"
  else
    (( NO_MULTILIB == 1 )) && SEED_STAGE_PREFIX="${SEED_STAGE_PREFIX}-nomultilib"
  fi

  SEED_STAGE="${SEED_STAGE_PREFIX}-${DIST_STAGE3_LATEST}.tar.bz2"
  SEED_STAGE_DIGESTS="${SEED_STAGE}.DIGESTS"
  SEED_STAGE_ASC="${SEED_STAGE_DIGESTS}.asc"
  SEED_STAGE_CONTENTS="${SEED_STAGE}.CONTENTS"

  if [[ -z ${VERSION_STAMP_PREFIX} ]]
  then
    VERSION_STAMP="${DIST_STAGE3_LATEST}"
  else
    VERSION_STAMP="${VERSION_STAMP_PREFIX}-${DIST_STAGE3_LATEST}"
  fi

  [[ ${BUILD_TARGET} == livecd ]] && prepCatalystLiveCD
  [[ ${BUILD_TARGET} == stage ]] && prepCatalystStage
  
  log 0 "Checking dependencies"
  verifyCatalystDeps || die "Failed to verify Seed Stage." '1'
  verifyTemplates || die "Could not verify templates" '1'
  
  log '1' "Starting run ID: ${RUN_ID} for: ${BUILD_NAME} with a ${BASE_PROFILE} stack on ${BUILD_ARCH} for Stage: ${BUILD_TARGET_STAGE} for delivery by: ${BUILD_TARGET}"

  if (( SELINUX == 1 ))
  then
    local SCRIPT_SCOPE='1'
    (( VERBOSITY > 0 )) && log '0' "SELinux Enabled"
  fi

  if (( NO_MULTILIB == 1 ))
  then
    local SCRIPT_SCOPE='1'
    (( VERBOSITY > 0 )) && log '0' "Multilib Disabled"
  fi

  if (( AWS_SUPPORT == 1 ))
  then
    local SCRIPT_SCOPE='1'
    (( VERBOSITY > 0 )) && log '0' "Building Stage for aws"
  fi

  if (( OPENSTACK_SUPPORT == 1 ))
  then
    local SCRIPT_SCOPE='1'
    (( VERBOSITY > 0 )) && log '0' "Building Stage for openstack"
  fi

  if [[ ${BASE_PROFILE} == 'hardened' ]]
  then
    SRC_PATH_PREFIX="${SRC_PATH_PREFIX}-${BASE_PROFILE}"
    (( SELINUX == 1 )) && SRC_PATH_PREFIX="${SRC_PATH_PREFIX}-selinux"
    (( NO_MULTILIB == 1 )) && SRC_PATH_PREFIX="${SRC_PATH_PREFIX}+nomultilib"
  else
    (( NO_MULTILIB == 1 )) && SRC_PATH_PREFIX="${SRC_PATH_PREFIX}-nomultilib"
  fi

  SRC_PATH="${BUILD_NAME}/${BUILD_TARGET}/${SRC_PATH_PREFIX}-${DIST_STAGE3_LATEST}"

  mangleTemplate 'overwrite' "${SPEC_FILE}.header.template" "BUILD_ARCH VERSION_STAMP BASE_PROFILE BASE_PROFILE_PATH PORTAGE_SNAPSHOT SRC_PATH BUILD_NAME CPU_COUNT CATALYST_USERS BUILD_TARGET"
  (( $? == 0 )) || die "Could not manipulate spec file: header" '1'

  if ( (( ${BUILD_TARGET_STAGE} == 1 )) && [[ ${BUILD_TARGET} == 'livecd' ]] ) || ( (( ${BUILD_TARGET_STAGE} == 4 )) && [[ ${BUILD_TARGET} == 'stage' ]] )
  then
    cat ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep >> ${CATALYST_BUILD_DIR}/${SPEC_FILE}
  fi

  if ( (( ${BUILD_TARGET_STAGE} == 2 )) && [[ ${BUILD_TARGET} == 'livecd' ]] ) || ( (( ${BUILD_TARGET_STAGE} == 4 )) && [[ ${BUILD_TARGET} == 'stage' ]] )
  then
    mangleTemplate 'append' "${SPEC_FILE}.boot.template" "BASE_PROFILE BUILD_ARCH BUILD_TARGET TARGET_KERNEL"
    (( $? == 0 )) || die "Could not manipulate spec file: boot" '1'
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.post.template >> ${CATALYST_BUILD_DIR}/${SPEC_FILE}
    (( $? == 0 )) || die "Could not manipulate spec file: post" '1'
  fi

  (( BUILD_TARGET_STAGE == 1 )) && (( TAKE_SNAPSHOT == 1 )) && prepPortage

  if (( CLEAR_CCACHE == 1 ))
  then
    local SCRIPT_SCOPE='3'
    CURRENT_STAGE=$( basename ${SEED_STAGE/stage[1-4]/stage${BUILD_TARGET_STAGE}} .tar.bz2)
    log '0' "Clearing CCache: ${CATALYST_TMP_DIR}/${BUILD_NAME}/${BUILD_TARGET}/${CURRENT_STAGE}/var/ccache/"
    rm -rf ${CATALYST_TMP_DIR}/${BUILD_NAME}/${BUILD_TARGET}/${CURRENT_STAGE}/var/ccache/* || die "Failed to clear CCache" '1'
    (( $? > 0 )) &&  log '2' "Failed to clear ccache"
  fi

  runCatalyst 'build' || die "Catalyst failed to build" "1"
}

burnAmi () {
  if [[ -n ${PEM_KEY} ]]
  then
    echo "${PEM_KEY}" | awsBundleImage
  else
    awsBundleImage
  fi
  return $?
}

burnIso () {
  #Something should be here
  #mkisofs -J -R -l  -V "${BUILD_NAME}" -o ${CATALYST_BUILD_DIR}/nameofthething -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table ${CATALYST_BUILD_DIR}/livecd-stage2-
  echo "Burn"
}

menuSelect () {
  TIME_NOW=$(date +%s)
  START_TIME=${TIME_NOW}
  RUN_ID=${TIME_NOW}
  CATALYST_ARGS=""

  (( ${#@} < 1 )) && die "No arguments supplied" '2'

  while getopts ":A:K:N:P:R:S:T:V:acdknopqrsv" opt
  do
    case ${opt} in
      A)
        BUILD_ARCH="${OPTARG}"
      ;;
      K)
        TARGET_KERNEL="${OPTARG}"
      ;;
      N)
        BUILD_NAME="${OPTARG}"
      ;;
      P)
        BASE_PROFILE="${OPTARG}"
      ;;
      R)
       PORTAGE_SNAPSHOT="${OPTARG}" 
       TAKE_SNAPSHOT='0'
       [[ ${PORTAGE_SNAPSHOT} =~ ^[0-9]+$ ]] || die "Invalid format: ${PORTAGE_SNAPSHOT} should look something like: ${DATE_SUFFIX}" '2'
      ;;
      S)
        [[ -z ${BUILD_TARGET_STAGE} ]] && BUILD_TARGET_STAGE="${OPTARG}"
      ;;
      T)
        case ${OPTARG} in
          ami)
            BUILD_TARGET='ami'
          ;;
          iso)
            BUILD_TARGET='iso'
          ;;
          livecd)
            BUILD_TARGET='livecd'
          ;;
          stage)
            BUILD_TARGET='stage'
          ;;
          \?)
            die "Unknown flag: -$OPTARG" '2'
          ;;
          :)
            die "Missing parameter for flag: -$OPTARG" '2'
          ;;
          *)
            die "Invalid Target specified: $OPTARG, should be one of [ iso, ami, stage ]" '2'
          ;;
        esac
      ;;
      V)
        BUILD_VERSION="${OPTARG}"
      ;;
      a)
        AWS_SUPPORT='1'
      ;;
      c)
        CLEAR_CCACHE='1'
      ;;
      d)
        DEBUG='1'
        [[ ! ${CATALYST_ARGS} =~ "-d" ]] && CATALYST_ARGS="${CATALYST_ARGS} -d"
      ;;
      k)
        CATALYST_CONFIG="${CATALYST_CONFIG_KERNCACHE}"
        [[ ! ${CATALYST_ARGS} =~ "-c" ]] && CATALYST_ARGS="${CATALYST_ARGS} -c ${CATALYST_CONFIG}"
      ;;
      o)
        OPENSTACK_SUPPORT='1'
      ;;
      n)
        NO_MULTILIB='1'
      ;;
      p)
        [[ ! ${CATALYST_ARGS} =~ "-p -a" ]] && CATALYST_ARGS="${CATALYST_ARGS} -p -a"
        CLEAR_CCACHE='1'
      ;;
      q)
        QUIET_OUTPUT='1'
      ;;
      r)
        [[ ! ${CATALYST_ARGS} =~ "-a" ]] && CATALYST_ARGS="${CATALYST_ARGS} -a"
      ;;
      s)
        SELINUX='1'
      ;;
      v)
        (( VERBOSITY < 5 )) && (( ++VERBOSITY ))
        (( VERBOSITY == 1 )) && CATALYST_ARGS="${CATALYST_ARGS} -v"
      ;;
      \?)
        die "Unknown option: -$OPTARG" '1'
      ;;
      :)
        die "Missing parameter for flag: -$OPTARG" '1'
      ;;
      *)
        die "Invalid option specified: $OPTARG" '1'
      ;;
    esac
  done

  (( VERBOSITY > 0 || DEBUG == 1 )) && debug

  [[ -n ${BUILD_TARGET} ]] || die "Target Unset" '1'
  (( OPENSTACK_SUPPORT == 1 && AWS_SUPPORT == 1 )) && die "Only one of -a or -o can be set" '2'

  [[ ${BASE_PROFILE} == 'hardened' || ${BASE_PROFILE} == 'vanilla' ]] || die "Unknown profile: ${BASE_PROFILE}" '2'
  [[ ${BASE_PROFILE} == 'vanilla' ]] && (( SELINUX == 1 )) && die "Selinux not supported on profile: ${BASE_PROFILE}" '2'
  
  if [[ ${BUILD_TARGET}='stage' || ${BUILD_TARGET}='livecd' ]]
  then
        [[ -n ${BUILD_TARGET_STAGE} ]] || die "Stage (-S) unset" '2'
        [[ -n ${BUILD_ARCH} ]] || die "ARCH (-A) unset" '2'
        [[ -n ${TARGET_KERNEL} ]] || die "Target kernel (-K) Unset" '2'
        [[ -n ${BUILD_NAME} ]] || die "Build name (-N) unset" '2'
        [[ -n ${BASE_PROFILE} ]] || die "Profile (-P) unset" '2'
  fi
  main
}

main() {
  TIME_NOW=$(date +%s)
  RUN_ID=${TIME_NOW}
  if [[ ${BUILD_TARGET} == "livecd" ]]
  then
    if [[ ${BUILD_TARGET_STAGE} == "all" ]]
    then
      runWrapper "1 2"
    fi
    [[ ${BUILD_TARGET_STAGE} == [1-2] ]] || die "Need number of stage to build [1-2]" '1'
  else
    if [[ ${BUILD_TARGET_STAGE} == "all" ]] 
    then
      if (( AWS_SUPPORT > 0 || OPENSTACK_SUPPORT > 0 ))
      then
        [[ ${BUILD_TARGET} == "livecd" ]] && die "Livecd target currently not supported" '2'
        runWrapper "1 2 3 4"
      fi
      runWrapper "1 2 3"
    fi
    [[ ${BUILD_TARGET_STAGE} == [1-4] ]] || die "Need number of stage to build [1-4]" '1'
  fi 

  if [[ ${BUILD_TARGET} == "livecd" ]] || [[ ${BUILD_TARGET} == "stage" ]]
  then
    prepCatalyst || return 1
  elif [[ ${BUILD_TARGET} == "ami" ]]
  then
    burnAmi || return 1
  elif [[ ${BUILD_TARGET} == "iso" ]]
  then
    burnIso || return 1
  fi
}

trap "echo && die 'SIGINT Caught' 1" SIGINT 
trap "echo && die 'SIGTERM Caught' 1" SIGTERM
trap "echo && die 'SIGHUP Caught' 1" SIGHUP
trap "cleanUp" EXIT
trap "(( ++VERBOSITY )) && debug" SIGUSR1
trap "DEBUG=1 && debug" SIGUSR2

RUN_ARGS="$@"

menuSelect ${RUN_ARGS}

die "Fin." '0'
