"""
トレース評価（preview）— App Insights の invoke_agent スパンを採点
=================================================================
検証用エージェント（agent/create_agent.py + invoke）が App Insights に出力した
OpenTelemetry gen_ai トレースを、評価器で直接採点します。

前提:
  - プロジェクト → App Insights 接続が存在（Bicep で作成済み）
  - プロジェクト MI に Monitoring Reader / Log Analytics Reader（deploy で付与）
  - 採点対象のトレースが存在（先に agent/create_agent.py を実行してエージェントを呼び出す）

注意:
  - トレース評価は preview。ルックバックは最大 7 日（168時間）。
  - ingestion 遅延があるため、エージェント呼び出し直後は数分待ってから実行。

参照: _report/20260614-1600-batch-eval-foundry/final-report.md（第2章 第3節 (C)）
"""
from __future__ import annotations

import os
import time

from _common import get_openai_client, get_project_client, model_deployment_name

POLL_INTERVAL_SEC = 10
POLL_TIMEOUT_SEC = 1800


def main() -> None:
    agent_id = os.environ.get("AGENT_ID")
    if not agent_id:
        raise RuntimeError(
            "環境変数 AGENT_ID が未設定です。agent/create_agent.py 実行時に "
            "出力される gen_ai.agent.id（例 'contoso-support-agent:1'）を設定してください。"
        )

    lookback_hours = int(os.environ.get("TRACE_LOOKBACK_HOURS", "1"))
    max_traces = int(os.environ.get("TRACE_MAX_TRACES", "20"))

    project_client = get_project_client()
    openai_client = get_openai_client(project_client)
    model = model_deployment_name()

    print("[1/3] トレース評価の定義を作成")
    eval_object = openai_client.evals.create(
        name="contoso-trace-eval",
        data_source_config={"type": "azure_ai_source", "scenario": "traces"},
        testing_criteria=[
            {
                "type": "azure_ai_evaluator",
                "name": "task_adherence",
                "evaluator_name": "builtin.task_adherence",
                "initialization_parameters": {"deployment_name": model},
            },
            {
                "type": "azure_ai_evaluator",
                "name": "tool_call_accuracy",
                "evaluator_name": "builtin.tool_call_accuracy",
                "data_mapping": {
                    "query": "{{item.query}}",
                    "response": "{{item.response}}",
                    "tool_calls": "{{item.tool_calls}}",
                    "tool_definitions": "{{item.tool_definitions}}",
                },
                "initialization_parameters": {"deployment_name": model},
            },
        ],
    )
    print(f"      eval_id = {eval_object.id}")

    print(f"[2/3] ラン起動 (agent_id={agent_id}, lookback={lookback_hours}h)")
    run = openai_client.evals.runs.create(
        eval_id=eval_object.id,
        name="contoso-trace-run",
        data_source={
            "type": "azure_ai_traces",
            "agent_id": agent_id,
            "max_traces": max_traces,
            "lookback_hours": lookback_hours,
        },
    )
    print(f"      run_id = {run.id}  status = {run.status}")

    print("[3/3] 完了までポーリング...")
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

    if run.status not in ("completed",):
        print(
            "\nヒント: トレースが見つからない場合は、(1) エージェントを呼び出したか、"
            "(2) ingestion 遅延（数分）を待ったか、(3) AGENT_ID が正しいかを確認してください。"
        )


if __name__ == "__main__":
    main()
