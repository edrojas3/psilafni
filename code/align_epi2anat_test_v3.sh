#!/bin/bash

# ==============================================================================
# Script Name : align_epi2anat_test_v2.sh
# Language    : BASH
# Description : Benchmarking script for EPI-to-Anatomical alignment cost
#               functions in AFNI. Conditionally handles B0 distortion unwarping
#               if fieldmaps (magnitude/phasediff) exist for the subject/session.
#
# Usage:
#   ./align_epi2anat_test_v2.sh -d <site_dir> -s <subj_id> -a <aw_dir> [-ses <session_str>]
#   ./align_epi2anat_test_v2.sh -h
# ==============================================================================

# Helper function to display usage and help documentation
show_help() {
    cat << EOF

==============================================================================
  ALIGNMENT COST FUNCTION BENCHMARKING (EPI -> ANAT) - HELP
==============================================================================

Description:
  Automates cost function testing for fMRI-to-Anatomical alignment in AFNI:
    1. Locates target anatomy from @animal_warper outputs (isolated per subject).
    2. Identifies Resting-State BOLD runs.
    3. Truncates pre-steady state TRs and computes global minimum outlier TR.
    4. (OPTIONAL) Conditionally detects Magnitude + PhaseDiff fieldmaps, unwraps
       phase, converts to Hz, and unwarps EPI base distortion.
    5. Runs 'align_epi_anat.py' with -multi_cost.
    6. Generates visual snapshots using '@snapshot_volreg'.

Usage:
  $0 -d <site_dir> -s <subj_id> -a <aw_dir> [-ses <session_string>]
  $0 -h

Required Flags:
  -d <path> : Absolute path to BIDS site directory (e.g., /path/to/site-ion)
  -s <id>   : Unique subject ID (e.g., sub-032198)
  -a <path> : Absolute path to @animal_warper directory for the site
              (e.g., /path/to/site-ion/data_aw)

Optional Flags:
  -ses <str>: Specific session string filter (e.g., 'ses-001' or 'ses-002').
  -h, --help: Display this help message and exit.

==============================================================================
EOF
    exit 0
}

