#!/usr/bin/env bash

########################################################################
#
# Copyright (C) 2015 - 2017 Martin Wimpress <code@ubuntu-mate.org>
# Copyright (C) 2015 Rohith Madhavan <rohithmadhavan@gmail.com>
# Copyright (C) 2015 Ryan Finnie <ryan@finnie.org>
#
# See the included LICENSE file.
# 
########################################################################

set -ex

trap exit_clean 1 2 3 6


exit_clean()
{
  echo "Caught Signal ... cleaning up."
  umount_system
  echo "Done cleanup ... quitting."
  exit 1
}

if [ -f build-settings.sh ]; then
    source build-settings.sh
else
    echo "ERROR! Could not source build-settings.sh."
    exit 1
fi

if [ $(id -u) -ne 0 ]; then
    echo "ERROR! Must be root."
    exit 1
fi

if [ -n "$LOCAL_MIRROR" ]; then
  MIRROR=$LOCAL_MIRROR
else
  MIRROR=http://ports.ubuntu.com/
fi

if [ -n "$LOCAL_ROS_MIRROR" ]; then
  ROS_MIRROR=$LOCAL_ROS_MIRROR
else
  ROS_MIRROR=http://packages.ros.org/ros/ubuntu
fi

# Mount host system
function mount_system() {
    # In case this is a re-run move the cofi preload out of the way
    if [ -e $R/etc/ld.so.preload ]; then
        mv -v $R/etc/ld.so.preload $R/etc/ld.so.preload.disabled
    fi
    mount -t proc none $R/proc
    mount -t sysfs none $R/sys
    mount -o bind /dev $R/dev
    mount -o bind /dev/pts $R/dev/pts
    mount -o bind /dev/shm $R/dev/shm
    echo "nameserver 8.8.8.8" > $R/etc/resolv.conf
}

# Unmount host system
function umount_system() {
    umount -l $R/sys
    umount -l $R/proc
    umount -l $R/dev/pts
    umount -l $R/dev
    echo "" > $R/etc/resolv.conf
}

function sync_to() {
    local TARGET="${1}"
    if [ ! -d "${TARGET}" ]; then
        mkdir -p "${TARGET}"
    fi
    rsync -aHAXx --progress --delete ${R}/ ${TARGET}/
}

# Base debootstrap
function bootstrap() {
    # Use the same base system for all flavours.
    if [ ! -f "${R}/tmp/.bootstrap" ]; then
        if [ "${ARCH}" == "armv7l" ]; then
            debootstrap --verbose $RELEASE $R $MIRROR
        else
            qemu-debootstrap --verbose --arch=armhf $RELEASE $R $MIRROR
        fi
        touch "$R/tmp/.bootstrap"
    fi
}


function generate_locale() {
    for LOCALE in $(chroot $R locale | cut -d'=' -f2 | grep -v : | sed 's/"//g' | uniq); do
        if [ -n "${LOCALE}" ]; then
            # C.UTF-8 is a fixed locale that cannot and does not need to be generated
	    if [ "${LOCALE}" -ne "C.UTF-8"]; then
                chroot $R locale-gen $LOCALE
	    fi
        fi
    done
}

# Set up initial sources.list
function apt_sources() {
    cat <<EOM >$R/etc/apt/sources.list
deb ${MIRROR} ${RELEASE} main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE} main restricted universe multiverse

deb ${MIRROR} ${RELEASE}-updates main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE}-updates main restricted universe multiverse

deb ${MIRROR} ${RELEASE}-security main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE}-security main restricted universe multiverse

deb ${MIRROR} ${RELEASE}-backports main restricted universe multiverse
#deb-src ${MIRROR} ${RELEASE}-backports main restricted universe multiverse
EOM

    cat <<EOM >$R/etc/apt/sources.list.d/ros-latest.list
deb ${ROS_MIRROR} xenial main
EOM
}

function ubiquity_apt() {
    chroot $R apt-key adv --keyserver hkp://keyserver.ubuntu.com --recv-key C3032ED8
    chroot $R apt-get -y install apt-transport-https

    if [ ${UBIQUITY_TESTING_REPO} -eq 1 ]; then
        cat <<EOM >$R/etc/apt/sources.list.d/ubiquity-latest.list
deb https://packages.ubiquityrobotics.com/ubuntu/ubiquity-testing xenial main

deb https://packages.ubiquityrobotics.com/ubuntu/ubiquity-testing xenial pi
EOM
    else
        cat <<EOM >$R/etc/apt/sources.list.d/ubiquity-latest.list
deb https://packages.ubiquityrobotics.com/ubuntu/ubiquity xenial main

deb https://packages.ubiquityrobotics.com/ubuntu/ubiquity xenial pi
EOM
    fi

    chroot $R apt-get update
}

