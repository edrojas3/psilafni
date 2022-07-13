#!/bin/bash


basedir=$PWD
 
export SINGULARITY_TMPDIR=/misc/tezca/alfonso/tmp/containers/tmp
export SINGULARITY_CACHEDIR=/misc/tezca/alfonso/tmp/containers/tmp




# clean singularity cache

singularity cache clean --force

autenticate with singularity credentials

singularity remote login --tokenfile /misc/tezca/alfonso/tmp/containers/sylabs.token


# build de container

echo
echo 
echo "++ Updating container... This may take a while but no as much as creating the container from zero."

echo 

echo




# build a sandbox container from the previous one

echo "++ Creating temporary sandbox to edit the container..."
echo
singularity build --sandbox  -F /misc/tezca/alfonso/tmp/containers/tmp/afni \
 /misc/tezca/alfonso/tmp/containers/afni.sif


# update afni binaries 

if [ -d /misc/tezca/alfonso/tmp/containers/tmp/afni ]
then

echo "++ Updating AFNI"
cd /misc/tezca/alfonso/tmp/containers/tmp/afni

tcsh ./AFNI/abin/@update.afni.binaries -do_extras -package linux_ubuntu_16_64 \
 -bindir ./AFNI/abin -make_backup no


tcsh ./AFNI/abin/@Install_NMT -install_dir ./AFNI -overwrite -sym sym
tcsh ./AFNI/abin/@Install_NMT -install_dir ./AFNI -overwrite -sym asym

# copy files to abin 

find ./AFNI -name "NMT*.nii.gz" -exec cp -v {} ./AFNI/abin \;



# update MNI atlas in the abin folder 
 
cp /misc/tezca/alfonso/tmp/repos/psilafni/utils/*.nii.gz /misc/tezca/alfonso/tmp/containers/tmp/afni/AFNI/abin

cd $basedir


 

# convert the afni sandbox to a .sif container


singularity cache clean --force 

singularity build -F /misc/tezca/alfonso/tmp/containers/tmp/afni.sif \
 /misc/tezca/alfonso/tmp/containers/tmp/afni


rm -rf  /misc/tezca/alfonso/tmp/containers/tmp/afni


else

echo
echo 
echo "++ Failure to create container. Program exits now!!!! "
echo 
exit 



fi



if [  -f /misc/tezca/alfonso/tmp/containers/tmp/afni.sif ]
then
mv  /misc/tezca/alfonso/tmp/containers/tmp/afni.sif /misc/tezca/alfonso/tmp/containers/afni.sif

echo
echo
echo "++ Transfering container to lavis directories"

rsync --progress  --verbose --force /misc/tezca/alfonso/tmp/containers/afni.sif \
 afajardo@ada.lavis.unam.mx:/mnt/MD1200B/egarza/afajardo/containers/

else 
echo
echo 
echo "++ Failure to create and/or transfer container. Program exits now!!!! "
echo 
exit 


fi

singularity cache clean --force 
echo 
echo 
echo "++ DONE"

exit
