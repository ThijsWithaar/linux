#!/bin/bash

# dkms will use the default clang, so CLANG_MAJOR must match the default version, or apt-install needs LLVM as env variable.
# Clang-18's LTO + ZEN4 stumbles over the kernel. https://github.com/llvm/llvm-project/issues/82896#issuecomment-1969968898
#export CLANG_MAJOR=`echo __clang_major__ | clang -E -x c - | tail -n 1`
export CLANG_MAJOR=19
export LC_CTYPE="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

BUILD_DEPENDENCIES_DEBIAN="libssl-dev openssl mokutil clang-$CLANG_MAJOR llvm-$CLANG_MAJOR lld-$CLANG_MAJOR"
dpkg-checkbuilddeps -d "${BUILD_DEPENDENCIES_DEBIAN// /, }" /dev/null &>/dev/null
if [[ $? != 0 ]]; then
	sudo apt -y install ${BUILD_DEPENDENCIES_DEBIAN}
fi

export SIG_DIR=/root
export SIG_PRIV=$SIG_DIR/mok.key
export SIG_PEM=$SIG_DIR/mok.pem
export SIG_PUB=$SIG_DIR/mok.pub
export SIG_CRT=$SIG_DIR/mok.crt
export SIG_PEM_MOD=/var/lib/dkms/mok.pem
mokutil --test-key $SIG_PUB
#if [ ! -f /root/MOK.priv ]; then
	#sudo openssl req -config ./mokconfig.cnf -new -x509 -newkey rsa:2048 -nodes -days 36500 -outform DER -keyout "/root/MOK.priv" -out "/root/MOK.der"
	#sudo openssl x509 -in "/root/MOK.der" -inform DER -outform PEM -out "/root/MOK.pem"
	# mokutil --import /root/MOK.der
	# openssl req -sha256 -new -config mokconfig.cnf -key $SIG_PRIV -out mok.csr
	# openssl req -new -x509 -config mokconfig.cnf -key MOK.priv -out ca.crt -days 9600 -batch
#fi

cp /boot/config-6.12.73+deb13-amd64 .config #config-$(uname -r) .config
make LLVM=-$CLANG_MAJOR olddefconfig
cp .config .config_updated
# Note: HSA_AND_SVM requires the "amdgpu.noretry=0" boot parameter
./scripts/config -e DRM -m DRM_AMDGPU -e DEVICE_PRIVATE -e HSA_AMD_SVM
# -d CONFIG_ZERO_CALL_USED_REGS avoids a clang bug:
#	https://github.com/llvm/llvm-project/issues/72026#issuecomment-1834473250
#	https://github.com/llvm/llvm-project/pull/85081
#	replace -e MZEN4 with -e GENERIC_CPU4
./scripts/config -d GENERIC_CPU -e MZEN4 -d SPECULATION_MITIGATIONS
# ATH11K needs it's firmware, and also
# https://salsa.debian.org/kernel-team/linux/-/blob/master/debian/patches/debian/wireless-add-debian-wireless-regdb-certificates.patch
./scripts/config --set-str EXTRA_FIRMWARE_DIR "/lib/firmware" --set-str EXTRA_FIRMWARE "ath11k/WCN6855/hw2.1/amss.bin ath11k/WCN6855/hw2.1/board-2.bin ath11k/WCN6855/hw2.1/m3.bin regulatory.db-debian"
./scripts/config -e RFKILL -e CFG80211 -e MAC80211 -e ATH11K -e ATH11K_PCI -e CFG80211_CERTIFICATION_ONUS -d CFG80211_REQUIRE_SIGNED_REGDB
./scripts/config -d DRM_NOUVEAU -d DRM_I915 -d SCSI_LOWLEVEL -e THINKPAD_ACPI
./scripts/config -e BCACHEFS_FS
./scripts/config -e KERNEL_ZSTD -d KERNEL_XZ
./scripts/config -e DRM_VBOXVIDEO -e VBOXGUEST -e VBOXSF_FS
make LLVM=-$CLANG_MAJOR olddefconfig
./scripts/config -d MODULE_COMPRESS_XZ -e MODULE_COMPRESS_ZSTD
./scripts/config -d MODULE_SIG -d MODULE_SIG_ALL -e MODULE_SIG_KEY_TYPE_ECDSA -d MODULE_SIG_SHA256 --set-str MODULE_SIG_KEY $SIG_PEM_MOD
./scripts/config -d LTO_NONE -e LTO_CLANG_THIN --set-val CONFIG_FRAME_WARN 4096
./scripts/config -e CONFIG_NTSYNC

mv -f ../*.deb ../deb || true
export LOCALVERSION=-twi
KDEB_PKGVERSION="0" nice make CC=clang-$CLANG_MAJOR LLVM=-$CLANG_MAJOR -j16 bindeb-pkg

DEB_FILE=$(ls linux-image-*_amd64.deb | tail -n1)
echo "## Signing kernel $DEB_FILE ##"
dpkg-deb -R $DEB_FILE extracted-deb/
sudo sbsign --key $SIG_PRIV --cert $SIG_CRT ./extracted-deb/boot/vmlinuz-*$LOCALVERSION --output ./extracted-deb/boot/vmlinuz-*$LOCALVERSION-signed
mv ./extracted-deb/boot/vmlinuz-*$LOCALVERSION-signed ./extracted-deb/boot/vmlinuz-*$LOCALVERSION
# dpkg-deb -b extracted-deb/ $DEB_FILE

echo "## Installing kernel $DEB_FILE ##"
mv -f ../*dbg_*.deb ../deb || true
# Alternatively add "export LLVM=19" to /etc/dkms/framework.com
CC=clang-${CLANG_MAJOR} LLVM=-$CLANG_MAJOR apt install ../linux-image*.deb ../linux-headers-*.deb
