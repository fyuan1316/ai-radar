#!/bin/bash
set -e
REMOTE="airport-jp"   
rsync -avz --progress \
  --exclude='.env' \
  --exclude='.DS_Store' \
  "ubuntu@${REMOTE}:/home/ubuntu/workspace/fangyuan/ai-radar/" \
  "/Users/yuan/Dev/speedup-lab/ai-radar/"
