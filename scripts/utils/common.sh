#!/bin/bash

function ordered_ls() {
  find "${1-.}" -name "${2-*}" -maxdepth 1 ! -name "$(basename "${1-.}")" | sort -V
}

function execute_scripts() {
  if [ -e "${1}" ] && [[ $(ls -A "${1}") ]]; then

    echo "[LIFERAY] Executing scripts in ${1}:"
    for SCRIPT_NAME in $(ordered_ls "${1}" "*.sh"); do
      echo ""
      echo "[LIFERAY] Executing ${SCRIPT_NAME}."

      source "${SCRIPT_NAME}"
    done
    echo ""
  fi
}

function execute_sql_scripts() {
  if [ -e "${1}" ] && [[ $(ls -A "${1}") ]]; then

    echo "[LIFERAY] Executing scripts in ${1}:"
    for SQL_SCRIPT in $(ordered_ls "${1}" "*.sql"); do
      echo ""
      echo "[LIFERAY] Executing ${SQL_SCRIPT}."

      mysql -h "$DB_SERVER" -P "$DB_PORT" $DBUSER $DBPASS <"$SQL_SCRIPT"

    done
    echo ""
  fi
}

function copy() {
  cp "${cpOpts--r}" $1 $2
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
function file_env() {
  local var="$1"
  local fileVar="${var}_FILE"
  local def="${2:-}"
  if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
    echo >&2 "[ERROR] both $var and $fileVar are set (but are exclusive)"
    exit 1
  fi
  local val="$def"
  if [ "${!var:-}" ]; then
    val="${!var}"
  elif [ "${!fileVar:-}" ]; then
    val="$(<"${!fileVar}")"
  fi
  export "$var"="$val"
  unset "$fileVar"
}
