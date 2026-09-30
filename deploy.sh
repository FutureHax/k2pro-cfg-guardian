#!/bin/sh
# ./deploy.sh root@printer
set -e
host=${1:?usage: ./deploy.sh root@printer}
here=$(cd "$(dirname "$0")" && pwd)

ssh "$host" 'mkdir -p /mnt/UDISK/cfg-guardian/dist'
tar -C "$here/src" -cf - . | ssh "$host" 'tar -C /mnt/UDISK/cfg-guardian/dist -xf -'
ssh "$host" 'sh /mnt/UDISK/cfg-guardian/dist/install.sh'
