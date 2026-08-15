#!/bin/bash

# ==============================================================================
# Script Name : align_epi2anat_benchmark.sh
# Language    : BASH
# Description : Multi-session benchmarking script for EPI-to-Anatomical 
#               alignment in AFNI for Non-Human Primates (NHP).
#               - Pre-centers anatomy with @Align_Centers.
#               - Evaluates multiple cost functions in rigid-body (6 DOF).
#               - Resamples masks to functional grid and computes Dice rankings.
#               - Automatically executes @AddEdge on top-ranked cost functions.
#
# Usage:
#   ./align_epi2anat_benchmark.sh -d <site_dir> -s <subj_id> -a <aw_dir> [-ses <session_str>]
#   ./align_epi2anat_benchmark.sh -h
# ==============================================================================

show_help() {
    cat << EOF

==============================================================================
  MULTI-SESSION ALIGNMENT BENCHMARKING (EPI -> ANAT) - HELP
==============================================================================

Description:
  Automates multi-cost function testing per session for NHP fMRI in AFNI:
    - Auto-detects all 'ses-*' directories (or runs single-session if no 'ses-*').
    - Pairs session-specific @animal_warper anatomy (_nsu).
    - Summarizes session functional and anatomical inputs.
    - Calculates the global minimum outlier base TR across runs.
    - Pre-aligns anatomical centers with EPI base using @Align_Centers.
    - Runs 'align_epi_anat.py' with -multi_cost in rigid-body mode (6 DOF).
    - Resamples masks and computes automated Dice spatial overlap ranking.
    - Runs '@AddEdge' automatically on the top 3 alignment candidates.
    - Saves a complete execution log inside each session directory.

Usage:
  $0 -d <site_dir> -s <subj_id> -a <aw_dir> [-ses <session_string>]
  $0 -h

Required Flags:
  -d <path> : Absolute path to BIDS site directory (e.g., /path/to/site-ion)
  -s <id>   : Unique subject ID (e.g., sub-032198)
  -a <path> : Absolute path to @animal_warper directory for the site
              (e.g., /path/to/site-ion/data_aw)

Optional Flags:
  -ses <str>: Target a specific session only (e.g., 'ses-001').
              If omitted, ALL sessions found for the subject will be processed.
  -h, --help: Display this help message and exit.

==============================================================================
EOF
    exit 0
}

# Check help
if [ $# -eq 0 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

site_dir=""
subj_id=""
aw_dir=""
user_ses=""

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            site_dir="$2"
            shift 2
            ;;
        -s)
            subj_id="$2"
            shift 2
            ;;
        -a)
            aw_dir="$2"
            shift 2
            ;;
        -ses|-p)
            user_ses="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            show_help
            ;;
    esac
done

# Validate compulsory arguments
if [ -z "$site_dir" ] || [ -z "$subj_id" ] || [ -z "$aw_dir" ]; then
    echo -e "\n[ERROR] Missing mandatory flags (-d, -s, -a are required)!"
    show_help
fi

subj_dir="$site_dir/$subj_id"
aw_subj_dir="$aw_dir/$subj_id"

if [ ! -d "$subj_dir" ]; then
    echo "[ERROR] Subject directory not found: $subj_dir"
    exit 1
fi

if [ ! -d "$aw_subj_dir" ]; then
    echo "[ERROR] Subject Animal Warper folder not found: $aw_subj_dir"
    exit 1
fi

# ------------------------------------------------------------------------------
# DISCOVER SESSIONS
# ------------------------------------------------------------------------------
sessions=()

if [ -n "$user_ses" ]; then
    if [ -d "$subj_dir/$user_ses" ]; then
        sessions+=("$user_ses")
    else
        echo "[ERROR] Specified session '$user_ses' does not exist in $subj_dir"
        exit 1
    fi
