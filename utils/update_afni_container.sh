#!/bin/bash


basedir=$PWD
 
export SINGULARITY_TMPDIR=/misc/purcell/alfonso/tmp/container/tmp
export SINGULARITY_CACHEDIR=/misc/purcell/alfonso/tmp/container/tmp




# clean singularity cache

singularity cache clean --force




# login in with singularity remote login 

singularity remote login --tokenfile \
 /misc/purcell/alfonso/tmp/container/sylabs-token



# build de container

echo
echo 
echo "++ Updating container... This may take a while but no as much as creating the container from zero."

echo 

echo


# build a sandbox container from the previous one

echo "++ Creating temporary sandbox to edit the container..."
echo
singularity build --sandbox  -F /misc/purcell/alfonso/tmp/container/tmp/afni \
 /misc/purcell/alfonso/tmp/container/afni.sif


# update afni binaries 

if [ -d /misc/purcell/alfonso/tmp/container/tmp/afni ]
then

echo "++ Updating AFNI"
cd /misc/purcell/alfonso/tmp/container/tmp/afni

tcsh ./AFNI/abin/@update.afni.binaries -do_extras -package linux_ubuntu_16_64 \
 -bindir ./AFNI/abin -make_backup no


tcsh ./AFNI/abin/@Install_NMT -install_dir ./AFNI -overwrite -sym sym
tcsh ./AFNI/abin/@Install_NMT -install_dir ./AFNI -overwrite -sym asym

# copy files to abin 

find ./AFNI -name "NMT*.nii.gz" -exec cp -v {} ./AFNI/abin \;



# update MNI atlas in the abin folder 
 
cp /misc/purcell/alfonso/tmp/github/psilafni/utils/*.nii.gz /misc/purcell/alfonso/tmp/container/tmp/afni/AFNI/abin

cd $basedir


 

# convert the afni sandbox to a .sif container


singularity cache clean --force 

singularity build -F /misc/purcell/alfonso/tmp/container/tmp/afni.sif \
 /misc/purcell/alfonso/tmp/container/tmp/afni


rm -rf  /misc/purcell/alfonso/tmp/container/tmp/afni


else

echo
echo 
echo "+ +Failure to create container. Program exits now!!!! "
echo 
exit 



fi



if [  -f /misc/purcell/alfonso/tmp/container/tmp/afni.sif ]
then
mv  /misc/purcell/alfonso/tmp/container/tmp/afni.sif /misc/purcell/alfonso/tmp/container/afni.sif

echo
echo
echo "++ Transfering container to lavis directories"

rsync --progress  --verbose --force /misc/purcell/alfonso/tmp/container/afni.sif \
 afajardo@ada.lavis.unam.mx:/mnt/MD1200B/egarza/afajardo/containers/

else 
echo
echo 
echo "++Failure to create container. Program exits now!!!! "
echo 
exit 


fi

singularity cache clean --force 
echo 
echo 
echo "++ DONE"

exit
