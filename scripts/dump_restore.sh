#!/bin/bash

# set uri globally
declare -A uri

# shellcheck source=utils
for util in /usr/local/bin/utils/*.sh; do source "$util"; done

function dump_target() {
  # wait for the next time to start a backup
  echo "[LIFERAY] Starting at $(date)"
  last_run=0
  current_time=$(date +"%s")
  freq_time=$((DB_DUMP_FREQ * 60))
  # get the begin time on our date
  # REMEMBER: we are using the basic date package in alpine
  # could be a delay in minutes or an absolute time of day
  if [ -n "$DB_DUMP_CRON" ]; then
    # calculate how long until the next cron instance is met
    waittime=$(wait_for_cron "$DB_DUMP_CRON" "$current_time" $last_run)
  elif [[ $DB_DUMP_BEGIN =~ ^\+(.*)$ ]]; then
    waittime=$((BASH_REMATCH[1] * 60))
    target_time=$((current_time + waittime))
  else
    today=$(date +"%Y%m%d")
    target_time=$(date --date="${today}${DB_DUMP_BEGIN}" +"%s")

    if [[ "$target_time" < "$current_time" ]]; then
      target_time=$((target_time + 24 * 60 * 60))
    fi

    waittime=$((target_time - current_time))
  fi

  # If RUN_ONCE is set, don't wait
  if [ -z "${RUN_ONCE}" ]; then
    sleep $waittime
    last_run=$(date +"%s")
  fi

  exit_code=0
  while true; do
    # make sure the directory exists
    mkdir -p "$TMPDIR"
    do_dump
    [ $? -ne 0 ] && exit_code=1
    # we can have multiple targets
    for target in ${DB_DUMP_TARGET}; do
      backup_rotate_target "${target}"
      [ $? -ne 0 ] && exit_code=1
    done
    # remove lingering file
    /bin/rm "${TMPDIR}/${SOURCE}"

    # wait, unless RUN_ONCE is set
    current_time=$(date +"%s")
    if [ -n "${RUN_ONCE}" ]; then
      exit $exit_code
    elif [ -n "${DB_DUMP_CRON}" ]; then
      waittime=$(wait_for_cron "${DB_DUMP_CRON}" "$current_time" "$last_run")
    else
      current_time=$(date +"%s")
      # Calculate how long the previous backup took
      backup_time=$((current_time - target_time))
      # Calculate how many times the frequency time was passed during the previous backup.
      freq_time_count=$((backup_time / freq_time))
      # Increment the count with one because we want to wait at least the frequency time once.
      freq_time_count_to_add=$((freq_time_count + 1))
      # Calculate the extra time to add to the previous target time
      extra_time=$((freq_time_count_to_add * freq_time))
      # Calculate the new target time needed for the next calculation
      target_time=$((target_time + extra_time))
      # Calculate the wait time
      waittime=$((target_time - current_time))
    fi
    sleep $waittime
    last_run=$(date +"%s")
  done
}

function restore_target() {
  TMP_RESTORE=/tmp/restorefile
  wait_if_needed
  execute_scripts /scripts.d/pre-restore

  copy_backup_file_to_dest $TMP_RESTORE

  if [[ -f "$TMP_RESTORE" ]]; then
    workdir=/tmp/restore.$$
    rm -rf $workdir
    mkdir -p $workdir
    $UNCOMPRESS <$TMP_RESTORE | tar -C $workdir -xvf -
    execute_sql_scripts $workdir
    sync_dir=$workdir/$(basename "$DB_SYNC_TARGET_DIR")/.
    copy "$sync_dir" "$DB_SYNC_TARGET_DIR"
    rm -rf $workdir $TMP_RESTORE
  else
    echo "[LIFERAY] Could not find restore file $DB_RESTORE_TARGET"
    exit 1
  fi

  execute_scripts /scripts.d/post-restore
}
