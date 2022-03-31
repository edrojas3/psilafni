#!/bin/bash

help ()
{
	echo " 
Functional preprocessing with afni_proc.py WITHOUT VOXEL SMOOTHING. If you like it smooth, try nhp-chmx_afni_proc_ap_vox.sh
       	
USAGE: $(basename $0) <-S site_directory> <-s subject_id> [options];

MNADATORY INPUTS:
		-S: /path/to/site-directory
		-s: subject id. Ex. sub-032202

OPTIONAL INPUTS
		-h: print help
		-w: path to animal_warper results directory. Default = specified/site-directory/data_aw
		-o: Output directory. DEFAULT: s/data_ap. If the output directory doesn't exist, the script will create one. The script also creates a folder inside of the output directory named as the subject id. All the afni_proc.py outputs will be saved in this data_ap/sub-id path. 
		-r: NMT_v2 path. DEFAULT:/misc/tezca/reduardo/resources/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm. Inside of this folder a NMT*SS.nii.gz must exxist.
		-c: AFNI container directory. DEFAULT:/misc/purcell/alfonso/tmp/container/afni.sif.

Example: use afni_proc.py to preprocess the functional data of sub-032202 of site-blah and save the output in another folder/data_ap.
$(basename $0) -S site-blah -s sub-032202 -w site-blah/data_aw -o other_folder/data_ap
       	 
NOTES
		- The cost function is fixed at lpc+zz.

	 "

}

# SOME DEFAULTS
refdir=/misc/hahn2/reduardo/atlases_and_templates/NMT_v2.0_sym/NMT_v2.0_sym_05mm
container=/misc/purcell/alfonso/tmp/container/afni.sif
cost_func='lpc+ZZ'
multruns=0

# OPTIONS
while getopts "S:s:r:o:c:w:mh" opt; do
	case ${opt} in
		S) site=${OPTARG};;
                s) s=${OPTARG};;
                r) refdir=${OPTARG};;
                o) outdir=${OPTARG};;
                c) container=${OPTARG};;
		w) data_aw=${OPTARG};;
		m) multruns=1;;
                h) help
                   exit
                   ;;
                \?) help
                    exit
                    ;;
    esac
done

SECONDS=0

if [ "$#" -eq 0 ]; then help; exit 0; fi

# DEFAULTS FOR ANIMAL_WARPER INPUTS AND OUTPUT DIRECTORY
if [ -z $data_aw ]; then data_aw=$site/data_aw; fi
if [ -z $outdir ]; then outdir=$site/data_ap; fi


echo "Checking if everything is in it's right place"
refvol=$refdir/NMT*_SS.nii.gz
s_epi=($(find $site/$s -type f -name "*bold_bet.nii.gz" | sort -V))
s_anat=$(ls $data_aw/${s}/*_nsu.* | grep -v "_warp2std")


if [ ! -d $refdir ]; then echo "No reference $ref found." ; exit 1; fi
if [ ! -d $site ]; then echo "No site with name $site found."; exit 1; fi
if [ ! -d $site/$s ]; then echo "No subject with id $s found in $site."; exit 1; fi
if [ ! -d $data_aw ]; then echo "No folder $data_aw for @animal_warper output found for $s"; exit 1; fi
if [ -z $s_anat ]; then echo "No $s anatomical volume found."; exit 1; fi
if [ ${#s_epi} -eq 0 ]; then echo "No functional data found."; exit 1; fi

if [ ! -d $outdir/$s ]; then mkdir -p $outdir/$s; fi

# afni_proc.py using all runs
if [ $multruns -eq 0 ]; then

	echo "Enter the singularity..."
	echo "Preprocessing witn afni_proc.py"
	singularity exec -B /misc:/misc --cleanenv $container afni_proc.py \
		-subj_id $s \
		-script $outdir/$s/proc.$s -scr_overwrite \
		-out_dir $outdir/$s/$s.results \
		-blocks despike tshift align tlrc volreg blur mask scale regress \
		-dsets ${s_epi[@]} \
		-copy_anat "${s_anat}" \
		-anat_has_skull no \
		-anat_uniform_method none \
		-radial_correlate_blocks tcat volreg \
		-radial_correlate_opts -sphere_rad 14 \
		-tcat_remove_first_trs 2 \
		-volreg_align_to MIN_OUTLIER \
		-volreg_align_e2a \
		-volreg_tlrc_warp \
		-volreg_warp_dxyz 1.25 \
		-align_opts_aea -cost ${cost_func} -giant_move \
		                -cmass cmass -feature_size 0.5 \
		-tlrc_base ${refvol} \
		-tlrc_NL_warp \
		-tlrc_NL_warped_dsets \
		    ${data_aw}/$s/${s}*_warp2std_nsu.nii.gz \
		    ${data_aw}/$s/${s}*_composite_linear_to_template.1D \
		    ${data_aw}/$s/${s}*_shft_WARP.nii.gz \
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
	
	echo "Done."
	
	echo "Converting errts.$s.tproject+tlrc to NIFTI because who uses BRIK?"
	singularity exec -B /misc:/misc --cleanenv $container 3dAFNItoNIFTI \
		-prefix $outdir/$s/$s.results/errts.$s.tproject+tlrc.nii.gz \
		$outdir/$s/$s.results/errts.$s.tproject+tlrc.
	
	echo "This is the end my friend."

else # afni_proc.py for each run

	for epi in ${s_epi[@]}; do

		base=$(basename $epi)
		ses=$(echo $base | cut -d_ -f2)
		run=$(echo $base | cut -d_ -f4)

		echo "Enter the singularity..."
		echo "Preprocessing witn afni_proc.py"
		singularity exec -B /misc:/misc --cleanenv $container afni_proc.py \
			-subj_id $s \
			-script $outdir/$s/proc.${s}_${ses}_${run} -scr_overwrite \
			-out_dir $outdir/$s/${s}_${ses}_${run}.results \
			-blocks despike tshift align tlrc volreg blur mask scale regress \
			-dsets $epi \
			-copy_anat "${s_anat}" \
			-anat_has_skull no \
			-anat_uniform_method none \
			-radial_correlate_blocks tcat volreg \
			-radial_correlate_opts -sphere_rad 14 \
			-tcat_remove_first_trs 2 \
			-volreg_align_to MIN_OUTLIER \
			-volreg_align_e2a \
			-volreg_tlrc_warp \
			-volreg_warp_dxyz 1.25 \
			-align_opts_aea -cost ${cost_func} -giant_move -check_flip \
			                -cmass cmass -feature_size 0.5 \
			-tlrc_base ${refvol} \
			-tlrc_NL_warp \
			-tlrc_NL_warped_dsets \
			    ${data_aw}/$s/${s}*_warp2std_nsu.nii.gz \
			    ${data_aw}/$s/${s}*_composite_linear_to_template.1D \
			    ${data_aw}/$s/${s}*_shft_WARP.nii.gz \
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
		
		echo "Done..."
		
		echo "Converting errts.$s.tproject+tlrc to NIFTI. "
		singularity exec -B /misc:/misc --cleanenv $container 3dAFNItoNIFTI \
			-prefix $outdir/$s/${s}_${ses}_${run}.results/errts.$s.tproject+tlrc.nii.gz \
			$outdir/$s/${s}_${ses}_${run}.results/errts.$s.tproject+tlrc.
		
		echo "This is the end my friend."
		
	done

fi
