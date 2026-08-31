#!/bin/bash

# ==============================================================================
# Script Name : align_epi2anat_benchmark_v7.sh
# Language    : BASH
# Description : Multi-site / Multi-session / Multi-run benchmarking script for
#               EPI-to-Anatomical alignment in AFNI for Non-Human Primates (NHP).
#               - Evaluates single or ALL available T1w anatomical runs/sessions
#                 derived from @animal_warper against fMRI sessions.
#               - Default: No fieldmap correction (Use -fmap to enable FSL fugue).
#               - Pre-aligns anatomical centers to EPI base using @Align_Centers.
#               - Robust, fully automated metric calculation (3dCM/3dAllineate).
#               - Exports PRE-CENTERED anatomy paths to TSV for direct afni_proc use.
#               - Multi-cost function testing (10 costs in rigid-body 6 DOF).
#               - Automated Dice spatial overlap ranking and top-3 @AddEdge.
#
# Usage:
#   ./align_epi2anat_benchmark_v7.sh -d <site_dir> -s <subj_id> -a <aw_dir> [options]
#   ./align_epi2anat_benchmark_v7.sh -h
# ==============================================================================

set -o pipefail

show_help() {
    cat << EOF

==============================================================================
 MULTI-SITE / MULTI-ANAT ALIGNMENT BENCHMARK (EPI -> ANAT) [V7] - HELP
==============================================================================

Description:
  Automates multi-cost function testing across all available anatomical sessions
  and runs for NHP fMRI in AFNI:
    - Evaluates 1 or ALL T1w anatomical runs/sessions from data_aw.
    - By default, skips fieldmap unwarping (pass -fmap to enable FSL fugue).
    - Pre-aligns anatomical centers with EPI base using @Align_Centers.
    - Inspects displacement (3dCM) to auto-select search limits (-giant_move, etc.).
    - Evaluates 10 cost functions in rigid-body mode (6 DOF).
    - Ranks combinations via Dice spatial overlap and runs @AddEdge on top 3.
    - Exports the PRE-ALIGNED anatomy path in TSVs for direct afni_proc execution.
    - Outputs a global comparison report (master_benchmark_summary.tsv).

Usage:
  $0 -d <site_dir> -s <subj_id> -a <aw_dir> [options]
  $0 -h

Required Flags:
  -d <path>            : Absolute path to BIDS site directory (e.g., /path/to/site-name)
  -s <id>              : Unique subject ID (e.g., sub-032144)
  -a <path>            : Absolute path to @animal_warper directory for the site
                         (e.g., /path/to/site-name/data_aw)

Optional Flags:
  -ses <str>           : Target a specific functional session only (e.g., 'ses-004').
  -anat_ses <str>      : Target a specific anatomical session/run (e.g., 'ses-001_run-2').
                         If omitted, tests ALL available anatomies/runs in data_aw.
  -fmap, --use-fmap    : Explicitly enable B0 Fieldmap geometric unwarping (FSL fugue).
                         (Default: DISABLED).
  -dwell <s>           : Custom EPI Dwell Time (Default: auto-detected or 0.00065s).

Movement Mode Overrides (Optional - Defaults to auto-detection):
  -big_move            : Force -big_move (search +/- 30 deg).
  -giant_move          : Force -giant_move (search +/- 45 deg + cmass).
  -ginormous_move      : Force -ginormous_move (search +/- 180 deg + cmass).
  -cmass <cmass|nocmass> : Force specific center of mass mode.
  -h, --help           : Display this help message and exit.

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
user_anat_ses=""
enable_fmap=false
user_dwell=""
user_move=""
user_cmass=""

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            site_dir="$2"; shift 2 ;;
        -s)
            subj_id="$2"; shift 2 ;;
        -a)
            aw_dir="$2"; shift 2 ;;
        -ses|-p)
            user_ses="$2"; shift 2 ;;
        -anat_ses|-aw_ses)
            user_anat_ses="$2"; shift 2 ;;
        -fmap|--use-fmap)
            enable_fmap=true; shift 1 ;;
        -dwell)
            user_dwell="$2"; shift 2 ;;
        -big_move)
            user_move="-big_move"; shift 1 ;;
        -giant_move)
            user_move="-giant_move"; shift 1 ;;
        -ginormous_move)
            user_move="-ginormous_move"; shift 1 ;;
        -cmass)
            user_cmass="$2"; shift 2 ;;
        -h|--help)
            show_help ;;
        *)
            echo "[ERROR] Unknown option: $1"
            show_help ;;
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
    echo "[ERROR] Subject directory not found: $subj_dir"; exit 1
