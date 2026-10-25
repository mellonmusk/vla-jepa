#!/bin/bash
# Train and evaluate methods A and B with seeds 43 and 44, one after another.
# Finished trainings and evaluations are skipped, so the script can simply be re-run after an interruption.
# Usage (inside tmux): bash scripts/runpod/run_seeds.sh 2>&1 | tee -a /workspace/run_seeds.log
set -o pipefail
source /workspace/miniconda3/bin/activate VLA_JEPA
cd /workspace/VLA-JEPA
export PYTHONPATH=$PWD WANDB_MODE=disabled TOKENIZERS_PARALLELISM=false
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
unset LIBERO_HOME SIM_PYTHON

RUNS=${RUNS:-"A_s43 B_s43 A_s44 B_s44"}   # seed 43 first, so an early stop still leaves a complete A/B pair
EVAL=${EVAL:-1}                              # EVAL=0: train only (evaluation done elsewhere)

for r in $RUNS; do
  run=libero_$r
  ckpt=/workspace/runs/$run/checkpoints/steps_30000_pytorch_model.pt

  if [ -f "$ckpt" ]; then
    echo "== skip training $run (checkpoint exists)"
  else
    echo "== train $run  $(date)"
    rm -rf /workspace/runs/$run
    date | tee /workspace/start_$run.txt
    nvidia-smi --query-gpu=memory.used --format=csv -l 60 > /workspace/vram_$run.csv &
    vram_pid=$!
    accelerate launch --config_file starVLA/config/deepseeds/deepspeed_zero2.yaml --num_processes 1 \
      starVLA/training/train_starvla.py --config_yaml scripts/configs/vlajepa_$run.yaml \
      2>&1 | tee /workspace/$run.log
    kill $vram_pid 2>/dev/null
    date | tee /workspace/end_$run.txt
    if [ ! -f "$ckpt" ]; then echo "!! training $run did not produce $ckpt, stopping"; exit 1; fi
    rm -rf /workspace/runs/$run/final_model   # same weights as steps_30000, saves 6 GB
  fi

  if [ "$EVAL" = "0" ]; then echo "== skip all evals for $run (EVAL=0)"; continue; fi
  for suite in libero_spatial libero_object libero_goal libero_10; do
    log=results/$suite/${run}_steps_30000_pytorch_model.pt/eval.log
    if grep -q "Total episodes" "$log" 2>/dev/null; then echo "== skip eval $run $suite"; continue; fi
    pkill -f server_policy.py 2>/dev/null; sleep 2
    bash examples/LIBERO/eval_one.sh "$ckpt" $suite 10
  done
done

echo "== all done $(date)"
for f in results/*/libero_*_s4?_steps_30000_pytorch_model.pt/eval.log; do
  echo "$f: $(grep -A1 'Total success rate' "$f" | grep -oE '[0-9]\.[0-9]+' | tail -n 1)"
done
tar czf /workspace/seed_logs.tgz results/*/libero_*_s4?_*/*.log /workspace/libero_*_s4?.log \
  /workspace/vram_libero_*_s4?.csv /workspace/start_libero_*_s4?.txt /workspace/end_libero_*_s4?.txt \
  /workspace/runs/libero_*_s4?/config.yaml 2>/dev/null
ls -lh /workspace/seed_logs.tgz