function apt_upgrade() {
    chroot $R apt-get update
    chroot $R apt-get -y -u dist-upgrade
}

function apt_clean() {
    cat <<EOM >$R/etc/apt/sources.list
deb http://ports.ubuntu.com ${RELEASE} main restricted universe multiverse
deb-src http://ports.ubuntu.com  ${RELEASE} main restricted universe multiverse

deb http://ports.ubuntu.com ${RELEASE}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com  ${RELEASE}-updates main restricted universe multiverse

deb http://ports.ubuntu.com ${RELEASE}-security main restricted universe multiverse
deb-src http://ports.ubuntu.com  ${RELEASE}-security main restricted universe multiverse

deb http://ports.ubuntu.com ${RELEASE}-backports main restricted universe multiverse
deb-src http://ports.ubuntu.com ${RELEASE}-backports main restricted universe multiverse
EOM

    cat <<EOM >$R/etc/apt/sources.list.d/ros-latest.list
deb http://packages.ros.org/ros/ubuntu xenial main
EOM
    chroot $R apt-get -y autoremove
    chroot $R apt-get clean
}

# Install Ubuntu minimal
function ubuntu_minimal() {
    if [ ! -f "${R}/tmp/.minimal" ]; then
        chroot $R apt-get -y install ubuntu-minimal parted software-properties-common
        if [ "${FS}" == "f2fs" ]; then
            chroot $R apt-get -y install f2fs-tools
        fi
        touch "${R}/tmp/.minimal"
    fi
}

# Install Ubuntu standard
function ubuntu_standard() {
    if [ ! -f "${R}/tmp/.standard" ]; then
        chroot $R apt-get -y install ubuntu-standard
        touch "${R}/tmp/.standard"
    fi
}

function ros_packages() {
    wget https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -O - | chroot $R apt-key add -

    chroot $R apt-get update
    chroot $R apt-get -y install chrony
    chroot $R apt-get -y install ros-kinetic-desktop ros-kinetic-magni-robot \
    ros-kinetic-magni-bringup ros-kinetic-magni-* ros-kinetic-loki-base-node ros-kinetic-loki-robot  \
    ros-kinetic-loki-* ros-kinetic-tf2-web-republisher ros-kinetic-rosbridge-server \
    ros-kinetic-nav-core ros-kinetic-move-base-msgs ros-kinetic-sick-tim \
    ros-kinetic-ubiquity-motor ros-kinetic-pi-sonar ros-kinetic-robot-upstart \
    ros-kinetic-teleop-twist-keyboard ros-kinetic-camera-calibration nginx
}

# Install meta packages
function install_meta() {
    local META="${1}"
    local RECOMMENDS="${2}"
    if [ "${RECOMMENDS}" == "--no-install-recommends" ]; then
        echo 'APT::Install-Recommends "false";' > $R/etc/apt/apt.conf.d/99noinstallrecommends
    else
        local RECOMMENDS=""
    fi

    cat <<EOM >$R/usr/local/bin/${1}.sh
#!/bin/bash
service dbus start
apt-get -f install
dpkg --configure -a
apt-get -y install ${RECOMMENDS} ${META}^
service dbus stop
EOM
    chmod +x $R/usr/local/bin/${1}.sh
    chroot $R /usr/local/bin/${1}.sh

    rm $R/usr/local/bin/${1}.sh

    if [ "${RECOMMENDS}" == "--no-install-recommends" ]; then
        rm $R/etc/apt/apt.conf.d/99noinstallrecommends
    fi
}

function create_groups() {
    chroot $R groupadd -f --system gpio
    chroot $R groupadd -f --system i2c
    chroot $R groupadd -f --system input
    chroot $R groupadd -f --system spi
    chroot $R groupadd -f --system bluetooth

    # Create adduser hook
    cp files/adduser.local $R/usr/local/sbin/adduser.local
    chmod +x $R/usr/local/sbin/adduser.local
}

# Create default user
function create_user() {
    local DATE=$(date +%m%H%M%S)
    local PASSWD=$(mkpasswd -m sha-512 ${USERNAME} ${DATE})

    chroot $R adduser --gecos "Ubuntu User" --add_extra_groups --disabled-password ${USERNAME}

    chroot $R usermod -a -G sudo -p ${PASSWD} ${USERNAME}
}

