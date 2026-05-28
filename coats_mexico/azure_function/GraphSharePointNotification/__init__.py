import json
import logging
from datetime import datetime, timezone

import azure.functions as func


def main(req: func.HttpRequest) -> func.HttpResponse:
    validation_token = req.params.get("validationToken")
    if validation_token:
        return func.HttpResponse(validation_token, status_code=200, mimetype="text/plain")

    from coats_function_common import (
        claim_drive_item_event,
        is_target_workbook,
        recent_target_workbooks,
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
