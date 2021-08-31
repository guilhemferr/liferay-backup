#!/bin/bash
set -e

DEBUG=${DEBUG:-0}
[[ -n "$DEBUG" && "$DEBUG" == "verbose" ]] && DEBUG=1
[[ -n "$DEBUG" && "$DEBUG" == "debug" ]] && DEBUG=2

[[ "$DEBUG" == "2" ]] && set -x

BACKUP_IMAGE=liferaybackup_backup_test:latest
BACKUP_TESTER_IMAGE=liferaybackup_backup_test_harness:latest
SMB_IMAGE=liferaybackup_smb_test:latest
BACKUP_VOL=liferaybackup-test
MYSQLUSER=user
MYSQLPW=abcdefg
MYSQLDB=tester
MYSQLOPTS="--compact --no-tablespaces --no-create-db"

QUIET="-q"
[[ "$DEBUG" != "0" ]] && QUIET=""

smb_cid=
mysql_cid=
s3_cid=

function create_backup_file() {
  local target=/tmp/backup.$$.tgz
  echo 'use '"${MYSQLDB}"'; create table t1 (id INT, name VARCHAR(20)); INSERT INTO t1 (id,name) VALUES (1, "John"), (2, "Jill"), (3, "Sam"), (4, "Sarah");' | $db_connect
  tmpdumpdir=/tmp/backup_holder.$$
  rm -rf $tmpdumpdir
  mkdir $tmpdumpdir
  tmpdumpfile=backup.sql
  docker exec "$mysql_cid" mysqldump -hlocalhost --protocol=tcp -u$MYSQLUSER -p$MYSQLPW --databases $MYSQLDB $MYSQLOPTS >$tmpdumpdir/$tmpdumpfile
  tar -C $tmpdumpdir -cvf - $tmpdumpfile | gzip >${target}
  docker run -i --label mysqltest --name mysqlbackup-data-source --rm -v ${BACKUP_VOL}:/portal_backup -e DEBUG=${DEBUG} ${BACKUP_TESTER_IMAGE} save_dump <$target
  rm -rf $tmpdumpdir $target
}

function configure_backup_directory_target() {
  local t=$1
  local seqno=$2
  # where will we store
  # create the backups directory
  # clear the target
  # replace SEQ if needed
  t2=${t/SEQ/${seqno}}
  mkdir -p ${BACKUP_DIRECTORY_BASE}/${seqno}/data
  chmod -R 0777 ${BACKUP_DIRECTORY_BASE}/${seqno}
  echo "target: ${t2}" >>${BACKUP_DIRECTORY_BASE}/${seqno}/list

  # are we working with nopath?
  if [[ "$t2" =~ nopath ]]; then
    rm -f ${BACKUP_DIRECTORY_BASE}/nopath
    ln -s ${seqno}/data ${BACKUP_DIRECTORY_BASE}/nopath
  fi

  echo ${t2}
}

function get_default_source() {
  echo "portal_backup_*.tgz"
}

function make_test_images() {
  [[ "$DEBUG" != "0" ]] && echo "Creating backup image"

  docker build ${QUIET} -t ${BACKUP_IMAGE} -f ../Dockerfile ../
  docker build ${QUIET} -t ${BACKUP_TESTER_IMAGE} -f Dockerfile_test --build-arg BASE=${BACKUP_IMAGE} ctr/
}

function rm_containers() {
  local cids=$@
  [[ "$DEBUG" != "0" ]] && echo "Removing backup containers"

  # stop and remove each container
  [[ "$DEBUG" != "0" ]] && echo "Stopping and removing ${cids}"
  for i in ${cids}; do
    CMD1="docker kill ${i}"
    CMD2="docker rm ${i}"
    if [[ "$DEBUG" == "0" ]]; then
      $CMD1 >/dev/null 2>&1
      $CMD2 >/dev/null 2>&1
    else
      # keep the logs
      docker logs $i
      $CMD1
      $CMD2
    fi
  done
}

function makenetwork() {
  [[ "$DEBUG" != "0" ]] && echo "Creating the test network"
  local EXISTING_NETS
  EXISTING_NETS=$(docker network ls --filter label=mysqltest -q)
  [ -n "${EXISTING_NETS}" ] && docker network rm "${EXISTING_NETS}"
  docker network create mysqltest --label mysqltest
}

function makevolume() {
  local EXISTING_VOLS
  EXISTING_VOLS=$(docker volume ls --filter label=mysqltest -q)
  [ -n "${EXISTING_VOLS}" ] && docker volume rm "${EXISTING_VOLS}"
  docker volume create --label mysqltest $BACKUP_VOL
}

function makesmb() {
  [[ "$DEBUG" != "0" ]] && echo "Creating smb image"
  docker build ${QUIET} -t ${SMB_IMAGE} -f ./Dockerfile_smb ctr/
}

