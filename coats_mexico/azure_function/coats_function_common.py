import base64
import csv
import io
import json
import logging
import os
import tempfile
from decimal import Decimal, InvalidOperation
from html import escape
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import quote

import requests
from azure.identity import DefaultAzureCredential
from azure.core.exceptions import ResourceExistsError
from azure.storage.blob import BlobServiceClient

from extract_coats_mexico_workbook import extract_workbook


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


def graph_post(url: str, body: dict[str, Any]) -> dict[str, Any]:
    response = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {graph_access_token()}",
            "Content-Type": "application/json",
        },
        data=json.dumps(body),
        timeout=30,
    )
    response.raise_for_status()
    if response.content:
        return response.json()
    return {}


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
        data=json.dumps(parameters),
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


def claim_drive_item_event(item: dict[str, Any]) -> bool:
    drive_id = item.get("parentReference", {}).get("driveId") or required_setting("GRAPH_DRIVE_ID")
    item_id = item.get("id")
    item_version = item.get("eTag") or item.get("lastModifiedDateTime") or item.get("createdDateTime")
    if not item_id or not item_version:
        return False

    marker_key = f"{drive_id}:{item_id}:{item_version}"
    safe_marker_key = quote(marker_key, safe="")
    blob_path = f"coats-mexico/event-claims/{safe_marker_key}.json"
    payload = {
        "driveId": drive_id,
        "itemId": item_id,
        "itemVersion": item_version,
        "fileName": item.get("name"),
        "claimedAtUtc": datetime.now(timezone.utc).isoformat(),
    }

    connection_string = required_setting("RAW_STORAGE_CONNECTION_STRING")
    container = os.environ.get("RAW_STORAGE_CONTAINER", "raw")
    service = BlobServiceClient.from_connection_string(connection_string)
    client = service.get_blob_client(container=container, blob=blob_path)
    try:
        client.upload_blob(json.dumps(payload), overwrite=False)
        return True
    except ResourceExistsError:
        logging.info("Skipping duplicate SharePoint event for %s.", item.get("name"))
        return False


def _email_recipients(setting_name: str) -> list[dict[str, dict[str, str]]]:
    value = os.environ.get(setting_name, "")
    addresses = [part.strip() for part in value.replace(";", ",").split(",") if part.strip()]
    return [{"emailAddress": {"address": address}} for address in addresses]


def _issue_rows_html(issues: list[dict[str, Any]]) -> str:
    if not issues:
        return "<p>No validation issue rows were provided by ADF.</p>"

    rows = []
    for issue in issues[:50]:
        rows.append(
            "<tr>"
            f"<td>{escape(str(issue.get('issue_code') or ''))}</td>"
            f"<td>{escape(str(issue.get('Invoiced_Qty') or ''))}</td>"
            f"<td>{escape(str(issue.get('Item_ID') or ''))}</td>"
            f"<td>{escape(str(issue.get('PO_No') or ''))}</td>"
            f"<td>{escape(str(issue.get('Bin_ID') or ''))}</td>"
            f"<td>{escape(str(issue.get('message') or ''))}</td>"
            "</tr>"
        )

    overflow_note = ""
    if len(issues) > 50:
        overflow_note = f"<p>Showing first 50 of {len(issues)} blocking issues.</p>"

    return (
        f"{overflow_note}"
        "<table border='1' cellpadding='4' cellspacing='0'>"
        "<thead><tr>"
        "<th>Issue</th><th>Invoiced Qty</th><th>Item</th><th>PO</th><th>Bin</th><th>Message</th>"
        "</tr></thead>"
        f"<tbody>{''.join(rows)}</tbody>"
        "</table>"
    )


def _date_only(value: Any) -> str:
    text = str(value or "")
    return text.replace("T", " ").split(" ", 1)[0]


def _quantity_4(value: Any) -> str:
    if value is None:
        return ""

    try:
        quantity = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return str(value)

    text = f"{quantity:.4f}".rstrip("0").rstrip(".")
    return text or "0"


