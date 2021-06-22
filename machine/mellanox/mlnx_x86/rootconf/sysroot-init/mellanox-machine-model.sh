#!/bin/sh

awk '!/onie_build_platform/ && !/onie_build_machine/' /etc/machine-build.conf > /etc/machine.conf

if [ -s /etc/machine-live.conf ] ; then
    awk '!/Runtime/' /etc/machine-live.conf >> /etc/machine.conf
fi

exit 0
