import json

import azure.functions as func

from coats_function_common import extract_drive_item, graph_get, is_target_workbook, required_setting


def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse("Invalid JSON payload.", status_code=400)

    drive_id = body.get("sharePointDriveId") or body.get("driveId") or required_setting("GRAPH_DRIVE_ID")
    item_id = body.get("sharePointDriveItemId") or body.get("driveItemId")
    if not item_id:
        return func.HttpResponse("Missing sharePointDriveItemId.", status_code=400)

    item = graph_get(f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{item_id}")
    if not is_target_workbook(item):
        return func.HttpResponse(
            json.dumps({"skipped": True, "reason": "Not a target workbook."}),
            status_code=200,
            mimetype="application/json",
        )

    pipeline_run_id = body.get("pipelineRunId") or body.get("runId") or "adf"
    extraction = extract_drive_item(item, pipeline_run_id)
    return func.HttpResponse(
        json.dumps({"skipped": False, "extraction": extraction}),
        status_code=200,
        mimetype="application/json",
    )
