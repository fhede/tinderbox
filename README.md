# tinderbox
The goal is to detect build issues of and conflicts between Gentoo Linux packages.

## usage
### create a new image

    cd ~/img2; setup_img.sh

A profile, keyword and a USE flag set are choosen.
The current *stage3* file is downloaded, verified and unpacked.
Mandatory portage config files will be compiled.
Few required packages (*ssmtp*, *pybugz* etc.) are installed.
All available package are listed in a randomized order in */tmp/backlog*.
A symlink is made into *~/run* and the image is started.

### start an image
    
    start_img.sh <image>

The wrapper *chr.sh* handles all chroot related actions and gives control to *job.sh*.
The file */tmp/LOCK* is created to avoid 2 parallel starts of the same image.
Without any arguments all symlinks in *~/run* are processed.

### stop an image

    stop_img.sh <image>

A marker file */tmp/STOP* is created in that image.
The current emerge operation is finished before *job.sh* removes */tmp/{LOCK,STOP}* and exits.

### chroot into a stopped image
    
    sudo /opt/tb/bin/chr.sh <image>

This bind-mount all desired directories from the host system. Without any argument an interactive login is made afterwards. Otherwise the argumenti(s) are treated as command(s) to be run within that image before the cheroot is exited.

### chroot into a running image
    
    sudo /opt/tb/bin/scw.sh <image>

Simple wrapper of chroot with few checks, no hosts files are mounted. This can be made if an image is already running and therefore chr.sh can't be used.

### removal of an image
Stop the image and remove the symlink in *~/run*.
The chroot image itself will be kept around in the data dir.

### status of all images

    whatsup.sh -otlp

### report findings
New findings are send via email to the user specified in the variable *mailto*.
Bugs can be filed using *bgo.sh* - a comand line ready for copy+paste is in the email.

### manually bug hunting within an image
1. stop image if it is running
2. chroot into it
3. inspect/adapt files in */etc/portage/packages.*
4. do your work in */usr/local/portage* to test new/changed ebuilds (do not edit files in */usr/portage*, that is sbind-mountedi from the host)
5. exit from chroot

### unattended test of package/s
Append package/s to the package list in the following way:
    
    cat <<<EOF >> ~/run/[image]/tmp/backlog
    INFO this text becomes the subject of an email if reached
    package1
    ...
    %action1
    ...
    packageN
    ...
    EOF

"STOP" can be used instead "INFO" to stop the image at that point.

### mis
The script *update_backlog.sh* mixes repository updates into the backlog of each image. *retest.sh* is used to undo any package specific changes to portage files and schedule an emerge of the package afterwards. *logcheck.sh* is a helper to notify about non-empty log file(s).

## installation
Create the user *tinderbox*:

    useradd -m tinderbox
Run in */home/tinderbox*:

    mkdir ~/img{1,2} ~/logs ~/run ~/tb
Copy *./data* and *./sdata* into *~/tb* and *./bin* into */opt/tb*.
The user *tinderbox* must not be allowed to edit the scripts in */opt/tb/bin*.
The user must have write permissions for files in *~/tb/data*.
Edit files in *~/sdata* and strip away the suffix *.sample*.
Grant sudo rights:

    tinderbox ALL=(ALL) NOPASSWD: /opt/tb/bin/chr.sh,/opt/tb/bin/scw.sh,/opt/tb/bin/setup_img.sh

## more info
https://www.zwiebeltoralf.de/tinderbox.html

