#!/bin/bash

declare -a OPT_ARGS=( 'a' 'd' 'k' 'o' 's' 'c' 'n' 'p' 'q' 'r' 'x' 'v' 'b' )
declare -a MAIN_ARGS=( 'T' 'S' 'A' 'K' 'N' 'P' 'R' 'V' )

declare -i FUZZ_OPT_ARGS_MAX='20'
declare -i FUZZ_MAIN_ARGS_MAX='10'
declare -i FUZZ_MAIN_VAL_MAX='15'
declare -i FUZZ_MAIN_VAL_MIN='5'
declare -i REAL_OPT_ARGS_MAX="${#OPT_ARGS[@]}"
declare -i REAL_MAIN_ARGS_MAX="${#MAIN_ARGS[@]}"

rand () {
  case $1 in
    str)
      openssl rand -base64 $2 | sed 's/==$//'
    ;;
    int)
      shuf -i 1-${2} -n ${3}
    ;;
  esac
}

fuzzer () {
  case $1 in
    1)
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

      echo "$geni_args $run_opt_args"
    ;;
    2)
      echo "Two"
    ;;
    3)
      echo "Three"
    ;;
  esac
}

#case $(rand int 2 1) in
case 1 in
  1)
    fuzzer $(rand int 3 1)
  ;;
  2)
      echo "Two"
  ;;
  3)
  ;;
  4)
  ;;
esac

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
