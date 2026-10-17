#!/bin/bash
# Download model weights and LIBERO training data. Run after `hf auth login` (Read token).
# Usage: bash scripts/runpod/download.sh 2>&1 | tee /workspace/download.log
set -o pipefail
source /workspace/miniconda3/bin/activate VLA_JEPA
export HF_HOME=/workspace/hf

retry() { until "$@"; do echo "retry in 60s: $*"; sleep 60; done; }

retry hf download Qwen/Qwen3-VL-2B-Instruct --local-dir /workspace/models/Qwen3-VL-2B-Instruct
retry hf download facebook/vjepa2-vitl-fpc64-256 --local-dir /workspace/models/vjepa2-vitl-fpc64-256
retry hf download ginwind/VLA-JEPA --include "Pretrain/*" --local-dir /workspace/models/VLA-JEPA

for s in spatial object goal 10; do
  d=libero_${s}_no_noops_1.0.0_lerobot
  retry hf download IPEC-COMMUNITY/$d --repo-type dataset --local-dir /workspace/data/libero/$d --max-workers 2
  cp /workspace/VLA-JEPA/examples/LIBERO/modality.json /workspace/data/libero/$d/meta/
done

echo "== check (expected parquet: spatial 432, object 454, goal 428, 10 379; mp4 = 2 x parquet)"
ls -lh /workspace/models/VLA-JEPA/Pretrain/checkpoints/
for d in /workspace/data/libero/*; do echo "$d: $(find $d -name '*.mp4' | wc -l) mp4, $(find $d -name '*.parquet' | wc -l) parquet"; done
