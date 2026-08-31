#!/bin/bash

# ==============================================================================
# Script Name : psilafni_proc.sh
# Language    : BASH
# Description : Automated fMRI preprocessing master pipeline in AFNI for Non-Human
#               Primates (NHP).
#               - Reads optimal alignment parameters from harvested TSV.
#               - Ingests RAW skull-stripped T1w anatomy directly from data_aw.
#               - Forces @Align_Centers and strict 6-DOF (rigid body) registration.
#               - Concatenates native EPI-to-Anat alignment with Animal Warper 
#                 non-linear warps to the NMT standard template in a single step.
#               - Extracts tissue noise masks (WM/CSF) and generates QC overlays.
#               - Computes tSNR maps and exports final residuals to NIfTI (.nii.gz).
#               - Auto-detects HPC (SLURM) vs Local execution for OpenMP threads.
#               - Built-in overwrite protection (requires -f/--force to overwrite).
#
# Usage:
#   ./psilafni_proc.sh -d <site_dir> -s <subj_id> [options]
#   ./psilafni_proc.sh -h
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# 0. SANITY CHECKS & THREAD MANAGEMENT
# ------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] ${message}"
}

if ! command -v afni_proc.py &> /dev/null || ! command -v @chauffeur_afni &> /dev/null; then
    log_msg "ERROR" "Required binaries (afni_proc.py or @chauffeur_afni) not found in PATH."
    exit 1
fi

if [ -n "$SLURM_CPUS_PER_TASK" ]; then
    export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
    log_msg "INFO" "HPC SLURM environment detected. Setting OpenMP threads to $OMP_NUM_THREADS."
else
    local_cores=$(nproc 2>/dev/null || echo 4)
    calc_threads=$((local_cores - 2))
    export OMP_NUM_THREADS=$((calc_threads < 3 ? 3 : calc_threads))
    log_msg "INFO" "Local execution detected. Setting OpenMP threads to $OMP_NUM_THREADS."
fi

# ------------------------------------------------------------------------------
# 1. PARSE INPUT ARGUMENTS
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF

==============================================================================
  PSILAFNI MASTER fMRI PREPROCESSING PIPELINE (v1.0) - HELP
==============================================================================

Description:
  Automates the construction and execution of 'afni_proc.py' for resting-state
  fMRI in non-human primates using benchmark-optimized alignment parameters:
    - Ingests best cost, movement limits, and winner RAW T1w anatomy from TSV.
    - Applies non-linear transformations to NMT template in a single interpolation.
    - Performs ANATICOR local WM and CSF PCA denoising.
    - Default behavior processes all session BOLD runs jointly in a single model.
    - Optional flag isolates runs into separate directories for Fingerprinting.
    - Default behavior protects existing outputs from being overwritten.

Usage:
  $0 -d <site_dir> -s <subj_id> [options]
  $0 -h | --help

Required Arguments:
  -d <path>               : Absolute path to BIDS site root directory
  -s <id>                 : Unique Subject ID (e.g., sub-032198)

Optional Flags:
  -a <path>               : Path to @animal_warper folder (Default: <site_dir>/data_aw)
  -t, --template <path>   : Path to standard template directory (Default: /AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm)
  -ses <str>              : Process a specific session only (e.g., 'ses-001').
                            If omitted, processes all sessions found for subject.
  -sep, --separate_runs   : Process each BOLD run individually (separate folders).
                            Default: concatenates all runs into a joint GLM.
  -motion <float>         : Motion censor limit in mm (Default: 0.30)
  -outlier <float>        : Outlier censor fraction (Default: 0.05)
  -bandpass <fbot ftop>   : Bandpass filtering frequency band (Default: 0.01 0.1)
  -dxyz <float>           : Resampling voxel size in mm for NMT grid (Default: 1.25)
  -f, --force, --overwrite: Overwrite existing output directories.
  -h, --help              : Display this documentation and exit.

