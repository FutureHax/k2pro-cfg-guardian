#!/bin/sh
# Run on the printer from the directory that holds this file.
#   sh install.sh
set -e

here=$(cd "$(dirname "$0")" && pwd)
base=/mnt/UDISK/cfg-guardian
vault=$base/vault
config_dir=/mnt/UDISK/printer_data/config

echo "installing cfg-guardian"
mkdir -p "$vault" "$base/state"

cp -f "$here/cfg-guardian.sh" /usr/bin/cfg-guardian.sh
chmod 755 /usr/bin/cfg-guardian.sh
cp -f "$here/cfg-guardian.init" /etc/init.d/cfg-guardian
chmod 755 /etc/init.d/cfg-guardian

for saved in "$here"/vault/*.cfg; do
    [ -f "$saved" ] || continue
    name=$(basename "$saved")
    if [ -f "$config_dir/$name" ]; then
        cp -f "$config_dir/$name" "$vault/$name"
        echo "vault kept the live $name"
    elif [ ! -f "$vault/$name" ]; then
        cp -f "$saved" "$vault/$name"
        echo "vault seeded $name"
    else
        echo "vault already has $name"
    fi
done

# Not shipped here. See jglerner/creality-k2-pro-klipper-screws-tilt.
screws=screws_tilt_adjust.cfg
screws_url=https://raw.githubusercontent.com/jglerner/creality-k2-pro-klipper-screws-tilt/main/screws_tilt_adjust.cfg
if [ -f "$config_dir/$screws" ]; then
    cp -f "$config_dir/$screws" "$vault/$screws"
    echo "vault kept the live $screws"
elif [ -f "$vault/$screws" ]; then
    echo "vault already has $screws"
else
    echo "downloading $screws"
    python3 -c 'import urllib.request,sys; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' \
        "$screws_url" "$vault/$screws"
fi
[ -f "$base/printer.cfg.includes" ] || cp -f "$here/vault/printer.cfg.includes" "$base/printer.cfg.includes"

if [ -f "$here/patches.json" ]; then
    cp -f "$here/patches.json" "$base/patches.json"
fi
rm -rf "$base/patches" "$here/patches"

if [ "$here" != "$base/dist" ]; then
    mkdir -p "$base/dist"
    cp -rf "$here"/. "$base/dist"/
fi
sync

/etc/init.d/cfg-guardian enable
/etc/init.d/cfg-guardian restart
sleep 1
echo "installed: $(ls /etc/rc.d/ | grep cfg-guardian | tr '\n' ' ')"
/usr/bin/cfg-guardian.sh status
