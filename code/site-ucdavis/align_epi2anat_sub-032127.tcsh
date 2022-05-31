#!/bin/tcsh -xef


# -------------------------------------------------------
# Script for testing alignment in sub-032127
# Cost functions
#		- nmi
#		- hel
#		- mi 
#		- sp 
#		- je 
#		- lss
# - nmi has been the best cost function so far
# 
# 
# -------------------------------------------------------

# Input arguments

set subj = sub-032127 # sub-id
set vr_base = /misc/tezca/reduardo/data/site-ucdavis/align_tests/${subj}/${subj}_01/vr_base_min_outlier+orig.HEAD # add path to base func data if you have one 

# assign source and output directory names
set sourcedir = /misc/hahn2/alfonso/primates/monkeys/data/site-ucdavis
set output_dir = /misc/tezca/reduardo/data/site-ucdavis/align_tests/${subj}/${subj}_05
set overwrite  = 1 # set to 1 if you want to overwrite output_dir if it exists


# set list of runs
set runs = (`count -digits 2 1 1`)


# create results and stimuli directories
if ( $overwrite == 1 ) then
		rm -r $output_dir
endif
mkdir -p $output_dir
#mkdir $output_dir/stimuli

# copy anatomy to results dir
3dcopy                                                                                                   \
    $sourcedir/data_aw/${subj}/${subj}_anat.nii.gz \
    $output_dir/${subj}_anat

3dcopy                                                                                                   \
    $sourcedir/data_aw/${subj}/${subj}_anat_nsu.nii.gz \
    $output_dir/${subj}_anat_nsu

# copy external -tlrc_NL_warped_dsets datasets
3dcopy                                                                                                                        \
    $sourcedir/data_aw/${subj}/${subj}_anat_warp2std_nsu.nii.gz             \
    $output_dir/${subj}_anat_warp2std_nsu
3dcopy                                                                                                                        \
    $sourcedir/data_aw/${subj}/${subj}_anat_composite_linear_to_template.1D \
    $output_dir/${subj}_anat_composite_linear_to_template.1D
3dcopy                                                                                                                        \
    $sourcedir/data_aw/${subj}/${subj}_anat_shft_WARP.nii.gz                \
    $output_dir/${subj}_anat_shft_WARP.nii.gz

set vr_base_exists = 0
if ( -f $vr_base ) then
		3dcopy ${vr_base} \
		$output_dir/vr_base_min_outlier+orig
		set vr_base_exists = 1
endif


# -------------------------------------------------------
# enter the results directory (can begin processing data)
cd $output_dir

if ( $vr_base_exists == 0 ) then

# ============================ auto block: tcat ============================
		# apply 3dTcat to copy input dsets to results dir,
		# while removing the first 2 TRs
		3dTcat -prefix $output_dir/pb00.${subj}.r01.tcat                   \
		    $sourcedir/${subj}/ses-001/func/${subj}_ses-001_task-resting_run-1_bold_unwarped.nii.gz'[2..$]'
		
		# and make note of repetitions (TRs) per run
		set tr_counts = ( 248 )

		# ---------------------------------------------------------
		# data check: compute correlations with spherical ~averages
		@radial_correlate -nfirst 0 -do_clean yes -rdir radcor.pb00.tcat \
		                  -sphere_rad 14                                 \
		                  pb00.$subj.r*.tcat+orig.HEAD
		
		# ========================== auto block: outcount ==========================
		# data check: compute outlier fraction for each volume
		touch out.pre_ss_warn.txt
		foreach run ( $runs )
		    3dToutcount -automask -fraction -polort 3 -legendre                     \
		                pb00.$subj.r$run.tcat+orig > outcount.r$run.1D
		
		    # censor outlier TRs per run, ignoring the first 0 TRs
		    # - censor when more than 0.05 of automask voxels are outliers
		    # - step() defines which TRs to remove via censoring
		    1deval -a outcount.r$run.1D -expr "1-step(a-0.05)" > rm.out.cen.r$run.1D
		
		    # outliers at TR 0 might suggest pre-steady state TRs
		    if ( `1deval -a outcount.r$run.1D"{0}" -expr "step(a-0.4)"` ) then
		        echo "** TR #0 outliers: possible pre-steady state TRs in run $run" \
		            >> out.pre_ss_warn.txt
		    endif
		end
		
		# catenate outlier counts into a single time series
		cat outcount.r*.1D > outcount_rall.1D
		
		# catenate outlier censor files into a single time series
		cat rm.out.cen.r*.1D > outcount_${subj}_censor.1D
		
		# get run number and TR index for minimum outlier volume
		set minindex = `3dTstat -argmin -prefix - outcount_rall.1D\'`
		set ovals = ( `1d_tool.py -set_run_lengths $tr_counts                       \
		                          -index_to_run_tr $minindex` )
		# save run and TR indices for extraction of vr_base_min_outlier
		set minoutrun = $ovals[1]
		set minouttr  = $ovals[2]
		echo "min outlier: run $minoutrun, TR $minouttr" | tee out.min_outlier.txt
		
		# ================================ despike =================================
		# apply 3dDespike to each run
		foreach run ( $runs )
		    3dDespike -NEW -nomask -prefix pb01.$subj.r$run.despike \
		        pb00.$subj.r$run.tcat+orig
		end
		
		# ================================= tshift =================================
		# time shift data so all slice timing is the same 
		foreach run ( $runs )
		    3dTshift -tzero 0 -quintic -prefix pb02.$subj.r$run.tshift \
		             pb01.$subj.r$run.despike+orig
		end
		
		# --------------------------------
		# extract volreg registration base
		3dbucket -prefix vr_base_min_outlier                           \
	    pb02.$subj.r$minoutrun.tshift+orig"[$minouttr]"
		
endif
# ================================= align ==================================
# for e2a: compute anat alignment transformation to EPI registration base
# (new anat will be current ${subj}_anat_nsu+orig)
align_epi_anat.py -anat2epi -anat ${subj}_anat_nsu+orig       \
		-suffix _al                                           \
		-epi vr_base_min_outlier+orig  -epi_base 0            \
		-epi_strip 3dAutomask                                 \
		-anat_has_skull no                                    \
		-cmass nocmass -feature_size 0.5	                  \
		-rigid_body                                           \
		-cost nmi                                             \
		-Allineate_opts -source_automask+2                    \
				-maxscl 1.01                                  \
				-maxshr 0.01                                  \
				-maxshf 1                                     \
		-multi_cost crA crM crU hel ls                        \
		            lpa lpa+ lpa+ZZ lpc lpc+ lpc+ZZ           \
		            mi sp je lss                              \
		-volreg off -tshift off                              
		
# ------------------------------------------------------
# snapshots for quick visualization

@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_crA+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_crM+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_crU+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_hel+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_ls+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lpa+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lpa++orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lpa+ZZ+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lpc+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lpc++orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lpc+ZZ+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_mi+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_sp+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_je+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu_al_lss+orig
@snapshot_volreg vr_base_min_outlier+orig ${subj}_anat_nsu+orig
