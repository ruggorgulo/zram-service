# zram-service
Activate compressed ram disks and swaps. Usefull for read-only root filesystem.
This script provides an easy way of creating compressed ram disks and swaps.

Basic configuration in /etc/zram-service.sh creates one compressed swap and several compressed disks.

Contains *upstart* init service. Tested  on Linux Mint 17.3.


## Create deb package
Based on instructions at
[Creating a simple deb package based on a directory structure](http://www.sj-vs.net/creating-a-simple-debian-deb-package-based-on-a-directory-structure/)
[How to make a Basic deb](http://ubuntuforums.org/showthread.php?t=910717)

Download the source to local directory. Run the following commands as root (or use sudo if you’re on Ubuntu/Mint):

1. Rename the package directory so that it has version number:
`mv zram-service zram-service-1.0`

2. Build the package using dpkg-deb:
`dpkg-deb --build zram-service-1.0`
