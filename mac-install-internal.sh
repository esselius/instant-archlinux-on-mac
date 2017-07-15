#!/bin/bash

set -x

#==============================================================================
#==============================================================================
#         Copyright (c) 2015-2016 Jonathan Yantis
#               yantis@yantis.net
#          Released under the MIT license
#==============================================================================
#==============================================================================

###############################################################################
# Exit on any error whatsoever
# since we don't actually modify the physical drive until the very end
###############################################################################
set -e -u -o pipefail

###############################################################################
# Get the model of this Mac/Macbook
###############################################################################
MODEL=$(grep "Model Identifier" /systeminfo | awk '{print $3}')
echo ""
echo "Mac Model: $MODEL"

###############################################################################
# Get the initial configuration file. Moved from inside the docker container
# To a URL so the user can change it to thier liking.
###############################################################################
wget -O /root/initial_configuration.sh \
  https://raw.githubusercontent.com/yantis/instant-archlinux-on-mac/master/initial_configuration.sh

###############################################################################
# A lot of this complexity is because of the error:
# mount: unknown filesystem type 'devtmpfs'
# Which only happens in docker container but not in a virtual machine.
# It would have been very nice to simply use pacstrap =(
###############################################################################
mkdir /arch
unsquashfs -d /squashfs-root /root/airootfs.sfs
ls /squashfs-root

# ls /root
# mount -o loop /squashfs-root/airootfs.img /arch
# mount -o loop -t squash/squashfs-root /arch
# mv /squashfs-root /arch
mount --bind /squashfs-root /arch
mount --bind /dev /arch/dev
ls /arch/boot
chroot /arch ls /boot
chroot /arch mount -t proc none /proc
chroot /arch mount -t sysfs none /sys
chroot /arch mount -t devpts none /dev/pts

# bind /proc /arch/proc
# mount -o bind /sys /arch/sys
# mount -o bind /dev /arch/dev

# mount -t proc none /arch/proc
# mount -t sysfs none /arch/sys
# mount -o bind /dev /arch/dev

# Important for pacman (for signature check)
# (Doesn't seem to matter at all they are still messed up.)
# mount -o bind /dev/pts /arch/dev/pts

###############################################################################
# Use Google's nameservers though I believe we may be able to simply copy the
# /etc/resolv.conf over since Docker magages that and it "should" be accurate.
###############################################################################
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "nameserver 8.8.8.4" >> /etc/resolv.conf
cp /etc/resolv.conf /arch/etc/resolv.conf

# chroot /arch export HOME=/dev/root
# chroot /arch export LC_ALL=C
###############################################################################
# Generate entropy
###############################################################################
chroot /arch haveged

###############################################################################
# Init pacman
###############################################################################
# Fix for failed: IPC connect call failed

echo "*** Checking network ***"
chroot /arch ping -c2  8.8.8.8

echo "*** Launching dirmngr ***"
chroot /arch bash -c "dirmngr </dev/null > /dev/null 2>&1"

echo "*** pacman-key Init ***"
if ! chroot /arch pacman-key --init; then
 echo "pacman-key init failure. Trying to continue anyway"
fi

echo "*** pacman-key populate ***"
if ! chroot /arch pacman-key --populate; then
  echo "pacman-key init failure. Trying to continue anyway"
fi

###############################################################################
# Temp bypass sigchecks because of 
# GPGME error: Inapproropriate ioctrl for device
# It has something to do with the /dev/pts in a chroot but I didn't have any 
# luck solving it.
# https://bbs.archlinux.org/viewtopic.php?id=130538
###############################################################################
sed -i "s/\[core\]/\[core\]\nSigLevel = Never/" /arch/etc/pacman.conf
sed -i "s/\[extra\]/\[extra\]\nSigLevel = Never/" /arch/etc/pacman.conf
sed -i "s/\[community\]/\[community\]\nSigLevel = Never/" /arch/etc/pacman.conf

###############################################################################
# Enable multilib repo
###############################################################################
sed -i '/#\[multilib\]/,/#Include = \/etc\/pacman.d\/mirrorlist/ s/#//' /arch/etc/pacman.conf
sed -i '/#\[multilib\]/,/#Include = \/etc\/pacman.d\/mirrorlist/ s/#//' /arch/etc/pacman.conf
sed -i 's/#\[multilib\]/\[multilib\]/g' /arch/etc/pacman.conf

###############################################################################
# Allow for colored output in pacman.conf
###############################################################################
sed -i "s/#Color/Color/" /arch/etc/pacman.conf

