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
echo "++ Updating container!!!! This may take a while but no as much as creating the container from zero."

echo 

echo


# build a sandbox container from the previous one 

echo "creating temporary sandbox to edit the container "

singularity build --sandbox  -F /misc/purcell/alfonso/tmp/container/tmp/afni \
 /misc/purcell/alfonso/tmp/container/afni.sif 


# update afni binaries 

if [ -d /misc/purcell/alfonso/tmp/container/tmp/afni ]
then

echo "++ Updating AFNI"
cd /misc/purcell/alfonso/tmp/container/tmp/afni

tcsh ./AFNI/abin/@update.afni.binaries -do_extras -package linux_ubuntu_16_64 \
 -bindir ./AFNI/abin -no_recur


tcsh ./AFNI/abin/@Install_NMT -install_dir ./AFNI -overwrite -sym sym
tcsh ./AFNI/abin/@Install_NMT -install_dir ./AFNI -overwrite -sym asym

# copy files to abin 

find ./AFNI -name "NMT*.nii.gz" -exec cp -v {} ./AFNI/abin \;

# update MNI atlas in the abin folder 
 
cd ./AFNI/abin

wget https://github.com/edrojas3/psilafni/raw/main/utils/MNI152_T1_2mm.nii.gz
wget https://github.com/edrojas3/psilafni/raw/main/utils/MNI152_T1_2mm_brain.nii.gz
wget https://github.com/edrojas3/psilafni/raw/main/utils/MNI152_T1_2mm_template1.0_SSW.nii.gz
wget https://github.com/edrojas3/psilafni/raw/main/utils/MNI152_T1_2mm_ventricle_mask.nii.gz
wget https://github.com/edrojas3/psilafni/raw/main/utils/NMT_v2.0_sym_05mm_template1.0_SSW.nii.gz


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
cp  /misc/purcell/alfonso/tmp/container/tmp/afni.sif /misc/purcell/alfonso/tmp/container/afni.sif

echo
echo
echo "++ Transfering container to lavis directories"

rsync --progress  --verbose --force /misc/purcell/alfonso/tmp/container/afni.sif \
 afajardo@ada.lavis.unam.mx:/mnt/MD1200B/egarza/afajardo/containers/tmp

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