else
    while IFS= read -r s_path; do
        [ -n "$s_path" ] && sessions+=("$(basename "$s_path")")
    done < <(find "$subj_dir" -mindepth 1 -maxdepth 1 -type d -name "ses-*" | sort)

    if [ ${#sessions[@]} -eq 0 ]; then
        sessions+=("no_ses")
    fi
fi

echo "=================================================="
echo " STARTING MULTI-SESSION BENCHMARK FOR: $subj_id"
echo " Site Directory     : $site_dir"
echo " AW Directory       : $aw_subj_dir"
echo " Sessions to process: ${sessions[*]}"
echo "=================================================="

# ==============================================================================
# SESSION PROCESSING LOOP
# ==============================================================================
for ses in "${sessions[@]}"; do

    # Set up session-specific paths
    if [ "$ses" == "no_ses" ]; then
        ses_data_dir="$subj_dir"
        out_ses_dir="${site_dir}/align_tests_centered/${subj_id}"
        ses_filter=""
        log_filename="align_benchmark_centered_${subj_id}.log"
    else
        ses_data_dir="$subj_dir/$ses"
        out_ses_dir="${site_dir}/align_tests_centered/${subj_id}/${ses}"
        ses_filter="$ses"
        log_filename="align_benchmark_centered_${subj_id}_${ses}.log"
    fi

    mkdir -p "$out_ses_dir"
    log_file="${out_ses_dir}/${log_filename}"

    # Wrap session execution into a block piped directly to 'tee'
    {
        echo "######################################################################"
        echo "  STARTING BENCHMARK FOR SUBJECT: $subj_id | SESSION: $ses"
        echo "  Date & Time : $(date)"
        echo "  Host        : $(hostname)"
        echo "  Log File    : $log_file"
        echo "######################################################################"

        cd "$out_ses_dir" || exit 1

        # ----------------------------------------------------------------------
        # STEP 0: LOCATE TARGET ANATOMICAL IMAGE FOR THIS SESSION
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 0] Locating Target Anatomy for $ses..."

        if [ -n "$ses_filter" ]; then
            mapfile -t all_anats < <(find "$aw_subj_dir" -type f \( -name "*${ses_filter}*nsu.nii.gz" -o -name "*${ses_filter}*nsu.HEAD" \) ! -name "*warp2std*" | sort)
        else
            mapfile -t all_anats < <(find "$aw_subj_dir" -type f \( -name "*_nsu.nii.gz" -o -name "*_nsu.HEAD" \) ! -name "*warp2std*" | sort)
        fi

        num_anats=${#all_anats[@]}

        if [ "$num_anats" -eq 0 ]; then
            echo "[WARNING] No native '_nsu' found specifically for session '$ses' in $aw_subj_dir."
            echo "[INFO] Fallback: Searching for any subject native '_nsu'..."
            mapfile -t all_anats < <(find "$aw_subj_dir" -type f \( -name "*_nsu.nii.gz" -o -name "*_nsu.HEAD" \) ! -name "*warp2std*" | sort)
            if [ ${#all_anats[@]} -eq 0 ]; then
                echo "[ERROR] No anatomical '_nsu' file found at all for $subj_id. Skipping session $ses."
                exit 1
            fi
        fi

        anat_nsu_file="${all_anats[0]}"
        3dcopy "$anat_nsu_file" "./${subj_id}_anat_nsu" -overwrite

        # ----------------------------------------------------------------------
        # STEP 1: LOCATE RESTING-STATE BOLD RUNS
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 1] Locating Data Files in $ses_data_dir..."

        mapfile -t rs_runs < <(find "$ses_data_dir" -type f \( -name "*task-rest*bold*.nii*" -o -name "*task-resting*bold*.nii*" \) ! -name "*fmap*" ! -name "*magnitude*" ! -name "*phasediff*" ! -name "*dir-*" | sort)
        num_runs=${#rs_runs[@]}

        # Summary Block
        echo -e "\n======================================================================"
        echo "                    SESSION INPUTS RESUME & INVENTORY                 "
        echo "======================================================================"
        echo "  Subject ID       : $subj_id"
        echo "  Session ID       : $ses"
        echo "  Target Anatomy   : $anat_nsu_file"
        echo "  Working Output   : $out_ses_dir"
        echo "----------------------------------------------------------------------"
        echo "  Resting fMRI Runs (${num_runs} found):"
        if [ "$num_runs" -gt 0 ]; then
            for r in "${rs_runs[@]}"; do
                echo "    - $r"
            done
        else
            echo "    [NONE] No resting runs located!"
        fi
        echo -e "======================================================================\n"

        if [ "$num_runs" -eq 0 ]; then
            echo "[WARNING] No resting-state fMRI runs found for session '$ses'. Skipping execution."
            exit 0
        fi

        # ----------------------------------------------------------------------
        # STEP 2: CALCULATE MINIMUM OUTLIER BASE TR
        # ----------------------------------------------------------------------
        echo ">>> [STEP 2] Calculating global minimum outlier base across session runs..."

        run_idx=1
        tr_counts=()

        for run_path in "${rs_runs[@]}"; do
            run_str=$(printf "%02d" $run_idx)
            tcat_prefix="pb00.${subj_id}.${ses}.r${run_str}.tcat"
            
            3dTcat -prefix "${tcat_prefix}" -overwrite "${run_path}[2..\$]"
            num_trs=$(3dinfo -nv "${tcat_prefix}+orig.HEAD")
            tr_counts+=("$num_trs")
            
            3dToutcount -automask -fraction -polort 3 -legendre "${tcat_prefix}+orig.HEAD" > "outcount.r${run_str}.1D"
            ((run_idx++))
        done

        cat outcount.r*.1D > outcount_rall.1D
        minindex=$(3dTstat -argmin -prefix - outcount_rall.1D\')
        ovals=($(1d_tool.py -set_run_lengths "${tr_counts[@]}" -index_to_run_tr "$minindex"))

        minoutrun=${ovals[0]}
        minouttr=${ovals[1]}
        min_run_str=$(printf "%02d" "$minoutrun")

        echo "[SUCCESS] Base TR selected -> Run: $minoutrun, TR index: $minouttr"

        3dbucket -prefix vr_base_min_outlier -overwrite \
            "pb00.${subj_id}.${ses}.r${min_run_str}.tcat+orig[${minouttr}]"

        epi_target="vr_base_min_outlier+orig"

        # ----------------------------------------------------------------------
        # STEP 2.5: PRE-ALIGN CENTERS (ANAT -> EPI BASE)
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 2.5] Pre-aligning anatomical center of mass to EPI base..."

        @Align_Centers -base "$epi_target" \
                       -dset "./${subj_id}_anat_nsu+orig" \
                       -prefix "./${subj_id}_anat_nsu_shft" \
                       -overwrite

        # ----------------------------------------------------------------------
        # STEP 3: MULTI-COST ALIGNMENT TEST (RIGID BODY - 6 DOF ON CENTERED ANAT)
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 3] Running align_epi_anat.py with -multi_cost on $epi_target..."

        cost_funcs=(ls lpa lpa+ lpc lpc+ lpc+ZZ mi nmi je hel)

        align_epi_anat.py \
            -anat2epi \
            -anat "${subj_id}_anat_nsu_shft+orig" \
            -suffix _al \
            -epi "$epi_target" \
            -epi_base 0 \
            -epi_strip 3dAutomask \
            -anat_has_skull no \
            -feature_size 0.5 \
            -Allineate_opts "-warp shift_rotate -source_automask+2" \
            -multi_cost "${cost_funcs[@]}" \
            -volreg off \
            -tshift off \
            -overwrite

        # ----------------------------------------------------------------------
        # STEP 4: GENERATE QC SNAPSHOTS
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 4] Generating QC Snapshots for $ses..."

        for cost in "${cost_funcs[@]}"; do
            anat_al_file="${subj_id}_anat_nsu_shft_al_${cost}+orig"
            if [ -f "${anat_al_file}.HEAD" ]; then
                @snapshot_volreg "$epi_target" "$anat_al_file"
            fi
        done

        # ----------------------------------------------------------------------
        # STEP 5: QUANTITATIVE DICE OVERLAP EVALUATION & RANKING
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 5] Computing Spatial Dice Coefficients across cost functions..."

        # Generate base functional binary mask
        3dAutomask -prefix mask_epi_base.nii.gz -overwrite "$epi_target"

        dice_results_file="dice_rankings_${ses}.txt"
        rm -f "$dice_results_file"

        for cost in "${cost_funcs[@]}"; do
            anat_al_file="${subj_id}_anat_nsu_shft_al_${cost}+orig"
            if [ -f "${anat_al_file}.HEAD" ]; then
                # Generate binary mask of aligned anatomy
                3dmask_tool -input "$anat_al_file" \
                            -prefix "mask_${cost}.nii.gz" \
                            -fill_holes \
                            -overwrite
                
                # Match grid resolution to EPI base for 3ddot compatibility
                3dresample -master mask_epi_base.nii.gz \
                           -input "mask_${cost}.nii.gz" \
                           -prefix "mask_${cost}_rs.nii.gz" \
                           -overwrite
                
                # Compute Dice coefficient against functional base
                dice_val=$(3ddot -dodice mask_epi_base.nii.gz "mask_${cost}_rs.nii.gz" 2>/dev/null | awk '{print $1}')
                echo "${dice_val} ${cost} ${anat_al_file}" >> "$dice_results_file"
                rm -f "mask_${cost}_rs.nii.gz"
            fi
        done

        # Sort rankings from highest Dice to lowest
        sort -k1,1nr -o "$dice_results_file" "$dice_results_file"

        echo -e "\n======================================================================"
        echo "                 COST FUNCTION RANKING (DICE COEFFICIENT)             "
        echo "======================================================================"
        printf "%-8s | %-12s | %-35s\n" "RANK" "COST FUNC" "DICE OVERLAP SCORE"
        echo "----------------------------------------------------------------------"
        rank=1
        top_candidates=()
        while read -r d_score c_name dset_path; do
            printf "#%-7d | %-12s | %-35s\n" "$rank" "$c_name" "$d_score"
            if [ $rank -le 3 ]; then
                top_candidates+=("$dset_path")
            fi
            ((rank++))
        done < "$dice_results_file"
        echo "======================================================================"

        # ----------------------------------------------------------------------
        # STEP 6: AUTOMATIC @AddEdge ON TOP CANDIDATES
        # ----------------------------------------------------------------------
        if [ ${#top_candidates[@]} -gt 0 ]; then
            echo -e "\n>>> [STEP 6] Running @AddEdge on top ${#top_candidates[@]} cost candidates..."
            @AddEdge "$epi_target" "${top_candidates[@]}"
            echo "[SUCCESS] @AddEdge completed. Review detailed edges in 'AddEdge/' folder."
        fi

        echo -e "\n######################################################################"
        echo "  SESSION $ses COMPLETED SUCCESSFULLY"
        echo "  Output Directory : $out_ses_dir"
        echo "  Saved Log File   : $log_file"
        echo "######################################################################"

    } 2>&1 | tee "$log_file"

done

echo -e "\n=================================================="
echo "++ ALL REQUESTED SESSIONS COMPLETED FOR: $subj_id"
echo "=================================================="

exit 0