###############################################################################
# For now only uses mirrors.kernel.org as that is the most trusted mirror.
# So we do not run into a malicious mirror. 
# Will run reflector towards the end of the script.
###############################################################################
echo "Server = http://mirrors.kernel.org/archlinux/\$repo/os/\$arch" > /arch/etc/pacman.d/mirrorlist

###############################################################################
# Copy over general & custom cached packages
# Moved the packages to the docker container as I know the docker container 
# downloads trusted packages and it should be being build by a third party
# (docker hub) plus it avoids hammering the mirrors while working on this. 
# Plus it makes the install extremely fast.
###############################################################################

mkdir -p /arch/var/cache/pacman/custom/
cp /var/cache/pacman/custom/* /arch/var/cache/pacman/custom/

###############################################################################
echo "** Syncing pacman database & Update **"
###############################################################################
chroot /arch pacman -Syyu --noconfirm

###############################################################################
# update after pushing packages from docker container to get the system 
# in the most up to date state.
###############################################################################

echo "** Updating System **"
chroot /arch pacman -Syyu --noconfirm

###############################################################################
# Setup our initial_configuration service
###############################################################################
cp /root/initial_configuration.sh /arch/usr/lib/systemd/scripts/
cat >/arch/usr/lib/systemd/system/initial_configuration.service <<EOL
[Unit]
Description=One time Initialization

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/lib/systemd/scripts/initial_configuration.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOL

chmod +x /arch/usr/lib/systemd/scripts/initial_configuration.sh
chroot /arch systemctl enable initial_configuration.service

###############################################################################
# Increase the fontsize of the console. 
# On the new April 2015 12" Macbook I can not even read it.
###############################################################################
echo "FONT=ter-132n" >> /arch/etc/vconsole.conf


if [ "$MODEL" == "MacBook8,1" ]; then
  ###############################################################################
  # Experimental
  ###############################################################################
  sed -i "s/MODULES=\"\"/MODULES=\"ahci sd_mod libahci\"/" /arch/etc/mkinitcpio.conf

else
  ###############################################################################
  # ahci and sd_mod per this post: https://wiki.archlinux.org/index.php/MacBook
  sed -i "s/MODULES=\"\"/MODULES=\"ahci sd_mod\"/" /arch/etc/mkinitcpio.conf
  ###############################################################################
fi

###############################################################################
# Fix root device not showing up.
# http://superuser.com/questions/769047/unable-to-find-root-device-on-a-fresh-archlinux-install
###############################################################################
# HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
# HOOKS="base udev fsck block autodetect modconf filesystems keyboard"
OLDLINE=`grep "^HOOKS" /arch/etc/mkinitcpio.conf`
NEWLINE=`echo ${OLDLINE} | sed -e "s/autodetect block/block autodetect/"`
sed -i "s/${OLDLINE}/${NEWLINE}/" /arch/etc/mkinitcpio.conf

# Fix macbook 12.1 not booting and possibly others
OLDLINE=`grep "^HOOKS" /arch/etc/mkinitcpio.conf`
NEWLINE=`echo ${OLDLINE} | sed -e "s/base udev autodetect modconf block filesystems keyboard fsck/base udev fsck block autodetect modconf filesystems keyboard/"`
sed -i "s/${OLDLINE}/${NEWLINE}/" /arch/etc/mkinitcpio.conf

###############################################################################
# Install the fan daemon
# TODO: The new macbook April 2015 is fanless so this might not work on that. Need to check.
###############################################################################
chroot /arch pacman --noconfirm --needed -U /var/cache/pacman/custom/mbpfan*.pkg.tar.xz

###############################################################################
# Powersaving 
# http://loicpefferkorn.net/2015/01/arch-linux-on-macbook-pro-retina-2014-with-dm-crypt-lvm-and-suspend-to-disk/
###############################################################################
echo "options snd_hda_intel power_save=1" >> /arch/etc/modprobe.d/snd_hda_intel.conf
echo "options usbcore autosuspend=1" >> /arch/etc/modprobe.d/usbcore.conf

###############################################################################
# Broadcom network drivers
###############################################################################
if grep -i -A1 "Broadcom" /systeminfo | grep -qi "MAC" ; then
  echo "Machine has an Broadcom network card."

  chroot /arch pacman --noconfirm --needed -U /var/cache/pacman/custom/broadcom-wl-dkms*.pkg.tar.xz

  # Install the Broadcom b43 firmware just in case the user needs it.
  # https://wiki.archlinux.org/index.php/Broadcom_wireless
  cp -R /firmware/* /arch/lib/firmware/
fi

###############################################################################
# Fix IRQ issues.
# https://wiki.archlinux.org/index.php/MacBook#Sound
###############################################################################
echo "options snd_hda_intel model=intel-mac-auto"  >> /arch/etc/modprobe.d/snd_hda_intel.conf

###############################################################################
# Generate locale (change this to yours if it is not US English)
###############################################################################
chroot /arch locale-gen en_US.UTF-8

# Create new account that isn't root. user: user password: user
# You can and should change this later https://wiki.archlinux.org/index.php/Change_username
# Or just delete it and create another.
###############################################################################
chroot /arch useradd -m -g users -G wheel -s /bin/zsh user
chroot /arch bash -c "echo "user:user" | chpasswd"

# allow passwordless sudo for our user
echo "user ALL=(ALL) NOPASSWD: ALL" >> /arch/etc/sudoers

###############################################################################
# Give it a host name 
###############################################################################
echo macbook > /arch/etc/hostname

###############################################################################
# Enable kernel modules for fan speed and the temperature sensors
###############################################################################
echo coretemp >> /arch/etc/modules
echo applesmc >> /arch/etc/modules

###############################################################################
# Enable Thermald 
###############################################################################
chroot /arch pacman --noconfirm --needed -S thermald
chroot /arch systemctl enable thermald

###############################################################################
# Enable cpupower and set governer to powersave
###############################################################################
chroot /arch pacman --noconfirm --needed -S cpupower
chroot /arch systemctl enable cpupower

###############################################################################
# Get latest Early 2015 13" - Version 12,x wireless lan firware otherwise it won't work.
###############################################################################
# https://wiki.archlinux.org/index.php/MacBook
(cd /arch/usr/lib/firmware/brcm/ && \
  curl -O https://git.kernel.org/cgit/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac43602-pcie.bin)

###############################################################################
# Force reinstall microkernel updates so they appear in boot.
###############################################################################
chroot /arch pacman -S --noconfirm intel-ucode
echo "done ucode"

###############################################################################
# Setup rEFInd to boot up using Intel Micokernel updates
###############################################################################
# Hit F2 for these options
ls /dev

echo "start refind setup"
UUID=$(blkid /dev/sdb -o export | grep UUID | head -1)
echo $UUID
#if [ $MODEL == "MacBook8,1" ]; then
if [ $MODEL == "EXPERIMENTAL" ]; then
  echo "placeholder"
 #  echo "\"1\" \"root=$UUID rootfstype=ext4 rw downclock=1 usbcore.autosuspend=1 h initrd=/boot/initramfs-linux.img\" " >> /arch/boot/refind_linux.conf
else
  # Normal setup which works fine.
  echo "\"Fallback with microkernel updates\" \"root=$UUID rootfstype=ext4 rw loglevel=6 initrd=/boot/intel-ucode.img initrd=/boot/initramfs-linux-fallback.img\" " >> /arch/boot/refind_linux.conf
  echo "\"Fallback without microkernel updates\" \"root=$UUID rootfstype=ext4 rw loglevel=6 initrd=/boot/initramfs-linux-fallback\" " >> /arch/boot/refind_linux.conf
  echo "\"Graphical Interface\" \"root=$UUID rootfstype=ext4 rw quiet loglevel=6 systemd.unit=graphical.target initrd=/boot/intel-ucode.img initrd=/boot/initramfs-linux.img\" " > /arch/boot/refind_linux.conf
  echo "\"Normal with microkernel updates\" \"root=$UUID rootfstype=ext4 rw loglevel=6 initrd=/boot/intel-ucode.img initrd=/boot/initramfs-linux.img\" " >> /arch/boot/refind_linux.conf
  echo "\"Normal without microkernel updates\" \"root=$UUID rootfstype=ext4 rw loglevel=6 initrd=/boot/initramfs-linux.img\" " >> /arch/boot/refind_linux.conf
fi
echo "end refind setup"
###############################################################################
# Setup fstab
# TODO look into not using discard. http://blog.neutrino.es/2013/howto-properly-activate-trim-for-your-ssd-on-linux-fstrim-lvm-and-dmcrypt/
###############################################################################
if [ $MODEL == "MacBook8,1" ]; then
# NVMe on 8,1 does't user discard
  echo "$UUID / ext4 rw,relatime,data=ordered 0 1" > /arch/etc/fstab
else
  echo "$UUID / ext4 discard,rw,relatime,data=ordered 0 1" > /arch/etc/fstab
fi

echo "efivarfs  /sys/firmware/efi/efivars efivarfs  rw,nosuid,nodev,noexec,relatime 0 0" >> /arch/etc/fstab
echo "LABEL=EFI /boot/EFI vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro  0 2" >> /arch/etc/fstab
echo "done fstab"

###############################################################################
# Enable and setup SDDM Display Manger
###############################################################################
chroot /arch pacman -S --noconfirm --needed sddm
chroot /arch systemctl enable sddm
cat >/arch/etc/sddm.conf<<EOL
[Theme]
Current=archlinux
EOL

###############################################################################
# Enable network manager
###############################################################################
chroot /arch systemctl disable dhcpcd

###############################################################################
# xfce4-terminal is my terminal of choice (for now)
# So set that up.
###############################################################################
mkdir -p /arch/home/user/.config/xfce4/terminal
cat >/arch/home/user/.config/xfce4/terminal/terminalrc <<EOL
[Configuration]
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscBordersDefault=TRUE
MiscCursorBlinks=FALSE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=100x40
MiscInheritGeometry=FALSE
MiscMenubarDefault=FALSE
MiscMouseAutohide=FALSE
MiscToolbarDefault=FALSE
MiscConfirmClose=TRUE
MiscCycleTabs=TRUE
MiscTabCloseButtons=TRUE
MiscTabCloseMiddleClick=TRUE
MiscTabPosition=GTK_POS_TOP
MiscHighlightUrls=TRUE
FontName=Liberation Mono for Powerline 14
ColorPalette=#000000000000;#cccc00000000;#4e4e9a9a0606;#c4c4a0a00000;#34346565a4a4;#757550507b7b;#060698989a9a;#d3d3d7d7cfcf;#555557575353;#efef29292929;#8a8ae2e23434;#fcfce9e94f4f;#73739f9fcfcf;#adad7f7fa8a8;#3434e2e2e2e2;#eeeeeeeeecec
TitleMode=TERMINAL_TITLE_REPLACE
ShortcutsNoMenukey=TRUE
ShortcutsNoMnemonics=TRUE
ScrollingLines=100000
EOL

# Disable F1 and F10 in the terminal so I can use my function keys to move around tmux panes
cat >/arch/home/user/.config/xfce4/terminal/accels.scm <<EOL
(gtk_accel_path "<Actions>/terminal-window/fullscreen" "")
(gtk_accel_path "<Actions>/terminal-window/contents" "")
EOL

chroot /arch pacman -Syy --noconfirm
chroot /arch cat /etc/pacman.conf

###############################################################################
# Install the xf86-input-mtrack package
#
# The defaults are way to fast for my taste.
# Config is here: https://github.com/BlueDragonX/xf86-input-mtrack
# Config I am trying is from : https://help.ubuntu.com/community/MacBookPro11-1/utopic
###############################################################################
# Mac Retina doesn't have a trackpad
if [[ $MODEL == *"MacBook"* ]]
then
  chroot /arch pacman --noconfirm --needed -U /var/cache/pacman/custom/xf86-input-mtrack*.pkg.tar.xz
  cat >/arch/usr/share/X11/xorg.conf.d/10-mtrack.conf <<EOL
  Section "InputClass"
  MatchIsTouchpad "on"
  Identifier "Touchpads"
  Driver "mtrack"
  Option "Sensitivity" "0.7"
  Option "IgnoreThumb" "true"
  Option "ThumbSize" "50"
  Option "IgnorePalm" "true"
  Option "DisableOnPalm" "false"
  Option "BottomEdge" "30"
  Option "TapDragEnable" "true"
  Option "Sensitivity" "0.6"
  Option "FingerHigh" "3"
  Option "FingerLow" "2"
  Option "ButtonEnable" "true"
  Option "ButtonIntegrated" "true"
  Option "ButtonTouchExpire" "750"
  Option "ClickFinger1" "1"
  Option "ClickFinger2" "3"
  Option "TapButton1" "1"
  Option "TapButton2" "3"
  Option "TapButton3" "2"
  Option "TapButton4" "0"
  Option "TapDragWait" "100"
  Option "ScrollLeftButton" "7"
  Option "ScrollRightButton" "6"
  Option "ScrollDistance" "100"
  EndSection
EOL

  # Enable natural scrolling
  echo "pointer = 1 2 3 5 4 6 7 8 9 10 11 12" > /arch/home/user/.Xmodmap
else
  # Install mouse drivers.

  chroot /arch pacman -S --noconfirm --needed xf86-input-mouse
  # pacman -S --noconfirm --needed xf86-input-mouse
fi

###############################################################################
# Copy over the mac system info in case we need it for something in the future.
###############################################################################
cp /systeminfo /arch/systeminfo.txt

###############################################################################
# Disable autologin for root
###############################################################################
cat >/arch/etc/systemd/system/getty@tty1.service.d/override.conf<<EOL
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear %I 38400 linux
EOL

###############################################################################
# Setup Awesome Tiling Windows Manager
###############################################################################
chroot /arch pacman --noconfirm --needed -S awesome vicious
chroot /arch mkdir -p /home/user/.config/awesome/themes/default
chroot /arch cp /etc/xdg/awesome/rc.lua /home/user/.config/awesome
chroot /arch cp -rf /usr/share/awesome/themes/default \
                    /home/user/.config/awesome/themes/
chroot /arch sed -i "s/beautiful.init(\"\/usr\/share\/awesome\/themes\/default\/theme.lua\")/beautiful.init(awful.util.getdir(\"config\") .. \"\/themes\/default\/theme.lua\")/" \
                  /home/user/.config/awesome/rc.lua
chroot /arch sed -i "s/xterm/xfce4-terminal/" /home/user/.config/awesome/rc.lua
# chroot /arch sed -i "s/nano/vim/" /home/user/.config/awesome/rc.lua
chroot /arch sed -i '1s/^/vicious = require("vicious")\n/' \
                  /home/user/.config/awesome/rc.lua

###############################################################################
# Setup oh-my-zsh
###############################################################################
chroot /arch cp /usr/share/oh-my-zsh/zshrc /home/user/.zshrc
chroot /arch sed -i "s/ZSH_THEME=\"robbyrussell\"/ZSH_THEME=\"bullet-train\"/" \
  /home/user/.zshrc
chroot /arch sed -i "s/plugins=(git)/plugins=(git git-extras pip tmux python rsync cp archlinux node npm history-substring-search)/" \
  /home/user/.zshrc
echo "BULLETTRAIN_CONTEXT_SHOW=\"true\"" >> /arch/home/user/.zshrc
echo "BULLETTRAIN_CONTEXT_BG=\"31\"" >> /arch/home/user/.zshrc
echo "BULLETTRAIN_CONTEXT_FG=\"231\"" >> /arch/home/user/.zshrc

###############################################################################
# Update mlocate
###############################################################################
chroot /arch updatedb

#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# Final things before syncing to the physical drive.
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------

###############################################################################
# Create initial ramdisk enviroment. 
###############################################################################
# avoid fsck.aufs error
chroot /arch ln -s /bin/true /sbin/fsck.aufs
chroot /arch pacman --noconfirm -S linux

# Needed or won't find the root device
chroot /arch mkinitcpio -p linux

###############################################################################
# Move any general or custom packages into the pacman cache
###############################################################################
echo "Moving any general or custom packages into pacman cache"
mv /arch/var/cache/pacman/custom/* /arch/var/cache/pacman/pkg/

###############################################################################
# Update databases
# Not exactly sure what pacman is doing that pacman isn't but 
# pacman -Syy won't update everyting if the packages changed
# TODO: See /usr/lib/pacman/*.sh
###############################################################################
echo "Updating Databases"
chroot /arch pacman -Syy

###############################################################################
# Lets make sure that any config files etc our user has full ownership of.
###############################################################################
chroot /arch chown -R user:users /home/user/

###############################################################################
# Force root user to change password on next login.
###############################################################################
chroot /arch chage -d 0 root

###############################################################################
# Mount the physical drive 
###############################################################################
mkdir /mnt/archlinux
mount /dev/sdb /mnt/archlinux

###############################################################################
# Sync to the physical drive
#
# On very slow USBs docker can time out This has only happened on one USB
# drive so far and appears to be more of a boot2docker issue than anything else.
###############################################################################
echo "Syncing system to your drive. This will take a couple minutes. (or significantly longer if using USB)"

time rsync -aAX --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} /arch/* /mnt/archlinux

# Not sure if this is needed but to be safe.
sync

###############################################################################
# Helpful message for user
#
# Not sure why mkinitcpio -p linux has to be done again
###############################################################################
echo " "
echo "If for some reason you get an error device not found"
echo "hit F2 then select a fallback"
echo "then run mkinitcpio -p linux"
echo " "

###############################################################################
# Unmount physical drive
###############################################################################
# delay before unmount to finish writing.otherwise sometimes in use.
sleep 2

# Unmount main disk
umount /mnt/archlinux

echo "*** FINISHED ***"

# vim:set ts=2 sw=2 et:
