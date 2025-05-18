#!/bin/bash

#set -o pipefail
#set -e
set -x

piSerials=("00280603" "388b1880" "ad56bebd") # replace with the serials from your PIs
piFirmwareVersion="1.41"
talosVersion="1.10.2" # use or replace
talosClusterName="pinetes" # replace
talosClusterIp="192.168.178.230" # replace

# everything below can be left as is or updated to meet your needs.

tftpRoot="/tftp"
tftpBaseline="$tftpRoot/baseline"
tftpCmdlines="$tftpRoot/cmdlines"
tftpIp=$(hostname -I | grep -Eo '([0-9]*\.){3}[0-9]*' | xargs | awk '{print $1}') # trouble if ipv6 is active, so only get IPv4, see: https://danielchg.github.io/posts/dnsmasq-for-dualstack/
apacheRoot="/var/www/html"
talosBaselineDir="${apacheRoot}/talosBaseline"

# upgrade everything
apt update && apt upgrade -y

# install required apps
apt install dnsmasq apache2 git unzip -y

# determine number of controlplanes and workers
numberOfNodes=${#piSerials[@]}
numberOfControlPlanes=1
untaintControlPlanes=false # used later to allow scheduling on the controlplanes for small clusters
if [[ $numberOfNodes -gt 3 ]]
then
    ((numberOfControlPlanes=3))
else
    ((untaintControlPlanes=true))
fi
let z=numberOfControlPlanes-1 #zero based array

# ---- TFTP BOOT BEGIN ----

# configure dnsmasq

systemctl stop dnsmasq.service
rm /etc/dnsmasq.conf

cat <<EOT >> /etc/dnsmasq.conf
interface=eth0
no-hosts
dhcp-range=$tftpIp,proxy
dhcp-option=3,192.168.178.1
dhcp-option=6,192.168.178.42
dhcp-option=43,"Raspberry Pi Boot"
log-dhcp
log-queries
tftp-no-fail
tftp-no-blocksize
enable-tftp
tftp-root=$tftpRoot
pxe-service=0,"Raspberry Pi Boot"
EOT

#tftp-no-fail
#tftp-no-blocksize


# configure tftp boot dir
rm -rf $tftpRoot

mkdir -p $tftpRoot
chmod 777 $tftpRoot
mkdir $tftpBaseline

# maybe use this? https://github.com/raspberrypi/firmware/tree/master/boot 

# create boot baseline
wget -O $tftpBaseline/RPi4_UEFI-Firmware.zip https://github.com/pftf/RPi4/releases/download/v$piFirmwareVersion/RPi4_UEFI_Firmware_v$piFirmwareVersion.zip
unzip $tftpBaseline/RPi4_UEFI-Firmware.zip -d $tftpBaseline
rm $tftpBaseline/RPi4_UEFI-Firmware.zip
rm $tftpBaseline/RPI_EFI.fd
rm $tftpBaseline/config.txt

wget -O $tftpBaseline/initramfs-arm64.xz https://github.com/talos-systems/talos/releases/download/v$talosVersion/initramfs-arm64.xz
wget -O $tftpBaseline/vmlinuz-arm64 https://github.com/talos-systems/talos/releases/download/v$talosVersion/vmlinuz-arm64

# configure the pi boot to use the Talos kernel and initrd boot
cat <<EOT >> $tftpBaseline/config.txt
#arm_64bit=1
# Some Raspberry Pi devices have a second switch-mode power supply for the SoC voltage rail. When enabled, increases the default turbo-mode clock>#arm_boost=1
# enable_uart=1 (in conjunction with console=serial0,115200 in cmdline.txt) requests that the kernel creates a serial console, accessible using G>#enable_uart=0
# device_tree_address=0x1f0000
# device_tree_end=0x200000
# armstub=RPI_EFI.fd
# The dtoverlay option requests the firmware to load a named Device Tree overlay - a configuration file that can enable kernel support for built-># As a special case, if called with no value - dtoverlay= - the option marks the end of a list of overlay parameters. If used before any other dt>#dtoverlay=disable-bt
#dtoverlay=disable-wifi
kernel=vmlinuz-arm64
initramfs initramfs-arm64.xz followkernel
arm_64bit=1
arm_boost=1
enable_uart=1
uart_2ndstage=1
enable_gic=1
armstub=RPI_EFI.fd
#disable_commandline_tags=1
#disable_overscan=1
device_tree_address=0x1f0000
device_tree_end=0x200000
dtoverlay=miniuart-bt
dtoverlay=upstream-pi4
EOT

# symlink a directory for each pi to the baseline
rm -rf $tftpCmdlines
mkdir $tftpCmdlines

for i in ${!piSerials[@]}; do
 
    rm -rf $tftpRoot/${piSerials[$i]}
    mkdir $tftpRoot/${piSerials[$i]}
    cp -r $tftpBaseline/* $tftpRoot/${piSerials[$i]}
    cp serials/${piSerials[$i]}/RPI_EFI.fd $tftpRoot/${piSerials[$i]}/RPI_EFI.fd

    configName='worker.yaml'
    if [[ $i -le $z ]]
    then
        configName='controlplane.yaml'
    fi

# create the talos node specific cmdline.txt (i.e. kernel params)
cat <<EOT >> $tftpCmdlines/${piSerials[$i]}.txt
talos.config=http://$tftpIp/${piSerials[$i]}/$configName talos.platform=metal talos.board=rpi_4 panic=0 console=serial0,115200 init_on_alloc=1 init_on_free=1 slab_nomerge pti=on
EOT

    ln -s $tftpCmdlines/${piSerials[$i]}.txt $tftpRoot/${piSerials[$i]}/cmdline.txt

done

# ---- TFTP BOOT END ----

# ---- TALOS WEB BEGIN ----

# TODO config Apache to only respond to the PI's CIDR

rm /var/www/html/index.html

# install TalosCtl
rm /usr/local/bin/talosctl

curl -Lo /usr/local/bin/talosctl https://github.com/talos-systems/talos/releases/download/v$talosVersion/talosctl-linux-arm64
chmod +x /usr/local/bin/talosctl

# generate configs
rm -rf $talosBaselineDir

mkdir $talosBaselineDir
talosctl gen config $talosClusterName "https://${talosClusterIp}:6443" --output-dir $talosBaselineDir

talosConfigFiles=("${talosBaselineDir}/controlplane.yaml" "${talosBaselineDir}/worker.yaml")

for i in ${talosConfigFiles[@]}; do
    sed -i 's|/dev/sda|/dev/mmcblk0|g' $i
    sed -i 's|# sysctls:|sysctls:|g' $i
    sed -i 's|#     net.ipv4.ip_forward: "0"|    net.ipv4.ip_forward: "1"|g' $i

    sed -i 's|network: {}|network:|g' $i
    sed -i 's|# interfaces:|  interfaces:|g' $i
    sed -i 's|#     - interface: eth0|    - interface: eth0|g' $i
    sed -i 's|#       # dhcp: true|      dhcp: true|g' $i
    if [[ $i == "${talosBaselineDir}/controlplane.yaml" ]]
    then
        #controlplane so let's add the VIP
        sed -i 's|#       # vip:|      vip:|g' $i
        sed -i "s|#       #     ip: 172.16.199.55|          ip: $talosClusterIp|g" $i
    fi
done

# now loop through all the PIs and create a directory for each in apache
for i in ${!piSerials[@]}; do
    newDir="${apacheRoot}/${piSerials[$i]}"

    rm -rf $newDir
    mkdir $newDir    

    if [[ $i -le $z ]]
    then
        #controlplane node
        ln -s "${talosBaselineDir}/controlplane.yaml" "${newDir}/controlplane.yaml"
    else
        #worker node
        ln -s "${talosBaselineDir}/worker.yaml" "${newDir}/worker.yaml"
    fi
done

# ---- TALOS WEB END ----

# enable and start dnsmasq
sudo systemctl enable dnsmasq.service
sudo systemctl restart dnsmasq.service