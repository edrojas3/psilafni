#!/bin/bash

# ==============================================================================
# Script Name : psilafni_proc.sh
# Language    : BASH
# Description : Automated fMRI preprocessing master pipeline in AFNI for NHP.
#               - Dynamically reads optimal alignment parameters from TSV.
#               - Pre-unwarps 4D BOLD runs using FSL 'fugue' if fieldmap is active.
#               - Forces @Align_Centers and strict 6-DOF (rigid body) alignment.
#               - Extracts tissue noise masks (WM/CSF) and generates QC overlays.
#               - Auto-detects HPC (SLURM) vs Local execution for OpenMP threads.
#               - Built-in overwrite protection (requires -f/--force to overwrite).
# ==============================================================================

set -eo pipefail

# ------------------------------------------------------------------------------
# 0. SANITY CHECKS & THREAD MANAGEMENT
# ------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    local message="$2"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level}] ${message}"
}

if ! command -v afni_proc.py &> /dev/null || ! command -v @chauffeur_afni &> /dev/null || ! command -v fugue &> /dev/null; then
    log_msg "ERROR" "Required binaries (AFNI, @chauffeur_afni, or FSL fugue) not found in PATH."
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
  PSILAFNI MASTER fMRI PREPROCESSING PIPELINE (v1.0)
==============================================================================
Usage: $0 -d <site_dir> -s <subj_id> [options]

Required:
  -d <path>               : Absolute path to BIDS site root directory
  -s <id>                 : Unique Subject ID (e.g., sub-032198)

Optional:
  -a <path>               : Path to @animal_warper folder (Default: <site_dir>/data_aw)
  -t, --template <path>   : Path to standard template directory (Default: /AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm)
  -ses <str>              : Process a specific session only (e.g., 'ses-001')
  -sep, --separate_runs   : Process each BOLD run individually (for Fingerprinting)
  -f, --force             : Overwrite existing output directories
  -h, --help              : Display this documentation and exit
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
user_ses=""
template_dir=""
separate_runs=false
force_overwrite=false
censor_motion="0.30"
censor_outlier="0.05"
bandpass_bot="0.01"
bandpass_top="0.1"
resample_dxyz="1.25"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) site_dir="$2"; shift 2 ;;
        -s) subj_id="$2"; shift 2 ;;
        -a) aw_dir="$2"; shift 2 ;;
        -t|--template) template_dir="$2"; shift 2 ;;
        -ses|-p) user_ses="$2"; shift 2 ;;
        -sep|--separate_runs) separate_runs=true; shift 1 ;;
        -f|--force|--overwrite) force_overwrite=true; shift 1 ;;
        *) shift 1 ;;
    esac
done

if [ -z "$site_dir" ] || [ -z "$subj_id" ]; then
    log_msg "ERROR" "Missing mandatory flags (-d and -s)"
    show_help
fi

[ -z "$aw_dir" ] && aw_dir="${site_dir}/data_aw"
[ -z "$template_dir" ] && template_dir="/AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm"

refvol=$(find "$template_dir" -type f -name "*_SS.nii*" | head -n 1)
if [ -z "$refvol" ]; then
    log_msg "ERROR" "Template skull-stripped volume (*_SS.nii*) not found in $template_dir"
    exit 1
fi

subj_dir="${site_dir}/${subj_id}"
aw_subj_dir="${aw_dir}/${subj_id}"

if [ ! -d "$subj_dir" ]; then
    log_msg "ERROR" "Subject directory not found: $subj_dir"
    exit 1
fi

if [ ! -d "$aw_subj_dir" ]; then
    log_msg "ERROR" "Animal Warper directory not found: $aw_subj_dir"
    exit 1
fi

site_name=$(basename "$site_dir")
master_tsv="${site_dir}/align_tests_centered/${site_name}_best_alignment_parameters.tsv"

if [ ! -f "$master_tsv" ]; then
    log_msg "ERROR" "Master benchmark TSV not found: $master_tsv. Please run get_alignment_metrics.sh first."
    exit 1
fi

if [ -n "$user_ses" ]; then
    func_sessions=("$user_ses")
