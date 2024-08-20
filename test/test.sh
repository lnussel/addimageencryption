#!/bin/bash
set -euxo pipefail

# Some basic combustion testing:
# 1. Download the latest MicroOS image
# 2. Use its combustion to install the disk-encryption-tool to test and transfer kernel + initrd to the host using 9pfs
# 3. Revert the image to the original state and perform tests using the generated kernel + initrd

# Skip the generation of a new initrd with the changed disk-encryption-tool.
# Only useful when iterating this test script.
reuseinitrd=
if [ "${1-}" = "--reuseinitrd" ]; then
	reuseinitrd=1
	shift
fi

# Working dir which is also exposed to the VM through 9pfs.
# If not specified, create a temporary directory which is deleted on exit.
if [ -n "${1-}" ]; then
	tmpdir="$(realpath "$1")"
else
	tmpdir="$(mktemp -d)"
	cleanup() {
		rm -rf "$tmpdir"
	}
	trap cleanup EXIT
fi

QEMU_BASEARGS=(
	# -accel tcg was here after -accel kvm but the fallback hid a weird bug
	# that in GH actions only the first instance of QEMU was able to access /dev/kvm.
	-accel kvm -nographic -m 1024
	# Reading from stdin doesn't work, configure serial and monitor appropriately.
	-chardev null,id=serial,logfile=/dev/stdout,logappend=on -serial chardev:serial -monitor none
	-virtfs "local,path=${tmpdir},mount_tag=tmpdir,security_model=none")

if [ -e /usr/share/qemu/ovmf-x86_64-code.bin ]; then
	QEMU_BASEARGS+=(-bios /usr/share/qemu/ovmf-x86_64-code.bin)
elif [ -e /usr/share/qemu/OVMF.fd ]; then
	QEMU_BASEARGS+=(-bios /usr/share/qemu/OVMF.fd)
else
	echo "No OVMF found"
	exit 1
fi

# Prepare the temporary dir: Install disk-encryption-tool and copy resources.
testdir="$(dirname "$0")"
# TODO: Use a Makefile for this and in the .spec file.
mkdir -p "${tmpdir}/install/usr/lib/dracut/modules.d/95disk-encryption-tool"
for i in disk-encryption-tool{,-dracut,-dracut.service} module-setup.sh generate-recovery-key; do
	cp "${testdir}/../${i}" "${tmpdir}/install/usr/lib/dracut/modules.d/95disk-encryption-tool/${i}"
done
cp "${testdir}/"{testscript,config.ign} "${tmpdir}"
cd "$tmpdir"

# Download latest MicroOS image
if ! [ -f openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2 ]; then
	wget --progress=bar:force:noscroll https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2
	qemu-img snapshot -c initial openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2
else
	qemu-img snapshot -a initial openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2
fi

# First step: Use combustion in the downloaded image to generate an initrd with the new disk-encryption-tool.
if ! [ -n "${reuseinitrd}" ] || ! [ -e "${tmpdir}/vmlinuz" ] || ! [ -e "${tmpdir}/initrd" ]; then
	rm -f "${tmpdir}/done"
	cat >create-initrd <<'EOF'
#!/bin/bash
set -euxo pipefail
exec &>/dev/ttyS0
trap '[ $? -eq 0 ] || poweroff -f' EXIT
mount -t 9p -o trans=virtio tmpdir /mnt
# Install new disk-encryption-tool, make sure the old remnants are gone
rpm -e --nodeps --noscripts disk-encryption-tool
cp -av /mnt/install/usr /
cp /usr/lib/modules/$(uname -r)/vmlinuz /mnt/vmlinuz
dracut -f --no-hostonly /mnt/initrd
touch /mnt/done
umount /mnt
SYSTEMD_IGNORE_CHROOT=1 poweroff -f
EOF

	timeout 300 qemu-system-x86_64 "${QEMU_BASEARGS[@]}" -drive if=virtio,file=openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2 \
		-fw_cfg name=opt/org.opensuse.combustion/script,file=create-initrd

	if ! [ -e "${tmpdir}/done" ]; then
		echo "Initrd generation failed"
		exit 1
	fi
fi

# Test using a config drive
rm -f "${tmpdir}/done"
qemu-img snapshot -a initial openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2

mkdir -p configdrv/combustion/
cp testscript configdrv/combustion/script
#mkdir -p configdrv/ignition/
#cp config.ign configdrv/ignition/config.ign
/sbin/mkfs.ext4 -F -d configdrv -L ignition combustion.raw 16M

timeout 300 qemu-system-x86_64 "${QEMU_BASEARGS[@]}" -drive if=virtio,file=openSUSE-MicroOS.x86_64-kvm-and-xen-sdboot.qcow2 \
	-kernel vmlinuz -initrd initrd -append "root=LABEL=ROOT console=ttyS0 quiet systemd.show_status=1 systemd.log_target=console systemd.journald.forward_to_console=1 rd.emergency=poweroff rd.shell=0" \
	-drive if=virtio,file=combustion.raw

if ! [ -e "${tmpdir}/done" ]; then
	echo "Test failed"
	exit 1
fi
