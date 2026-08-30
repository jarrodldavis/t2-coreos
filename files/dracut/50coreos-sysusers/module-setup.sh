#!/usr/bin/bash

check() {
    return 0
}

depends() {
    echo systemd-sysusers
}

install() {
    inst_sysusers 00-coreos-static.conf
}
