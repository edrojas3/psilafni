#!/bin/bash
# ==============================================================================
# Script Name : get_alignment_metrics.sh
# Language    : BASH
# Description : Audits BIDS site subjects against benchmark outputs, harvests
#               the winning parameters, and guarantees the RAW anatomy path
#               from data_aw is exported for afni_proc.py consumption.
# Usage       : ./get_alignment_metrics.sh (Run inside the BIDS site folder)
# ==============================================================================

set -eo pipefail

site_path=$(pwd)
site_name=$(basename "$site_path")
bench_dir="${site_path}/align_tests_centered"

if [ ! -d "$bench_dir" ]; then
    echo "[ERROR] No alignment test directory found at: $bench_dir"
    exit 1
fi

echo "======================================================================"
echo " HARVESTING ALIGNMENT BENCHMARK METRICS: $site_name"
echo " Site Path        : $site_path"
echo " Benchmark Folder : $(basename "$bench_dir")"
echo "======================================================================"

# ------------------------------------------------------------------------------
# STEP 1: AUDIT SUBJECTS
# ------------------------------------------------------------------------------
mapfile -t bids_subjects < <(find "$site_path" -maxdepth 1 -mindepth 1 -type d -name "sub-*" -exec basename {} \; | sort)

if [ ${#bids_subjects[@]} -eq 0 ]; then
    echo "[ERROR] No 'sub-*' directories found in current directory: $site_path"
    exit 1
fi

missing_subjects=()
processed_subjects=()

for s_id in "${bids_subjects[@]}"; do
    s_bench_path="${bench_dir}/${s_id}"
    if [ ! -d "$s_bench_path" ]; then
        echo "  [WARNING] Subject '$s_id' exists in BIDS root but has NO benchmark folder."
        missing_subjects+=("$s_id")
    else
        num_reports=$(find "$s_bench_path" -type f -name "alignment_metrics_*.tsv" | wc -l)
        if [ "$num_reports" -eq 0 ]; then
            echo "  [WARNING] Subject '$s_id' folder exists but has NO completed 'alignment_metrics_*.tsv'."
            missing_subjects+=("$s_id")
        else
            processed_subjects+=("$s_id")
        fi
    fi
done

echo "[AUDIT] Total BIDS Subjects Found : ${#bids_subjects[@]}"
echo "[AUDIT] Benchmarked Subjects      : ${#processed_subjects[@]}"
echo "[AUDIT] Missing / Incomplete      : ${#missing_subjects[@]}"

# ------------------------------------------------------------------------------
# STEP 2: AGGREGATE BEST PARAMETERS WITH RAW ANATOMY PATHS
# ------------------------------------------------------------------------------
afni_proc_params_tsv="${bench_dir}/${site_name}_best_alignment_parameters.tsv"
rm -f "$afni_proc_params_tsv"

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "subject_id" "func_session" "best_anat_tag" "fieldmap_applied" \
    "dist_euc_mm" "active_move" "active_cmass" "best_cost" \
    "best_dice" "dwell_time_s" "best_anat_path" "fieldmap_path" > "$afni_proc_params_tsv"

mapfile -t metric_files < <(find "$bench_dir" -type f -name "alignment_metrics_*.tsv" | sort)

for tsv in "${metric_files[@]}"; do
    # Select winning row
    best_row=$(awk -F'\t' '$10 == "1" {print $0}' "$tsv" | head -n 1)
    [ -z "$best_row" ] && best_row=$(tail -n +2 "$tsv" | sort -t$'\t' -k9,9nr | head -n 1)

    if [ -n "$best_row" ]; then
        subj=$(echo "$best_row" | awk -F'\t' '{print $1}')
        ses=$(echo "$best_row" | awk -F'\t' '{print $2}')
        anat_tag=$(echo "$best_row" | awk -F'\t' '{print $3}')
        dist_euc=$(echo "$best_row" | awk -F'\t' '{print $4}')
        act_move=$(echo "$best_row" | awk -F'\t' '{print $6}')
        act_cmass=$(echo "$best_row" | awk -F'\t' '{print $7}')
        b_cost=$(echo "$best_row" | awk -F'\t' '{print $8}')
        b_dice=$(echo "$best_row" | awk -F'\t' '{print $9}')
        fmap_app=$(echo "$best_row" | awk -F'\t' '{print $11}')
        # Extract strictly the RAW anatomy source (last column of alignment_metrics_*.tsv)
        raw_anat_src=$(echo "$best_row" | awk -F'\t' '{print $NF}')

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$subj" "$ses" "$anat_tag" "$fmap_app" \
            "$dist_euc" "$act_move" "$act_cmass" "$b_cost" \
            "$b_dice" "none" "$raw_anat_src" "none" >> "$afni_proc_params_tsv"
    fi
done

echo -e "\n======================================================================"
echo "                  AFNI_PROC OPTIMAL PARAMETERS PER RUN                "
echo "======================================================================"
cat "$afni_proc_params_tsv" | column -t -s $'\t'
echo "======================================================================"
echo "[SUCCESS] Generated: $afni_proc_params_tsv"