def _pipeline_label(payload: dict[str, Any]) -> str:
    return str(payload.get("pipelineDisplayPrefix") or os.environ.get("COATS_PIPELINE_DISPLAY_PREFIX", ""))


def _target_database(payload: dict[str, Any]) -> str:
    return str(payload.get("targetDatabase") or os.environ.get("COATS_TARGET_DATABASE", "P21Import"))


def _staging_database(payload: dict[str, Any]) -> str:
    return str(payload.get("stagingDatabase") or os.environ.get("COATS_STAGING_DATABASE", "P21Import"))


def _raw_extract_csv_attachment(payload: dict[str, Any]) -> dict[str, str] | None:
    rows = payload.get("rawFileRows") or []
    if not rows:
        return None

    fieldnames = list(rows[0].keys())
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)

    csv_bytes = output.getvalue().encode("utf-8-sig")
    attachment_name = payload.get("rawFileAttachmentName") or "coats-mexico-raw-extract.csv"
    return {
        "@odata.type": "#microsoft.graph.fileAttachment",
        "name": str(attachment_name),
        "contentType": "text/csv",
        "contentBytes": base64.b64encode(csv_bytes).decode("ascii"),
    }


def send_validation_email(payload: dict[str, Any]) -> dict[str, Any]:
    sender = required_setting("COATS_VALIDATION_EMAIL_FROM")
    to_recipients = _email_recipients("COATS_VALIDATION_EMAIL_TO")
    cc_recipients = _email_recipients("COATS_VALIDATION_EMAIL_CC")
    if not to_recipients:
        raise RuntimeError("Missing required app setting: COATS_VALIDATION_EMAIL_TO")

    source_file_name = payload.get("sourceFileName") or "Unknown Coats Mexico shipment"
    source_web_url = payload.get("sourceWebUrl")
    shipment_date = payload.get("shipmentDate")
    trailer_name = payload.get("trailerName")
    blocking_issue_count = payload.get("blockingIssueCount")
    issues = payload.get("issues") or []
    pipeline_label = _pipeline_label(payload)
    target_database = _target_database(payload)
    staging_database = _staging_database(payload)
    sharepoint_folder_url = (
        "https://komaralliance.sharepoint.com/:f:/s/KomarPublic/"
        "IgCDj5_b6WVRRZVWbeFhBuclAaslRh1JpPXSCRkwXlhEhY4?e=rylPQf"
    )

    source_link = escape(str(source_web_url)) if source_web_url else ""
    file_label = escape(str(source_file_name))
    file_html = f"<a href='{source_link}'>{file_label}</a>" if source_link else file_label
    folder_html = f"<a href='{escape(sharepoint_folder_url)}'>Coats Mexico Shipment Reports</a>"

    html = (
        f"<p>{escape(pipeline_label)}The Coats Mexico shipment pipeline found blocking validation issues. "
        f"{escape(target_database)} receipt records were not created.</p>"
        "<ul>"
        f"<li><b>Source file:</b> {file_html}</li>"
        f"<li><b>Target database:</b> {escape(target_database)}</li>"
        f"<li><b>Staging database:</b> {escape(staging_database)}</li>"
        f"<li><b>Shipment date:</b> {escape(_date_only(shipment_date))}</li>"
        f"<li><b>Trailer:</b> {escape(str(trailer_name or ''))}</li>"
        f"<li><b>Blocking issue count:</b> {escape(str(blocking_issue_count or len(issues)))}</li>"
        "</ul>"
        f"{_issue_rows_html(issues)}"
        "<p>After these issues have been resolved, please upload the file again.</p>"
        f"<p>Upload folder: {folder_html}</p>"
    )

    message = {
        "message": {
            "subject": f"{pipeline_label}Coats Mexico shipment validation failed: {source_file_name}",
            "body": {
                "contentType": "HTML",
                "content": html,
            },
            "toRecipients": to_recipients,
            "ccRecipients": cc_recipients,
        },
        "saveToSentItems": True,
    }
    graph_post(f"https://graph.microsoft.com/v1.0/users/{quote(sender, safe='')}/sendMail", message)
    return {"sent": True, "toCount": len(to_recipients), "ccCount": len(cc_recipients)}


