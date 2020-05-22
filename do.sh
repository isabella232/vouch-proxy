#!/bin/bash
set -e

# change dir to where this script is running
CURDIR=${PWD}
SCRIPT=$(readlink -f "$0")
SDIR=$(dirname "$SCRIPT")
cd $SDIR

export VOUCH_ROOT=${GOPATH}/src/github.com/vouch/vouch-proxy/

IMAGE=voucher/vouch-proxy:latest
ALPINE=voucher/vouch-proxy:alpine
GOIMAGE=golang:1.14
NAME=vouch-proxy
HTTPPORT=9090
GODOC_PORT=5050

run () {
  go run main.go
}

build () {
  local VERSION=$(git describe --always --long)
  local DT=$(date -u +"%Y-%m-%dT%H:%M:%SZ") # ISO-8601
  local FQDN=$(hostname --fqdn)
  local SEMVER=$(git tag --list --sort="v:refname" | tail -n -1)
  local BRANCH=$(git rev-parse --abbrev-ref HEAD)
  go build -i -v -ldflags=" -X main.version=${VERSION} -X main.builddt=${DT} -X main.host=${FQDN} -X main.semver=${SEMVER} -X main.branch=${BRANCH}" .
}

install () {
  cp ./vouch-proxy ${GOPATH}/bin/vouch-proxy
}

gogo () {
  docker run --rm -i -t -v /var/run/docker.sock:/var/run/docker.sock -v ${SDIR}/go:/go --name gogo $GOIMAGE $*
}

dbuild () {
  docker build -f Dockerfile -t $IMAGE .
}

dbuildalpine () {  
  docker build -f Dockerfile.alpine -t $ALPINE .
}

gobuildstatic () {
  export CGO_ENABLED=0
  export GOOS=linux
  build
}

drun () {
  if [ "$(docker ps | grep $NAME)" ]; then
    docker stop $NAME
    docker rm $NAME
  fi

  CMD="docker run --rm -i -t 
    -p ${HTTPPORT}:${HTTPPORT} 
    --name $NAME 
    -v ${SDIR}/config:/config 
    $IMAGE $* "

    echo $CMD
    $CMD
}

drunalpine () {
  IMAGE=$ALPINE
  drun $*
}


watch () {
  CMD=$@;
  if [ -z "$CMD" ]; then
      CMD="go run main.go"
  fi
  clear
  echo -e "starting watcher for:\n\t$CMD"

  # TODO: add *.tmpl and *.css
  # find . -type f -name '*.css' | entr -cr $CMD
  find . -name '*.go' | entr -cr $CMD
}

goget () {
  # install all the things
  go get -t -v ./...
}

REDACT=""
bug_report() {
  set +e
  # CONFIG=$1; shift;
  CONFIG=config/config.yml
  REDACT=$*

  if [ -z "$REDACT" ]; then 
    cat <<EOF

    bug_report cleans the ${CONFIG} and the Vouch Proxy logs of secrets and any additional strings (usually domains and email addresses)

    usage:

      $0 bug_report redacted_string redacted_string 

EOF
    exit 1;
  fi
  echo -e "\n-------------------------\n\n#\n# redacted Vouch Proxy ${CONFIG}\n# $(date -I)\n#\n"
  cat $CONFIG | _redact

  echo -e "\n-------------------------\n\n#\n# redacted Vouch Proxy logs\n# $(date -I)\n#\n"
  echo -e "# be sure to set 'vouch.testing: true' and 'vouch.logLevel: debug' in your config\n"

  trap _redact_exit SIGINT
  ./vouch-proxy 2>&1 | _redact


}
_redact_exit () {
  echo -e "\n\n-------------------------\n"
  echo -e "redact your nginx config with:\n"
  echo -e "\tcat nginx.conf | sed 's/yourdomain.com/DOMAIN.COM/g'\n"
  echo -e "Please upload both configs and some logs to https://hastebin.com/ and open an issue on GitHub at https://github.com/vouch/vouch-proxy/issues\n"
}

_redact() {
  SECRET_FIELDS=("client_id client_secret secret")
  while IFS= read -r LINE; do
    for i in $SECRET_FIELDS; do
      LINE=$(echo "$LINE" | sed -r "s/${i}..[[:graph:]]*\>/${i}: XXXXXXXXXXX/g")
    done
    # j=$(expr $j + 1)
    for i in $REDACT; do
      r=$i
      r=$(echo "$r" | sed "s/[[:alnum:]]/+/g")
      # LINE=$(echo "$LINE" | sed "s/${i}/+++++++/g")
      LINE=$(echo "$LINE" | sed "s/${i}/${r}/g")
    done
    echo "${LINE}"
  done
}

coverage() {
  export EXTRA_TEST_ARGS='-cover'
  test
  go tool cover -html=coverage.out -o coverage.html
}

test() {
  if [ -z "$VOUCH_CONFIG" ]; then
    export VOUCH_CONFIG="$SDIR/config/testing/test_config.yml"
  fi
  # test all the things
  if [ -n "$*" ]; then
    # go test -v -race $EXTRA_TEST_ARGS $*
    go test -race $EXTRA_TEST_ARGS $*
  else
    # go test -v -race $EXTRA_TEST_ARGS ./...
    go test -race $EXTRA_TEST_ARGS ./...
  fi
}

