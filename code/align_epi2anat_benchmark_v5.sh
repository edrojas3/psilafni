#!/bin/bash

# ==============================================================================
# Script Name : align_epi2anat_benchmark_v4.sh
# Language    : BASH
# Description : Multi-session benchmarking script for EPI-to-Anatomical 
#               alignment in AFNI for Non-Human Primates (NHP) with optional/auto
#               B0 Fieldmap Unwarping support (FSL fugue).
#               - Supports: default, -big_move, -giant_move, -ginormous_move.
#               - Pre-centers anatomy with @Align_Centers.
#               - Pre-inspects geometric distance & search limits to auto-select
#                 or accept manual overrides for movement flags and -cmass.
#               - Evaluates multiple cost functions in rigid-body (6 DOF).
#               - Computes Dice coefficients and ranks all evaluated costs.
#               - Outputs an analytical per-subject/session .tsv summary report.
#               - Automatically executes @AddEdge on top-ranked candidates.
#
# Usage:
#   ./align_epi2anat_benchmark_v4.sh -d <site_dir> -s <subj_id> -a <aw_dir> [options]
#   ./align_epi2anat_benchmark_v4.sh -h
# ==============================================================================

show_help() {
    cat << EOF

==============================================================================
  MULTI-SESSION ALIGNMENT BENCHMARKING (EPI -> ANAT) [V4 - AUTO/MANUAL] - HELP
==============================================================================

Description:
  Automates multi-cost function testing per session for NHP fMRI in AFNI:
    - Auto-detects all 'ses-*' directories (or runs single-session if no 'ses-*').
    - Auto-detects prepared fieldmaps in 'fieldmaps_prepared_all/' and applies
      geometric unwarping (fugue) to the base TR before alignment.
    - Fallback: Gracefully switches to standard alignment if no fieldmaps exist.
    - Pairs session-specific @animal_warper anatomy (_nsu).
    - Summarizes session functional and anatomical inputs.
    - Calculates the global minimum outlier base TR across runs.
    - Pre-aligns anatomical centers with EPI base using @Align_Centers.
    - Pre-inspects center-of-mass distance (3dCM) and shift percentages to 
      auto-select: [default], -big_move, -giant_move, or -ginormous_move.
    - Allows manual override of move and cmass flags.
    - Runs 'align_epi_anat.py' with -multi_cost in rigid-body mode (6 DOF).
    - Resamples masks and computes automated Dice spatial overlap ranking.
    - Generates a per-session structured TSV metric report.
    - Runs '@AddEdge' automatically on the top 3 alignment candidates.

Usage:
  $0 -d <site_dir> -s <subj_id> -a <aw_dir> [options]
  $0 -h

Required Flags:
  -d <path>           : Absolute path to BIDS site directory (e.g., /path/to/site-ion)
  -s <id>             : Unique subject ID (e.g., sub-032199)
  -a <path>           : Absolute path to @animal_warper directory for the site
                        (e.g., /path/to/site-ion/data_aw)

Optional Flags:
  -ses <str>          : Target a specific session only (e.g., 'ses-001').
  -nf                 : No Fieldmap flag. Force skipping fieldmap unwarping.
  -dwell <s>          : Custom EPI Dwell Time (Default: auto-detected or 0.00065s).

Movement Mode Overrides (Optional - Defaults to auto-detection):
  -big_move           : Force -big_move (search +/- 30 deg).
  -giant_move         : Force -giant_move (search +/- 45 deg + cmass).
  -ginormous_move     : Force -ginormous_move (search +/- 180 deg + cmass).
  -cmass <cmass|nocmass> : Force specific center of mass mode.
  -h, --help          : Display this help message and exit.

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
disable_fmap=false
user_dwell=""
user_move=""
user_cmass=""

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
        -nf|--no-fmap)
            disable_fmap=true
            shift 1
            ;;
        -dwell)
            user_dwell="$2"
            shift 2
            ;;
        -big_move)
            user_move="-big_move"
            shift 1
            ;;
        -giant_move)
            user_move="-giant_move"
            shift 1
            ;;
        -ginormous_move)
            user_move="-ginormous_move"
            shift 1
            ;;
        -cmass)
            user_cmass="$2"
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
echo " STARTING MULTI-SESSION BENCHMARK [V4] FOR: $subj_id"
echo " Site Directory     : $site_dir"
echo " AW Directory       : $aw_subj_dir"
echo " Sessions to run    : ${sessions[*]}"
echo " Fieldmap Override  : $( [ "$disable_fmap" = true ] && echo "DISABLED (-nf)" || echo "AUTO-DETECT (DEFAULT)" )"
echo " Manual Move Flag   : ${user_move:-[AUTO-DETECT]}"
echo " Manual CMass Flag  : ${user_cmass:-[AUTO-DETECT]}"
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
        ses_fmap_str="ses-default"
        log_filename="align_benchmark_centered_${subj_id}.log"
        tsv_report="${out_ses_dir}/alignment_metrics_${subj_id}.tsv"
    else
        ses_data_dir="$subj_dir/$ses"
        out_ses_dir="${site_dir}/align_tests_centered/${subj_id}/${ses}"
        ses_filter="$ses"
        ses_fmap_str="$ses"
        log_filename="align_benchmark_centered_${subj_id}_${ses}.log"
        tsv_report="${out_ses_dir}/alignment_metrics_${subj_id}_${ses}.tsv"
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

        # ----------------------------------------------------------------------
        # STEP 2.1: FIELDMAP CHECK & GEOMETRIC UNWARPING (FSL FUGUE)
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 2.1] Evaluating Fieldmap Unwarping..."

        prepared_fmap_dir="${site_dir}/fieldmaps_prepared_all/${subj_id}/${ses_fmap_str}/fmap_prepared"
        fmap_rads_file="${prepared_fmap_dir}/fmap_rads.nii.gz"
        fmap_applied=false

        if [ "$disable_fmap" = true ]; then
            echo "[INFO] Fieldmap correction explicitly disabled by user (-nf flag)."
        elif [ -f "$fmap_rads_file" ]; then
            echo "[SUCCESS] Prepared Fieldmap located at: $fmap_rads_file"
            
            # Determine Dwell Time (Effective Echo Spacing)
            dwell_val="0.00065" # Safe standard NHP default
            if [ -n "$user_dwell" ]; then
                dwell_val="$user_dwell"
            else
                bold_json=$(find "$ses_data_dir" -type f \( -name "*task-rest*bold*.json" -o -name "*task-resting*bold*.json" \) | head -n 1)
                if [ -f "$bold_json" ]; then
                    extracted_dwell=$(python3 -c "
import json
try:
    d = json.load(open('$bold_json'))
    val = d.get('EffectiveEchoSpacing', d.get('DwellTime', None))
    if val: print(val)
except: pass
" 2>/dev/null)
                    [ -n "$extracted_dwell" ] && dwell_val="$extracted_dwell"
                fi
            fi

            echo "[INFO] Applying FSL fugue unwarping (Dwell Time: ${dwell_val}s)..."
            
            3dcopy vr_base_min_outlier+orig vr_base_min_outlier.nii.gz -overwrite
            
            if fugue -i vr_base_min_outlier.nii.gz \
                     --dwell="$dwell_val" \
                     --loadfmap="$fmap_rads_file" \
                     -u vr_base_min_outlier_unwarped.nii.gz; then
                
                3dcopy vr_base_min_outlier_unwarped.nii.gz vr_base_min_outlier_unwarped -overwrite
                rm -f vr_base_min_outlier.nii.gz vr_base_min_outlier_unwarped.nii.gz
                
                epi_target="vr_base_min_outlier_unwarped+orig"
                fmap_applied=true
                echo "[SUCCESS] Base EPI unwarping successful -> Active target: $epi_target"
            else
                echo "[WARNING] FSL fugue execution failed! Falling back to standard base."
            fi
        else
            echo "[WARNING] No prepared fieldmap found at: $prepared_fmap_dir"
            echo "[INFO] Fallback: Continuing with standard base (Non-Fieldmap)."
        fi

        if [ "$fmap_applied" = false ]; then
            epi_target="vr_base_min_outlier+orig"
            echo "[INFO] Active target: $epi_target"
        fi

        # ----------------------------------------------------------------------
        # STEP 2.5: PRE-ALIGN CENTERS (ANAT -> ACTIVE EPI BASE)
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 2.5] Pre-aligning anatomical center of mass to EPI base ($epi_target)..."

        @Align_Centers -base "$epi_target" \
                       -dset "./${subj_id}_anat_nsu+orig" \
                       -prefix "./${subj_id}_anat_nsu_shft" \
                       -overwrite

        anat_target="${subj_id}_anat_nsu_shft+orig"

        # ----------------------------------------------------------------------
        # STEP 2.6: PRE-INSPECTION OF GEOMETRIC DISTANCE & MOVEMENT PARAMETERS
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 2.6] Pre-inspecting geometric distance & search limits..."

        # Calculate exact center of mass coordinates in physical space (mm)
        cm_anat=($(3dCM "$anat_target"))
        cm_epi=($(3dCM "$epi_target"))

        dist_metrics=$(python3 -c "
import math
x1, y1, z1 = float('${cm_anat[0]}'), float('${cm_anat[1]}'), float('${cm_anat[2]}')
x2, y2, z2 = float('${cm_epi[0]}'), float('${cm_epi[1]}'), float('${cm_epi[2]}')

dx = abs(x1 - x2)
dy = abs(y1 - y2)
dz = abs(z1 - z2)
euc = math.sqrt(dx**2 + dy**2 + dz**2)
max_d = max(dx, dy, dz)

print(f'{dx:.3f} {dy:.3f} {dz:.3f} {euc:.3f} {max_d:.3f}')
")

        read -r dx_mm dy_mm dz_mm dist_euc_mm max_dist_mm <<< "$dist_metrics"

        # Run 3dAllineate in pre-check mode (-allcost) to parse shift search percentages
        allcost_out=$(3dAllineate -base "$epi_target" -source "$anat_target" -allcost 2>&1)
        
        cmass_pct_max=$(echo "$allcost_out" | grep -A 2 "shift search range is +/-" | tail -n 1 | awk '
        {
            gsub("%","",$0);
            max_pct = 0.0;
            for(i=1;i<=NF;i++) {
                val = $i + 0.0;
                if(val > max_pct) max_pct = val;
            }
            print max_pct;
        }')

        [ -z "$cmass_pct_max" ] && cmass_pct_max="0.0"

        echo "----------------------------------------------------------------------"
        echo "  Center of Mass (3dCM) Coordinates:"
        echo "    - Anatomy (${anat_target}) : (${cm_anat[0]}, ${cm_anat[1]}, ${cm_anat[2]}) mm"
        echo "    - EPI Base (${epi_target})   : (${cm_epi[0]}, ${cm_epi[1]}, ${cm_epi[2]}) mm"
        echo "  Displacement Offsets:"
        echo "    - Delta X : ${dx_mm} mm | Delta Y : ${dy_mm} mm | Delta Z : ${dz_mm} mm"
        echo "    - Total Euclidean Distance : ${dist_euc_mm} mm"
        echo "    - Max Shift Search Pct     : ${cmass_pct_max}%"
        echo "----------------------------------------------------------------------"

        # Automated Decision Logic for all 4 Levels
        auto_move=""
        auto_cmass="nocmass"
        auto_reason=""

        is_ginormous=$(python3 -c "print(1 if ($max_dist_mm >= 25.0 or $cmass_pct_max >= 60.0) else 0)")
        is_giant=$(python3 -c "print(1 if ($max_dist_mm >= 12.0 or $cmass_pct_max >= 30.0) else 0)")
        is_big=$(python3 -c "print(1 if ($max_dist_mm >= 6.0 or $cmass_pct_max >= 15.0) else 0)")

        if [ "$is_ginormous" -eq 1 ]; then
            auto_move="-ginormous_move"
            auto_cmass="cmass"
            auto_reason="Extreme offset detected (Max dist >= 25mm or Search >= 60%)"
        elif [ "$is_giant" -eq 1 ]; then
            auto_move="-giant_move"
            auto_cmass="cmass"
            auto_reason="Large offset detected (Max dist >= 12mm or Search >= 30%)"
        elif [ "$is_big" -eq 1 ]; then
            auto_move="-big_move"
            auto_cmass="cmass"
            auto_reason="Moderate offset detected (Max dist >= 6mm or Search >= 15%)"
        else
            auto_move=""
            auto_cmass="nocmass"
            auto_reason="Small offset within default search limits (Max dist < 6mm)"
        fi

        # Apply User Overrides if specified, else use Auto Decisions
        active_move="${user_move:-$auto_move}"
        active_cmass="${user_cmass:-$auto_cmass}"

        echo "  => Pre-check Decision:"
        echo "       Auto-detected Move  = ${auto_move:-[DEFAULT]} (Reason: $auto_reason)"
        echo "       Auto-detected CMass = ${auto_cmass}"
        echo "       ACTIVE EXEC MOVE    = ${active_move:-[DEFAULT]}"
        echo "       ACTIVE EXEC CMASS   = ${active_cmass}"
        echo "----------------------------------------------------------------------"

        # ----------------------------------------------------------------------
        # STEP 3: MULTI-COST ALIGNMENT TEST
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 3] Running align_epi_anat.py with -multi_cost on $epi_target..."

        cost_funcs=(ls lpa lpa+ lpc lpc+ lpc+ZZ mi nmi je hel)

        # Build dynamic execution parameters
        align_cmd=(
            align_epi_anat.py
            -anat2epi
            -anat "$anat_target"
            -suffix _al
            -epi "$epi_target"
            -epi_base 0
            -epi_strip 3dAutomask
            -anat_has_skull no
            -feature_size 0.5
            -cmass "$active_cmass"
        )

        [ -n "$active_move" ] && align_cmd+=("$active_move")

        align_cmd+=(
            -Allineate_opts "-warp shift_rotate -source_automask+2"
            -multi_cost "${cost_funcs[@]}"
            -volreg off
            -tshift off
            -overwrite
        )

        echo "[EXEC] Running: ${align_cmd[*]}"
        "${align_cmd[@]}"

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
                [ -z "$dice_val" ] && dice_val="0.0000"

                echo "${dice_val} ${cost} ${anat_al_file}" >> "$dice_results_file"
                rm -f "mask_${cost}_rs.nii.gz" "mask_${cost}.nii.gz"
            fi
        done

        # Sort rankings from highest Dice to lowest
        sort -k1,1nr -o "$dice_results_file" "$dice_results_file"

        echo -e "\n======================================================================"
        echo "     COST FUNCTION RANKING (DICE COEFFICIENT) [FMAP: $fmap_applied]    "
        echo "======================================================================"
        printf "%-8s | %-12s | %-35s\n" "RANK" "COST FUNC" "DICE OVERLAP SCORE"
        echo "----------------------------------------------------------------------"
        
        rank=1
        top_candidates=()
        best_cost_name=""
        best_dice_score=""

        while read -r d_score c_name dset_path; do
            printf "#%-7d | %-12s | %-35s\n" "$rank" "$c_name" "$d_score"
            if [ $rank -eq 1 ]; then
                best_cost_name="$c_name"
                best_dice_score="$d_score"
            fi
            if [ $rank -le 3 ]; then
                top_candidates+=("$dset_path")
            fi
            ((rank++))
        done < "$dice_results_file"
        echo "======================================================================"

        # ----------------------------------------------------------------------
        # STEP 5.5: GENERATE STRUCTURED TSV REPORT
        # ----------------------------------------------------------------------
        echo -e "\n>>> [STEP 5.5] Exporting metric report to TSV: $tsv_report"

        {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "subject_id" "session_id" "fieldmap_applied" \
                "dist_x_mm" "dist_y_mm" "dist_z_mm" "euclidean_dist_mm" "cmass_search_pct_max" \
                "auto_move" "auto_cmass" "active_move" "active_cmass" \
                "cost_function" "dice_coefficient" "is_best_cost"

            while read -r d_score c_name dset_path; do
                is_best="0"
                [ "$c_name" == "$best_cost_name" ] && is_best="1"

                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                    "$subj_id" "$ses" "$fmap_applied" \
                    "$dx_mm" "$dy_mm" "$dz_mm" "$dist_euc_mm" "$cmass_pct_max" \
                    "${auto_move:-none}" "$auto_cmass" "${active_move:-none}" "$active_cmass" \
                    "$c_name" "$d_score" "$is_best"
            done < "$dice_results_file"
        } > "$tsv_report"

        echo "[SUCCESS] TSV summary exported successfully."

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
        echo "  Fieldmap Applied   : $fmap_applied"
        echo "  Active Move Flag   : ${active_move:-[DEFAULT]}"
        echo "  Active -cmass Flag : ${active_cmass}"
        echo "  Best Cost Function : ${best_cost_name} (Dice = ${best_dice_score})"
        echo "  Metrics TSV File   : $tsv_report"
        echo "  Output Directory   : $out_ses_dir"
        echo "  Saved Log File     : $log_file"
        echo "######################################################################"

    } 2>&1 | tee "$log_file"

done

echo -e "\n=================================================="
echo "++ ALL REQUESTED SESSIONS COMPLETED FOR: $subj_id"
echo "=================================================="

exit 0
