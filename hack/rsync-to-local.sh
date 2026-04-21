#!/bin/bash
set -e
REMOTE="airport-jp"   
rsync -avz --progress \
  -e 'ssh -o RemoteCommand=none -o RequestTTY=no' \
  --exclude='.env' \
  --exclude='.DS_Store' \
  "ubuntu@${REMOTE}:/home/ubuntu/workspace/fangyuan/ai-radar/" \
  "/Users/yuan/Dev/alauda/ai-radar/"
