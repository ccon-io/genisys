#!/bin/bash

#set -u -o pipefail

declare -r GENI='/usr/local/bin/geni'

declare -a OPT_ARGS=( 'a' 'd' 'k' 'o' 's' 'c' 'n' 'p' 'q' 'r' 'x' 'v' 'b' )
declare -a MAIN_ARGS=( 'T' 'S' 'A' 'K' 'N' 'P' 'R' 'V' )

declare -i FUZZ_OPT_ARGS_MAX='20'
declare -i FUZZ_MAIN_ARGS_MAX='10'
declare -i FUZZ_MAIN_VAL_MAX='15'
declare -i FUZZ_MAIN_VAL_MIN='5'
declare -i REAL_OPT_ARGS_MAX="${#OPT_ARGS[@]}"
declare -i REAL_MAIN_ARGS_MAX="${#MAIN_ARGS[@]}"
declare KERNEL_CUR='4.3.3'
declare ARCH_CUR='amd64'

rand () {
  case $1 in
    str)
      openssl rand -base64 $2 | sed 's/=//g'
    ;;
    int)
      shuf -i 1-${2} -n ${3}
    ;;
    wrd)
      shuf -n ${2} /usr/share/dict/cracklib-small
    ;;
  esac
}

gene () {
  #Gene Geni ;)
  case $1 in
    1)
      ${GENI} -T stage -S all -A ${ARCH_CUR} -K ${KERNEL_CUR} -N $(rand wrd 1) -P ${2} ${3}
    ;;
    2)
      ${GENI} ${2} ${3}
    ;;
  esac
}

fuzzer () {
  case $1 in
    1)
      #gibberish
      local -a run_main_args=""
      local -a run_opt_args=""
      local -a geni_args=""

      local -i str_length=$(rand int 15 1)
      local -i main_itr=$(( FUZZ_MAIN_ARGS_MAX - $(rand int 3 1) ))
      local -i opt_itr=$(( FUZZ_OPT_ARGS_MAX - $(rand int 7 1) ))

      for i in $(rand int ${FUZZ_MAIN_ARGS_MAX} ${main_itr} )
      do
        local run_main_args+=" ${MAIN_ARGS[$i]}"
      done

      for i in $(rand int ${FUZZ_MAIN_ARGS_MAX} ${opt_itr} )
      do
        local run_opt_args+=" -${OPT_ARGS[$i]}"
      done
      
      for opt in ${run_main_args[@]}
      do
        geni_args+=" -${opt} $(rand str ${str_length})"
      done
    ;;
    2)
      #little smarter
      local -a run_main_args=""
      local -a run_opt_args=""
      local -a geni_args=""

      local -i main_itr=$(( FUZZ_MAIN_ARGS_MAX - $(rand int 3 1) ))
      local -i opt_itr=$(( FUZZ_OPT_ARGS_MAX - $(rand int 7 1) ))

      for i in $(rand int ${FUZZ_MAIN_ARGS_MAX} ${main_itr} )
      do
        local run_main_args+=" ${MAIN_ARGS[$i]}"
      done

      for i in $(rand int ${FUZZ_MAIN_ARGS_MAX} ${opt_itr} )
      do
        local run_opt_args+=" -${OPT_ARGS[$i]}"
      done
      
      for opt in ${run_main_args[@]}
      do
        geni_args+=" -${opt} $(rand wrd 1)"
      done

    ;;
  esac

  gene 2 "$geni_args" "$run_opt_args"
}