==============================================================================
EOF
    exit 0
}

if [ $# -eq 0 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

site_dir=""
subj_id=""
aw_dir=""
template_dir=""
user_ses=""
separate_runs=false
censor_motion="0.30"
censor_outlier="0.05"
bandpass_bot="0.01"
bandpass_top="0.1"
resample_dxyz="1.25"
force_overwrite=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            site_dir="$2"; shift 2 ;;
        -s)
            subj_id="$2"; shift 2 ;;
        -a)
            aw_dir="$2"; shift 2 ;;
        -t|--template)
            template_dir="$2"; shift 2 ;;
        -ses|-p)
            user_ses="$2"; shift 2 ;;
        -sep|--separate_runs)
            separate_runs=true; shift 1 ;;
        -motion)
            censor_motion="$2"; shift 2 ;;
        -outlier)
            censor_outlier="$2"; shift 2 ;;
        -bandpass)
            bandpass_bot="$2"
            bandpass_top="$3"
            shift 3 ;;
        -dxyz)
            resample_dxyz="$2"; shift 2 ;;
        -f|--force|--overwrite)
            force_overwrite=true; shift 1 ;;
        -h|--help)
            show_help ;;
        *)
            echo "[ERROR] Unknown option: $1"
            show_help ;;
    esac
done

if [ -z "$site_dir" ] || [ -z "$subj_id" ]; then
    log_msg "ERROR" "Mandatory flags (-d and -s) are required!"
    show_help
fi

subj_dir="${site_dir}/${subj_id}"
[ -z "$aw_dir" ] && aw_dir="${site_dir}/data_aw"
[ -z "$template_dir" ] && template_dir="/AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm"
aw_subj_dir="${aw_dir}/${subj_id}"

if [ ! -d "$subj_dir" ]; then
    log_msg "ERROR" "Subject directory not found: $subj_dir"; exit 1
fi
if [ ! -d "$aw_subj_dir" ]; then
    log_msg "ERROR" "Animal Warper directory not found: $aw_subj_dir"; exit 1
fi

refvol=$(find "$template_dir" -type f -name "*_SS.nii*" | head -n 1)
if [ -z "$refvol" ]; then
    log_msg "ERROR" "Template skull-stripped volume (*_SS.nii*) not found in $template_dir"
    exit 1
fi

site_name=$(basename "$site_dir")
master_tsv="${site_dir}/align_tests_centered/${site_name}_best_alignment_parameters.tsv"

if [ ! -f "$master_tsv" ]; then
    master_tsv="${site_dir}/align_tests_centered/${subj_id}/master_benchmark_summary.tsv"
fi

if [ ! -f "$master_tsv" ]; then
    log_msg "ERROR" "Benchmark parameters TSV not found at: $master_tsv. Run get_alignment_metrics.sh first."
    exit 1
fi

# Discover Functional Sessions
if [ -n "$user_ses" ]; then
    if [ -d "$subj_dir/$user_ses" ]; then
        func_sessions=("$user_ses")
    else
        log_msg "ERROR" "Specified session '$user_ses' not found in $subj_dir"; exit 1
    fi