function configure_ssh() {
    chroot $R apt-get -y install openssh-server sshguard
    cp files/sshdgenkeys.service $R/lib/systemd/system/
    mkdir -p $R/etc/systemd/system/ssh.service.wants
    chroot $R /bin/systemctl enable sshdgenkeys.service
    # chroot $R /bin/systemctl disable ssh.service
    chroot $R /bin/systemctl disable sshguard.service
}

function configure_network() {
    # Set up hosts
    echo ${IMAGE_HOSTNAME} >$R/etc/hostname
    cat <<EOM >$R/etc/hosts
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       ${IMAGE_HOSTNAME} ${IMAGE_HOSTNAME}.local
EOM

    # Set up interfaces
    cat <<EOM >$R/etc/network/interfaces
# interfaces(5) file used by ifup(8) and ifdown(8)
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

# The loopback network interface
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOM

    # Add entries to DNS in AP mode
    cat <<EOM >$R/etc/NetworkManager/dnsmasq-shared.d/hosts.conf
address=/robot.ubiquityrobotics.com/10.42.0.1
address=/ubiquityrobot/10.42.0.1
EOM

}

function configure_ros() {
    chroot $R apt-get -y install python-rosinstall python-wstool
    chroot $R rosdep init
    # Overlay that has our custom dependencies
    cat <<EOM >$R/etc/ros/rosdep/sources.list.d/30-ubiquity.list
yaml https://raw.githubusercontent.com/UbiquityRobotics/rosdep/master/raspberry-pi.yaml
EOM
    chroot $R chmod a+r /etc/ros/rosdep/sources.list.d/30-ubiquity.list
    
    chroot $R apt-get update

    echo "source /opt/ros/kinetic/setup.bash" >> $R/home/${USERNAME}/.bashrc
    echo "source /opt/ros/kinetic/setup.bash" >> $R/root/.bashrc
    echo "source /opt/ros/kinetic/setup.bash" >> $R/etc/skel/.bashrc
    chroot $R su ubuntu -c "mkdir -p /home/${USERNAME}/catkin_ws/src"

    # It doesn't exsist yet, but we are sourcing it in anyway
    echo "source /home/${USERNAME}/catkin_ws/devel/setup.bash" >> $R/home/${USERNAME}/.bashrc
    chroot $R su ubuntu -c "rosdep update"

    chroot $R su ubuntu -c "cd /home/${USERNAME}/catkin_ws/src; git clone https://github.com/UbiquityRobotics/demos.git"
    chroot $R sh -c "cd /home/${USERNAME}/catkin_ws; HOME=/home/ubuntu rosdep install --from-paths src --ignore-src --rosdistro=kinetic -y"
    
    # Make sure that permissions are still sane
    chroot $R chown -R ubuntu:ubuntu /home/ubuntu
    chroot $R su ubuntu -c "bash -c 'cd /home/${USERNAME}/catkin_ws; source /opt/ros/kinetic/setup.bash; catkin_make;'"

    # Setup ros environment variables in a file
    chroot $R mkdir -p /etc/ubiquity
    cat <<EOM >$R/etc/ubiquity/env.sh
#!/bin/sh
export ROS_HOSTNAME=\$(hostname).local
export ROS_MASTER_URI=http://\$ROS_HOSTNAME:11311
EOM
    chroot $R chmod +x /etc/ubiquity/env.sh
    chroot $R chmod a+r /etc/ubiquity/env.sh

    # Make sure that the ros environment will be sourced for all users
    echo "source /etc/ubiquity/env.sh" >> $R/home/ubuntu/.bashrc
    echo "source /etc/ubiquity/env.sh" >> $R/root/.bashrc
    echo "source /etc/ubiquity/env.sh" >> $R/etc/skel/.bashrc


    echo "export ROS_PARALLEL_JOBS=-j1 \
# Limit the number of compile threads due to memory limits" >> $R/home/ubuntu/.bashrc
    echo "export ROS_PARALLEL_JOBS=-j1 \
# Limit the number of compile threads due to memory limits" >> $R/root/.bashrc
    echo "export ROS_PARALLEL_JOBS=-j1 \
# Limit the number of compile threads due to memory limits" >> $R/etc/skel/.bashrc


    if [ ${ROSCORE_AUTOSTART} -eq 1 ]; then
        cat <<EOM >$R/etc/systemd/system/roscore.service 
[Unit]
After=NetworkManager.service time-sync.target
[Service]
Type=forking
User=ubuntu
# Start roscore as a fork and then wait for the tcp port to be opened
# ----------------------------------------------------------------
# Source all the environment variables, start roscore in a fork
# Since the service type is forking, systemd doesn't mark it as
# 'started' until the original process exits, so we have the 
# non-forked shell wait until it can connect to the tcp opened by
# roscore, and then exit, preventing conflicts with dependant services
ExecStart=/bin/sh -c ". /opt/ros/kinetic/setup.sh; . /etc/ubiquity/env.sh; roscore & while ! echo exit | nc localhost 11311 > /dev/null; do sleep 1; done"
[Install]
WantedBy=multi-user.target
EOM
        chroot $R /bin/systemctl enable roscore.service
    fi
   

    if [ ${MAGNI_AUTOSTART} -eq 1 ]; then
        cp files/magni-base.sh $R/usr/sbin/magni-base
        chroot $R chmod +x /usr/sbin/magni-base

        cat <<EOM >$R/etc/systemd/system/magni-base.service 
[Unit]
Requires=roscore.service
PartOf=roscore.service
After=NetworkManager.service time-sync.target roscore.service
[Service]
Type=simple
User=ubuntu
ExecStart=/usr/sbin/magni-base
[Install]
WantedBy=multi-user.target
EOM
        chroot $R /bin/systemctl enable magni-base.service
    fi

}

