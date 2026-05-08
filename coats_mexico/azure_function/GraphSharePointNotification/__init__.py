import json
import logging
from datetime import datetime, timezone

import azure.functions as func


def main(req: func.HttpRequest) -> func.HttpResponse:
    validation_token = req.params.get("validationToken")
    if validation_token:
        return func.HttpResponse(validation_token, status_code=200, mimetype="text/plain")

    from coats_function_common import (
        is_target_workbook,
        resolve_drive_item,
        start_adf_pipeline,
    )

    try:
        payload = req.get_json()
    except ValueError:
        return func.HttpResponse("Invalid JSON payload.", status_code=400)

    started_runs = []
    for notification in payload.get("value", []):
        try:
            item = resolve_drive_item(notification)
            if not item or not is_target_workbook(item):
                continue

            parameters = {
                "sharePointDriveId": item.get("parentReference", {}).get("driveId"),
                "sharePointDriveItemId": item.get("id"),
                "sourceFileName": item.get("name"),
                "sourceWebUrl": item.get("webUrl"),
                "sourceFolderPath": item.get("parentReference", {}).get("path"),
                "graphSubscriptionId": notification.get("subscriptionId"),
                "notificationReceivedUtc": datetime.now(timezone.utc).isoformat(),
            }
            run = start_adf_pipeline(parameters)
            started_runs.append({"sourceFileName": item.get("name"), "run": run})
        except Exception:
            logging.exception("Failed to process Graph notification.")
            raise

    return func.HttpResponse(
        json.dumps({"startedRuns": started_runs}),
        status_code=202,
        mimetype="application/json",
    )
