#!/bin/bash

# ==============================================================================
# Script Name : align_epi2anat_test_v3.sh
# Language    : BASH
# Description : Multi-session benchmarking script for EPI-to-Anatomical 
#               alignment in AFNI. Automatically iterates through all sessions
#               (or a user-specified session) for a subject, isolating:
#                 1. Session-specific @animal_warper anatomy (_nsu)
#                 2. Session-specific Resting-State EPI runs
#                 3. Session-specific B0 distortion correction (Fieldmaps)
#                 4. Complete input summary (including fmaps) for debugging
#                 5. Full execution log via 'tee' per session folder
#                 6. Session-specific QC snapshots
#
# Usage:
#   ./align_epi2anat_test_v3.sh -d <site_dir> -s <subj_id> -a <aw_dir> [-ses <session_str>]
#   ./align_epi2anat_test_v3.sh -h
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
    - Summarizes all session inputs (Anat, Func, Fieldmaps) for debugging.
    - Conditionally unwarps B0 distortion if session 'fmap/' exists.
    - Runs 'align_epi_anat.py' with -multi_cost.
    - Saves a full terminal log inside each session's output folder via 'tee'.
    - Generates edge QC snapshots per cost function.

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

    # Set up session-specific input and output paths
    if [ "$ses" == "no_ses" ]; then
        ses_data_dir="$subj_dir"
        out_ses_dir="${site_dir}/align_tests_cost_functions/${subj_id}"
        ses_filter=""
        log_filename="align_benchmark_${subj_id}.log"
    else
        ses_data_dir="$subj_dir/$ses"
        out_ses_dir="${site_dir}/align_tests_cost_functions/${subj_id}/${ses}"
        ses_filter="$ses"
        log_filename="align_benchmark_${subj_id}_${ses}.log"
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
        # STEP 1: LOCATE RESTING-STATE BOLD RUNS & FIELDMAP FILES
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 1] Locating Data Files in $ses_data_dir..."

        # 1. BOLD runs
        mapfile -t rs_runs < <(find "$ses_data_dir" -type f \( -name "*task-rest*bold*.nii*" -o -name "*task-resting*bold*.nii*" \) ! -name "*fmap*" ! -name "*magnitude*" ! -name "*phasediff*" ! -name "*dir-*" | sort)
        num_runs=${#rs_runs[@]}

        # 2. Fieldmaps
        fmap_mag=$(find "$ses_data_dir" -type f -name "*magnitude*.nii*" | sort | head -n 1)
        fmap_phase=$(find "$ses_data_dir" -type f -name "*phasediff*.nii*" | sort | head -n 1)
        fmap_json=$(find "$ses_data_dir" -type f -name "*phasediff*.json" | sort | head -n 1)

        # ----------------------------------------------------------------------
        # DEBUG RESUME / INVENTORY SUMMARY BLOCK
        # ----------------------------------------------------------------------
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
        echo "----------------------------------------------------------------------"
        echo "  Fieldmap Files Detected:"
        if [ -n "$fmap_mag" ]; then
            echo "    - Magnitude : $fmap_mag"
        else
            echo "    - Magnitude : [NOT FOUND]"
        fi

        if [ -n "$fmap_phase" ]; then
            echo "    - PhaseDiff : $fmap_phase"
        else
            echo "    - PhaseDiff : [NOT FOUND]"
        fi

        if [ -n "$fmap_json" ]; then
            echo "    - JSON Meta : $fmap_json"
        else
            echo "    - JSON Meta : [NOT FOUND / DEFAULT DTE WILL BE USED]"
        fi
        echo "======================================================================\n"

        if [ "$num_runs" -eq 0 ]; then
            echo "[WARNING] No resting-state fMRI runs found for session '$ses'. Skipping pipeline execution."
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

        # ----------------------------------------------------------------------
        # STEP 2.5: CONDITIONAL FIELDMAP CORRECTION (B0 UNWARPING)
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 2.5] Evaluating Fieldmap B0 unwarping for $ses..."

        if [ -n "$fmap_mag" ] && [ -n "$fmap_phase" ]; then
            echo "[ACTION] Full fieldmap pair present. Executing B0 distortion correction..."

            delta_te="0.00246"
            if [ -f "$fmap_json" ]; then
                parsed_dte=$(python3 -c "
import json
try:
    with open('$fmap_json') as f:
        d = json.load(f)
        dte = abs(d.get('EchoTime2', 0.00668) - d.get('EchoTime1', 0.00422))
        print(f'{dte:.6f}')
except Exception:
    print('0.00246')
" 2>/dev/null)
                [ -n "$parsed_dte" ] && delta_te="$parsed_dte"
            fi
            echo "[INFO] Calculated Delta TE : $delta_te seconds"

            # 1. Mask Magnitude
            3dcopy "$fmap_mag" ./fmap_mag -overwrite
            3dAutomask -prefix fmap_mag_mask.nii.gz -overwrite ./fmap_mag+orig

            # 2. Rescale phase to [-PI, PI] and Unwrap
            3dcalc -a "$fmap_phase" \
                   -expr '(a - 2048) * 3.14159265 / 2048' \
                   -prefix phasediff_rad.nii.gz -overwrite

            3dUnwrap -prefix fmap_unwrapped.nii.gz -overwrite phasediff_rad.nii.gz

            # 3. Convert to Hz
            3dcalc -a fmap_unwrapped.nii.gz -b fmap_mag_mask.nii.gz \
                   -expr "(a / (2 * 3.14159265 * ${delta_te})) * b" \
                   -prefix fmap_hz.nii.gz -overwrite

            # 4. Rigid-align Magnitude to EPI Base
            align_epi_anat.py \
                -dset1 vr_base_min_outlier+orig \
                -dset2 ./fmap_mag+orig \
                -dset2to1 \
                -child_dset2 fmap_hz.nii.gz \
                -cost nmi \
                -rigid_body \
                -overwrite

            # 5. Calculate Warp and Apply B0 Unwarping
            3dQwarp -plusminus -pmNAMES fmap_warp \
                    -base vr_base_min_outlier+orig \
                    -source ./fmap_mag_al+orig \
                    -prefix fmap_qwarp -overwrite

            3dNwarpApply -nwarp fmap_warp_PLUS_WARP+orig \
                         -source vr_base_min_outlier+orig \
                         -master vr_base_min_outlier+orig \
                         -prefix vr_base_min_outlier_unwarped -overwrite

            epi_target="vr_base_min_outlier_unwarped+orig"
            echo "[SUCCESS] B0 unwarping finished successfully."
            echo "[TARGET] Benchmark alignment will evaluate: $epi_target"
        else
            echo "[INFO] Incomplete or absent Fieldmaps for $ses."
            echo "[INFO] Continuing benchmark directly on raw EPI base without B0 unwarping."
            epi_target="vr_base_min_outlier+orig"
            echo "[TARGET] Benchmark alignment will evaluate: $epi_target"
        fi

        # ----------------------------------------------------------------------
        # STEP 3: MULTI-COST ALIGNMENT TEST
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 3] Running align_epi_anat.py with -multi_cost on $epi_target..."

        align_epi_anat.py \
            -anat2epi \
            -anat "${subj_id}_anat_nsu+orig" \
            -suffix _al \
            -epi "$epi_target" \
            -epi_base 0 \
            -epi_strip 3dAutomask \
            -anat_has_skull no \
            -cmass nocmass \
            -feature_size 0.5 \
            -rigid_body \
            -Allineate_opts -source_automask+2 \
            -multi_cost ls lpa lpa+ lpc lpc+ lpc+ZZ mi nmi je hel \
            -volreg off \
            -tshift off

        # ----------------------------------------------------------------------
        # STEP 4: GENERATE QC SNAPSHOTS
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 4] Generating QC Snapshots for $ses..."

        cost_funcs=(lpa lpa+ lpc lpc+ lpc+ZZ mi nmi je hel)

        for cost in "${cost_funcs[@]}"; do
            anat_al_file="${subj_id}_anat_nsu_al_${cost}+orig"
            if [ -f "${anat_al_file}.HEAD" ]; then
                @snapshot_volreg "$epi_target" "$anat_al_file"
            fi
        done

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