# 1. Display help if no arguments or help flags are provided
if [ $# -eq 0 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
fi

# Initialize argument variables
site_dir=""
subj_id=""
aw_dir=""
ses_id=""

# Parse command line flags
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
            ses_id="$2"
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

# Check existence of input directories
if [ ! -d "$site_dir/$subj_id" ]; then
    echo "[ERROR] Subject directory not found: $site_dir/$subj_id"
    exit 1
fi

if [ ! -d "$aw_dir" ]; then
    echo "[ERROR] Animal Warper root directory not found: $aw_dir"
    exit 1
fi

# ------------------------------------------------------------------------------
# STEP 0: LOCATE TARGET ANATOMICAL IMAGE
# ------------------------------------------------------------------------------
aw_subj_dir="$aw_dir/$subj_id"

if [ ! -d "$aw_subj_dir" ]; then
    echo "[ERROR] Subject Animal Warper folder not found: $aw_subj_dir"
    exit 1
fi

echo -e "\n>>> STEP 0: Locating Target Anatomical Image for $subj_id in $aw_subj_dir..."

if [ -n "$ses_id" ]; then
    echo "[INFO] Filtering anatomy by session pattern: '$ses_id'..."
    mapfile -t all_anats < <(find "$aw_subj_dir" -type f \( -name "*${ses_id}*nsu.nii.gz" -o -name "*${ses_id}*nsu.HEAD" \) ! -name "*warp2std*" | sort)
else
    mapfile -t all_anats < <(find "$aw_subj_dir" -type f \( -name "*_nsu.nii.gz" -o -name "*_nsu.HEAD" \) ! -name "*warp2std*" | sort)
fi

num_anats=${#all_anats[@]}

if [ "$num_anats" -eq 0 ]; then
    echo "[ERROR] Could not find any native '_nsu' volume in: $aw_subj_dir (Filter: '$ses_id')"
    exit 1
elif [ "$num_anats" -gt 1 ]; then
    echo "[WARNING] Found $num_anats anatomical options for $subj_id:"
    for a in "${all_anats[@]}"; do
        echo "  - $a"
    done
    anat_nsu_file="${all_anats[0]}"
    echo "[INFO] Defaulting to first option: $anat_nsu_file"
else
    anat_nsu_file="${all_anats[0]}"
fi

# Output directory isolation
out_dir="${site_dir}/align_tests_cost_functions/${subj_id}"
[ -n "$ses_id" ] && out_dir="${out_dir}/${ses_id}"
mkdir -p "$out_dir"
cd "$out_dir" || exit 1

echo "=================================================="
echo " STARTING BASH ALIGNMENT BENCHMARK FOR: $subj_id"
echo " Site Directory : $site_dir"
echo " AW Directory   : $aw_subj_dir"
echo " Output Dir     : $out_dir"
echo " Target Anat    : $anat_nsu_file"
echo "=================================================="

3dcopy "$anat_nsu_file" "./${subj_id}_anat_nsu" -overwrite

# ------------------------------------------------------------------------------
# STEP 1: FIND RESTING STATE RUNS
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 1: Locating Resting-State BOLD runs..."

search_root="$site_dir/$subj_id"
[ -n "$ses_id" ] && search_root="$site_dir/$subj_id/$ses_id"

mapfile -t rs_runs < <(find "$search_root" -type f \( -name "*task-rest*bold*.nii*" -o -name "*task-resting*bold*.nii*" \) ! -name "*fmap*" ! -name "*magnitude*" ! -name "*phasediff*" ! -name "*dir-*" | sort)

num_runs=${#rs_runs[@]}

if [ "$num_runs" -eq 0 ]; then
    echo "[ERROR] No resting-state fMRI runs found for $subj_id."
    exit 1
fi

echo "[INFO] Found $num_runs resting-state run(s):"
for r in "${rs_runs[@]}"; do
    echo "  - $r"
done

# ------------------------------------------------------------------------------
# STEP 2: PROCESS TRs & CALCULATE GLOBAL MINIMUM OUTLIER BASE
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 2: Processing TRs and calculating minimum outlier base..."

run_idx=1
tr_counts=()

for run_path in "${rs_runs[@]}"; do
    run_str=$(printf "%02d" $run_idx)
    tcat_prefix="pb00.${subj_id}.r${run_str}.tcat"
    
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

echo "[SUCCESS] Global minimum outlier TR found -> Run: $minoutrun, TR: $minouttr"

3dbucket -prefix vr_base_min_outlier -overwrite \
    "pb00.${subj_id}.r${min_run_str}.tcat+orig[${minouttr}]"

# ------------------------------------------------------------------------------
# STEP 2.5: CONDITIONAL FIELDMAP CORRECTION (B0 UNWARPING)
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 2.5: Checking for Fieldmap sequences..."

# Search strictly for magnitude and phasediff files within the subject/session space
fmap_mag=$(find "$search_root" -type f -name "*magnitude*.nii*" | sort | head -n 1)
fmap_phase=$(find "$search_root" -type f -name "*phasediff*.nii*" | sort | head -n 1)
fmap_json=$(find "$search_root" -type f -name "*phasediff*.json" | sort | head -n 1)

if [ -n "$fmap_mag" ] && [ -n "$fmap_phase" ]; then
    echo "[INFO] Fieldmap detected! Starting B0 distortion correction..."
    echo "       - Magnitude : $fmap_mag"
    echo "       - PhaseDiff : $fmap_phase"

    # Extract DeltaTE from JSON if present, else fallback to standard 0.00246 s (2.46 ms)
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
    echo "       - Delta TE  : $delta_te seconds"

    # Copy and mask magnitude
    3dcopy "$fmap_mag" ./fmap_mag -overwrite
    3dAutomask -prefix fmap_mag_mask.nii.gz -overwrite ./fmap_mag+orig

    # Rescale phase to [-PI, PI] and unwrap
    3dcalc -a "$fmap_phase" \
           -expr '(a - 2048) * 3.14159265 / 2048' \
           -prefix phasediff_rad.nii.gz -overwrite

    3dUnwrap -prefix fmap_unwrapped.nii.gz -overwrite phasediff_rad.nii.gz

    # Convert unwrapped phase to Fieldmap in Hz
    3dcalc -a fmap_unwrapped.nii.gz -b fmap_mag_mask.nii.gz \
           -expr "(a / (2 * 3.14159265 * ${delta_te})) * b" \
           -prefix fmap_hz.nii.gz -overwrite

    # Rigid-align fieldmap magnitude to base EPI
    align_epi_anat.py \
        -dset1 vr_base_min_outlier+orig \
        -dset2 ./fmap_mag+orig \
        -dset2to1 \
        -child_dset2 fmap_hz.nii.gz \
        -cost nmi \
        -rigid_body \
        -overwrite

    # Warp and apply unwarping
    3dQwarp -plusminus -pmNAMES fmap_warp \
            -base vr_base_min_outlier+orig \
            -source ./fmap_mag_al+orig \
            -prefix fmap_qwarp -overwrite

    3dNwarpApply -nwarp fmap_warp_PLUS_WARP+orig \
                 -source vr_base_min_outlier+orig \
                 -master vr_base_min_outlier+orig \
                 -prefix vr_base_min_outlier_unwarped -overwrite

    epi_target="vr_base_min_outlier_unwarped+orig"
    echo "[SUCCESS] Unwarping completed. Benchmarking will use: $epi_target"
else
    echo "[INFO] No complete Fieldmap pair (magnitude + phasediff) found."
    echo "[INFO] Proceeding with standard native EPI base without B0 unwarping."
    epi_target="vr_base_min_outlier+orig"
fi

# ------------------------------------------------------------------------------
# STEP 3: MULTI-COST ALIGNMENT TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 3: Running align_epi_anat.py with -multi_cost on $epi_target..."

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

# ------------------------------------------------------------------------------
# STEP 4: GENERATE QC SNAPSHOTS
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 4: Generating Quality Control (QC) Snapshots..."

cost_funcs=(lpa lpa+ lpc lpc+ lpc+ZZ mi nmi je hel)

for cost in "${cost_funcs[@]}"; do
    anat_al_file="${subj_id}_anat_nsu_al_${cost}+orig"
    
    if [ -f "${anat_al_file}.HEAD" ]; then
        @snapshot_volreg "$epi_target" "$anat_al_file"
    fi
done

echo "=================================================="
echo "++ BASH ALIGNMENT BENCHMARK COMPLETED FOR: $subj_id"
echo "++ Target Volume Used : $epi_target"
echo "++ Check PNG/GIF snapshots in: $out_dir"
echo "=================================================="

exit 0
