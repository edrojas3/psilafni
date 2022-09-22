#!/bin/tcsh -xef

# ANATOMICAL REGISTRATION TO STANDARD SPACE (NMT) USING @animal_warper.py

# Process a single subject

# INPUTS
set site = /misc/tezca/reduardo/data/site-oxford
set subj = sub-032171
set outdir = ${site}/data_aw/${subj}


# Get anatomical volume(s)
set subj_anat = `find ${site}/${subj} -type f -name "${subj}*run-1_T1w_N4.nii.gz"`

# Standard volume location
set refdir      = /misc/tezca/reduardo/resources/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm
set refvol      = ${refdir}/NMT*_SS.nii.gz
set refmask     = ${refdir}/NMT*_brainmask.nii.gz
set refmask_ab  = MASK

# @animal_warper.py
@animal_warper                                                               \
    -echo                                                                    \
    -no_surfaces                                                             \
    -input            ${subj_anat}                                           \
    -input_abbrev     ${subj}_anat                                           \
    -base             ${refvol}                                              \
    -base_abbrev      NMT                                                    \
    -atlas_followers  ${refdir}/CHARM*.nii.gz ${refdir}/D99*.nii.gz          \
    -atlas_abbrevs    CHARM D99                                              \
    -seg_followers    ${refdir}/NMT*_segmentation*.nii.gz                    \
                      ${refdir}/NMT*_ventricles*.nii.gz                      \
    -seg_abbrevs      SEG VENT                                               \
    -skullstrip       ${refmask}                                             \
    -outdir           ${outdir}                                              \
    -ok_to_exist

echo "++ DONE."
