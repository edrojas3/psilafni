#!/bin/tcsh -xef

# -------------------------------------------------
# SCRIPT FOR RUNNING afni_proc.py on site-oxford/sub-032128 
# 
# IMPORTANT DETAILS:
# 1. During aligning test doing `@Aling_Centers -base anat -dset epi` was the best option 
# 2. For @Align_Centers, data was transformed to BRIK
# 3. Local Unifize improved the alignment
# 4. big_move was needed
# 5. lpc+ cost function was selected but another option was hel
# 
# -------------------------------------------------

# SET VARIABLES
set subj      = sub-032176 
set site 	  = /misc/m/mchakrav/afajardo/PRIME-DE/data/site-oxford
set outdir    = $site/data_ap/${subj}

# Most common control variables
set test	      = 1 # if 1, creates a subset of 100 volumes to do a quick afni_proc and see pre-eliminary results. Check lines 57-65 to change output directories
set cost_func     = nmi
set cmass         = cmass
set unif_epi	  = local # no = just don't; local = 3dLocalUnifize; yes = 3dUnifize -T2
set move		  = NA

# IMPORTANT DIRECTORIES
set data_aw   = $site/data_aw/$subj # @animal_warper output directory
set refdir    = /misc/m/mchakrav/afajardo/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm # location of standard template
 
# INPUT DATA
set dir_epi    = ${site}/${subj}/ses-001/func
set sub_epi    = ${dir_epi}/${subj}_ses-001_task-resting_run-1_bold_ac+orig
set sub_anat   = ${data_aw}/${subj}_anat_nsu+orig
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

set radcor_rad   = 14
set feat_size    = 0.5
set anat_unif    = none
set automask_val = 2

# HPC variables
set OMP_NUM_THREADS = 3                                                      


# ---------------- test subset ----------------
# create a subset for testing
# site-oxford data has too many volumes. To run afni_proc.py on the whole data is costly.
# It's better to do the preprocessing on a small subset to see if you're happy with the alignment results.
if ( $test == 1 ) then
		echo "++ Creating a testing set as requested..."
		3dTcat -prefix $dir_epi/${subj}_ses-001_task-resting_run-1_bold_subset \
				${sub_epi}'[0..1599(10)]'

		set sub_epi = $dir_epi/${subj}_ses-001_task-resting_run-1_bold_subset+orig
		set outdir = ${outdir}_test
		echo "++ Done."
endif


if ( ! -d ${outdir} ) then 
    mkdir -p ${outdir}
endif

 
# ----------------- afni_proc.py -----------------
                                                                             
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
    -align_unifize_epi		  ${unif_epi}									 \
    -volreg_align_e2a                                                        \
    -volreg_tlrc_warp                                                        \
    -volreg_warp_dxyz         ${final_dxyz}                                  \
    -blur_size                ${blur_size}                                   \
    -align_opts_aea           -cost ${cost_func}                             \
                              -cmass ${cmass}                                \
                              -feature_size ${feat_size}                     \
						      -Allineate_opts								 \
								      -source_automask+${automask_val}       \
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
