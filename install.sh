#!/bin/bash

#Set no unset and pipefail
set -u -o pipefail

#Set Installation Directory
declare -r INSTALL_DIR='/usr/local/bin'
declare -r BASE='/usr/bin/basename'

die () {
  echo "${1}"
  exit "${2}"
}

#Should probably do something smarter than this
[[ -f ./install.sh ]] || die "Please run from the same directory as project files" '1'

#Run as root!
(( UID == 0 )) || die "Please run as root" '1'

for file in *.sh
do
  [[ ${file} == install.sh ]] && continue
  cp ${file} ${INSTALL_DIR}/$(${BASE} ${file} .sh) || die "Could not copy ${file} to ${INSTALL_DIR}" '1'
  if [[ ! -x ${INSTALL_DIR}/$(${BASE} ${file} .sh) ]]
  then
    ${CHMOD} 755 ${INSTALL_DIR}/$(${BASE} ${file} .sh) || die "Could not chmod ${file}"
  fi
done

die 'fin.' '0'
