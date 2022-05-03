#!/bin/bash

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
echo "++ Starting to build. Grab a coffee or something cause this is going to take a while."

echo 

echo



 singularity build --remote -F /misc/purcell/alfonso/tmp/container/tmp/afni.sif build_afni_container.def

if [  -f /misc/purcell/alfonso/tmp/container/tmp/afni.sif ]
then
cp  /misc/purcell/alfonso/tmp/container/tmp/afni.sif /misc/purcell/alfonso/tmp/container/afni.sif

echo
echo
echo "++ Transfering container to lavis directories"

rsync --progress --checksum --append-verify  --verbose --force /misc/purcell/alfonso/tmp/container/afni.sif \ 
 afajardo@ada.lavis.unam.mx:/mnt/MD1200B/egarza/afajardo/containers/tmp

else 

echo echo
echo "++Failure to create container. Program exits now!!!! "
 exit 


fi
echo 
echo 
echo "++ DONE"

exit
