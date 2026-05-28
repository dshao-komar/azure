import json
import logging
from datetime import datetime, timezone

import azure.functions as func

from coats_function_common import (
    claim_drive_item_event,
    extract_drive_item,
    graph_get,
    is_target_workbook,
    recent_target_workbooks,
    required_setting,
    resolve_drive_item,
    send_success_email,
    send_validation_email,
    start_adf_pipeline,
)


app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


@app.route(route="process-coats-workbook", methods=["POST"])
def process_coats_workbook(req: func.HttpRequest) -> func.HttpResponse:
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


@app.route(route="graph-sharepoint-notification", methods=["GET", "POST"])
def graph_sharepoint_notification(req: func.HttpRequest) -> func.HttpResponse:
    validation_token = req.params.get("validationToken")
    if validation_token:
        return func.HttpResponse(validation_token, status_code=200, mimetype="text/plain")

    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse("Invalid JSON payload.", status_code=400)

    started_runs: list[dict[str, object]] = []
    for notification in payload.get("value", []):
        try:
            item = resolve_drive_item(notification)
            items = [item] if item and is_target_workbook(item) else []
            if not item:
                items = recent_target_workbooks(minutes=3)

            for target_item in items:
                if not claim_drive_item_event(target_item):
                    continue
                parameters = {
                    "sharePointDriveId": target_item.get("parentReference", {}).get("driveId"),
                    "sharePointDriveItemId": target_item.get("id"),
                    "sourceFileName": target_item.get("name"),
                    "sourceWebUrl": target_item.get("webUrl"),
                    "sourceFolderPath": target_item.get("parentReference", {}).get("path"),
                    "graphSubscriptionId": notification.get("subscriptionId"),
                    "notificationReceivedUtc": datetime.now(timezone.utc).isoformat(),
                }
                run = start_adf_pipeline(parameters)
                started_runs.append({"sourceFileName": target_item.get("name"), "run": run})
        except Exception:
            logging.exception("Failed to process Graph notification.")
            raise

    return func.HttpResponse(
        json.dumps({"startedRuns": started_runs}),
        status_code=202,
        mimetype="application/json",
    )


@app.route(route="send-coats-validation-email", methods=["POST"])
def send_coats_validation_email(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
        result = send_validation_email(body)
        return func.HttpResponse(json.dumps(result), status_code=202, mimetype="application/json")
    except Exception:
        logging.exception("Failed to send Coats Mexico validation email.")
        raise


@app.route(route="send-coats-success-email", methods=["POST"])
def send_coats_success_email(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
        result = send_success_email(body)
        return func.HttpResponse(json.dumps(result), status_code=202, mimetype="application/json")
    except Exception:
        logging.exception("Failed to send Coats Mexico success email.")
        raise
