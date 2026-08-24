#!/bin/bash
# ==============================================================================
# Script Name : prepared_alignment_metrics.sh
# Language    : BASH
# Description : Audits BIDS site subjects, filters the optimal anatomical run
#               and cost function per functional session, resolves fieldmap
#               paths/dwell times, and outputs a consolidated TSV for afni_proc.
# Usage       : ./get_alignment_metrics.sh [-d <site_directory>] [-h]
# ==============================================================================

set -eo pipefail

show_help() {
    cat << EOF
Usage: $0 [-d <site_directory>] [-h]
  -d <path> : Path to BIDS site root directory (default: current directory)
  -h        : Show this help message
EOF
    exit 0
}

site_path="$(pwd)"

while getopts "d:h" opt; do
    case "$opt" in
        d) site_path="$(cd "$OPTARG" && pwd)" ;;
        h) show_help ;;
        *) show_help ;;
    esac
done

site_name=$(basename "$site_path")

# ------------------------------------------------------------------------------
# 1. DETECT BENCHMARK DIRECTORY
# ------------------------------------------------------------------------------
bench_dir=""
for candidate in "align_tests_centered" "align_tests_centered_fmap" "align_tests_cost_functions" "alignment_test"; do
    if [ -d "${site_path}/${candidate}" ]; then
        bench_dir="${site_path}/${candidate}"
        bench_dir_name="$candidate"
        break
    fi
done

if [ -z "$bench_dir" ]; then
    echo -e "\e[31m[ERROR] No alignment benchmark folder found in: $site_path\e[0m"
    exit 1
fi

echo "======================================================================"
echo " AUDITING & HARVESTING OPTIMAL ALIGNMENTS: $site_name"
echo " Site Path           : $site_path"
echo " Benchmark Directory : $bench_dir_name"
echo "======================================================================"

# ------------------------------------------------------------------------------
# 2. AUDIT BIDS DIRECTORY SUBJECTS
# ------------------------------------------------------------------------------
echo -e "\n>>> [AUDIT] Checking BIDS subjects against benchmark directory..."
mapfile -t bids_subjects < <(find "$site_path" -maxdepth 1 -mindepth 1 -type d -name "sub-*" -exec basename {} \; | sort)

missing_subjects=()
processed_subjects=()

for s_id in "${bids_subjects[@]}"; do
    s_bench_path="${bench_dir}/${s_id}"
    if [ ! -d "$s_bench_path" ]; then
        echo -e "  \e[33m[WARNING]\e[0m Subject '$s_id' exists in BIDS root but has NO benchmark directory."
        missing_subjects+=("$s_id")
    else
        num_reports=$(find "$s_bench_path" -type f -name "alignment_metrics_*.tsv" | wc -l)
        if [ "$num_reports" -eq 0 ]; then
            echo -e "  \e[33m[WARNING]\e[0m Subject '$s_id' exists but has NO completed 'alignment_metrics_*.tsv'."
            missing_subjects+=("$s_id")
        else
            processed_subjects+=("$s_id")
        fi
    fi
done

echo "[AUDIT] Total BIDS Subjects Found : ${#bids_subjects[@]}"
echo "[AUDIT] Benchmarked Subjects      : ${#processed_subjects[@]}"
echo "[AUDIT] Incomplete / Missing      : ${#missing_subjects[@]}"

# ------------------------------------------------------------------------------
# 3. DISCOVER & HARVEST METRIC TSVs
# ------------------------------------------------------------------------------
mapfile -t metric_files < <(find "$bench_dir" -type f -name "alignment_metrics_*.tsv" | sort)

