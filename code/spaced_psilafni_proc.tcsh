#!/bin/tcsh -xef

# -------------------------------------------------
# STANDARD SCRIPT FOR RUNNING afni_proc.py on the PRIME-DE datasets 
#
# This script is meant to be a starting point for preprocessing
# functional data.
# It contains the standard parameters which might change depending on
# each dataset pecularities and antics (movement, reverse polarity
# data, etc.)
# As you tweak and refine this script for each dataset (or even
# subject), save the modifications on a separate file.
# The goal is to have a psilafni_proc file for each dataset so there's
# a record of what was done on each case.
# 
# -------------------------------------------------

# SET VARIABLES
set subj      = 
set outdir    =  

# IMPORTANT DIRECTORIES
set site      = /misc/hahn2/alfonso/primates/monkeys/data/site-ucdavis # location of dataset
set data_aw   = $site/data_aw/$sub # @animal_warper output directory
set refdir    = /misc/hahn2/reduardo/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm # location of standard template
set container = /misc/purcell/alfonso/tmp/container/afni.sif # location of container
 
# INPUT DATA
set dir_epi    = ${site}/${subj}/ses-001/func
set sub_epi    = ${dir_epi}/func/${subj}_ses-001_task-resting_run-1_bold.nii.gz
set sub_anat   = ${data_aw}/${subj}_anat_nsu.nii.gz
set dsets_warp = ( ${data_aw}/${subj}*_warp2std_nsu.nii.gz               \
                   ${data_aw}/${subj}*_composite_linear_to_template.1D   \
                   ${data_aw}/${subj}*_shft_WARP.nii.gz )
set refvol     = ${refdir}/NMT*_SS.nii.gz

# control variables
set nt_rm         = 4
set blur_size     = 2.0              ### SET APPROPRIATE FOR MACAQUE
set final_dxyz    = 1.25
set cen_motion    = 0.3
set cen_outliers  = 0.05

set cost_func     = lpc
set radcor_rad    = 14
set feat_size     = 0.5
set anat_unif     = no


# ----------------- afni_proc.py -----------------
if ( ! -d ${outdir} ) then 
    mkdir -p ${outdir}
endif

singularity  exec -B /misc:/misc --cleanenv ${container}                     \
afni_proc.py                                                                 \
    -subj_id                  ${subj}                                        \
    -script                   ${outdir}/proc.${subj}                         \
    -scr_overwrite                                                           \
    -out_dir                  $outdir/${subj}.results                        \
    -blocks                   despike tshift align tlrc volreg blur          \
                              mask scale regress                             \
    -dsets                    ${sub_epi}                                     \
    -copy_anat                "${sub_anat}"                                  \
    -anat_has_skull           no                                             \
    -anat_uniform_method      ${anat_unif}                                   \
    -radial_correlate_blocks  tcat volreg                                    \
    -radial_correlate_opts    -sphere_rad ${radcor_rad}                      \
    -tcat_remove_first_trs    ${nt_rm}                                       \
    -volreg_align_to          MIN_OUTLIER                                    \
    -volreg_align_e2a                                                        \
    -volreg_tlrc_warp                                                        \
    -volreg_warp_dxyz         ${final_dxyz}                                  \
    -blur_size                ${blur_size}                                   \
    -align_opts_aea           -cost ${cost_func}                             \
                              -cmass cmass                                   \
                              -feature_size ${feat_size}                     \
    -tlrc_base                ${refvol}                                      \
    -tlrc_NL_warp                                                            \
    -tlrc_NL_warped_dsets     ${dsets_warps}                                 \
    -mask_epi_anat            yes                                            \
    -regress_motion_per_run                                                  \
    -regress_apply_mot_types  demean deriv                                   \
    -regress_censor_motion    ${cen_motion}                                  \
    -regress_censor_outliers  ${cen_outliers}                                \
    -regress_est_blur_errts                                                  \
    -regress_est_blur_epits                                                  \
    -regress_run_clustsim     no                                             \
    -html_review_style        pythonic                                       \
    -execute






