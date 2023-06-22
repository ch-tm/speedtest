#!/bin/bash
LANG=C

# data reported to main thread
testStatus=0 # 0=not started, 1=download test, 2=ping+jitter test, 3=upload test, 4=finished, 5=abort/error
dlStatus='' # download speed in megabit/s with 2 decimal digits
ulStatus='' # upload speed in megabit/s with 2 decimal digits
pingStatus='' # ping in milliseconds with 2 decimal digits
jitterStatus='' # jitter in milliseconds with 2 decimal digits
clientIp='' # client's IP address as reported by getIP.php

# test settings. can be overridden by sending specific values with the start command
time_ul=15 # duration of upload test in seconds
time_dl=15 # duration of download test in seconds
time_ulGraceTime=3 # time to wait in seconds before actually measuring ul speed (wait for buffers to fill)
time_dlGraceTime=2 # time to wait in seconds before actually measuring dl speed (wait for TCP window to increase)
count_ping=35 # number of pings to perform in ping test
server='speedtest.wildpark.net'
url_dl="http://$server/garbage.php" # path to a large file or garbage.php, used for download test. must be relative to this bash script
url_ul="http://$server/empty.php" # path to an empty file, used for upload test. must be relative to this bash script
url_ping="http://$server/empty.php" # path to an empty file, used for ping test. must be relative to this bash script
url_getIp="http://$server/getIP.php" # path to getIP.php relative to this bash script, or a similar thing that outputs the client's ip
xhr_dlMultistream=10 # number of download streams to use (can be different if enable_quirks is active)
xhr_ulMultistream=3 # number of upload streams to use (can be different if enable_quirks is active)
xhr_ignoreErrors=1 # 0=fail on errors, 1=attempt to restart a stream if it fails, 2=ignore all errors
xhr_dlUseBlob=false # if set to true, it reduces ram usage but uses the hard drive (useful with large garbagePhp_chunkSize and/or high xhr_dlMultistream)
garbagePhp_chunkSize=20 # size of chunks sent by garbage.php (can be different if enable_quirks is active)
enable_quirks=true # enable quirks for specific browsers. currently it overrides settings to optimize for specific browsers, unless they are already being overridden with the start command
overheadCompensationFactor=1048576/925000 # compensation for HTTP+TCP+IP+ETH overhead. 925000 is how much data is actually carried over 1048576 (1mb) bytes downloaded/uploaded. This default value assumes HTTP+TCP+IPv4+ETH with typical MTUs over the Internet. You may want to change this if you're going through your local network with a different MTU or if you're going over IPv6 (see doc.md for some other values)
upload_size=10 #upload size in Mb

# test functions

# done function to report the test results
print_done() {
  # report the test results to the main thread
  echo "$1 dl: $dlStatus ul: $ulStatus ping: $pingStatus jitter: $jitterStatus: ip: $clientIp"
}

# get client's IP using url_getIp, then call the done function
getIp() {
  clientIp=$(curl -s "$url_getIp?r=$(date +%s%N)")
}

# download test, call done function when it's over
dlTest() {
  dlSum=0.0
  for i in $(seq 1 $time_dl); do

    if (( $i > 1 )); then
      # wait for the grace time to complete
      sleep "$time_dlGraceTime"
    fi
    # download the file using curl
    downloadResult=$(curl -o /dev/null -s -w "%{time_total} %{size_download} %{speed_download}" "$url_dl?r=$RANDOM&ckSize=$garbagePhp_chunkSize")

    duration=$(echo "$downloadResult" | awk '{print $1}')
    totLoaded=$(echo "$downloadResult" | awk '{print $2}')
    speed_download=$(echo "$downloadResult" | awk '{print $3}')
    dlSum=$(echo "scale=2; $dlSum + $speed_download" | bc)
    dlSpeed=$(echo "scale=2; $dlSum / $i * 8 / 1000000" | bc)

    # wait for the download to finish
    #wait "$dlPid"

    # set the test status and download speed
    testStatus=2
    dlStatus=$dlSpeed

    # call the done function
    print_done "download test: $i/$time_dl"
  done
}

# upload test, call done function when it's over
ulTest() {
  ulSum=0.0
  for i in $(seq 1 $time_ul); do
    # generate a random 10MB file for upload
    dd if=/dev/urandom of=upload.tmp bs=1048576 count=$upload_size &>/dev/null

    if (( $i > 1 )); then
      sleep $time_ulGraceTime
    fi

    # upload the file using curl
    uploadResult=$(curl -o /dev/null -H Expect: -s -w "%{time_total} %{size_upload} %{speed_upload}" -F "file=@upload.tmp" "$url_ul?r=$RANDOM")

    duration=$(echo "$uploadResult" | awk '{print $1}')
    totLoaded=$(echo "$uploadResult" | awk '{print $2}')
    ulSpeed=$(echo "$uploadResult" | awk '{print $3}')

    # remove the temporary file
    rm upload.tmp

    # calculate the upload speed in megabit/s
    ulSum=$(echo "scale=2; $ulSum + $ulSpeed" | bc)
    ulSpeed=$(echo "scale=2; $ulSum / $i * 8 / 1000000" | bc)

    ulStatus=$ulSpeed

    # call the done function
    print_done "upload test: $i/$time_ul"
  done
}

# ping and jitter test, call done function when it's over
pingTest() {
  pingCalled=true # used to prevent multiple accidental calls to pingTest

  # perform the ping test and retrieve the average and jitter
  pingResult=$(ping -c "$count_ping" "$server" | tail -n 1 | awk -F'/' '{print $5,$7}')
  pingAvg=$(echo "$pingResult" | awk '{print $1}')
  jitter=$(echo "$pingResult" | awk '{print $2}')

  # set the test status, ping, and jitter
  testStatus=2
  pingStatus=$pingAvg
  jitterStatus=$jitter

  # call the done function
  print_done "ping test"
}

# main thread

# process the start command arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -ip)
      clientIp=$2
      shift ;;
    -dl)
      time_dl=$2
      shift ;;
    -ul)
      time_ul=$2
      shift ;;
    -ping)
      count_ping=$2
      shift ;;
    -getip)
      url_getIp=$2
      shift ;;
    -dlpath)
      url_dl=$2
      shift ;;
    -ulpath)
      url_ul=$2
      shift ;;
    -pingpath)
      url_ping=$2
      shift ;;
    -ulsize)
      upload_size=$2
      shift ;;
    *)
      shift ;;
  esac
  shift
done

# retrieve the client's IP address if not provided
if [[ -z $clientIp ]]; then
  getIp
fi

if [[ $count_ping -gt 0 ]]; then
  pingTest
fi

# run the tests based on the specified durations
if [[ $time_dl -gt 0 ]]; then
  dlTest
fi

if [[ $time_ul -gt 0 ]]; then
  ulTest
fi

# wait for all the tests to finish
#wait
#print_done