if [ ${#metric_files[@]} -eq 0 ]; then
    echo -e "\e[31m[ERROR] No 'alignment_metrics_*.tsv' files found in '$bench_dir'.\e[0m"
    exit 1
fi

output_tsv="${bench_dir}/${site_name}_best_alignment_parameters.tsv"
rm -f "$output_tsv"

# Header with complete spatial and fmap metadata
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "subject_id" "func_session" "best_anat_tag" "fieldmap_applied" \
    "dist_euc_mm" "active_move" "active_cmass" "best_cost" \
    "best_dice" "dwell_time_s" "best_anat_path" "fieldmap_path" > "$output_tsv"

echo -e "\n>>> [HARVEST] Filtering best anatomical result & metadata per session..."

# Aggregate top Dice row per (subject, func_session)
raw_best_lines=$(for tsv in "${metric_files[@]}"; do
    tail -n +2 "$tsv"
done | awk -F'\t' '
{
    key = $1 FS $2
    dice = $9 + 0.0
    if (dice > max_dice[key]) {
        max_dice[key] = dice
        best_line[key] = $1 FS $2 FS $3 FS $11 FS $4 FS $6 FS $7 FS $8 FS $9 FS $12
    }
}
END {
    for (k in best_line) {
        print best_line[k]
    }
}' OFS='\t' | sort -k1,1 -k2,2)

# ------------------------------------------------------------------------------
# 4. RESOLVE FIELDMAP PATHS & DWELL TIMES
# ------------------------------------------------------------------------------
while IFS=$'\t' read -r subj ses atg fm euc mv cm co di ap; do
    fmap_file="none"
    dwell_val="none"

    if [ "$fm" == "true" ]; then
        cand_1="${site_path}/fieldmaps_prepared_all/${subj}/${ses}/fmap_prepared/fmap_rads.nii.gz"
        cand_2="${site_path}/fieldmaps_prepared_all/${subj}/ses-default/fmap_prepared/fmap_rads.nii.gz"
        cand_3="${site_path}/${subj}/${ses}/fmap_prepared/fmap_rads.nii.gz"

        if [ -f "$cand_1" ]; then
            fmap_file="$cand_1"
        elif [ -f "$cand_2" ]; then
            fmap_file="$cand_2"
        elif [ -f "$cand_3" ]; then
            fmap_file="$cand_3"
        else
            fmap_file="not_found"
        fi

        # Extract Dwell Time / EffectiveEchoSpacing from functional JSON
        bold_json=$(find "${site_path}/${subj}/${ses}" -type f \( -name "*task-rest*bold*.json" -o -name "*task-resting*bold*.json" \) 2>/dev/null | head -n 1)
        if [ -f "$bold_json" ]; then
            dwell_val=$(python3 -c "
import json
try:
    d = json.load(open('$bold_json'))
    val = d.get('EffectiveEchoSpacing', d.get('DwellTime', None))
    if val: print(f'{float(val):.7f}')
    else: print('0.0006500')
except:
    print('0.0006500')
" 2>/dev/null)
        else
            dwell_val="0.0006500"
        fi
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$subj" "$ses" "$atg" "$fm" "$euc" "$mv" "$cm" "$co" "$di" "$dwell_val" "$ap" "$fmap_file" >> "$output_tsv"
done <<< "$raw_best_lines"

# ------------------------------------------------------------------------------
# 5. DISPLAY CONSOLIDATED REPORT
# ------------------------------------------------------------------------------
echo -e "\n========================================================================================="
echo "                    OPTIMAL ALIGNMENT CONFIGURATION PER FUNCTIONAL SESSION               "
echo "========================================================================================="
printf "%-12s | %-8s | %-15s | %-6s | %-10s | %-8s | %-10s\n" \
    "SUBJ" "FUNC_SES" "BEST_ANAT" "FMAP" "BEST_COST" "DICE" "DWELL_TIME"
echo "-----------------------------------------------------------------------------------------"
tail -n +2 "$output_tsv" | while IFS=$'\t' read -r s fs atg fm euc mv cm co di dw ap fmp; do
    printf "%-12s | %-8s | %-15s | %-6s | %-10s | %-8s | %-10s\n" \
        "$s" "$fs" "$atg" "$fm" "$co" "$di" "$dw"
done
echo "========================================================================================="

echo -e "\n\e[32m[SUCCESS] Master parameter table generated:\e[0m"
echo "  -> $output_tsv"
