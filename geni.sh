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

declare -r COLOUR_RED='\033[0;31m'
declare -r COLOUR_GREEN='\033[0;32m'
declare -r COLOUR_RST='\033[0m'

declare BUILD_TARGET_STAGE=""
declare BUILD_TARGET=""
declare BUILD_VERSION=""

CATALYST_USERS=""

CATALYST_CONFIG_DIR='/etc/catalyst'
CATALYST_CONFIG="${CATALYST_CONFIG_DIR}/catalyst.conf"
CATALYST_CONFIG_KERNCACHE="${CATALYST_CONFIG_DIR}/catalyst-kerncache.conf"
CATALYST_BASE_DIR="$(grep ^storedir ${CATALYST_CONFIG}|cut -d\" -f2)"
CATALYST_BUILD_DIR_BASE="${CATALYST_BASE_DIR}/builds"
CATALYST_TEMPLATE_DIR=${CATALYST_CONFIG_DIR}/templates
CATALYST_TMP_DIR="${CATALYST_BASE_DIR}/tmp"

declare -r PID_FILE="${CATALYST_TMP_DIR}/genisys.pid"

CATALYST_LOG_DIR="$(grep ^port_logdir ${CATALYST_CONFIG}|cut -d\" -f2)"
CATALYST_SNAPSHOT_DIR="$(grep ^snapshot_cache ${CATALYST_CONFIG}|cut -d\" -f2)"

die () {
  (( $2 > 0 )) && log '2' "$1"
  if (( $2 == 0 ))
  then
    END_TIME=$(date +%s)
    BUILD_TIME=$(( END_TIME - START_TIME ))

    seconds=${BUILD_TIME}
    hours=$((seconds / 3600))
    seconds=$((seconds % 3600))
    minutes=$((seconds / 60))
    seconds=$((seconds % 60))

    BUILD_TIME="${hours}h:${minutes}m:${seconds}s"
    log '1' "$1"
    log '1' "Completed in: ${BUILD_TIME}"
  fi
  exit $2
}

usage () {
  log 1 "Usage:"
  echo -e "\n\t$(basename $0) \t-T { ami | iso | livecd | stage } \t-- Build an AMI for Amazon, bootable iso, livecd image or stage tarball\n\t\t-S { 1..4 } \t\t\t\t-- What stage (1-2 for livecd, 1-4 for regular stage)\n\t\t-A { amd64 | x32 | ... } \t\t-- Architecture we are building on\n\t\t-K { kernel version } \t\t\t-- Version of kernel to build\n\t\t-N { BuildName }  \t\t\t-- Name / Unique Identifier of this build\n\t\t-P { hardened | gentoo } \t\t-- Base profile for this build\n\t\t-V { version } \t\t\t\t-- Version of stage snapshot to fetch"
  echo -e "\n\tOptional args:\t-a [clear autoresume] -c [clear ccache] -d [debug] -k [enable kerncache] -n [no-multilib] -p [purge] -q [quiet] -s [enable selinux] -v [increment verbosity]"
  echo
}

