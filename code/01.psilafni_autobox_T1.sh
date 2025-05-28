#!/bin/bash

# Description: FOV is too big in some of the anatomicals, often containing tissue that hinders anatomical processing.
#              This script calls 3dAutobox function to reduce the FOV as much as possible to only contain the head.

# INPUTS
site=$1 # PATH OF YOUR BIDS (OR BIDS-LIKE) FOLDER
subj=$2 # Id of SUBJECT TO PROCESS

# Find anatomical images matching with the subject
subj_anat=$(find "$site/$subj" -type f -name "${subj}*T1w.nii*")

# prefix
prefix_anat=$(echo "$subj_anat" | sed 's/\.nii\(.*\)$/_boxed.nii\1/')

# Now simply call 3dAutobox 
3dAutobox -input "$subj_anat" -prefix "$prefix_anat"

echo ++ DONE

exit 0