masher () {
  TARGETS=( 'ami' 'iso' 'livecd' 'stage' )
  STAGES=( '1' '2' '3' '4' 'all' )
  ARCHES=( 'amd64' 'x86' )
  KERNELS=( '4.1.7' '4.1.12' '4.1.15' '4.3.3' )
  PROFILES=( 'hardened' 'vanilla' )
  PORT_SNAPSHOTS=( '20160125' '20160126' '20160127' '20160128' )
  STAGE_SNAPSHOTS=( '20160121' '20160123' '20160115' '20160126' )

  case ${1} in
    1)
      gene 2 "-T ${TARGETS[(( $(rand int ${#TARGETS[@]} 1) - 1 ))]} -S ${STAGES[(( $(rand int ${#STAGES[@]} 1) - 1 ))]} -A ${ARCHES[(( $(rand int ${#ARCHES[@]} 1) - 1 ))]} -K ${KERNELS[(( $(rand int ${#KERNELS[@]} 1) - 1 ))]} -P ${PROFILES[(( $(rand int ${#PROFILES[@]} 1) - 1 ))]}"
    ;;
    2)
      local method=$(rand int 2 1)
      (( method == 1 )) && local target=$(rand int 6 1)
      (( method == 2 )) && local target=$(rand int 8 1)
      case ${method} in
        1)
          case ${target} in
            1)
              gene 1 "vanilla" "-b"
            ;;
            2)
              gene 1 "vanilla" "-n -b"
            ;;
            3)
              gene 1 "vanilla" "-n -a -b"
            ;;
            4)
              gene 1 "vanilla" "-n -o -b"
            ;;
            5)
              gene 1 "vanilla" "-n -a -d -b"
            ;;
            6)
              gene 1 "vanilla" "-n -o -d -b"
            ;;
          esac
        ;;
        2)
          case ${target} in
            1)
              gene 1 "hardened" "-b"
            ;;
            2)
              gene 1 "hardened" "-s -b"
            ;;
            3)
              gene 1 "hardened" "-n -b"
            ;;
            4)
              gene 1 "hardened" "-n -s -b"
            ;;
            5)
              gene 1 "hardened" "-n -s -a -d -b"
            ;;
            6)
              gene 1 "hardened" "-n -s -o -d -b"
            ;;
            7)
              gene 1 "hardened" "-n -a -d -b"
            ;;
            8)
              gene 1 "hardened" "-n -o -d -b"
            ;;
          esac
        ;;
      esac
    ;;
  esac


}

main () {
  case $(rand int 2 1) in
    1)
      fuzzer $(rand int 2 1)
    ;;
    2)
      masher $(rand int 2 1)
    ;;
  esac
}

(( ${#@} == 0 )) && echo "How long to run?" && exit

if [[ $1 =~ ^[0-9].*h$ ]]
then
  TIME_LIMIT=$(( ${1/h/} * 3600 ))
elif [[ $1 =~ ^[0-9].*m$ ]]
then
  TIME_LIMIT=$(( ${1/m/} * 60 ))
else
  TIME_LIMIT=${1}
fi

TIME_LIMIT=$(( $(date +%s) + TIME_LIMIT ))

echo "Runing until $(date --date=@${TIME_LIMIT})"

while (( $(date +%s) < TIME_LIMIT  )) 
do
  echo "Screeeeee! Chaos Pidgeoning..."
  main
done

#geni    -T { ami | iso | livecd | stage }       -- Build an AMI for Amazon, bootable iso, livecd image or stage tarball
#-S { 1..4 }                             -- What stage (1-2 for livecd, 1-4 for regular stage or 'all' for either)
#-A { amd64 | x86 | ... }                -- Architecture we are building on
#-K { kernel version }                   -- Version of kernel to build
#-N { BuildName }                        -- Name / Unique Identifier of this build
#-P { hardened | vanilla }               -- Base profile for this build
#-R { snapshot }                         -- ID of Portage snapshot to use (latest if omitted)
#-V { version }                          -- Version of stage snapshot to fetch (latest if omitted)
#
#Optional args:  -a [aws support]        -d [docker support]     -k [enable kerncache]   -o [openstack support]  -s [selinux support]
#-c [clear ccache]       -n [no-multilib]        -p [purge last build]   -q [quiet output]       -r [clear autoresume]
#-x [debug output]       -v [increase verbosity] -b [batch mode]