function disable_services() {
    # Disable brltty because it spams syslog with SECCOMP errors
    if [ -e $R/sbin/brltty ]; then
        chroot $R /bin/systemctl disable brltty.service
    fi

    # Disable irqbalance because it is of little, if any, benefit on ARM.
    if [ -e $R/etc/init.d/irqbalance ]; then
        chroot $R /bin/systemctl disable irqbalance
    fi

    # Disable TLP because it is redundant on ARM devices.
    if [ -e $R/etc/default/tlp ]; then
        sed -i s'/TLP_ENABLE=1/TLP_ENABLE=0/' $R/etc/default/tlp
        chroot $R /bin/systemctl disable tlp.service
        chroot $R /bin/systemctl disable tlp-sleep.service
    fi

    # Disable apport because these images are not official
    if [ -e $R/etc/default/apport ]; then
        sed -i s'/enabled=1/enabled=0/' $R/etc/default/apport
        chroot $R /bin/systemctl disable apport.service
        chroot $R /bin/systemctl disable apport-forward.socket
    fi

    # Disable whoopsie because these images are not official
    if [ -e $R/usr/bin/whoopsie ]; then
        chroot $R /bin/systemctl disable whoopsie.service
    fi

    # Disable mate-optimus
    if [ -e $R/usr/share/mate/autostart/mate-optimus.desktop ]; then
        rm -f $R/usr/share/mate/autostart/mate-optimus.desktop || true
    fi

    # Disable unttended upgrades
    # When plugging in a fresh image to the internet, unattended
    # upgrades locks up the system trying to update
    cat <<EOM >$R/etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0"; 

EOM
    cat <<EOM >$R/etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOM

}

