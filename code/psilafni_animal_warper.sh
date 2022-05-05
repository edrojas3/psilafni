#!/bin/bash

# ANATOMICAL REGISTRATION TO STANDARD SPACE (NMT) USING @animal_warper.py

# Process a single subject

# INPUTS
site=$1
subj=$2

# DEFAULTS
outdir=$site/data_aw/$subj
container=/misc/purcell/alfonso/tmp/container/afni.sif

# Get anatomical volume(s)
subj_anat=$(find $site/$subj -type f -name "${subj}*T1*nii*")

# Standard volume location
refdir=/misc/hahn2/reduardo/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm
refvol=$refdir/NMT*_SS.nii.gz
refmask=$refdir/NMT*_brainmask.nii.gz
refmask_ab=MASK

# @animal_warper.py
singularity exec -B /misc:/misc --cleanenv $container @animal_warper \
	-echo \
	-no_surfaces \
	-input ${subj_anat} \
	-input_abbrev ${subj}_anat \
	-base ${refvol} \
	-base_abbrev NMT \
	-atlas_followers ${refdir}/CHARM*.nii.gz ${refdir}/D99*.nii.gz \
	-atlas_abbrevs CHARM D99 \
	-seg_followers $refdir/NMT*_segmentation*.nii.gz $refdir/NMT*_ventricles*.nii.gz \
	-seg_abbrevs SEG VENT \
	-skullstrip  ${refmask} \
	-outdir $outdir \
	-ok_to_exist

echo DONE.
