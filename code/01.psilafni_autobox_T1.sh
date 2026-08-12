#!/bin/bash

# ==============================================================================
# Description: Reduces the FOV of anatomical images (T1w) to isolate the head
#              tissue and prevent issues during anatomical preprocessing.
#              Calls AFNI's 3dAutobox individually for each file found.
# ==============================================================================

# Helper function for user guidance
usage() {
    echo -e "\n[ERROR] Missing required arguments!"
    echo -e "Usage: $0 <path_to_bids_folder> <subject_id>\n"
    echo -e "Example:"
    echo -e "  $0 /project/rrg-mchakrav-ab/afajardo/github/psilafni/bids sub-01\n"
    exit 1
}

# 1. Check if both required arguments were provided
if [ -z "$1" ] || [ -z "$2" ]; then
    usage
fi

# INPUTS
site="$1" # PATH OF YOUR BIDS (OR BIDS-LIKE) FOLDER
subj="$2" # ID OF SUBJECT TO PROCESS

# 2. Check if AFNI's 3dAutobox is available in PATH
if ! command -v 3dAutobox &> /dev/null; then
    echo "[ERROR] '3dAutobox' command not found. Please ensure AFNI is loaded/installed."
    exit 1
fi

# 3. Check if the subject directory exists
if [ ! -d "$site/$subj" ]; then
    echo "[ERROR] Subject directory not found: $site/$subj"
    exit 1
fi

echo "=================================================="
echo " Starting 3dAutobox processing for: $subj"
echo " Search Directory: $site/$subj"
echo "=================================================="

# 4. Find all T1w anatomical images (handles .nii and .nii.gz)
# Mapfile reads all matches into an array to handle spaces and line breaks properly
mapfile -t anat_files < <(find "$site/$subj" -type f -name "${subj}*T1w.nii*" ! -name "*_boxed.nii*")

# Check if any matching files were found
if [ ${#anat_files[@]} -eq 0 ]; then
    echo "[WARNING] No T1w anatomical images found for $subj in $site/$subj"
    exit 0
fi

echo "[INFO] Found ${#anat_files[@]} T1w image(s) to process."

# 5. Process each file individually to prevent 3dAutobox from crashing
for subj_anat in "${anat_files[@]}"; do
    echo "--------------------------------------------------"
    echo "Processing file: $subj_anat"
    
    # Generate output prefix dynamically for .nii or .nii.gz
    if [[ "$subj_anat" == *.nii.gz ]]; then
        prefix_anat="${subj_anat%.nii.gz}_boxed.nii.gz"
    elif [[ "$subj_anat" == *.nii ]]; then
        prefix_anat="${subj_anat%.nii}_boxed.nii"
    else
        prefix_anat="${subj_anat}_boxed"
    fi

    # Execute 3dAutobox
    3dAutobox -input "$subj_anat" -prefix "$prefix_anat"

    if [ $? -eq 0 ]; then
        echo "[SUCCESS] Saved autoboxed file to: $prefix_anat"
    else
        echo "[ERROR] 3dAutobox failed for file: $subj_anat"
    fi
done

echo "--------------------------------------------------"
echo "++ ALL DONE FOR SUBJECT: $subj"
