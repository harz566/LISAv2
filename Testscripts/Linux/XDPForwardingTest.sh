#!/bin/bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

# This script starts pktgen and checks XDP_TX forwarding performance

packetCount=10000000
nicName='eth1'

function download_pktgen_scripts(){
        local ip=$1
        local dir=$2
        if [ "${core}" = "multi" ];then
                ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/pktgen_sample05_flow_per_thread.sh?h=v5.7.8 -O ${dir}/pktgen_sample.sh"
        else
                ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/pktgen_sample01_simple.sh?h=v5.7.8 -O ${dir}/pktgen_sample.sh"
        fi
        ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/functions.sh?h=v5.7.8 -O ${dir}/functions.sh"
        ssh $ip "wget https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/samples/pktgen/parameters.sh?h=v5.7.8 -O ${dir}/parameters.sh"
        ssh $ip "chmod +x ${dir}/*.sh"
}

UTIL_FILE="./utils.sh"

# Source utils.sh
. ${UTIL_FILE} || {
    echo "ERROR: unable to source ${UTIL_FILE}!"
    echo "TestAborted" > state.txt
    exit 0
}

XDPUTIL_FILE="./XDPUtils.sh"

# Source utils.sh
. ${XDPUTIL_FILE} || {
    echo "ERROR: unable to source ${XDPUTIL_FILE}!"
    echo "TestAborted" > state.txt
    exit 0
}

# Source constants file and initialize most common variables
UtilsInit
# Script start from here
LogMsg "*********INFO: Script execution Started********"
LogMsg "forwarder : ${forwarder}"
LogMsg "receiver : ${receiver}"
LogMsg "nicName: ${nicName}"
bash ./XDPDumpSetup.sh ${forwarder} ${nicName}
check_exit_status "XDPDumpSetup on ${forwarder}" "exit"
bash ./XDPDumpSetup.sh ${receiver} ${nicName}
check_exit_status "XDpDUMPSetup on ${receiver}" "exit"

LogMsg "XDP Setup Completed"

# Setup pktgen on Sender
LogMsg "Configure pktgen on ${sender}"
pktgenDir=~/pktgen
ssh ${sender} "mkdir -p ${pktgenDir}"
download_pktgen_scripts ${sender} ${pktgenDir}
# Configure XDP_TX on Forwarder
LogMsg "Build XDPDump with TX Action on ${forwarder}"
ssh ${forwarder} "cd bpf-samples/xdpdump && make clean && CFLAGS='-D __PERF_TX__ -D __PERF__ -I../libbpf/src/root/usr/include' make"
check_exit_status "Build xdpdump with TX Action on ${forwarder}"
# Configure XDP_DROP on receiver
LogMsg "Build XDPDump with DROP Action on ${receiver}"
ssh ${receiver} "cd bpf-samples/xdpdump && make clean && CFLAGS='-D __PERF_DROP__ -D __PERF__ -I../libbpf/src/root/usr/include' make"
check_exit_status "Build xdpdump with DROP Action on ${receiver}"

# Calculate packet drops before tests
packetDropBefore=$(ssh ${receiver} ". XDPUtils.sh && calculate_packets_drop ${nicName}")
LogMsg "Before test, Packet drop count on ${receiver} is ${packetDropBefore}"
# Calculate packets forwarded before tests
pktForwardBefore=$(ssh ${forwarder} ". XDPUtils.sh && calculate_packets_forward ${nicName}")
LogMsg "Before test, Packet forward count on ${forwarder} is ${pktForwardBefore}"

# Start XDPDump on receiver
xdpdumpCommand="cd bpf-samples/xdpdump && ./xdpdump -i ${nicName} > ~/xdpdumpout_${receiver}.txt"
LogMsg "Starting xdpdump on ${receiver} with command: ${xdpdumpCommand}"
ssh -f ${receiver} "sh -c '${xdpdumpCommand}'"
# Start XDPDump on forwarder
xdpdumpCommand="cd bpf-samples/xdpdump && ./xdpdump -i ${nicName} > ~/xdpdumpout_${forwarder}.txt"
LogMsg "Starting xdpdump on ${forwarder} with command: ${xdpdumpCommand}"
ssh -f ${forwarder} "sh -c '${xdpdumpCommand}'"

# Start pktgen on Sender
forwarderSecondMAC=$((ssh ${forwarder} "ip link show ${nicName}") | grep ether | awk '{print $2}')
LogMsg "Forwarder second MAC: ${forwarderSecondMAC}"
if [ "${core}" = "single" ];then
        startCommand="cd ${pktgenDir} && ./pktgen_sample.sh -i ${nicName} -m ${forwarderSecondMAC} -d ${forwarderSecondIP} -v -n${packetCount}"
        LogMsg "Starting pktgen on sender: $startCommand"
        ssh ${sender} "modprobe pktgen; lsmod | grep pktgen"
        result=$(ssh ${sender} "${startCommand}")
else
        startCommand="cd ${pktgenDir} && ./pktgen_sample.sh -i ${nicName} -m ${forwarderSecondMAC} -d ${forwarderSecondIP} -v -n${packetCount} -t8"
        LogMsg "Starting pktgen on sender: ${startCommand}"
        ssh ${sender} "modprobe pktgen; lsmod | grep pktgen"
        result=$(ssh ${sender} "${startCommand}")
fi
sleep 10
# Kill XDPDump on reciever & forwarder
LogMsg "Killing xdpdump on receiver and forwarder"
ssh ${receiver} "killall xdpdump"
ssh ${forwarder} "killall xdpdump"
# Calculate: Sender PPS, Forwarder # packets, receiver # packets
# Calculate packet drops before tests
packetDropAfter=$(ssh ${receiver} ". XDPUtils.sh && calculate_packets_drop ${nicName}")
LogMsg "After test, Packet drop count on ${receiver} is ${packetDropAfter}"
# Calculate packets forwarded before tests
pktForwardAfter=$(ssh ${forwarder} ". XDPUtils.sh && calculate_packets_forward ${nicName}")
LogMsg "After test, Packet forward count on ${forwarder} is ${pktForwardAfter}"

# threshold value check

# Success
SetTestStateCompleted