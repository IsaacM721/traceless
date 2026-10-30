#!/bin/zsh
cd "$(dirname "$0")"
/usr/bin/log stream --style compact --predicate 'subsystem == "com.isaacmendez.Traceless"' > 02-spotify-unified-log.txt 2>&1 &
LOGPID=$!
/usr/sbin/screencapture -v -V 50 -x 02-spotify-experiment.mov > screencapture-err.txt 2>&1 &
REC=$!
sleep 1.5
open -n ../build/Traceless.app --args --select Spotify --demo-uninstall
wait $REC
kill $LOGPID
cp ~/Library/Logs/Traceless/Traceless.log 02-spotify-traceless-log.txt
echo finished
