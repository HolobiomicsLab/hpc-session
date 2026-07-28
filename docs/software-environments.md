# Software and environments

Clusters do not work like your laptop: you are not root, `/usr/lib` is not yours to
change, home directories are small and often slow, and compute nodes may have no route
to the internet. This page covers finding what already exists, installing what does not,
and doing both without making the shared filesystem miserable.

Run any of these through your session:

```bash
hpc-session run -- module avail
```

## First: find out what is already there

Sites install a great deal centrally. Look before you build.

```bash
module avail                  # everything currently visible
module spider samtools        # search the whole tree, including hidden versions
module spider samtools/1.19   # what must be loaded first to reach that version
module key blast              # search by keyword, on Lmod sites
module list                   # what you have loaded right now
```

If `module avail` looks suspiciously short, the site probably uses a **hierarchical**
tree: a compiler and an MPI module must be loaded before the rest becomes visible.
`module spider <name>` tells you the prerequisites.

Ask the administrators before building anything substantial yourself — see
[support-and-feedback.md](support-and-feedback.md). Software they install is built for
the hardware, maintained, and available to everyone after you.

## Using modules well

```bash
module purge                  # start from a known state
module load gcc/12.2.0 openmpi/4.1.5 python/3.12
module list
```

Three habits worth adopting immediately:

- **Pin versions in job scripts.** `module load python` gives you whatever the default is
  today; `module load python/3.12` gives you the same thing next year. A default that
  moves under a running project is a genuinely nasty source of irreproducibility.
- **`module purge` at the top of every job script**, then load exactly what you need. Do
  not rely on what your interactive shell happened to have.
- **Save a set you use often**: `module save myproject`, then `module restore myproject`.

Record what you loaded alongside your results — `module list 2>&1` in the job output
costs nothing and answers "what did we actually run" months later.

## Python

Two workable approaches. Pick one per project and write down which.

**A virtual environment on top of a site Python** — light, fast, plays well with modules:

```bash
module load python/3.12
python -m venv /scratch/$USER/envs/myproject
source /scratch/$USER/envs/myproject/bin/activate
pip install -r requirements.txt
```

**Conda / mamba** — when you need non-Python dependencies too:

```bash
module load miniforge          # or the site's conda module
mamba create -p /scratch/$USER/envs/myproject python=3.12 numpy
mamba activate /scratch/$USER/envs/myproject
```

Whichever you choose:

- **Put the environment outside your home directory** (`-p /path`, not `-n name`). Conda
  environments are tens of thousands of small files; home quotas are counted in inodes as
  well as bytes, and shared home filesystems handle that pattern badly.
- **Move the caches too**, or they will silently fill your home quota:
  ```bash
  export PIP_CACHE_DIR=/scratch/$USER/.cache/pip
  export CONDA_PKGS_DIRS=/scratch/$USER/.conda/pkgs
  export XDG_CACHE_HOME=/scratch/$USER/.cache
  ```
- **Avoid `pip install --user`.** It writes to `~/.local`, which then leaks into every
  environment you use afterwards and produces conflicts that are painful to diagnose.
- **Install from the login node**, which usually has internet; compute nodes often do not.
  Create and populate the environment first, then submit the job that uses it.
- **Activate inside the job script**, not in `~/.bashrc`. An environment loaded for every
  shell will eventually break someone else's job — including yours.

If activation is slow on a parallel filesystem, that is the small-file problem again:
`conda-pack`, or a container, will fix it.

## R

```bash
module load r/4.4.1
export R_LIBS_USER=/scratch/$USER/R/4.4
```

Use [`renv`](https://rstudio.github.io/renv/) to pin a project's packages, and keep the
library path per R version — packages built against one R version rarely work under
another.

## Containers

Where the site allows them, containers are the most reliable answer to "this software
will not build here" and the most portable record of what you ran.

```bash
apptainer pull mytool.sif docker://organisation/mytool:1.4.0
hpc-session run -- apptainer exec /scratch/\$USER/mytool.sif mytool --help
```

Points that catch people out: build images where you have root (your laptop, or a
registry) and only *run* them on the cluster; bind-mount the paths you need
(`--bind /scratch:/scratch`) since the container sees very little by default; and pin a
tag, never `latest`. For GPU work, pass the site's flag (`--nv` for NVIDIA) and match the
image's CUDA version to the driver the nodes actually have.

## Building your own

If a module does not exist and a container will not do, build with the tools the site
already uses — [Spack](https://spack.readthedocs.io/) or
[EasyBuild](https://docs.easybuild.io/) — rather than by hand. They handle the compiler
toolchain and produce something you can reproduce and share.

Compile **in a job**, not on the login node: a parallel build is exactly the kind of load
that makes a login node unusable for everyone else.

## Compute nodes without internet

This surprises everyone once. If a job fails with a name-resolution or connection error
while downloading a model, a database or a package, the fix is to fetch it beforehand on
the login node and point the job at the local copy — for instance by setting the tool's
cache directory (`HF_HOME`, `TORCH_HOME`, `MPLCONFIGDIR`) to a path under scratch that
you populated in advance.

## Reproducibility, cheaply

Three lines in a job script are usually enough to answer later questions:

```bash
module list 2>&1
pip freeze                     # or: mamba list --explicit
echo "commit: $(git -C /path/to/code rev-parse --short HEAD)"
```

Keep them. The cost is nothing; the alternative is rerunning an analysis to find out what
it was.
