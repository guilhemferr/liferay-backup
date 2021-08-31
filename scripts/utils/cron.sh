#!/bin/bash

function max_day_in_month() {
  local month="$1"
  local year="$1"

  case $month in
  "1" | "3" | "5" | "7" | "8" | "10" | "12")
    echo 31
    ;;
  "2")
    local div4=$((year % 4))
    local div100=$((year % 100))
    local div400=$((year % 400))
    local days=28
    if [ "$div4" = "0" ] && [ "$div100" != "0" ]; then
      days=29
    fi
    if [ "$div400" = "0" ]; then
      days=29
    fi
    echo $days
    ;;
  *)
    echo 30
    ;;
  esac
}

function next_cron_expression() {
  local crex="$1"
  local num="$2"

  if [ "$crex" = "*" ] || [ "$crex" = "$num" ]; then
    echo $num
    return 0
  fi

  # expand
  local allvalid=""
  # take each comma-separated expression
  local parts=${crex//,/ }
  # replace * with # so that we can handle * as one of comma-separated terms without doing shell expansion
  parts=${parts//\*/#}
  for i in $parts; do
    # handle a range like 3-7
    # if it is a *, just add the number
    if [ "$i" = "#" ]; then
      echo $num
      return 0
    fi
    start=${i%%-*}
    end=${i##*-}
    for n in $(seq $start $end); do
      allvalid="$allvalid $n"
    done
  done

  # sort for deduplication and ordering
  allvalid=$(echo $allvalid | tr ' ' '\n' | sort -n -u | tr '\n' ' ')
  local bestmatch=${allvalid%% *}
  for i in $allvalid; do
    if [ "$i" = "$num" ]; then
      echo $num
      return 0
    fi
    if [ "$i" -gt "$num" ] && [ "$bestmatch" -lt "$num" ]; then
      bestmatch=$i
    fi
  done

  echo $bestmatch
}

#
# calculate seconds until next cron match
#
function wait_for_cron() {
  local cron="$1"
  local compare="$2"
  local last_run="$3"
  # we keep a copy of the actual compare time, because we might shift the compare time in a moment
  local comparesec=$compare
  # there must be at least 60 seconds between last run and next run, so if it is less than 60 seconds,
  #   add differential seconds to $compare
  local compareDiff=$((compare - last_run))
  if [ $compareDiff -lt 60 ]; then
    compare=$((compare + $((60 - compareDiff))))
  fi

  # cron only works in minutes, so we want to round down to the current minute
  # e.g. if we are at 20:06:25, we need to treat it as 20:06:00, or else our waittime will be -25
  # on the other hand, if we are at 20:06:00, do not round it down
  local current_seconds
  current_seconds=$(date --date="@$comparesec" +"%-S")
  if [ $current_seconds -ne 0 ]; then
    comparesec=$((comparesec - current_seconds))
  fi

  # reminder, cron format is:
  # minute(0-59)
  #   hour(0-23)
  #     day of month(1-31)
  #       month(1-12)
  #         day of week(0-6 = Sunday-Saturday)
  local cron_minute cron_hour cron_dom cron_month cron_dow
  cron_minute=$(echo -n "$cron" | awk '{print $1}')
  cron_hour=$(echo -n "$cron" | awk '{print $2}')
  cron_dom=$(echo -n "$cron" | awk '{print $3}')
  cron_month=$(echo -n "$cron" | awk '{print $4}')
  cron_dow=$(echo -n "$cron" | awk '{print $5}')

  local success=1

  # when is the next time we hit that month?
  local next_minute next_hour next_dom next_month next_dow next_year
  next_minute=$(date --date="@$compare" +"%-M")
  next_hour=$(date --date="@$compare" +"%-H")
  next_dom=$(date --date="@$compare" +"%-d")
  next_month=$(date --date="@$compare" +"%-m")
  next_dow=$(date --date="@$compare" +"%-u")
  next_year=$(date --date="@$compare" +"%-Y")

  # date returns DOW as 1-7/Mon-Sun, we need 0-6/Sun-Sat
  next_dow=$((next_dow % 7))

  local cron_next=

  # logic for determining next time to run
  # start by assuming our current min/hr/dom/month/dow is good, store it as "next"
  # go through each section: if it matches, keep going; if it does not, make it match or move ahead

  while [ "$success" != "0" ]; do
    # minute:
    # if minute matches, move to next step
    # if minute does not match, move "next" minute to the time that does match in cron
    #   if "next" minute is ahead of cron minute, then increment "next" hour by one
    #   move to hour
    cron_next=$(next_cron_expression "$cron_minute" "$next_minute")
    if [ "$cron_next" != "$next_minute" ]; then
      if [ "$next_minute" -gt "$cron_next" ]; then
        next_hour=$((next_hour + 1))
      fi
      next_minute=$cron_next
    fi

    # hour:
    # if hour matches, move to next step
    # if hour does not match:
    #   if "next" hour is ahead of cron hour, then increment "next" day by one
    #   set "next" hour to cron hour, set "next" minute to 0, return to beginning of loop
    cron_next=$(next_cron_expression "$cron_hour" "$next_hour")
    if [ "$cron_next" != "$next_hour" ]; then
      if [ "$next_hour" -gt "$cron_next" ]; then
        next_dom=$((next_dom + 1))
      fi
      next_hour=$cron_next
      next_minute=0
    fi

    # weekday:
    # if weekday matches, move to next step
    # if weekday does not match:
    #   move "next" weekday to next matching weekday, accounting for overflow at end of week
    #   reset "next" hour to 0, reset "next" minute to 0, return to beginning of loop
    cron_next=$(next_cron_expression "$cron_dow" "$next_dow")
    if [ "$cron_next" != "$next_dow" ]; then
      dowDiff=$((cron_next - next_dow))
      if [ "$dowDiff" -lt "0" ]; then
        dowDiff=$((dowDiff + 7))
      fi
      next_dom=$((next_dom + dowDiff))
      next_hour=0
      next_minute=0
    fi

    # dom:
    # if dom matches, move to next step
    # if dom does not match:
    #   if "next" dom is ahead of cron dom OR "next" month does not have crom dom (e.g. crom dom = 30 in Feb),
    #       increment "next" month, reset "next" day to 1, reset "next" minute to 0, reset "next" hour to 0, return to beginning of loop
    #   else set "next" day to cron day, reset "next" minute to 0, reset "next" hour to 0, return to beginning of loop
    maxDom=$(max_day_in_month next_month next_year)
    cron_next=$(next_cron_expression "$cron_dom" "$next_dom")
    if [ "$cron_next" != "$next_dom" ]; then
      if [ $next_dom -gt $cron_next ] || [ $next_dom -gt $maxDom ]; then
        next_month=$((next_month + 1))
        next_dom=1
      else
        next_dom=$cron_next
      fi
      next_hour=0
      next_minute=0
    fi

    # month:
    # if month matches, move to next step
    # if month does not match:
    #   if "next" month is ahead of cron month, increment "next" year by 1
    #   set "next" month to cron month, set "next" day to 1, set "next" minute to 0, set "next" hour to 0
    #   return to beginning of loop
    cron_next=$(next_cron_expression "$cron_month" "$next_month")
    if [ "$cron_next" != "$next_month" ]; then
      if [ $next_month -gt $cron_next ]; then
        next_year=$((next_year + 1))
      fi
      next_month=$cron_next
      next_day=1
      next_minute=0
      next_hour=0
    fi

    success=0
  done
  # success: "next" is now set to the next match!

  local future
  future=$(date --date="${next_year}.${next_month}.${next_dom}-${next_hour}:${next_minute}:00" +"%s")
  local futurediff=$((future - comparesec))
  echo $futurediff
}
