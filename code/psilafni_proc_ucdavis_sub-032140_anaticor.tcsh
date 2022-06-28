#!/bin/tcsh -xef

# -------------------------------------------------
# STANDARD SCRIPT FOR RUNNING afni_proc.py on the PRIME-DE datasets 
#
# This script is meant to be a starting point for preprocessing functional data.
# It contains the standard parameters which might change depending on each dataset pecularities and antics (movement, reverse polarity data, etc.) 
# As you tweak and refine this script for each dataset (or even subject), save the modifications on a separate file.  
# The goal is to have a psilafni_proc file for each dataset so there's a record of what was done on each case.
# 
# -------------------------------------------------

# SET VARIABLES
set sub	      = sub-032140
set outdir    =  /mnt/MD1200B/egarza/afajardo/primeDE/site-ucdavis/data_ap/${sub}_anaticor
set cost_func = je

# IMPORTANT DIRECTORIES
set site      = /mnt/MD1200B/egarza/afajardo/primeDE/site-ucdavis # location of dataset
set data_aw   = $site/data_aw/$sub # @animal_warper output directory
set refdir    = /AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm # location of standard template
set SEG_Mask = ${data_aw}/SEG_in_${sub}_anat.nii.gz
set WM_Mask = ${data_aw}/WM_in_${sub}_anat.nii.gz
set CSF_Mask = ${data_aw}/CSF_in_${sub}_anat.nii.gz
#set container = /misc/purcell/alfonso/tmp/container/afni.sif # location of container
 
# INPUT DATA
set sub_epi    = $site/$sub/ses-001/func/${sub}_ses-001_task-resting_run-1_bold.nii.gz
set sub_anat   = $data_aw/${sub}_anat_nsu.nii.gz
set refvol     = $refdir/NMT*_SS.nii.gz

# ---- Calculate  white matter mask from animal warper segmentation
if (! -f $WM_Mask) then
	echo "++ Calculating White Matter Mask:"
	echo 
	3dcalc -a $SEG_Mask -expr "within(a,4,4)" -prefix $WM_Mask
endif

# ----- Calculate CSF mask from animal warper segmentation
if (! -f $CSF_Mask) then
	echo "++ Calculating CSF Mask:"
	echo 
	3dcalc -a $SEG_Mask -expr "within(a,1,1)" -prefix $CSF_Mask
endif


# ----------------- afni_proc.py -----------------
if ( ! -d $outdir ) then 
	mkdir -p $outdir
endif

afni_proc.py \
	-subj_id $sub \
	-script $outdir/proc.$sub -scr_overwrite \
	-out_dir $outdir/${sub}.results \
	-blocks despike tshift align tlrc volreg blur mask scale regress \
	-dsets $sub_epi\
	-copy_anat "${sub_anat}" \
	-anat_has_skull no \
	-anat_uniform_method none \
	-radial_correlate_blocks tcat volreg \
	-radial_correlate_opts -sphere_rad 14 \
	-tcat_remove_first_trs 5 \
	-volreg_align_to MIN_OUTLIER \
	-volreg_align_e2a \
	-volreg_tlrc_warp \
	-volreg_warp_dxyz 1.25 \
	-align_opts_aea -cost ${cost_func} \
	                -cmass cmass -feature_size 0.5 \
	-tlrc_base ${refvol} \
	-tlrc_NL_warp \
	-tlrc_NL_warped_dsets \
	    ${data_aw}/${sub}*_warp2std_nsu.nii.gz \
	    ${data_aw}/${sub}*_composite_linear_to_template.1D \
	    ${data_aw}/${sub}*_shft_WARP.nii.gz \
	-anat_follower_ROI WM_Mask epi  $WM_Mask \
	-anat_follower_ROI CSF_Mask epi $CSF_Mask \
	-anat_follower_erode WM_Mask CSF_Mask \
	-mask_union WM_CSF WM_Mask CSF_Mask \
	-mask_epi_anat yes \
	-regress_motion_per_run \
	-regress_apply_mot_types demean deriv \
	-regress_censor_motion 0.30 \
	-regress_censor_outliers 0.05 \
	-regress_ROI_PC WM_Mask 3 \
	-regress_ROI_PC CSF_Mask 3 \
	-regress_ROI_PC_per_run WM_Mask CSF_Mask \
	-regress_anaticor_fast \
	-regress_anaticor_label WM_CSF \
	-regress_est_blur_errts \
	-regress_est_blur_epits \
	-regress_run_clustsim no \
	-html_review_style pythonic \
	-remove_preproc_files \
	-execute
