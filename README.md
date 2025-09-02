# firecracker-helpers
A series of tools to help your firecracker installation be more like the AWS CI and more like Docker. 

## fc-nethelper
This is an opinionated script to add and remove tap devices named after the new service and joins them to `virbr-fc`. It is assumed you have firewall rules properly established on `virbr-fc` or the bridge you set on line 5. If it is to be used in a service run by a non-root user, this script needs `NET_CAP_ADMIN` caps set. It would be nice to add a tool here to show how to set that bridge and associated firewalls up. 

## fc-kernel.sh
This tool takes a firecracker commit hash or release version and a few optional flags to download the same kernels that firecracker version was tested against in CI. 

## fc-rootfs.sh
This accepts a dockerfile, or docker image and builds a matching firecracker rootfs from it. The image has a newly generated unencrypted ssh key for immediate access, all required faculties for firecracker support, and is properly packed into a .ext4 file. 
This allows easy setup of new target environments without the need to manually administer the server before use. This also allows for integration in decalrative systems and CI pipelines. 

