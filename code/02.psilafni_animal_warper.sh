#!/bin/bash

# ANATOMICAL REGISTRATION TO STANDARD SPACE (NMT) USING @animal_warper.py

# Process a single subject

# INPUTS
site=$1
subj=$2

# DEFAULTS
outdir=${site}/data_aw/$subj

# Get anatomical volume(s)
subj_anat=$(find ${site}/${subj} -type f -name "${subj}*T1*boxed*nii*")

echo
echo
echo ++ Current Site Directory: $site 
echo ++ Preprocessing ${subj} anat: $(basename $subj_anat)
echo ++ Output Directory: $outdir
echo

echo ++ Starting:
sleep 5s 

# MAKE SURE TO HAVE ALL THE FOLDERS. FOR MORE DETAILS TRY @Install_NMT

refdir=/AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm
refvol=${refdir}/NMT_v2.1_sym_05mm_SS.nii.gz
refmask=${refdir}/NMT_v2.1_sym_05mm_brainmask.nii.gz



 @animal_warper  \
 -input $subj_anat \
 -input_abbrev ${subj}_anat \
 -base $refvol \
 -base_abbrev NMT_v2.2_sym \
 -atlas followers ${refdir}/CHARM_in_NMT_v2.1_sym_05mm.nii.gz ${refdir}/D99_atlas_in_NMT_v2.1_sym_05mm.nii.gz \
 -atlas_abbrevs CHARM D99 \
 -skullstrip ${refdir}/NMT_v2.1_sym_05mm_brainmask.nii.gz \
 -seg_followers  ${refdir}/NMT_v2.1_sym_05mm_segmentation.nii.gz  ${refdir}/supplemental_masks/NMT_v2.1_sym_05mm_ventricles.nii.gz \
 -seg_abbrevs SEG VENT \
 -outdir $outdir \
 -ok_to_exist \
 -no_surfaces \
 -echo


exit 
