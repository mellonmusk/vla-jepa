#!/bin/bash
# One-time setup of a fresh RunPod pod (RTX 4090, Volume Disk mounted at /workspace).
# Prerequisite: /workspace/vlajepa_seed.patch was copied to the pod, and `hf auth login` is NOT needed yet.
# Usage: bash /workspace/setup_pod.sh 2>&1 | tee /workspace/setup.log
set -eo pipefail

echo "== 0. system packages"
apt-get update -qq
apt-get install -y -qq tmux git git-lfs wget unzip ffmpeg libegl1 libgl1 libglib2.0-0 libosmesa6-dev > /dev/null
grep -q PIP_CACHE_DIR ~/.bashrc || echo 'export HF_HOME=/workspace/hf PIP_CACHE_DIR=/workspace/.pip-cache' >> ~/.bashrc
export HF_HOME=/workspace/hf PIP_CACHE_DIR=/workspace/.pip-cache

# /workspace must be a normal disk (chmod works), not a network volume
touch /workspace/.perm_test && chmod +x /workspace/.perm_test && rm -f /workspace/.perm_test

echo "== 1. miniconda"
cd /workspace
if [ ! -x /workspace/miniconda3/bin/conda ]; then
  rm -rf /workspace/miniconda3
  wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O Miniconda3.sh
  bash Miniconda3.sh -b -p /workspace/miniconda3
fi
source /workspace/miniconda3/bin/activate
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main > /dev/null || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r > /dev/null || true

echo "== 2. VLA-JEPA code + experiment patch"
if [ ! -d /workspace/VLA-JEPA ]; then
  git clone https://github.com/ginwind/VLA-JEPA /workspace/VLA-JEPA
  cd /workspace/VLA-JEPA && git checkout -q ec90777 && git apply /workspace/vlajepa_seed.patch
fi
cd /workspace/VLA-JEPA
ls scripts/configs/vlajepa_libero_A_s43.yaml scripts/runpod/run_seeds.sh > /dev/null

echo "== 3. VLA_JEPA env"
if [ ! -d /workspace/miniconda3/envs/VLA_JEPA ]; then conda create -n VLA_JEPA python=3.10 -y -q; fi
conda activate VLA_JEPA
pip install -q -r requirements.txt
pip install -q https://github.com/Dao-AILab/flash-attention/releases/download/v2.7.4.post1/flash_attn-2.7.4.post1+cu12torch2.6cxx11abiFALSE-cp310-cp310-linux_x86_64.whl
pip install -q -e .
pip install -q peft==0.17.1 tyro mediapy websockets msgpack hf_transfer
python -c "import torch, flash_attn, peft; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), 'flash_attn', flash_attn.__version__)"

echo "== 4. LIBERO env"
if [ ! -d /workspace/LIBERO ]; then git clone --depth 1 https://github.com/Lifelong-Robot-Learning/LIBERO.git /workspace/LIBERO; fi
if [ ! -d /workspace/miniconda3/envs/libero ]; then conda create -n libero python=3.10 -y -q; fi
P=/workspace/miniconda3/envs/libero/bin/pip
(cd /workspace/LIBERO && $P install -q -e .)
$P install -q torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cpu
$P install -q numpy==1.26.4 robosuite==1.4.1 mujoco==3.3.2 bddl==1.0.1 easydict cloudpickle gym==0.25.2 future \
  "imageio[ffmpeg]" opencv-python-headless matplotlib tyro websockets msgpack omegaconf rich requests tqdm pillow typing_extensions
printf 'N\n' | PYTHONPATH=/workspace/LIBERO LIBERO_CONFIG_PATH=/workspace/LIBERO/libero \
  /workspace/miniconda3/envs/libero/bin/python -c "from libero.libero import benchmark; print(sorted(benchmark.get_benchmark_dict().keys())[:4])"

echo "== setup done. Next: hf auth login, then bash scripts/runpod/download.sh"