function configure_hardware() {
    local FS="${1}"
    if [ "${FS}" != "ext4" ] && [ "${FS}" != 'f2fs' ]; then
        echo "ERROR! Unsupport filesystem requested. Exitting."
        exit 1
    fi

    # Install the RPi PPA
    chroot $R apt-add-repository -y ppa:ubuntu-pi-flavour-makers/ppa
    chroot $R apt-get update

    # Firmware Kernel installation
    chroot $R apt-get -y install libraspberrypi-bin libraspberrypi-dev \
    libraspberrypi-doc libraspberrypi0 raspberrypi-bootloader rpi-update \
    bluez-firmware linux-firmware pi-bluetooth

    # Raspberry Pi 3 WiFi firmware. Supplements what is provided in linux-firmware
    cp -v firmware/* $R/lib/firmware/brcm/
    chown root:root $R/lib/firmware/brcm/*

    # pi-top poweroff and brightness utilities
    cp -v files/pi-top-* $R/usr/bin/
    chown root:root $R/usr/bin/pi-top-*
    chmod +x $R/usr/bin/pi-top-*

    if [ "${GUI}" -eq 1 ]; then
        # Install fbturbo drivers on non composited desktop OS
        # fbturbo causes VC4 to fail
        if [ "${GUI}" -eq 1]; then
            chroot $R apt-get -y install xserver-xorg-video-fbturbo
        fi

        # omxplayer
        # - Requires: libpcre3 libfreetype6 fonts-freefont-ttf dbus libssl1.0.0 libsmbclient libssh-4
        cp deb/omxplayer_0.3.7-git20160923-dfea8c9_armhf.deb $R/tmp/omxplayer.deb
        chroot $R apt-get -y install /tmp/omxplayer.deb
    fi

    # Install Raspberry Pi system tweaks
    chroot $R apt-get -y install fbset raspberrypi-sys-mods

    # Enable hardware random number generator
    chroot $R apt-get -y install rng-tools

    # copies-and-fills
    # Create /spindel_install so cofi doesn't segfault when chrooted via qemu-user-static
    touch $R/spindle_install
    cp deb/raspi-copies-and-fills_0.5-1_armhf.deb $R/tmp/cofi.deb
    chroot $R apt-get -y install /tmp/cofi.deb

    # Add /root partition resize
    if [ "${FS}" == "ext4" ]; then
        CMDLINE_INIT="init=/usr/lib/raspi-config/init_resize.sh"
        # Add the first boot filesystem resize, init_resize.sh is
        # shipped in raspi-config.
        cp files/resize2fs_once	$R/etc/init.d/
        chroot $R /bin/systemctl enable resize2fs_once        
    else
        CMDLINE_INIT=""
    fi
    chroot $R apt-get -y install raspi-config

    # Add /boot/config.txt
    cp files/config.txt $R/boot/

    cp device-tree/ubiquity-led-buttons.dtbo $R/boot/overlays
    chown root:root $R/boot/overlays/ubiquity-led-buttons.dtbo

    cat <<EOM >$R/etc/systemd/system/hwclock-sync.service 
[Unit] 
Description=Time Synchronisation from RTC Source 
After=systemd-modules-load.service 
RequiresMountsFor=/dev/rtc 
Conflicts=shutdown.target 
[Service] 
Type=oneshot 
ExecStart=/sbin/hwclock -s 
TimeoutSec=0 
[Install] 
WantedBy=time-sync.target 
EOM

    chroot $R /bin/systemctl enable hwclock-sync.service

    # Add /boot/cmdline.txt
    echo "dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootfstype=${FS} elevator=deadline fsck.repair=yes rootwait quiet splash plymouth.ignore-serial-consoles ${CMDLINE_INIT}" > $R/boot/cmdline.txt

    # Set up fstab
    cat <<EOM >$R/etc/fstab
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               ${FS}   defaults,noatime  0       1
/dev/mmcblk0p1  /boot/          vfat    defaults          0       2
EOM
}

function install_software() {

    # Raspicam needs to be after configure_hardware
    chroot $R apt-get -y install ros-kinetic-raspicam-node
    chroot $R apt-get -y install pifi

    mkdir -p $R/etc/pifi
    cp files/default_ap.em $R/etc/pifi/default_ap.em
    cp files/pifi.conf $R/etc/pifi/pifi.conf

    mkdir -p $R/etc/ubiquity
    cp files/robot.yaml $R/etc/ubiquity/robot.yaml

    chroot $R apt-get -y install usbmount
    cp files/usbmount.conf $R/etc/usbmount/usbmount.conf

    # Solves issue where SSH takes forever to start
    # https://forum.ubiquityrobotics.com/t/ros-image-on-raspberry-pi-4/326/59
    sed -i s'/TimeoutStartSec=5min/TimeoutStartSec=10sec/' $R/lib/systemd/system/networking.service

    # FIXME - Replace with meta packages(s)

    # Install some useful utils
    chroot $R apt-get -y install \
    vim nano emacs htop screen

    # Python
    chroot $R apt-get -y install \
    python-minimal python3-minimal \
    python-dev python3-dev \
    python-pip python3-pip \
    python-setuptools python3-setuptools

    # Python extras a Raspberry Pi hacker expects to be available ;-)
    chroot $R apt-get -y install \
    raspi-gpio \
    python-rpi.gpio python3-rpi.gpio \
    python-gpiozero python3-gpiozero \
    pigpio python-pigpio python3-pigpio \
    python-serial python3-serial \
    python-spidev python3-spidev \
    python-smbus python3-smbus \
    python-astropi python3-astropi \
    python-drumhat python3-drumhat \
    python-envirophat python3-envirophat \
    python-pianohat python3-pianohat \
    python-pantilthat python3-pantilthat \
    python-scrollphat python3-scrollphat \
    python-st7036 python3-st7036 \
    python-sn3218 python3-sn3218 \
    python-piglow python3-piglow \
    python-microdotphat python3-microdotphat \
    python-mote python3-mote \
    python-motephat python3-motephat \
    python-explorerhat python3-explorerhat \
    python-rainbowhat python3-rainbowhat \
    python-sense-hat python3-sense-hat \
    python-sense-emu python3-sense-emu sense-emu-tools \
    python-picamera python3-picamera \
    python-rtimulib python3-rtimulib \
    python-pygame

    chroot $R pip2 install codebug_tether
    chroot $R pip3 install codebug_tether
}

function branding() {
    # Set Desktop and Lockscreen Background
    cp branding/magni_wallpaper.png $R/usr/local/share/magni_wallpaper.png
    
    local pcman_conf=$R/etc/xdg/pcmanfm/lubuntu/pcmanfm.conf
    sed -i s'/wallpaper_mode=center/wallpaper_mode=screen/' $pcman_conf
    sed -i s',wallpaper0=.*,wallpaper0=/usr/local/share/magni_wallpaper.png,' $pcman_conf
    sed -i s',wallpaper=.*,wallpaper=/usr/local/share/magni_wallpaper.png,' $pcman_conf
    local pcman2_conf=$R/etc/xdg/pcmanfm/lubuntu/desktop-items-0.conf
    sed -i s'/wallpaper_mode=center/wallpaper_mode=screen/' $pcman2_conf
    sed -i s',wallpaper0=.*,wallpaper0=/usr/local/share/magni_wallpaper.png,' $pcman2_conf
    sed -i s',wallpaper=.*,wallpaper=/usr/local/share/magni_wallpaper.png,' $pcman2_conf
    
    sed -i s',bg=.*,bg=/usr/local/share/magni_wallpaper.png,' $R/etc/xdg//lubuntu/lxdm/lxdm.conf
    sed -i s',background=.*,background=/usr/local/share/magni_wallpaper.png,' $R/etc/lightdm/lightdm-gtk-greeter.conf.d/30_lubuntu.conf

    # Set plymouth splash
    cp -r branding/ubiquity-plymouth $R/usr/share/plymouth/themes/ubiquity-logo
    chroot $R ln -sf /usr/share/plymouth/themes/ubiquity-logo/ubiquity-logo.plymouth /etc/alternatives/default.plymouth

    # Message of the Day Customization
    chmod -x $R/etc/update-motd.d/10-help-text
    chmod -x $R/etc/update-motd.d/91-release-upgrade

    cat <<EOM >$R/etc/update-motd.d/50-ubiquity
#!/bin/sh

echo ""
echo "Welcome to the Ubiquity Robotics Raspberry Pi Image"
echo "Learn more: https://learn.ubiquityrobotics.com"
echo "Like our image? Support us on PayPal: tips@ubiquityrobotics.com"
echo ""
echo "Wifi can be managed with pifi (pifi --help for more info)"
EOM
    chmod +x $R/etc/update-motd.d/50-ubiquity
}

function clean_up() {
    rm -f $R/etc/apt/*.save || true
    rm -f $R/etc/apt/sources.list.d/*.save || true
    rm -f $R/etc/resolvconf/resolv.conf.d/original
    rm -f $R/run/*/*pid || true
    rm -f $R/run/*pid || true
    rm -f $R/run/cups/cups.sock || true
    rm -f $R/run/uuidd/request || true
    rm -f $R/etc/*-
    rm -rf $R/tmp/*
    rm -f $R/var/crash/*
    rm -f $R/var/lib/urandom/random-seed

    # Build cruft
    rm -f $R/var/cache/debconf/*-old || true
    rm -f $R/var/lib/dpkg/*-old || true
    rm -f $R/var/cache/bootstrap.log || true
    truncate -s 0 $R/var/log/lastlog || true
    truncate -s 0 $R/var/log/faillog || true

    # SSH host keys
    rm -f $R/etc/ssh/ssh_host_*key
    rm -f $R/etc/ssh/ssh_host_*.pub

    # Clean up old Raspberry Pi firmware and modules
    rm -f $R/boot/.firmware_revision || true
    rm -rf $R/boot.bak || true
    rm -rf $R/lib/modules.bak || true

    # Potentially sensitive.
    rm -f $R/root/.bash_history
    rm -f $R/root/.ssh/known_hosts

    # Remove bogus home directory
    # if [ -d $R/home/${SUDO_USER} ]; then
    #     rm -rf $R/home/${SUDO_USER} || true
    # fi

    # Machine-specific, so remove in case this system is going to be
    # cloned.  These will be regenerated on the first boot.
    rm -f $R/etc/udev/rules.d/70-persistent-cd.rules
    rm -f $R/etc/udev/rules.d/70-persistent-net.rules
    rm -f $R/etc/NetworkManager/system-connections/*
    [ -L $R/var/lib/dbus/machine-id ] || rm -f $R/var/lib/dbus/machine-id
    echo '' > $R/etc/machine-id

    # Enable cofi
    if [ -e $R/etc/ld.so.preload.disabled ]; then
        mv -v $R/etc/ld.so.preload.disabled $R/etc/ld.so.preload
    fi

    rm -rf $R/tmp/.bootstrap || true
    rm -rf $R/tmp/.minimal || true
    rm -rf $R/tmp/.standard || true
    rm -rf $R/spindle_install || true
}

function make_raspi2_image() {
    # Build the image file
    local FS="${1}"
    local SIZE_IMG="${2}"
    local SIZE_BOOT="64MiB"

    if [ "${FS}" != "ext4" ] && [ "${FS}" != 'f2fs' ]; then
        echo "ERROR! Unsupport filesystem requested. Exitting."
        exit 1
    fi

    # Remove old images.
    rm -f "${IMAGEDIR}/${IMAGE}" || true

    # Create an empty file file.
    dd if=/dev/zero of="${IMAGEDIR}/${IMAGE}" bs=1MB count=1
    dd if=/dev/zero of="${IMAGEDIR}/${IMAGE}" bs=1MB count=0 seek=$(( ${SIZE_IMG} * 1000 ))

    # Initialising: msdos
    parted -s ${IMAGEDIR}/${IMAGE} mktable msdos
    echo "Creating /boot partition"
    parted -a optimal -s ${IMAGEDIR}/${IMAGE} mkpart primary fat32 1 "${SIZE_BOOT}"
    echo "Creating /root partition"
    parted -a optimal -s ${IMAGEDIR}/${IMAGE} mkpart primary ext4 "${SIZE_BOOT}" 100%

    PARTED_OUT=$(parted -s ${IMAGEDIR}/${IMAGE} unit b print)
    BOOT_OFFSET=$(echo "${PARTED_OUT}" | grep -e '^ 1'| xargs echo -n \
    | cut -d" " -f 2 | tr -d B)
    BOOT_LENGTH=$(echo "${PARTED_OUT}" | grep -e '^ 1'| xargs echo -n \
    | cut -d" " -f 4 | tr -d B)

    ROOT_OFFSET=$(echo "${PARTED_OUT}" | grep -e '^ 2'| xargs echo -n \
    | cut -d" " -f 2 | tr -d B)
    ROOT_LENGTH=$(echo "${PARTED_OUT}" | grep -e '^ 2'| xargs echo -n \
    | cut -d" " -f 4 | tr -d B)

    IMG_LOOP=$(losetup --show -f -P ${IMAGEDIR}/${IMAGE})
    BOOT_LOOP=${IMG_LOOP}p1
    ROOT_LOOP=${IMG_LOOP}p2
    echo "/boot: offset ${BOOT_OFFSET}, length ${BOOT_LENGTH}"
    echo "/:     offset ${ROOT_OFFSET}, length ${ROOT_LENGTH}"

    mkfs.vfat -n PI_BOOT -S 512 -s 16 -v "${BOOT_LOOP}"
    if [ "${FS}" == "ext4" ]; then
        mkfs.ext4 -L PI_ROOT -m 0 -O ^huge_file "${ROOT_LOOP}"
    else
        mkfs.f2fs -l PI_ROOT -o 1 "${ROOT_LOOP}"
    fi

    MOUNTDIR="${BUILDDIR}/mount"
    mkdir -p "${MOUNTDIR}"
    mount -v "${ROOT_LOOP}" "${MOUNTDIR}" -t "${FS}"
    mkdir -p "${MOUNTDIR}/boot"
    mount -v "${BOOT_LOOP}" "${MOUNTDIR}/boot" -t vfat
    rsync -aHAXx "$R/" "${MOUNTDIR}/"
    sync
    umount -l "${MOUNTDIR}/boot"
    umount -l "${MOUNTDIR}"
    losetup -d "${IMG_LOOP}"

    chmod a+r ${IMAGEDIR}/${IMAGE}
}

function write_image_name() {
    cat <<EOM >./latest_image
${IMAGEDIR}/${IMAGE}
EOM
    chmod a+r ./latest_image
}

function make_hash() {
    local FILE="${1}"
    local HASH="sha256"
    if [ ! -f ${FILE}.${HASH}.sign ]; then
        if [ -f ${FILE} ]; then
            ${HASH}sum ${FILE} > ${FILE}.${HASH}
            sed -i -r "s/ .*\/(.+)/  \1/g" ${FILE}.${HASH}
        else
            echo "WARNING! Didn't find ${FILE} to hash."
        fi
    else
        echo "Existing signature found, skipping..."
    fi
}

function make_tarball() {
    if [ ${MAKE_TARBALL} -eq 1 ]; then
        rm -f "${IMAGEDIR}/${TARBALL}" || true
        tar -cSf "${IMAGEDIR}/${TARBALL}" $R
        make_hash "${IMAGEDIR}/${TARBALL}"
    fi
}

function compress_image() {
    mkdir -p ${IMAGEDIR}
    echo "Compressing to: ${IMAGEDIR}/${IMAGE}.xz"
    xz -4 ${IMAGEDIR}/${IMAGE}
}

function stage_01_base() {
    R="${BASE_R}"
    bootstrap
    mount_system
    generate_locale
    apt_sources
    apt_upgrade
    ubiquity_apt
    ubuntu_minimal
    ubuntu_standard
    ros_packages
    apt_clean
    umount_system
#    sync_to "${DESKTOP_R}"
}

function stage_02_desktop() {
    R="${BASE_R}"
    mount_system
    apt_sources
    chroot $R apt-get update

    if [ "${GUI}" -eq 1 ]; then
        install_meta lubuntu-core --no-install-recommends
        install_meta lubuntu-desktop --no-install-recommends
    else
        echo "Skipping desktop install for ${FLAVOUR}"
    fi

    create_groups
    create_user
    configure_ssh
    configure_network
    configure_ros
    disable_services
    apt_upgrade
    apt_clean
    umount_system
    clean_up
#    sync_to ${BASE_R}
    make_tarball
}

function stage_03_raspi2() {
    R=${BASE_R}
    mount_system
    apt_sources
    chroot $R apt-get update
    configure_hardware ${FS_TYPE}
    install_software
    apt_upgrade
    apt_clean
    clean_up
    umount_system
#    make_raspi2_image ${FS_TYPE} ${FS_SIZE}
}

function stage_04_corrections() {
    R=${BASE_R}
    mount_system
    apt_sources

    if [ "${RELEASE}" == "xenial" ]; then
      # Upgrade Xorg using HWE.
      chroot $R apt-get install -y --install-recommends \
      xserver-xorg-core-hwe-16.04 \
      xserver-xorg-input-all-hwe-16.04 \
      xserver-xorg-input-evdev-hwe-16.04 \
      xserver-xorg-input-synaptics-hwe-16.04 \
      xserver-xorg-input-wacom-hwe-16.04 \
      xserver-xorg-video-all-hwe-16.04 \
      xserver-xorg-video-fbdev-hwe-16.04 \
      xserver-xorg-video-vesa-hwe-16.04
    fi

    # Insert other corrections here.

# Disable cups trying to load modules that don't exist
    cat <<EOM >$R/etc/modules-load.d/cups-filters.conf
# Parallel printer driver modules loading for cups
# LOAD_LP_MODULE was 'yes' in /etc/default/cups
#lp
#ppdev
#parport_pc 
EOM

    chroot $R apt-get -y purge firefox
    cp deb/firefox_52.0.2+build1-0ubuntu0.16.04.1_armhf.deb $R/tmp/firefox.deb
    chroot $R apt-get -y --allow-downgrades install /tmp/firefox.deb
    rm $R/tmp/firefox.deb
    chroot $R apt-mark hold firefox

    chmod a+r -R $R/etc/apt/sources.list.d/

    chroot $R apt-get -y install chrony
    chroot $R apt-get -y install ros-kinetic-magni-demos ros-kinetic-magni-bringup ros-kinetic-magni-*

    # Do all the branding things
    branding
    
    apt_clean
    clean_up
    umount_system
    make_raspi2_image ${FS_TYPE} ${FS_SIZE}
}

stage_01_base
stage_02_desktop
stage_03_raspi2
stage_04_corrections
write_image_name
compress_image
