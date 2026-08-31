#!/bin/bash
#SBATCH --job-name=align_bench
#SBATCH --account=def-mchakrav-ab
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=01:30:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#SBATCH --mail-user=faj.alf@gmail.com
#SBATCH --mail-type=END,FAIL

# ==============================================================================
# SLURM LAUNCH SCRIPT: EPI -> ANAT BENCHMARK (V6)
# ==============================================================================

# Purge previous modules and load standard environment stack
module --force purge
module load StdEnv/2023
module load apptainer

# Mandatory arguments passed via sbatch
SITE_DIR="$1"
SUBJ_ID="$2"

# Cluster container and script paths
CONTAINER="/project/rrg-mchakrav-ab/afajardo/containers/afni.sif"
BENCHMARK_SCRIPT="/project/rrg-mchakrav-ab/afajardo/github/psilafni/code/align_epi2anat_benchmark_v7.sh"
AW_DIR="${SITE_DIR}/data_aw"

# Validate mandatory arguments
if [ -z "$SITE_DIR" ] || [ -z "$SUBJ_ID" ]; then
    echo "[ERROR] Missing required positional arguments."
    echo "Usage: sbatch --job-name=<subject_id> $0 <site_dir> <subject_id> [optional_flags]"
    exit 1
fi

# Verify input prerequisites and container paths
if [ ! -f "$CONTAINER" ]; then
    echo "[ERROR] Apptainer container image not found at: $CONTAINER"
    exit 1
fi

if [ ! -f "$BENCHMARK_SCRIPT" ]; then
    echo "[ERROR] Benchmark script target not found at: $BENCHMARK_SCRIPT"
    exit 1
fi

if [ ! -d "$AW_DIR" ]; then
    echo "[ERROR] Animal Warper directory not found at: $AW_DIR"
    exit 1
fi

# Create local logs directory in the current working directory
mkdir -p logs

# Set OpenMP thread allocation for AFNI within the Apptainer environment
export APPTAINERENV_OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK

# Capture optional trailing parameters (e.g., -ses ses-004, -anat_ses ses-001, -nf)
EXTRA_ARGS=("${@:3}")

echo "=================================================="
echo " Job ID          : $SLURM_JOB_ID"
echo " Job Name        : $SLURM_JOB_NAME"
echo " Account         : def-mchakrav-ab"
echo " Working Dir     : $PWD"
echo " Logs Dir        : $PWD/logs"
echo " Processing Subj : $SUBJ_ID"
echo " Cores Allocated : $SLURM_CPUS_PER_TASK"
echo " Site Directory  : $SITE_DIR"
echo " AW Directory    : $AW_DIR"
echo " Extra Flags     : ${EXTRA_ARGS[*]:-[NONE]}"
echo " Notification    : faj.alf@gmail.com (END, FAIL)"
echo " Container Image : $CONTAINER"
echo " Script Target   : $BENCHMARK_SCRIPT"
echo "=================================================="

# ==============================================================================
# APPTAINER EXECUTION BLOCK (WITHOUT /project BIND)
# ==============================================================================
apptainer exec -C \
    -B "$PWD:$PWD" \
    "$CONTAINER" \
    "$BENCHMARK_SCRIPT" \
    -d "$SITE_DIR" \
    -s "$SUBJ_ID" \
    -a "$AW_DIR" \
    "${EXTRA_ARGS[@]}"

STATUS=$?

if [ $STATUS -eq 0 ]; then
    echo "++ [SUCCESS] Benchmark execution completed for $SUBJ_ID"
else
    echo "-- [ERROR] Benchmark execution failed for $SUBJ_ID (Exit code: $STATUS)"
fi

exit $STATUS