test_logging() {
  build

  declare -a levels=(error warn info debug)

  echo "testing loglevel set from command line"
  levelcount=0
  for ll in ${levels[*]}; do
    # test that we can see the current level and no level below this level

    declare -a shouldnotfind=()
    for (( i=0; i<${#levels[@]}; i++ ));  do
      if (( $i > $levelcount )); then
        shouldnotfind+=(${levels[$i]})
      fi
    done

    linesread=0
    IFS=$'\n';for line in $(./vouch-proxy -logtest -loglevel ${ll} -config ./config/testing/test_config.yml); do
      let "linesread+=1"
      # echo "$linesread $line"
      # first line is log info
      if (( $linesread > 1 )); then
        for nono in ${shouldnotfind[*]} ; do
          if echo $line | grep $nono; then
            echo "error: line should not contain '$nono' when loglevel is '$ll'"
            echo "$linesread $line"
            exit 1;
          fi
        done
      fi
    done
    let "levelcount+=1"
  done
  echo "passed"
  
  echo "testing loglevel set from config file"
  levelcount=0
  for ll in ${levels[*]}; do
    # test that we can see the current level and no level below this level
    declare -a shouldnotfind=()
    for (( i=0; i<${#levels[@]}; i++ ));  do
      if (( $i > $levelcount )); then
        shouldnotfind+=(${levels[$i]})
      fi
    done

    linesread=0
    IFS=$'\n';for line in $(./vouch-proxy -logtest -config ./config/testing/logging_${ll}.yml); do
      let "linesread+=1"
      # the first four messages are log and info when starting from the command line
      if (( $linesread > 4 )); then
        # echo "$linesread $line"
        for nono in ${shouldnotfind[*]} ; do
          # echo "testing $nono"
          if echo $line | grep $nono; then
            echo "error: line should not contain '$nono' when loglevel is '$ll'"
            echo "$linesread $line"
            exit 1;
          fi
        done
      fi
    done
    let "levelcount+=1"

  done
  echo "passed"
  exit 0
}

stats () {
  echo -n "lines of code: "
  find . -name '*.go' | xargs wc -l | grep total

  echo -n "number of go files: "
  find . -name '*.go' | wc -l

  echo -n "number of covered packages: "
  covered=$(coverage | grep ok | wc -l)
  echo $covered
  echo -n "number of packages not covered: "
  coverage | grep -v ok | wc -l

  echo -n "average of coverage for all covered packages: "
  sumcoverage=$(coverage | grep ok | awk '{print $5}' | sed 's/%//' | paste -sd+ - | bc)
  # echo " sumcoverage: $sumcoverage "
  perl -le "print $sumcoverage/$covered, '%'"
  exit 0;
}

license() {
  local FILE=$1;
  if [ ! -f "${FILE}" ]; then
    echo "need filename";
    exit 1;
  fi
  FOUND=$(_has_license $FILE)
  if [ -z "${FOUND}" ]; then
    local YEAR=$(git log -1 --format="%ai" -- $FILE | cut -d- -f1);
    _print_license $YEAR > ${FILE}_licensed
    cat $FILE >> ${FILE}_licensed
    mv ${FILE}_licensed $FILE
    echo "added license to the header of $FILE"
  fi

  # and then format the codebase
  gofmt

}

_print_license() {
  local YEAR=$1;
  if [ -z "$YEAR" ]; then
    YEAR=$(date +%Y)
  fi
  cat <<EOF
/*

Copyright $YEAR The Vouch Proxy Authors.
Use of this source code is governed by The MIT License (MIT) that 
can be found in the LICENSE file. Software distributed under The 
MIT License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
OR CONDITIONS OF ANY KIND, either express or implied.

*/

EOF

}

_has_license() {
  local FILE=$1;
  # echo checking $FILE
  echo $(grep -P 'Copyright \d\d\d\d The Vouch Proxy Authors' ${FILE})
}

profile() {
  echo "for profiling to work you may need to uncomment the code in main.go"
  build
  ./vouch-proxy -profile
  go tool pprof -http=0.0.0.0:19091 http://0.0.0.0:9090/debug/pprof/profile?seconds=10
}

gofmt() {
  # segfault's without exec since it would just call this function infinitely :)
  exec gofmt -w -s .
}

usage() {
   cat <<EOF
   usage:
     $0 run                    - go run main.go
     $0 build                  - go build
     $0 install                - move binary to ${GOPATH}/bin/vouch
     $0 goget                  - get all dependencies
     $0 gofmt                  - gofmt the entire code base
     $0 dbuild                 - build docker container
     $0 drun [args]            - run docker container
     $0 dbuildalpine           - build docker container for alpine
     $0 drunalpine [args]      - run docker container for alpine
     $0 test [./pkg_test.go]   - run go tests (defaults to all tests)
     $0 test_logging           - test the logging output
     $0 coverage               - coverage report
     $0 profile                - go pprof tools
     $0 bug_report domain.com  - print config file removing secrets and each provided domain
     $0 gogo [gocmd]           - run, build, any go cmd
     $0 stats                  - simple metrics (lines of code in project, number of go files)
     $0 watch [cmd]            - watch the $CWD for any change and re-reun the [cmd]
     $0 license [file]         - apply the license to the file

  do is like make

EOF
  exit 1

}

ARG=$1;

case "$ARG" in
   'run' \
   |'build' \
   |'dbuild' \
   |'drun' \
   |'dbuildalpine' \
   |'drunalpine' \
   |'install' \
   |'test' \
   |'goget' \
   |'gogo' \
   |'watch' \
   |'gobuildstatic' \
   |'coverage' \
   |'stats' \
   |'usage' \
   |'bug_report' \
   |'test_logging' \
   |'license' \
   |'profile' \
   |'gofmt')
   shift
   $ARG $*
   ;;
   'godoc')
   echo "godoc running at http://${GODOC_PORT}"
   godoc -http=:${GODOC_PORT}
   ;;
   'all')
   shift
   gobuildstatic
   dbuild
   drun $*
   ;;
   *)
   usage
   ;;
esac

exit;