else
    mapfile -t func_sessions < <(find "$subj_dir" -mindepth 1 -maxdepth 1 -type d -name "ses-*" -exec basename {} \; | sort)
    if [ ${#func_sessions[@]} -eq 0 ]; then
        func_sessions=("no_ses")
    fi
fi

echo "======================================================================"
echo "          STARTING PSILAFNI PREPROCESSING PIPELINE (v1.0)             "
echo " Subject ID        : $subj_id"
echo " Site Directory    : $site_dir"
echo " AW Directory      : $aw_subj_dir"
echo " Template Base     : $refvol"
echo " Benchmark TSV     : $master_tsv"
echo " Target Sessions   : ${func_sessions[*]}"
echo " Run Mode          : $( [ "$separate_runs" = true ] && echo "SEPARATE RUNS (--separate_runs)" || echo "JOINT RUNS (DEFAULT)" )"
echo " Overwrite Mode    : $( [ "$force_overwrite" = true ] && echo "ENABLED (--force)" || echo "PROTECTED (DEFAULT)" )"
echo " Motion Censoring  : ${censor_motion} mm | Outliers: ${censor_outlier}"
echo " Bandpass Limits   : ${bandpass_bot} - ${bandpass_top} Hz"
echo " NMT Grid Resample : ${resample_dxyz} mm"
echo "======================================================================"

# ==============================================================================
# 2. SESSION EXECUTION LOOP
# ==============================================================================
for f_ses in "${func_sessions[@]}"; do

    if [ "$f_ses" == "no_ses" ]; then
        ses_data_dir="$subj_dir"
        ses_label="ses-001"
    else
        ses_data_dir="$subj_dir/$f_ses"
        ses_label="$f_ses"
    fi

    # 1. Discover Resting-State BOLD runs
    mapfile -t rs_runs < <(find "$ses_data_dir" -type f \( -name "*task-rest*bold*.nii*" -o -name "*task-resting*bold*.nii*" \) ! -name "*fmap*" ! -name "*magnitude*" ! -name "*phasediff*" ! -name "*dir-*" | sort)
    num_runs=${#rs_runs[@]}

    if [ "$num_runs" -eq 0 ]; then
        log_msg "WARNING" "No resting BOLD runs found for session '$f_ses'. Skipping."
        continue
    fi

    # 2. Dynamic Drop of First TRs (~6s steady-state)
    sample_bold="${rs_runs[0]}"
    tr_sec=$(3dinfo -tr "$sample_bold" 2>/dev/null | awk '{print $1}')
    if [ -z "$tr_sec" ] || (( $(echo "$tr_sec <= 0" | bc -l) )); then
        tr_sec="2.0"
        log_msg "WARNING" "Could not read TR from header. Defaulting to 2.0s."
    fi
    drop_trs=$(python3 -c "import math; print(max(2, math.ceil(6.0 / float('$tr_sec'))))")
    log_msg "INFO" "Session TR = ${tr_sec}s. Automatically dropping first ${drop_trs} TRs."

    # 3. Harvest Best Parameters from Harvested 12-Column TSV
    matched_row=$(awk -F'\t' -v s="$subj_id" -v ses="$f_ses" '$1 == s && ($2 == ses || $2 == "no_ses") {print $0}' "$master_tsv" | tr -d '\r' | tail -n 1)

    if [ -z "$matched_row" ]; then
        log_msg "ERROR" "No benchmark entry found for ${subj_id} (${f_ses}) in TSV. Skipping."
        continue
    fi

    # Column mapping: 5:dist_euc 6:active_move 7:active_cmass 8:best_cost 9:best_dice 11:best_anat_path
    active_move=$(echo "$matched_row" | awk -F'\t' '{print $6}')
    active_cmass=$(echo "$matched_row" | awk -F'\t' '{print $7}')
    best_cost=$(echo "$matched_row" | awk -F'\t' '{print $8}')
    raw_anat_path=$(echo "$matched_row" | awk -F'\t' '{print $11}')

    [ "$active_move" == "none" ] && active_move=""
    [ -z "$active_cmass" ] || [ "$active_cmass" == "none" ] && active_cmass="cmass"
    log_msg "SUCCESS" "Harvested params -> Cost: $best_cost | Move: ${active_move:-[DEFAULT]} | CMass: $active_cmass | Anat: $(basename "$raw_anat_path")"

    # 4. Resolve Animal Warper Transformation Matrices and Datasets
    anat_base_dir=$(dirname "$raw_anat_path")
    anat_prefix=$(basename "$raw_anat_path" | sed -E 's/(_nsu.*|\+orig.*)$//')

    aff_1D=$(find "$aw_subj_dir" -type f -name "*${anat_prefix}*composite_linear_to_template.1D" | head -n 1)
    warp_nii=$(find "$aw_subj_dir" -type f \( -name "*${anat_prefix}*shft_WARP.nii.gz" -o -name "*${anat_prefix}*WARP.nii.gz" \) | head -n 1)
    anat_std=$(find "$aw_subj_dir" -type f -name "*${anat_prefix}*warp2std_nsu.nii*" | head -n 1)
    seg_mask=$(find "$aw_subj_dir" -type f -name "SEG_in_*${anat_prefix}*.nii*" | head -n 1)

    if [ -z "$aff_1D" ] || [ -z "$warp_nii" ] || [ -z "$anat_std" ]; then
        log_msg "ERROR" "Missing Animal Warper matrices or warp2std dataset for $anat_prefix. Skipping $f_ses."
        continue
    fi

    # 5. Extract Tissue Masks (WM & CSF) from Animal Warper Segmentation
    wm_mask="${anat_base_dir}/WM_in_${anat_prefix}.nii.gz"
    csf_mask="${anat_base_dir}/CSF_in_${anat_prefix}.nii.gz"

    if [ -n "$seg_mask" ] && [ -f "$seg_mask" ]; then
        log_msg "INFO" "Generating tissue masks and QC snapshots for $anat_prefix..."
        if [ ! -f "$wm_mask" ] || [ "$force_overwrite" = true ]; then
            3dcalc -a "$seg_mask" -expr "within(a,4,4)" -prefix "$wm_mask" -overwrite
        fi
        if [ ! -f "$csf_mask" ] || [ "$force_overwrite" = true ]; then
            3dcalc -a "$seg_mask" -expr "within(a,1,1)" -prefix "$csf_mask" -overwrite
        fi
    fi

    # --------------------------------------------------------------------------
    # EXECUTION MODES: JOINT RUNS vs SEPARATE RUNS
    # --------------------------------------------------------------------------
    if [ "$separate_runs" = false ]; then
        # ======================================================================
        # MODE A: JOINT RUNS (DEFAULT)
        # ======================================================================
        out_base_dir="${site_dir}/data_ap/${subj_id}/${ses_label}/joint_runs"
        results_dir="${out_base_dir}/${subj_id}_${ses_label}_joint.results"
        log_file="${out_base_dir}/proc_${subj_id}_${ses_label}_joint.log"

        if [ -d "$results_dir" ]; then
            if [ "$force_overwrite" = false ]; then
                log_msg "WARNING" "Output directory already exists: $results_dir. Use -f to overwrite. Skipping."
                continue
            else
                log_msg "INFO" "Force overwrite active. Clearing previous results directory..."
                rm -rf "$results_dir"
            fi
        fi

        mkdir -p "$out_base_dir"

        {
            log_msg "START" "Processing JOINT runs for ${subj_id} (${ses_label})..."

            # Generate QC Overlays
            if [ -f "$wm_mask" ] && [ -f "$csf_mask" ]; then
                @chauffeur_afni -ulay "$raw_anat_path" -olay "$wm_mask" -cbar Reds_and_Blues_inv -func_range 1 -opacity 5 -prefix "${out_base_dir}/qc_mask_WM_${anat_prefix}" -save_ftype JPEG 2>/dev/null || true
                @chauffeur_afni -ulay "$raw_anat_path" -olay "$csf_mask" -cbar Reds_and_Blues_inv -func_range 1 -opacity 5 -prefix "${out_base_dir}/qc_mask_CSF_${anat_prefix}" -save_ftype JPEG 2>/dev/null || true
            fi

            align_args=(
                "-cost" "$best_cost"
                "-align_centers" "yes"
                "-cmass" "$active_cmass"
                "-feature_size" "0.5"
            )
            [ -n "$active_move" ] && align_args+=("$active_move")
            align_args+=("-Allineate_opts" "-warp shift_rotate -source_automask+2")

            cmd=(
                afni_proc.py
                -subj_id "${subj_id}_${ses_label}_joint"
                -script "${out_base_dir}/proc.${subj_id}_${ses_label}_joint"
                -scr_overwrite
                -out_dir "$results_dir"
                -blocks despike tshift align tlrc volreg blur mask scale regress
                -dsets "${rs_runs[@]}"
                -copy_anat "$raw_anat_path"
                -anat_has_skull no
                -tcat_remove_first_trs "$drop_trs"
                -volreg_align_to MIN_OUTLIER
                -volreg_align_e2a
                -volreg_tlrc_warp
                -volreg_warp_dxyz "$resample_dxyz"
                -align_opts_aea "${align_args[@]}"
                -tlrc_base "$refvol"
                -tlrc_NL_warp
                -tlrc_NL_warped_dsets "$anat_std" "$aff_1D" "$warp_nii"
                -mask_epi_anat yes
                -blur_size 2.0
                -regress_motion_per_run
                -regress_apply_mot_types demean deriv
                -regress_censor_motion "$censor_motion"
                -regress_censor_outliers "$censor_outlier"
                -regress_bandpass "$bandpass_bot" "$bandpass_top"
                -regress_compute_tsnr yes
                -regress_run_clustsim no
                -html_review_style pythonic
            )

            if [ -f "$wm_mask" ] && [ -f "$csf_mask" ]; then
                cmd+=(
                    -anat_follower_ROI WM_Mask epi "$wm_mask"
                    -anat_follower_ROI CSF_Mask epi "$csf_mask"
                    -anat_follower_erode WM_Mask CSF_Mask
                    -mask_union ANATICOR_Mask CSF_Mask WM_Mask
                    -regress_anaticor_fast
                    -regress_anaticor_label ANATICOR_Mask
                    -regress_ROI_PC WM_Mask 3
                    -regress_ROI_PC CSF_Mask 3
                )
            fi

            "${cmd[@]}" -execute

            # Convert outputs to compressed NIfTI
            if [ -d "$results_dir" ]; then
                cd "$results_dir" || exit 1
                for f in errts.*.fanaticor+tlrc.HEAD errts.*+tlrc.HEAD TSNR.*+tlrc.HEAD; do
                    if [ -f "$f" ]; then
                        nii_out="${f%.HEAD}.nii.gz"
                        3dAFNItoNIFTI -prefix "$nii_out" "$f" -overwrite
                        rm -f "${f%.HEAD}.BRIK"* "${f%.HEAD}.HEAD"*
                    fi
                done
                log_msg "SUCCESS" "Completed joint run processing -> $results_dir"
            fi
        } 2>&1 | tee "$log_file"

    else
        # ======================================================================
        # MODE B: SEPARATE RUNS (--separate_runs) FOR FINGERPRINTING
        # ======================================================================
        r_idx=1
        for run_file in "${rs_runs[@]}"; do
            r_str=$(printf "r%02d" $r_idx)
            out_base_dir="${site_dir}/data_ap/${subj_id}/${ses_label}/separate_runs"
            results_dir="${out_base_dir}/${subj_id}_${ses_label}_${r_str}.results"
            log_file="${out_base_dir}/proc_${subj_id}_${ses_label}_${r_str}.log"

            if [ -d "$results_dir" ]; then
                if [ "$force_overwrite" = false ]; then
                    log_msg "WARNING" "Output directory already exists: $results_dir. Use -f to overwrite. Skipping run."
                    ((r_idx++))
                    continue
                else
                    log_msg "INFO" "Force overwrite active. Clearing previous results directory..."
                    rm -rf "$results_dir"
                fi
            fi

            mkdir -p "$out_base_dir"

            {
                log_msg "START" "Processing SEPARATE run ${r_str} for ${subj_id} (${ses_label})..."

                if [ -f "$wm_mask" ] && [ -f "$csf_mask" ]; then
                    @chauffeur_afni -ulay "$raw_anat_path" -olay "$wm_mask" -cbar Reds_and_Blues_inv -func_range 1 -opacity 5 -prefix "${out_base_dir}/qc_mask_WM_${anat_prefix}" -save_ftype JPEG 2>/dev/null || true
                    @chauffeur_afni -ulay "$raw_anat_path" -olay "$csf_mask" -cbar Reds_and_Blues_inv -func_range 1 -opacity 5 -prefix "${out_base_dir}/qc_mask_CSF_${anat_prefix}" -save_ftype JPEG 2>/dev/null || true
                fi

                align_args=(
                    "-cost" "$best_cost"
                    "-align_centers" "yes"
                    "-cmass" "$active_cmass"
                    "-feature_size" "0.5"
                )
                [ -n "$active_move" ] && align_args+=("$active_move")
                align_args+=("-Allineate_opts" "-warp shift_rotate -source_automask+2")

                cmd=(
                    afni_proc.py
                    -subj_id "${subj_id}_${ses_label}_${r_str}"
                    -script "${out_base_dir}/proc.${subj_id}_${ses_label}_${r_str}"
                    -scr_overwrite
                    -out_dir "$results_dir"
                    -blocks despike tshift align tlrc volreg blur mask scale regress
                    -dsets "$run_file"
                    -copy_anat "$raw_anat_path"
                    -anat_has_skull no
                    -tcat_remove_first_trs "$drop_trs"
                    -volreg_align_to MIN_OUTLIER
                    -volreg_align_e2a
                    -volreg_tlrc_warp
                    -volreg_warp_dxyz "$resample_dxyz"
                    -align_opts_aea "${align_args[@]}"
                    -tlrc_base "$refvol"
                    -tlrc_NL_warp
                    -tlrc_NL_warped_dsets "$anat_std" "$aff_1D" "$warp_nii"
                    -mask_epi_anat yes
                    -blur_size 2.0
                    -regress_motion_per_run
                    -regress_apply_mot_types demean deriv
                    -regress_censor_motion "$censor_motion"
                    -regress_censor_outliers "$censor_outlier"
                    -regress_bandpass "$bandpass_bot" "$bandpass_top"
                    -regress_compute_tsnr yes
                    -regress_run_clustsim no
                    -html_review_style pythonic
                )

                if [ -f "$wm_mask" ] && [ -f "$csf_mask" ]; then
                    cmd+=(
                        -anat_follower_ROI WM_Mask epi "$wm_mask"
                        -anat_follower_ROI CSF_Mask epi "$csf_mask"
                        -anat_follower_erode WM_Mask CSF_Mask
                        -mask_union ANATICOR_Mask CSF_Mask WM_Mask
                        -regress_anaticor_fast
                        -regress_anaticor_label ANATICOR_Mask
                        -regress_ROI_PC WM_Mask 3
                        -regress_ROI_PC CSF_Mask 3
                    )
                fi

                "${cmd[@]}" -execute

                if [ -d "$results_dir" ]; then
                    cd "$results_dir" || exit 1
                    for f in errts.*.fanaticor+tlrc.HEAD errts.*+tlrc.HEAD TSNR.*+tlrc.HEAD; do
                        if [ -f "$f" ]; then
                            nii_out="${f%.HEAD}.nii.gz"
                            3dAFNItoNIFTI -prefix "$nii_out" "$f" -overwrite
                            rm -f "${f%.HEAD}.BRIK"* "${f%.HEAD}.HEAD"*
                        fi
                    done
                    log_msg "SUCCESS" "Completed run processing -> $results_dir"
                fi
            } 2>&1 | tee "$log_file"

            ((r_idx++))
        done
    fi

done

log_msg "SUCCESS" "All requested sessions completed for: $subj_id"
exit 0
