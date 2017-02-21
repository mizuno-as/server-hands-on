#!/bin/bash

if [ -z "$1" ]
then
    echo "$0 container_name"
    exit 1
fi

YML=$(mktemp /tmp/init-XXXXX.yml)

cat > $YML <<EOF
#cloud-config

hostname: $1
ssh_pwauth: false

users:
  - name: YOURNAME
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - "YOUR PUBLIC KEY"
EOF

lxc info $1 2>/dev/null

if [ $? -eq 0 ]
then
    cat $YML
    lxc config set $1 user.user-data - < $YML
fi

rm $YML