else
    mapfile -t func_sessions < <(find "$subj_dir" -mindepth 1 -maxdepth 1 -type d -name "ses-*" -exec basename {} \; | sort)
    [ ${#func_sessions[@]} -eq 0 ] && func_sessions=("no_ses")
fi

echo "======================================================================"
echo "          STARTING PSILAFNI PREPROCESSING PIPELINE (v1.0)             "
echo " Subject ID        : $subj_id"
echo " Site Directory    : $site_dir"
echo " Template Base     : $refvol"
echo " Benchmark TSV     : $master_tsv"
echo " Run Mode          : $( [ "$separate_runs" = true ] && echo "SEPARATE RUNS" || echo "JOINT RUNS (DEFAULT)" )"
echo "======================================================================"

# ==============================================================================
# 2. CORE SESSION PROCESSING FUNCTION
# ==============================================================================
process_session() {
    local f_ses="$1"
    
    log_msg "START" "Processing session ${f_ses} for subject ${subj_id}..."

    local ses_data_dir="${subj_dir}/${f_ses}"
    [ "$f_ses" == "no_ses" ] && ses_data_dir="$subj_dir"

    local out_base_dir="${site_dir}/data_ap/${subj_id}/${f_ses}/$([ "$separate_runs" = true ] && echo "separate_runs" || echo "joint_runs")"
    mkdir -p "$out_base_dir"

    # Locate Resting BOLD Runs
    mapfile -t rs_runs < <(find "$ses_data_dir" -type f \( -name "*task-rest*bold*.nii*" -o -name "*task-resting*bold*.nii*" \) ! -name "*fmap*" ! -name "*magnitude*" ! -name "*phasediff*" ! -name "*dir-*" | sort)

    if [ ${#rs_runs[@]} -eq 0 ]; then
        log_msg "WARNING" "No resting BOLD runs found for session $f_ses. Skipping."
        return 0
    fi

    # 3. HARVEST BENCHMARK PARAMETERS FROM TSV
    local matched_row
    matched_row=$(awk -F'\t' -v s="$subj_id" -v ses="$f_ses" '$1 == s && $2 == ses {print $0}' "$master_tsv" | tr -d '\r' | tail -n 1)

    if [ -z "$matched_row" ]; then
        log_msg "ERROR" "No benchmark entry found for ${subj_id} (${f_ses}) in TSV. Skipping."
        return 0
    fi

    local fmap_applied=$(echo "$matched_row" | awk -F'\t' '{print $4}')
    local active_move=$(echo "$matched_row" | awk -F'\t' '{print $6}')
    local active_cmass=$(echo "$matched_row" | awk -F'\t' '{print $7}')
    local best_cost=$(echo "$matched_row" | awk -F'\t' '{print $8}')
    local dwell_time=$(echo "$matched_row" | awk -F'\t' '{print $10}')
    local raw_anat_path=$(echo "$matched_row" | awk -F'\t' '{print $11}')
    local fmap_path=$(echo "$matched_row" | awk -F'\t' '{print $12}')

    [ "$active_move" == "none" ] && active_move=""
    [ -z "$dwell_time" ] && dwell_time="0.0006500"
    log_msg "INFO" "Harvested Params -> Cost: $best_cost | Move: ${active_move:-default} | CMass: $active_cmass | Fmap: $fmap_applied"

    # 4. Resolve Animal Warper Matrices (and Standard Space Anatomy)
    local anat_base_dir=$(dirname "$raw_anat_path")
    local anat_prefix=$(basename "$raw_anat_path" | sed -E 's/(_nsu.*|\+orig.*)$//')
    
    local aff_1D=$(find "$aw_subj_dir" -type f -name "*${anat_prefix}*composite_linear_to_template.1D" | head -n 1)
    local warp_nii=$(find "$aw_subj_dir" -type f \( -name "*${anat_prefix}*shft_WARP.nii.gz" -o -name "*${anat_prefix}*WARP.nii.gz" \) | head -n 1)
    local anat_std=$(find "$aw_subj_dir" -type f -name "*${anat_prefix}*warp2std_nsu.nii*" | head -n 1)
    local seg_mask=$(find "$aw_subj_dir" -type f -name "SEG_in_*${anat_prefix}*.nii*" | head -n 1)

    if [ -z "$aff_1D" ] || [ -z "$warp_nii" ] || [ -z "$anat_std" ]; then
        log_msg "ERROR" "Missing Animal Warper matrices or warp2std anatomy for $anat_prefix. Skipping."
        return 0
    fi

    # 5. TISSUE MASK EXTRACTION & QC
    local wm_mask="${anat_base_dir}/WM_in_${anat_prefix}.nii.gz"
    local csf_mask="${anat_base_dir}/CSF_in_${anat_prefix}.nii.gz"

    if [ -n "$seg_mask" ] && [ -f "$seg_mask" ]; then
        log_msg "INFO" "Extracting tissue masks (WM/CSF) and generating QC overlays..."
        if [ ! -f "$wm_mask" ] || [ "$force_overwrite" = true ]; then
            3dcalc -a "$seg_mask" -expr "within(a,4,4)" -prefix "$wm_mask" -overwrite
        fi
        if [ ! -f "$csf_mask" ] || [ "$force_overwrite" = true ]; then
            3dcalc -a "$seg_mask" -expr "within(a,1,1)" -prefix "$csf_mask" -overwrite
        fi

        @chauffeur_afni -ulay "$raw_anat_path" -olay "$wm_mask" -cbar Reds_and_Blues_inv -func_range 1 -opacity 5 -prefix "${out_base_dir}/qc_mask_WM_${anat_prefix}" -save_ftype JPEG 2>/dev/null
        @chauffeur_afni -ulay "$raw_anat_path" -olay "$csf_mask" -cbar Reds_and_Blues_inv -func_range 1 -opacity 5 -prefix "${out_base_dir}/qc_mask_CSF_${anat_prefix}" -save_ftype JPEG 2>/dev/null
    fi

    # 6. OPTION A: PRE-PROCESSING BOLD RUNS WITH FSL FUGUE
    local processed_runs=()
    local temp_fmap_dir="${out_base_dir}/_temp_unwarped"
    mkdir -p "$temp_fmap_dir"

    for run_file in "${rs_runs[@]}"; do
        local r_name=$(basename "$run_file")
        local clean_name="${r_name%.nii*}.nii.gz"
        local out_unwarped="${temp_fmap_dir}/unwarped_${clean_name}"

        if [ "$fmap_applied" == "true" ] && [ -f "$fmap_path" ] && [ "$fmap_path" != "none" ]; then
            log_msg "INFO" "Applying FSL fugue unwarping to $r_name..."
            3dcopy "$run_file" "${temp_fmap_dir}/temp_in.nii.gz" -overwrite

            if fugue -i "${temp_fmap_dir}/temp_in.nii.gz" \
                     --dwell="$dwell_time" \
                     --loadfmap="$fmap_path" \
                     -u "$out_unwarped"; then
                processed_runs+=("$out_unwarped")
                log_msg "SUCCESS" "Unwarped run ready: $out_unwarped"
            else
                log_msg "WARNING" "Fugue failed for $r_name. Falling back to original raw run."
                processed_runs+=("$run_file")
            fi
            rm -f "${temp_fmap_dir}/temp_in.nii.gz"
        else
            processed_runs+=("$run_file")
        fi
    done

    # 7. AFNI_PROC.PY CONSTRUCTION & EXECUTION
    log_msg "START" "Building afni_proc.py command for ${subj_id} (${f_ses})..."

    local align_args=("-cost" "$best_cost" "-cmass" "$active_cmass" "-feature_size" "0.5")
    [ -n "$active_move" ] && align_args+=("$active_move")
    align_args+=("-align_centers" "yes" "-Allineate_opts" "-warp shift_rotate -source_automask+2")

    local dset_array=("${processed_runs[@]}")
    local run_label="joint"

    if [ "$separate_runs" = true ]; then
        dset_array=("${processed_runs[0]}")
        run_label="r01"
    fi

    local results_dir="${out_base_dir}/${subj_id}_${f_ses}_${run_label}.results"

    if [ -d "$results_dir" ] && [ "$force_overwrite" = false ]; then
        log_msg "WARNING" "Output directory already exists: $results_dir. Use -f to overwrite. Skipping."
        return 0
    fi

    local cmd=(
        afni_proc.py
        -subj_id "${subj_id}_${f_ses}_${run_label}"
        -script "${out_base_dir}/proc.${subj_id}_${f_ses}_${run_label}"
        -scr_overwrite
        -out_dir "$results_dir"
        -blocks despike tshift align tlrc volreg blur mask scale regress
        -dsets "${dset_array[@]}"
        -copy_anat "$raw_anat_path"
        -anat_has_skull no
        -tcat_remove_first_trs 2
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

    # Execute Pipeline
    "${cmd[@]}" -execute

    # Cleanup temporary fugue unwarped runs to save disk space
    rm -rf "$temp_fmap_dir"

    log_msg "SUCCESS" "Successfully completed preprocessing for ${subj_id} (${f_ses})"
    return 0
}

# ==============================================================================
# 3. LOOP OVER SESSIONS AND REDIRECT LOG
# ==============================================================================
for f_ses in "${func_sessions[@]}"; do
    
    out_base_dir="${site_dir}/data_ap/${subj_id}/${f_ses}/$([ "$separate_runs" = true ] && echo "separate_runs" || echo "joint_runs")"
    mkdir -p "$out_base_dir"
    log_file="${out_base_dir}/proc_${subj_id}_${f_ses}.log"
    
    # Process session and safely tee to log without trapping subshell commands
    process_session "$f_ses" 2>&1 | tee "$log_file"

done

log_msg "SUCCESS" "All requested sessions completed for: $subj_id"
exit 0