log () {
  local prefix=$(printf "%${SCRIPT_SCOPE}s")
  local log_tag="[PID:$$]-[${0}]"
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
    export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    DEBUG='1'
  fi
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

  [[ -f ${PID_FILE} ]] && rm ${PID_FILE}
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
    export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    DEBUG='1'
  fi
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

  [[ -f ${PID_FILE} ]] && rm ${PID_FILE}
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

bundleLogs () {
  local SCRIPT_SCOPE='1'
  local CATALYST_LOGS=()
  local CATALYST_LOG_MASKS=( '*.log' '*.info' '*.err' )

  (( DEBUG == 1 )) && (( QUIET_OUTPUT == 1 )) && CATALYST_LOG_MASKS+=" *.dbg"

  log 0 "Clearing empty logs"
  find ${CATALYST_LOG_DIR} -type f -empty -exec rm {} \; &> /dev/null
  find ${CATALYST_LOG_DIR} -type d -empty -exec rm -rf {} \; &> /dev/null

  log 0 "Collecting logs"
  for mask in ${CATALYST_LOG_MASKS[@]}
  do
    CATALYST_LOGS+=" $(find ${CATALYST_LOG_DIR} -type f -not -path "*/archive/*" -not -path "*/failed/*" -name ${mask})"
  done
  
  verifyObject 'dir' "${CATALYST_LOG_DIR}/archive" || die "Could not create archive dir: ${CATALYST_LOG_DIR}/archive" '1'

  case $1 in
    1)
      CATALYST_LOGS+=" ${CATALYST_BUILD_DIR}/${SPEC_FILE}"
      log 0 "Compressing logs"
      tar czvf ${CATALYST_LOG_DIR}/archive/catalyst-build-${BUILD_NAME}-$(basename ${SPEC_FILE} .spec)-${RUN_ID}.tgz ${CATALYST_LOGS[@]} &> /dev/null
      (( $? == 0 )) && rm -rf ${CATALYST_LOGS[@]}
    ;;
    2)
      log 0 "Moving logs to: ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-$(basename ${SPEC_FILE} .spec)-${RUN_ID}"
      mkdir -p ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-$(basename ${SPEC_FILE} .spec)-${RUN_ID}
      for file in ${CATALYST_LOGS[@]}
      do
        [[ -f ${file} ]]
        mv ${file} ${CATALYST_LOG_DIR}/failed/${BUILD_NAME}-$(basename ${SPEC_FILE} .spec)-${RUN_ID}/
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
  log '0' "Mangling template: ${template}"
  
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
      log '0' "Verifying ${method} hash for: ${file}"
      ${SHA512SUM} -c ${digest} | egrep -e ": OK$" | grep "${file}" &>/dev/null
      retVal=$?
      (( retVal == 0 )) || return "${retVal}"
    ;;
    openssl)
      log '0' "Verifying ${submethod} hash for: ${file} with: ${method}"
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
  log '0' "Verifying GPG Signature for: $1"
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
  verifyObject 'dir' "/${IMAGE_STORE}/ami/${REL_NAME}/${BUILD_VER}/"
  ${EC2_BUNDLE_IMAGE} -k ${CATALYST_CONFIG_DIR}/keys/key.pem -c /etc/ec2/amitools/cert-ec2.pem  -u ${AWS_ACCOUNT_ID} -i ${CATALYST_BASE_DIR}/iso/${REL_NAME}-${SUB_ARCH}-${REL_TYPE}-installer-${BUILD_VER}.iso -d ${IMAGE_STORE}/ami/${REL_NAME}/${BUILD_VER}/ -r x86_64
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
        ( script ${SCRIPT_FLAGS} "${CATALYST} ${CATALYST_ARGS} latest" ${SCRIPT_OUT}  2> ${SCRIPT_ERR} &> /dev/null ) &
        jobWait $!
        retVal=$?
        (( retVal > 0 )) && cat ${SCRIPT_OUT} && log '2' "Errors reported, check: ${CATALYST_LOG_DIR}/failed/${RUN_ID} for details"
      else
        ${CATALYST} ${CATALYST_ARGS} latest
        retVal=$?
      fi
      (( retVal == 0 )) || return "${retVal}"
    ;;
    build)
      [[ ! ${CATALYST_ARGS} =~ "-f" ]] &&  CATALYST_ARGS="${CATALYST_ARGS} -f"
      log '1' "Building with args: ${CATALYST_ARGS} ${CATALYST_BUILD_DIR}/${SPEC_FILE}"
      if (( QUIET_OUTPUT == 1 ))
      then
        local SCRIPT_SCOPE='2'
        log '3' "Running silently..."
        ( script ${SCRIPT_FLAGS} "${CATALYST} ${CATALYST_ARGS} ${CATALYST_BUILD_DIR}/${SPEC_FILE}" ${SCRIPT_OUT} 2> ${SCRIPT_ERR} &> /dev/null ) &
        jobWait $!
        retVal=$?
        (( retVal > 0 )) && cat ${SCRIPT_OUT} && log '2' "Errors reported, check: ${CATALYST_LOG_DIR}/failed/${RUN_ID} for details"
      else
        ${CATALYST} ${CATALYST_ARGS} ${CATALYST_BUILD_DIR}/${SPEC_FILE}
        retVal=$?
      fi

      (( retVal > 0 )) && bundleLogs '2' && return "${retVal}"
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

prepCatalystStage () {
  STAGE1_TEMPLATES=( "${SPEC_FILE}.header.template" )
  STAGE2_TEMPLATES=( "${SPEC_FILE}.header.template" )
  STAGE3_TEMPLATES=( "${SPEC_FILE}.header.template" )
  STAGE4_TEMPLATES=( "${SPEC_FILE}.header.template" "${SPEC_FILE}.pkg.template" "${SPEC_FILE}.use.template" )

  if (( ${BUILD_TARGET_STAGE} == '4' ))
  then
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.pkg.template > ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.use.template >> ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep
  fi
}

prepCatalystStage1 () {
  SEED_STAGE="${DIST_STAGE3_BZ2}"
  local SCRIPT_SCOPE='1'
  log '0' "Checking for stage files"
  for file in "${DIST_STAGE3_DIGESTS}" "${DIST_STAGE3_CONTENTS}" "${DIST_STAGE3_ASC}" "${DIST_STAGE3_BZ2}"
  do
    if [[ ! -f ${CATALYST_BUILD_DIR}/${file} ]] 
    then
      fetchRemote 'parallel' "${DIST_BASE_URL}/${DIST_STAGE3_PATH_BASE}/${file}" "${CATALYST_BUILD_DIR}"
      (( $? == 0 )) || die "Failed to fetch: ${file}" "$?"
    fi
  done

  log '0' "Verifying Stage Files"
  if [[ -f ${CATALYST_SNAPSHOT_DIR}/${DIST_STAGE3_BZ2} ]]
  then
    sigCheck "${CATALYST_SNAPSHOT_DIR}/${DIST_STAGE3_ASC}" 'Good signature from "Gentoo Linux Release Engineering (Automated Weekly Release Key) <releng@gentoo.org>"'
    (( $? == 0 )) || die "Failed to verify signature" "$?"

    for file in "${DIST_STAGE3_BZ2}" "${DIST_STAGE3_CONTENTS}"
    do
      sumCheck 'openssl' "${CATALYST_SNAPSHOT_DIR}" "${file}" "${DIST_STAGE3_DIGESTS}" sha512
      (( $? == 0 )) || die "SHA512 checksum failed for: ${file}" "$?"
      sumCheck 'openssl' "${CATALYST_SNAPSHOT_DIR}" "${file}" "${DIST_STAGE3_DIGESTS}" whirlpool
      (( $? == 0 )) || die "Whirlpool checksum failed for: ${file}" "$?"
    done
  fi

  log '1' "Starting Catalyst run..."
  if (( BUILD_TARGET_STAGE == 1 ))
  then
    if (( PORTAGE_SNAPSHOT_AGE > PORTAGE_SNAPSHOT_AGE_MAX ))
    then 
      runCatalyst 'snapshot' || die "Catalyst failed to make a snapshot of portage" "$?"
    fi
  fi
}

prepCatalyst () {
  (( $UID > 0 )) && die "Must run with root" '2'
  START_TIME=$(date +%s)
  echo $$ > ${PID_FILE}

  STALE_LOGS=$(find ${CATALYST_LOG_DIR} -type f -mindepth 1 -maxdepth 1 2> /dev/null)

  if [[ -n ${STALE_LOGS} ]]
  then
    log '0' "Cleaning up stale logs"
    verifyObject 'dir' "${CATALYST_LOG_DIR}/failed/stale" || die "Could not create stale log dir: ${CATALYST_LOG_DIR}/failed/stale" '1'
    mv ${STALE_LOGS} ${CATALYST_LOG_DIR}/failed/stale/ || die "Could not move stale logs to: ${CATALYST_LOG_DIR}/failed/stale" '1'
  fi

  verifyObject 'dir' "${CATALYST_TMP_DIR}/${BUILD_NAME}" || die "Could not create build dir: ${CATALYST_TMP_DIR}/${BUILD_NAME}" '1'

  mount|grep "${CATALYST_TMP_DIR}" &> /dev/null
  (( $? == 0 )) && die "Looks like stuff is still mounted in the chroot. This makes pain. Check: mount | grep ${CATALYST_TMP_DIR}" '1'


  CATALYST_BUILD_DIR="${CATALYST_BUILD_DIR_BASE}/${BUILD_NAME}/${BUILD_TARGET}"

  PORTAGE_SNAPSHOT_DATE=$(date +%s -r ${CATALYST_SNAPSHOT_DIR}/portage-latest.tar.bz2)
  PORTAGE_SNAPSHOT_AGE=$(( TIME_NOW - PORTAGE_SNAPSHOT_DATE ))
  PORTAGE_SNAPSHOT_AGE_MAX='14400'

  REL_PROFILE="${REL_TYPE}/linux/${SUB_ARCH}"
  (( NO_MULTILIB == 1 )) &&  REL_PROFILE="${REL_PROFILE}/no-multilib"
  (( SELINUX == 1 )) &&  REL_PROFILE="${REL_PROFILE}/selinux"

  #todo: make this conditional
  REL_SNAPSHOT='latest'

  DIST_BASE_URL='http://distfiles.gentoo.org/releases'
  DIST_STAGE3_PREFIX="stage3-${SUB_ARCH}"
  DIST_STAGE3_PATH_BASE="${SUB_ARCH}/autobuilds"
  DIST_STAGE3_MANIFEST="latest-stage3-${SUB_ARCH}"

  if [[ ${REL_TYPE} == 'hardened' ]] 
  then
    DIST_STAGE3_MANIFEST="latest-${DIST_STAGE3_PREFIX}-hardened"
    (( NO_MULTILIB == 1 )) && DIST_STAGE3_MANIFEST="${DIST_STAGE3_MANIFEST}+nomultilib"
  else
    (( NO_MULTILIB == 1 )) && DIST_STAGE3_MANIFEST="${DIST_STAGE3_MANIFEST}-nomultilib"
  fi

  DIST_STAGE3_MANIFEST="${DIST_STAGE3_MANIFEST}.txt"
  DIST_STAGE3_LATEST="$(fetchRemote 'print' ${DIST_BASE_URL}/${SUB_ARCH}/autobuilds/${DIST_STAGE3_MANIFEST}|grep bz2|cut -d/ -f1)"

  [[ -z ${BUILD_VERSION} ]] && BUILD_VERSION="${DIST_STAGE3_LATEST}"

  DIST_STAGE3_PATH_BASE="${DIST_STAGE3_PATH_BASE}/${BUILD_VERSION}"

  if [[ ${REL_TYPE} == 'hardened' ]] 
  then
    DIST_STAGE3_PATH_BASE="${DIST_STAGE3_PATH_BASE}/hardened"
    DIST_STAGE3_PREFIX="${DIST_STAGE3_PREFIX}-${REL_TYPE}"
    (( NO_MULTILIB == 1 )) && DIST_STAGE3_PREFIX="${DIST_STAGE3_PREFIX}+nomultilib"
  else
    (( NO_MULTILIB == 1 )) && DIST_STAGE3_PREFIX="${DIST_STAGE3_PREFIX}-nomultilib"
  fi

  DIST_STAGE3_DIGESTS="${DIST_STAGE3_PREFIX}-${DIST_STAGE3_LATEST}.tar.bz2.DIGESTS"
  DIST_STAGE3_CONTENTS="${DIST_STAGE3_PREFIX}-${DIST_STAGE3_LATEST}.tar.bz2.CONTENTS"
  DIST_STAGE3_ASC="${DIST_STAGE3_PREFIX}-${DIST_STAGE3_LATEST}.tar.bz2.DIGESTS.asc"
  DIST_STAGE3_BZ2="${DIST_STAGE3_PREFIX}-${DIST_STAGE3_LATEST}.tar.bz2"

  DIST_STAGE1_BZ2="${DIST_STAGE3_BZ2/stage3/stage1}"
  SEED_STAGE="${DIST_STAGE1_BZ2}"

  VERSION_STAMP="${REL_TYPE}-${DIST_STAGE3_LATEST}"
  (( NO_MULTILIB == 1 )) && VERSION_STAMP="${REL_TYPE}+nomultilib-${DIST_STAGE3_LATEST}"

  SPEC_FILE="stage${BUILD_TARGET_STAGE}.spec"

  if (( ${BUILD_TARGET_STAGE} == '1' ))
  then
    SRC_PATH_PREFIX="stage3-${SUB_ARCH}"
  elif (( ${BUILD_TARGET_STAGE} == '2' ))
  then
    SRC_PATH_PREFIX="stage1-${SUB_ARCH}"
  elif (( ${BUILD_TARGET_STAGE} == '3' ))
  then
    SRC_PATH_PREFIX="stage2-${SUB_ARCH}"
  elif (( ${BUILD_TARGET_STAGE} == '4' ))
  then
    SRC_PATH_PREFIX="stage3-${SUB_ARCH}"
  fi

  [[ ${BUILD_TARGET} == livecd ]] && prepCatalystLiveCD
  [[ ${BUILD_TARGET} == stage ]] && prepCatalystStage
  
  log '1' "Starting run for: ${BUILD_NAME} with a ${REL_TYPE} stack on ${SUB_ARCH} for Stage: ${BUILD_TARGET_STAGE} for delivery by: ${BUILD_TARGET}"

  if (( SELINUX == 1 ))
  then
    local SCRIPT_SCOPE='1'
    log '1' "SELinux Enabled"
  fi

  if (( NO_MULTILIB == 1 ))
  then
    local SCRIPT_SCOPE='1'
    log '1' "Multilib Disabled"
  fi

  verifyObject 'dir' "${CATALYST_BUILD_DIR}" || die "Could not create build dir: ${CATALYST_BUILD_DIR}" '1'


  if [[ ${REL_TYPE} == 'hardened' ]]
  then
    SRC_PATH_PREFIX="${SRC_PATH_PREFIX}-${REL_TYPE}"
    (( NO_MULTILIB == 1 )) && SRC_PATH_PREFIX="${SRC_PATH_PREFIX}+nomultilib"
  else
    (( NO_MULTILIB == 1 )) && SRC_PATH_PREFIX="${SRC_PATH_PREFIX}-nomultilib"
  fi

  SRC_PATH="${BUILD_NAME}/${BUILD_TARGET}/${SRC_PATH_PREFIX}-${DIST_STAGE3_LATEST}"

  verifyTemplates "${SPEC_FILE}" || die "Could not verify templates" '1'
  mangleTemplate 'overwrite' "${SPEC_FILE}.header.template" "SUB_ARCH VERSION_STAMP REL_TYPE REL_PROFILE REL_SNAPSHOT SRC_PATH BUILD_NAME CPU_COUNT CATALYST_USERS BUILD_TARGET"
  (( $? == 0 )) || die "Could not manipulate spec file: header" '1'

  if ( (( ${BUILD_TARGET_STAGE} == '1' )) && [[ ${BUILD_TARGET} == 'livecd' ]] ) || ( (( ${BUILD_TARGET_STAGE} == '4' )) && [[ ${BUILD_TARGET} == 'stage' ]] )
  then
    cat ${CATALYST_TMP_DIR}/${BUILD_NAME}/${SPEC_FILE}.prep >> ${CATALYST_BUILD_DIR}/${SPEC_FILE}
  fi

  if ( (( ${BUILD_TARGET_STAGE} == '2' )) && [[ ${BUILD_TARGET} == 'livecd' ]] ) || ( (( ${BUILD_TARGET_STAGE} == '4' )) && [[ ${BUILD_TARGET} == 'stage' ]] )
  then
    mangleTemplate 'append' "${SPEC_FILE}.boot.template" "REL_TYPE SUB_ARCH BUILD_TARGET TARGET_KERNEL"
    (( $? == 0 )) || die "Could not manipulate spec file: boot" '1'
    cat ${CATALYST_TEMPLATE_DIR}/${SPEC_FILE}.post.template >> ${CATALYST_BUILD_DIR}/${SPEC_FILE}
    (( $? == 0 )) || die "Could not manipulate spec file: post" '1'
  fi

  (( BUILD_TARGET_STAGE == '1' )) && prepCatalystStage1

  if (( CLEAR_CCACHE == 1 ))
  then
    local SCRIPT_SCOPE='1'
    CURRENT_STAGE=$( basename ${SEED_STAGE/stage[1-4]/stage${BUILD_TARGET_STAGE}} .tar.bz2)
    log '0' "Clearing CCache: ${CATALYST_TMP_DIR}/${BUILD_NAME}/${BUILD_TARGET}/${CURRENT_STAGE}/var/ccache/"
    rm -rf ${CATALYST_TMP_DIR}/${BUILD_NAME}/${BUILD_TARGET}/${CURRENT_STAGE}/var/ccache/* || die "Failed to clear CCache" '1'
    (( $? > 0 )) &&  log '2' "Failed to clear ccache"
  fi

  runCatalyst 'build' || die "Catalyst failed to build" "$?"
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
  RUN_ID=${TIME_NOW}
  CATALYST_ARGS=""
  MAND_OPTS='6'

  (( ${#@} < 1 )) && usage && die "No arguments supplied" '1'

  while getopts ":A:K:N:P:S:T:V:acdknpqsv" opt
  do
    case ${opt} in
      A)
        SUB_ARCH="${OPTARG}"
      ;;
      K)
        TARGET_KERNEL="${OPTARG}"
      ;;
      N)
        BUILD_NAME="${OPTARG}"
      ;;
      P)
        REL_TYPE="${OPTARG}"
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
            die "Unknown flag: -$OPTARG"
          ;;
          :)
            die "Missing parameter for flag: -$OPTARG"
          ;;
          *)
            die "Invalid Target specified: $OPTARG, should be one of [ iso, ami, stage ]" '1'
          ;;
        esac
      ;;
      V)
        BUILD_VERSION="${OPTARG}"
      ;;
      a)
        [[ ! ${CATALYST_ARGS} =~ "-a" ]] && CATALYST_ARGS="${CATALYST_ARGS} -a"
      ;;
      c)
        CLEAR_CCACHE='1'
      ;;
      d)
        [[ ! ${CATALYST_ARGS} =~ "-d" ]] && CATALYST_ARGS="${CATALYST_ARGS} -d"
      ;;
      k)
        CATALYST_CONFIG="${CATALYST_CONFIG_KERNCACHE}"
        [[ ! ${CATALYST_ARGS} =~ "-c" ]] && CATALYST_ARGS="${CATALYST_ARGS} -c ${CATALYST_CONFIG}"
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

  [[ -n ${BUILD_TARGET} ]] || die "Target Unset" '1'
  
  if [[ ${BUILD_TARGET}='stage' || ${BUILD_TARGET}='livecd' ]]
  then
        [[ -n ${SUB_ARCH} ]] || die "ARCH Unset" '1'
        [[ -n ${TARGET_KERNEL} ]] || die "Target kernel Unset" '1'
        [[ -n ${BUILD_NAME} ]] || die "Build name unet" '1'
        [[ -n ${REL_TYPE} ]] || die "Profile unset" '1'
        [[ -n ${BUILD_TARGET_STAGE} ]] || die "Stage unset" '1'
  fi
  main
}

main() {
  if [[ ${BUILD_TARGET} == "livecd" ]]
  then
    if [[ ${BUILD_TARGET_STAGE} == "all" ]]
    then
      BUILD_TARGET_STAGE='1'
      main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
      BUILD_TARGET_STAGE='2'
      main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
    fi
    [[ ${BUILD_TARGET_STAGE} == [1-2] ]] || die "Need number of stage to build [1-2]" '1'
  else
    if [[ ${BUILD_TARGET_STAGE} == "all" ]]
    then
      BUILD_TARGET_STAGE='1'
      main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
      BUILD_TARGET_STAGE='2'
      main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
      BUILD_TARGET_STAGE='3'
      main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
      BUILD_TARGET_STAGE='4'
      main || die "Batch run failed in stage: ${BUILD_TARGET_STAGE}" '1'
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

(( VERBOSITY > 0 )) && debug

trap "echo && bundleLogs '2' && die 'SIGINT Caught' 2" SIGINT 
trap "echo && bundleLogs '2' && die 'SIGTERM Caught' 2" SIGTERM
trap "echo && bundleLogs '2' && die 'SIGHUP Caught' 2" SIGHUP
trap "cleanUp" EXIT
trap "(( ++VERBOSITY )) && debug" SIGUSR1
trap "DEBUG=1 && debug" SIGUSR2
RUN_ARGS=$@

menuSelect ${RUN_ARGS}

die "Fin." '0'