def send_success_email(payload: dict[str, Any]) -> dict[str, Any]:
    sender = required_setting("COATS_VALIDATION_EMAIL_FROM")
    to_recipients = _email_recipients("COATS_VALIDATION_EMAIL_TO")
    cc_recipients = _email_recipients("COATS_VALIDATION_EMAIL_CC")
    if not to_recipients:
        raise RuntimeError("Missing required app setting: COATS_VALIDATION_EMAIL_TO")

    source_file_name = payload.get("sourceFileName") or "Unknown Coats Mexico shipment"
    source_web_url = payload.get("sourceWebUrl")
    shipment_date = payload.get("shipmentDate")
    trailer_name = payload.get("trailerName")
    receipt = payload.get("receipt") or {}
    raw_file_rows = payload.get("rawFileRows") or []
    pipeline_label = _pipeline_label(payload)
    target_database = _target_database(payload)
    staging_database = _staging_database(payload)

    source_link = escape(str(source_web_url)) if source_web_url else ""
    file_label = escape(str(source_file_name))
    file_html = f"<a href='{source_link}'>{file_label}</a>" if source_link else file_label

    html = (
        f"<p>{escape(pipeline_label)}The Coats Mexico shipment import succeeded and "
        f"{escape(target_database)} receipt records were created.</p>"
        "<ul>"
        f"<li><b>Source file:</b> {file_html}</li>"
        f"<li><b>Target database:</b> {escape(target_database)}</li>"
        f"<li><b>Staging database:</b> {escape(staging_database)}</li>"
        f"<li><b>Shipment date:</b> {escape(_date_only(shipment_date))}</li>"
        f"<li><b>Trailer:</b> {escape(str(trailer_name or ''))}</li>"
        f"<li><b>Container building Number:</b> {escape(str(receipt.get('container_building_uid') or ''))}</li>"
        f"<li><b>Vessel receipts header Number:</b> {escape(str(receipt.get('vessel_receipts_hdr_uid') or ''))}</li>"
        f"<li><b>Container receipts header Number:</b> {escape(str(receipt.get('container_receipts_hdr_uid') or ''))}</li>"
        f"<li><b>Line count:</b> {escape(str(receipt.get('line_count') or ''))}</li>"
        f"<li><b>Total quantity:</b> {escape(_quantity_4(receipt.get('total_qty')))}</li>"
        "</ul>"
    )
    if not raw_file_rows:
        html += "<p>The raw file could not be sent because of a data load issue.</p>"

    message = {
        "message": {
            "subject": f"{pipeline_label}Coats Mexico shipment import succeeded: {source_file_name}",
            "body": {
                "contentType": "HTML",
                "content": html,
            },
            "toRecipients": to_recipients,
            "ccRecipients": cc_recipients,
        },
        "saveToSentItems": True,
    }
    attachment = _raw_extract_csv_attachment(payload)
    if attachment:
        message["message"]["attachments"] = [attachment]

    graph_post(f"https://graph.microsoft.com/v1.0/users/{quote(sender, safe='')}/sendMail", message)
    return {
        "sent": True,
        "toCount": len(to_recipients),
        "ccCount": len(cc_recipients),
        "attachmentCount": 1 if attachment else 0,
    }


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
    children = graph_get(f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{folder_item_id}/children")
    items: list[dict[str, Any]] = []
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=minutes)

    for item in children.get("value", []):
        name = item.get("name", "")
        if not name.lower().endswith(".xlsx") or name.startswith("~$"):
            continue
        item_time_text = item.get("lastModifiedDateTime") or item.get("createdDateTime")
        if item_time_text:
            item_time = datetime.fromisoformat(item_time_text.replace("Z", "+00:00"))
            if item_time < cutoff:
                continue
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


def stable_shipment_file_id(drive_id: str, item_id: str) -> str:
    import uuid

    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"graph-drive-item:{drive_id}:{item_id}"))


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
