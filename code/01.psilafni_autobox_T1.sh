#!/bin/bash

#Description: FOV is too big in some of the anatomicals, often cotaining tissue that hiders anatomical proprocesing.
 #             This script calls 3dAUtobox function to reduce the FOV as much as possible to only contain the head. 




# INPUTS
site=$1 # PATH OF YOUR BIDS (OR BIDS-LIKE) FOLDER
subj=$2 # Id of SUBJECT TO PROCESS



# Edit this variables, depending ON  the location of your NMT atlas folder


# Find anatomical images matching with the subject
subj_anat=$(find $site/$subj -type f -name "${subj}*T1w.nii*")

# prefix

prefix_anat=$(echo $subj_anat | sed 's/.nii/_boxed.nii/g')


# No simply call 3dAutobox 

3dAutobox -input $subj_anat -prefix $prefix_anat 

echo ++ DONE

exit 
