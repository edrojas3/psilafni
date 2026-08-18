#!/bin/bash

# ==============================================================================
# Pipeline: PSILAFNI Anatomical Processing Pipeline (AFNI)
# Description: 
#   1. Reduces FOV around the head using 3dAutobox.
#   2. Registers anatomical images (T1w) to NMT v2.1 standard template 
#      and performs brain extraction using @animal_warper.
#
# Usage:
#   ./psilafni_anat_pipeline.sh -d <path_to_bids_folder> -s <subject_id>
#   ./psilafni_anat_pipeline.sh [-h | --help]
# ==============================================================================

# Helper function to display script documentation
show_help() {
    cat << EOF

==============================================================================
  PSILAFNI ANATOMICAL PROCESSING PIPELINE - HELP
==============================================================================

Description:
  This script automates anatomical processing for non-human primate MRI:
    - Step 1: Runs '3dAutobox' on raw T1w images to remove neck/body tissue.
    - Step 2: Runs '@animal_warper' on boxed T1w images for registration 
              and brain extraction using the NMT v2.1 sym template.

Usage:
  $0 -d <bids_dir> -s <subject_id>
  $0 [-h | --help]

Required Flags:
  -d <path> : Absolute path to your BIDS or BIDS-like root directory.
  -s <id>   : Unique subject ID (e.g., sub-01).

Options:
  -h        : Display this help message and exit.

Examples:
  $ $0 -d /project/rrg-mchakrav-ab/afajardo/github/psilafni/bids -s sub-01
  $ $0 -s sub-01 -d /path/to/bids
  $ $0 -h

System Requirements:
  - AFNI toolsuite must be loaded in your environment PATH.
  - Template directory must exist at: /AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm

==============================================================================
EOF
    exit 0
}

# 1. Display help if requested or if no arguments are passed
if [ $# -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "help" ]]; then
    show_help
fi

# Initialize variables
site=""
subj=""

# Parse flags using getopts
while getopts "d:s:h" opt; do
  case $opt in
    d) site="$OPTARG" ;;
    s) subj="$OPTARG" ;;
    h) show_help ;;
    \?) echo -e "\n[ERROR] Invalid option: -$OPTARG" >&2; show_help ;;
  esac
done

# Validate that mandatory flags were provided
if [ -z "$site" ] || [ -z "$subj" ]; then
    echo -e "\n[ERROR] Both flags '-d' (directory) and '-s' (subject) are required!"
    show_help
fi

# 2. System and Dependency Checks
if ! command -v 3dAutobox &> /dev/null || ! command -v @animal_warper &> /dev/null; then
    echo "[ERROR] AFNI tools (3dAutobox / @animal_warper) not found in PATH."
    echo "        Please ensure AFNI is properly loaded in your environment."
    exit 1
fi

if [ ! -d "$site/$subj" ]; then
    echo "[ERROR] Subject directory not found: $site/$subj"
    exit 1
fi

refdir="/AFNI/NMT_v2.1_sym/NMT_v2.1_sym_05mm"
refvol="${refdir}/NMT_v2.1_sym_05mm_SS.nii.gz"
refmask="${refdir}/NMT_v2.1_sym_05mm_brainmask.nii.gz"

if [ ! -f "$refvol" ]; then
    echo "[ERROR] Reference volume not found at: $refvol"
    echo "        Verify that the NMT template is installed at the expected path."
    exit 1
fi

echo "=================================================="
echo " STARTING ANATOMICAL PIPELINE FOR: $subj"
echo " Working Directory: $site/$subj"
echo "=================================================="

# ------------------------------------------------------------------------------
# STEP 1: 3dAutobox (FOV Reduction)
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 1: Running 3dAutobox..."

# Find all original T1w images (skipping previously boxed files)
mapfile -t raw_anat_files < <(find "$site/$subj" -type f -name "${subj}*T1w.nii*" ! -name "*_boxed.nii*")

