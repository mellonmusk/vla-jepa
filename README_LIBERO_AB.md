# VLA-JEPA × LIBERO: Action expert only (A) vs LoRA (B)

VLA-JEPA 사전학습 체크포인트를 LIBERO에 post-training할 때, action expert만 학습하는 방법(A)과 VLM 언어 모델에 LoRA를 추가하는 방법(B)을 비교한 실험의 코드입니다.

원본 저장소 [ginwind/VLA-JEPA](https://github.com/ginwind/VLA-JEPA)의 커밋 `ec90777` 위에 수정을 얹은 것입니다. 원본과의 차이는 이 저장소의 마지막 커밋 하나에 모두 들어 있습니다.

## 원본에서 바뀐 것

| 파일 | 내용 |
|---|---|
| `starVLA/model/framework/VLA_JEPA.py` | `framework.qwenvl.lora_r`가 있으면 Qwen 언어 모델의 attention projection에 LoRA 주입(vision tower 제외). `trainer.use_wm_loss: false`면 JEPA 계산을 건너뛰고 `action_loss`만 반환 |
| `starVLA/training/trainer_utils/trainer_tools.py` | 옵티마이저에서 동결 파라미터 제외. 사전학습 가중치를 LoRA가 붙은 층(`*.base_layer.*`)에 맞춰 로딩하고, LoRA 외에 빠진 키가 있으면 오류 |
| `starVLA/dataloader/__init__.py` | 데이터 로더 `num_workers` 4 → 8 |
| `examples/LIBERO/eval_libero.py` | `task_stride` 옵션(N번째 태스크만 평가), LIBERO-Plus용 경로 문자열 변환 |
| `scripts/configs/vlajepa_libero_A.yaml` | 기법 A 설정 |
| `scripts/configs/vlajepa_libero_B.yaml` | 기법 B 설정 |
| `scripts/configs/vlajepa_libero_B_r2.yaml` | 기법 B에서 LoRA rank만 2로 줄인 설정 (추가 실험) |
| `examples/LIBERO/eval_one.sh` | GPU 1장으로 체크포인트 1개, suite 1개를 평가 |

## 두 기법의 차이

두 설정 파일의 차이는 아래 세 가지뿐입니다.

| | (A) Action expert only | (B) LoRA |
|---|---|---|
| `freeze_modules` | `qwen_vl_interface,vj_encoder,vj_predictor` | `vj_encoder,vj_predictor` |
| LoRA | 없음 | r=16, alpha=32, dropout 0.05, `q_proj,k_proj,v_proj,o_proj` |
| `qwen_vl_interface` lr | (동결이라 쓰이지 않음) | 1e-4 |

공통: 시작 가중치 `Pretrain/checkpoints/VLA-JEPA-pretrain.pt`, 데이터 `libero_all`, 30,000 step, batch size 8, warmup 1,500, seed 42, action expert lr 1e-4, JEPA loss 끔, RTX 4090 1장.

## 환경 (원본 README와 다른 점)

- 학습 환경: 원본 README대로 설치한 뒤 `pip install peft==0.17.1 tyro mediapy websockets msgpack hf_transfer`
- `flash-attn`은 미리 빌드된 파일로 설치: `flash_attn-2.7.4.post1+cu12torch2.6cxx11abiFALSE-cp310-cp310-linux_x86_64.whl`
- LIBERO 환경은 Python 3.10 (평가 스크립트 문법 때문에 3.8 불가), `torch==2.5.1`(CPU), `robosuite==1.4.1`, `numpy==1.26.4`
- `mujoco==3.3.2`로 고정해야 합니다. 최신 버전은 `robosuite 1.4.1`과 맞지 않아 `AssertionError`가 납니다.
- LIBERO는 `pip install -e .`만으로는 import되지 않습니다. `eval_one.sh`가 `PYTHONPATH`로 경로를 지정합니다.
- LIBERO-Plus: `wand`, `scikit-image`, `libmagickwand-dev` 추가 설치. `assets.zip`은 저자 서버의 긴 경로 아래에 풀리므로 `assets` 폴더를 `libero/libero/` 아래로 옮겨야 합니다.
- 설정 파일의 경로는 `/workspace` 기준입니다. 다른 위치라면 `base_vlm`, `base_encoder`, `data_root_dir`, `pretrained_checkpoint`, `run_root_dir`를 고치세요.

## 실행

```bash
export PYTHONPATH=$PWD WANDB_MODE=disabled TOKENIZERS_PARALLELISM=false
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# 학습 (A 또는 B)
accelerate launch --config_file starVLA/config/deepseeds/deepspeed_zero2.yaml --num_processes 1 \
  starVLA/training/train_starvla.py --config_yaml scripts/configs/vlajepa_libero_A.yaml

# 평가: <체크포인트> <suite> [태스크당 횟수] [task_stride] [LIBERO-Plus 범주]
bash examples/LIBERO/eval_one.sh /workspace/runs/libero_A/checkpoints/steps_30000_pytorch_model.pt libero_spatial 10
```

LIBERO-Plus는 `LIBERO_HOME`과 `SIM_PYTHON`을 LIBERO-Plus 쪽으로 지정하고 suite를 `libero_mix`로 줍니다.

```bash
export LIBERO_HOME=/workspace/LIBERO-plus SIM_PYTHON=/workspace/miniconda3/envs/libero_plus/bin/python
bash examples/LIBERO/eval_one.sh <체크포인트> libero_mix 1 10 "Language Instructions"
```

## 알아 둘 점

- yaml의 `gradient_accumulation_steps`는 쓰이지 않습니다(DeepSpeed 설정에서 1로 고정). batch를 바꾸려면 `per_device_batch_size`를 바꿔야 합니다.
- batch 16은 B가 24GB에 들어가지 않습니다. 최대 VRAM은 A 12.7GB, B 18.1GB입니다.
- 데이터 읽기가 병목입니다. step당 약 1초 중 모델 계산은 A 0.44초, B 0.60초입니다.
- B가 실제로 LoRA를 학습하는지는 로그의 `LoRA injected` / `keys remapped into LoRA base layers` 줄과, 체크포인트의 `lora_B` 텐서가 0이 아닌지로 확인합니다.
- LIBERO 학습 데이터는 `IPEC-COMMUNITY/libero_*_no_noops_1.0.0_lerobot` 4개이고, 각 `meta/`에 `examples/LIBERO/modality.json`을 복사해야 합니다.
