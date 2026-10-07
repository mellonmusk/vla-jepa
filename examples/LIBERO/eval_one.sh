#!/bin/bash
# Evaluate ONE checkpoint on ONE task suite with a single GPU.
#
# Usage (run from the VLA-JEPA repo root, with the VLA_JEPA conda env active):
#   bash examples/LIBERO/eval_one.sh <checkpoint.pt> <suite> [num_trials] [task_stride] [category]
#
#   suite:       libero_spatial | libero_object | libero_goal | libero_10 | libero_mix (LIBERO-Plus)
#   num_trials:  rollouts per task (default 10; must be 1 for LIBERO-Plus)
#   task_stride: evaluate every N-th task (default 1 = all tasks)
#   category:    LIBERO-Plus perturbation, e.g. "Language Instructions" (only for libero_mix)
#
# Environment overrides: LIBERO_HOME, SIM_PYTHON, MUJOCO_GL, PORT
set -eo pipefail

ckpt=$1
suite=$2
num_trials=${3:-10}
task_stride=${4:-1}
category=${5:-}

if [ -z "$ckpt" ] || [ -z "$suite" ]; then
    echo "Usage: bash examples/LIBERO/eval_one.sh <checkpoint.pt> <suite> [num_trials] [task_stride] [category]"
    exit 1
fi

export PYTHONDONTWRITEBYTECODE=1
export LIBERO_HOME=${LIBERO_HOME:-/workspace/LIBERO}
export LIBERO_CONFIG_PATH=${LIBERO_HOME}/libero
export MUJOCO_GL=${MUJOCO_GL:-egl}
export PYTHONPATH=$(pwd):${LIBERO_HOME}:${PYTHONPATH}
sim_python=${SIM_PYTHON:-/workspace/miniconda3/envs/libero/bin/python}
port=${PORT:-15083}

# results/<suite>[/<category>]/<run_id>_<checkpoint file>/
run_name=$(echo "$ckpt" | awk -F'/' '{print $(NF-2)"_"$NF}')
out_dir="results/${suite}"
if [ -n "$category" ]; then
    out_dir="${out_dir}/${category// /_}"
fi
out_dir="${out_dir}/${run_name}"
mkdir -p "${out_dir}"

# 1) start the policy server in the background
python ./deployment/model_server/server_policy.py \
    --ckpt_path "${ckpt}" \
    --port "${port}" \
    --use_bf16 \
    --cuda 0 > "${out_dir}/server.log" 2>&1 &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT

echo "Waiting for the policy server to load the model (log: ${out_dir}/server.log) ..."
until grep -q "server running" "${out_dir}/server.log"; do
    if ! kill -0 ${server_pid} 2>/dev/null; then
        echo "The policy server stopped. Last lines of its log:"
        tail -n 30 "${out_dir}/server.log"
        exit 1
    fi
    sleep 5
done

# 2) run the simulator client
extra_args=()
if [ -n "$category" ]; then
    extra_args+=(--args.category_value "$category")
fi

${sim_python} ./examples/LIBERO/eval_libero.py \
    --args.pretrained-path "${ckpt}" \
    --args.host 127.0.0.1 \
    --args.port "${port}" \
    --args.task-suite-name "${suite}" \
    --args.num-trials-per-task "${num_trials}" \
    --args.task-stride "${task_stride}" \
    --args.video-out-path "${out_dir}" \
    --args.with_state true \
    "${extra_args[@]}" 2>&1 | tee "${out_dir}/eval.log"

echo "===== ${suite} ${category} : ${ckpt}"
grep -E "Total success rate|Total episodes" "${out_dir}/eval.log" | tail -n 2
