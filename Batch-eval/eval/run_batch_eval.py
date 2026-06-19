"""
バッチ評価（cloud evaluation）— データセット採点
=================================================
sample-eval.jsonl をアップロードし、built-in 評価器
（coherence / relevance / groundedness / f1_score）で一括採点します。

フロー（公式 3 ステップ）:
  1. data_source_config（列スキーマ）+ testing_criteria（評価器）を定義
  2. evals.create() で評価定義を登録
  3. evals.runs.create() でラン起動 → ポーリング → 結果取得

参照: _report/20260614-1600-batch-eval-foundry/final-report.md（第1章〜第4章）
"""
from __future__ import annotations

import time
from pathlib import Path

from _common import get_openai_client, get_project_client, model_deployment_name

DATASET_PATH = Path(__file__).resolve().parent / "data" / "sample-eval.jsonl"
POLL_INTERVAL_SEC = 10
POLL_TIMEOUT_SEC = 1800


def build_testing_criteria(model: str) -> list[dict]:
    """built-in 評価器の定義（data_mapping で列→引数を対応付け）。"""
    return [
        {
            "type": "azure_ai_evaluator",
            "name": "coherence",
            "evaluator_name": "builtin.coherence",
            "initialization_parameters": {"deployment_name": model},
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{item.response}}",
            },
        },
        {
            "type": "azure_ai_evaluator",
            "name": "relevance",
            "evaluator_name": "builtin.relevance",
            "initialization_parameters": {"deployment_name": model},
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{item.response}}",
            },
        },
        {
            "type": "azure_ai_evaluator",
            "name": "groundedness",
            "evaluator_name": "builtin.groundedness",
            "initialization_parameters": {"deployment_name": model},
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{item.response}}",
                "context": "{{item.context}}",
            },
        },
        {
            "type": "azure_ai_evaluator",
            "name": "f1_score",
            "evaluator_name": "builtin.f1_score",
            "data_mapping": {
                "response": "{{item.response}}",
                "ground_truth": "{{item.ground_truth}}",
            },
        },
    ]


def main() -> None:
    project_client = get_project_client()
    openai_client = get_openai_client(project_client)
    model = model_deployment_name()

    print(f"[1/4] データセットをアップロード: {DATASET_PATH.name}")
    with open(DATASET_PATH, "rb") as f:
        uploaded = openai_client.files.create(file=f, purpose="evals")
    data_id = uploaded.id
    print(f"      file_id = {data_id}")

    print("[2/4] 評価定義を作成 (evals.create)")
    data_source_config = {
        "type": "custom",
        "item_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "response": {"type": "string"},
                "ground_truth": {"type": "string"},
                "context": {"type": "string"},
            },
            "required": ["query", "response"],
        },
        "include_sample_schema": True,
    }
    eval_object = openai_client.evals.create(
        name="contoso-dataset-batch-eval",
        data_source_config=data_source_config,
        testing_criteria=build_testing_criteria(model),
    )
    print(f"      eval_id = {eval_object.id}")

    print("[3/4] ランを起動 (evals.runs.create)")
    run = openai_client.evals.runs.create(
        eval_id=eval_object.id,
        name="contoso-dataset-run",
        data_source={
            "type": "jsonl",
            "source": {"type": "file_id", "id": data_id},
        },
    )
    print(f"      run_id = {run.id}  status = {run.status}")

    print("[4/4] 完了までポーリング...")
    deadline = time.time() + POLL_TIMEOUT_SEC
    while run.status in ("queued", "in_progress") and time.time() < deadline:
        time.sleep(POLL_INTERVAL_SEC)
        run = openai_client.evals.runs.retrieve(eval_id=eval_object.id, run_id=run.id)
        print(f"      status = {run.status}")

    print("\n=== 結果 ===")
    print(f"status     : {run.status}")
    report_url = getattr(run, "report_url", None)
    if report_url:
        print(f"report_url : {report_url}")

    counts = getattr(run, "result_counts", None)
    if counts:
        print(f"result_counts: {counts}")

    # 行ごとの結果
    try:
        items = openai_client.evals.runs.output_items.list(
            eval_id=eval_object.id, run_id=run.id
        )
        for i, item in enumerate(items, start=1):
            print(f"--- item {i} ---")
            for res in getattr(item, "results", []) or []:
                name = res.get("name") if isinstance(res, dict) else getattr(res, "name", "?")
                score = res.get("score") if isinstance(res, dict) else getattr(res, "score", None)
                label = res.get("label") if isinstance(res, dict) else getattr(res, "label", None)
                print(f"  {name}: score={score} label={label}")
    except Exception as ex:  # noqa: BLE001
        print(f"(output_items 取得をスキップ: {ex})")


if __name__ == "__main__":
    main()
