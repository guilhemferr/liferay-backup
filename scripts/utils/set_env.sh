#!/bin/bash

function set_env_variables() {
  file_env "DB_SERVER"
  file_env "DB_PORT"
  file_env "DB_USER"
  file_env "DB_PASS"
  file_env "DB_NAMES"

  file_env "DB_DUMP_FREQ" "1440"
  file_env "DB_DUMP_BEGIN" "+0"
  file_env "DB_DUMP_DEBUG"
  file_env "DB_DUMP_TARGET" "/home/liferay/portal_backup"
  file_env "DB_DUMP_TARGET_ROTATION_SIZE"
  file_env "DB_DUMP_FILE_PREFIX" "portal_backup"
  file_env "DB_DUMP_BY_SCHEMA"
  file_env "DB_DUMP_KEEP_PERMISSIONS" "true"

  file_env "DB_SYNC_TARGET_DIR"

  file_env "DB_RESTORE_TARGET" "/home/liferay/portal_backup"
  file_env "DB_RESTORE_BEGIN" "+0"
  file_env "DB_RESTORE_ONLY"

  file_env "AWS_ENDPOINT_URL"
  file_env "AWS_ENDPOINT_OPT"
  file_env "AWS_CLI_OPTS"
  file_env "AWS_CLI_S3_CP_OPTS"
  file_env "AWS_ACCESS_KEY_ID"
  file_env "AWS_SECRET_ACCESS_KEY"
  file_env "AWS_DEFAULT_REGION"

  file_env "SMB_USER"
  file_env "SMB_PASS"

  file_env "COMPRESSION" "gzip"

  TMPDIR=/tmp/portal_backup
}

function set_env_debug_mode() {
  if [[ -n "$DB_DUMP_DEBUG" ]]; then
    set -x
  fi
}

function set_env_mysql() {
  MYSQLDUMP_OPTS=${MYSQLDUMP_OPTS:-}
  # login credentials
  if [ -n "${DB_USER}" ]; then
    DBUSER="-u${DB_USER}"
  else
    DBUSER=
  fi
  if [ -n "${DB_PASS}" ]; then
    DBPASS="-p${DB_PASS}"
  else
    DBPASS=
  fi
  # database server
  if [ -z "${DB_SERVER}" ]; then
    echo "DB_SERVER variable is required. Exiting."
    exit 1
  fi
  # database port
  if [ -z "${DB_PORT}" ]; then
    echo "DB_PORT not provided, defaulting to 3306"
    DB_PORT=3306
  fi
}

function set_env_compress_decompress() {
  COMPRESS=
  UNCOMPRESS=
  case $COMPRESSION in
  gzip)
    COMPRESS="gzip"
    UNCOMPRESS="gunzip"
    EXTENSION="tgz"
    ;;
  bzip2)
    COMPRESS="bzip2"
    UNCOMPRESS="bzip2 -d"
    EXTENSION="tbz2"
    ;;
  *)
    echo "Unknown compression requested: $COMPRESSION" >&2
    exit 1
    ;;
  esac
  export COMPRESS UNCOMPRESS EXTENSION
}

function set_env_copy_options() {
  cpOpts="-a"
  [ -n "$DB_DUMP_KEEP_PERMISSIONS" ] && [ "$DB_DUMP_KEEP_PERMISSIONS" = "false" ] && cpOpts=""
  export cpOpts
}

function set_env() {
  set_env_debug_mode
  set_env_variables
  set_env_debug_mode
  set_env_mysql
  set_env_compress_decompress
  set_env_copy_options
}
