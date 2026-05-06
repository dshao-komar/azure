import json
import logging
import os
import tempfile
from typing import Any
from datetime import datetime, timedelta, timezone

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

from extract_coats_mexico_workbook import extract_workbook


app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
credential = DefaultAzureCredential()


def required_setting(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required app setting: {name}")
    return value


def access_token(resource_scope: str) -> str:
    return credential.get_token(resource_scope).token


def graph_access_token() -> str:
    tenant_id = os.environ.get("GRAPH_TENANT_ID")
    client_id = os.environ.get("GRAPH_CLIENT_ID")
    client_secret = os.environ.get("GRAPH_CLIENT_SECRET")

    if tenant_id and client_id and client_secret:
        response = requests.post(
            f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "scope": "https://graph.microsoft.com/.default",
                "grant_type": "client_credentials",
            },
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["access_token"]

    return access_token("https://graph.microsoft.com/.default")


def graph_get(url: str) -> dict[str, Any]:
    response = requests.get(
        url,
        headers={"Authorization": f"Bearer {graph_access_token()}"},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def graph_download(url: str) -> bytes:
    response = requests.get(
        url,
        headers={"Authorization": f"Bearer {graph_access_token()}"},
        timeout=120,
    )
    response.raise_for_status()
    return response.content


def start_adf_pipeline(parameters: dict[str, Any]) -> dict[str, Any]:
    subscription_id = required_setting("ADF_SUBSCRIPTION_ID")
    resource_group = required_setting("ADF_RESOURCE_GROUP")
    factory_name = required_setting("ADF_FACTORY_NAME")
    pipeline_name = required_setting("ADF_PIPELINE_NAME")

    url = (
        "https://management.azure.com/subscriptions/"
        f"{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.DataFactory/factories/{factory_name}"
        f"/pipelines/{pipeline_name}/createRun?api-version=2018-06-01"
    )
    response = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {access_token('https://management.azure.com/.default')}",
            "Content-Type": "application/json",
        },
        data=json.dumps({"parameters": parameters}),
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def is_target_workbook(item: dict[str, Any]) -> bool:
    name = item.get("name", "")
    if not name.lower().endswith(".xlsx"):
        return False
    if name.startswith("~$"):
        return False

    expected_folder = os.environ.get("SHAREPOINT_WATCH_FOLDER_PATH", "Coats Mexico Shipment Reports")
    parent_path = item.get("parentReference", {}).get("path", "")
    return expected_folder.lower() in parent_path.lower()


def recent_target_workbooks(minutes: int = 10) -> list[dict[str, Any]]:
    drive_id = required_setting("GRAPH_DRIVE_ID")
    folder_item_id = required_setting("GRAPH_WATCH_FOLDER_ITEM_ID")
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=minutes)
    children = graph_get(f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{folder_item_id}/children")
    items: list[dict[str, Any]] = []

    for item in children.get("value", []):
        if not is_target_workbook(item):
            continue

        timestamp = item.get("createdDateTime") or item.get("lastModifiedDateTime")
        if not timestamp:
            continue

        changed_at = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if changed_at >= cutoff:
            items.append(item)

    return items


def resolve_drive_item(notification: dict[str, Any]) -> dict[str, Any] | None:
    resource_data = notification.get("resourceData") or {}
    item_id = resource_data.get("id")
    drive_id = resource_data.get("driveId") or os.environ.get("GRAPH_DRIVE_ID")

    if not item_id or not drive_id:
        logging.warning("Notification missing drive item id or drive id: %s", notification)
        return None

    return graph_get(f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{item_id}")


def raw_blob_path(file_name: str, received_utc: datetime) -> str:
    safe_name = file_name.replace("\\", "_").replace("/", "_")
    return f"coats-mexico/{received_utc:%Y/%m/%d}/{safe_name}"


def upload_raw_workbook(blob_path: str, content: bytes) -> None:
    connection_string = required_setting("RAW_STORAGE_CONNECTION_STRING")
    container = os.environ.get("RAW_STORAGE_CONTAINER", "raw")
    service = BlobServiceClient.from_connection_string(connection_string)
    client = service.get_blob_client(container=container, blob=blob_path)
    client.upload_blob(content, overwrite=True)


def extract_drive_item(item: dict[str, Any], pipeline_run_id: str) -> dict[str, Any]:
    drive_id = item.get("parentReference", {}).get("driveId") or required_setting("GRAPH_DRIVE_ID")
    item_id = item["id"]
    file_name = item["name"]
    content = graph_download(f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{item_id}/content")

    received_utc = datetime.now(timezone.utc)
    blob_path = raw_blob_path(file_name, received_utc)
    upload_raw_workbook(blob_path, content)

    with tempfile.NamedTemporaryFile(suffix=".xlsx") as temp_file:
        temp_file.write(content)
        temp_file.flush()
        payload = extract_workbook(
            workbook_path=temp_file.name,
            source_file_name=file_name,
            source_web_url=item.get("webUrl"),
            pipeline_run_id=pipeline_run_id,
            shipment_date_override=None,
            trailer_name_override=None,
        )

    payload["metadata"]["shipment_file_id"] = stable_shipment_file_id(drive_id, item_id)
    payload["metadata"]["raw_blob_container"] = os.environ.get("RAW_STORAGE_CONTAINER", "raw")
    payload["metadata"]["raw_blob_path"] = blob_path
    payload["metadata"]["sharepoint_drive_id"] = drive_id
    payload["metadata"]["sharepoint_drive_item_id"] = item_id
    return payload


def stable_shipment_file_id(drive_id: str, item_id: str) -> str:
    import uuid

    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"graph-drive-item:{drive_id}:{item_id}"))


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

    started_runs: list[dict[str, Any]] = []
    for notification in payload.get("value", []):
        try:
            item = resolve_drive_item(notification)
            target_items = [item] if item and is_target_workbook(item) else recent_target_workbooks()

            for target_item in target_items:
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
