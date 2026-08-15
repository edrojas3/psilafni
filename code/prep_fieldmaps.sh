#!/bin/bash

# ==============================================================================
# Script Name : prep_fieldmaps.sh
# Description : Independent BIDS Fieldmap Preprocessing Script for Non-Human Primates.
#               Computes absolute B0 field maps using FSL (prelude, fugue) and AFNI.
#               Outputs results to a centralized folder inside the dataset directory (-d).
# Usage       : ./prep_fieldmaps.sh -d <dataset_directory> -s <subject_id>
# ==============================================================================

# Exit immediately if any command exits with a non-zero status
set -e

# ------------------------------------------------------------------------------
# Helper Function: Print usage instructions
# ------------------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 -d <dataset_directory> -s <subject_id>"
    echo "  -d : Path to the root dataset directory (outputs will be stored here)"
    echo "  -s : Subject ID to process (e.g., sub-032199)"
    echo "  -h : Display this help message"
    exit 1
}

# ------------------------------------------------------------------------------
# Helper Function: Process individual fieldmap session data
# Arguments: 
#   $1 -> Magnitude raw file path
#   $2 -> Phasediff raw file path
#   $3 -> Phasediff json file path
#   $4 -> Output directory for prepared fieldmap
# ------------------------------------------------------------------------------
process_fieldmap_session() {
    local mag_file="$1"
    local phase_file="$2"
    local json_file="$3"
    local out_dir="$4"

    echo "==> [HELPER] Starting fieldmap processing pipeline..."
    
    # Create a secure local temporary working directory
    local temp_dir
    temp_dir=$(mktemp -d)
    pushd "$temp_dir" > /dev/null

    # 1. Extract Delta TE dynamically from the JSON sidecar file using Python
    echo "==> [HELPER] Step 1: Extracting Delta TE from JSON metadata..."
    local delta_te
    delta_te=$(python3 -c "import json; data=json.load(open('$json_file')); print(round(data['EchoTime2'] - data['EchoTime1'], 6))")
    echo "    Detected Delta TE: $delta_te seconds"

    # 2. Convert raw Siemens phasediff integers [0, 4094] to physical radians [-pi, +pi]
    echo "==> [HELPER] Step 2: Converting raw phase to radians [-pi, +pi]..."
    3dcalc -a "$phase_file" \
           -expr '(a * 0.0015339808) - 3.14159265' \
           -prefix phasediff_rad.nii.gz \
           -overwrite > /dev/null 2>&1

    # 3. Generate a clean tissue mask from the magnitude image
    echo "==> [HELPER] Step 3: Generating clean brain/tissue mask from magnitude..."
    3dAutomask -prefix fmap_mag_mask.nii.gz -clfrac 0.58 -overwrite "$mag_file" > /dev/null 2>&1
    3dmask_tool -input fmap_mag_mask.nii.gz \
                -prefix fmap_mag_mask_clean.nii.gz \
                -fill_holes \
                -dilate_inputs -1 \
                -overwrite > /dev/null 2>&1
    
    3dcalc -a "$mag_file" \
           -b fmap_mag_mask_clean.nii.gz \
           -expr 'a*b' \
           -prefix fmap_mag_brain.nii.gz \
           -overwrite > /dev/null 2>&1

    # 4. Perform phase unwrapping using FSL prelude
    echo "==> [HELPER] Step 4: Unwrapping phase discontinuities (FSL prelude)..."
    prelude -a fmap_mag_brain.nii.gz \
            -p phasediff_rad.nii.gz \
            -u fmap_unwrapped_rad.nii.gz \
            -m fmap_mag_mask_clean.nii.gz

    # 5. Convert unwrapped phase to absolute field map in radians per second (rad/s)
    echo "==> [HELPER] Step 5: Converting to absolute field map (rad/s)..."
    fslmaths fmap_unwrapped_rad.nii.gz -div "$delta_te" fmap_rads.nii.gz

    # 6. Copy clean final results to the structured output directory
    mkdir -p "$out_dir"
    cp fmap_rads.nii.gz "${out_dir}/fmap_rads.nii.gz"
    cp fmap_mag_brain.nii.gz "${out_dir}/fmap_mag_brain.nii.gz"
    cp fmap_mag_mask_clean.nii.gz "${out_dir}/fmap_mag_mask_clean.nii.gz"
    echo "$delta_te" > "${out_dir}/delta_te.txt"

    # Clean up temporary working directory
    popd > /dev/null
    rm -rf "$temp_dir"
    echo "==> [HELPER] Fieldmap successfully processed and stored at: $out_dir"
}

