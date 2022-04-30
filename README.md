# **PRIME-DE preprocessing with AFNI**

![](https://github.com/edrojas3/psilafni/blob/main/media/monkey3.png?raw=true)

### Description:

- Preprocessing is a key aspect in MRI analyses. There is not gold standard to achive a "good" preprocessing of MRI data, neither humans, macaques or any other species.
- Each PRIME-DE site collected macaque fMRI in a different way (e.g Field of View, voxel resolution etc.).
- between-site discrepancies in data acquisition result in the need of creating customized and flexible AFNI scripts to address different issues in the data that vary from site to site.

- **We are trying to generate a customized AFNI preprocessing recipe for each PRIME-DE site (or in some cases per individual) to end up with the best posible  quality.**

### General Preprocessing steps

#### 1. Install AFNI.

  a) Depending on your system features follow the [ installation guide ](https://afni.nimh.nih.gov/pub/dist/doc/htmldoc/background_install/install_instructs/index.html). Also, make sure to install NMT atlases with `@Install_NMT`

  b) If you are familiar with singularity/docker we previde you with are singularity recipe to build a container with an AFNI complete installation:

  - Clone this repository
  - go to the utils folder: ```cd utils```

  - Use the recipe to build the container: ```sudo singularity build -F afni.sif build_afni_singularity_container |& tee singularity_build_afni.logs```
  - keep the container up to date with: ```sudo singularity build -F afni.sif update_afni_singularity_container |& tee update afni_logs```

**Note:** you must have root privileges unless you call singularity build with the `--fake-root` or `--remote` flags.
