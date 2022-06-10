#!/bin/tcsh -xef

# -------------------------------------------------
# SCRIPT FOR RUNNING afni_proc.py on site-ucdavis datasets
# Details of this dataset
# - reverse polarity data: adds blip_forward/blip_reverse dsets to afni_proc
# - for some subjects the epi2anat alignment goes better using the same transformation matrix for anat2standard
#	-data_aw/sub-id/sub-id_anat_composite_linear_to_template.1D
# -------------------------------------------------

# SET VARIABLES
set sub	      = sub-032136
set cost_func = mi

# IMPORTANT DIRECTORIES
set site      = /mnt/MD1200B/egarza/afajardo/primeDE/site-ucdavis # location of dataset
set data_aw   = $site/data_aw/$sub # @animal_warper output directory
set refdir    = /AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm # location of standard template
# set container = /misc/purcell/alfonso/tmp/container/afni.sif # location of container
set outdir    = ${site}/data_ap/$sub 
 
# INPUT DATA
set sub_epi    = ${site}/$sub/ses-001/func/${sub}_ses-001_task-resting_run-1_bold.nii.gz
set sub_epirev = ${site}/$sub/ses-001/func/${sub}_ses-001_task-resting_acq-RevPol_run-1_bold.nii.gz
set sub_anat   = $data_aw/${sub}_anat_nsu.nii.gz
set refvol     = ${refdir}/NMT_v2.1_sym_05mm_SS.nii.gz

# set this variable configure the number of threads to use
set OMP_NUM_THREADS = 4

echo $sub_anat
echo $sub_epi

echo
echo
# ----------------- afni_proc.py -----------------
if ( ! -d $outdir ) then 
	mkdir -p $outdir
endif

         afni_proc.py \
	-subj_id $sub \
	-script $outdir/proc.$sub -scr_overwrite \
	-out_dir $outdir/${sub}.results \
	-blocks despike tshift align tlrc volreg blur mask scale regress \
	-dsets $sub_epi \
	-blip_forward_dset $sub_epi \
	-blip_reverse_dset $sub_epirev \
	-copy_anat "${sub_anat}" \
	-anat_has_skull no \
	-anat_uniform_method none \
	-radial_correlate_blocks tcat volreg \
	-radial_correlate_opts -sphere_rad 14 \
	-tcat_remove_first_trs 2 \
	-volreg_align_to MIN_OUTLIER \
	-volreg_align_e2a \
	-volreg_tlrc_warp \
	-volreg_warp_dxyz 1.25 \
	-align_opts_aea -cost ${cost_func} \
	                -cmass nocmass -feature_size 0.5 \
	-tlrc_base ${refvol} \
	-tlrc_NL_warp \
	-tlrc_NL_warped_dsets \
	    ${data_aw}/${sub}*_warp2std_nsu.nii.gz \
	    ${data_aw}/${sub}*_composite_linear_to_template.1D \
	    ${data_aw}/${sub}*_shft_WARP.nii.gz \
	-mask_epi_anat yes \
	-regress_motion_per_run \
	-regress_apply_mot_types demean deriv \
	-regress_censor_motion 0.30 \
	-regress_censor_outliers 0.05 \
	-regress_est_blur_errts \
	-regress_est_blur_epits \
	-regress_run_clustsim no \
	-html_review_style pythonic \
	-execute

exit