# ------------------------------------------------------------------------------
# Main Execution Flow & Flag Parsing
# ------------------------------------------------------------------------------

DATASET_DIR=""
SUBJ_ID=""

# Parse command line flags using getopts
while getopts "d:s:h" opt; do
    case ${opt} in
        d)
            DATASET_DIR="${OPTARG}"
            ;;
        s)
            SUBJ_ID="${OPTARG}"
            ;;
        h)
            print_usage
            ;;
        \?)
            print_usage
            ;;
    esac
done

# Validate that mandatory arguments are provided
if [ -z "$DATASET_DIR" ] || [ -z "$SUBJ_ID" ]; then
    echo "Error: Missing mandatory options (-d or -s)."
    print_usage
fi

echo "=================================================="
echo "++ Independent Fieldmap Prep Pipeline Started"
echo "++ Dataset Directory : $DATASET_DIR"
echo "++ Subject ID        : $SUBJ_ID"
echo "=================================================="

SUBJ_PATH="${DATASET_DIR}/${SUBJ_ID}"

if [ ! -d "$SUBJ_PATH" ]; then
    echo "-- [ERROR] Subject directory not found: $SUBJ_PATH"
    exit 1
fi

# Locate all sessions or fallback to default path if sessions folder is absent
sessions=$(find "$SUBJ_PATH" -maxdepth 2 -type d -name "ses-*" | sort)
if [ -z "$sessions" ]; then
    sessions="$SUBJ_PATH"
fi

for ses_path in $sessions; do
    ses_name=$(basename "$ses_path")
    if [[ "$ses_name" == ses-* ]]; then
        echo -e "\n--- Processing session: $ses_name ---"
        FMAP_DIR="${ses_path}/fmap"
    else
        echo -e "\n--- Processing non-session structured subject ---"
        ses_name="ses-default"
        FMAP_DIR="${SUBJ_PATH}/fmap"
    fi

    # Check if fmap directory exists for this session
    if [ ! -d "$FMAP_DIR" ]; then
        echo "--> [NOTICE] No 'fmap' directory found for $SUBJ_ID ($ses_name). Skipping unwarping prep."
        continue
    fi

    # Locate required BIDS fieldmap files via wildcards
    mag_file=$(find "$FMAP_DIR" -type f -name "*magnitude1.nii.gz" | head -n 1)
    phase_file=$(find "$FMAP_DIR" -type f -name "*phasediff.nii.gz" | head -n 1)
    json_file=$(find "$FMAP_DIR" -type f -name "*phasediff.json" | head -n 1)

    if [ -z "$mag_file" ] || [ -z "$phase_file" ] || [ -z "$json_file" ]; then
        echo "--> [NOTICE] Incomplete fieldmap files in $FMAP_DIR. Skipping."
        continue
    fi

    echo "++ Magnitude file found : $(basename "$mag_file")"
    echo "++ Phasediff file found : $(basename "$phase_file")"
    echo "++ JSON sidecar found   : $(basename "$json_file")"

    # Define centralized output directory directly inside the dataset path under a unified folder
    CENTRAL_OUTPUT_ROOT="${DATASET_DIR}/fieldmaps_prepared_all"
    OUT_FMAP_DIR="${CENTRAL_OUTPUT_ROOT}/${SUBJ_ID}/${ses_name}/fmap_prepared"

    # Call the helper function to execute the preprocessing steps
    process_fieldmap_session "$mag_file" "$phase_file" "$json_file" "$OUT_FMAP_DIR"

done

echo "=================================================="
echo "++ Fieldmap preparation pipeline completed successfully."
echo "=================================================="
