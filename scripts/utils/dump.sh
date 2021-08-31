#!/bin/bash

function do_dump() {
  # what is the name of our source and target?
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # SOURCE: file that the uploader looks for when performing the upload
  # TARGET: the remote file that is actually uploaded

  # option to replace
  if [ -n "$DB_DUMP_SAFECHARS" ]; then
    now=${now//:/-}
  fi
  SOURCE=${DB_DUMP_FILE_PREFIX}_${now}.$EXTENSION
  TARGET=${SOURCE}

  export NOW=${now} DUMPFILE=${TMPDIR}/${TARGET} DUMPDIR=${TMPDIR} DB_DUMP_DEBUG=${DB_DUMP_DEBUG}

  if ! execute_scripts /scripts.d/pre-backup; then
    echo "[LIFERAY] failed to execute scripts"
    return 1
  fi

  # do the dump
  workdir=/tmp/backup.$$
  rm -rf $workdir
  mkdir -p $workdir
  copy "$DB_SYNC_TARGET_DIR" $workdir
  NICE_CMD=
  # if we asked to do by schema, then we need to get a list of all of the databases,
  # take each, and then tar and zip them
  if [ -n "$DB_DUMP_BY_SCHEMA" ] && [ "$DB_DUMP_BY_SCHEMA" = "true" ]; then
    if [[ -z "$DB_NAMES" ]]; then
      DB_NAMES=$(mysql -h "$DB_SERVER" -P "$DB_PORT" "$DBUSER" "$DBPASS" -N -e 'show databases')
      [ $? -ne 0 ] && return 1
    fi
    for onedb in $DB_NAMES; do
      if [ "$NICE" = "true" ]; then
        NICE_CMD="nice -n19 ionice -c2"
      fi
      $NICE_CMD mysqldump -h "$DB_SERVER" -P "$DB_PORT" "$DBUSER" "$DBPASS" --databases "${onedb}" $MYSQLDUMP_OPTS >$workdir/"${onedb}"_"${now}".sql
      [ $? -ne 0 ] && return 1
    done
  else
    # just a single command
    if [[ -n "$DB_NAMES" ]]; then
      DB_LIST="--databases $DB_NAMES"
    else
      DB_LIST="-A"
    fi
    if [ "$NICE" = "true" ]; then
      NICE_CMD="nice -n19 ionice -c2"
    fi
    $NICE_CMD mysqldump -h "$DB_SERVER" -P "$DB_PORT" "$DBUSER" "$DBPASS" $DB_LIST $MYSQLDUMP_OPTS >$workdir/backup_"${now}".sql
    [ $? -ne 0 ] && return 1
  fi
  tar -C $workdir -cvf - . | $COMPRESS >"${TMPDIR}"/"${SOURCE}"
  [ $? -ne 0 ] && return 1
  rm -rf $workdir
  [ $? -ne 0 ] && return 1

  # Execute additional scripts for post processing. For example, create a new
  # backup file containing this db backup and a second tar file with the
  # contents of a wordpress install.
  if ! execute_scripts /scripts.d/post-backup; then
    echo "[LIFERAY] failed to execute scripts"
    return 1
  fi

  # Execute a script to modify the name of the source file path before uploading to the dump target
  # For example, modifying the name of the source dump file from the default, e.g. db-other-files-combined.tar.$EXTENSION
  if [ -f /scripts.d/source.sh ] && [ -x /scripts.d/source.sh ]; then
    SOURCE=$(NOW=${now} DUMPFILE=${TMPDIR}/${SOURCE} DUMPDIR=${TMPDIR} DB_DUMP_DEBUG=${DB_DUMP_DEBUG} /scripts.d/source.sh | tr -d '\040\011\012\015')
    [ $? -ne 0 ] && return 1

    if [ -z "${SOURCE}" ]; then
      echo "[LIFERAY] Your source script located at /scripts.d/source.sh must return a value to stdout"
      exit 1
    fi
  fi
  # Execute a script to modify the name of the target file before uploading to the dump target.
  # For example, uploading to a date stamped object key path in S3, i.e. s3://bucket/2018/08/23/path
  if [ -f /scripts.d/target.sh ] && [ -x /scripts.d/target.sh ]; then
    TARGET=$(NOW=${now} DUMPFILE=${TMPDIR}/${SOURCE} DUMPDIR=${TMPDIR} DB_DUMP_DEBUG=${DB_DUMP_DEBUG} /scripts.d/target.sh | tr -d '\040\011\012\015')
    [ $? -ne 0 ] && return 1

    if [ -z "${TARGET}" ]; then
      echo "[LIFERAY] Your target script located at /scripts.d/target.sh must return a value to stdout"
      exit 1
    fi
  fi

  return 0
}

function rotate_file() {
  if (( DB_DUMP_TARGET_ROTATION_SIZE > 0 )) && [[ -d ${1} ]]; then
    TARGET_FILES=$(ordered_ls "${1}" "*.${EXTENSION}")
    TARGET_FILES_SIZE=$(echo "$TARGET_FILES" | wc -l | xargs)
    if [ "$TARGET_FILES_SIZE" -gt "$DB_DUMP_TARGET_ROTATION_SIZE" ]; then
      echo "[LIFERAY] rotating $((TARGET_FILES_SIZE - DB_DUMP_TARGET_ROTATION_SIZE)) files: "
      echo "$TARGET_FILES" |
        head "$((DB_DUMP_TARGET_ROTATION_SIZE - TARGET_FILES_SIZE))" |
        xargs -t -I '{}' rm '{}'
    else
      echo "[LIFERAY] no files to rotate"
    fi
  fi
}

function rotate_s3() {
  echo "todo"
}

function rotate_smb() {
  echo "todo"
}

function backup_rotate_target() {
  local target=$1
  uri_parser "${target}"

  case "${uri[schema]}" in
  "file")
    copy "${TMPDIR}/${SOURCE}" "${uri[path]}/${TARGET}"
    rotate_file "${uri[path]}"
    ;;
  "s3")
    [[ -n "$AWS_ENDPOINT_URL" ]] && AWS_ENDPOINT_OPT="--endpoint-url $AWS_ENDPOINT_URL"
    aws ${AWS_CLI_OPTS} ${AWS_ENDPOINT_OPT} s3 cp "${TMPDIR}/${SOURCE}" "${DB_DUMP_TARGET}/${TARGET}"
    rotate_s3
    ;;
  "smb")
    if [[ -n "$SMB_USER" ]]; then
      UPASSARG="-U"
      UPASS="${SMB_USER}%${SMB_PASS}"
    elif [[ -n "${uri[user]}" ]]; then
      UPASSARG="-U"
      UPASS="${uri[user]}%${uri[password]}"
    else
      UPASSARG=
      UPASS=
    fi
    if [[ -n "${uri[userdomain]}" ]]; then
      UDOM="-W ${uri[userdomain]}"
    else
      UDOM=
    fi
    # smb has issues with the character `:` in filenames, so replace with `-`
    smbTargetName=${TARGET//:/-}
    smbclient -N "//${uri[host]}/${uri[share]}" ${UPASSARG} ${UPASS} ${UDOM} -c "cd ${uri[sharepath]}; put ${TMPDIR}/${SOURCE} ${smbTargetName}"
    rotate_smb
    ;;
  esac
  [ $? -ne 0 ] && return 1
  return 0
}