fi
if [ ! -d "$aw_subj_dir" ]; then
    echo "[ERROR] Subject Animal Warper folder not found: $aw_subj_dir"; exit 1
fi

# ------------------------------------------------------------------------------
# 1. DISCOVER FUNCTIONAL SESSIONS
# ------------------------------------------------------------------------------
func_sessions=()

if [ -n "$user_ses" ]; then
    if [ -d "$subj_dir/$user_ses" ]; then
        func_sessions+=("$user_ses")
    else
        echo "[ERROR] Specified functional session '$user_ses' does not exist in $subj_dir"
        exit 1
    fi
else
    while IFS= read -r s_path; do
        [ -n "$s_path" ] && func_sessions+=("$(basename "$s_path")")
    done < <(find "$subj_dir" -mindepth 1 -maxdepth 1 -type d -name "ses-*" | sort)

    if [ ${#func_sessions[@]} -eq 0 ]; then
        func_sessions+=("no_ses")
    fi
fi

# ------------------------------------------------------------------------------
# 2. DISCOVER ALL UNIQUE ANATOMICAL RUNS & SESSIONS IN DATA_AW
# ------------------------------------------------------------------------------
anat_target_list=()

if [ -n "$user_anat_ses" ]; then
    mapfile -t raw_anats < <(find "$aw_subj_dir" -type f \( -name "*${user_anat_ses}*nsu.nii.gz" -o -name "*${user_anat_ses}*nsu.HEAD" \) ! -name "*warp2std*" | sort)
else
    mapfile -t raw_anats < <(find "$aw_subj_dir" -type f \( -name "*_nsu.nii.gz" -o -name "*_nsu.HEAD" \) ! -name "*warp2std*" | sort)
fi

# Deduplicate prefixes
declare -A seen_anats
for f in "${raw_anats[@]}"; do
    clean_prefix="${f%+orig.HEAD}"
    clean_prefix="${clean_prefix%.HEAD}"
    clean_prefix="${clean_prefix%.nii.gz}"
    clean_prefix="${clean_prefix%.nii}"

    if [ -z "${seen_anats[$clean_prefix]}" ]; then
        seen_anats[$clean_prefix]=1
        anat_target_list+=("$f")
    fi
done

num_anats_found=${#anat_target_list[@]}
if [ "$num_anats_found" -eq 0 ]; then
    echo "[ERROR] No anatomical '_nsu' files found in $aw_subj_dir"
    exit 1
fi

echo "=================================================="
echo " STARTING MULTI-ANAT / MULTI-RUN BENCHMARK [V7]"
echo " Subject ID         : $subj_id"
echo " Site Directory     : $site_dir"
echo " AW Directory       : $aw_subj_dir"
echo " Functional Sessions: ${func_sessions[*]}"
echo " Anatomical Inputs  : $num_anats_found candidate run(s)/session(s) detected:"
for a in "${anat_target_list[@]}"; do
    echo "   -> $a"
done
echo " Fieldmap Mode      : $( [ "$enable_fmap" = true ] && echo "ENABLED (-fmap)" || echo "DISABLED (DEFAULT)" )"
echo " Movement Mode      : ${user_move:-[AUTO-DETECT]}"
echo " CMass Mode         : ${user_cmass:-[AUTO-DETECT]}"
echo "=================================================="

# Master summary report across all combinations
master_report="${site_dir}/align_tests_centered/${subj_id}/master_benchmark_summary.tsv"
mkdir -p "$(dirname "$master_report")"
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "subject_id" "func_session" "anat_tag" "fieldmap_applied" \
    "active_move" "best_cost" "best_dice" "anat_shft_path" "anat_raw_path" > "$master_report"

# ==============================================================================
# FUNCTIONAL SESSION LOOP
# ==============================================================================
for f_ses in "${func_sessions[@]}"; do

    if [ "$f_ses" == "no_ses" ]; then
        ses_data_dir="$subj_dir"
        base_out_dir="${site_dir}/align_tests_centered/${subj_id}"
        ses_fmap_str="ses-default"
    else
        ses_data_dir="$subj_dir/$f_ses"
        base_out_dir="${site_dir}/align_tests_centered/${subj_id}/${f_ses}"
        ses_fmap_str="$f_ses"
    fi

    # Locate resting BOLD runs
    mapfile -t rs_runs < <(find "$ses_data_dir" -type f \( -name "*task-rest*bold*.nii*" -o -name "*task-resting*bold*.nii*" \) ! -name "*fmap*" ! -name "*magnitude*" ! -name "*phasediff*" ! -name "*dir-*" | sort)
    num_runs=${#rs_runs[@]}

    if [ "$num_runs" -eq 0 ]; then
        echo "[INFO] No resting-state fMRI runs found for session '$f_ses'. Skipping."
        continue
    fi

    # Prep directory for base TR
    prep_dir="${base_out_dir}/_base_prep"
    mkdir -p "$prep_dir"
    cd "$prep_dir" || exit 1

    echo -e "\n>>> [BASE TR] Calculating global minimum outlier base for functional session: $f_ses (${num_runs} BOLD runs)..."
    run_idx=1
    tr_counts=()

    for run_path in "${rs_runs[@]}"; do
        run_str=$(printf "%02d" $run_idx)
        tcat_prefix="pb00.${subj_id}.${f_ses}.r${run_str}.tcat"

        3dTcat -prefix "${tcat_prefix}" -overwrite "${run_path}[2..\$]"
        num_trs=$(3dinfo -nv "${tcat_prefix}+orig" 2>/dev/null || 3dinfo -nv "${tcat_prefix}+orig.HEAD")
        tr_counts+=("$num_trs")

        3dToutcount -automask -fraction -polort 3 -legendre "${tcat_prefix}+orig" > "outcount.r${run_str}.1D"
        ((run_idx++))
    done

    cat outcount.r*.1D > outcount_rall.1D
    minindex=$(3dTstat -argmin -prefix - outcount_rall.1D\' 2>/dev/null | tr -d '[:space:]')

    if [ -z "$minindex" ] || ! [[ "$minindex" =~ ^[0-9]+$ ]]; then
        minoutrun=1; minouttr=0
    else
        ovals=($(1d_tool.py -set_run_lengths "${tr_counts[@]}" -index_to_run_tr "$minindex"))
        minoutrun=${ovals[0]}; minouttr=${ovals[1]}
    fi

    min_run_str=$(printf "%02d" "$minoutrun")
    echo "[SUCCESS] Global base TR selected -> Run: $minoutrun, TR index: $minouttr"

    3dbucket -prefix vr_base_min_outlier -overwrite \
        "pb00.${subj_id}.${f_ses}.r${min_run_str}.tcat+orig[${minouttr}]"

    # Optional Fieldmap Unwarping (Only if -fmap flag explicitly passed)
    prepared_fmap_dir="${site_dir}/fieldmaps_prepared_all/${subj_id}/${ses_fmap_str}/fmap_prepared"
    fmap_rads_file="${prepared_fmap_dir}/fmap_rads.nii.gz"
    fmap_applied=false

    if [ "$enable_fmap" = true ] && [ -f "$fmap_rads_file" ]; then
        dwell_val="0.00065"
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
except Exception:
    pass
" 2>/dev/null)
                [ -n "$extracted_dwell" ] && dwell_val="$extracted_dwell"
            fi
        fi

        echo "[INFO] Applying FSL fugue unwarping (Dwell: ${dwell_val}s)..."
        3dcopy vr_base_min_outlier+orig vr_base_min_outlier.nii.gz -overwrite

        if fugue -i vr_base_min_outlier.nii.gz \
                 --dwell="$dwell_val" \
                 --loadfmap="$fmap_rads_file" \
                 -u vr_base_min_outlier_unwarped.nii.gz; then

            3dcopy vr_base_min_outlier_unwarped.nii.gz "${prep_dir}/vr_base_active" -overwrite
            rm -f vr_base_min_outlier.nii.gz vr_base_min_outlier_unwarped.nii.gz
            fmap_applied=true
            echo "[SUCCESS] EPI base deswarped with Fieldmap."
        fi
    fi

    if [ "$fmap_applied" = false ]; then
        3dcopy vr_base_min_outlier+orig "${prep_dir}/vr_base_active" -overwrite
    fi

    epi_global_target="${prep_dir}/vr_base_active+orig"

    # ==========================================================================
    # ANATOMICAL RUNS & SESSIONS BENCHMARK LOOP
    # ==========================================================================
    for raw_anat_path in "${anat_target_list[@]}"; do

        anat_filename=$(basename "$raw_anat_path")
        parent_dir=$(basename "$(dirname "$raw_anat_path")")

        # Parse session tag
        ses_part=""
        if [[ "$anat_filename" =~ (ses-[a-zA-Z0-9]+) ]]; then
            ses_part="${BASH_REMATCH[1]}"
        elif [[ "$parent_dir" =~ (ses-[a-zA-Z0-9]+) ]]; then
            ses_part="${BASH_REMATCH[1]}"
        fi

        # Parse run tag
        run_part=""
        if [[ "$anat_filename" =~ (run-[0-9]+) ]]; then
            run_part="${BASH_REMATCH[1]}"
        elif [[ "$parent_dir" =~ (run-[0-9]+) ]]; then
            run_part="${BASH_REMATCH[1]}"
        fi

        # Construct unique tag
        if [ -n "$ses_part" ] && [ -n "$run_part" ]; then
            anat_tag="${ses_part}_${run_part}"
        elif [ -n "$ses_part" ]; then
            anat_tag="${ses_part}"
        elif [ -n "$run_part" ]; then
            anat_tag="${run_part}"
        else
            anat_tag=$(echo "$anat_filename" | sed -E 's/(_nsu.*|\+orig.*)$//; s/^[a-zA-Z0-9]+_//')
            [ -z "$anat_tag" ] && anat_tag="single_anat"
        fi

        out_ses_dir="${base_out_dir}/anat_${anat_tag}"
        mkdir -p "$out_ses_dir"
        log_file="${out_ses_dir}/align_benchmark_${subj_id}_${f_ses}_${anat_tag}.log"
        tsv_report="${out_ses_dir}/alignment_metrics_${subj_id}_${f_ses}_${anat_tag}.tsv"

        {
            echo "######################################################################"
            echo "  BENCHMARK: FUNC SES [$f_ses] vs ANATOMY [$anat_tag]"
            echo "  Target Raw Anatomy  : $raw_anat_path"
            echo "  Output Directory    : $out_ses_dir"
            echo "  Log File            : $log_file"
            echo "######################################################################"

            cd "$out_ses_dir" || exit 1

            3dcopy "$raw_anat_path" "./${subj_id}_anat_input" -overwrite
            3dcopy "$epi_global_target" "./epi_base_active" -overwrite
            epi_target="epi_base_active+orig"

            # Step 2.5: Pre-align centers (ANAT -> EPI)
            echo -e "\n>>> Pre-aligning anatomical center to EPI base..."
            @Align_Centers -base "$epi_target" \
                           -dset "./${subj_id}_anat_input+orig" \
                           -prefix "./${subj_id}_anat_shft" \
                           -overwrite

            anat_target="${subj_id}_anat_shft+orig"
            anat_shft_absolute_path="${out_ses_dir}/${subj_id}_anat_shft+orig"

            # Step 2.6: Robust Geometric Pre-Check
            cm_anat=($(3dCM "$anat_target" 2>/dev/null | tail -n 1))
            cm_epi=($(3dCM "$epi_target" 2>/dev/null | tail -n 1))

            dist_metrics=$(python3 -c "
import math
try:
    x1, y1, z1 = float('${cm_anat[0]}'), float('${cm_anat[1]}'), float('${cm_anat[2]}')
    x2, y2, z2 = float('${cm_epi[0]}'), float('${cm_epi[1]}'), float('${cm_epi[2]}')
    dx, dy, dz = abs(x1 - x2), abs(y1 - y2), abs(z1 - z2)
    euc = math.sqrt(dx**2 + dy**2 + dz**2)
    max_d = max(dx, dy, dz)
    print(f'{dx:.3f} {dy:.3f} {dz:.3f} {euc:.3f} {max_d:.3f}')
except Exception:
    print('0.000 0.000 0.000 0.000 0.000')
")
            read -r dx_mm dy_mm dz_mm dist_euc_mm max_dist_mm <<< "$dist_metrics"

            allcost_out=$(3dAllineate -base "$epi_target" -source "$anat_target" -allcost 2>&1)
            cmass_pct_max=$(echo "$allcost_out" | grep -A 2 "shift search range is +/-" | tail -n 1 | awk '
            {
                gsub("%","",$0); max_pct = 0.0;
                for(i=1;i<=NF;i++) { val = $i + 0.0; if(val > max_pct) max_pct = val; }
                print max_pct;
            }')
            [ -z "$cmass_pct_max" ] && cmass_pct_max="0.0"

            is_ginormous=$(python3 -c "print(1 if ($max_dist_mm >= 25.0 or $cmass_pct_max >= 60.0) else 0)")
            is_giant=$(python3 -c "print(1 if ($max_dist_mm >= 12.0 or $cmass_pct_max >= 30.0) else 0)")
            is_big=$(python3 -c "print(1 if ($max_dist_mm >= 6.0 or $cmass_pct_max >= 15.0) else 0)")

            if [ "$is_ginormous" -eq 1 ]; then
                auto_move="-ginormous_move"; auto_cmass="cmass"
            elif [ "$is_giant" -eq 1 ]; then
                auto_move="-giant_move"; auto_cmass="cmass"
            elif [ "$is_big" -eq 1 ]; then
                auto_move="-big_move"; auto_cmass="cmass"
            else
                auto_move=""; auto_cmass="nocmass"
            fi

            active_move="${user_move:-$auto_move}"
            active_cmass="${user_cmass:-$auto_cmass}"

            # Step 3: Multi-cost Alignment (Rigid Body 6 DOF)
            cost_funcs=(ls lpa lpa+ lpc lpc+ lpc+ZZ mi nmi je hel)

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

            echo "[EXEC] Running align_epi_anat.py..."
            "${align_cmd[@]}"

            # Step 5: Compute Dice Rankings
            3dAutomask -prefix mask_epi_base.nii.gz -overwrite "$epi_target"
            dice_results_file="dice_rankings_${f_ses}_${anat_tag}.txt"
            rm -f "$dice_results_file"

            for cost in "${cost_funcs[@]}"; do
                anat_al_file="${subj_id}_anat_shft_al_${cost}+orig"
                if [ -f "${anat_al_file}.HEAD" ]; then
                    @snapshot_volreg "$epi_target" "$anat_al_file"

                    3dmask_tool -input "$anat_al_file" -prefix "mask_${cost}.nii.gz" -fill_holes -overwrite
                    3dresample -master mask_epi_base.nii.gz -input "mask_${cost}.nii.gz" -prefix "mask_${cost}_rs.nii.gz" -overwrite
                    dice_val=$(3ddot -dodice mask_epi_base.nii.gz "mask_${cost}_rs.nii.gz" 2>/dev/null | awk '{print $1}')
                    [ -z "$dice_val" ] && dice_val="0.0000"

                    echo "${dice_val} ${cost} ${anat_al_file}" >> "$dice_results_file"
                    rm -f "mask_${cost}_rs.nii.gz" "mask_${cost}.nii.gz"
                fi
            done

            sort -k1,1nr -o "$dice_results_file" "$dice_results_file"

            top_candidates=()
            best_cost_name=""
            best_dice_score=""
            rank=1

            while read -r d_score c_name dset_path; do
                if [ $rank -eq 1 ]; then
                    best_cost_name="$c_name"
                    best_dice_score="$d_score"
                fi
                [ $rank -le 3 ] && top_candidates+=("$dset_path")
                ((rank++))
            done < "$dice_results_file"

            # Export local TSV report
            {
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                    "subject_id" "func_ses" "anat_tag" "dist_euc_mm" \
                    "cmass_pct_max" "active_move" "active_cmass" \
                    "cost_function" "dice_coefficient" "is_best_cost" \
                    "fieldmap_applied" "anat_shft_path" "anat_raw_source"

                while read -r d_score c_name dset_path; do
                    is_best="0"
                    [ "$c_name" == "$best_cost_name" ] && is_best="1"
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                        "$subj_id" "$f_ses" "$anat_tag" "$dist_euc_mm" \
                        "$cmass_pct_max" "${active_move:-none}" "$active_cmass" \
                        "$c_name" "$d_score" "$is_best" "$fmap_applied" \
                        "$anat_shft_absolute_path" "$raw_anat_path"
                done < "$dice_results_file"
            } > "$tsv_report"

            # Append to master comparison summary
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "$subj_id" "$f_ses" "$anat_tag" "$fmap_applied" \
                "${active_move:-none}" "$best_cost_name" "$best_dice_score" \
                "$anat_shft_absolute_path" "$raw_anat_path" >> "$master_report"

            # Step 6: Visual @AddEdge on top 3 candidates
            if [ ${#top_candidates[@]} -gt 0 ]; then
                @AddEdge "$epi_target" "${top_candidates[@]}"
            fi

            echo -e "\n[DONE] Finished Pair -> Func: $f_ses | Anat: $anat_tag | Best: $best_cost_name (Dice = $best_dice_score)"

        } 2>&1 | tee "$log_file"

    done

    rm -rf "$prep_dir"
done

# ==============================================================================
# GLOBAL SUMMARY DISPLAY
# ==============================================================================
echo -e "\n======================================================================"
echo "          MULTI-ANATOMICAL BENCHMARKING GLOBAL SUMMARY [V7]           "
echo "======================================================================"
cat "$master_report" | column -t -s $'\t'
echo "======================================================================"
echo " Master report saved at: $master_report"
echo "++ ALL REQUESTED COMBINATIONS COMPLETED FOR: $subj_id"

exit 0
