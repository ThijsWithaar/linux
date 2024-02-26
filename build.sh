#!/bin/bash

# dkms will use the default clang, so CLANG_MAJOR must match the default version, or apt-install needs LLVM as env variable.
# Clang-18's LTO + ZEN4 stumbles over the kernel. https://github.com/llvm/llvm-project/issues/82896#issuecomment-1969968898
export CLANG_MAJOR=`echo __clang_major__ | clang -E -x c - | tail -n 1`

BUILD_DEPENDENCIES_DEBIAN="libssl-dev openssl mokutil clang-$CLANG_MAJOR llvm-$CLANG_MAJOR lld-$CLANG_MAJOR"
dpkg-checkbuilddeps -d "${BUILD_DEPENDENCIES_DEBIAN// /, }" /dev/null &>/dev/null
if [[ $? != 0 ]]; then
	sudo apt -y install ${BUILD_DEPENDENCIES_DEBIAN}
fi

if [ ! -f /root/MOK.priv ]; then
	openssl req -config ./mokconfig.cnf -new -x509 -newkey rsa:2048 -nodes -days 36500 -outform DER -keyout "/root/MOK.priv" -out "/root/MOK.der"
	openssl x509 -in "/root/MOK.der" -inform DER -outform PEM -out "/root/MOK.pem"
	# mokutil --import /root/MOK.der
fi

cp /boot/config-6.12.27-amd64 .config
make LLVM=-$CLANG_MAJOR olddefconfig
# Note: HSA_AND_SVM requires the "amdgpu.noretry=0" boot parameter
./scripts/config -e DRM -m DRM_AMDGPU -e DEVICE_PRIVATE -e HSA_AMD_SVM
./scripts/config -d GENERIC_CPU -e MZEN4
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
./scripts/config -d MODULE_SIG -d MODULE_SIG_ALL -e MODULE_SIG_KEY_TYPE_ECDSA -d MODULE_SIG_SHA256 --set-str MODULE_SIG_KEY /root/mok.pem
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
