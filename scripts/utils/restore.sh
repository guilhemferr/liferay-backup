#!/bin/bash

function wait_if_needed() {
  if [[ $DB_RESTORE_BEGIN =~ ^\+(.*)$ ]]; then
    waittime=$((BASH_REMATCH[1] * 60))
    sleep $waittime
  fi
}

function copy_backup_file_to_dest() {
  local dest=$1
  uri_parser "${DB_RESTORE_TARGET}"

  case "${uri[schema]}" in
  "file")
    if [[ -d ${DB_RESTORE_TARGET} ]]; then
      DB_RESTORE_TARGET="$(ordered_ls "$DB_RESTORE_TARGET" | tail -1)"
      echo "[LIFERAY] get latest dump: ${DB_RESTORE_TARGET}"
      export DB_RESTORE_TARGET
    fi
    copy "$DB_RESTORE_TARGET" "$dest"
    ;;
  "s3")
    echo "todo"
    ;;
  "smb")
    echo "todo"
    ;;
  *)
    echo "[LIFERAY] Invalid restore target file: $DB_RESTORE_TARGET"
    exit 1
    ;;
  esac
}
