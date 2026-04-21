#!/bin/bash
set -e
REMOTE="airport-jp"   
rsync -avz --progress \
  -e 'ssh -o RemoteCommand=none -o RequestTTY=no' \
  --exclude='.env' \
  --exclude='.DS_Store' \
  "/Users/yuan/Dev/alauda/ai-radar/" \
  "ubuntu@${REMOTE}:/home/ubuntu/workspace/fangyuan/ai-radar/"