function start_service_containers() {
  [[ "$DEBUG" != "0" ]] && echo "Running smb, s3 and mysql containers"
  smb_cid=$(docker run --label mysqltest --net mysqltest --name=smb -d -p 445:445 -v ${BACKUP_VOL}:/share/portal_backup -t ${SMB_IMAGE})
  mysql_cid=$(docker run --label mysqltest --net mysqltest --name mysql -d -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=$MYSQLDB -e MYSQL_USER=$MYSQLUSER -e MYSQL_PASSWORD=$MYSQLPW mysql:8.0)
  s3_cid=$(docker run --label mysqltest --net mysqltest --name s3 -d -v ${BACKUP_VOL}:/fakes3_root/s3/mybucket lphoward/fake-s3 -r /fakes3_root -p 443)
}

function await_database() {
  echo "waiting for DB to be ready..."
  db_connect="docker exec -i $mysql_cid mysql -u$MYSQLUSER -p$MYSQLPW --protocol=tcp -h127.0.0.1 --wait --connect_timeout=20 $MYSQLDB"
  retry_count=0
  retryMax=20
  retrySleep=1
  until [[ $retry_count -ge $retryMax ]]; do
    set +e
    $db_connect -e 'select 1;' 2>/dev/null
    success=$?
    set -e
    [[ $success == 0 ]] && break
    ((retry_count++)) || true
    sleep $retrySleep
  done
  # did we succeed?
  if [[ $success != 0 ]]; then
    echo -n "failed to connect to database after $retryMax tries." >&2
    return 1
  fi
  echo "DB is ready!"
}

function rm_service_containers() {
  local smb_cid="$1"
  local mysql_cid="$2"
  local s3_cid="$3"
  if [[ "$DEBUG" == "2" ]]; then
    echo
    echo "SMB LOGS:"
    docker logs $smb_cid
    echo
    echo "MYSQL LOGS:"
    docker logs $mysql_cid
    echo
    echo "S3 LOGS:"
    docker logs $s3_cid
  fi

  [[ "$DEBUG" != "0" ]] && echo "Stopping and removing smb, mysql and s3 containers"
  local CMD1="docker kill $smb_cid $mysql_cid $s3_cid"
  local CMD2="docker rm $smb_cid $mysql_cid $s3_cid"
  if [[ "$DEBUG" == "0" ]]; then
    $CMD1 >/dev/null 2>&1
    $CMD2 >/dev/null 2>&1
  else
    $CMD1
    $CMD2
  fi
}

function rm_network() {
  [[ "$DEBUG" != "0" ]] && echo "Removing docker network"
  docker network rm mysqltest
}

function rm_volume() {
  [[ "$DEBUG" != "0" ]] && echo "Removing docker volume"
  docker volume rm ${BACKUP_VOL}
}

function run_dump_test() {
  local t=$1
  local sequence=$2
  local subseq=0
  local allTargets=
  # we might have multiple targets
  for target in $t; do
    seqno="${sequence}-${subseq}"
    # where will we store
    # create the backups directory
    # clear the target
    # replace SEQ if needed
    t2=${target/SEQ/${seqno}}
    allTargets="${allTargets} ${t2}"

    ((subseq++)) || true
  done

  # if in DEBUG, make sure backup also runs in DEBUG
  if [[ "$DEBUG" != "0" ]]; then
    DBDEBUG="-e DB_DUMP_DEBUG=2"
  else
    DBDEBUG=
  fi

  # change our target
  # ensure that we remove leading whitespace from targets
  allTargets=$(echo $allTargets | awk '{$1=$1;print}')
  cid=$(docker container create --label mysqltest --name mysqlbackup-${sequence} --net mysqltest -v ${BACKUP_VOL}:/portal_backup --link ${s3_cid}:mybucket.s3.amazonaws.com ${DBDEBUG} -e DB_USER=$MYSQLUSER -e DB_PASS=$MYSQLPW -e DB_NAMES=$MYSQLDB -e MYSQLDUMP_OPTS="${MYSQLOPTS}" -e DB_DUMP_FREQ=60 -e DB_DUMP_BEGIN=+0 -e DB_DUMP_TARGET="${allTargets}" -e AWS_ACCESS_KEY_ID=abcdefg -e AWS_SECRET_ACCESS_KEY=1234567 -e AWS_ENDPOINT_URL=http://s3:443/ -e DB_SERVER=mysql ${BACKUP_IMAGE})
  linkfile=/tmp/link.$$
  ln -s /portal_backup/$sequence ${linkfile}
  docker cp ${linkfile} $cid:/scripts.d
  rm ${linkfile}
  docker container start ${cid} >/dev/null
  echo $cid
}