if [ ${#raw_anat_files[@]} -eq 0 ]; then
    echo "[WARNING] No raw T1w images found for $subj. Checking if pre-boxed files exist..."
else
    echo "[INFO] Found ${#raw_anat_files[@]} raw T1w image(s) to box."

    for raw_anat in "${raw_anat_files[@]}"; do
        echo "Processing FOV reduction for: $raw_anat"

        # Determine boxed output path
        if [[ "$raw_anat" == *.nii.gz ]]; then
            prefix_anat="${raw_anat%.nii.gz}_boxed.nii.gz"
        elif [[ "$raw_anat" == *.nii ]]; then
            prefix_anat="${raw_anat%.nii}_boxed.nii"
        else
            prefix_anat="${raw_anat}_boxed"
        fi

        # Run 3dAutobox
        3dAutobox -input "$raw_anat" -prefix "$prefix_anat"

        if [ $? -eq 0 ]; then
            echo "[SUCCESS] Autoboxed file saved: $prefix_anat"
        else
            echo "[ERROR] 3dAutobox failed for: $raw_anat"
        fi
    done
fi

# ------------------------------------------------------------------------------
# STEP 2: @animal_warper (Template Alignment & Brain Extraction)
# ------------------------------------------------------------------------------
echo -e "\n>>> STEP 2: Running @animal_warper..."

# Find all autoboxed anatomical images
mapfile -t boxed_anat_files < <(find "$site/$subj" -type f -name "${subj}*T1*boxed*nii*")

if [ ${#boxed_anat_files[@]} -eq 0 ]; then
    echo "[ERROR] No boxed T1w images found for $subj. Step 2 cannot proceed."
    exit 1
fi

echo "[INFO] Found ${#boxed_anat_files[@]} boxed T1w file(s) for registration."

for subj_anat in "${boxed_anat_files[@]}"; do
    fname=$(basename "$subj_anat")
    
    # Extract base name for clean file labeling (e.g., sub-01_run-01_T1w)
    base_name=$(echo "$fname" | sed -E 's/\_boxed\.nii(\.gz)?$//; s/\.nii(\.gz)?$//')
    
    # Organize outputs into separate folders if multiple runs exist
    if [ ${#boxed_anat_files[@]} -gt 1 ]; then
        outdir="${site}/data_aw/${subj}/${base_name}"
    else
        outdir="${site}/data_aw/${subj}"
    fi

    echo "--------------------------------------------------"
    echo "++ Preprocessing File : $fname"
    echo "++ Label Abbreviation : $base_name"
    echo "++ Output Directory   : $outdir"
    echo "--------------------------------------------------"

    mkdir -p "$outdir"

    # Execute @animal_warper
    @animal_warper \
      -input "$subj_anat" \
      -input_abbrev "$base_name" \
      -base "$refvol" \
      -base_abbrev NMT_v2.1_sym \
      -atlas_followers "${refdir}/CHARM_in_NMT_v2.1_sym_05mm.nii.gz" "${refdir}/D99_atlas_in_NMT_v2.1_sym_05mm.nii.gz" \
      -atlas_abbrevs CHARM D99 \
      -no_skullstrip \
      -seg_followers "${refdir}/NMT_v2.1_sym_05mm_segmentation.nii.gz" "${refdir}/supplemental_masks/NMT_v2.1_sym_05mm_ventricles.nii.gz" \
      -seg_abbrevs SEG VENT \
      -outdir "$outdir" \
      -ok_to_exist \
      -no_surfaces \
      -echo

    if [ $? -eq 0 ]; then
        echo "++ [SUCCESS] Completed @animal_warper for: $fname"
    else
        echo "[ERROR] @animal_warper failed for: $fname"
    fi
done

echo "--------------------------------------------------"
echo "++ ALL ANATOMICAL PROCESSING COMPLETED FOR: $subj"
exit 0
