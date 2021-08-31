#!/bin/bash
set -e

source ./_functions.sh

# list of sources and targets
declare -a targets

targets=(
  "/portal_backup/SEQ/data"
  "file:///portal_backup/SEQ/data"
  "smb://smb/noauth/SEQ/data"
  "smb://smb/nopath"
  "smb://user:pass@smb/auth/SEQ/data"
  "smb://CONF;user:pass@smb/auth/SEQ/data"
  "s3://mybucket/SEQ/data"
  "file:///portal_backup/SEQ/data file:///portal_backup/SEQ/data"
)
# we need to run through each each target and test the backup.
# before the first run, we:
# - start the sql database
# - populate it with a few inserts/creates
# - run a single clear backup
# for each stage, we:
# - clear the target
# - run the backup
# - check that the backup now is there in the right format
# - clear the target

cids=""

function do_test() {
  seq=0
  # do the file tests
  [[ "$DEBUG" != "0" ]] && echo "Doing tests"
  # create each target
  [[ "$DEBUG" != "0" ]] && echo "Populating volume for each target"
  for ((i = 0; i < ${#targets[@]}; i++)); do
    t=${targets[$i]}
    docker run --label mysqltest --name liferaybackup-data-populate --rm -v ${BACKUP_VOL}:/portal_backup -e DEBUG=${DEBUG} ${BACKUP_TESTER_IMAGE} populate "$t" $seq
    docker run --label mysqltest --name liferaybackup-data-populate --rm -v ${BACKUP_VOL}:/portal_backup -e DEBUG=${DEBUG} ${BACKUP_TESTER_IMAGE} prepare_pre_post "$t" $seq
    ((seq++)) || true
  done
  total=$seq

  # keep track of the sequence
  seq=0
  # create each target
  [[ "$DEBUG" != "0" ]] && echo "Running backups for each target"
  for ((i = 0; i < ${#targets[@]}; i++)); do
    t=${targets[$i]}
    cids1=$(run_dump_test "$t" $seq)
    cids="$cids $cids1"
    # increment our counter
    ((seq++)) || true
  done

  # now wait for everything
  waittime=10
  [[ "$DEBUG" != "0" ]] && echo "Waiting ${waittime} seconds to complete backup runs"
  sleep ${waittime}s

  rm_service_containers $smb_cid $mysql_cid $s3_cid
  rm_containers $cids
  rm_network

  # see the results and exit accordingly
  [[ "$DEBUG" != "0" ]] && echo "Checking results"
  declare -a fail
  declare -a pass

  seq=0
  for ((i = 0; i < ${#targets[@]}; i++)); do
    t=${targets[$i]}
    results=$(docker run --label mysqltest --name liferaybackup-data-check --rm -v ${BACKUP_VOL}:/portal_backup -e DEBUG=${DEBUG} ${BACKUP_TESTER_IMAGE} check "$t" $seq)

    echo "$results"
    # save the passes and fails
    #   | cat  - so that it doesn't return an error on no-match
    passes=$(echo "$results" | grep '^PASS:' | cat)
    fails=$(echo "$results" | grep '^FAIL:' | cat)
    echo "passes: '$passes'"
    echo "fails: '$fails'"
    while read -r line; do
      pass+=("$line")
    done < <(echo "$passes")
    while read -r line; do
      [ -n "$line" ] && fail+=("$line")
    done < <(echo "$fails")
    ((seq++)) || true
  done

  rm_volume

  # report results
  echo "Passed: ${#pass[@]}"
  echo "Failed: ${#fail[@]}"

  if [[ "${#fail[@]}" != "0" ]]; then
    for ((i = 0; i < ${#fail[@]}; i++)); do
      echo "${fail[$i]}"
    done
    exit 1
  else
    exit 0
  fi
}

makevolume
make_test_images
makesmb
makenetwork
start_service_containers
await_database
create_backup_file

do_test
