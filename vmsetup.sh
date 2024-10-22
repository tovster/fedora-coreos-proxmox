#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# template vm vars
TEMPLATE_VMID=${TEMPLATE_VMID}
TEMPLATE_VMSTORAGE=${TEMPLATE_VMSTORAGE}
SNIPPET_STORAGE=${SNIPPET_STORAGE}
VMDISK_OPTIONS=${VMDISK_OPTIONS}

TEMPLATE_IGNITION=${TEMPLATE_IGNITION}

# fcos version
STREAMS=${STREAMS}
VERSION=${VERSION}
PLATFORM=qemu
BASEURL=https://builds.coreos.fedoraproject.org

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exist... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exist... "
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet enable
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep snippets || {
	echo "You musr activate content snippet on storage: ${SNIPPET_STORAGE}"
	exit 1
}

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"
echo "${snippet_storage}"
cp -av ${TEMPLATE_IGNITION} hook-fcos.sh ${snippet_storage}/snippets
sed -e "/^COREOS_TMPLT/ c\COREOS_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcos.sh
chmod 755 ${snippet_storage}/snippets/hook-fcos.sh

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
        dir|nfs|cifs|glusterfs|cephfs) TEMPLATE_VMSTORAGE_type="file"; echo "[file]"; ;;
        lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool) TEMPLATE_VMSTORAGE_type="block"; echo "[block]" ;;
        *)
                echo "[unknown]"
                exit 1
        ;;
esac

# download fcos vdisk
[[ ! -e fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ]]&& {
    echo "Download fedora coreos..."
    wget -q --show-progress \
        ${BASEURL}/prod/streams/${STREAMS}/builds/${VERSION}/x86_64/fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
    xz -dv fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz
}

# create a new VM
echo "Create fedora coreos vm ${VMID}"
qm create ${TEMPLATE_VMID} --name ${TEMPLATE_NAME}
qm set ${TEMPLATE_VMID} --memory 4096 \
			--cpu host \
			--cores 4 \
			--agent enabled=1 \
			--autostart \
			--onboot 1 \
			--ostype l26 \
			--tablet 0 \
			--boot c --bootdisk scsi0

template_vmcreated=$(date +%Y-%m-%d)
qm set ${TEMPLATE_VMID} --description "Fedora CoreOS

 - Version             : ${VERSION}
 - Cloud-init          : true

Creation date : ${template_vmcreated}
"

# add virtual serial port 
qm set ${TEMPLATE_VMID} -serial0 socket

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0

echo -e "\nCreating Cloud-init vmdisk..."
qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit

# import fedora disk
if [[ "x${TEMPLATE_VMSTORAGE_type}" = "xfile" ]]
then
	vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
	vmdisk_format="--format qcow2"
else
	vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
        vmdisk_format=""
fi
qm importdisk ${TEMPLATE_VMID} fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2 ${TEMPLATE_VMSTORAGE} ${vmdisk_format}
qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}

# set hook-script
qm set ${TEMPLATE_VMID} -hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh


# convert vm template
echo -n "Converting VM ${TEMPLATE_VMID} in proxmox vm template... "
qm template ${TEMPLATE_VMID} &> /dev/null || true
echo "[done]"
