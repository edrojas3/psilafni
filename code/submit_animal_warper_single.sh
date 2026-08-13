#!/bin/bash
#SBATCH --job-name=aw_job           # Default job name (overridden at submission)
#SBATCH --nodes=1                   # AFNI processes a single subject per node
#SBATCH --cpus-per-task=8           # Allocated CPU cores for OpenMP parallelization
#SBATCH --time=06:00:00             # Walltime limit (6 hours)
#SBATCH --output=/scratch/afajardo/logs/%x_%j.out   # Standard output saved in /scratch
#SBATCH --error=/scratch/afajardo/logs/%x_%j.err    # Standard error saved in /scratch
#SBATCH --mail.user=faj.alf@gmail.com
#SBATCH --mem=16G
# ==============================================================================
# INPUT ARGUMENTS AND PATHS
# ==============================================================================
SITE_DIR="$1"
SUBJ_ID="$2"

CONTAINER="/project/rrg-mchakrav-ab/afajardo/containers/afni.sif"
ANIMAL_WARPER="/project/rrg-mchakrav-ab/afajardo/github/psilafni/code/02.psilafni_animal_warper.sh"

# Validate required input parameters
if [ -z "$SITE_DIR" ] || [ -z "$SUBJ_ID" ]; then
    echo "[ERROR] Missing required arguments!"
    echo "Usage: sbatch --job-name=<subject_id> $0 <site_dir_path> <subject_id>"
    exit 1
fi

# Ensure scratch logs directory exists
mkdir -p /scratch/afajardo/logs

# Optimize AFNI / OpenMP multithreading inside Apptainer
export APPTAINERENV_OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK

echo "=================================================="
echo " Job ID          : $SLURM_JOB_ID"
echo " Job Name        : $SLURM_JOB_NAME"
echo " Processing Subj : $SUBJ_ID"
echo " Cores Allocated : $SLURM_CPUS_PER_TASK"
echo " Site Directory  : $SITE_DIR"
echo " Container       : $CONTAINER"
echo " Script          : $ANIMAL_WARPER"
echo " Logs Path       : /scratch/afajardo/logs/"
echo "=================================================="

# ==============================================================================
# APPTAINER EXECUTION
# ==============================================================================
apptainer exec -C -B "$PWD:$PWD" -B /scratch/afajardo:/scratch/afajardo "$CONTAINER" "$ANIMAL_WARPER" -d "$SITE_DIR" -s "$SUBJ_ID"

STATUS=$?
if [ $STATUS -eq 0 ]; then
    echo "++ [SUCCESS] Completed processing for $SUBJ_ID"
else
    echo "-- [ERROR] Processing failed for $SUBJ_ID (Exit code $STATUS)"
fi

exit $STATUS
