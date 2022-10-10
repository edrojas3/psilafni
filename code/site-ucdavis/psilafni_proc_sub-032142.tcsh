#!/bin/tcsh -xef

# -------------------------------------------------
# SCRIPT FOR RUNNING afni_proc.py on site-ucdavis/sub-032128 
# 
# IMPORTANT DETAILS:
# 1. Raw anat and epi match almost exactly
# 2. No cmass. If included, it shifts the volumes a lot
# 3. Only rigid_body transformations
# 4. lpc cost function was the best
# 
# -------------------------------------------------

# SET VARIABLES
set subj      = sub-032142 

# IMPORTANT DIRECTORIES

## Clusterio
#set site      = /misc/hahn2/alfonso/primates/monkeys/data/site-ucdavis # location of dataset
#set data_aw   = $site/data_aw/$subj # @animal_warper output directory
#set outdir    = /misc/tezca/reduardo/data/site-ucdavis/data_ap/${subj}_test
#set refdir    = /misc/hahn2/reduardo/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm # location of standard template
 
## Niagara
set site      = /misc/m/mchakrav/afajardo/PRIME-DE/data/site-ucdavis # location of dataset
set data_aw   = $site/data_aw/$subj # @animal_warper output directory
set outdir    = $site/data_ap/${subj}
set refdir    = /misc/m/mchakrav/afajardo/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm # location of standard template

# INPUT DATA
set dir_epi    = ${site}/${subj}/ses-001/func
set sub_epi    = ${dir_epi}/${subj}_ses-001_task-resting_run-1_bold.nii.gz
set sub_epirev = ${dir_epi}/${subj}_ses-001_task-resting_acq-RevPol_run-1_bold.nii.gz
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

set cmass        = nocmass
set cost_func    = mi
set radcor_rad   = 14
set feat_size    = 0.5
set anat_unif    = none
set unif_epi	 = yes # no: self explanatory; local: use 3dLocalUnifize (T1); yes: use 3dUnifize -T2
set automask_val = 2

# HPC variables
set OMP_NUM_THREADS = 3                                                      

# ----------------- afni_proc.py -----------------
if ( ! -d ${outdir} ) then 
    mkdir -p ${outdir}
endif
                                                                             
afni_proc.py                                                                 \
    -subj_id                  ${subj}                                        \
    -script                   ${outdir}/proc.${subj}                         \
    -scr_overwrite                                                           \
    -out_dir                  $outdir/${subj}.results                        \
    -blocks                   despike tshift align tlrc volreg blur          \
                              mask scale regress                             \
    -dsets                    ${sub_epi}                                     \
    -blip_forward_dset		  ${sub_epi}                                     \
    -blip_reverse_dset		  ${sub_epirev}                                  \
    -copy_anat                "${sub_anat}"                                  \
    -anat_has_skull           no                                             \
    -anat_uniform_method      ${anat_unif}                                   \
    -radial_correlate_blocks  tcat volreg                                    \
    -radial_correlate_opts    -sphere_rad ${radcor_rad}                      \
    -tcat_remove_first_trs    ${nt_rm}                                       \
    -volreg_align_to          MIN_OUTLIER                                    \
    -align_unifize_epi		  ${unif_epi}									 \
    -volreg_align_e2a                                                        \
    -volreg_tlrc_warp                                                        \
    -volreg_warp_dxyz         ${final_dxyz}                                  \
    -blur_size                ${blur_size}                                   \
    -align_opts_aea           -cost ${cost_func}                             \
                              -cmass ${cmass}                                \
						      -rigid_body									 \
                              -feature_size ${feat_size}                     \
						      -Allineate_opts								 \
									  -smallrange                            \
								      -source_automask+${automask_val}       \
								      -maxshf 1.0                            \
								      -maxscl 1.5                            \
    -tlrc_base                ${refvol}                                      \
    -tlrc_NL_warp                                                            \
    -tlrc_NL_warped_dsets     ${dsets_warp}									 \
    -mask_epi_anat            yes                                            \
    -regress_motion_per_run                                                  \
    -regress_apply_mot_types  demean deriv                                   \
    -regress_censor_motion    ${cen_motion}                                  \
    -regress_censor_outliers  ${cen_outliers}                                \
    -regress_est_blur_errts                                                  \
    -regress_est_blur_epits                                                  \
    -regress_run_clustsim     no                                             \
    -remove_preproc_files                                                    \
    -html_review_style        pythonic                                       \
    -execute
