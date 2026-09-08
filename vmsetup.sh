#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

# Install dependencies
if [[ ! -f $(which jq) ]]; then apt install jq -y; fi
 
# template vm vars
DEFAULT_ID=900
TEMPLATE_VMID=$DEFAULT_ID
read -p "VM Template ID: ($DEFAULT_ID)" vmid
if [ -n "$vmid" ] ; then
   TEMPLATE_VMID="$vmid"
fi

TEMPLATE_VMSTORAGE="local-lvm"
read -p "VM Storage ($TEMPLATE_VMSTORAGE)" vmstorage
if [ -n "$vmstorage" ] ; then
   TEMPLATE_VMSTORAGE="$vmstorage"
fi

SNIPPET_STORAGE="local"
echo "Snippet storage is $SNIPPET_STORAGE. (else modify script)"

VMDISK_OPTIONS=",discard=on"
TEMPLATE_IGNITION="fcos-base-tmplt.yaml"

# fcos version - stable, next, or testing
STREAMS=stable
PLATFORM=qemu
# Get the latest version
JSON=$(curl -s "https://builds.coreos.fedoraproject.org/streams/${STREAMS}.json")
VERSION=$(echo ${JSON} | jq -r ".architectures.x86_64.artifacts.${PLATFORM}.release")
IMAGE_URL=$(echo ${JSON} | jq -r ".architectures.x86_64.artifacts.${PLATFORM}.formats.\"qcow2.xz\".disk.location")
IMAGE_NAME_XZ="fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2.xz"
IMAGE_NAME="fedora-coreos-${VERSION}-${PLATFORM}.x86_64.qcow2"

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
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
	echo "You musr activate content snippet on storage: ${SNIPPET_STORAGE}"
	exit 1
}

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"
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
[[ ! -e ${IMAGE_NAME} ]] && {
    echo "Download fedora coreos..."
    wget -c -q --show-progress ${IMAGE_URL} -O ${IMAGE_NAME_XZ}
    xz -dv ${IMAGE_NAME_XZ}
}

set -x
# create a new VM
echo "Create fedora coreos vm ${VMID}"
qm create ${TEMPLATE_VMID} --name fcos-tmplt
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
https://github.com/gunnarx/fedora-coreos-proxmox 
forked from: https://github.com/windweaver828/fedora-coreos-proxmox (2024)
forked from: https://github.com/GECO-IT/fedora-coreos-proxmox (2020)
...

 - Version             : ${VERSION}
 - Cloud-init          : true

Creation date : ${template_vmcreated}
"

qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0
#qm set ${TEMPLATE_VMID} --net1 virtio,bridge=vmbr1

echo -e "\nCreate Cloud-init vmdisk..."
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
qm importdisk ${TEMPLATE_VMID} ${IMAGE_NAME} ${TEMPLATE_VMSTORAGE} ${vmdisk_format}
qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}

# set hook-script
qm set ${TEMPLATE_VMID} -hookscript ${SNIPPET_STORAGE}:snippets/hook-fcos.sh

# convert to vm template
echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
qm template ${TEMPLATE_VMID} &> /dev/null || true
echo "[done]"

echo "VM template created."
echo  
echo "Now we should set the required vars, otherwise the pre-start hookscript (which runs on PVE host) will not succeed"
echo
read -p "Username (user):" user
if [ -z "$user" ] ; then
   echo "OK, using 'user' as username"
   user=user
fi
read -s -p "Password for $user (no echo): " password

echo "ssh-key via file-path: leave empty if you prefer to paste actual key"
read -p "ssh-key path (optional)" sshkeypath
if [ -z "$sshkeypath" ] ; then
   echo "ssh-key (paste PUBLIC key, then CTRL-D):"
   cat >/tmp/key.$$
   sshkeypath=/tmp/key.$$
fi

qm set 900 --ciuser "$user"
qm set 900 --cipassword "$password"
qm set 900 --sshkeys "$sshkeypath"
qm set 900 --ipconfig0 "ip=dhcp"

echo
echo "Variables have now been set to your given values."
echo "To edit again go into PVE GUI and select the Cloud-Init section on the fcos-tmplt."
echo "After cloning the template, it is also possible to set on the new VM before first boot"
